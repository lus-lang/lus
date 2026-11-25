//! The layout rules of `lus check --strict`, the style that
//! `lus fmt --strict` writes (`spec/design/style.md`, section 13):
//!
//! - Each statement starts a line of its own, and the body of a block
//!   takes lines of its own.
//! - A blank line separates a multi-line block from the statements before
//!   and after it in the same scope.
//! - A short string uses double quotes unless it holds a double quote.
//! - The last field of a multi-line table ends with a comma.
//! - A line holds at most 100 columns, unless a string or a comment
//!   crosses the limit.
//!
//! Strict checking also raises the hints that name a Lus form of a
//! Lua-era pattern to warnings (`promoted`).

const std = @import("std");
const ast = @import("ast.zig");
const lint = @import("lint.zig");
const walk = @import("walk.zig");
const Allocator = std.mem.Allocator;
const Span = ast.Span;
const Diagnostic = lint.Diagnostic;
const Edit = lint.Edit;

/// The widest line in columns.
pub const max_width = 100;

/// The hints that strict checking reports as warnings. Each names a Lus
/// form of a pattern that Lua code spells out by hand.
pub const promoted = [_][]const u8{
    "use-from",
    "use-for-from",
    "use-optional-chain",
    "use-if-assign",
    "use-interpolation",
    "format-to-interpolation",
    "redundant-tostring",
    "use-continue",
};

pub fn isPromoted(code: []const u8) bool {
    for (promoted) |p| if (std.mem.eql(u8, p, code)) return true;
    return false;
}

const Construct = struct {
    /// The statement or expression that holds the blocks.
    span: Span,
    blocks: []const *ast.Block,
};

const Checker = struct {
    arena: Allocator,
    src: []const u8,
    chunk: ast.Chunk,
    starts: []u32,
    /// Lines that hold a comment and nothing before it, by line number.
    comment_lines: []bool,
    out: std.ArrayList(Diagnostic) = .empty,
    constructs: std.ArrayList(Construct) = .empty,
    /// Spans of the function and do expressions.
    nested: std.ArrayList(Span) = .empty,
    /// Spans of the string literals and interpolated strings.
    strings: std.ArrayList(Span) = .empty,
    tables: std.ArrayList(*ast.Expr) = .empty,
    blocks: std.ArrayList(*ast.Block) = .empty,

    fn lineOf(c: *const Checker, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = c.starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (c.starts[mid] <= off) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    fn lineText(c: *const Checker, line: u32) []const u8 {
        if (line == 0 or line > c.starts.len) return "";
        const start = c.starts[line - 1];
        var end: usize = if (line < c.starts.len) c.starts[line] else c.src.len;
        while (end > start and (c.src[end - 1] == '\n' or c.src[end - 1] == '\r')) end -= 1;
        return c.src[start..end];
    }

    fn isBlank(c: *const Checker, line: u32) bool {
        return std.mem.trim(u8, c.lineText(line), " \t\x0b\x0c").len == 0;
    }

    /// Whether only whitespace comes before `off` on its line.
    fn firstOnLine(c: *const Checker, off: u32) bool {
        const start = c.starts[c.lineOf(off) - 1];
        return std.mem.trim(u8, c.src[start..off], " \t\x0b\x0c").len == 0;
    }

    /// The first line of a statement, together with the comments right
    /// above it.
    fn effectiveStart(c: *const Checker, s: *const ast.Stat) u32 {
        var line = c.lineOf(s.span.start);
        while (line > 1 and c.comment_lines[line - 1]) line -= 1;
        return line;
    }

    fn report(c: *Checker, span: Span, code: []const u8, fix: []const Edit, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try c.out.append(c.arena, .{
            .span = span,
            .severity = .warning,
            .code = code,
            .message = try std.fmt.allocPrint(c.arena, fmt, args),
            .fix = fix,
        });
    }

    fn insert(c: *Checker, at: u32, text: []const u8) Allocator.Error![]const Edit {
        const e = try c.arena.alloc(Edit, 1);
        e[0] = .{ .span = .{ .start = at, .end = at }, .text = text };
        return e;
    }

    fn visit(c: *Checker, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        switch (e.kind) {
            .function => |f| {
                try c.nested.append(c.arena, e.span);
                try c.constructs.append(c.arena, .{ .span = e.span, .blocks = try c.one(f.body) });
                try c.blocks.append(c.arena, f.body);
            },
            .do_ => |b| {
                try c.nested.append(c.arena, e.span);
                try c.constructs.append(c.arena, .{ .span = e.span, .blocks = try c.one(b) });
                try c.blocks.append(c.arena, b);
            },
            .table => try c.tables.append(c.arena, e),
            .string, .interp => try c.strings.append(c.arena, e.span),
            else => {},
        }
    }

    fn one(c: *Checker, b: *ast.Block) Allocator.Error![]const *ast.Block {
        const list = try c.arena.alloc(*ast.Block, 1);
        list[0] = b;
        return list;
    }

    fn stat(c: *Checker, s: *ast.Stat) anyerror!void {
        var list: std.ArrayList(*ast.Block) = .empty;
        switch (s.kind) {
            .do_ => |b| try list.append(c.arena, b),
            .while_ => |w| try list.append(c.arena, w.body),
            .repeat_ => |r| try list.append(c.arena, r.body),
            .if_ => |i| {
                for (i.clauses) |cl| try list.append(c.arena, cl.body);
                if (i.else_) |b| try list.append(c.arena, b);
            },
            .numeric_for => |f| try list.append(c.arena, f.body),
            .generic_for => |f| try list.append(c.arena, f.body),
            .local_function => |f| try list.append(c.arena, f.func.body),
            .global_function => |f| try list.append(c.arena, f.func.body),
            .function => |f| try list.append(c.arena, f.func.body),
            else => return,
        }
        try c.blocks.appendSlice(c.arena, list.items);
        try c.constructs.append(c.arena, .{ .span = s.span, .blocks = list.items });
    }

    /// Whether `s` spans several lines and holds a block: a control
    /// structure, a function, or a do-expression.
    fn isMultiBlock(c: *const Checker, s: *const ast.Stat) bool {
        if (c.lineOf(s.span.start) == c.lineOf(s.span.end -| 1)) return false;
        switch (s.kind) {
            .do_, .while_, .repeat_, .if_, .numeric_for, .generic_for, .local_function, .global_function, .function => return true,
            else => {},
        }
        for (c.nested.items) |n| {
            if (n.start >= s.span.start and n.end <= s.span.end and c.lineOf(n.start) != c.lineOf(n.end -| 1)) return true;
        }
        return false;
    }

    fn statements(c: *Checker, stats_: []*ast.Stat) Allocator.Error!void {
        var stats: std.ArrayList(*ast.Stat) = .empty;
        for (stats_) |s| if (s.kind != .empty) try stats.append(c.arena, s);
        const list = stats.items;
        var prev_multi = false;
        for (list, 0..) |s, i| {
            const multi = c.isMultiBlock(s);
            if (i > 0 and !c.firstOnLine(s.span.start)) {
                try c.report(s.span, "one-statement-per-line", &.{}, "put each statement on a line of its own", .{});
            } else if (i > 0 and multi and !prev_multi) {
                const line = c.effectiveStart(s);
                if (!c.isBlank(line - 1)) {
                    try c.report(s.span, "blank-line-around-block", try c.insert(c.starts[line - 1], "\n"), "put a blank line before a block that spans several lines", .{});
                }
            }
            if (multi and i + 1 < list.len) {
                const end_line = c.lineOf(s.span.end -| 1);
                const next = list[i + 1];
                if (c.lineOf(next.span.start) > end_line and !c.isBlank(end_line + 1)) {
                    try c.report(s.span, "blank-line-around-block", try c.insert(c.starts[end_line], "\n"), "put a blank line after a block that spans several lines", .{});
                }
            }
            prev_multi = multi;
        }
    }

    fn singleLine(c: *Checker, k: Construct) Allocator.Error!void {
        for (k.blocks, 0..) |b, i| {
            var bad = false;
            var last_end: ?u32 = null;
            for (b.stats) |s| {
                if (s.kind == .empty) continue;
                if (last_end == null and !c.firstOnLine(s.span.start)) bad = true;
                last_end = s.span.end;
            }
            if (last_end) |e| {
                if (b.end_line == c.lineOf(e -| 1)) bad = true;
            } else if (i == 0 and b.end_line == c.lineOf(k.span.start)) {
                bad = true;
            }
            if (bad) {
                return c.report(k.span, "single-line-block", &.{}, "write the body of a block on lines of its own", .{});
            }
        }
    }

    fn fieldStart(fld: ast.Field) u32 {
        return switch (fld.kind) {
            .positional => |v| v.span.start,
            .named => |nv| nv.name.span.start,
            .keyed => |kv| kv.key.span.start,
        };
    }

    fn fieldEnd(fld: ast.Field) u32 {
        return switch (fld.kind) {
            .positional => |v| v.span.end,
            .named => |nv| nv.value.span.end,
            .keyed => |kv| kv.value.span.end,
        };
    }

    /// The offset of the first byte after `off` that is neither space nor
    /// part of a comment.
    fn skipSpace(c: *const Checker, off: u32, limit: u32) u32 {
        var i = off;
        outer: while (i < limit) {
            switch (c.src[i]) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => i += 1,
                else => {
                    for (c.chunk.comments) |cm| {
                        if (cm.span.start == i) {
                            i = cm.span.end;
                            continue :outer;
                        }
                    }
                    return i;
                },
            }
        }
        return i;
    }

    fn trailingComma(c: *Checker, e: *ast.Expr) Allocator.Error!void {
        const fields = e.kind.table;
        if (fields.len == 0) return;
        const close = e.span.end -| 1;
        // A table is on several lines when a line break follows its brace,
        // as `lus fmt --strict` writes it.
        if (c.lineOf(e.span.start) == c.lineOf(fieldStart(fields[0]))) return;
        const after = fieldEnd(fields[fields.len - 1]);
        const next = c.skipSpace(after, close);
        if (next < close and (c.src[next] == ',' or c.src[next] == ';')) return;
        try c.report(e.span, "trailing-comma", try c.insert(after, ","), "end the last field of a multi-line table with a comma", .{});
    }

    fn quotes(c: *Checker, span: Span) Allocator.Error!void {
        const text = try doubleQuoted(c.arena, c.src[span.start..span.end]) orelse return;
        const e = try c.arena.alloc(Edit, 1);
        e[0] = .{ .span = span, .text = text };
        try c.report(span, "prefer-double-quotes", e, "write a string that holds no double quote in double quotes", .{});
    }

    fn lineLength(c: *Checker) Allocator.Error!void {
        var line: u32 = 1;
        while (line <= c.starts.len) : (line += 1) {
            const text = c.lineText(line);
            if (text.len <= max_width) continue;
            const view = std.unicode.Utf8View.init(text) catch continue;
            var it = view.iterator();
            var cols: u32 = 0;
            var limit_off: ?u32 = null;
            while (it.nextCodepointSlice()) |cp| {
                cols += 1;
                if (cols == max_width + 1) limit_off = @intCast(@intFromPtr(cp.ptr) - @intFromPtr(c.src.ptr));
            }
            const at = limit_off orelse continue;
            if (c.inStringOrComment(at)) continue;
            const start = c.starts[line - 1];
            try c.report(.{ .start = start, .end = start + @as(u32, @intCast(text.len)) }, "line-too-long", &.{}, "line is {d} columns long, over the limit of {d}", .{ cols, max_width });
        }
    }

    fn inStringOrComment(c: *const Checker, off: u32) bool {
        for (c.strings.items) |s| if (off >= s.start and off < s.end) return true;
        for (c.chunk.comments) |cm| if (off >= cm.span.start and off < cm.span.end) return true;
        return false;
    }
};

/// The double-quoted spelling of `text`, a single-quoted string literal
/// as the source writes it. Null when `text` is not single-quoted or holds
/// a double quote, which double quotes would have to escape.
pub fn doubleQuoted(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    if (text.len < 2 or text[0] != '\'' or text[text.len - 1] != '\'') return null;
    const inner = text[1 .. text.len - 1];
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch == '"') return null;
        if (ch == '\\' and i + 1 < inner.len) {
            if (inner[i + 1] == '\'') {
                try out.append(arena, '\'');
            } else {
                try out.appendSlice(arena, inner[i .. i + 2]);
            }
            i += 2;
            continue;
        }
        try out.append(arena, ch);
        i += 1;
    }
    try out.append(arena, '"');
    return out.items;
}

/// The layout diagnostics of `chunk`, located in its source.
pub fn check(arena: Allocator, chunk: ast.Chunk) Allocator.Error![]Diagnostic {
    const src = chunk.source;
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '\n' or ch == '\r') {
            if (i + 1 < src.len and (src[i + 1] == '\n' or src[i + 1] == '\r') and src[i + 1] != ch) i += 2 else i += 1;
            try starts.append(arena, @intCast(i));
        } else i += 1;
    }
    // A source that ends with a line break has no line after it.
    if (starts.items.len > 1 and starts.items[starts.items.len - 1] == src.len) starts.items.len -= 1;

    var c: Checker = .{
        .arena = arena,
        .src = src,
        .chunk = chunk,
        .starts = starts.items,
        .comment_lines = try arena.alloc(bool, starts.items.len + 2),
    };
    @memset(c.comment_lines, false);
    for (chunk.comments) |cm| {
        if (!c.firstOnLine(cm.span.start)) continue;
        var l = c.lineOf(cm.span.start);
        const last = c.lineOf(cm.span.end -| 1);
        while (l <= last) : (l += 1) c.comment_lines[l] = true;
    }

    const v: walk.Visitor(*Checker) = .{ .ctx = &c, .func = Checker.visit, .stat_func = Checker.stat };
    v.block(chunk.block) catch return error.OutOfMemory;

    try c.statements(chunk.block.stats);
    for (c.blocks.items) |b| try c.statements(b.stats);
    for (c.constructs.items) |k| try c.singleLine(k);
    for (c.tables.items) |t| try c.trailingComma(t);
    for (c.strings.items) |s| try c.quotes(s);
    try c.lineLength();
    lint.locate(src, c.out.items);
    return c.out.items;
}

const testing = std.testing;

fn strictCodes(src: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: ?[]const u8 = null;
    const chunk = try @import("parser.zig").parse(testing.allocator, arena, src, .{ .chunkname = "=t" }, &diag);
    const list = try check(arena, chunk);
    var buf: std.ArrayList(u8) = .empty;
    for (list) |d| {
        if (buf.items.len > 0) try buf.append(arena, ' ');
        try buf.appendSlice(arena, d.code);
    }
    return testing.allocator.dupe(u8, buf.items);
}

fn expectStrict(src: []const u8, want: []const u8) !void {
    const got = try strictCodes(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "statements and blocks" {
    try expectStrict("local a = 1 local b = 2\n", "one-statement-per-line");
    try expectStrict("local a = 1\nlocal b = 2\n", "");
    try expectStrict("if a then b() end\n", "single-line-block");
    try expectStrict("while a do\nend\n", "");
    try expectStrict("while a do end\n", "single-line-block");
    try expectStrict("local f = function(x) return x end\n", "single-line-block");
    try expectStrict("if a then b()\nend\n", "single-line-block");
    try expectStrict("if a then\n    b()\nelse c() end\n", "single-line-block");
}

test "blank lines around blocks" {
    try expectStrict("local a = 1\nif a then\n    b()\nend\nc()\n", "blank-line-around-block blank-line-around-block");
    try expectStrict("local a = 1\n\nif a then\n    b()\nend\n\nc()\n", "");
    // The comments right above a block belong to it.
    try expectStrict("local a = 1\n-- note\nif a then\n    b()\nend\n", "blank-line-around-block");
    try expectStrict("local a = 1\n\n-- note\nif a then\n    b()\nend\n", "");
    // A block at the start or the end of its scope needs no blank line
    // on that side, and two blocks in a row need one between them.
    try expectStrict("do\n    if a then\n        b()\n    end\nend\n", "");
    try expectStrict("if a then\n    b()\nend\nif c then\n    d()\nend\n", "blank-line-around-block");
    // A statement whose value holds a function spanning lines is a block.
    try expectStrict("local a = 1\nlocal f = function()\n    return a\nend\n", "blank-line-around-block");
    try expectStrict("local a = 1\nlocal t = {\n    x = 1,\n}\n", "");
}

test "quotes, commas, and line length" {
    try expectStrict("local s = 'pear'\n", "prefer-double-quotes");
    try expectStrict("local s = 'say \"hi\"'\n", "");
    try expectStrict("local s = \"pear\"\n", "");
    try expectStrict("local t = {\n    x = 1,\n    y = 2\n}\n", "trailing-comma");
    try expectStrict("local t = {\n    x = 1,\n    y = 2 -- last\n}\n", "trailing-comma");
    try expectStrict("local t = {\n    x = 1,\n    y = 2, -- last\n}\n", "");
    try expectStrict("local t = { x = 1, y = 2 }\n", "");
    const long = "local x = a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a + a\n";
    try expectStrict(long, "line-too-long");
    const long_string = "local x = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n";
    try expectStrict(long_string, "");
}
