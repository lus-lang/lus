//! Standalone bundles made by `lus build`. A bundle is a copy of the
//! `lus` executable followed by a payload and a fixed trailer:
//!
//!   program | module data ... | index | trailer
//!
//! The index lists the preserved command line options, the entry module,
//! and every module with its chunk name and the offset and size of its
//! data in the payload. Module data are binary chunks from
//! `compile/dump.zig`. The trailer is 24 bytes at the very end of the
//! file: the payload length and the index length as little endian u64,
//! then the magic `LUSBNDL` followed by the format version byte.
//!
//! At startup the CLI reads its own trailer. A file without the magic is
//! a plain interpreter. On macOS and iOS the payload with its trailer is
//! the section `__LUS,__bundle` of the executable, inside what its code
//! signature covers, and the CLI finds it in its own image.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Whether the payload is a section of the executable.
pub const in_section = builtin.os.tag.isDarwin();

pub const magic = "LUSBNDL";
pub const version: u8 = 1;
pub const trailer_len = 24;

pub const Module = struct {
    /// Dotted module name, the key `require` looks up.
    name: []const u8,
    /// Chunk name used in messages, such as "@lib/util.lus".
    chunkname: []const u8,
    /// A binary chunk.
    data: []const u8,
};

/// A loaded bundle. Every slice points into `bytes`.
pub const Bundle = struct {
    bytes: []u8,
    /// Preserved command line options, as `-P spec` and `-F spec` pairs
    /// flattened into one list.
    args: []const []const u8,
    modules: []const Module,
    entry: usize,

    pub fn find(b: *const Bundle, name: []const u8) ?Module {
        for (b.modules) |m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    pub fn entryModule(b: *const Bundle) Module {
        return b.modules[b.entry];
    }

    pub fn deinit(b: *Bundle, gpa: Allocator) void {
        gpa.free(b.args);
        gpa.free(b.modules);
        gpa.free(b.bytes);
    }
};

pub const Trailer = struct {
    payload_len: u64,
    index_len: u64,
};

/// Reads the trailer of `file`, or returns null when it carries none.
pub fn readTrailer(io: std.Io, file: std.Io.File, file_len: u64) !?Trailer {
    if (file_len < trailer_len) return null;
    var t: [trailer_len]u8 = undefined;
    const n = try file.readPositionalAll(io, &t, file_len - trailer_len);
    if (n != trailer_len) return null;
    return decodeTrailer(&t, file_len);
}

/// The trailer `t` at the end of `file_len` bytes, or null when it is not
/// one.
fn decodeTrailer(t: *const [trailer_len]u8, file_len: u64) !?Trailer {
    if (!std.mem.eql(u8, t[16..23], magic) or t[23] != version) return null;
    const tr: Trailer = .{
        .payload_len = std.mem.readInt(u64, t[0..8], .little),
        .index_len = std.mem.readInt(u64, t[8..16], .little),
    };
    if (tr.index_len > tr.payload_len or tr.payload_len > file_len - trailer_len) return error.Malformed;
    return tr;
}

/// The length of the program part of the running executable, without any
/// bundle it carries. `lus build` copies this part.
pub fn programLength(io: std.Io, file: std.Io.File) !u64 {
    const len = try file.length(io);
    const tr = (try readTrailer(io, file, len)) orelse return len;
    return len - trailer_len - tr.payload_len;
}

extern "c" fn getsectiondata(mhp: *const anyopaque, segname: [*:0]const u8, sectname: [*:0]const u8, size: *c_ulong) ?[*]u8;
/// The header of image `i`, where image 0 is the main executable.
extern "c" fn _dyld_get_image_header(i: u32) ?*const anyopaque;

/// Loads the bundle that `data` holds, a payload followed by its trailer.
pub fn fromMemory(gpa: Allocator, data: []const u8) !?Bundle {
    if (data.len < trailer_len) return null;
    const tr = (try decodeTrailer(data[data.len - trailer_len ..][0..trailer_len], data.len)) orelse return null;
    const start = data.len - trailer_len - @as(usize, @intCast(tr.payload_len));
    const bytes = try gpa.dupe(u8, data[start .. data.len - trailer_len]);
    errdefer gpa.free(bytes);
    return try parse(gpa, bytes, @intCast(tr.index_len));
}

/// Loads the bundle of the running executable, or returns null for a
/// plain interpreter.
pub fn loadSelf(io: std.Io, gpa: Allocator) !?Bundle {
    if (comptime in_section and builtin.link_libc) {
        var size: c_ulong = 0;
        const header = _dyld_get_image_header(0) orelse return null;
        if (getsectiondata(header, "__LUS", "__bundle", &size)) |p| return fromMemory(gpa, p[0..size]);
    }
    const file = std.process.openExecutable(io, .{}) catch return null;
    defer file.close(io);
    const len = file.length(io) catch return null;
    const tr = (try readTrailer(io, file, len)) orelse return null;
    const bytes = try gpa.alloc(u8, @intCast(tr.payload_len));
    errdefer gpa.free(bytes);
    const n = try file.readPositionalAll(io, bytes, len - trailer_len - tr.payload_len);
    if (n != bytes.len) return error.Malformed;
    return try parse(gpa, bytes, @intCast(tr.index_len));
}

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn int(r: *Reader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (r.buf.len - r.pos < n) return error.Malformed;
        const v = std.mem.readInt(T, r.buf[r.pos..][0..n], .little);
        r.pos += n;
        return v;
    }

    fn str(r: *Reader) ![]const u8 {
        const n = try r.int(u32);
        if (r.buf.len - r.pos < n) return error.Malformed;
        const s = r.buf[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }
};

/// Parses a payload whose last `index_len` bytes are the index. Takes
/// ownership of `bytes`.
fn parse(gpa: Allocator, bytes: []u8, index_len: usize) !Bundle {
    const data_len = bytes.len - index_len;
    var r: Reader = .{ .buf = bytes[data_len..] };
    const nargs = try r.int(u32);
    if (nargs > r.buf.len) return error.Malformed;
    const args = try gpa.alloc([]const u8, nargs);
    errdefer gpa.free(args);
    for (args) |*a| a.* = try r.str();
    const entry = try r.int(u32);
    const nmods = try r.int(u32);
    if (nmods == 0 or entry >= nmods or nmods > r.buf.len) return error.Malformed;
    const mods = try gpa.alloc(Module, nmods);
    errdefer gpa.free(mods);
    for (mods) |*m| {
        const name = try r.str();
        const chunkname = try r.str();
        const off = try r.int(u64);
        const size = try r.int(u64);
        if (off > data_len or size > data_len - off) return error.Malformed;
        m.* = .{ .name = name, .chunkname = chunkname, .data = bytes[@intCast(off)..][0..@intCast(size)] };
    }
    return .{ .bytes = bytes, .args = args, .modules = mods, .entry = entry };
}

/// Serializes a payload with its index and trailer into `out`.
pub fn write(gpa: Allocator, out: *std.ArrayList(u8), args: []const []const u8, modules: []const Module, entry: usize) !void {
    const start = out.items.len;
    var offsets = try gpa.alloc(u64, modules.len);
    defer gpa.free(offsets);
    for (modules, 0..) |m, i| {
        offsets[i] = out.items.len - start;
        try out.appendSlice(gpa, m.data);
    }
    const index_start = out.items.len;
    try putInt(gpa, out, u32, @intCast(args.len));
    for (args) |a| try putStr(gpa, out, a);
    try putInt(gpa, out, u32, @intCast(entry));
    try putInt(gpa, out, u32, @intCast(modules.len));
    for (modules, 0..) |m, i| {
        try putStr(gpa, out, m.name);
        try putStr(gpa, out, m.chunkname);
        try putInt(gpa, out, u64, offsets[i]);
        try putInt(gpa, out, u64, m.data.len);
    }
    const index_len = out.items.len - index_start;
    try putInt(gpa, out, u64, out.items.len - start);
    try putInt(gpa, out, u64, index_len);
    try out.appendSlice(gpa, magic);
    try out.append(gpa, version);
}

fn putInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn putStr(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try putInt(gpa, out, u32, @intCast(s.len));
    try out.appendSlice(gpa, s);
}

test "round trip" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "PROGRAM");
    const mods = [_]Module{
        .{ .name = "main", .chunkname = "@main.lus", .data = "chunk one" },
        .{ .name = "lib.util", .chunkname = "@lib/util.lus", .data = "two" },
    };
    try write(gpa, &out, &.{ "-P", "fs:read" }, &mods, 0);
    const t = out.items[out.items.len - trailer_len ..];
    try std.testing.expectEqualStrings(magic, t[16..23]);
    const payload_len = std.mem.readInt(u64, t[0..8], .little);
    const index_len = std.mem.readInt(u64, t[8..16], .little);
    try std.testing.expectEqual(@as(u64, out.items.len - 7 - trailer_len), payload_len);
    const bytes = try gpa.dupe(u8, out.items[7 .. out.items.len - trailer_len]);
    var b = try parse(gpa, bytes, @intCast(index_len));
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), b.modules.len);
    try std.testing.expectEqualStrings("two", b.find("lib.util").?.data);
    try std.testing.expectEqualStrings("fs:read", b.args[1]);
    try std.testing.expectEqualStrings("@main.lus", b.entryModule().chunkname);
}
