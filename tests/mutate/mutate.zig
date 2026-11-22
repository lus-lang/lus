//! The mutant generator behind `tests/mutate/run.lus`.
//!
//! It parses a Zig file with `std.zig.Ast` and finds the places where one
//! small change makes a plausible bug:
//!
//! - `flip`: a comparison becomes its negation, `<` to `>=`, `==` to `!=`.
//! - `bool`: `and` becomes `or`, and the reverse.
//! - `const`: an integer constant grows or shrinks by one.
//! - `swap`: the operands of a subtraction, a division, a remainder, a
//!   shift, or an ordering comparison change places.
//! - `drop`: a statement that calls a function or assigns a value goes.
//!
//! `mutate sites FILE [LINES]` prints one site per line, as `INDEX KIND
//! LINE TEXT`. LINES names a file of `line` numbers, one per line, and
//! keeps only the sites on those lines, which `run.lus` fills with the
//! lines that the conformance suite covers. `mutate apply FILE INDEX`
//! rewrites FILE with site INDEX changed.

const std = @import("std");
const Ast = std.zig.Ast;

const Kind = enum { flip, bool, @"const", swap, drop };

const Site = struct {
    kind: Kind,
    /// The bytes of the source that the mutation replaces.
    start: u32,
    end: u32,
    /// The text that replaces them.
    text: []const u8,
    line: u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const cmd = args.next() orelse return error.Usage;
    const path = args.next() orelse return error.Usage;
    const third = args.next();
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
    var lines: ?std.AutoHashMapUnmanaged(u32, void) = null;
    if (std.mem.eql(u8, cmd, "sites")) if (third) |lp| {
        var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const data = try cwd.readFileAlloc(io, lp, arena, .unlimited);
        var it = std.mem.tokenizeAny(u8, data, " \n");
        while (it.next()) |t| try set.put(arena, std.fmt.parseInt(u32, t, 10) catch continue, {});
        lines = set;
    };
    const sites = try findSites(arena, source);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    if (std.mem.eql(u8, cmd, "sites")) {
        for (sites, 0..) |s, i| {
            if (lines) |set| if (!set.contains(s.line)) continue;
            const old = std.mem.trim(u8, source[s.start..s.end], " \n\t");
            const shown = if (old.len > 60) old[0..60] else old;
            try w.interface.print("{d} {t} {d} {s} => {s}\n", .{ i, s.kind, s.line, oneLine(arena, shown), oneLine(arena, s.text) });
        }
        try w.interface.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "apply")) {
        const index = try std.fmt.parseInt(usize, third orelse return error.Usage, 10);
        if (index >= sites.len) return error.NoSuchSite;
        const s = sites[index];
        const out = try std.mem.concat(arena, u8, &.{ source[0..s.start], s.text, source[s.end..] });
        try cwd.writeFile(io, .{ .sub_path = path, .data = out });
        return;
    }
    return error.Usage;
}

fn oneLine(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const r = arena.dupe(u8, s) catch return s;
    for (r) |*c| if (c.* == '\n' or c.* == '\t') {
        c.* = ' ';
    };
    return r;
}

fn tokenEnd(tree: *const Ast, t: Ast.TokenIndex) u32 {
    return @intCast(tree.tokenStart(t) + tree.tokenSlice(t).len);
}

fn nodeSpan(tree: *const Ast, n: Ast.Node.Index) [2]u32 {
    return .{ tree.tokenStart(tree.firstToken(n)), tokenEnd(tree, tree.lastToken(n)) };
}

fn lineOf(source: []const u8, at: u32) u32 {
    return @intCast(1 + std.mem.countScalar(u8, source[0..at], '\n'));
}

fn findSites(arena: std.mem.Allocator, source: [:0]const u8) ![]Site {
    var tree = try Ast.parse(arena, source, .{});
    var sites: std.ArrayList(Site) = .empty;
    // Spans of tests and comptime blocks, whose changes the shipped binary
    // never sees or the compiler rejects.
    var skip: std.ArrayList([2]u32) = .empty;
    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(n)) {
            .test_decl, .@"comptime" => try skip.append(arena, nodeSpan(&tree, n)),
            else => {},
        }
    }
    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const span = nodeSpan(&tree, n);
        var skipped = false;
        for (skip.items) |r| if (span[0] >= r[0] and span[1] <= r[1]) {
            skipped = true;
        };
        if (skipped) continue;
        const tag = tree.nodeTag(n);
        const op = tree.nodeMainToken(n);
        const op_start = tree.tokenStart(op);
        const op_end = tokenEnd(&tree, op);
        const line = lineOf(source, op_start);
        const flipped: ?[]const u8 = switch (tag) {
            .less_than => ">=",
            .greater_than => "<=",
            .less_or_equal => ">",
            .greater_or_equal => "<",
            .equal_equal => "!=",
            .bang_equal => "==",
            else => null,
        };
        if (flipped) |t| try sites.append(arena, .{ .kind = .flip, .start = op_start, .end = op_end, .text = t, .line = line });
        switch (tag) {
            .bool_and => try sites.append(arena, .{ .kind = .bool, .start = op_start, .end = op_end, .text = "or", .line = line }),
            .bool_or => try sites.append(arena, .{ .kind = .bool, .start = op_start, .end = op_end, .text = "and", .line = line }),
            .number_literal => {
                const text = tree.tokenSlice(op);
                const v = std.fmt.parseInt(i64, text, 0) catch continue;
                // Zero grows. Other constants grow or shrink, by a choice
                // that stays the same for the same place.
                const changed = if (v == 0) v + 1 else if (stableBit(op_start)) v + 1 else v - 1;
                try sites.append(arena, .{ .kind = .@"const", .start = op_start, .end = op_end, .text = try std.fmt.allocPrint(arena, "{d}", .{changed}), .line = line });
            },
            .sub, .div, .mod, .shl, .shr, .less_than, .greater_than, .less_or_equal, .greater_or_equal => {
                const lhs, const rhs = tree.nodeData(n).node_and_node;
                const l = nodeSpan(&tree, lhs);
                const r = nodeSpan(&tree, rhs);
                const text = try std.mem.concat(arena, u8, &.{ source[r[0]..r[1]], source[l[1]..r[0]], source[l[0]..l[1]] });
                try sites.append(arena, .{ .kind = .swap, .start = l[0], .end = r[1], .text = text, .line = line });
            },
            else => {},
        }
    }
    // Statements of blocks that call a function or assign a value.
    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buf: [2]Ast.Node.Index = undefined;
        const stmts = tree.blockStatements(&buf, n) orelse continue;
        for (stmts) |st| {
            switch (tree.nodeTag(st)) {
                .call, .call_one, .call_comma, .call_one_comma, .assign, .assign_add, .assign_sub, .assign_mul => {},
                else => continue,
            }
            const span = nodeSpan(&tree, st);
            var skipped = false;
            for (skip.items) |r| if (span[0] >= r[0] and span[1] <= r[1]) {
                skipped = true;
            };
            if (skipped) continue;
            // The statement and its semicolon.
            const last = tree.lastToken(st) + 1;
            const end = if (last < tree.tokens.len and tree.tokenTag(last) == .semicolon) tokenEnd(&tree, last) else span[1];
            try sites.append(arena, .{ .kind = .drop, .start = span[0], .end = end, .text = "", .line = lineOf(source, span[0]) });
        }
    }
    std.mem.sort(Site, sites.items, {}, struct {
        fn lt(_: void, a: Site, b: Site) bool {
            return a.start < b.start or (a.start == b.start and @backingInt(a.kind) < @backingInt(b.kind));
        }
    }.lt);
    return sites.items;
}

/// A choice that depends only on `x`.
fn stableBit(x: u32) bool {
    return (x *% 2654435761) >> 7 & 1 == 0;
}
