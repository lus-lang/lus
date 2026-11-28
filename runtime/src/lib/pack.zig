//! Binary packing with Lua 5.4 `string.pack` format strings. This is the
//! single implementation behind `string.pack`, `string.unpack`,
//! `string.packsize`, `vector.pack`, `vector.unpack`, and
//! `vector.unpackmany`. Packed data always lives in vectors.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;

/// The size of a C long: four bytes on Windows and eight elsewhere.
const c_long_size: usize = if (@import("builtin").os.tag == .windows) 4 else 8;
const String = object.String;

const max_int_size = 16;
const native_align = @alignOf(f64);

const Kind = enum { int, uint, float, double, number, char, string, zstr, padding, paddalign, nop };

const Item = struct {
    kind: Kind,
    size: usize,
    ntoalign: usize = 0,
};

pub const Parser = struct {
    fmt: []const u8,
    pos: usize = 0,
    little: bool = true,
    maxalign: usize = 1,
    l: *Thread,
    argi: u32,
    /// Set while the option after an `X` is read.
    in_padding: bool = false,

    fn digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn getNum(p: *Parser, default: usize) usize {
        if (p.pos >= p.fmt.len or !digit(p.fmt[p.pos])) return default;
        var a: usize = 0;
        while (p.pos < p.fmt.len and digit(p.fmt[p.pos]) and a < (std.math.maxInt(usize) - 9) / 10) : (p.pos += 1) {
            a = a * 10 + (p.fmt[p.pos] - '0');
        }
        return a;
    }

    fn getNumLimit(p: *Parser, default: usize) Error!usize {
        const sz = p.getNum(default);
        if (sz > max_int_size or sz <= 0) {
            return p.l.raiseFmt("integral size ({d}) out of limits [1,{d}]", .{ sz, max_int_size });
        }
        return sz;
    }

    /// Reads the next option. Returns null at the end of the format.
    pub fn next(p: *Parser, total: usize) Error!?Item {
        while (p.pos < p.fmt.len) {
            const opt = p.fmt[p.pos];
            p.pos += 1;
            var it: Item = .{ .kind = .nop, .size = 0 };
            switch (opt) {
                'b' => it = .{ .kind = .int, .size = 1 },
                'B' => it = .{ .kind = .uint, .size = 1 },
                'h' => it = .{ .kind = .int, .size = 2 },
                'H' => it = .{ .kind = .uint, .size = 2 },
                'l' => it = .{ .kind = .int, .size = c_long_size },
                'L' => it = .{ .kind = .uint, .size = c_long_size },
                'j' => it = .{ .kind = .int, .size = 8 },
                'J', 'T' => it = .{ .kind = .uint, .size = 8 },
                'f' => it = .{ .kind = .float, .size = 4 },
                'n', 'd' => it = .{ .kind = if (opt == 'n') .number else .double, .size = 8 },
                'i' => it = .{ .kind = .int, .size = try p.getNumLimit(4) },
                'I' => it = .{ .kind = .uint, .size = try p.getNumLimit(4) },
                's' => it = .{ .kind = .string, .size = try p.getNumLimit(8) },
                'c' => {
                    const save = p.pos;
                    const n = p.getNum(std.math.maxInt(usize));
                    if (n == std.math.maxInt(usize) or save == p.pos) return p.l.raiseFmt("missing size for format option 'c'", .{});
                    it = .{ .kind = .char, .size = n };
                },
                'z' => it = .{ .kind = .zstr, .size = 0 },
                'x' => it = .{ .kind = .padding, .size = 1 },
                'X' => it = .{ .kind = .paddalign, .size = 0 },
                ' ' => continue,
                '<' => {
                    p.little = true;
                    continue;
                },
                '>' => {
                    p.little = false;
                    continue;
                },
                '=' => {
                    p.little = @import("builtin").cpu.arch.endian() == .little;
                    continue;
                },
                '!' => {
                    p.maxalign = try p.getNumLimit(native_align);
                    continue;
                },
                else => return p.l.raiseFmt("invalid format option '{c}'", .{opt}),
            }
            // Alignment.
            var alignment = it.size;
            if (it.kind == .paddalign) {
                if (p.pos >= p.fmt.len) return p.l.raiseFmt("invalid next option for option 'X'", .{});
                // The option after `X` only gives its size, and another `X`
                // has none, so the options never nest.
                if (p.in_padding) return p.l.raiseFmt("invalid next option for option 'X'", .{});
                p.in_padding = true;
                defer p.in_padding = false;
                const nx = (try p.next(0)) orelse return p.l.raiseFmt("invalid next option for option 'X'", .{});
                alignment = nx.size;
                if (alignment == 0 or nx.kind == .char) return p.l.raiseFmt("invalid next option for option 'X'", .{});
                // Rewind is not needed: Lua consumes the option after X
                // only to read its size. Recreate the behavior by keeping
                // the consumed option skipped, matching luaL semantics.
            }
            if (alignment <= 1 or it.kind == .char or it.kind == .string or it.kind == .zstr or it.kind == .padding) {
                it.ntoalign = 0;
            } else {
                if (alignment > p.maxalign) alignment = p.maxalign;
                if (alignment & (alignment - 1) != 0) return p.l.raiseFmt("format asks for alignment not power of 2", .{});
                it.ntoalign = (alignment - (total & (alignment - 1))) & (alignment - 1);
            }
            return it;
        }
        return null;
    }
};

fn putInt(buf: []u8, v: u64, nbytes: usize, little: bool, neg: bool) void {
    var x = v;
    var i: usize = 0;
    while (i < nbytes) : (i += 1) {
        const byte: u8 = if (i < 8) @truncate(x) else if (neg) 0xFF else 0;
        if (little) buf[i] = byte else buf[nbytes - 1 - i] = byte;
        if (i < 8) x >>= 8;
    }
}

fn getInt(l: *Thread, buf: []const u8, little: bool, nbytes: usize, signed: bool) Error!i64 {
    var res: u64 = 0;
    const limit = @min(nbytes, 8);
    var i: usize = limit;
    while (i > 0) {
        i -= 1;
        const byte = if (little) buf[i] else buf[nbytes - 1 - i];
        res = (res << 8) | byte;
    }
    if (nbytes < 8) {
        if (signed) {
            const mask = @as(u64, 1) << @intCast(nbytes * 8 - 1);
            res = (res ^ mask) -% mask;
        }
    } else if (nbytes > 8) {
        // Bytes above 64 bits must be sign or zero extension.
        const mask: u8 = if (!signed or @as(i64, @bitCast(res)) >= 0) 0 else 0xFF;
        var j: usize = limit;
        while (j < nbytes) : (j += 1) {
            const byte = if (little) buf[j] else buf[nbytes - 1 - j];
            if (byte != mask) return l.raiseFmt("{d}-byte integer does not fit into Lua Integer", .{nbytes});
        }
    }
    return @bitCast(res);
}

/// Packs arguments starting at `first_arg` according to `fmt`, appending
/// to `out`.
pub fn pack(l: *Thread, fmt: []const u8, first_arg: u32, out: *std.ArrayList(u8)) Error!void {
    const gpa = l.g.gpa;
    var p: Parser = .{ .fmt = fmt, .l = l, .argi = first_arg };
    var arg = first_arg;
    var total: usize = 0;
    while (try p.next(total)) |it| {
        out.appendNTimes(gpa, 0, it.ntoalign) catch return l.raiseMem();
        total += it.ntoalign;
        switch (it.kind) {
            .int, .uint => {
                const v = try aux.checkInt(l, arg);
                if (it.size < 8) {
                    const lim: i64 = @as(i64, 1) << @intCast(it.size * 8 - 1);
                    if (it.kind == .int) {
                        if (!(-lim <= v and v < lim)) return aux.argError(l, arg, "integer overflow", .{});
                    } else {
                        if (!(@as(u64, @bitCast(v)) < @as(u64, @intCast(lim)) * 2)) return aux.argError(l, arg, "unsigned overflow", .{});
                    }
                }
                var tmp: [max_int_size]u8 = undefined;
                putInt(tmp[0..it.size], @bitCast(v), it.size, p.little, v < 0);
                out.appendSlice(gpa, tmp[0..it.size]) catch return l.raiseMem();
                arg += 1;
            },
            .float, .double, .number => {
                const f = try aux.checkFloat(l, arg);
                var tmp: [8]u8 = undefined;
                if (it.kind == .float) {
                    const bits: u32 = @bitCast(@as(f32, @floatCast(f)));
                    putInt(tmp[0..4], bits, 4, p.little, false);
                } else {
                    putInt(tmp[0..8], @bitCast(f), 8, p.little, false);
                }
                out.appendSlice(gpa, tmp[0..it.size]) catch return l.raiseMem();
                arg += 1;
            },
            .char => {
                const s = try argBytes(l, arg);
                if (s.len > it.size) return aux.argError(l, arg, "string longer than given size", .{});
                out.appendSlice(gpa, s) catch return l.raiseMem();
                out.appendNTimes(gpa, 0, it.size - s.len) catch return l.raiseMem();
                arg += 1;
            },
            .string => {
                const s = try argBytes(l, arg);
                if (it.size < 8 and @as(u64, s.len) >= @as(u64, 1) << @intCast(it.size * 8)) return aux.argError(l, arg, "string length does not fit in given size", .{});
                var tmp: [max_int_size]u8 = undefined;
                putInt(tmp[0..it.size], s.len, it.size, p.little, false);
                out.appendSlice(gpa, tmp[0..it.size]) catch return l.raiseMem();
                out.appendSlice(gpa, s) catch return l.raiseMem();
                total += s.len;
                arg += 1;
            },
            .zstr => {
                const s = try argBytes(l, arg);
                if (std.mem.indexOfScalar(u8, s, 0) != null) return aux.argError(l, arg, "string contains zeros", .{});
                out.appendSlice(gpa, s) catch return l.raiseMem();
                out.append(gpa, 0) catch return l.raiseMem();
                total += s.len + 1;
                arg += 1;
            },
            .padding => out.append(gpa, 0) catch return l.raiseMem(),
            .paddalign, .nop => {},
        }
        total += it.size;
    }
}

/// String or vector bytes for an argument.
fn argBytes(l: *Thread, i: u32) Error![]const u8 {
    const v = l.arg(i);
    if (v.tag == .vector) return v.as(object.Vector).bytes.items;
    return aux.checkBytes(l, i);
}

pub fn size(l: *Thread, fmt: []const u8) Error!usize {
    var p: Parser = .{ .fmt = fmt, .l = l, .argi = 0 };
    var total: usize = 0;
    while (try p.next(total)) |it| {
        if (it.kind == .string or it.kind == .zstr) return aux.argError(l, 1, "variable-length format", .{});
        total = std.math.add(usize, total, std.math.add(usize, it.ntoalign, it.size) catch std.math.maxInt(usize)) catch
            return aux.argError(l, 1, "format result too large", .{});
        if (total > std.math.maxInt(i64)) return aux.argError(l, 1, "format result too large", .{});
    }
    return total;
}

/// The error messages of `unpack`, which differ between `string.unpack`
/// and the vector library.
pub const Msgs = struct {
    short: []const u8,
    zterm: []const u8,
};

pub const string_msgs: Msgs = .{ .short = "data string too short", .zterm = "unfinished string for format 'z'" };
pub const vector_msgs: Msgs = .{ .short = "data too short", .zterm = "unfinished string in vector" };

/// Unpacks values from `data` at byte offset `start`, pushing them.
/// Returns the number of values pushed and the offset after the data.
pub fn unpack(l: *Thread, fmt: []const u8, data: []const u8, start: usize, msgs: Msgs) Error!struct { u32, usize } {
    var p: Parser = .{ .fmt = fmt, .l = l, .argi = 0 };
    var pos = start;
    var n: u32 = 0;
    while (try p.next(pos)) |it| {
        if (it.ntoalign + it.size > data.len -| pos and it.kind != .zstr and it.kind != .nop and it.kind != .paddalign) {
            return aux.argError(l, 2, "{s}", .{msgs.short});
        }
        // Padding alone never moves the position past the data.
        if (it.ntoalign > data.len -| pos) return aux.argError(l, 2, "{s}", .{msgs.short});
        pos += it.ntoalign;
        switch (it.kind) {
            .int, .uint => {
                const v = try getInt(l, data[pos .. pos + it.size], p.little, it.size, it.kind == .int);
                try l.push(Value.int(v));
                n += 1;
            },
            .float => {
                const bits: u32 = @intCast(@as(u64, @bitCast(try getInt(l, data[pos .. pos + 4], p.little, 4, false))) & 0xFFFFFFFF);
                try l.push(Value.float(@as(f32, @bitCast(bits))));
                n += 1;
            },
            .double, .number => {
                const bits: u64 = @bitCast(try getInt(l, data[pos .. pos + 8], p.little, 8, false));
                try l.push(Value.float(@bitCast(bits)));
                n += 1;
            },
            .char => {
                try l.push(try bytesValue(l, data[pos .. pos + it.size]));
                n += 1;
            },
            .string => {
                const len = std.math.cast(usize, @as(u64, @bitCast(try getInt(l, data[pos .. pos + it.size], p.little, it.size, false)))) orelse return aux.argError(l, 2, "{s}", .{msgs.short});
                if (len > data.len - pos - it.size) return aux.argError(l, 2, "{s}", .{msgs.short});
                try l.push(try bytesValue(l, data[pos + it.size .. pos + it.size + len]));
                pos += len;
                n += 1;
            },
            .zstr => {
                const end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse return aux.argError(l, 2, "{s}", .{msgs.zterm});
                try l.push(try bytesValue(l, data[pos..end]));
                pos = end + 1 - it.size;
                n += 1;
            },
            .padding, .paddalign, .nop => {},
        }
        pos += it.size;
    }
    return .{ n, pos };
}

/// Unpacked byte strings become strings when they hold valid text and
/// vectors otherwise.
fn bytesValue(l: *Thread, b: []const u8) Error!Value {
    if (@import("../vm/wtf8.zig").analyze(b).valid) return l.newStringValue(b);
    return Value.obj(.vector, try @import("vector.zig").newVector(l, b));
}
