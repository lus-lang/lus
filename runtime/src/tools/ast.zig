//! `lus ast`: prints the syntax tree of a file as JSON.
//!
//! The tree is the one `debug.parse` returns, written with its fields in
//! a fixed order (`type`, `line`, `column`, the end position, the fields
//! of the node, then `children`). The shape is described by
//! `spec/language/ast.schema.json`.
//!
//! Usage: lus ast [--no-comments] [--no-recover] FILE
//!
//! The exit status is 0 for a tree without errors, 1 when the tree lists
//! errors or the file cannot be parsed at all, and 2 for a usage or I/O
//! problem.

const std = @import("std");
const lus = @import("../lus.zig");
const astexport = @import("../syntax/astexport.zig");
const ast = lus.syntax.ast;
const api = lus.api;
const codegen = lus.compile.codegen;

const usage = "usage: lus ast [--no-comments] [--no-recover] FILE\n";

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var path: ?[]const u8 = null;
    var comments = true;
    var recover = true;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--no-comments")) {
            comments = false;
        } else if (std.mem.eql(u8, a, "--no-recover")) {
            recover = false;
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus ast: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        } else if (path == null) {
            path = a;
        } else {
            std.debug.print("{s}", .{usage});
            return 2;
        }
    }
    const file = path orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const src = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited) catch |e| {
        std.debug.print("lus ast: cannot open {s} ({s})\n", .{ file, @errorName(e) });
        return 2;
    };
    defer gpa.free(src);

    // A runtime state backs the compiler pass that reports the errors
    // found after parsing.
    const l = try api.newState(gpa, io);
    defer api.close(l);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chunkname = try std.fmt.allocPrint(arena, "@{s}", .{file});
    const checker: astexport.Checker = .{ .ctx = l.g, .check = check };
    const res = try astexport.run(gpa, arena, src, .{ .chunkname = chunkname, .comments = comments, .recover = recover }, checker);
    switch (res) {
        .fail => |msg| {
            std.debug.print("lus ast: {s}\n", .{msg});
            return 1;
        },
        .tree => |root| {
            var buf: std.Io.Writer.Allocating = .init(gpa);
            defer buf.deinit();
            astexport.writeJson(&buf.writer, root) catch return error.OutOfMemory;
            std.Io.File.stdout().writeStreamingAll(io, buf.written()) catch {};
            for (root.fields.items) |f| {
                if (std.mem.eql(u8, f.key, "errors")) return 1;
            }
            return 0;
        },
    }
}

fn check(ctx: *anyopaque, arena: std.mem.Allocator, chunk: ast.Chunk, chunkname: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const g: *lus.vm.state.Global = @ptrCast(@alignCast(ctx));
    const r = try codegen.compileAst(g, arena, chunk, .{ .chunkname = chunkname });
    switch (r) {
        .ok => return null,
        .err => |m| {
            defer g.gpa.free(m);
            return try arena.dupe(u8, m);
        },
    }
}
