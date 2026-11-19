//! The string library.
//!
//! Strings are WTF-8 text and every function here works in characters
//! (code points, lone surrogates included). Positions and lengths seen by
//! Lus code are character positions. Internally the code works on byte
//! offsets and always steps over whole characters, converting between the
//! two only at the boundary. ASCII strings, flagged on the string object,
//! use bytes and characters interchangeably.
//!
//! Every result that is a slice of an argument is valid WTF-8 by
//! construction and is created without revalidation. Results assembled
//! from several pieces go through `Builder`, which joins a lead surrogate
//! followed by a trail surrogate into one supplementary character, as
//! concatenation does.

const std = @import("std");
const builtin = @import("builtin");
const Decimal = @import("../vm/fdigits.zig").Decimal;
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const vmtable = @import("../vm/table.zig");
const wtf8 = @import("../vm/wtf8.zig");
const numeric = @import("../vm/numeric.zig");
const aux = @import("aux.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;
const Allocator = std.mem.Allocator;

pub const funcs = [_]aux.Reg{
    .{ .name = "byte", .func = byte },
    .{ .name = "char", .func = char },
    .{ .name = "find", .func = find },
    .{ .name = "format", .func = format },
    .{ .name = "gmatch", .func = gmatch },
    .{ .name = "gsub", .func = gsub },
    .{ .name = "join", .func = join },
    .{ .name = "len", .func = len },
    .{ .name = "lower", .func = lower },
    .{ .name = "ltrim", .func = ltrim },
    .{ .name = "match", .func = match },
    .{ .name = "rep", .func = rep },
    .{ .name = "dump", .func = dump },
    .{ .name = "reverse", .func = reverse },
    .{ .name = "rtrim", .func = rtrim },
    .{ .name = "split", .func = split },
    .{ .name = "sub", .func = sub, .leaf = subLeaf },
    .{ .name = "trim", .func = trim },
    .{ .name = "upper", .func = upper },
};

/// Creates the `string` table, publishes it as a global, and installs the
/// metatable shared by all strings, whose `__index` is the library table.
pub fn open(l: *Thread) Error!void {
    const lib = try l.newTable(0, funcs.len);
    // Keep the table rooted while the natives are allocated.
    try l.push(Value.obj(.table, lib));
    try aux.setFuncs(l, lib, &funcs);
    const mt = try l.newTable(0, 1);
    try l.push(Value.obj(.table, mt));
    try aux.setField(l, mt, "__index", Value.obj(.table, lib));
    l.g.type_metatables[@backingInt(value.Tag.string)] = mt;
    try aux.setGlobal(l, "string", Value.obj(.table, lib));
    l.top -= 2;
}

// ---------------------------------------------------------------------
// Character helpers

/// Characters in `b`, a slice of `s` that starts and ends on character
/// boundaries.
inline fn charsIn(s: *const String, b: []const u8) usize {
    return if (s.flags.ascii) b.len else wtf8.countChars(b);
}

/// Byte offset of the character that ends just before offset `i > 0`.
fn prevChar(src: []const u8, i: usize) usize {
    var j = i - 1;
    while (j > 0 and src[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

/// Creates the string `s[from..to]` (byte offsets on character
/// boundaries). The slice is valid text, so it is not revalidated.
fn substring(l: *Thread, s: *String, from: usize, to: usize) Error!Value {
    return substringKnown(l, s, from, to, charsIn(s, s.bytes()[from..to]));
}

/// Creates the string `s[from..to]` whose character count is already
/// known. A slice is ASCII exactly when it has one byte per character.
fn substringKnown(l: *Thread, s: *String, from: usize, to: usize, chars: usize) Error!Value {
    if (from == 0 and to == s.len) return Value.obj(.string, s);
    const b = s.bytes()[from..to];
    const r = state.newStringKnown(l.g, b, chars == b.len, chars) catch return l.raiseMem();
    return Value.obj(.string, r);
}

/// Byte offset of the character at zero-based index `ci` of `s`, where
/// `ci` may equal the character count. Long non-ASCII strings start from
/// the nearest breadcrumb at or before `ci` and skip the remaining
/// characters with the vectorized `wtf8.advance`.
fn charOffset(l: *Thread, s: *String, ci: usize) usize {
    if (s.flags.ascii) return ci;
    if (ci >= s.chars) return s.len;
    const k = ci - ci % String.crumb_step;
    return wtf8.advance(s.bytes(), s.byteOffset(l.g.gpa, k), ci - k);
}

/// Translates a relative initial position (negative counts back from the
/// end) into a 1-based position clipped to [1, inf).
fn posRelat(pos: i64, n: usize) usize {
    if (pos > 0) return @intCast(pos);
    if (pos == 0) return 1;
    if (pos < -@as(i64, @intCast(n))) return 1;
    return n - @as(usize, @intCast(-pos)) + 1;
}

/// Optional end position at argument `i`, clipped to [0, n].
fn getEndPos(l: *Thread, i: u32, default: i64, n: usize) Error!usize {
    return clipEnd(try aux.optInt(l, i, default), n);
}

/// An end position clipped to [0, n].
fn clipEnd(pos: i64, n: usize) usize {
    const ni: i64 = @intCast(n);
    if (pos > ni) return n;
    if (pos >= 0) return @intCast(pos);
    if (pos < -ni) return 0;
    return @intCast(ni + pos + 1);
}

/// Size of the stack buffers that hold short results before they are
/// copied into a new string.
const stack_len = 512;

/// Accumulates the bytes of a result string. Appending a piece that
/// starts with a trail surrogate right after a lead surrogate joins the
/// two into one supplementary character, so the result stays valid
/// WTF-8. Short results never leave the builder's stack buffer.
const Builder = struct {
    l: *Thread,
    buf: std.ArrayList(u8),
    first: std.heap.BufferFirstAllocator,
    stack: [stack_len]u8,

    /// Prepares the builder in place, because its allocator points into
    /// its own stack buffer.
    fn init(b: *Builder, l: *Thread) void {
        b.l = l;
        b.buf = .empty;
        b.first = .init(&b.stack, l.g.gpa);
    }

    fn gpa(b: *Builder) Allocator {
        return b.first.allocator();
    }

    fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa());
    }

    fn append(b: *Builder, bytes: []const u8) Error!void {
        const a = b.gpa();
        if (bytes.len >= 3 and bytes[0] == 0xED) {
            if (wtf8.leadingTrailSurrogate(bytes)) |trail| {
                if (wtf8.trailingLeadSurrogate(b.buf.items)) |lead| {
                    b.buf.items.len -= 3;
                    var tmp: [4]u8 = undefined;
                    const n = wtf8.encode(wtf8.combineSurrogates(lead, trail), &tmp);
                    b.buf.appendSlice(a, tmp[0..n]) catch return b.l.raiseMem();
                    b.buf.appendSlice(a, bytes[3..]) catch return b.l.raiseMem();
                    return;
                }
            }
        }
        b.buf.appendSlice(a, bytes) catch return b.l.raiseMem();
    }

    fn appendChar(b: *Builder, cp: u21) Error!void {
        var tmp: [4]u8 = undefined;
        const n = wtf8.encode(cp, &tmp);
        return b.append(tmp[0..n]);
    }

    fn appendRepeat(b: *Builder, c: u8, n: usize) Error!void {
        b.buf.appendNTimes(b.gpa(), c, n) catch return b.l.raiseMem();
    }

    fn print(b: *Builder, comptime fmt: []const u8, args: anytype) Error!void {
        b.buf.print(b.gpa(), fmt, args) catch return b.l.raiseMem();
    }

    fn reserve(b: *Builder, n: usize) Error!void {
        b.buf.ensureTotalCapacity(b.gpa(), n) catch return b.l.raiseMem();
    }

    /// Creates the result string. Every piece appended is valid WTF-8 and
    /// surrogate pairs are joined on the way in, so the bytes need no
    /// validation. The ASCII flag and the character count come from
    /// vectorized scans.
    fn finish(b: *Builder) Error!Value {
        const items = b.buf.items;
        if (builtin.mode == .debug) std.debug.assert(wtf8.analyze(items).valid);
        const ascii = wtf8.asciiPrefix(items) == items.len;
        const chars = if (ascii) items.len else wtf8.countChars(items);
        const r = state.newStringKnown(b.l.g, items, ascii, chars) catch return b.l.raiseMem();
        return Value.obj(.string, r);
    }
};

/// A temporary buffer for a result of known size that is then copied
/// into a new string. Short results stay on the stack.
const Scratch = struct {
    stack: [stack_len]u8 = undefined,
    heap: []u8 = &.{},

    fn get(sc: *Scratch, l: *Thread, n: usize) Error![]u8 {
        if (n <= stack_len) return sc.stack[0..n];
        sc.heap = l.g.gpa.alloc(u8, n) catch return l.raiseMem();
        return sc.heap;
    }

    fn deinit(sc: *Scratch, l: *Thread) void {
        if (sc.heap.len > 0) l.g.gpa.free(sc.heap);
    }
};

// ---------------------------------------------------------------------
// Basic functions

fn len(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    return aux.retInt(l, s.chars);
}

fn sub(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n: usize = s.chars;
    const start = posRelat(try aux.checkInt(l, 2), n);
    const end = try getEndPos(l, 3, -1, n);
    return aux.ret(l, subRange(l, s, start, end) catch return l.raiseMem());
}

/// `string.sub` with integer positions (`state.LeafFn`), the common call.
fn subLeaf(l: *Thread, args: [*]const Value, nargs: u32) ?Value {
    if (nargs < 2 or nargs > 3) return null;
    if (args[0].tag != .string or args[1].tag != .integer) return null;
    var j: i64 = -1;
    if (nargs == 3) {
        if (args[2].tag == .integer) {
            j = args[2].asInt();
        } else if (args[2].tag != .nil) return null;
    }
    const s = args[0].as(String);
    const n: usize = s.chars;
    return subRange(l, s, posRelat(args[1].asInt(), n), clipEnd(j, n)) catch null;
}

/// The characters `start` through `end` of `s`, 1-based and clipped.
inline fn subRange(l: *Thread, s: *String, start: usize, end: usize) Allocator.Error!Value {
    var from: usize = 0;
    var to: usize = 0;
    var count: usize = 0;
    if (start <= end) {
        count = end - start + 1;
        if (s.flags.ascii) {
            from = start - 1;
            to = end;
        } else {
            // Find the start, then skip the characters of the result
            // from there.
            from = charOffset(l, s, start - 1);
            to = wtf8.advance(s.bytes(), from, count);
        }
    }
    if (from == 0 and to == s.len) return Value.obj(.string, s);
    const b = s.bytes()[from..to];
    return Value.obj(.string, try state.newStringKnown(l.g, b, count == b.len, count));
}

/// Maps ASCII letters with `f` and leaves every other byte unchanged.
/// Bytes of multi-byte characters are never ASCII letters, so the
/// character count and ASCII flag carry over.
fn mapAscii(l: *Thread, comptime first: u8) Error!u32 {
    const s = try aux.checkString(l, 1);
    const src = s.bytes();
    var sc: Scratch = .{};
    defer sc.deinit(l);
    const buf = try sc.get(l, src.len);
    // Flipping bit 0x20 maps between the cases. A letter of the case
    // being mapped is one of the 26 bytes from `first`, which a single
    // unsigned comparison tests.
    const vlen = 32;
    const V = @Vector(vlen, u8);
    var i: usize = 0;
    while (i + vlen <= src.len) : (i += vlen) {
        const v: V = src[i..][0..vlen].*;
        const hit = (v -% @as(V, @splat(first))) < @as(V, @splat(26));
        buf[i..][0..vlen].* = @select(u8, hit, v ^ @as(V, @splat(0x20)), v);
    }
    while (i < src.len) : (i += 1) {
        const c = src[i];
        buf[i] = if (c -% first < 26) c ^ 0x20 else c;
    }
    const r = state.newStringKnown(l.g, buf, s.flags.ascii, s.chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, r));
}

fn upper(l: *Thread) Error!u32 {
    return mapAscii(l, 'a');
}

fn lower(l: *Thread) Error!u32 {
    return mapAscii(l, 'A');
}

/// string.dump(f [, strip]): the binary chunk of a Lus function, as a
/// vector of raw bytes. `load` accepts it back.
fn dump(l: *Thread) Error!u32 {
    const f = l.arg(1);
    if (f.tag != .closure) {
        if (f.tag == .native) return l.raiseFmt("unable to dump given function", .{});
        return aux.typeError(l, 1, "function");
    }
    const strip = l.arg(2).truthy();
    const bytes = @import("../compile/dump.zig").dump(l.g.gpa, f.as(object.Closure).proto, strip) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.Unsupported => return l.raiseFmt("unable to dump given function", .{}),
    };
    defer l.g.gpa.free(bytes);
    return aux.ret(l, Value.obj(.vector, try @import("vector.zig").newVector(l, bytes)));
}

fn rep(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n = try aux.checkInt(l, 2);
    const sep: ?*String = if (l.arg(3).isNil()) null else try aux.checkString(l, 3);
    const sb = s.bytes();
    const sepb: []const u8 = if (sep) |x| x.bytes() else "";
    const sep_chars: usize = if (sep) |x| x.chars else 0;
    const sep_ascii = if (sep) |x| x.flags.ascii else true;
    if (n <= 0 or (sb.len == 0 and sepb.len == 0)) return aux.retStr(l, "");
    const count: usize = @intCast(n);
    const unit = sb.len + sepb.len;
    const max_len: usize = std.math.maxInt(u32);
    if (unit > max_len or count > (max_len + sepb.len) / unit)
        return l.raiseFmt("resulting string too large", .{});
    const total = count * unit - sepb.len;

    // A copy can join with its neighbour only when a piece starts with a
    // trail surrogate. Otherwise the result is a plain byte join whose
    // character count is known up front.
    const may_join = wtf8.leadingTrailSurrogate(sb) != null or wtf8.leadingTrailSurrogate(sepb) != null;
    if (may_join) {
        var b: Builder = undefined;
        b.init(l);
        defer b.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (i > 0) try b.append(sepb);
            try b.append(sb);
        }
        return aux.ret(l, try b.finish());
    }
    var sc: Scratch = .{};
    defer sc.deinit(l);
    const buf = try sc.get(l, total);
    var off: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            @memcpy(buf[off..][0..sepb.len], sepb);
            off += sepb.len;
        }
        @memcpy(buf[off..][0..sb.len], sb);
        off += sb.len;
    }
    const chars = count * s.chars + (count - 1) * sep_chars;
    const ascii = s.flags.ascii and sep_ascii;
    const r = state.newStringKnown(l.g, buf, ascii, chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, r));
}

fn reverse(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const src = s.bytes();
    if (s.flags.ascii) {
        var sc: Scratch = .{};
        defer sc.deinit(l);
        const buf = try sc.get(l, src.len);
        for (buf, 0..) |*o, i| o.* = src[src.len - 1 - i];
        const r = state.newStringKnown(l.g, buf, true, src.len) catch return l.raiseMem();
        return aux.ret(l, Value.obj(.string, r));
    }
    // Reversing characters can bring an unpaired trail surrogate before
    // an unpaired lead surrogate into the joining order, so go through
    // the builder.
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    var end = src.len;
    while (end > 0) {
        const start = prevChar(src, end);
        try b.append(src[start..end]);
        end = start;
    }
    return aux.ret(l, try b.finish());
}

fn byte(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n: usize = s.chars;
    const pi = try aux.optInt(l, 2, 1);
    const posi = posRelat(pi, n);
    const pose = try getEndPos(l, 3, pi, n);
    if (posi > pose) return 0;
    if (pose - posi >= std.math.maxInt(i32)) return l.raiseFmt("string slice too long", .{});
    const count = pose - posi + 1;
    try l.ensure(count);
    const src = s.bytes();
    if (s.flags.ascii) {
        for (src[posi - 1 ..][0..count]) |c| try l.push(Value.int(c));
        return @intCast(count);
    }
    var off = charOffset(l, s, posi - 1);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const d = wtf8.decodeValid(src, off);
        try l.push(Value.int(d.cp));
        off += d.len;
    }
    return @intCast(count);
}

fn char(l: *Thread) Error!u32 {
    const n = l.argCount();
    // Short runs of ASCII code points are the common case and need no
    // surrogate joining.
    if (n <= stack_len) {
        var tmp: [stack_len]u8 = undefined;
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const v = l.arg(i);
            if (v.tag != .integer or v.asInt() < 0 or v.asInt() >= 0x80) break;
            tmp[i - 1] = @intCast(v.asInt());
        } else {
            const r = state.newStringKnown(l.g, tmp[0..n], true, n) catch return l.raiseMem();
            return aux.ret(l, Value.obj(.string, r));
        }
    }
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const c = try aux.checkInt(l, i);
        if (c < 0 or c > 0x10FFFF) return aux.argError(l, i, "value out of range", .{});
        try b.appendChar(@intCast(c));
    }
    return aux.ret(l, try b.finish());
}

// ---------------------------------------------------------------------
// Lus additions: trim, split, join

fn isDefaultTrim(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r';
}

/// Whether `cp` is one of the characters of `set`, or whitespace when
/// `set` is null.
fn inSet(cp: u21, set: ?*String) bool {
    const st = set orelse return isDefaultTrim(cp);
    const b = st.bytes();
    if (st.flags.ascii) return cp < 0x80 and std.mem.indexOfScalar(u8, b, @intCast(cp)) != null;
    var i: usize = 0;
    while (i < b.len) {
        const d = wtf8.decodeValid(b, i);
        if (d.cp == cp) return true;
        i += d.len;
    }
    return false;
}

fn trimImpl(l: *Thread, left: bool, right: bool) Error!u32 {
    const s = try aux.checkString(l, 1);
    const set: ?*String = if (l.arg(2).isNil()) null else try aux.checkString(l, 2);
    const src = s.bytes();
    var start: usize = 0;
    var end: usize = src.len;
    if (left) {
        while (start < end) {
            const d = wtf8.decodeValid(src, start);
            if (!inSet(d.cp, set)) break;
            start += d.len;
        }
    }
    if (right) {
        while (end > start) {
            const q = prevChar(src, end);
            if (!inSet(wtf8.decodeValid(src, q).cp, set)) break;
            end = q;
        }
    }
    return aux.ret(l, try substring(l, s, start, end));
}

fn trim(l: *Thread) Error!u32 {
    return trimImpl(l, true, true);
}

fn ltrim(l: *Thread) Error!u32 {
    return trimImpl(l, true, false);
}

fn rtrim(l: *Thread) Error!u32 {
    return trimImpl(l, false, true);
}

/// Splits on a literal delimiter. Matching bytes is enough: valid WTF-8
/// is self-synchronizing, so a match always starts and ends on character
/// boundaries.
fn split(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const d = try aux.checkString(l, 2);
    const src = s.bytes();
    const delim = d.bytes();
    const t = try l.newTable(if (delim.len == 0) s.chars else 0, 0);
    try l.push(Value.obj(.table, t));
    var idx: i64 = 1;
    if (delim.len == 0) {
        var i: usize = 0;
        while (i < src.len) : (idx += 1) {
            const k = wtf8.seqLen(src[i]);
            try ops.rawSet(l, t, Value.int(idx), try substring(l, s, i, i + k));
            i += k;
        }
        return 1;
    }
    var pos: usize = 0;
    while (true) : (idx += 1) {
        const found = std.mem.indexOfPos(u8, src, pos, delim) orelse {
            try ops.rawSet(l, t, Value.int(idx), try substring(l, s, pos, src.len));
            break;
        };
        try ops.rawSet(l, t, Value.int(idx), try substring(l, s, pos, found));
        pos = found + delim.len;
    }
    return 1;
}

fn join(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const tv = l.arg(1);
    const sep = try aux.checkBytes(l, 2);
    const lv = try ops.length(l, tv);
    const n: i64 = switch (lv.tag) {
        .integer => lv.asInt(),
        else => ops.toIntegerStrict(lv) orelse return l.raiseFmt("object length is not an integer", .{}),
    };
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    // A table without a metatable is read twice: once to size the result
    // so the bytes are copied once into one buffer, and once to append.
    const t = tv.as(Table);
    if (t.metatable == null and n > 0) {
        var room: usize = 0;
        var j: i64 = 1;
        while (j <= n) : (j += 1) {
            const v = vmtable.getInt(t, j);
            if (v.tag != .string) break;
            room += v.as(String).len + sep.len;
        }
        try b.reserve(room);
    }
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const v = try ops.index(l, tv, Value.int(i));
        // A hole ends the sequence, so the result never depends on which
        // border the length operator picks.
        if (v.isNil()) break;
        if (i > 1) try b.append(sep);
        // The bytes are copied before anything else can allocate.
        const str = try ops.toString(l, v);
        try b.append(str.bytes());
    }
    return aux.ret(l, try b.finish());
}

// ---------------------------------------------------------------------
// Pattern matching
//
// The matcher follows the classic backtracking design. It works on byte
// offsets into valid WTF-8 and always consumes whole characters, so `.`
// matches one character and sets compare code points. The character
// classes describe ASCII characters only. The matcher has no dependency
// on the VM, which keeps it unit testable.

pub const max_captures = 32;
const max_depth = 200;
const cap_unfinished: isize = -1;
const cap_position: isize = -2;
const specials = "^$*+?.([%-";

pub const PatternError = error{
    TooComplex,
    InvalidCaptureIndex,
    InvalidPatternCapture,
    EndsWithPercent,
    MissingBracket,
    MissingBalanceArgs,
    MissingFrontierBracket,
    TooManyCaptures,
    UnfinishedCapture,
};

/// A capture result: a byte range, or the byte offset of a position
/// capture.
pub const Cap = union(enum) {
    range: struct { from: usize, to: usize },
    position: usize,
};

/// The pattern matcher, specialized at compile time. With `bytewise` set
/// the subject and the pattern are both ASCII, so every character is one
/// byte and the matcher compares bytes without decoding anything.
pub fn MatcherFor(comptime bytewise: bool) type {
    return struct {
        const M = @This();

        src: []const u8,
        pat: []const u8,
        /// Source is ASCII, so byte offsets are character indices.
        ascii: bool,
        depth: u32 = max_depth,
        level: usize = 0,
        capture: [max_captures]struct { init: usize, len: isize } = undefined,
        /// Capture number reported by `error.InvalidCaptureIndex`.
        bad_index: i32 = 0,
        /// A byte offset whose character index is known, used to convert
        /// later offsets without rescanning from the start.
        anchor_byte: usize = 0,
        anchor_char: usize = 0,

        pub fn init(src: []const u8, pat: []const u8, ascii: bool) M {
            return .{ .src = src, .pat = pat, .ascii = bytewise or ascii };
        }

        /// Prepares a new match attempt starting at byte `s`, which is
        /// character `c`.
        pub fn reset(m: *M, s: usize, c: usize) void {
            m.depth = max_depth;
            m.level = 0;
            m.anchor_byte = s;
            m.anchor_char = c;
        }

        /// Zero-based character index of byte offset `off`.
        pub fn charIndex(m: *const M, off: usize) usize {
            if (m.ascii) return off;
            if (off >= m.anchor_byte) return m.anchor_char + wtf8.countChars(m.src[m.anchor_byte..off]);
            return wtf8.countChars(m.src[0..off]);
        }

        /// The character of `text` at byte `i`.
        inline fn charAt(text: []const u8, i: usize) wtf8.Decoded {
            if (bytewise) return .{ .cp = text[i], .len = 1 };
            return wtf8.decodeValid(text, i);
        }

        /// Byte length of the character of `text` that starts at `i`.
        inline fn lenAt(text: []const u8, i: usize) usize {
            if (bytewise) return 1;
            return wtf8.seqLen(text[i]);
        }

        /// Byte offset of the source character that ends just before `s`.
        inline fn before(m: *const M, s: usize) usize {
            if (bytewise) return s - 1;
            return prevChar(m.src, s);
        }

        /// Matches the pattern from byte `p` against the source from byte
        /// `s`, returning the end of the match.
        pub fn match(m: *M, s_in: usize, p_in: usize) PatternError!?usize {
            if (m.depth == 0) return error.TooComplex;
            m.depth -= 1;
            defer m.depth += 1;
            const pat = m.pat;
            var s = s_in;
            var p = p_in;
            while (p < pat.len) {
                switch (pat[p]) {
                    '(' => {
                        if (p + 1 < pat.len and pat[p + 1] == ')') return m.startCapture(s, p + 2, cap_position);
                        return m.startCapture(s, p + 1, cap_unfinished);
                    },
                    ')' => return m.endCapture(s, p + 1),
                    '$' => if (p + 1 == pat.len) {
                        return if (s == m.src.len) s else null;
                    },
                    '%' => if (p + 1 < pat.len) switch (pat[p + 1]) {
                        'b' => {
                            const r = try m.matchBalance(s, p + 2) orelse return null;
                            s = r.s;
                            p = r.p;
                            continue;
                        },
                        'f' => {
                            p += 2;
                            if (p >= pat.len or pat[p] != '[') return error.MissingFrontierBracket;
                            const ep = try m.classEnd(p);
                            const prev: u21 = if (s == 0) 0 else charAt(m.src, m.before(s)).cp;
                            const cur: u21 = if (s < m.src.len) charAt(m.src, s).cp else 0;
                            if (!m.matchBracket(prev, p, ep - 1) and m.matchBracket(cur, p, ep - 1)) {
                                p = ep;
                                continue;
                            }
                            return null;
                        },
                        '0'...'9' => {
                            s = try m.matchCapture(s, pat[p + 1]) orelse return null;
                            p += 2;
                            continue;
                        },
                        else => {},
                    },
                    else => {},
                }
                // A single character class with an optional repetition
                // suffix.
                const ep = try m.classEnd(p);
                const suffix: u8 = if (ep < pat.len) pat[ep] else 0;
                const n = m.singleMatch(s, p, ep);
                if (n == 0) {
                    if (suffix == '*' or suffix == '?' or suffix == '-') {
                        p = ep + 1;
                        continue;
                    }
                    return null;
                }
                switch (suffix) {
                    '?' => {
                        if (try m.match(s + n, ep + 1)) |r| return r;
                        p = ep + 1;
                    },
                    '+' => return m.maxExpand(s + n, p, ep),
                    '*' => return m.maxExpand(s, p, ep),
                    '-' => return m.minExpand(s, p, ep),
                    else => {
                        s += n;
                        p = ep;
                    },
                }
            }
            return s;
        }

        /// Returns capture `i` of a successful match spanning `s..e`. With
        /// no captures, capture 0 is the whole match.
        pub fn getCapture(m: *M, i: usize, s: usize, e: usize) PatternError!Cap {
            if (i >= m.level) {
                if (i != 0) {
                    m.bad_index = @intCast(i + 1);
                    return error.InvalidCaptureIndex;
                }
                return .{ .range = .{ .from = s, .to = e } };
            }
            const c = m.capture[i];
            if (c.len == cap_unfinished) return error.UnfinishedCapture;
            if (c.len == cap_position) return .{ .position = c.init };
            return .{ .range = .{ .from = c.init, .to = c.init + @as(usize, @intCast(c.len)) } };
        }

        /// Byte offset just past the single class starting at `p`.
        fn classEnd(m: *M, p: usize) PatternError!usize {
            const pat = m.pat;
            const c = pat[p];
            var q = p + lenAt(pat, p);
            switch (c) {
                '%' => {
                    if (q >= pat.len) return error.EndsWithPercent;
                    return q + lenAt(pat, q);
                },
                '[' => {
                    if (q < pat.len and pat[q] == '^') q += 1;
                    // The first character is part of the set even when it
                    // is ']', so look for the closing bracket after it.
                    while (true) {
                        if (q >= pat.len) return error.MissingBracket;
                        const cc = pat[q];
                        q += lenAt(pat, q);
                        if (cc == '%' and q < pat.len) q += lenAt(pat, q);
                        if (q < pat.len and pat[q] == ']') break;
                    }
                    return q + 1;
                },
                else => return q,
            }
        }

        /// Byte length of the source character at `s` when it matches the
        /// class `p..ep`, or zero.
        inline fn singleMatch(m: *M, s: usize, p: usize, ep: usize) usize {
            if (s >= m.src.len) return 0;
            const d = charAt(m.src, s);
            const ok = switch (m.pat[p]) {
                '.' => true,
                '%' => matchClass(d.cp, charAt(m.pat, p + 1).cp),
                '[' => m.matchBracket(d.cp, p, ep - 1),
                else => charAt(m.pat, p).cp == d.cp,
            };
            return if (ok) d.len else 0;
        }

        /// Matches `c` against the set whose '[' is at `p` and ']' at
        /// `ec`.
        fn matchBracket(m: *M, c: u21, p: usize, ec: usize) bool {
            const pat = m.pat;
            var sig = true;
            var i = p + 1;
            if (pat[i] == '^') {
                sig = false;
                i += 1;
            }
            while (i < ec) {
                if (pat[i] == '%') {
                    i += 1;
                    const cl = charAt(pat, i);
                    if (matchClass(c, cl.cp)) return sig;
                    i += cl.len;
                    continue;
                }
                const lo = charAt(pat, i);
                const next = i + lo.len;
                if (next + 1 < ec and pat[next] == '-') {
                    const hi = charAt(pat, next + 1);
                    if (lo.cp <= c and c <= hi.cp) return sig;
                    i = next + 1 + hi.len;
                } else {
                    if (lo.cp == c) return sig;
                    i = next;
                }
            }
            return !sig;
        }

        fn matchBalance(m: *M, s: usize, p: usize) PatternError!?struct { s: usize, p: usize } {
            const pat = m.pat;
            if (p >= pat.len) return error.MissingBalanceArgs;
            const open_c = charAt(pat, p);
            if (p + open_c.len >= pat.len) return error.MissingBalanceArgs;
            const close_c = charAt(pat, p + open_c.len);
            const next_p = p + open_c.len + close_c.len;
            if (s >= m.src.len) return null;
            const first = charAt(m.src, s);
            if (first.cp != open_c.cp) return null;
            var depth: usize = 1;
            var q = s + first.len;
            while (q < m.src.len) {
                const d = charAt(m.src, q);
                q += d.len;
                if (d.cp == close_c.cp) {
                    depth -= 1;
                    if (depth == 0) return .{ .s = q, .p = next_p };
                } else if (d.cp == open_c.cp) {
                    depth += 1;
                }
            }
            return null;
        }

        /// The set of ASCII bytes that match the class `p..ep`, as a bit
        /// set. Only the bytewise matcher uses it, because there every
        /// pattern character is one ASCII byte.
        fn classSet(m: *M, p: usize, ep: usize) u128 {
            const pat = m.pat;
            switch (pat[p]) {
                '.' => return ~@as(u128, 0),
                '%' => return classMask(pat[p + 1]),
                '[' => {
                    var set: u128 = 0;
                    var i = p + 1;
                    const ec = ep - 1;
                    const negate = pat[i] == '^';
                    if (negate) i += 1;
                    while (i < ec) {
                        if (pat[i] == '%') {
                            set |= classMask(pat[i + 1]);
                            i += 2;
                        } else if (i + 2 < ec and pat[i + 1] == '-') {
                            var c = pat[i];
                            while (c <= pat[i + 2]) : (c += 1) set |= bitOf(c);
                            i += 3;
                        } else {
                            set |= bitOf(pat[i]);
                            i += 1;
                        }
                    }
                    return if (negate) ~set else set;
                },
                else => return bitOf(pat[p]),
            }
        }

        fn maxExpand(m: *M, s: usize, p: usize, ep: usize) PatternError!?usize {
            var e = s;
            if (bytewise) {
                // Build the class once and test each byte with one shift.
                const set = m.classSet(p, ep);
                const src = m.src;
                while (e < src.len and (set >> @intCast(src[e])) & 1 != 0) e += 1;
            } else while (true) {
                const n = m.singleMatch(e, p, ep);
                if (n == 0) break;
                e += n;
            }
            // Back off one character at a time until the rest matches.
            while (true) {
                if (try m.match(e, ep + 1)) |r| return r;
                if (e == s) return null;
                e = m.before(e);
            }
        }

        fn minExpand(m: *M, s: usize, p: usize, ep: usize) PatternError!?usize {
            var cur = s;
            while (true) {
                if (try m.match(cur, ep + 1)) |r| return r;
                const n = m.singleMatch(cur, p, ep);
                if (n == 0) return null;
                cur += n;
            }
        }

        fn startCapture(m: *M, s: usize, p: usize, what: isize) PatternError!?usize {
            if (m.level >= max_captures) return error.TooManyCaptures;
            m.capture[m.level] = .{ .init = s, .len = what };
            m.level += 1;
            const r = try m.match(s, p);
            if (r == null) m.level -= 1;
            return r;
        }

        fn endCapture(m: *M, s: usize, p: usize) PatternError!?usize {
            const lv = try m.captureToClose();
            m.capture[lv].len = @intCast(s - m.capture[lv].init);
            const r = try m.match(s, p);
            if (r == null) m.capture[lv].len = cap_unfinished;
            return r;
        }

        fn captureToClose(m: *M) PatternError!usize {
            var lv = m.level;
            while (lv > 0) {
                lv -= 1;
                if (m.capture[lv].len == cap_unfinished) return lv;
            }
            return error.InvalidPatternCapture;
        }

        fn matchCapture(m: *M, s: usize, digit: u8) PatternError!?usize {
            const i = @as(i32, digit) - '1';
            if (i < 0 or i >= m.level or m.capture[@intCast(i)].len == cap_unfinished) {
                m.bad_index = i + 1;
                return error.InvalidCaptureIndex;
            }
            const c = m.capture[@intCast(i)];
            // A position capture has no text and never matches.
            if (c.len < 0) return null;
            const n: usize = @intCast(c.len);
            if (m.src.len - s >= n and std.mem.eql(u8, m.src[c.init..][0..n], m.src[s..][0..n])) return s + n;
            return null;
        }
    };
}

/// The general matcher, which decodes characters.
pub const Matcher = MatcherFor(false);

/// The class letters and, for every ASCII character, a bit set of the
/// classes it belongs to. Bit k stands for `class_letters[k]`.
const class_letters = "acdglpsuwx";
const class_table: [128]u16 = blk: {
    @setEvalBranchQuota(10000);
    var t: [128]u16 = @splat(0);
    for (0..128) |i| {
        const b: u8 = @intCast(i);
        const in = [class_letters.len]bool{
            std.ascii.isAlphabetic(b),
            b < 0x20 or b == 0x7F,
            std.ascii.isDigit(b),
            b > 0x20 and b < 0x7F,
            std.ascii.isLower(b),
            b > 0x20 and b < 0x7F and !std.ascii.isAlphanumeric(b),
            b == ' ' or (b >= '\t' and b <= '\r'),
            std.ascii.isUpper(b),
            std.ascii.isAlphanumeric(b),
            std.ascii.isHex(b),
        };
        for (in, 0..) |yes, k| {
            if (yes) t[i] |= 1 << k;
        }
    }
    break :blk t;
};
/// The bit of each lowercase class letter in `class_table`, or zero.
const class_bit: [128]u16 = blk: {
    var t: [128]u16 = @splat(0);
    for (class_letters, 0..) |c, k| t[c] = 1 << k;
    break :blk t;
};

/// For each class letter, the ASCII bytes in the class as a bit set.
const class_masks: [class_letters.len]u128 = blk: {
    @setEvalBranchQuota(10000);
    var t: [class_letters.len]u128 = @splat(0);
    for (0..128) |c| {
        for (0..class_letters.len) |k| {
            if (class_table[c] & (1 << k) != 0) t[k] |= @as(u128, 1) << c;
        }
    }
    break :blk t;
};

/// The bit for ASCII byte `c` in a class bit set.
inline fn bitOf(c: u8) u128 {
    return @as(u128, 1) << @intCast(c);
}

/// The ASCII bytes that `%cl` matches, for an ASCII `cl`.
fn classMask(cl: u8) u128 {
    const lc = std.ascii.toLower(cl);
    const bit = class_bit[lc];
    const set = if (bit != 0)
        class_masks[@ctz(bit)]
    else if (lc == 'z')
        bitOf(0)
    else
        return bitOf(cl);
    return if (cl == lc) set else ~set;
}

/// Whether `c` belongs to class `cl` (the character after '%'). Class
/// letters describe ASCII characters, and an uppercase letter is the
/// complement. Any other `cl` matches itself.
fn matchClass(c: u21, cl: u21) bool {
    if (cl >= 0x80) return cl == c;
    const lc = std.ascii.toLower(@intCast(cl));
    const bit = class_bit[lc];
    const res = if (bit != 0)
        c < 0x80 and class_table[c] & bit != 0
    else if (lc == 'z')
        c == 0
    else
        return cl == c;
    return if (cl == lc) res else !res;
}

fn noSpecials(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, specials) == null;
}

/// The literal text every match of `pat` (from byte `p`) starts with:
/// the leading plain characters, after any opening captures, that are
/// not optional. A match can only start where this text occurs, so the
/// search loops jump between its occurrences with a vectorized
/// substring search instead of trying every position.
fn literalPrefix(pat: []const u8, p_in: usize) []const u8 {
    var p = p_in;
    // Captures consume nothing, so the text after them starts the match.
    while (p < pat.len and pat[p] == '(') {
        p += 1;
        if (p < pat.len and pat[p] == ')') p += 1;
    }
    const start = p;
    while (p < pat.len) {
        if (std.mem.indexOfScalar(u8, "^$*+?.([%-)", pat[p]) != null) break;
        const next = p + wtf8.seqLen(pat[p]);
        const suffix: u8 = if (next < pat.len) pat[next] else 0;
        // A character that may repeat zero times is not required.
        if (suffix == '*' or suffix == '?' or suffix == '-') break;
        p = next;
        // A character that repeats is required once, and nothing after it
        // is at a fixed offset.
        if (suffix == '+') break;
    }
    return pat[start..p];
}

fn patternError(l: *Thread, m: anytype, e: PatternError) Error {
    return switch (e) {
        error.TooComplex => l.raiseFmt("pattern too complex", .{}),
        error.InvalidCaptureIndex => l.raiseFmt("invalid capture index %{d}", .{m.bad_index}),
        error.InvalidPatternCapture => l.raiseFmt("invalid pattern capture", .{}),
        error.EndsWithPercent => l.raiseFmt("malformed pattern (ends with '%')", .{}),
        error.MissingBracket => l.raiseFmt("malformed pattern (missing ']')", .{}),
        error.MissingBalanceArgs => l.raiseFmt("malformed pattern (missing arguments to '%b')", .{}),
        error.MissingFrontierBracket => l.raiseFmt("missing '[' after '%f' in pattern", .{}),
        error.TooManyCaptures => l.raiseFmt("too many captures", .{}),
        error.UnfinishedCapture => l.raiseFmt("unfinished capture", .{}),
    };
}

/// Pushes capture `i` of the match `s..e` of subject `str`.
fn pushCapture(l: *Thread, str: *String, m: anytype, i: usize, s: usize, e: usize) Error!void {
    const cap = m.getCapture(i, s, e) catch |err| return patternError(l, m, err);
    switch (cap) {
        .range => |r| try l.push(try substring(l, str, r.from, r.to)),
        .position => |off| try l.push(Value.int(@intCast(m.charIndex(off) + 1))),
    }
}

/// Pushes every capture, or the whole match when the pattern has none
/// and `s` is given.
fn pushCaptures(l: *Thread, str: *String, m: anytype, s: ?usize, e: usize) Error!u32 {
    const n: usize = if (m.level == 0 and s != null) 1 else m.level;
    try l.ensure(n);
    var i: usize = 0;
    while (i < n) : (i += 1) try pushCapture(l, str, m, i, s orelse 0, e);
    return @intCast(n);
}

/// Whether the bytewise matcher applies: the subject and the pattern are
/// both ASCII.
fn bothAscii(s: *const String, p: *const String) bool {
    return s.flags.ascii and p.flags.ascii;
}

fn findAux(l: *Thread, is_find: bool) Error!u32 {
    const s = try aux.checkString(l, 1);
    const p = try aux.checkString(l, 2);
    const init_c = posRelat(try aux.optInt(l, 3, 1), s.chars) - 1;
    if (init_c > s.chars) return aux.retNil(l);
    const src = s.bytes();
    const pat = p.bytes();
    const init_b = charOffset(l, s, init_c);
    if (is_find and (l.arg(4).truthy() or noSpecials(pat))) {
        const rel = std.mem.indexOf(u8, src[init_b..], pat) orelse return aux.retNil(l);
        const start = init_c + charsIn(s, src[init_b..][0..rel]);
        try l.push(Value.int(@intCast(start + 1)));
        try l.push(Value.int(@intCast(start + p.chars)));
        return 2;
    }
    if (bothAscii(s, p)) return findWith(MatcherFor(true), l, s, p, init_b, init_c, is_find);
    return findWith(Matcher, l, s, p, init_b, init_c, is_find);
}

fn findWith(comptime M: type, l: *Thread, s: *String, p: *String, init_b: usize, init_c: usize, is_find: bool) Error!u32 {
    const src = s.bytes();
    const pat = p.bytes();
    var m = M.init(src, pat, s.flags.ascii);
    const anchor = pat.len > 0 and pat[0] == '^';
    const pstart: usize = if (anchor) 1 else 0;
    const prefix = if (anchor) "" else literalPrefix(pat, pstart);
    var s1 = init_b;
    var c1 = init_c;
    while (true) {
        if (prefix.len > 0) {
            const at = std.mem.indexOfPos(u8, src, s1, prefix) orelse break;
            c1 += charsIn(s, src[s1..at]);
            s1 = at;
        }
        m.reset(s1, c1);
        const res = m.match(s1, pstart) catch |err| return patternError(l, &m, err);
        if (res) |e| {
            if (is_find) {
                try l.push(Value.int(@intCast(c1 + 1)));
                try l.push(Value.int(@intCast(m.charIndex(e))));
                return 2 + try pushCaptures(l, s, &m, null, 0);
            }
            return pushCaptures(l, s, &m, s1, e);
        }
        if (s1 >= src.len or anchor) break;
        s1 += wtf8.seqLen(src[s1]);
        c1 += 1;
    }
    return aux.retNil(l);
}

fn find(l: *Thread) Error!u32 {
    return findAux(l, true);
}

fn match(l: *Thread) Error!u32 {
    return findAux(l, false);
}

// Upvalues of the gmatch iterator.
const gm_subject = 0;
const gm_pattern = 1;
const gm_pos = 2; // byte offset of the next attempt
const gm_char = 3; // character index of that offset
const gm_last = 4; // end of the last match, or -1

fn gmatch(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const p = try aux.checkString(l, 2);
    const init_c = posRelat(try aux.optInt(l, 3, 1), s.chars) - 1;
    var pos_b: usize = s.len + 1;
    var pos_c: usize = s.chars + 1;
    if (init_c <= s.chars) {
        pos_b = charOffset(l, s, init_c);
        pos_c = init_c;
    }
    const it = state.newNative(l.g, gmatchAux, null, 5) catch return l.raiseMem();
    const ups = it.upvalues();
    ups[gm_subject] = Value.obj(.string, s);
    ups[gm_pattern] = Value.obj(.string, p);
    ups[gm_pos] = Value.int(@intCast(pos_b));
    ups[gm_char] = Value.int(@intCast(pos_c));
    ups[gm_last] = Value.int(-1);
    return aux.ret(l, Value.obj(.native, it));
}

fn gmatchAux(l: *Thread) Error!u32 {
    const ups = l.frame().native.?.upvalues();
    const s = ups[gm_subject].as(String);
    const p = ups[gm_pattern].as(String);
    if (bothAscii(s, p)) return gmatchWith(MatcherFor(true), l, ups, s, p);
    return gmatchWith(Matcher, l, ups, s, p);
}

fn gmatchWith(comptime M: type, l: *Thread, ups: []Value, s: *String, p: *String) Error!u32 {
    const src = s.bytes();
    const pat = p.bytes();
    var m = M.init(src, pat, s.flags.ascii);
    const prefix = literalPrefix(pat, 0);
    var pos: usize = @intCast(ups[gm_pos].asInt());
    var c: usize = @intCast(ups[gm_char].asInt());
    const last = ups[gm_last].asInt();
    while (pos <= src.len) {
        if (prefix.len > 0) {
            const at = std.mem.indexOfPos(u8, src, pos, prefix) orelse break;
            c += charsIn(s, src[pos..at]);
            pos = at;
        }
        m.reset(pos, c);
        const res = m.match(pos, 0) catch |err| return patternError(l, &m, err);
        if (res) |e| {
            if (@as(i64, @intCast(e)) != last) {
                ups[gm_pos] = Value.int(@intCast(e));
                ups[gm_char] = Value.int(@intCast(m.charIndex(e)));
                ups[gm_last] = Value.int(@intCast(e));
                return pushCaptures(l, s, &m, pos, e);
            }
        }
        if (pos == src.len) break;
        pos += wtf8.seqLen(src[pos]);
        c += 1;
    }
    ups[gm_pos] = Value.int(@intCast(src.len + 1));
    return 0;
}

const ReplKind = enum { string, table, function };

/// Expands a replacement string: `%0` to `%9` insert captures and `%%`
/// inserts a percent sign.
fn addString(l: *Thread, b: *Builder, str: *String, m: anytype, s: usize, e: usize, news: []const u8) Error!void {
    const src = str.bytes();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, news, i, '%')) |j| {
        try b.append(news[i..j]);
        const k = j + 1;
        const c: u8 = if (k < news.len) news[k] else 0;
        if (c == '%') {
            try b.append("%");
        } else if (c == '0') {
            try b.append(src[s..e]);
        } else if (std.ascii.isDigit(c)) {
            const cap = m.getCapture(c - '1', s, e) catch |err| return patternError(l, m, err);
            switch (cap) {
                .range => |r| try b.append(src[r.from..r.to]),
                .position => |off| try b.print("{d}", .{m.charIndex(off) + 1}),
            }
        } else {
            return l.raiseFmt("invalid use of '%' in replacement string", .{});
        }
        i = k + 1;
    }
    try b.append(news[i..]);
}

/// Appends the replacement for the match `s..e`. Returns false when the
/// function or table produced nil or false, which keeps the original
/// text.
fn addValue(l: *Thread, b: *Builder, str: *String, m: anytype, s: usize, e: usize, kind: ReplKind) Error!bool {
    const repl = l.arg(3);
    const base = l.top;
    const r: Value = switch (kind) {
        .string => {
            try addString(l, b, str, m, s, e, repl.as(String).bytes());
            return true;
        },
        .function => blk: {
            const n = try pushCaptures(l, str, m, s, e);
            // Copy the arguments off the stack, which the call may grow.
            var args: [max_captures]Value = undefined;
            @memcpy(args[0..n], l.stack[base..][0..n]);
            break :blk try ops.call1(l, repl, args[0..n]);
        },
        .table => blk: {
            try pushCapture(l, str, m, 0, s, e);
            break :blk try ops.index(l, repl, l.stack[base]);
        },
    };
    l.top = base;
    // The result is used before anything else allocates.
    if (!r.truthy()) {
        try b.append(str.bytes()[s..e]);
        return false;
    }
    switch (r.tag) {
        .string => try b.append(r.as(String).bytes()),
        .integer, .float, .bigint, .decimal => ops.numberToBuf(b.gpa(), &b.buf, r) catch return l.raiseMem(),
        else => return l.raiseFmt("invalid replacement value (a {s})", .{value.typeName(r.tag)}),
    }
    return true;
}

fn gsub(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const p = try aux.checkString(l, 2);
    const kind: ReplKind = switch (l.arg(3).tag) {
        .string => .string,
        .integer, .float, .bigint, .decimal => blk: {
            _ = try aux.checkString(l, 3);
            break :blk .string;
        },
        .table => .table,
        .closure, .native => .function,
        else => return aux.typeError(l, 3, "string/function/table"),
    };
    const max_s = try aux.optInt(l, 4, @as(i64, s.chars) + 1);
    if (bothAscii(s, p)) return gsubWith(MatcherFor(true), l, s, p, kind, max_s);
    return gsubWith(Matcher, l, s, p, kind, max_s);
}

fn gsubWith(comptime M: type, l: *Thread, s: *String, p: *String, kind: ReplKind, max_s: i64) Error!u32 {
    const src = s.bytes();
    const pat = p.bytes();
    const anchor = pat.len > 0 and pat[0] == '^';
    const pstart: usize = if (anchor) 1 else 0;
    const prefix = if (anchor) "" else literalPrefix(pat, pstart);
    var m = M.init(src, pat, s.flags.ascii);
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    var pos: usize = 0;
    var cpos: usize = 0;
    // Source text before `copied` is already in the builder. Unmatched
    // text is copied in runs, when a match or the end is reached.
    var copied: usize = 0;
    var last: ?usize = null;
    var n: i64 = 0;
    var changed = false;
    while (n < max_s) {
        if (prefix.len > 0) {
            const at = std.mem.indexOfPos(u8, src, pos, prefix) orelse break;
            cpos += charsIn(s, src[pos..at]);
            pos = at;
        }
        m.reset(pos, cpos);
        const res = m.match(pos, pstart) catch |err| return patternError(l, &m, err);
        if (res != null and res != last) {
            const e = res.?;
            n += 1;
            try b.append(src[copied..pos]);
            changed = (try addValue(l, &b, s, &m, pos, e, kind)) or changed;
            cpos = m.charIndex(e);
            pos = e;
            copied = e;
            last = e;
        } else if (pos < src.len) {
            pos += wtf8.seqLen(src[pos]);
            cpos += 1;
        } else break;
        if (anchor) break;
    }
    if (!changed) {
        try l.push(Value.obj(.string, s));
    } else {
        try b.append(src[copied..]);
        try l.push(try b.finish());
    }
    try l.push(Value.int(n));
    return 2;
}

// ---------------------------------------------------------------------
// string.format

/// A parsed conversion specification.
const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    hash: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

const flags_float = "-+#0 ";
const flags_hex = "-#0";
const flags_int = "-+0 ";
const flags_uint = "-0";
const flags_char = "-";

/// Validates the text between '%' and the conversion letter against the
/// accepted flags (at most two width digits and two precision digits)
/// and parses it.
fn parseSpec(l: *Thread, form: []const u8, spec: []const u8, flags: []const u8, allow_precision: bool) Error!Spec {
    var r: Spec = .{};
    var i: usize = 0;
    while (i < spec.len and std.mem.indexOfScalar(u8, flags, spec[i]) != null) : (i += 1) {
        switch (spec[i]) {
            '-' => r.minus = true,
            '+' => r.plus = true,
            ' ' => r.space = true,
            '#' => r.hash = true,
            '0' => r.zero = true,
            else => unreachable,
        }
    }
    if (i < spec.len and spec[i] != '0') {
        var d: usize = 0;
        while (d < 2 and i < spec.len and std.ascii.isDigit(spec[i])) : ({
            i += 1;
            d += 1;
        }) r.width = r.width * 10 + (spec[i] - '0');
        if (i < spec.len and spec[i] == '.' and allow_precision) {
            i += 1;
            var pr: usize = 0;
            d = 0;
            while (d < 2 and i < spec.len and std.ascii.isDigit(spec[i])) : ({
                i += 1;
                d += 1;
            }) pr = pr * 10 + (spec[i] - '0');
            r.precision = pr;
        }
    }
    if (i != spec.len) return l.raiseFmt("invalid conversion specification: '{s}'", .{form});
    return r;
}

/// Appends `prefix` and `body` padded to the field width. `body_chars`
/// is the character count of `body`. Zero padding goes between the
/// prefix and the body.
fn pad(b: *Builder, spec: Spec, prefix: []const u8, body: []const u8, body_chars: usize, zero_ok: bool) Error!void {
    const used = prefix.len + body_chars;
    const fill = if (spec.width > used) spec.width - used else 0;
    if (spec.minus) {
        try b.append(prefix);
        try b.append(body);
        try b.appendRepeat(' ', fill);
    } else if (spec.zero and zero_ok) {
        try b.append(prefix);
        try b.appendRepeat('0', fill);
        try b.append(body);
    } else {
        try b.appendRepeat(' ', fill);
        try b.append(prefix);
        try b.append(body);
    }
}

fn signPrefix(spec: Spec, negative: bool) []const u8 {
    if (negative) return "-";
    if (spec.plus) return "+";
    if (spec.space) return " ";
    return "";
}

/// Formats an integer conversion from its magnitude digits.
fn fmtIntDigits(b: *Builder, spec: Spec, conv: u8, negative: bool, digits_in: []const u8) Error!void {
    var digits = digits_in;
    var tmp: [128]u8 = undefined;
    const is_zero = digits.len == 1 and digits[0] == '0';
    if (spec.precision) |pr| {
        if (pr == 0 and is_zero) {
            digits = "";
        } else if (digits.len < pr) {
            const z = pr - digits.len;
            @memset(tmp[0..z], '0');
            @memcpy(tmp[z..][0..digits.len], digits);
            digits = tmp[0..pr];
        }
    }
    var prefix_buf: [3]u8 = undefined;
    var prefix: []const u8 = signPrefix(spec, negative);
    if (spec.hash) {
        if (conv == 'o' and (digits.len == 0 or digits[0] != '0')) {
            prefix = "0";
        } else if ((conv == 'x' or conv == 'X') and !is_zero) {
            prefix_buf = .{ '0', conv, 0 };
            prefix = prefix_buf[0..2];
        }
    }
    try pad(b, spec, prefix, digits, digits.len, spec.precision == null);
}

fn fmtInt(b: *Builder, spec: Spec, conv: u8, n: i64) Error!void {
    var buf: [32]u8 = undefined;
    const bits: u64 = @bitCast(n);
    const digits = switch (conv) {
        'd', 'i' => std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}),
        'u' => std.fmt.bufPrint(&buf, "{d}", .{bits}),
        'o' => std.fmt.bufPrint(&buf, "{o}", .{bits}),
        'x' => std.fmt.bufPrint(&buf, "{x}", .{bits}),
        'X' => std.fmt.bufPrint(&buf, "{X}", .{bits}),
        else => unreachable,
    } catch unreachable;
    const negative = (conv == 'd' or conv == 'i') and n < 0;
    return fmtIntDigits(b, spec, conv, negative, digits);
}

/// The %e, %f, and %g conversions (and their uppercase forms).
fn fmtFloat(b: *Builder, spec: Spec, conv: u8, f: f64) Error!void {
    const l = b.l;
    const gpa = l.g.gpa;
    const upper_case = std.ascii.isUpper(conv);
    const prefix = signPrefix(spec, std.math.signbit(f));
    if (!std.math.isFinite(f)) {
        const body = if (std.math.isNan(f))
            (if (upper_case) "NAN" else "nan")
        else
            (if (upper_case) "INF" else "inf");
        return pad(b, spec, prefix, body, 3, false);
    }
    var d = Decimal.init(gpa, @abs(f)) catch return l.raiseMem();
    defer d.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const prec = spec.precision orelse 6;
    (switch (std.ascii.toLower(conv)) {
        'f' => d.writeFixed(gpa, &body, prec, spec.hash),
        'e' => d.writeExp(gpa, &body, prec, spec.hash, upper_case),
        'g' => blk: {
            const p = if (prec == 0) 1 else prec;
            d.round(@intCast(p));
            const x: i32 = if (d.isZero()) 0 else d.exp;
            if (x < p and x >= -4) {
                d.writeFixed(gpa, &body, @intCast(@as(i32, @intCast(p)) - 1 - x), spec.hash) catch |err| break :blk err;
            } else {
                d.writeExp(gpa, &body, p - 1, spec.hash, upper_case) catch |err| break :blk err;
            }
            if (!spec.hash) stripZeros(&body);
        },
        else => unreachable,
    }) catch return l.raiseMem();
    return pad(b, spec, prefix, body.items, body.items.len, true);
}

/// Removes trailing fractional zeros (and a bare point) from a %g body,
/// keeping any exponent.
fn stripZeros(body: *std.ArrayList(u8)) void {
    const s = body.items;
    const point = std.mem.indexOfScalar(u8, s, '.') orelse return;
    const exp_at = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    var end = exp_at;
    while (end > point + 1 and s[end - 1] == '0') end -= 1;
    if (end == point + 1) end = point;
    const removed = exp_at - end;
    if (removed == 0) return;
    std.mem.copyForwards(u8, s[end..], s[exp_at..]);
    body.items.len -= removed;
}

/// The %a conversion: hexadecimal floating point, in the style of the C
/// library (a leading digit of 1 for normal numbers).
fn hexFloatBody(buf: *std.ArrayList(u8), gpa: Allocator, f: f64, precision: ?usize, hash: bool) !void {
    const bits: u64 = @bitCast(@abs(f));
    const exp_bits: u64 = (bits >> 52) & 0x7FF;
    var mant: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var lead: u64 = 1;
    var e: i64 = @as(i64, @intCast(exp_bits)) - 1023;
    if (exp_bits == 0) {
        if (mant == 0) {
            lead = 0;
            e = 0;
        } else {
            // Normalize subnormals so the leading digit is 1.
            const shift: u6 = @intCast(@clz(mant) - 11);
            mant = (mant << shift) & ((@as(u64, 1) << 52) - 1);
            e = -1022 - @as(i64, shift);
        }
    }
    var ndig: usize = 13;
    if (precision) |pr| {
        if (pr < 13) {
            const shift: u6 = @intCast((13 - pr) * 4);
            const rem = mant & ((@as(u64, 1) << shift) - 1);
            mant >>= shift;
            const half = @as(u64, 1) << (shift - 1);
            if (rem > half or (rem == half and mant & 1 == 1)) mant += 1;
            if (pr == 0) {
                lead += mant;
                mant = 0;
            } else if (mant >> @intCast(pr * 4) != 0) {
                lead += 1;
                mant &= (@as(u64, 1) << @intCast(pr * 4)) - 1;
            }
        }
        ndig = pr;
    } else {
        // Shortest form: drop trailing zero digits.
        while (ndig > 0 and mant & 0xF == 0) {
            mant >>= 4;
            ndig -= 1;
        }
    }
    try buf.print(gpa, "0x{d}", .{lead});
    if (ndig > 0 or hash) try buf.append(gpa, '.');
    if (ndig > 0) {
        const shown = @min(ndig, 13);
        try buf.print(gpa, "{x:0>[1]}", .{ mant, shown });
        try buf.appendNTimes(gpa, '0', ndig - shown);
    }
    try buf.print(gpa, "p{s}{d}", .{ if (e < 0) "-" else "+", @abs(e) });
}

fn fmtHexFloat(b: *Builder, spec: Spec, conv: u8, f: f64) Error!void {
    const l = b.l;
    const gpa = l.g.gpa;
    const upper_case = conv == 'A';
    const sign = signPrefix(spec, std.math.signbit(f));
    if (!std.math.isFinite(f)) {
        const body = if (std.math.isNan(f))
            (if (upper_case) "NAN" else "nan")
        else
            (if (upper_case) "INF" else "inf");
        return pad(b, spec, sign, body, 3, false);
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    hexFloatBody(&body, gpa, f, spec.precision, spec.hash) catch return l.raiseMem();
    if (upper_case) for (body.items) |*c| {
        c.* = std.ascii.toUpper(c.*);
    };
    // Zero padding goes after the "0x" prefix.
    var prefix_buf: [3]u8 = undefined;
    @memcpy(prefix_buf[0..sign.len], sign);
    @memcpy(prefix_buf[sign.len..][0..2], body.items[0..2]);
    return pad(b, spec, prefix_buf[0 .. sign.len + 2], body.items[2..], body.items.len - 2, true);
}

/// Appends a string literal that reads back as the same string.
fn addQuoted(b: *Builder, s: []const u8) Error!void {
    try b.append("\"");
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x80) {
            const d = wtf8.decodeValid(s, i);
            if (d.cp >= 0xD800 and d.cp <= 0xDFFF) {
                try b.print("\\u{{{x}}}", .{d.cp});
            } else {
                try b.append(s[i..][0..d.len]);
            }
            i += d.len;
            continue;
        }
        if (c == '"' or c == '\\' or c == '\n') {
            try b.append(&.{ '\\', c });
        } else if (c < 0x20 or c == 0x7F) {
            const next_digit = i + 1 < s.len and std.ascii.isDigit(s[i + 1]);
            if (next_digit) try b.print("\\{d:0>3}", .{c}) else try b.print("\\{d}", .{c});
        } else {
            try b.append(&.{c});
        }
        i += 1;
    }
    try b.append("\"");
}

/// The %q conversion.
fn addLiteral(l: *Thread, b: *Builder, arg: u32) Error!void {
    const v = l.arg(arg);
    switch (v.tag) {
        .string => try addQuoted(b, v.as(String).bytes()),
        .integer => {
            const n = v.asInt();
            if (n == std.math.minInt(i64)) try b.append("0x8000000000000000") else try b.print("{d}", .{n});
        },
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f)) {
                try b.append("(0/0)");
            } else if (std.math.isInf(f)) {
                try b.append(if (f < 0) "-1e9999" else "1e9999");
            } else {
                if (std.math.signbit(f)) try b.append("-");
                hexFloatBody(&b.buf, b.gpa(), f, null, false) catch return l.raiseMem();
            }
        },
        .bigint, .decimal => ops.numberToBuf(b.gpa(), &b.buf, v) catch return l.raiseMem(),
        .nil, .true, .false => try b.append((try ops.toString(l, v)).bytes()),
        else => return aux.argError(l, arg, "value has no literal form", .{}),
    }
}

fn format(l: *Thread) Error!u32 {
    const top = l.argCount();
    const fmt = (try aux.checkString(l, 1)).bytes();
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    var arg: u32 = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const j = std.mem.indexOfScalarPos(u8, fmt, i, '%') orelse fmt.len;
        try b.append(fmt[i..j]);
        if (j == fmt.len) break;
        i = j + 1;
        if (i < fmt.len and fmt[i] == '%') {
            try b.append("%");
            i += 1;
            continue;
        }
        arg += 1;
        if (arg > top) return aux.argError(l, arg, "no value", .{});
        var k = i;
        while (k < fmt.len and std.mem.indexOfScalar(u8, "-+#0 123456789.", fmt[k]) != null) k += 1;
        const spec = fmt[i..k];
        if (spec.len + 1 >= 22) return l.raiseFmt("invalid format (too long)", .{});
        if (k == fmt.len) return l.raiseFmt("invalid conversion '%{s}' to 'format'", .{spec});
        const conv = fmt[k];
        const form = fmt[j .. k + wtf8.seqLen(conv)];
        i = form.len + j;
        switch (conv) {
            'c' => {
                const sp = try parseSpec(l, form, spec, flags_char, false);
                const c = try aux.checkInt(l, arg);
                if (c < 0 or c > 0x10FFFF) return aux.argError(l, arg, "value out of range", .{});
                var tmp: [4]u8 = undefined;
                const n = wtf8.encode(@intCast(c), &tmp);
                try pad(&b, sp, "", tmp[0..n], 1, false);
            },
            'd', 'i', 'u', 'o', 'x', 'X' => {
                const flags = switch (conv) {
                    'd', 'i' => flags_int,
                    'u' => flags_uint,
                    else => flags_hex,
                };
                const v = l.arg(arg);
                if (v.tag == .bigint and (conv == 'd' or conv == 'i')) {
                    // Arbitrary precision integers print all their digits.
                    const sp = try parseSpec(l, form, spec, flags, true);
                    const str = numeric.bigToString(l.g.gpa, v.as(numeric.BigInt)) catch return l.raiseMem();
                    defer l.g.gpa.free(str);
                    const neg = str.len > 0 and str[0] == '-';
                    try fmtIntDigits(&b, sp, conv, neg, if (neg) str[1..] else str);
                } else {
                    const n = try aux.checkInt(l, arg);
                    const sp = try parseSpec(l, form, spec, flags, true);
                    try fmtInt(&b, sp, conv, n);
                }
            },
            'a', 'A' => {
                const sp = try parseSpec(l, form, spec, flags_float, true);
                try fmtHexFloat(&b, sp, conv, try aux.checkFloat(l, arg));
            },
            'e', 'E', 'f', 'F', 'g', 'G' => {
                const f = try aux.checkFloat(l, arg);
                const sp = try parseSpec(l, form, spec, flags_float, true);
                try fmtFloat(&b, sp, conv, f);
            },
            'p' => {
                const sp = try parseSpec(l, form, spec, flags_char, false);
                const v = l.arg(arg);
                if (v.tag.isCollectable()) {
                    var tmp: [24]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "0x{x}", .{v.payload}) catch unreachable;
                    try pad(&b, sp, "", s, s.len, false);
                } else {
                    try pad(&b, sp, "", "(null)", 6, false);
                }
            },
            'q' => {
                if (spec.len != 0) return l.raiseFmt("specifier '%q' cannot have modifiers", .{});
                try addLiteral(l, &b, arg);
            },
            's' => {
                const str = try ops.toString(l, l.arg(arg));
                // Root the converted string in the argument slot.
                l.stack[l.base() + arg - 1] = Value.obj(.string, str);
                if (spec.len == 0) {
                    try b.append(str.bytes());
                } else {
                    const sp = try parseSpec(l, form, spec, flags_char, true);
                    var to: usize = str.len;
                    var chars: usize = str.chars;
                    if (sp.precision) |pr| if (pr < chars) {
                        to = charOffset(l, str, pr);
                        chars = pr;
                    };
                    try pad(&b, sp, "", str.bytes()[0..to], chars, false);
                }
            },
            else => return l.raiseFmt("invalid conversion '{s}' to 'format'", .{form}),
        }
    }
    return aux.ret(l, try b.finish());
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Finds the first match of `pat` in `src`. When both are ASCII it runs
/// the bytewise matcher too and checks that the two agree.
fn testMatch(src: []const u8, pat: []const u8) !?[]const u8 {
    const general = try testMatchWith(Matcher, src, pat);
    if (wtf8.analyze(src).ascii and wtf8.analyze(pat).ascii) {
        const bytes = try testMatchWith(MatcherFor(true), src, pat);
        try testing.expectEqual(general == null, bytes == null);
        if (general) |g| try testing.expectEqualStrings(g, bytes.?);
    }
    return general;
}

fn testMatchWith(comptime M: type, src: []const u8, pat: []const u8) !?[]const u8 {
    var m = M.init(src, pat, wtf8.analyze(src).ascii);
    const anchor = pat.len > 0 and pat[0] == '^';
    var s: usize = 0;
    while (true) {
        m.reset(s, 0);
        if (try m.match(s, if (anchor) 1 else 0)) |e| return src[s..e];
        if (s >= src.len or anchor) return null;
        s += wtf8.seqLen(src[s]);
    }
}

test "literal prefixes" {
    try testing.expectEqualStrings("key_", literalPrefix("key_%d+", 0));
    try testing.expectEqualStrings("value ", literalPrefix("value (%d+)", 0));
    try testing.expectEqualStrings("ab", literalPrefix("(ab)c*", 0));
    try testing.expectEqualStrings("ab", literalPrefix("()ab+c", 0));
    try testing.expectEqualStrings("a", literalPrefix("ab-", 0));
    try testing.expectEqualStrings("", literalPrefix("a?b", 0));
    try testing.expectEqualStrings("", literalPrefix("%d+", 0));
    try testing.expectEqualStrings("", literalPrefix("[ab]c", 0));
    try testing.expectEqualStrings("日本", literalPrefix("日本.", 0));
    try testing.expectEqualStrings("x", literalPrefix("x$", 0));
    try testing.expectEqualStrings("abc", literalPrefix("^abc", 1));
}

test "class table" {
    // The table agrees with the class definitions on every ASCII byte.
    for (0..0x80) |i| {
        const c: u21 = @intCast(i);
        const b: u8 = @intCast(i);
        try testing.expectEqual(std.ascii.isAlphabetic(b), matchClass(c, 'a'));
        try testing.expectEqual(!std.ascii.isDigit(b), matchClass(c, 'D'));
        try testing.expectEqual(b == ' ' or (b >= '\t' and b <= '\r'), matchClass(c, 's'));
        try testing.expectEqual(b > 0x20 and b < 0x7F and !std.ascii.isAlphanumeric(b), matchClass(c, 'p'));
        try testing.expectEqual(c == 0, matchClass(c, 'z'));
        try testing.expectEqual(c == '.', matchClass(c, '.'));
    }
    try testing.expect(!matchClass(0xE9, 'a'));
    try testing.expect(matchClass(0xE9, 'A'));
    // The bit sets of the bytewise matcher agree with matchClass.
    for (0..0x80) |cl| for (0..0x80) |c| {
        const in_set = (classMask(@intCast(cl)) >> @intCast(c)) & 1 != 0;
        try testing.expectEqual(matchClass(@intCast(c), @intCast(cl)), in_set);
    };
}

test "bytewise sets agree with the general matcher" {
    const sets = [_][]const u8{ "[^,]", "[a-c]", "[%a_]", "[^%s]", "[%-a]", "[]]", "[^]]", "[a-]", "[%%]", "[%W%d]", "[z-a]", "%A", "%.", "." };
    var src: [128]u8 = undefined;
    for (&src, 0..) |*c, i| c.* = @intCast(i);
    for (sets) |set| {
        var pat_buf: [16]u8 = undefined;
        const pat = std.fmt.bufPrint(&pat_buf, "{s}+", .{set}) catch unreachable;
        // Every starting byte gives the same longest run in both matchers.
        for (0..src.len) |start| {
            var g = Matcher.init(&src, pat, true);
            var b = MatcherFor(true).init(&src, pat, true);
            g.reset(start, start);
            b.reset(start, start);
            try testing.expectEqual(try g.match(start, 0), try b.match(start, 0));
        }
    }
}

test "pattern basics" {
    try testing.expectEqualStrings("o w", (try testMatch("hello world", "o w")).?);
    try testing.expectEqualStrings("hello", (try testMatch("hello world", "%a+")).?);
    try testing.expectEqualStrings("123", (try testMatch("abc123def", "%d+")).?);
    try testing.expectEqualStrings("", (try testMatch("abc", "x*")).?);
    try testing.expect((try testMatch("abc", "^b")) == null);
    try testing.expectEqualStrings("c", (try testMatch("abc", "c$")).?);
    try testing.expectEqualStrings("(a(b)c)", (try testMatch("x(a(b)c)y", "%b()")).?);
    try testing.expectEqualStrings("THE", (try testMatch("THE (quick) fox", "%f[%a]%a+")).?);
    try testing.expectEqualStrings("<a><b>", (try testMatch("<a><b>", "<.*>")).?);
    try testing.expectEqualStrings("<a>", (try testMatch("<a><b>", "<.->")).?);
}

test "pattern characters" {
    // '.' consumes a whole character.
    try testing.expectEqualStrings("é", (try testMatch("é", ".")).?);
    try testing.expectEqualStrings("àé", (try testMatch("xàéy", "[éà]+")).?);
    try testing.expectEqualStrings("βγ", (try testMatch("aβγz", "[α-ω]+")).?);
    try testing.expectEqualStrings("ü", (try testMatch("aüb", "[^%a]")).?);
    try testing.expectEqualStrings("€€", (try testMatch("1€€2", "€+")).?);
    // Backtracking steps back over multi-byte characters.
    try testing.expectEqualStrings("日本語x", (try testMatch("日本語x", ".*x")).?);
}

test "pattern errors" {
    try testing.expectError(error.MissingBracket, testMatch("a", "[a"));
    try testing.expectError(error.EndsWithPercent, testMatch("a", "%"));
    try testing.expectError(error.InvalidPatternCapture, testMatch("a", "a)"));
    try testing.expectError(error.InvalidCaptureIndex, testMatch("a", "%1"));
}

test "decimal rounding" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const cases = [_]struct { f64, usize, []const u8 }{
        .{ 3.14159, 2, "3.14" },                 .{ 0.5, 0, "0" },             .{ 1.5, 0, "2" },        .{ 2.5, 0, "2" },
        .{ 0.125, 2, "0.12" },                   .{ 999.9996, 3, "1000.000" }, .{ 0.0006, 3, "0.001" }, .{ 0.0004, 3, "0.000" },
        .{ 1e20, 1, "100000000000000000000.0" },
    };
    for (cases) |c| {
        out.clearRetainingCapacity();
        var d = try Decimal.init(gpa, c[0]);
        defer d.deinit(gpa);
        try d.writeFixed(gpa, &out, c[1], false);
        try testing.expectEqualStrings(c[2], out.items);
    }
}
