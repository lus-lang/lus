//! Enums (grammar section 5.5): the members of an enum and the metatable
//! that they share.

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
    // A script reaches this native through the metatable and calls it
    // with any value.
    if (l.arg(1).tag != .enum_value) return l.raiseFmt("bad argument #1 (enum expected, got {s})", .{l.typeNameOf(l.arg(1))});
    const e = l.arg(1).as(object.EnumValue);
    const k = l.arg(2);
    const root = e.root;
    switch (k.tag) {
        .string => {
            const name = k.as(String);
            for (root.names, 0..) |n, i| {
                if (n == name or (n.len == name.len and n.hash == name.hash and std.mem.eql(u8, n.bytes(), name.bytes()))) {
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
    if (l.arg(1).tag != .enum_value) return l.raiseFmt("bad argument #1 (enum expected, got {s})", .{l.typeNameOf(l.arg(1))});
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
    aux.freeze(mt);
    l.g.type_metatables[@backingInt(value.Tag.enum_value)] = mt;
}
