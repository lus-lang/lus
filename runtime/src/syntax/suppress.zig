//! Inline suppression of `lus check` diagnostics.
//!
//! A comment `-- lus: allow(CODE, ...)` names the codes it suppresses.
//! At the end of a line of code it covers that line. On a line of its own
//! it covers the next statement, all its lines included. Inside the header
//! doc comment of a module, the run of `---` lines at the start of the file
//! that a blank line ends, it covers the whole file. Errors stay reported,
//! because the compiler rejects the chunk whatever a comment says. A code
//! that no diagnostic has is reported as `unknown-allow`, which catches a
//! misspelled code.

const std = @import("std");
const ast = @import("ast.zig");
const lint = @import("lint.zig");
const walk = @import("walk.zig");
const Allocator = std.mem.Allocator;

const marker = "lus: allow(";

/// The lines a directive covers, first and last included.
const Range = struct { first: u32, last: u32, codes: []const []const u8 };

/// Whether `code` names a diagnostic that `lus check` can report.
fn known(code: []const u8) bool {
    for (lint.codes) |c| if (std.mem.eql(u8, c.code, code)) return true;
    return false;
}

const Statements = struct {
    arena: Allocator,
    spans: std.ArrayList(ast.Span) = .empty,

    fn expr(_: *Statements, _: **ast.Expr) anyerror!void {}

    fn stat(s: *Statements, st: *ast.Stat) anyerror!void {
        try s.spans.append(s.arena, st.span);
    }
};

/// One-based line of the byte offset `at`.
fn lineOf(src: []const u8, at: usize) u32 {
    return @intCast(std.mem.count(u8, src[0..@min(at, src.len)], "\n") + 1);
}

/// The number of lines of the header doc comment, or 0 when the file has
/// none.
fn headerLines(src: []const u8) u32 {
    var it = std.mem.splitScalar(u8, src, '\n');
    var n: u32 = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (n == 0 and std.mem.startsWith(u8, line, "#!")) {
            n += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "---")) {
            n += 1;
            continue;
        }
        return if (line.len == 0 and n > 0) n else 0;
    }
    return 0;
}

/// Removes the warnings and hints that a directive covers from `list`,
/// and adds an `unknown-allow` warning for each unknown code.
pub fn apply(arena: Allocator, src: []const u8, chunk: ?ast.Chunk, list: []lint.Diagnostic) ![]lint.Diagnostic {
    if (std.mem.indexOf(u8, src, marker) == null) return list;
    var stats: Statements = .{ .arena = arena };
    if (chunk) |c| {
        const v: walk.Visitor(*Statements) = .{ .ctx = &stats, .func = Statements.expr, .stat_func = Statements.stat };
        v.block(c.block) catch return error.OutOfMemory;
    }
    const header = headerLines(src);

    var ranges: std.ArrayList(Range) = .empty;
    var extra: std.ArrayList(lint.Diagnostic) = .empty;
    var line_start: usize = 0;
    var lineno: u32 = 1;
    while (line_start <= src.len) : (lineno += 1) {
        const line_end = std.mem.indexOfScalarPos(u8, src, line_start, '\n') orelse src.len;
        const line = src[line_start..line_end];
        defer line_start = line_end + 1;
        const dash = std.mem.indexOf(u8, line, "--") orelse {
            if (line_end == src.len) break;
            continue;
        };
        const rest = std.mem.trimStart(u8, line[dash..], "-");
        const after = std.mem.trimStart(u8, rest, " \t");
        if (!std.mem.startsWith(u8, after, marker)) {
            if (line_end == src.len) break;
            continue;
        }
        const open = line_start + dash + (line[dash..].len - after.len) + marker.len;
        const close = std.mem.indexOfScalarPos(u8, src[0..line_end], open, ')') orelse {
            if (line_end == src.len) break;
            continue;
        };
        var codes: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, src[open..close], ", \t");
        while (it.next()) |code| {
            if (!known(code)) {
                const off = open + @as(usize, @intCast(@intFromPtr(code.ptr) - @intFromPtr(src[open..close].ptr)));
                var d: lint.Diagnostic = .{
                    .span = .{ .start = @intCast(off), .end = @intCast(off + code.len) },
                    .severity = .warning,
                    .code = "unknown-allow",
                    .message = try std.fmt.allocPrint(arena, "'{s}' is not a diagnostic code, so this allow suppresses nothing", .{code}),
                };
                lint.locate(src, (&d)[0..1]);
                try extra.append(arena, d);
                continue;
            }
            try codes.append(arena, code);
        }
        const trailing = std.mem.trim(u8, line[0..dash], " \t").len > 0;
        if (trailing) {
            try ranges.append(arena, .{ .first = lineno, .last = lineno, .codes = codes.items });
        } else if (lineno <= header) {
            try ranges.append(arena, .{ .first = 1, .last = std.math.maxInt(u32), .codes = codes.items });
        } else {
            // The statement that starts first after the comment.
            var best: ?ast.Span = null;
            for (stats.spans.items) |sp| {
                if (sp.start <= line_end) continue;
                if (best == null or sp.start < best.?.start) best = sp;
            }
            if (best) |sp| try ranges.append(arena, .{ .first = lineOf(src, sp.start), .last = lineOf(src, sp.end -| 1), .codes = codes.items });
        }
        if (line_end == src.len) break;
    }

    var out: std.ArrayList(lint.Diagnostic) = .empty;
    for (list) |d| {
        if (d.severity != .@"error" and covered(ranges.items, d)) continue;
        try out.append(arena, d);
    }
    try out.appendSlice(arena, extra.items);
    std.mem.sort(lint.Diagnostic, out.items, {}, struct {
        fn lt(_: void, a: lint.Diagnostic, b: lint.Diagnostic) bool {
            return a.span.start < b.span.start;
        }
    }.lt);
    return out.items;
}

fn covered(ranges: []const Range, d: lint.Diagnostic) bool {
    for (ranges) |r| {
        if (d.line < r.first or d.line > r.last) continue;
        for (r.codes) |c| if (std.mem.eql(u8, c, d.code)) return true;
    }
    return false;
}

const testing = std.testing;

fn codesOf(src: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: ?[]const u8 = null;
    const chunk = try @import("parser.zig").parse(testing.allocator, arena, src, .{ .chunkname = "=t" }, &diag);
    const list = try apply(arena, src, chunk, try lint.lint(arena, chunk, .{}));
    var buf: std.ArrayList(u8) = .empty;
    for (list) |d| {
        if (buf.items.len > 0) try buf.append(arena, ' ');
        try buf.print(arena, "{s}@{d}", .{ d.code, d.line });
    }
    return testing.allocator.dupe(u8, buf.items);
}

fn expectCodes(src: []const u8, want: []const u8) !void {
    const got = try codesOf(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a trailing allow covers its line" {
    try expectCodes("local a = 1 -- lus: allow(unused-local)\nlocal b = 2\n", "unused-local@2");
}

test "an allow on a line of its own covers the next statement" {
    try expectCodes(
        \\-- lus: allow(unused-param, unused-local)
        \\local function f(x)
        \\    local y = 1
        \\end
        \\local w = 1
        \\return f
    , "unused-local@5");
}

test "an allow in the header covers the file" {
    try expectCodes(
        \\--- A module.
        \\--- lus: allow(unused-local)
        \\
        \\local a = 1
        \\local function g() local b = 2 end
        \\return g
    , "");
}

test "errors stay and unknown codes are reported" {
    try expectCodes("goto nowhere -- lus: allow(undefined-label, unused-lokal)\n", "undefined-label@1 unknown-allow@1");
}

test "the codes of other diagnostics stay" {
    try expectCodes("local a = 1 -- lus: allow(shadowed-local)\n", "unused-local@1");
}
