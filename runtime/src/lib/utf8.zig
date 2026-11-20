//! The utf8 library, adapted to character indexed strings.
//!
//! Every Lus string is well formed WTF-8 (spec/design/strings.md), so the
//! byte level questions the Lua library answers have character level
//! counterparts here:
//!
//! - Positions are character positions, exactly like `string.sub` and
//!   `#s`. Negative positions count back from the end in characters.
//! - `utf8.len(s, i, j)` counts the characters in [i, j], so
//!   `utf8.len(s) == #s`. In strict mode (the default) a lone surrogate is
//!   invalid and the result is fail plus the position of that character.
//!   With `lax` set, surrogates count like any other character.
//! - `utf8.codepoint(s, i, j)` returns the code points of the characters in
//!   [i, j]. Strict mode raises "invalid UTF-8 code" on a lone surrogate.
//! - `utf8.offset(s, n, i)` returns the position of the n-th character
//!   counted from character position i. A character occupies exactly one
//!   position, so both results (start and end) are the same position.
//! - `utf8.codes(s)` yields the character position and code point of each
//!   character.
//! - `utf8.char(...)` accepts code points up to U+10FFFF, including
//!   surrogates. Adjacent lead and trail surrogates join into one
//!   supplementary character, as concatenation does.
//! - `utf8.charpattern` is ".", since patterns match whole characters.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("aux.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;

const msg_invalid = "invalid UTF-8 code";
const max_unicode = 0x10FFFF;

pub const funcs = [_]aux.Reg{
    .{ .name = "offset", .func = offset },
    .{ .name = "codepoint", .func = codepoint },
    .{ .name = "char", .func = char },
    .{ .name = "len", .func = len },
    .{ .name = "codes", .func = codes },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try l.push(Value.obj(.table, t));
    try aux.setField(l, t, "charpattern", try l.newStringValue("."));
    l.top -= 1;
    try aux.setGlobal(l, "utf8", Value.obj(.table, t));
}

/// Translates a relative position: negative means back from the end.
fn posrelat(pos: i64, n: usize) i64 {
    if (pos >= 0) return pos;
    if (0 -% @as(u64, @bitCast(pos)) > n) return 0;
    return @as(i64, @intCast(n)) + pos + 1;
}

fn isSurrogate(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDFFF;
}

/// Code point of the character at zero-based character index `ci`.
fn cpAt(l: *Thread, s: *String, ci: usize) u21 {
    const off = s.byteOffset(&l.g.gpa, ci);
    return wtf8.decodeValid(s.bytes(), off).cp;
}

fn len(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n: usize = s.chars;
    var posi = posrelat(try aux.optInt(l, 2, 1), n);
    var posj = posrelat(try aux.optInt(l, 3, -1), n);
    const lax = l.arg(4).truthy();
    if (!(1 <= posi and posi - 1 <= @as(i64, @intCast(n)))) return aux.argError(l, 2, "initial position out of bounds", .{});
    posi -= 1;
    posj -= 1;
    if (!(posj < @as(i64, @intCast(n)))) return aux.argError(l, 3, "final position out of bounds", .{});
    if (posi > posj) return aux.retInt(l, 0);
    if (!lax and !s.flags.ascii) {
        // Only lone surrogates can be invalid in a WTF-8 string.
        const b = s.bytes();
        var off = s.byteOffset(&l.g.gpa, @intCast(posi));
        var ci = posi;
        while (ci <= posj) : (ci += 1) {
            const d = wtf8.decodeValid(b, off);
            if (isSurrogate(d.cp)) {
                try l.push(.nil);
                try l.push(Value.int(ci + 1));
                return 2;
            }
            off += d.len;
        }
    }
    return aux.retInt(l, posj - posi + 1);
}

fn codepoint(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n: usize = s.chars;
    const posi = posrelat(try aux.optInt(l, 2, 1), n);
    const pose = posrelat(try aux.optInt(l, 3, posi), n);
    const lax = l.arg(4).truthy();
    if (posi < 1) return aux.argError(l, 2, "out of bounds", .{});
    if (pose > @as(i64, @intCast(n))) return aux.argError(l, 3, "out of bounds", .{});
    if (posi > pose) return 0;
    if (pose - posi >= std.math.maxInt(i32) or pose - posi + 1 + l.top >= Thread.max_stack) {
        return l.raiseFmt("string slice too long", .{});
    }
    const count: u32 = @intCast(pose - posi + 1);
    try l.ensure(count);
    const b = s.bytes();
    var off = s.byteOffset(&l.g.gpa, @intCast(posi - 1));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const d = wtf8.decodeValid(b, off);
        if (!lax and isSurrogate(d.cp)) return l.raiseFmt(msg_invalid, .{});
        try l.push(Value.int(d.cp));
        off += d.len;
    }
    return count;
}

fn checkCodepoint(l: *Thread, i: u32) Error!u21 {
    const code: u64 = @bitCast(try aux.checkInt(l, i));
    if (code > max_unicode) return aux.argError(l, i, "value out of range", .{});
    return @intCast(code);
}

fn char(l: *Thread) Error!u32 {
    const n = l.argCount();
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chars: usize = 0;
    var ascii = true;
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        var cp = try checkCodepoint(l, i);
        if (cp >= 0xDC00 and cp <= 0xDFFF) {
            if (wtf8.trailingLeadSurrogate(buf.items)) |lead| {
                buf.items.len -= 3;
                chars -= 1;
                cp = wtf8.combineSurrogates(lead, cp);
            }
        }
        var tmp: [4]u8 = undefined;
        const k = wtf8.encode(cp, &tmp);
        buf.appendSlice(gpa, tmp[0..k]) catch return l.raiseMem();
        chars += 1;
        if (cp >= 0x80) ascii = false;
    }
    const s = state.newStringKnown(l.g, buf.items, ascii, chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, s));
}

fn offset(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const slen: i64 = s.chars;
    const n = try aux.checkInt(l, 2);
    const default: i64 = if (n >= 0) 1 else slen + 1;
    var posi = posrelat(try aux.optInt(l, 3, default), @intCast(slen));
    if (!(1 <= posi and posi - 1 <= slen)) return aux.argError(l, 3, "position out of bounds", .{});
    posi -= 1; // zero based
    var target: i64 = undefined;
    if (n == 0) {
        target = posi;
    } else if (n > 0) {
        // The first character is the one at posi.
        if (n - 1 > slen - posi) return aux.retNil(l);
        target = posi + n - 1;
    } else {
        if (-n > posi) return aux.retNil(l);
        target = posi + n;
    }
    try l.push(Value.int(target + 1));
    try l.push(Value.int(target + 1));
    return 2;
}

fn iterAux(l: *Thread, strict: bool) Error!u32 {
    const s = try aux.checkString(l, 1);
    const ctl = l.arg(2);
    const i: i64 = if (ctl.tag == .integer) ctl.asInt() else 0;
    if (i < 0 or i >= s.chars) return 0;
    const cp = cpAt(l, s, @intCast(i));
    if (strict and isSurrogate(cp)) return l.raiseFmt(msg_invalid, .{});
    try l.push(Value.int(i + 1));
    try l.push(Value.int(cp));
    return 2;
}

fn iterStrict(l: *Thread) Error!u32 {
    return iterAux(l, true);
}

fn iterLax(l: *Thread) Error!u32 {
    return iterAux(l, false);
}

fn codes(l: *Thread) Error!u32 {
    const lax = l.arg(2).truthy();
    _ = try aux.checkString(l, 1);
    try l.push(try aux.native(l, if (lax) iterLax else iterStrict, "codes_aux"));
    try l.push(l.arg(1));
    try l.push(Value.int(0));
    return 3;
}
