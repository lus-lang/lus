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
const inv = @import("../vm/inv.zig");
const builtin = @import("builtin");
const Decimal = @import("../vm/fdigits.zig").Decimal;
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const vmtable = @import("../vm/table.zig");
const gc = @import("../vm/gc.zig");
const wtf8 = @import("../vm/wtf8.zig");
const numeric = @import("../vm/numeric.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;
const Allocator = std.mem.Allocator;

pub const funcs = [_]aux.Reg{
    .{ .name = "byte", .func = byte, .leaf = byteLeaf },
    .{ .name = "char", .func = char },
    .{ .name = "find", .func = find, .leaf = findLeaf, .leaf_first = true },
    .{ .name = "format", .func = format, .leaf = formatLeaf },
    .{ .name = "gmatch", .func = gmatch },
    .{ .name = "gsub", .func = gsub, .leaf = gsubLeaf, .leaf_first = true },
    .{ .name = "join", .func = join },
    .{ .name = "len", .func = len },
    .{ .name = "bytelen", .func = bytelen },
    .{ .name = "lower", .func = lower, .leaf = lowerLeaf },
    .{ .name = "ltrim", .func = ltrim },
    .{ .name = "match", .func = match },
    .{ .name = "rep", .func = rep },
    .{ .name = "dump", .func = dump },
    .{ .name = "reverse", .func = reverse },
    .{ .name = "rtrim", .func = rtrim },
    .{ .name = "split", .func = split },
    .{ .name = "sub", .func = sub, .leaf = subLeaf },
    .{ .name = "trim", .func = trim },
    .{ .name = "upper", .func = upper, .leaf = upperLeaf },
};

/// Creates the `string` table, publishes it as a global, and installs the
/// metatable shared by all strings, whose `__index` is the library table.
pub fn open(l: *Thread) Error!void {
    const lib = try l.newTable(0, funcs.len);
    // Keep the table rooted while the natives are allocated.
    try l.push(Value.obj(.table, lib));
    try aux.setFuncs(l, lib, .library, "string", &funcs);
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
    return if (s.flags().ascii) b.len else wtf8.countChars(b);
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
/// `ci` may equal the character count (`String.byteOffset`).
inline fn charOffset(l: *Thread, s: *String, ci: usize) usize {
    return s.byteOffset(&l.g.gpa, ci);
}

/// Translates a relative initial position (negative counts back from the
/// end) into a 1-based position clipped to [1, inf).
fn posRelat(pos: i64, n: usize) usize {
    // Callers compare the result with n and n + 1 only, so any position past
    // n + 1 saturates at n + 2. This keeps the cast in range where usize is
    // 32 bits.
    if (pos > 0) return if (pos > @as(i64, @intCast(n)) + 1) n + 2 else @intCast(pos);
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
        // The stack buffer is the first capacity, so short results never
        // call the allocator.
        b.buf.ensureTotalCapacityPrecise(b.gpa(), stack_len) catch {};
    }

    fn gpa(b: *Builder) Allocator {
        return b.first.allocator();
    }

    fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa());
    }

    /// Appends `bytes`. A piece that fits the room left and cannot join a
    /// surrogate is copied inline, which is nearly every piece.
    inline fn append(b: *Builder, bytes: []const u8) Error!void {
        const room = b.buf.unusedCapacitySlice();
        if (bytes.len <= room.len and (bytes.len == 0 or bytes[0] != 0xED)) {
            ops.copyBytes(room, bytes);
            b.buf.items.len += bytes.len;
            return;
        }
        return b.appendSlow(bytes);
    }

    noinline fn appendSlow(b: *Builder, bytes: []const u8) Error!void {
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
        if (inv.deep) inv.assert(wtf8.analyze(items).valid);
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

/// `string.bytelen(s)`: the number of bytes of the UTF-8 form of `s`,
/// which the string records, so the call reads no character.
fn bytelen(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    return aux.retInt(l, @intCast(s.bytes().len));
}

fn len(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    return aux.retInt(l, s.chars());
}

fn sub(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const n: usize = s.chars();
    const start = posRelat(try aux.checkInt(l, 2), n);
    const end = try getEndPos(l, 3, -1, n);
    return aux.ret(l, subRange(l, s, start, end) catch return l.raiseMem());
}

/// The characters `i` through `j` of `s`, as `string.sub` takes them, and
/// the position of the last of them, which is zero for an empty range.
pub fn subPositions(l: *Thread, s: *String, i: i64, j: i64) Allocator.Error!struct { Value, usize } {
    const n: usize = s.chars();
    const start = posRelat(i, n);
    const end = clipEnd(j, n);
    return .{ try subRange(l, s, start, end), if (start <= end) end else 0 };
}

/// The bytes `i` through `j` of a sequence of `n` bytes, as `string.sub`
/// takes positions, as a 0-based range.
pub fn byteRange(i: i64, j: i64, n: usize) struct { from: usize, to: usize } {
    const start = posRelat(i, n);
    const end = clipEnd(j, n);
    if (start > end) return .{ .from = 0, .to = 0 };
    return .{ .from = start - 1, .to = end };
}

/// `string.sub` with integer positions (`state.LeafFn`), the common call.
fn subLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs < 2 or nargs > 3) return state.leaf_miss;
    if (args[0].tag != .string or args[1].tag != .integer) return state.leaf_miss;
    var j: i64 = -1;
    if (nargs == 3) {
        if (args[2].tag == .integer) {
            j = args[2].asInt();
        } else if (args[2].tag != .nil) return state.leaf_miss;
    }
    const s = args[0].as(String);
    const n: usize = s.chars();
    return subRange(l, s, posRelat(args[1].asInt(), n), clipEnd(j, n)) catch state.leaf_miss;
}

/// The characters `start` through `end` of `s`, 1-based and clipped.
inline fn subRange(l: *Thread, s: *String, start: usize, end: usize) Allocator.Error!Value {
    var from: usize = 0;
    var to: usize = 0;
    var count: usize = 0;
    if (start <= end) {
        count = end - start + 1;
        if (s.flags().ascii) {
            from = start - 1;
            to = end;
        } else {
            from = charOffset(l, s, start - 1);
            to = s.endOffset(end, start - 1, from);
        }
    }
    if (from == 0 and to == s.len) return Value.obj(.string, s);
    const b = s.bytes()[from..to];
    return Value.obj(.string, try state.newStringKnown(l.g, b, count == b.len, count));
}

/// Maps ASCII letters with `f` and leaves every other byte unchanged.
/// Bytes of multi-byte characters are never ASCII letters, so the
/// character count and ASCII flag carry over.
/// Maps the case of the ASCII letters of `src` into `buf`.
fn mapCase(comptime first: u8, src: []const u8, buf: []u8) void {
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
}

fn mapAscii(l: *Thread, comptime first: u8) Error!u32 {
    const s = try aux.checkString(l, 1);
    const src = s.bytes();
    var sc: Scratch = .{};
    defer sc.deinit(l);
    const buf = try sc.get(l, src.len);
    mapCase(first, src, buf);
    const r = state.newStringKnown(l.g, buf, s.flags().ascii, s.chars()) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, r));
}

/// `upper` or `lower` of a string of up to `stack_len` bytes, without a
/// frame.
fn mapLeaf(comptime first: u8, l: *Thread, args: [*]const Value, nargs: u32) Value {
    if (nargs != 1 or args[0].tag != .string) return state.leaf_miss;
    const s = args[0].as(String);
    const src = s.bytes();
    if (src.len > stack_len) return state.leaf_miss;
    var buf: [stack_len]u8 = undefined;
    mapCase(first, src, buf[0..src.len]);
    const r = state.newStringKnown(l.g, buf[0..src.len], s.flags().ascii, s.chars()) catch return state.leaf_miss;
    return Value.obj(.string, r);
}

fn upperLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    return mapLeaf('a', l, args, nargs);
}

fn lowerLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    return mapLeaf('A', l, args, nargs);
}

/// `string.byte(s, i)` for one byte of an ASCII string, without a frame.
/// A position outside the string returns no value, which the full native
/// does.
fn byteLeaf(_: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs < 1 or nargs > 2 or args[0].tag != .string) return state.leaf_miss;
    const s = args[0].as(String);
    if (!s.flags().ascii) return state.leaf_miss;
    var i: i64 = 1;
    if (nargs == 2) {
        if (args[1].tag != .integer) return state.leaf_miss;
        i = args[1].asInt();
    }
    const n: i64 = s.len;
    if (i < 0) i += n + 1;
    if (i < 1 or i > n) return state.leaf_miss;
    return Value.int(s.bytes()[@intCast(i - 1)]);
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
    const sep_chars: usize = if (sep) |x| x.chars() else 0;
    const sep_ascii = if (sep) |x| x.flags().ascii else true;
    if (n <= 0 or (sb.len == 0 and sepb.len == 0)) return aux.retStr(l, "");
    // The size check runs in u64 so it holds where usize is 32 bits.
    const unit64: u64 = @as(u64, sb.len) + sepb.len;
    const max_len: u64 = l.g.max_string;
    if (unit64 > max_len or @as(u64, @intCast(n)) > (max_len + sepb.len) / unit64)
        return l.raiseFmt("resulting string too large", .{});
    const count: usize = @intCast(n);
    const total: usize = @intCast(@as(u64, count) * unit64 - sepb.len);

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
    const chars = count * s.chars() + (count - 1) * sep_chars;
    const ascii = s.flags().ascii and sep_ascii;
    const r = state.newStringKnown(l.g, buf, ascii, chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, r));
}

fn reverse(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const src = s.bytes();
    if (s.flags().ascii) {
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
    const n: usize = s.chars();
    const pi = try aux.optInt(l, 2, 1);
    const posi = posRelat(pi, n);
    const pose = try getEndPos(l, 3, pi, n);
    if (posi > pose) return 0;
    if (pose - posi >= std.math.maxInt(i32)) return l.raiseFmt("string slice too long", .{});
    const count = pose - posi + 1;
    try l.ensure(count);
    const src = s.bytes();
    if (s.flags().ascii) {
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
// trim, split, join

fn isDefaultTrim(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r';
}

/// Whether `cp` is one of the characters of `set`, or whitespace when
/// `set` is null.
fn inSet(cp: u21, set: ?*String) bool {
    const st = set orelse return isDefaultTrim(cp);
    const b = st.bytes();
    if (st.flags().ascii) return cp < 0x80 and std.mem.indexOfScalar(u8, b, @intCast(cp)) != null;
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
    var parts: SplitList = .{ .l = l, .slot = l.top };
    try l.push(.nil);
    if (delim.len == 0) {
        var i: usize = 0;
        while (i < src.len) {
            const k = wtf8.seqLen(src[i]);
            try parts.add(try substring(l, s, i, i + k));
            i += k;
        }
        return parts.finish();
    }
    var pos: usize = 0;
    while (true) {
        const found = findBytes(src, pos, delim) orelse {
            try parts.add(try substring(l, s, pos, src.len));
            break;
        };
        try parts.add(try substring(l, s, pos, found));
        pos = found + delim.len;
    }
    return parts.finish();
}

/// The pieces of `split`, which wait on the stack above `slot` and go to
/// the result in batches. A result of one batch is made at its exact
/// size, one word per piece in the cell of its table.
const SplitList = struct {
    l: *Thread,
    /// The stack slot that holds the result once it exists.
    slot: u32,
    t: ?*Table = null,
    n: usize = 0,

    const batch = 256;

    fn add(p: *SplitList, v: Value) Error!void {
        try p.l.push(v);
        if (p.l.top - p.slot - 1 >= batch) try p.flush(false);
    }

    fn flush(p: *SplitList, last: bool) Error!void {
        const l = p.l;
        const vals = l.stack[p.slot + 1 .. l.top];
        if (p.t == null) {
            // Making the table can collect, and the pieces are on the
            // stack, which keeps them alive.
            const t = state.newListIn(l.g, vals) catch return l.raiseMem();
            l.stack[p.slot] = Value.obj(.table, t);
            p.t = t;
        } else {
            const t = p.t.?;
            const end = p.n + vals.len;
            if (end > t.asize) {
                const grow = if (last) end else @max(end, 2 * @as(usize, t.asize));
                vmtable.resize(l.g.gpa, t, grow, vmtable.hashCount(t)) catch return l.raiseMem();
            }
            vmtable.storeList(l.g.gpa, t, p.n, vals) catch return l.raiseMem();
        }
        p.n += vals.len;
        gc.barrierBack(l.g, &p.t.?.hdr);
        l.top = p.slot + 1;
    }

    fn finish(p: *SplitList) Error!u32 {
        if (p.t == null or p.l.top > p.slot + 1) try p.flush(true);
        p.l.top = p.slot + 1;
        return 1;
    }
};

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
        /// The compiled form of the pattern from the start byte the
        /// search uses, for the bytewise matcher.
        prog: ?*const state.PatternProgram = null,

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

        /// Starts a match attempt of the pattern from byte `p` at source
        /// byte `s`, on the compiled program when there is one. The
        /// program starts at the same byte of the pattern as `p`.
        pub fn attempt(m: *M, s: usize, p: usize) PatternError!?usize {
            if (bytewise) if (m.prog) |prog| return m.run(prog, s, 0);
            return m.match(s, p);
        }

        /// Matches the program from op `pc` against the source from byte
        /// `s`. It recurses where `match` recurses, so both reach the
        /// depth limit on the same patterns.
        fn run(m: *M, prog: *const state.PatternProgram, s_in: usize, pc_in: usize) PatternError!?usize {
            if (m.depth == 0) return error.TooComplex;
            m.depth -= 1;
            defer m.depth += 1;
            const src = m.src;
            var s = s_in;
            var pc = pc_in;
            while (pc < prog.nops) {
                const op = &prog.ops[pc];
                switch (op.kind) {
                    .open, .open_position => {
                        if (m.level >= max_captures) return error.TooManyCaptures;
                        m.capture[m.level] = .{ .init = s, .len = if (op.kind == .open) cap_unfinished else cap_position };
                        m.level += 1;
                        if (prog.linear) {
                            pc += 1;
                            continue;
                        }
                        const r = try m.run(prog, s, pc + 1);
                        if (r == null) m.level -= 1;
                        return r;
                    },
                    .close => {
                        const lv = try m.captureToClose();
                        m.capture[lv].len = @intCast(s - m.capture[lv].init);
                        if (prog.linear) {
                            pc += 1;
                            continue;
                        }
                        const r = try m.run(prog, s, pc + 1);
                        if (r == null) m.capture[lv].len = cap_unfinished;
                        return r;
                    },
                    .end => return if (s == src.len) s else null,
                    .literal => {
                        const lit = prog.text[op.from..][0..op.len];
                        if (!std.mem.startsWith(u8, src[s..], lit)) return null;
                        s += lit.len;
                        pc += 1;
                    },
                    .single => {
                        if (s >= src.len or !inByteSet(op.set, src[s])) {
                            if (op.rep == '*' or op.rep == '?' or op.rep == '-') {
                                pc += 1;
                                continue;
                            }
                            return null;
                        }
                        if (op.possessive) {
                            s = if (op.rep == '?') s + 1 else longest(op, src, s + 1);
                            pc += 1;
                            continue;
                        }
                        switch (op.rep) {
                            '?' => {
                                if (try m.run(prog, s + 1, pc + 1)) |r| return r;
                                pc += 1;
                            },
                            '+' => return m.runMax(prog, s + 1, pc),
                            '*' => return m.runMax(prog, s, pc),
                            '-' => return m.runMin(prog, s, pc),
                            else => {
                                s += 1;
                                pc += 1;
                            },
                        }
                    },
                }
            }
            return s;
        }

        /// The end of the longest run of bytes of the set of `op` from `s`.
        inline fn longest(op: *const state.PatternProgram.Op, src: []const u8, s: usize) usize {
            if (op.scan) return std.mem.indexOfScalarPos(u8, src, s, op.stop) orelse src.len;
            var e = s;
            while (e < src.len and inByteSet(op.set, src[e])) e += 1;
            return e;
        }

        fn runMax(m: *M, prog: *const state.PatternProgram, s: usize, pc: usize) PatternError!?usize {
            const op = &prog.ops[pc];
            var e = longest(op, m.src, s);
            while (true) {
                if (try m.run(prog, e, pc + 1)) |r| return r;
                if (e == s) return null;
                e -= 1;
            }
        }

        fn runMin(m: *M, prog: *const state.PatternProgram, s: usize, pc: usize) PatternError!?usize {
            const set = prog.ops[pc].set;
            var cur = s;
            while (true) {
                if (try m.run(prog, cur, pc + 1)) |r| return r;
                if (cur >= m.src.len or !inByteSet(set, m.src[cur])) return null;
                cur += 1;
            }
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

/// The ASCII bytes that can start a match of `pat` from byte `p`, for
/// the bytewise matcher, or null when the pattern does not settle them.
/// A pattern that starts, after any opening captures, with a class that
/// must match once settles them, and the search loops then skip every
/// byte outside the set without starting a match there.
fn firstSet(pat: []const u8, p_in: usize) ?u128 {
    var p = p_in;
    while (p < pat.len and pat[p] == '(') {
        p += 1;
        if (p < pat.len and pat[p] == ')') p += 1;
    }
    if (p >= pat.len) return null;
    switch (pat[p]) {
        ')', '.' => return null,
        '$' => if (p + 1 == pat.len) return null,
        '%' => if (p + 1 >= pat.len or pat[p + 1] == 'b' or pat[p + 1] == 'f' or std.ascii.isDigit(pat[p + 1])) return null,
        else => {},
    }
    var m = MatcherFor(true).init("", pat, true);
    const ep = m.classEnd(p) catch return null;
    if (ep < pat.len and (pat[ep] == '*' or pat[ep] == '?' or pat[ep] == '-')) return null;
    return m.classSet(p, ep);
}

/// `firstSet` through the cache of the state, which holds the last
/// pattern examined by its text, so that a search repeated with the same
/// pattern skips the analysis.
fn firstSetCached(l: *Thread, pat: []const u8, p: usize) ?u128 {
    const c = &l.g.first_set;
    if (c.len == pat.len and c.start == p and std.mem.eql(u8, c.key[0..pat.len], pat)) return c.set;
    const set = firstSet(pat, p);
    if (pat.len <= c.key.len) {
        @memcpy(c.key[0..pat.len], pat);
        c.len = pat.len;
        c.start = p;
        c.set = set;
    }
    return set;
}

/// The first occurrence of `needle` in `hay` at or after byte `start`.
/// It tests the first and the last byte of the needle at 16 positions at
/// once and compares the rest only where both agree, so short subjects
/// pay no setup and long ones skip ahead a vector at a time.
pub fn findBytes(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (start > hay.len or needle.len > hay.len - start) return null;
    if (needle.len < 2) return if (needle.len == 0) start else std.mem.indexOfScalarPos(u8, hay, start, needle[0]);
    const V = @Vector(16, u8);
    const first: V = @splat(needle[0]);
    const last: V = @splat(needle[needle.len - 1]);
    const middle = needle[1 .. needle.len - 1];
    // The last offset a match can start at.
    const end = hay.len - needle.len;
    var misses: usize = 0;
    var i = start;
    while (i + 15 <= end) : (i += 16) {
        const a: V = hay[i..][0..16].*;
        const b: V = hay[i + needle.len - 1 ..][0..16].*;
        var mask = @as(u16, @bitCast(a == first)) & @as(u16, @bitCast(b == last));
        while (mask != 0) : (mask &= mask - 1) {
            const at = i + @ctz(mask);
            if (std.mem.eql(u8, hay[at + 1 ..][0..middle.len], middle)) return at;
            misses += 1;
        }
        // A subject full of near matches goes to a search whose cost
        // does not grow with them.
        if (misses > 64 and middle.len > 8) return std.mem.indexOfPos(u8, hay, i + 16, needle);
    }
    while (i <= end) : (i += 1) {
        if (hay[i] == needle[0] and std.mem.eql(u8, hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Whether ASCII byte `c` is in `set`.
inline fn inByteSet(set: u128, c: u8) bool {
    // One 64-bit half and one shift, which is cheaper than shifting the
    // whole set.
    const halves: [2]u64 = @bitCast(set);
    return (halves[c >> 6] >> @as(u6, @truncate(c))) & 1 != 0;
}

/// Compiles `pat` from byte `start` for the bytewise matcher into `out`,
/// returning false for a pattern outside the compiled forms: one with
/// `%b`, `%f` or a back reference, a malformed one, or one with more ops
/// or literal bytes than a program holds. Those run on the interpreter,
/// which also reports their errors.
fn compileProgram(pat: []const u8, start: usize, out: *state.PatternProgram) bool {
    var m = MatcherFor(true).init("", pat, true);
    var n: usize = 0;
    var text_len: usize = 0;
    var unclosed: usize = 0;
    var captures: usize = 0;
    var p = start;
    while (p < pat.len) {
        if (n == state.PatternProgram.max_ops) return false;
        switch (pat[p]) {
            '(' => {
                if (captures == max_captures) return false;
                captures += 1;
                if (p + 1 < pat.len and pat[p + 1] == ')') {
                    out.ops[n] = .{ .kind = .open_position };
                    p += 2;
                } else {
                    out.ops[n] = .{ .kind = .open };
                    unclosed += 1;
                    p += 1;
                }
                n += 1;
                continue;
            },
            ')' => {
                if (unclosed == 0) return false;
                unclosed -= 1;
                out.ops[n] = .{ .kind = .close };
                n += 1;
                p += 1;
                continue;
            },
            '$' => if (p + 1 == pat.len) {
                out.ops[n] = .{ .kind = .end };
                n += 1;
                p += 1;
                continue;
            },
            '%' => if (p + 1 < pat.len) switch (pat[p + 1]) {
                'b', 'f', '0'...'9' => return false,
                else => {},
            },
            else => {},
        }
        const ep = m.classEnd(p) catch return false;
        const suffix: u8 = if (ep < pat.len) pat[ep] else 0;
        const repeat: u8 = switch (suffix) {
            '?', '*', '+', '-' => suffix,
            else => 0,
        };
        const set = m.classSet(p, ep);
        p = if (repeat != 0) ep + 1 else ep;
        if (repeat == 0 and @popCount(set) == 1) {
            // One byte that must match once joins the literal run before it.
            if (text_len == out.text.len) return false;
            out.text[text_len] = @intCast(@ctz(set));
            text_len += 1;
            if (n > 0 and out.ops[n - 1].kind == .literal) {
                out.ops[n - 1].len += 1;
            } else {
                out.ops[n] = .{ .kind = .literal, .from = @intCast(text_len - 1), .len = 1 };
                n += 1;
            }
            continue;
        }
        out.ops[n] = .{ .kind = .single, .set = set, .rep = repeat };
        if (@popCount(~set) == 1) {
            out.ops[n].scan = true;
            out.ops[n].stop = @intCast(@ctz(~set));
        }
        n += 1;
    }
    out.nops = @intCast(n);
    for (out.ops[0..n], 0..) |*op, i| {
        if (op.kind != .single or (op.rep != '?' and op.rep != '*' and op.rep != '+')) continue;
        if (followSet(out, i + 1)) |follow| op.possessive = follow & op.set == 0;
    }
    out.linear = for (out.ops[0..n]) |op| {
        if (op.kind == .single and op.rep != 0 and !op.possessive) break false;
    } else true;
    return true;
}

/// The bytes that can start what the ops of `prog` from `pc` on match,
/// or null when they do not settle them. Captures consume nothing, so
/// the op after them decides. A program that ends, or reaches its final
/// `$`, there leaves no byte to start anything, which the empty set
/// stands for.
fn followSet(prog: *const state.PatternProgram, pc: usize) ?u128 {
    var j = pc;
    while (j < prog.nops) : (j += 1) {
        const op = &prog.ops[j];
        switch (op.kind) {
            .open, .open_position, .close => continue,
            .end => return 0,
            .literal => return @as(u128, 1) << @intCast(prog.text[op.from]),
            .single => return if (op.rep == 0 or op.rep == '+') op.set else null,
        }
    }
    return 0;
}

/// The compiled program of `pat` from byte `start`, through the cache of
/// the state, or null for a pattern that does not compile. The program
/// stays valid until the next call, which may replace it.
fn programFor(l: *Thread, pat: []const u8, start: usize) ?*const state.PatternProgram {
    const c = &l.g.patterns;
    for (&c.entries) |*e| {
        if (e.len == pat.len and e.start == start and std.mem.eql(u8, e.key[0..pat.len], pat)) return if (e.ok) e else null;
    }
    const e = &c.entries[c.next];
    if (pat.len > e.key.len) return null;
    c.next = @intCast((c.next + 1) % c.entries.len);
    @memcpy(e.key[0..pat.len], pat);
    e.len = pat.len;
    e.start = start;
    e.ok = compileProgram(pat, start, e);
    return if (e.ok) e else null;
}

/// The first byte at or after `pos` that is in `set`, or `src.len`.
inline fn skipTo(src: []const u8, pos: usize, set: u128) usize {
    var i = pos;
    while (i < src.len and !inByteSet(set, src[i])) i += 1;
    return i;
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
    // Each short capture looks up the string table, and the slots of a
    // large table are seldom in the cache. Loading them for every capture
    // first lets those reads overlap.
    if (n > 1) {
        const src = str.bytes();
        for (0..n) |i| {
            const c = m.capture[i];
            if (c.len < 2 or c.len > String.short_max) continue;
            const b = src[c.init..][0..@intCast(c.len)];
            l.g.strings.prefetch(object.hashBytes(l.g.seed, b));
        }
    }
    var i: usize = 0;
    while (i < n) : (i += 1) try pushCapture(l, str, m, i, s orelse 0, e);
    return @intCast(n);
}

/// Whether the bytewise matcher applies: the subject and the pattern are
/// both ASCII.
fn bothAscii(s: *const String, p: *const String) bool {
    return s.flags().ascii and p.flags().ascii;
}

fn findAux(l: *Thread, is_find: bool) Error!u32 {
    const s = try aux.checkString(l, 1);
    const p = try aux.checkString(l, 2);
    const init_c = posRelat(try aux.optInt(l, 3, 1), s.chars()) - 1;
    if (init_c > s.chars()) return aux.retNil(l);
    const src = s.bytes();
    const pat = p.bytes();
    const init_b = charOffset(l, s, init_c);
    if (is_find and (l.arg(4).truthy() or noSpecials(pat))) {
        const rel = findBytes(src[init_b..], 0, pat) orelse return aux.retNil(l);
        const start = init_c + charsIn(s, src[init_b..][0..rel]);
        try l.push(Value.int(@intCast(start + 1)));
        try l.push(Value.int(@intCast(start + p.chars())));
        return 2;
    }
    if (bothAscii(s, p)) return findWith(MatcherFor(true), l, s, p, init_b, init_c, is_find);
    return findWith(Matcher, l, s, p, init_b, init_c, is_find);
}

const Found = struct { start_b: usize, start_c: usize, end: usize };

/// Searches `s` for the pattern from byte `init_b`, which is character
/// `init_c`, with the matcher `m`, which holds the captures of the match
/// it returns.
fn search(comptime M: type, l: *Thread, m: *M, s: *String, p: *String, init_b: usize, init_c: usize) Error!?Found {
    const src = s.bytes();
    const pat = p.bytes();
    const anchor = pat.len > 0 and pat[0] == '^';
    const pstart: usize = if (anchor) 1 else 0;
    const prefix = if (anchor) "" else literalPrefix(pat, pstart);
    const first: ?u128 = if (M == MatcherFor(true) and !anchor and prefix.len == 0) firstSetCached(l, pat, pstart) else null;
    if (M == MatcherFor(true)) m.prog = programFor(l, pat, pstart);
    var s1 = init_b;
    var c1 = init_c;
    while (true) {
        if (prefix.len > 0) {
            const at = findBytes(src, s1, prefix) orelse break;
            c1 += charsIn(s, src[s1..at]);
            s1 = at;
        } else if (first) |set| {
            // The source is ASCII, so bytes are characters.
            const at = skipTo(src, s1, set);
            if (at == src.len) break;
            c1 += at - s1;
            s1 = at;
        }
        m.reset(s1, c1);
        const res = m.attempt(s1, pstart) catch |err| return patternError(l, m, err);
        if (res) |e| return .{ .start_b = s1, .start_c = c1, .end = e };
        if (s1 >= src.len or anchor) break;
        s1 += wtf8.seqLen(src[s1]);
        c1 += 1;
    }
    return null;
}

fn findWith(comptime M: type, l: *Thread, s: *String, p: *String, init_b: usize, init_c: usize, is_find: bool) Error!u32 {
    var m = M.init(s.bytes(), p.bytes(), s.flags().ascii);
    const f = (try search(M, l, &m, s, p, init_b, init_c)) orelse return aux.retNil(l);
    if (is_find) {
        try l.push(Value.int(@intCast(f.start_c + 1)));
        try l.push(Value.int(@intCast(m.charIndex(f.end))));
        return 2 + try pushCaptures(l, s, &m, null, 0);
    }
    return pushCaptures(l, s, &m, f.start_b, f.end);
}

/// `find` for a caller that wants only the start, without a frame. The
/// start needs no captures. Every error takes the full native.
fn findLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs < 2 or nargs > 4 or args[0].tag != .string or args[1].tag != .string) return state.leaf_miss;
    var init: i64 = 1;
    if (nargs >= 3) switch (args[2].tag) {
        .integer => init = args[2].asInt(),
        .nil => {},
        else => return state.leaf_miss,
    };
    const plain = nargs == 4 and args[3].truthy();
    const s = args[0].as(String);
    const p = args[1].as(String);
    const init_c = posRelat(init, s.chars()) - 1;
    if (init_c > s.chars()) return .nil;
    const src = s.bytes();
    const pat = p.bytes();
    const init_b = charOffset(l, s, init_c);
    if (plain or noSpecials(pat)) {
        const rel = findBytes(src[init_b..], 0, pat) orelse return .nil;
        return Value.int(@intCast(init_c + charsIn(s, src[init_b..][0..rel]) + 1));
    }
    const top = l.top;
    const f = (if (bothAscii(s, p)) blk: {
        var m = MatcherFor(true).init(src, pat, s.flags().ascii);
        break :blk search(MatcherFor(true), l, &m, s, p, init_b, init_c);
    } else blk: {
        var m = Matcher.init(src, pat, s.flags().ascii);
        break :blk search(Matcher, l, &m, s, p, init_b, init_c);
    }) catch {
        l.top = top;
        return state.leaf_miss;
    };
    return if (f) |x| Value.int(@intCast(x.start_c + 1)) else .nil;
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
// The literal prefix of the pattern, as the byte range `gm_prefix` of
// it packed into one integer, and the two halves of its first set, or
// nil when the pattern has none. They depend on the pattern alone, so
// `gmatch` finds them once for every step of the loop.
const gm_prefix = 5;
const gm_first_lo = 6;
const gm_first_hi = 7;
const gm_count = 8;

fn gmatch(l: *Thread) Error!u32 {
    const s = try aux.checkString(l, 1);
    const p = try aux.checkString(l, 2);
    const init_c = posRelat(try aux.optInt(l, 3, 1), s.chars()) - 1;
    var pos_b: usize = s.len + 1;
    var pos_c: usize = s.chars() + 1;
    if (init_c <= s.chars()) {
        pos_b = charOffset(l, s, init_c);
        pos_c = init_c;
    }
    const pat = p.bytes();
    const prefix = literalPrefix(pat, 0);
    const from: u64 = @intFromPtr(prefix.ptr) - @intFromPtr(pat.ptr);
    const first: ?u128 = if (bothAscii(s, p) and prefix.len == 0) firstSet(pat, 0) else null;
    const it = state.newNative(l.g, gmatchAux, null, gm_count) catch return l.raiseMem();
    const ups = it.upvalues();
    ups[gm_subject] = Value.obj(.string, s);
    ups[gm_pattern] = Value.obj(.string, p);
    ups[gm_pos] = Value.int(@intCast(pos_b));
    ups[gm_char] = Value.int(@intCast(pos_c));
    ups[gm_last] = Value.int(-1);
    ups[gm_prefix] = Value.int(@intCast((from << 32) | prefix.len));
    ups[gm_first_lo] = if (first) |f| Value.int(@bitCast(@as(u64, @truncate(f)))) else .nil;
    ups[gm_first_hi] = if (first) |f| Value.int(@bitCast(@as(u64, @truncate(f >> 64)))) else .nil;
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
    var m = M.init(src, pat, s.flags().ascii);
    if (M == MatcherFor(true)) m.prog = programFor(l, pat, 0);
    const packed_prefix: u64 = @bitCast(ups[gm_prefix].asInt());
    const prefix = pat[@intCast(packed_prefix >> 32)..][0..@intCast(packed_prefix & 0xFFFF_FFFF)];
    const first: ?u128 = if (M == MatcherFor(true) and !ups[gm_first_lo].isNil())
        @as(u128, @as(u64, @bitCast(ups[gm_first_hi].asInt()))) << 64 | @as(u64, @bitCast(ups[gm_first_lo].asInt()))
    else
        null;
    var pos: usize = @intCast(ups[gm_pos].asInt());
    var c: usize = @intCast(ups[gm_char].asInt());
    const last = ups[gm_last].asInt();
    while (pos <= src.len) {
        if (prefix.len > 0) {
            const at = findBytes(src, pos, prefix) orelse break;
            c += charsIn(s, src[pos..at]);
            pos = at;
        } else if (first) |set| {
            const at = skipTo(src, pos, set);
            if (at == src.len) break;
            c += at - pos;
            pos = at;
        }
        m.reset(pos, c);
        const res = m.attempt(pos, 0) catch |err| return patternError(l, &m, err);
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
fn addValue(l: *Thread, b: *Builder, str: *String, m: anytype, s: usize, e: usize, kind: ReplKind, repl: Value) Error!bool {
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
            // A table without a metatable is read directly, keyed by the
            // matched text when the pattern has no captures. Nothing
            // allocates between making the key and reading the table.
            if (m.level == 0 and repl.as(Table).metatable == null) {
                const key = try substring(l, str, s, e);
                break :blk vmtable.get(repl.as(Table), key);
            }
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
        .integer, .float, .bigint, .decimal => ops.numberToBuf(b.gpa(), &b.buf, r) catch |err| return ops.raiseText(l, err),
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
    const max_s = try aux.optInt(l, 4, @as(i64, s.chars()) + 1);
    const r = if (bothAscii(s, p))
        try gsubWith(MatcherFor(true), l, s, p, kind, l.arg(3), max_s)
    else
        try gsubWith(Matcher, l, s, p, kind, l.arg(3), max_s);
    try l.push(r.str);
    try l.push(Value.int(r.n));
    return 2;
}

/// `gsub` for a caller that wants only the resulting string, without a
/// frame: a string replacement, or a table without a metatable, whose
/// lookups run no Lus code. Anything else, and every error, takes the
/// full native.
fn gsubLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs != 3 or args[0].tag != .string or args[1].tag != .string) return state.leaf_miss;
    const repl = args[2];
    const kind: ReplKind = switch (repl.tag) {
        .string => .string,
        .table => if (repl.as(Table).metatable == null) .table else return state.leaf_miss,
        else => return state.leaf_miss,
    };
    const s = args[0].as(String);
    const p = args[1].as(String);
    const top = l.top;
    const max_s = @as(i64, s.chars()) + 1;
    const r = (if (bothAscii(s, p))
        gsubWith(MatcherFor(true), l, s, p, kind, repl, max_s)
    else
        gsubWith(Matcher, l, s, p, kind, repl, max_s)) catch {
        l.top = top;
        return state.leaf_miss;
    };
    return r.str;
}

const GsubResult = struct { str: Value, n: i64 };

fn gsubWith(comptime M: type, l: *Thread, s: *String, p: *String, kind: ReplKind, repl: Value, max_s: i64) Error!GsubResult {
    const src = s.bytes();
    const pat = p.bytes();
    const anchor = pat.len > 0 and pat[0] == '^';
    const pstart: usize = if (anchor) 1 else 0;
    const prefix = if (anchor) "" else literalPrefix(pat, pstart);
    const first: ?u128 = if (M == MatcherFor(true) and !anchor and prefix.len == 0) firstSetCached(l, pat, pstart) else null;
    var m = M.init(src, pat, s.flags().ascii);
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    if (first) |set| {
        // A pattern that is one class that must match once, such as
        // `[&<>]`, matches exactly the bytes in its start set, one at a
        // time, so the search needs no matcher.
        if ((m.classEnd(pstart) catch 0) == pat.len) {
            m.reset(0, 0);
            var n: i64 = 0;
            var copied: usize = 0;
            var changed = false;
            while (n < max_s) {
                const at = skipTo(src, copied, set);
                if (at == src.len) break;
                n += 1;
                try b.append(src[copied..at]);
                changed = (try addValue(l, &b, s, &m, at, at + 1, kind, repl)) or changed;
                copied = at + 1;
            }
            if (!changed) return .{ .str = Value.obj(.string, s), .n = n };
            try b.append(src[copied..]);
            return .{ .str = try b.finish(), .n = n };
        }
    }
    // A replacement function, or a metamethod of a replacement table, can
    // run searches that replace the entries of the cache, so the matcher
    // then keeps its own copy of the program.
    var own: state.PatternProgram = undefined;
    if (M == MatcherFor(true)) if (programFor(l, pat, pstart)) |prog| {
        const shared = kind == .string or (kind == .table and repl.as(Table).metatable == null);
        if (shared) {
            m.prog = prog;
        } else {
            own = prog.*;
            m.prog = &own;
        }
    };
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
            const at = findBytes(src, pos, prefix) orelse break;
            cpos += charsIn(s, src[pos..at]);
            pos = at;
        } else if (first) |set| {
            const at = skipTo(src, pos, set);
            if (at == src.len) break;
            cpos += at - pos;
            pos = at;
        }
        m.reset(pos, cpos);
        const res = m.attempt(pos, pstart) catch |err| return patternError(l, &m, err);
        if (res != null and res != last) {
            const e = res.?;
            n += 1;
            try b.append(src[copied..pos]);
            changed = (try addValue(l, &b, s, &m, pos, e, kind, repl)) or changed;
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
    if (!changed) return .{ .str = Value.obj(.string, s), .n = n };
    try b.append(src[copied..]);
    return .{ .str = try b.finish(), .n = n };
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
    if (conv != 'o' and conv != 'x' and conv != 'X') {
        const u: u64 = if (conv == 'u') bits else @abs(n);
        const start = ops.intDigits(buf[0..20], u);
        return fmtIntDigits(b, spec, conv, conv != 'u' and n < 0, buf[start..20]);
    }
    const digits = switch (conv) {
        'o' => std.fmt.bufPrint(&buf, "{o}", .{bits}),
        'x' => std.fmt.bufPrint(&buf, "{x}", .{bits}),
        'X' => std.fmt.bufPrint(&buf, "{X}", .{bits}),
        else => unreachable,
    } catch unreachable;
    return fmtIntDigits(b, spec, conv, false, digits);
}

/// The %e, %f, and %g conversions (and their uppercase forms).
fn fmtFloat(b: *Builder, spec: Spec, conv: u8, f: f64) Error!void {
    const l = b.l;
    const gpa = l.g.gpa;
    const upper_case = std.ascii.isUpper(conv);
    // A NaN has no meaningful sign, and its sign bit differs between
    // platforms, so it formats as a positive value (`ops.formatFloat`).
    const prefix = signPrefix(spec, std.math.signbit(f) and !std.math.isNan(f));
    if (!std.math.isFinite(f)) {
        const body = if (std.math.isNan(f))
            (if (upper_case) "NAN" else "nan")
        else
            (if (upper_case) "INF" else "inf");
        return pad(b, spec, prefix, body, 3, false);
    }
    var d = Decimal.init(gpa, @abs(f)) catch return l.raiseMem();
    defer d.deinit(gpa);
    return fmtDigits(b, spec, conv, prefix, &d);
}

/// The %e, %f and %g conversions of a decimal number, from its exact
/// digits, so `%.2f` of 2.675d rounds 2.675 itself.
fn fmtExactDecimal(b: *Builder, spec: Spec, conv: u8, v: *const numeric.Decimal) Error!void {
    const l = b.l;
    const gpa = l.g.gpa;
    const digits = numeric.radix.toDecimal(gpa, v.coef().abs()) catch return l.raiseMem();
    var d = Decimal.fromCoefficient(gpa, digits, v.exponent);
    defer d.deinit(gpa);
    const prefix = signPrefix(spec, !v.positive and !d.isZero());
    return fmtDigits(b, spec, conv, prefix, &d);
}

fn fmtDigits(b: *Builder, spec: Spec, conv: u8, prefix: []const u8, d: *Decimal) Error!void {
    const l = b.l;
    const gpa = l.g.gpa;
    const upper_case = std.ascii.isUpper(conv);
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
    const sign = signPrefix(spec, std.math.signbit(f) and !std.math.isNan(f));
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
        .bigint, .decimal => ops.numberToBuf(b.gpa(), &b.buf, v) catch |err| return ops.raiseText(l, err),
        .nil, .true, .false => try b.append((try ops.toString(l, v)).bytes()),
        else => return aux.argError(l, arg, "value has no literal form", .{}),
    }
}

fn format(l: *Thread) Error!u32 {
    const fmt = (try aux.checkString(l, 1)).bytes();
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    // A `%s` conversion runs `__tostring`, which can grow the stack and
    // free the block the arguments are in, so the conversions read a copy.
    // The arguments stay rooted in their stack slots.
    const args = l.g.gpa.dupe(Value, l.stack[l.base()..][0..l.argCount()]) catch return l.raiseMem();
    defer l.g.gpa.free(args);
    try formatInto(false, l, &b, fmt, args);
    return aux.ret(l, try b.finish());
}

/// `string.format` without a frame, for arguments that are numbers and
/// strings. Anything that needs a conversion with a metamethod, `%q`, an
/// exact integer, or an error takes the full native.
fn formatLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs < 1 or args[0].tag != .string) return state.leaf_miss;
    const top = l.top;
    var b: Builder = undefined;
    b.init(l);
    defer b.deinit();
    formatInto(true, l, &b, args[0].as(String).bytes(), args[0..nargs]) catch {
        l.top = top;
        return state.leaf_miss;
    };
    return b.finish() catch {
        l.top = top;
        return state.leaf_miss;
    };
}

/// The conversions of `string.format` over `args`, whose first value is
/// the format string. The leaf form accepts only plain numbers and
/// strings, and fails without a message on anything else.
fn fmtInt64(comptime leaf: bool, l: *Thread, args: []const Value, arg: u32) Error!i64 {
    const v = args[arg - 1];
    if (v.tag == .integer) return v.asInt();
    if (leaf) return error.LusError;
    return aux.checkInt(l, arg);
}

fn fmtFloat64(comptime leaf: bool, l: *Thread, args: []const Value, arg: u32) Error!f64 {
    const v = args[arg - 1];
    if (v.tag == .float) return v.asFloat();
    if (v.tag == .integer) return @floatFromInt(v.asInt());
    if (leaf) return error.LusError;
    return aux.checkFloat(l, arg);
}

/// The zero-padded width of an integer conversion whose specification is
/// empty or a zero and one digit, as `%d` and `%02d` are, or null for any
/// other specification. These are the common forms, which `appendInt`
/// writes without parsing the specification.
inline fn plainWidth(spec: []const u8) ?u8 {
    if (spec.len == 0) return 0;
    if (spec.len == 2 and spec[0] == '0' and spec[1] >= '1' and spec[1] <= '9') return spec[1] - '0';
    return null;
}

/// Appends the decimal digits of `n`, after its sign and enough zeros to
/// fill `width` bytes, as `%0Nd` does.
fn appendInt(b: *Builder, n: i64, width: u8) Error!void {
    const u = @abs(n);
    const room = b.buf.unusedCapacitySlice();
    if (u < 100_000_000 and room.len >= 9) {
        // Eight digits with leading zeros, built at once in one word,
        // so a number costs the same whatever its count of digits.
        const neg = @intFromBool(n < 0);
        const digits = 1 + @as(usize, @intFromBool(u >= 10)) + @intFromBool(u >= 100) + @intFromBool(u >= 1000) +
            @intFromBool(u >= 10_000) + @intFromBool(u >= 100_000) + @intFromBool(u >= 1_000_000) + @intFromBool(u >= 10_000_000);
        const fill: usize = if (width > neg + digits) width - neg else digits;
        if (fill <= 8) {
            room[0] = '-';
            const word = eightDigits(@intCast(u)) >> @intCast(8 * (8 - fill));
            std.mem.writeInt(u64, room[neg..][0..8], word, .little);
            b.buf.items.len += neg + fill;
            return;
        }
    }
    var tmp: [20]u8 = undefined;
    const start = ops.intDigits(&tmp, u);
    const digits = tmp[start..];
    var out: [32]u8 = undefined;
    var at: usize = 0;
    if (n < 0) {
        out[0] = '-';
        at = 1;
    }
    const used = at + digits.len;
    if (width > used) {
        @memset(out[at..][0 .. width - used], '0');
        at += width - used;
    }
    @memcpy(out[at..][0..digits.len], digits);
    return b.append(out[0 .. at + digits.len]);
}

/// The eight decimal digits of `u`, below 10^8, with leading zeros, as
/// the ASCII bytes of a little-endian word whose first byte is the first
/// digit. Each step splits every lane of the word in two, by
/// multiplications that stand for divisions by 10000, 100 and 10.
fn eightDigits(u: u32) u64 {
    const v: u64 = (u / 10_000) | (@as(u64, u % 10_000) << 32);
    const hundreds = ((v * 5243) >> 19) & 0x0000_007F_0000_007F;
    const pairs = hundreds | ((v - hundreds * 100) << 16);
    const tens = ((pairs * 103) >> 10) & 0x000F_000F_000F_000F;
    const d = tens | ((pairs - tens * 10) << 8);
    return d + 0x3030_3030_3030_3030;
}

/// Whether `c` may appear between '%' and the conversion letter: a flag,
/// a digit of the width or the precision, or the point between them.
inline fn isSpecByte(c: u8) bool {
    return switch (c) {
        '-', '+', '#', ' ', '.', '0'...'9' => true,
        else => false,
    };
}

fn formatInto(comptime leaf: bool, l: *Thread, b: *Builder, fmt: []const u8, args: []const Value) Error!void {
    const top: u32 = @intCast(args.len);
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
        if (arg > top) return if (leaf) error.LusError else aux.argError(l, arg, "no value", .{});
        var k = i;
        while (k < fmt.len and isSpecByte(fmt[k])) k += 1;
        const spec = fmt[i..k];
        if (spec.len + 1 >= 22) return l.raiseFmt("invalid format (too long)", .{});
        if (k == fmt.len) return l.raiseFmt("invalid conversion '%{s}' to 'format'", .{spec});
        const conv = fmt[k];
        const form = fmt[j .. k + wtf8.seqLen(conv)];
        i = form.len + j;
        switch (conv) {
            'c' => {
                const sp = try parseSpec(l, form, spec, flags_char, false);
                const c = try fmtInt64(leaf, l, args, arg);
                if (c < 0 or c > 0x10FFFF) return aux.argError(l, arg, "value out of range", .{});
                var tmp: [4]u8 = undefined;
                const n = wtf8.encode(@intCast(c), &tmp);
                try pad(b, sp, "", tmp[0..n], 1, false);
            },
            'd', 'i', 'u', 'o', 'x', 'X' => {
                const v0 = args[arg - 1];
                if ((conv == 'd' or conv == 'i') and v0.tag == .integer) {
                    if (plainWidth(spec)) |width| {
                        try appendInt(b, v0.asInt(), width);
                        continue;
                    }
                }
                const flags = switch (conv) {
                    'd', 'i' => flags_int,
                    'u' => flags_uint,
                    else => flags_hex,
                };
                const v = args[arg - 1];
                if (v.tag == .bigint and (conv == 'd' or conv == 'i')) {
                    if (leaf) return error.LusError;
                    // Arbitrary precision integers print all their digits.
                    const sp = try parseSpec(l, form, spec, flags, true);
                    const str = numeric.bigToText(l.g.gpa, v.as(numeric.BigInt)) catch |err| return ops.raiseText(l, err);
                    defer l.g.gpa.free(str);
                    const neg = str.len > 0 and str[0] == '-';
                    try fmtIntDigits(b, sp, conv, neg, if (neg) str[1..] else str);
                } else {
                    const n = try fmtInt64(leaf, l, args, arg);
                    const sp = try parseSpec(l, form, spec, flags, true);
                    try fmtInt(b, sp, conv, n);
                }
            },
            'a', 'A' => {
                const sp = try parseSpec(l, form, spec, flags_float, true);
                try fmtHexFloat(b, sp, conv, try fmtFloat64(leaf, l, args, arg));
            },
            'e', 'E', 'f', 'F', 'g', 'G' => {
                if (args[arg - 1].tag == .decimal) {
                    if (leaf) return error.LusError;
                    const sp = try parseSpec(l, form, spec, flags_float, true);
                    try fmtExactDecimal(b, sp, conv, args[arg - 1].as(numeric.Decimal));
                } else {
                    const f = try fmtFloat64(leaf, l, args, arg);
                    const sp = try parseSpec(l, form, spec, flags_float, true);
                    try fmtFloat(b, sp, conv, f);
                }
            },
            'p' => {
                const sp = try parseSpec(l, form, spec, flags_char, false);
                const v = args[arg - 1];
                if (v.tag.isCollectable()) {
                    var tmp: [24]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "0x{x}", .{v.payload}) catch unreachable;
                    try pad(b, sp, "", s, s.len, false);
                } else {
                    try pad(b, sp, "", "(null)", 6, false);
                }
            },
            'q' => {
                if (leaf) return error.LusError;
                if (spec.len != 0) return l.raiseFmt("specifier '%q' cannot have modifiers", .{});
                try addLiteral(l, b, arg);
            },
            's' => {
                const sv = args[arg - 1];
                if (leaf and sv.tag != .string and sv.tag != .integer and sv.tag != .float) return error.LusError;
                const str = if (sv.tag == .string) sv.as(String) else try ops.toString(l, sv);
                // Root the converted string in the argument slot. The
                // leaf copies it before anything else allocates.
                if (!leaf) l.stack[l.base() + arg - 1] = Value.obj(.string, str);
                if (spec.len == 0) {
                    try b.append(str.bytes());
                } else {
                    const sp = try parseSpec(l, form, spec, flags_char, true);
                    var to: usize = str.len;
                    var chars: usize = str.chars();
                    if (sp.precision) |pr| if (pr < chars) {
                        to = charOffset(l, str, pr);
                        chars = pr;
                    };
                    try pad(b, sp, "", str.bytes()[0..to], chars, false);
                }
            },
            else => return l.raiseFmt("invalid conversion '{s}' to 'format'", .{form}),
        }
    }
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

test "findBytes agrees with a plain search" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var hay: [300]u8 = undefined;
    var needle: [24]u8 = undefined;
    for (0..2000) |_| {
        // A small alphabet makes partial matches common.
        const hn = r.uintAtMost(usize, hay.len);
        const nn = r.uintAtMost(usize, needle.len);
        for (hay[0..hn]) |*c| c.* = 'a' + r.uintLessThan(u8, 3);
        for (needle[0..nn]) |*c| c.* = 'a' + r.uintLessThan(u8, 3);
        const start = r.uintAtMost(usize, hn + 1);
        const want = if (start > hn) null else std.mem.indexOfPosLinear(u8, hay[0..hn], start, needle[0..nn]);
        try testing.expectEqual(want, findBytes(hay[0..hn], start, needle[0..nn]));
    }
    // Long runs of near matches.
    var long: [200]u8 = @splat('a');
    var near: [31]u8 = @splat('a');
    near[30] = 'b';
    try testing.expectEqual(@as(?usize, null), findBytes(&long, 0, &near));
    @memset(long[160..], 'b');
    try testing.expectEqual(@as(?usize, 130), findBytes(&long, 0, &near));
}

test "skipTo finds the first byte of a set" {
    const src = "plain text with <tags> & \"quotes\" and it's 0123456789 abcdefghijklmnop";
    const sets = [_][]const u8{ "&<>\"'", "<", "z", "0123456789", "ab", "\n" };
    for (sets) |members| {
        var set: u128 = 0;
        for (members) |c| set |= @as(u128, 1) << @intCast(c);
        for (0..src.len + 1) |pos| {
            var want = pos;
            while (want < src.len and (set >> @intCast(src[want])) & 1 == 0) want += 1;
            try testing.expectEqual(want, skipTo(src, pos, set));
        }
    }
}

test "compiled patterns agree with the interpreter" {
    const B = MatcherFor(true);
    const pats = [_][]const u8{
        "^(%S+) %- %- %[[^%]]*%] \"(%u+) /(%S*) HTTP/1%.1\" (%d+) (%d+)$",
        "%a+",
        "[^\n]+",
        "(%d+)-(%d+)",
        "a?b",
        "a*b",
        "a-b",
        "<(.-)>",
        "<.*>",
        "()x()",
        "(a(b)c)",
        "[%w_]+$",
        "x$y",
        "^^a",
        "[]]+",
        "[^]]+",
        "%.%%",
        "(a*(.)%w(%s*))",
        "[a-c]+",
        "k=(%w*)",
        "(h)(e)(l)",
        "%s*$",
        "a+$",
        "(",
        "a)",
        "[a",
        "%",
        "%ba(",
        "%f[%a]",
        "(.)%1",
        "",
        "^",
        "%d+%.%d+",
        "%d*%d",
        "%a+%a",
        "%a?b",
        "%a?%d",
        "(%w+)=(%w*);",
        "%s*()$",
        "[^,]*,[^,]*",
        "%d+%s?%d+",
        "x*()x",
        "[ab]+b",
        "%S+ %S+$",
        "(%d+)%.(%d+)",
        "(%a+)=(%d*);",
        "((%a+) (%d+))$",
        "()%d+()%s",
        "(%a+)(%d?)x",
    };
    const srcs = [_][]const u8{
        "10.1.2.3 - - [20/Nov/2026:10:01:02 +0000] \"GET /api/v1/items/7 HTTP/1.1\" 200 512",
        "hello world 12-34 k=v_1 <a><b> abcab aab b",
        "x$y ^^a ]]] [z] .% (abc) help \n line two\n",
        "12.5 3 4 a=1;b=;cc a,b,,c xxx abab 77 8",
        "",
    };
    for (pats) |pat| {
        const anchor = pat.len > 0 and pat[0] == '^';
        const pstart: usize = if (anchor) 1 else 0;
        var prog: state.PatternProgram = .{};
        if (!compileProgram(pat, pstart, &prog)) continue;
        for (srcs) |src| {
            for (0..src.len + 1) |at| {
                var a = B.init(src, pat, true);
                var b = B.init(src, pat, true);
                b.prog = &prog;
                a.reset(at, at);
                b.reset(at, at);
                const ra = a.attempt(at, pstart);
                const rb = b.attempt(at, pstart);
                if (ra) |ea| {
                    try testing.expectEqual(ea, try rb);
                    if (ea != null) {
                        try testing.expectEqual(a.level, b.level);
                        for (0..a.level) |i| try testing.expectEqual(a.getCapture(i, at, ea.?), b.getCapture(i, at, ea.?));
                    }
                } else |err| try testing.expectError(err, rb);
            }
        }
    }
    // Patterns the program does not cover stay on the interpreter.
    var prog: state.PatternProgram = .{};
    for ([_][]const u8{ "%b()", "%f[%a]", "(.)%1", "[a", "%", "a)" }) |pat| try testing.expect(!compileProgram(pat, 0, &prog));
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
