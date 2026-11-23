//! The source transform behind the MC/DC measure of `mise run mcdc`.
//!
//! It rewrites every Zig file below a copy of `runtime/src` in place. Each
//! decision, a boolean expression of two or more conditions joined by
//! `and` and `or` inside a function body, becomes a block that records
//! which conditions ran, the value of each, and the outcome:
//!
//!     a and b
//!
//! becomes
//!
//!     (mcdc_1: {
//!         var mcdc_v1: u64 = 0;
//!         const mcdc_r1 = mcdc_rt.c(&mcdc_v1, 0, a) and mcdc_rt.c(&mcdc_v1, 1, b);
//!         mcdc_rt.d(1, mcdc_v1, mcdc_r1);
//!         break :mcdc_1 mcdc_r1;
//!     })
//!
//! `c` is an inline function that returns its condition, so a condition
//! that is known at compile time stays known, and the branches it removes
//! stay removed. The transform writes the table of decisions, one line of
//! `id file line conditions` each, to the path of its second argument,
//! and the runtime module `mcdc_rt.zig` next to the root of the sources.
//! `mcdc.lus` turns the vectors that the runs record into the report.

const std = @import("std");
const Ast = std.zig.Ast;

/// Files that belong to another module than the runtime library, or that
/// record coverage themselves.
const skip = [_][]const u8{ "main.zig", "capi.zig", "wasm.zig", "coverage.zig", "mcdc_rt.zig" };

/// Functions that only the invariant checks of `inv.assert` call. The
/// shipped build leaves the checks out, so their decisions stay out of
/// the measure, as SQLite leaves `assert` out of its own.
const checkers = [_][]const u8{ "textMatches", "internedOk", "wellFormed", "pageOk", "layoutOk", "arrayOk", "bytesOk" };

/// The calls whose argument is an invariant. An argument of `inv.assert`
/// is always true and runs only in a checking build. An argument of
/// `inv.always` or `inv.never` has one value in every run.
const invariant_calls = [_][]const u8{ "inv.assert", "inv.always", "inv.never" };

/// More conditions than a vector of 64 bits holds at two bits each.
const max_conditions = 31;

const Span = struct { start: u32, end: u32 };

const Decision = struct {
    span: Span,
    /// The conditions, in source order.
    leaves: []Span,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const src_path = args.next() orelse return error.Usage;
    const table_path = args.next() orelse return error.Usage;
    const rt_source = args.next() orelse return error.Usage;

    var src = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src.close(io);
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(gpa);
    var next_id: u32 = 0;

    var walker = try src.walk(gpa);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (paths.items) |path| {
        const skipped = for (skip) |s| {
            if (std.mem.eql(u8, path, s)) break true;
        } else false;
        if (skipped) continue;
        const source = try src.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(source);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const out = try transformFile(arena, source, path, &next_id, &table, gpa) orelse continue;
        try src.writeFile(io, .{ .sub_path = path, .data = out });
    }

    const rt = try std.Io.Dir.cwd().readFileAlloc(io, rt_source, gpa, .unlimited);
    defer gpa.free(rt);
    const rt_out = try std.fmt.allocPrint(gpa, "{s}\npub const decisions = {d};\n", .{ rt, next_id });
    defer gpa.free(rt_out);
    try src.writeFile(io, .{ .sub_path = "mcdc_rt.zig", .data = rt_out });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = table_path, .data = table.items });
    std.debug.print("mcdc: {d} decisions in {d} files\n", .{ next_id, paths.items.len });
}

/// Strips the parentheses around `n`.
fn unwrap(tree: *const Ast, n: Ast.Node.Index) Ast.Node.Index {
    var x = n;
    while (tree.nodeTag(x) == .grouped_expression) x = tree.nodeData(x).node_and_token[0];
    return x;
}

fn isBool(tree: *const Ast, n: Ast.Node.Index) bool {
    const t = tree.nodeTag(n);
    return t == .bool_and or t == .bool_or;
}

fn span(tree: *const Ast, n: Ast.Node.Index) Span {
    const first = tree.firstToken(n);
    const last = tree.lastToken(n);
    return .{
        .start = tree.tokenStart(first),
        .end = @intCast(tree.tokenStart(last) + tree.tokenSlice(last).len),
    };
}

/// Appends the conditions of the decision rooted at `n`.
fn collectLeaves(tree: *const Ast, arena: std.mem.Allocator, n: Ast.Node.Index, out: *std.ArrayList(Span)) !void {
    const x = unwrap(tree, n);
    if (isBool(tree, x)) {
        const lhs, const rhs = tree.nodeData(x).node_and_node;
        try collectLeaves(tree, arena, lhs, out);
        try collectLeaves(tree, arena, rhs, out);
    } else try out.append(arena, span(tree, n));
}

fn inside(s: Span, ranges: []const Span) bool {
    for (ranges) |r| if (s.start >= r.start and s.end <= r.end) return true;
    return false;
}

fn transformFile(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    path: []const u8,
    next_id: *u32,
    table: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !?[]const u8 {
    var tree = try Ast.parse(arena, source, .{ .recover = false });
    if (tree.errors.len > 0) return null;

    // Function bodies, where a decision runs at run time, and comptime
    // blocks and expressions, where it runs while compiling.
    var bodies: std.ArrayList(Span) = .empty;
    var comptimes: std.ArrayList(Span) = .empty;
    // Invariant checks, which the measure leaves out.
    var invariants: std.ArrayList(Span) = .empty;
    // Nodes that are a direct operand of `and` or `or`, which belong to
    // the decision above them.
    var operand: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    var candidates: std.ArrayList(Ast.Node.Index) = .empty;
    for (0..tree.nodes.len) |i| {
        const n: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(n)) {
            .fn_decl => {
                const proto, const body = tree.nodeData(n).node_and_node;
                try bodies.append(arena, span(&tree, body));
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, proto)) |fp| if (fp.name_token) |nt| {
                    for (checkers) |name| {
                        if (std.mem.eql(u8, tree.tokenSlice(nt), name)) try invariants.append(arena, span(&tree, body));
                    }
                };
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                var buf: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buf, n).?;
                const callee = span(&tree, call.ast.fn_expr);
                for (invariant_calls) |name| {
                    if (std.mem.eql(u8, source[callee.start..callee.end], name)) try invariants.append(arena, span(&tree, n));
                }
            },
            .@"comptime" => try comptimes.append(arena, span(&tree, n)),
            .bool_and, .bool_or => {
                try candidates.append(arena, n);
                const lhs, const rhs = tree.nodeData(n).node_and_node;
                try operand.put(arena, unwrap(&tree, lhs), {});
                try operand.put(arena, unwrap(&tree, rhs), {});
            },
            else => {},
        }
    }
    var decisions: std.ArrayList(Decision) = .empty;
    for (candidates.items) |n| {
        if (operand.contains(n)) continue;
        const s = span(&tree, n);
        if (!inside(s, bodies.items)) continue;
        if (inside(s, comptimes.items)) continue;
        if (inside(s, invariants.items)) continue;
        var leaves: std.ArrayList(Span) = .empty;
        try collectLeaves(&tree, arena, n, &leaves);
        if (leaves.items.len > max_conditions) continue;
        try decisions.append(arena, .{ .span = s, .leaves = leaves.items });
    }
    if (decisions.items.len == 0) return null;
    std.mem.sort(Decision, decisions.items, {}, struct {
        fn lt(_: void, a: Decision, b: Decision) bool {
            return a.span.start < b.span.start;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    var r: Renderer = .{
        .arena = arena,
        .source = source,
        .decisions = decisions.items,
        .next_id = next_id,
        .table = table,
        .gpa = gpa,
        .path = path,
    };
    try r.render(&out, 0, @intCast(source.len));
    // Every file reaches the runtime module through a path relative to it.
    const depth = std.mem.countScalar(u8, path, '/');
    try out.appendSlice(arena, "\nconst mcdc_rt = @import(\"");
    for (0..depth) |_| try out.appendSlice(arena, "../");
    try out.appendSlice(arena, "mcdc_rt.zig\");\n");
    return out.items;
}

const Renderer = struct {
    arena: std.mem.Allocator,
    source: [:0]const u8,
    decisions: []const Decision,
    next_id: *u32,
    table: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    path: []const u8,

    /// Copies the source between `start` and `end`, rewriting each
    /// decision that lies within it, outermost first.
    fn render(r: *Renderer, out: *std.ArrayList(u8), start: u32, end: u32) std.mem.Allocator.Error!void {
        var at = start;
        for (r.decisions) |d| {
            if (d.span.start < at or d.span.end > end) continue;
            try out.appendSlice(r.arena, r.source[at..d.span.start]);
            try r.decision(out, d);
            at = d.span.end;
        }
        try out.appendSlice(r.arena, r.source[at..end]);
    }

    fn decision(r: *Renderer, out: *std.ArrayList(u8), d: Decision) std.mem.Allocator.Error!void {
        r.next_id.* += 1;
        const id = r.next_id.*;
        const line = 1 + std.mem.countScalar(u8, r.source[0..d.span.start], '\n');
        try r.table.print(r.gpa, "{d} {s} {d} {d}\n", .{ id, r.path, line, d.leaves.len });
        try out.print(r.arena, "(mcdc_{d}: {{ var mcdc_v{d}: u64 = 0; const mcdc_r{d} = ", .{ id, id, id });
        var at = d.span.start;
        for (d.leaves, 0..) |leaf, k| {
            // The operators and parentheses between the conditions.
            try out.appendSlice(r.arena, r.source[at..leaf.start]);
            try out.print(r.arena, "mcdc_rt.c(&mcdc_v{d}, {d}, ", .{ id, k });
            try r.render(out, leaf.start, leaf.end);
            try out.appendSlice(r.arena, ")");
            at = leaf.end;
        }
        try out.appendSlice(r.arena, r.source[at..d.span.end]);
        try out.print(r.arena, "; mcdc_rt.d({d}, mcdc_v{d}, mcdc_r{d}); break :mcdc_{d} mcdc_r{d}; }})", .{ id, id, id, id, id });
    }
};
