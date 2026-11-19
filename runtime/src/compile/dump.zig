//! Binary chunks: `string.dump` serializes a function prototype and
//! `load` reads it back.
//!
//! The format is private to one runtime version. It starts with the
//! signature "\x1bLus", a format version byte and a check of the
//! instruction and number sizes. Each prototype then writes its scalar
//! fields, code, constants, upvalue descriptors, nested prototypes,
//! exception table and (unless stripped) its debug information.
//! Integers are little endian. Lengths are unsigned LEB128.

const std = @import("std");
const vm = struct {
    const value = @import("../vm/value.zig");
    const object = @import("../vm/object.zig");
    const state = @import("../vm/state.zig");
    const gc = @import("../vm/gc.zig");
    const numeric = @import("../vm/numeric.zig");
};
const object = vm.object;
const Value = vm.value.Value;
const Global = vm.state.Global;
const Proto = object.Proto;
const String = object.String;
const Allocator = std.mem.Allocator;

pub const signature = "\x1bLus";
/// Bumped whenever the instruction set changes. Version 2 added the
/// immediate comparisons.
const format_version: u8 = 2;

const ConstTag = enum(u8) { nil, false, true, integer, float, string, bigint, decimal, enumeration };

pub const DumpError = Allocator.Error || error{Unsupported};

/// Serializes `p` and everything it contains.
pub fn dump(gpa: Allocator, p: *Proto, strip: bool) DumpError![]u8 {
    var w: Writer = .{ .gpa = gpa, .strip = strip };
    errdefer w.buf.deinit(gpa);
    try w.bytes(signature);
    try w.byte(format_version);
    try w.byte(@sizeOf(u32));
    try w.byte(@sizeOf(i64));
    try w.byte(@sizeOf(f64));
    try w.proto(p);
    return w.buf.toOwnedSlice(gpa);
}

pub fn isBinary(src: []const u8) bool {
    return std.mem.startsWith(u8, src, signature);
}

const Writer = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    strip: bool,

    fn byte(w: *Writer, b: u8) !void {
        try w.buf.append(w.gpa, b);
    }
    fn bytes(w: *Writer, b: []const u8) !void {
        try w.buf.appendSlice(w.gpa, b);
    }
    fn uint(w: *Writer, v: u64) !void {
        var x = v;
        while (true) {
            const b: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x == 0) return w.byte(b);
            try w.byte(b | 0x80);
        }
    }
    fn fixed(w: *Writer, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(@Int(.unsigned, @bitSizeOf(T)), &tmp, @bitCast(v), .little);
        try w.bytes(&tmp);
    }
    fn str(w: *Writer, s: ?*String) !void {
        const v = s orelse return w.uint(0);
        try w.uint(v.len + 1);
        try w.bytes(v.bytes());
    }
    fn text(w: *Writer, s: []const u8) !void {
        try w.uint(s.len);
        try w.bytes(s);
    }

    fn proto(w: *Writer, p: *Proto) DumpError!void {
        try w.str(if (w.strip) null else p.source);
        try w.str(if (w.strip) null else p.name);
        try w.uint(p.line_defined);
        try w.uint(p.last_line_defined);
        try w.byte(p.num_params);
        try w.byte(@intFromBool(p.is_vararg));
        try w.byte(p.max_stack);
        try w.uint(p.code.len);
        for (p.code) |ins| try w.fixed(u32, ins);
        try w.uint(p.constants.len);
        for (p.constants) |k| try w.constant(k);
        try w.uint(p.upvals.len);
        for (p.upvals) |u| {
            try w.byte(@intFromBool(u.in_stack));
            try w.byte(u.index);
            try w.byte(@intFromBool(u.by_value));
            try w.str(if (w.strip) null else u.name);
        }
        try w.uint(p.protos.len);
        for (p.protos) |q| try w.proto(q);
        try w.uint(p.handlers.len);
        for (p.handlers) |h| {
            try w.uint(h.start_pc);
            try w.uint(h.end_pc);
            try w.uint(h.handler_pc);
            try w.byte(h.level);
            try w.byte(h.dest);
        }
        // Debug information.
        const lines: []const u32 = if (w.strip) &.{} else p.lines;
        try w.uint(lines.len);
        var prev: i64 = 0;
        for (lines) |ln| {
            // Lines change slowly, so store zigzag-encoded deltas.
            const d: i64 = @as(i64, ln) - prev;
            prev = ln;
            try w.uint(@bitCast((d << 1) ^ (d >> 63)));
        }
        const locvars: []const object.LocVar = if (w.strip) &.{} else p.locvars;
        try w.uint(locvars.len);
        for (locvars) |lv| {
            try w.str(lv.name);
            try w.uint(lv.start_pc);
            try w.uint(lv.end_pc);
            try w.byte(lv.reg);
        }
    }

    fn constant(w: *Writer, k: Value) DumpError!void {
        switch (k.tag) {
            .nil => try w.byte(@backingInt(ConstTag.nil)),
            .false => try w.byte(@backingInt(ConstTag.false)),
            .true => try w.byte(@backingInt(ConstTag.true)),
            .integer => {
                try w.byte(@backingInt(ConstTag.integer));
                try w.fixed(i64, k.asInt());
            },
            .float => {
                try w.byte(@backingInt(ConstTag.float));
                try w.fixed(f64, k.asFloat());
            },
            .string => {
                try w.byte(@backingInt(ConstTag.string));
                try w.str(k.as(String));
            },
            .bigint => {
                try w.byte(@backingInt(ConstTag.bigint));
                const s = vm.numeric.bigToString(w.gpa, k.as(vm.numeric.BigInt)) catch return error.OutOfMemory;
                defer w.gpa.free(s);
                try w.text(s);
            },
            .decimal => {
                try w.byte(@backingInt(ConstTag.decimal));
                const s = vm.numeric.decimalToString(w.gpa, k.as(vm.numeric.Decimal)) catch return error.OutOfMemory;
                defer w.gpa.free(s);
                try w.text(s);
            },
            .enum_value => {
                // An enum literal: its member names, loaded as a fresh enum.
                const e = k.as(object.EnumValue);
                try w.byte(@backingInt(ConstTag.enumeration));
                try w.uint(e.index);
                try w.uint(e.root.names.len);
                for (e.root.names) |n| try w.str(n);
            },
            else => return error.Unsupported,
        }
    }
};

pub const UndumpError = Allocator.Error || error{Malformed};

/// Reads a binary chunk produced by `dump`. Collection must be stopped by
/// the caller while the prototypes are built. `chunkname` names stripped
/// chunks.
pub fn undump(g: *Global, src: []const u8, chunkname: []const u8) UndumpError!*Proto {
    var r: Reader = .{ .g = g, .src = src };
    if (!isBinary(src)) return error.Malformed;
    r.pos = signature.len;
    if (try r.byte() != format_version) return error.Malformed;
    if (try r.byte() != @sizeOf(u32) or try r.byte() != @sizeOf(i64) or try r.byte() != @sizeOf(f64)) return error.Malformed;
    r.default_source = vm.state.newStringIn(g, chunkname) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return error.Malformed,
    };
    const p = try r.proto();
    if (r.pos != src.len) return error.Malformed;
    return p;
}

const Reader = struct {
    g: *Global,
    src: []const u8,
    pos: usize = 0,
    default_source: ?*String = null,

    fn byte(r: *Reader) !u8 {
        if (r.pos >= r.src.len) return error.Malformed;
        r.pos += 1;
        return r.src[r.pos - 1];
    }
    fn take(r: *Reader, n: usize) ![]const u8 {
        if (n > r.src.len - r.pos) return error.Malformed;
        r.pos += n;
        return r.src[r.pos - n .. r.pos];
    }
    fn uint(r: *Reader) !u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            if (shift >= 64) return error.Malformed;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
        }
    }
    fn len(r: *Reader) !usize {
        const n = try r.uint();
        if (n > r.src.len) return error.Malformed;
        return @intCast(n);
    }
    fn fixed(r: *Reader, comptime T: type) !T {
        const b = try r.take(@sizeOf(T));
        return @bitCast(std.mem.readInt(@Int(.unsigned, @bitSizeOf(T)), b[0..@sizeOf(T)], .little));
    }
    fn str(r: *Reader) UndumpError!?*String {
        const n = try r.len();
        if (n == 0) return null;
        const b = try r.take(n - 1);
        return vm.state.newStringIn(r.g, b) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return error.Malformed,
        };
    }

    fn proto(r: *Reader) UndumpError!*Proto {
        const g = r.g;
        const gpa = g.gpa;
        const p = try vm.gc.alloc(g, Proto, .proto, @sizeOf(Proto));
        p.* = .{ .hdr = p.hdr };
        p.source = (try r.str()) orelse r.default_source;
        p.name = try r.str();
        p.line_defined = @intCast(try r.uint());
        p.last_line_defined = @intCast(try r.uint());
        p.num_params = try r.byte();
        p.is_vararg = try r.byte() != 0;
        p.call.plain = !p.is_vararg;
        p.max_stack = try r.byte();
        const ncode = try r.len();
        p.code = try object.Proto.allocCode(gpa, ncode);
        for (p.code) |*ins| ins.* = try r.fixed(u32);
        try p.initIc(gpa);
        const nk = try r.len();
        p.constants = try gpa.alloc(Value, nk);
        p.link();
        @memset(p.constants, .nil);
        for (p.constants) |*k| k.* = try r.constant();
        const nup = try r.len();
        p.upvals = try gpa.alloc(object.UpvalDesc, nup);
        for (p.upvals) |*u| {
            u.* = .{ .in_stack = try r.byte() != 0, .index = try r.byte() };
            u.by_value = try r.byte() != 0;
            u.name = try r.str();
        }
        // Nested prototypes are collected objects of their own, so a
        // failure part way only has to free this list.
        const np = try r.len();
        const protos = try gpa.alloc(*Proto, np);
        var protos_owned = true;
        errdefer if (protos_owned) gpa.free(protos);
        for (protos) |*q| q.* = try r.proto();
        p.protos = protos;
        protos_owned = false;
        p.noteCloses();
        const nh = try r.len();
        p.handlers = try gpa.alloc(object.Handler, nh);
        for (p.handlers) |*h| h.* = .{
            .start_pc = @intCast(try r.uint()),
            .end_pc = @intCast(try r.uint()),
            .handler_pc = @intCast(try r.uint()),
            .level = try r.byte(),
            .dest = try r.byte(),
        };
        const nl = try r.len();
        p.lines = try gpa.alloc(u32, nl);
        var prev: i64 = 0;
        for (p.lines) |*ln| {
            const z = try r.uint();
            const d: i64 = @bitCast((z >> 1) ^ (0 -% (z & 1)));
            prev += d;
            ln.* = @intCast(std.math.clamp(prev, 0, std.math.maxInt(u32)));
        }
        const nlv = try r.len();
        p.locvars = try gpa.alloc(object.LocVar, nlv);
        for (p.locvars) |*lv| lv.* = .{
            .name = (try r.str()) orelse return error.Malformed,
            .start_pc = @intCast(try r.uint()),
            .end_pc = @intCast(try r.uint()),
            .reg = try r.byte(),
        };
        try verify(p);
        return p;
    }

    fn constant(r: *Reader) UndumpError!Value {
        const tag = std.enums.fromInt(ConstTag, try r.byte()) orelse return error.Malformed;
        const g = r.g;
        return switch (tag) {
            .nil => .nil,
            .false => .false,
            .true => .true,
            .integer => Value.int(try r.fixed(i64)),
            .float => Value.float(try r.fixed(f64)),
            .string => Value.obj(.string, (try r.str()) orelse return error.Malformed),
            .bigint => blk: {
                const s = try r.take(try r.len());
                const b = vm.numeric.parseBigLiteral(g, s) catch return error.Malformed;
                break :blk Value.obj(.bigint, b);
            },
            .decimal => blk: {
                const s = try r.take(try r.len());
                const d = vm.numeric.parseDecimalLiteral(g, s) catch return error.Malformed;
                break :blk Value.obj(.decimal, d);
            },
            .enumeration => blk: {
                const index = try r.len();
                const n = try r.len();
                if (n == 0 or index >= n) return error.Malformed;
                const root = try vm.gc.alloc(g, object.EnumRoot, .enum_root, @sizeOf(object.EnumRoot));
                root.names = try g.gpa.alloc(*String, n);
                root.values = try g.gpa.alloc(?*object.EnumValue, n);
                @memset(root.values, null);
                for (root.names) |*nm| nm.* = (try r.str()) orelse return error.Malformed;
                const v = try vm.gc.alloc(g, object.EnumValue, .enum_value, @sizeOf(object.EnumValue));
                v.root = root;
                v.index = @intCast(index);
                root.values[index] = v;
                break :blk Value.obj(.enum_value, v);
            },
        };
    }
};

/// Rejects structurally broken prototypes: unknown opcodes, jumps and
/// handlers outside the code, and constant or prototype operands outside
/// their tables. Binary chunks remain trusted input (see `load` mode "t"
/// for untrusted sources), so this guards against corruption, not against
/// a crafted chunk.
fn verify(p: *Proto) error{Malformed}!void {
    const opc = @import("opcodes.zig");
    if (p.code.len == 0) return error.Malformed;
    if (p.lines.len != 0 and p.lines.len != p.code.len) return error.Malformed;
    for (p.code) |ins| {
        const raw: u8 = @truncate(ins);
        if (std.enums.fromInt(opc.Op, raw) == null) return error.Malformed;
        switch (opc.op(ins)) {
            .loadk => if (opc.bx(ins) >= p.constants.len) return error.Malformed,
            .closure => if (opc.bx(ins) >= p.protos.len) return error.Malformed,
            else => {},
        }
    }
    for (p.handlers) |h| {
        if (h.start_pc > h.end_pc or h.end_pc > p.code.len or h.handler_pc >= p.code.len) return error.Malformed;
    }
}
