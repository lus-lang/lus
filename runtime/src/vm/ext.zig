//! Runtime support for Lus extension types and operations: slices, enum
//! members, and query objects.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const state = @import("state.zig");
const table = @import("table.zig");
const ops = @import("ops.zig");
const gc = @import("gc.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;

// ---------------------------------------------------------------------
// Slices (grammar section 5.3)

fn sliceBound(l: *Thread, v: Value) Error!?i64 {
    return switch (v.tag) {
        .nil => null,
        .integer => v.asInt(),
        .float => ops.floatToInt(v.asFloat()) orelse l.raiseFmt("slice index must be an integer", .{}),
        .string => blk: {
            const n = ops.toNumberCoerce(v) orelse return l.raiseFmt("slice index must be an integer", .{});
            break :blk ops.toIntegerStrict(n) orelse l.raiseFmt("slice index must be an integer", .{});
        },
        else => l.raiseFmt("slice index must be an integer", .{}),
    };
}

pub fn slice(l: *Thread, obj: Value, from: Value, to: Value) Error!Value {
    // __slice wins for tables and other values that define it.
    if (obj.tag != .string and obj.tag != .vector) {
        const tm = l.metamethod(obj, .index); // placeholder lookup to keep cache warm
        _ = tm;
        const sl = sliceMetamethod(l, obj);
        if (!sl.isNil()) return ops.call1(l, sl, &.{ obj, from, to });
    }
    switch (obj.tag) {
        .string => {
            const s = obj.as(String);
            const len: i64 = s.chars;
            var i = (try sliceBound(l, from)) orelse 1;
            var j = (try sliceBound(l, to)) orelse len;
            if (i < 1) i = 1;
            if (j > len) j = len;
            if (i > len or j < 1) return l.newStringValue("");
            if (i <= j) return substring(l, s, @intCast(i - 1), @intCast(j));
            // Reversed: characters from i down to j.
            return reversedSubstring(l, s, @intCast(j - 1), @intCast(i));
        },
        .vector => {
            const b = obj.as(object.Vector).bytes.items;
            const len: i64 = @intCast(b.len);
            var i = (try sliceBound(l, from)) orelse 1;
            var j = (try sliceBound(l, to)) orelse len;
            if (i < 1) i = 1;
            if (j > len) j = len;
            const vec = @import("../lib/vector.zig");
            if (i > len or j < 1) return Value.obj(.vector, try vec.newVector(l, &.{}));
            if (i <= j) return Value.obj(.vector, try vec.newVector(l, b[@intCast(i - 1)..@intCast(j)]));
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(l.g.gpa);
            var k = i;
            while (k >= j) : (k -= 1) tmp.append(l.g.gpa, b[@intCast(k - 1)]) catch return l.raiseMem();
            return Value.obj(.vector, try vec.newVector(l, tmp.items));
        },
        .table => {
            const t = obj.as(Table);
            const i = (try sliceBound(l, from)) orelse 1;
            const j = (try sliceBound(l, to)) orelse table.length(t);
            const span: i64 = if (i <= j) j - i + 1 else i - j + 1;
            if (span > (1 << 26)) return l.raiseFmt("slice span too large", .{});
            const r = try l.newTable(@intCast(@max(span, 0)), 0);
            var k: i64 = i;
            var dst: i64 = 1;
            const step: i64 = if (i <= j) 1 else -1;
            while (true) : (k += step) {
                const v = table.getInt(t, k);
                if (!v.isNil()) try ops.rawSet(l, r, Value.int(dst), v);
                dst += 1;
                if (k == j) break;
            }
            return Value.obj(.table, r);
        },
        else => return l.raiseFmt("attempt to slice a {s} value", .{l.typeNameOf(obj)}),
    }
}

fn sliceMetamethod(l: *Thread, obj: Value) Value {
    const mt = l.metatable(obj) orelse return .nil;
    const key = state.newStringKnown(l.g, "__slice", true, 7) catch return .nil;
    return table.getStr(mt, key);
}

/// Characters [ci, cj) of `s` as a new string.
pub fn substring(l: *Thread, s: *String, ci: usize, cj: usize) Error!Value {
    const b0 = s.byteOffset(&l.g.gpa, ci);
    const b1 = s.byteOffset(&l.g.gpa, cj);
    const str = state.newStringKnown(l.g, s.bytes()[b0..b1], s.flags.ascii or (cj - ci == b1 - b0), cj - ci) catch return l.raiseMem();
    return Value.obj(.string, str);
}

fn reversedSubstring(l: *Thread, s: *String, ci: usize, cj: usize) Error!Value {
    const gpa = l.g.gpa;
    const b0 = s.byteOffset(&l.g.gpa, ci);
    const b1 = s.byteOffset(&l.g.gpa, cj);
    const src = s.bytes()[b0..b1];
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.resize(gpa, src.len) catch return l.raiseMem();
    // Copy characters back to front.
    var r: usize = 0;
    var w: usize = src.len;
    while (r < src.len) {
        const n = @import("wtf8.zig").seqLen(src[r]);
        w -= n;
        @memcpy(buf.items[w .. w + n], src[r .. r + n]);
        r += n;
    }
    const str = state.newStringIn(l.g, buf.items) catch return l.raiseMem();
    return Value.obj(.string, str);
}

// ---------------------------------------------------------------------
// Enums (grammar section 5.5)

pub fn newEnum(l: *Thread, desc: Value) Error!Value {
    _ = desc;
    return l.raiseMsg("enums are compiled to constants");
}

pub fn enumMember(l: *Thread, root: *object.EnumRoot, idx: usize) Error!*object.EnumValue {
    if (root.values[idx]) |v| return v;
    const v = gc.alloc(l.g, object.EnumValue, .enum_value, @sizeOf(object.EnumValue)) catch return l.raiseMem();
    v.root = root;
    v.index = @intCast(idx);
    root.values[idx] = v;
    gc.barrierBack(l.g, &root.hdr);
    return v;
}

fn enumIndex(l: *Thread) Error!u32 {
    const e = l.arg(1).as(object.EnumValue);
    const k = l.arg(2);
    const root = e.root;
    switch (k.tag) {
        .string => {
            const name = k.as(String);
            for (root.names, 0..) |n, i| {
                if (n == name) {
                    try l.push(Value.obj(.enum_value, try enumMember(l, root, i)));
                    return 1;
                }
            }
        },
        .integer, .float => {
            if (ops.toIntegerStrict(k)) |i| {
                if (i >= 1 and i <= root.names.len) {
                    try l.push(Value.obj(.enum_value, try enumMember(l, root, @intCast(i - 1))));
                    return 1;
                }
            }
        },
        else => {},
    }
    try l.push(.nil);
    return 1;
}

fn enumCompare(l: *Thread, or_equal: bool) Error!bool {
    const a = l.arg(1);
    const b = l.arg(2);
    if (a.tag != .enum_value or b.tag != .enum_value) return l.raiseFmt("attempt to compare {s} with {s}", .{ l.typeNameOf(a), l.typeNameOf(b) });
    const ea = a.as(object.EnumValue);
    const eb = b.as(object.EnumValue);
    if (ea.root != eb.root) return l.raiseFmt("attempt to compare members of different enums", .{});
    return if (or_equal) ea.index <= eb.index else ea.index < eb.index;
}

fn enumLt(l: *Thread) Error!u32 {
    try l.push(Value.boolean(try enumCompare(l, false)));
    return 1;
}

fn enumLe(l: *Thread) Error!u32 {
    try l.push(Value.boolean(try enumCompare(l, true)));
    return 1;
}

fn enumToString(l: *Thread) Error!u32 {
    const e = l.arg(1).as(object.EnumValue);
    try l.push(Value.obj(.string, e.root.names[e.index]));
    return 1;
}

/// Installs the metatable shared by every enum member.
pub fn openEnums(l: *Thread) Error!void {
    const aux = @import("../lib/auxlib.zig");
    const mt = try l.newTable(0, 5);
    try aux.setField(l, mt, "__index", try aux.native(l, enumIndex, "enum_index"));
    try aux.setField(l, mt, "__lt", try aux.native(l, enumLt, "enum_lt"));
    try aux.setField(l, mt, "__le", try aux.native(l, enumLe, "enum_le"));
    try aux.setField(l, mt, "__name", try l.newStringValue("enum"));
    l.g.type_metatables[@backingInt(value.Tag.enum_value)] = mt;
}

// ---------------------------------------------------------------------
// Queries

pub fn newQuery(l: *Thread, plan: Value, sources: u32) Error!Value {
    return @import("query.zig").build(l, plan, sources);
}

/// Registers the `query` global and `debug.queryplan`.
pub fn openQueries(l: *Thread) Error!void {
    return @import("query.zig").open(l);
}
