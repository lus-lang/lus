//! The `vector` library: mutable byte buffers. Vectors hold raw bytes, and
//! strings hold text (spec/design/strings.md). Offsets in this library are
//! zero-based byte offsets.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("auxlib.zig");
const pack = @import("pack.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Vector = object.Vector;

pub const funcs = [_]aux.Reg{
    .{ .name = "create", .func = create },
    .{ .name = "fromstring", .func = from },
    .{ .name = "tostring", .func = tostring },
    .{ .name = "pack", .func = vpack },
    .{ .name = "unpack", .func = vunpack },
    .{ .name = "unpackmany", .func = unpackmany },
    .{ .name = "clone", .func = clone },
    .{ .name = "size", .func = size },
    .{ .name = "resize", .func = resize },
    .{ .name = "get", .func = get },
    .{ .name = "set", .func = set },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try aux.setGlobal(l, "vector", Value.obj(.table, t));
    // Vectors index their library, so v:size() works.
    const mt = try l.newTable(0, 2);
    try aux.setField(l, mt, "__index", Value.obj(.table, t));
    l.g.type_metatables[@backingInt(value.Tag.vector)] = mt;
}

pub fn newVector(l: *Thread, bytes: []const u8) Error!*Vector {
    gc.maybeCollect(l.g);
    const v = gc.alloc(l.g, Vector, .vector, @sizeOf(Vector)) catch return l.raiseMem();
    v.* = .{ .hdr = v.hdr };
    v.bytes.appendSlice(l.g.gpa, bytes) catch return l.raiseMem();
    return v;
}

pub fn newVectorFrom(l: *Thread, list: *std.ArrayList(u8)) Error!*Vector {
    gc.maybeCollect(l.g);
    const v = gc.alloc(l.g, Vector, .vector, @sizeOf(Vector)) catch return l.raiseMem();
    v.* = .{ .hdr = v.hdr, .bytes = list.* };
    list.* = .empty;
    return v;
}

pub fn checkVector(l: *Thread, i: u32) Error!*Vector {
    const v = l.arg(i);
    if (v.tag != .vector) return aux.typeError(l, i, "vector");
    const vec = v.as(Vector);
    if (vec.detached) return aux.argError(l, i, "vector was transferred to another worker", .{});
    return vec;
}

fn create(l: *Thread) Error!u32 {
    const n = try aux.checkInt(l, 1);
    if (n < 0) return aux.argError(l, 1, "capacity must be non-negative", .{});
    const v = try newVector(l, &.{});
    const len = std.math.cast(usize, n) orelse return l.raiseMem();
    v.bytes.appendNTimes(l.g.gpa, 0, len) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.vector, v));
}

fn from(l: *Thread) Error!u32 {
    const a = l.arg(1);
    if (a.tag == .vector) return aux.ret(l, Value.obj(.vector, try newVector(l, a.as(Vector).bytes.items)));
    const s = try aux.checkBytes(l, 1);
    return aux.ret(l, Value.obj(.vector, try newVector(l, s)));
}

/// vector.tostring(v [, i [, j [, mode]]]): decodes bytes i..j (zero-based,
/// inclusive start, exclusive end) as text. Mode "strict" raises on
/// invalid input, "lossy" replaces it with U+FFFD.
fn tostring(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const b = v.bytes.items;
    const i: usize = @intCast(std.math.clamp(try aux.optInt(l, 2, 0), 0, @as(i64, @intCast(b.len))));
    const j: usize = @intCast(std.math.clamp(try aux.optInt(l, 3, @intCast(b.len)), @as(i64, @intCast(i)), @as(i64, @intCast(b.len))));
    const mode = try aux.checkOption(l, 4, "strict", &.{ "strict", "lossy" });
    const slice = b[i..j];
    const a = wtf8.analyze(slice);
    if (a.valid) return aux.ret(l, Value.obj(.string, state.newStringKnown(l.g, slice, a.ascii, a.chars) catch return l.raiseMem()));
    if (mode == 0) return l.raiseFmt("invalid UTF-8 at byte {d}", .{i + a.error_offset});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    wtf8.appendLossy(l.g.gpa, &buf, slice) catch return l.raiseMem();
    return aux.retStr(l, buf.items);
}

fn checkOffset(l: *Thread, i: u32, len: usize) Error!usize {
    const off = try aux.checkInt(l, i);
    if (off < 0 or off > len) return aux.argError(l, i, "offset out of bounds", .{});
    return @intCast(off);
}

fn vpack(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const off = try checkOffset(l, 2, v.bytes.items.len);
    const fmt = try aux.checkBytes(l, 3);
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(l.g.gpa);
    try pack.pack(l, fmt, 4, &tmp);
    if (off + tmp.items.len > v.bytes.items.len) return aux.argError(l, 2, "pack would exceed vector bounds", .{});
    @memcpy(v.bytes.items[off .. off + tmp.items.len], tmp.items);
    return aux.retInt(l, @intCast(off + tmp.items.len));
}

fn vunpack(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const off = try checkOffset(l, 2, v.bytes.items.len);
    const fmt = try aux.checkBytes(l, 3);
    const r = try pack.unpack(l, fmt, v.bytes.items, off, pack.vector_msgs);
    try l.push(Value.int(@intCast(r[1])));
    return r[0] + 1;
}

fn unpackmanyAux(l: *Thread) Error!u32 {
    const nat = l.frame().native.?;
    const ups = nat.upvalues();
    const v = ups[0].as(Vector);
    const fmt = ups[1].as(object.String).bytes();
    const off: usize = @intCast(ups[2].asInt());
    const remaining = ups[3].asInt();
    if (remaining == 0 or off >= v.bytes.items.len) return aux.retNil(l);
    // A trailing partial record is an error rather than a silent stop.
    const need = pack.size(l, fmt) catch 0;
    if (need > 0 and off + need > v.bytes.items.len) return l.raiseFmt("unpack falls out of bounds", .{});
    const r = try pack.unpack(l, fmt, v.bytes.items, off, pack.vector_msgs);
    ups[2] = Value.int(@intCast(r[1]));
    if (remaining > 0) ups[3] = Value.int(remaining - 1);
    return r[0];
}

/// vector.unpackmany(v, offset, fmt [, count]): an iterator over records.
/// A count of zero, the default, means no limit.
fn unpackmany(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const off = try checkOffset(l, 2, v.bytes.items.len);
    const fmt = try aux.checkString(l, 3);
    const count = try aux.optInt(l, 4, 0);
    if (count < 0) return aux.argError(l, 4, "count must be non-negative", .{});
    const n = state.newNative(l.g, unpackmanyAux, "unpackmany", 4) catch return l.raiseMem();
    n.upvalues()[0] = Value.obj(.vector, v);
    n.upvalues()[1] = Value.obj(.string, fmt);
    n.upvalues()[2] = Value.int(@intCast(off));
    n.upvalues()[3] = Value.int(if (count == 0) -1 else count);
    return aux.ret(l, Value.obj(.native, n));
}

fn clone(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    return aux.ret(l, Value.obj(.vector, try newVector(l, v.bytes.items)));
}

fn size(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    return aux.retInt(l, @intCast(v.bytes.items.len));
}

fn resize(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const n = try aux.checkInt(l, 2);
    if (n < 0) return aux.argError(l, 2, "size must be non-negative", .{});
    const old = v.bytes.items.len;
    const len = std.math.cast(usize, n) orelse return l.raiseMem();
    v.bytes.resize(l.g.gpa, len) catch return l.raiseMem();
    if (len > old) @memset(v.bytes.items[old..], 0);
    return 0;
}

/// vector.get(v, offset): the byte at a zero-based offset.
fn get(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const off = try aux.checkInt(l, 2);
    if (off < 0 or off >= v.bytes.items.len) return aux.retNil(l);
    return aux.retInt(l, v.bytes.items[@intCast(off)]);
}

/// vector.set(v, offset, byte): stores a byte at a zero-based offset.
fn set(l: *Thread) Error!u32 {
    const v = try checkVector(l, 1);
    const off = try aux.checkInt(l, 2);
    const b = try aux.checkInt(l, 3);
    if (off < 0 or off >= v.bytes.items.len) return aux.argError(l, 2, "offset out of bounds", .{});
    if (b < 0 or b > 255) return aux.argError(l, 3, "byte out of range", .{});
    v.bytes.items[@intCast(off)] = @intCast(b);
    return 0;
}

/// string.pack(fmt, ...) -> vector
pub fn stringPack(l: *Thread) Error!u32 {
    const fmt = try aux.checkBytes(l, 1);
    var tmp: std.ArrayList(u8) = .empty;
    errdefer tmp.deinit(l.g.gpa);
    try pack.pack(l, fmt, 2, &tmp);
    return aux.ret(l, Value.obj(.vector, try newVectorFrom(l, &tmp)));
}

/// string.unpack(fmt, data [, pos]) with a 1-based position.
pub fn stringUnpack(l: *Thread) Error!u32 {
    const fmt = try aux.checkBytes(l, 1);
    const d = l.arg(2);
    const data = if (d.tag == .vector) d.as(Vector).bytes.items else try aux.checkBytes(l, 2);
    var pos = try aux.optInt(l, 3, 1);
    // Positions follow the string functions: zero and negative positions
    // beyond the start clamp to the first byte.
    if (pos < 0) pos = @as(i64, @intCast(data.len)) + pos + 1;
    if (pos < 1) pos = 1;
    if (pos - 1 > data.len) return aux.argError(l, 3, "initial position out of string", .{});
    const r = try pack.unpack(l, fmt, data, @intCast(pos - 1), pack.string_msgs);
    try l.push(Value.int(@intCast(r[1] + 1)));
    return r[0] + 1;
}

pub fn stringPacksize(l: *Thread) Error!u32 {
    const fmt = try aux.checkBytes(l, 1);
    return aux.retInt(l, @intCast(try pack.size(l, fmt)));
}

/// Adds pack, unpack, and packsize to the `string` table.
pub fn registerString(l: *Thread) Error!void {
    const g = l.g;
    var sv = try aux.getField(l, g.globals.as(object.Table), "string");
    if (sv.tag != .table) {
        sv = Value.obj(.table, try l.newTable(0, 4));
        try aux.setGlobal(l, "string", sv);
    }
    try aux.setFuncs(l, sv.as(object.Table), &.{
        .{ .name = "pack", .func = stringPack },
        .{ .name = "unpack", .func = stringUnpack },
        .{ .name = "packsize", .func = stringPacksize },
    });
}
