//! The Lus value representation: a 16-byte tagged struct. Integers and
//! floats live inline. Every heap object starts with a `gc.Header`.

const std = @import("std");
const gc = @import("gc.zig");

pub const Tag = enum(u8) {
    nil,
    false,
    true,
    integer,
    float,
    /// A raw pointer owned by the host. Compares by address.
    light,
    // Collectable tags. Everything at or after `string` points to a
    // `gc.Header`.
    string,
    table,
    closure,
    native,
    userdata,
    thread,
    bigint,
    decimal,
    vector,
    enum_value,
    enum_root,
    query,
    // Internal objects that never appear in a Value.
    proto,
    upvalue,

    pub inline fn isCollectable(t: Tag) bool {
        return @intFromEnum(t) >= @intFromEnum(Tag.string);
    }
};

pub const Value = extern struct {
    payload: u64 = 0,
    tag: Tag = .nil,
    /// Per-value auxiliary bits. Unused by most tags.
    aux: u8 = 0,
    _pad: [6]u8 = @splat(0),

    pub const nil: Value = .{};
    pub const @"true": Value = .{ .tag = .true };
    pub const @"false": Value = .{ .tag = .false };

    pub inline fn int(v: i64) Value {
        return .{ .payload = @bitCast(v), .tag = .integer };
    }
    pub inline fn float(v: f64) Value {
        return .{ .payload = @bitCast(v), .tag = .float };
    }
    pub inline fn boolean(b: bool) Value {
        return .{ .tag = if (b) .true else .false };
    }
    pub inline fn light(p: ?*anyopaque) Value {
        return .{ .payload = @intFromPtr(p), .tag = .light };
    }
    pub inline fn obj(tag: Tag, p: anytype) Value {
        return .{ .payload = @intFromPtr(p), .tag = tag };
    }

    pub inline fn isNil(v: Value) bool {
        return v.tag == .nil;
    }
    /// Lua truthiness: only nil and false are false.
    pub inline fn truthy(v: Value) bool {
        return @intFromEnum(v.tag) > @intFromEnum(Tag.false);
    }
    pub inline fn asInt(v: Value) i64 {
        return @bitCast(v.payload);
    }
    pub inline fn asFloat(v: Value) f64 {
        return @bitCast(v.payload);
    }
    pub inline fn isNumber(v: Value) bool {
        return switch (v.tag) {
            .integer, .float, .bigint, .decimal => true,
            else => false,
        };
    }
    pub inline fn header(v: Value) *gc.Header {
        return @ptrFromInt(v.payload);
    }
    pub inline fn as(v: Value, comptime T: type) *T {
        return @ptrFromInt(v.payload);
    }
    pub inline fn raw(v: Value) u64 {
        return v.payload;
    }

    /// Raw identity equality: same tag and same payload. Floats compare by
    /// value so that NaN is unequal to itself. Callers that need numeric
    /// equality across subtypes use `ops.rawEqual`.
    pub inline fn identical(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        if (a.tag == .float) return a.asFloat() == b.asFloat();
        if (a.tag == .nil or a.tag == .true or a.tag == .false) return true;
        return a.payload == b.payload;
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
}

/// Index into the per-type metatable array. Values of one Lus type share
/// a metatable whatever their internal tag (every number, both booleans,
/// every function).
pub fn typeSlot(tag: Tag) usize {
    return @intFromEnum(switch (tag) {
        .integer, .float, .bigint, .decimal => Tag.integer,
        .true, .false => Tag.false,
        .closure, .native => Tag.closure,
        .enum_value, .enum_root => Tag.enum_value,
        else => tag,
    });
}

pub fn typeName(tag: Tag) []const u8 {
    return switch (tag) {
        .nil => "nil",
        .false, .true => "boolean",
        .integer, .float, .bigint, .decimal => "number",
        .light, .userdata => "userdata",
        .string => "string",
        .table => "table",
        .closure, .native => "function",
        .thread => "thread",
        .vector => "vector",
        .enum_value, .enum_root => "enum",
        .query => "query",
        .proto => "proto",
        .upvalue => "upvalue",
    };
}
