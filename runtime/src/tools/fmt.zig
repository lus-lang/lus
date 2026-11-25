//! `lus fmt`: formats Lus source files.
//!
//! Usage: lus fmt [--check] [--write] [--indent N] [FILE...]
//!
//! By default the formatted text of every file is printed to standard
//! output. `--write` rewrites the files that change in place. `--check`
//! writes nothing and lists the files that would change. A directory
//! argument stands for every `.lus` file below it. With no file, or with
//! the file `-`, the source is read from standard input.
//!
//! The exit status is 0 when every file was formatted (or, with
//! `--check`, is already formatted), 1 when a file would change or cannot
//! be parsed, and 2 for a usage or I/O problem.

const std = @import("std");
const lus = @import("../lus.zig");
const astexport = @import("../syntax/astexport.zig");
const format = @import("../syntax/format.zig");
const paths = @import("paths.zig");
const ast = lus.syntax.ast;
const api = lus.api;
const codegen = lus.compile.codegen;

const usage =
    \\usage: lus fmt [--check] [--write] [--indent N] [FILE...]
    \\
    \\  --check     report the files that are not formatted, change nothing
    \\  --write     rewrite the files in place
    \\  --indent N  spaces per indentation level (default 4)
    \\
    \\A directory stands for every .lus file below it. With no FILE, or
    \\when FILE is -, read standard input.
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var check = false;
    var write = false;
    var indent: u32 = 4;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--write")) {
            write = true;
        } else if (std.mem.eql(u8, a, "--indent")) {
            i += 1;
            const n = if (i < args.len) std.fmt.parseInt(u32, args[i], 10) catch 0 else 0;
            if (n == 0 or n > 64) {
                std.debug.print("lus fmt: '--indent' needs a number between 1 and 64\n", .{});
                return 2;
            }
            indent = n;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus fmt: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        } else {
            try files.append(gpa, a);
        }
    }
    if (files.items.len == 0) try files.append(gpa, "-");

    var names_arena = std.heap.ArenaAllocator.init(gpa);
    defer names_arena.deinit();
    var expanded: std.ArrayList([]const u8) = .empty;
    for (files.items) |file| try paths.expand(names_arena.allocator(), io, file, &expanded);

    var status: u8 = 0;
    for (expanded.items) |file| {
        const from_stdin = std.mem.eql(u8, file, "-");
        const src = readSource(gpa, io, file, from_stdin) catch |e| {
            std.debug.print("lus fmt: cannot read {s} ({s})\n", .{ file, @errorName(e) });
            status = 2;
            continue;
        };
        defer gpa.free(src);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const chunkname = if (from_stdin) "=stdin" else try std.fmt.allocPrint(arena, "@{s}", .{file});
        const res = try format.format(gpa, arena, src, .{ .chunkname = chunkname, .indent_width = indent });
        const text = switch (res) {
            .fail => |msg| {
                std.debug.print("lus fmt: {s}\n", .{msg});
                if (status == 0) status = 1;
                continue;
            },
            .ok => |t| t,
        };
        const changed = !std.mem.eql(u8, src, text);
        if (check) {
            if (changed) {
                std.debug.print("{s}: not formatted\n", .{if (from_stdin) "<stdin>" else file});
                if (status == 0) status = 1;
            }
        } else if (write and !from_stdin) {
            if (changed) {
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text }) catch |e| {
                    std.debug.print("lus fmt: cannot write {s} ({s})\n", .{ file, @errorName(e) });
                    status = 2;
                };
            }
        } else {
            std.Io.File.stdout().writeStreamingAll(io, text) catch {};
        }
    }
    return status;
}

fn readSource(gpa: std.mem.Allocator, io: std.Io, file: []const u8, from_stdin: bool) ![]u8 {
    if (!from_stdin) return std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
    try r.interface.appendRemainingUnlimited(gpa, &buf);
    return buf.toOwnedSlice(gpa);
}
