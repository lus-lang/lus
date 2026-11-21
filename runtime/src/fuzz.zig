//! Fuzz targets for the front end and the binary chunk loader.
//!
//! Each target is an ordinary test that also runs under the fuzzer:
//! `zig build test` runs every target once over its seed corpus, and
//! `zig build test --fuzz` mutates the inputs for as long as it runs.
//! A target fails only on a crash, a leak, or a broken invariant, never
//! because the input is not a valid program.

const std = @import("std");
const lexer = @import("syntax/lexer.zig");
const parser = @import("syntax/parser.zig");
const format = @import("syntax/format.zig");
const codegen = @import("compile/codegen.zig");
const dump = @import("compile/dump.zig");
const state = @import("vm/state.zig");

const Smith = std.testing.Smith;

/// Programs that reach the interesting parts of the grammar, used as the
/// starting corpus for every target.
const seeds = [_][]const u8{
    "local x = 1 + 2 * 3",
    "local function f(a, ...) return a, ... end print(f(1, 2))",
    "for i = 1, 10 do if i % 2 == 0 then continue end print(i) end",
    "local t = { a = 1, [2] = 'b', 3; x = { y = {} } } print(t.a, t?.x?.y)",
    "local s = `value $(1 + 2) and $name` print(s)",
    "local ok, err = catch error('boom') print(ok, err)",
    "local v = do local a = 1 provide a + 1 end",
    "local e = enum red, green, blue end print(e.red)",
    "local big, dec = 12345678901234567890n, 1.25d",
    "while local x = next({}) do break end",
    "goto done ::done::",
    "local g <group> = { a = 1, b = { c = 2 } } print(g.b.c)",
    "global x = 1 global * y = 2",
    "local q = from p in {} where p.x > 1 select p.x",
    "repeat local n = 1 until n > 0",
    "local t = {1, 2, 3} print(t[1, 2], #t)",
    "local a <const>, b <close> = 1, nil",
};

fn sliceInput(smith: *Smith, buf: []u8) []const u8 {
    const n = smith.slice(buf);
    return buf[0..n];
}

fn parseOne(_: void, smith: *Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const src = sliceInput(smith, &buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: ?[]const u8 = null;
    _ = parser.parse(std.testing.allocator, arena_state.allocator(), src, .{ .chunkname = "=fuzz" }, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.SyntaxError => {},
    };
}

test "fuzz: the parser never crashes" {
    try std.testing.fuzz({}, parseOne, .{ .corpus = &seeds });
}

fn compileOne(_: void, smith: *Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const src = sliceInput(smith, &buf);
    const g = try state.create(std.testing.allocator, std.testing.io);
    defer state.destroy(g);
    switch (try codegen.compile(g, src, .{ .chunkname = "=fuzz" })) {
        .ok => {},
        .err => |msg| g.gpa.free(msg),
    }
}

test "fuzz: the compiler never crashes" {
    try std.testing.fuzz({}, compileOne, .{ .corpus = &seeds });
}

fn formatOne(_: void, smith: *Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const src = sliceInput(smith, &buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = switch (try format.format(std.testing.allocator, arena, src, .{})) {
        .ok => |s| s,
        .fail => return,
    };
    // Formatting is idempotent: formatted output formats to itself.
    switch (try format.format(std.testing.allocator, arena, first, .{})) {
        .ok => |second| try std.testing.expectEqualStrings(first, second),
        .fail => |why| {
            std.debug.print("formatted output does not format again: {s}\n{s}\n", .{ why, first });
            return error.FormatNotIdempotent;
        },
    }
}

test "fuzz: formatting is idempotent" {
    try std.testing.fuzz({}, formatOne, .{ .corpus = &seeds });
}

fn undumpOne(_: void, smith: *Smith) anyerror!void {
    const g = try state.create(std.testing.allocator, std.testing.io);
    defer state.destroy(g);
    g.gc_stopped = true;
    // Start from a real chunk and let the fuzzer change its bytes.
    const p = switch (try codegen.compile(g, seeds[smith.index(seeds.len)], .{ .chunkname = "=fuzz" })) {
        .ok => |p| p,
        .err => |msg| {
            g.gpa.free(msg);
            return;
        },
    };
    const bytes = try dump.dump(std.testing.allocator, p, smith.value(bool));
    defer std.testing.allocator.free(bytes);
    const edits = smith.valueRangeAtMost(u8, 0, 8);
    for (0..edits) |_| {
        if (bytes.len <= dump.signature.len) break;
        const at = dump.signature.len + smith.index(bytes.len - dump.signature.len);
        bytes[at] = smith.value(u8);
    }
    if (smith.value(bool)) {
        // Truncation is the most common corruption.
        const keep = smith.index(bytes.len + 1);
        _ = dump.undump(g, bytes[0..keep], "=fuzz") catch return;
        return;
    }
    _ = dump.undump(g, bytes, "=fuzz") catch return;
}

test "fuzz: loading a corrupt binary chunk never crashes" {
    try std.testing.fuzz({}, undumpOne, .{});
}

test "fuzz: the lexer never crashes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var buf: [2048]u8 = undefined;
            const src = sliceInput(smith, &buf);
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            var lx = lexer.Lexer.init(std.testing.allocator, arena_state.allocator(), src);
            defer lx.deinit();
            _ = lx.run() catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {},
            };
        }
    }.one, .{ .corpus = &seeds });
}
