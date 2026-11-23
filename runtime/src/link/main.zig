//! `lus-link LINKOBJECT OUT [MAP]`: links a link object with every
//! builtin, for testing the linker apart from `lus build --aot`, and
//! writes the map of the kept atoms with their addresses to MAP.

const std = @import("std");
const lobj = @import("lobj.zig");
const link = @import("link.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    while (it.next()) |a| try args.append(gpa, a);
    if (args.items.len != 3 and args.items.len != 4) {
        std.log.err("usage: lus-link LINKOBJECT OUT [MAP]", .{});
        return error.Usage;
    }
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAllocOptions(io, args.items[1], gpa, .unlimited, .@"8", null);
    defer gpa.free(data);
    const o = try lobj.read(data);
    var map_buf: [4096]u8 = undefined;
    var map_file: ?std.Io.File = null;
    defer if (map_file) |f| f.close(io);
    var map_writer: ?std.Io.File.Writer = null;
    if (args.items.len == 4) {
        map_file = try cwd.createFile(io, args.items[3], .{});
        map_writer = map_file.?.writer(io, &map_buf);
    }
    const r = try link.link(gpa, &o, .all, .{ .map = if (map_writer) |*mw| &mw.interface else null });
    defer gpa.free(r.bytes);
    const f = try cwd.createFile(io, args.items[2], .{ .permissions = .executable_file });
    defer f.close(io);
    try f.writeStreamingAll(io, r.bytes);
    std.debug.print("kept {d} of {d} bytes of atoms, wrote {d} bytes\n", .{ r.kept, r.total, r.bytes.len });
}
