//! The `lus` command line interface.

const std = @import("std");
const lus = @import("lus");
const api = lus.api;
const out = lus.lib.out;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    while (it.next()) |a| try args_list.append(gpa, a);
    const args = args_list.items;

    const l = try api.newState(gpa, io);
    defer api.close(l);
    defer out.deinit(l.g);
    api.openLibs(l) catch {
        std.debug.print("lus: cannot open libraries\n", .{});
        return 1;
    };

    if (args.len >= 3 and std.mem.eql(u8, args[1], "--dis")) {
        const s = std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .unlimited) catch return 1;
        defer gpa.free(s);
        const r = try lus.compile.codegen.compile(l.g, s, .{ .chunkname = args[2] });
        switch (r) {
            .err => |m| {
                std.debug.print("{s}\n", .{m});
                gpa.free(m);
                return 1;
            },
            .ok => |p| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                try lus.compile.disasm.dump(gpa, &buf, p, 0);
                out.stdout(l.g).write(l.g, buf.items);
                return 0;
            },
        }
    }
    if (args.len < 2) {
        std.debug.print("usage: lus script.lus [args]\n", .{});
        return 1;
    }
    const path = args[1];
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        std.debug.print("lus: cannot open {s} ({s})\n", .{ path, @errorName(e) });
        return 1;
    };
    defer gpa.free(src);
    const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{path});
    defer gpa.free(chunkname);
    if (api.doString(l, src, chunkname)) |msg| {
        out.flushAll(l.g);
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "lus: {s}\n", .{msg}) catch "lus: error\n";
        out.stderr(l.g, line);
        return 1;
    }
    return 0;
}
