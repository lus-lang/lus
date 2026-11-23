//! Code generation for query expressions.
//!
//! A query compiles into ordinary bytecode plus a plan string constant.
//! Clause expressions never run through an interpreter: they become
//! synthesized child functions compiled by the normal code generator.
//!
//! - The step function `(skip, rows...)` filters one tuple with the where
//!   clause. For an ungrouped query it returns `true`, the output record,
//!   and the order keys. For a grouped query it returns `true`, the group
//!   keys, and the argument of every aggregate. A filtered tuple returns
//!   `false`. Bit `i` of `skip` marks conjunct `i` as already applied by a
//!   provider that pushed it down.
//! - The final function `(rows..., aggregates...)` of a grouped query runs
//!   once per group with the group's first tuple and its aggregate values.
//!   It applies `having` and returns `true`, the record, and the order
//!   keys, or `false`.
//! - The window function `()` returns the limit and the offset.
//!
//! Scope names used in a clause are captured when the query is built: the
//! code evaluates each one into a hidden local, and the clause functions
//! read it as an upvalue that closes right after the build. Calls and
//! other suffixed expressions are host expressions, inlined into the clause
//! functions where row variables are parameters and every other name keeps
//! its live binding.
//!
//! The plan string describes what the runtime (`vm/query.zig`) needs: the
//! row variable names, the operand layout, the aggregates, the projection
//! names for `distinct`, and each where conjunct with the shape of its SQL
//! translation when one may exist. A conjunct that compares a column of
//! one source with a column of another for equality is a join, and the
//! plan names both columns, so that the runtime can find the matching
//! rows of the inner source through an index.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const codegen = @import("codegen.zig");

const I = codegen.Internal;
const FS = I.FS;
const Exp = I.Exp;
const Error = codegen.Error;

pub const max_sources = 8;

const NodeKind = union(enum) {
    lit: *ast.Expr,
    column: struct { src: u8, name: []const u8 },
    rowvar: u8,
    param: u32,
    host: *ast.Expr,
    nameref: []const u8,
    and_: [2]*Node,
    or_: [2]*Node,
    not_: *Node,
    neg: *Node,
    cmp: struct { op: ast.BinOp, a: *Node, b: *Node },
    arith: struct { op: ast.BinOp, a: *Node, b: *Node },
    concat: [2]*Node,
    agg: struct { func: ast.Aggregate, arg: ?*Node, slot: u32 },
};

const Node = struct {
    kind: NodeKind,
    line: u32,
};

const Item = struct {
    node: *Node,
    /// Field name in the record, or null for a whole-row item without a
    /// name.
    name: ?[]const u8,
    rowvar: bool,
};

const Agg = struct { func: ast.Aggregate, arg: ?*Node };

const Clause = enum { where, select, group, having, order, limit, offset };

const Ctx = struct {
    fs: *FS,
    q: *ast.Query,
    arena: std.mem.Allocator,
    line: u32,
    aliases: [][]const u8,
    /// Scope-name chains captured at build time, in order of appearance.
    params: std.ArrayList(*ast.Expr) = .empty,
    /// The name chain of each parameter, so that a chain that appears
    /// twice in a query is one parameter and its two uses are equal.
    param_chains: std.ArrayList([]const ast.Name) = .empty,
    aggs: std.ArrayList(Agg) = .empty,
    clause: Clause = .where,
    in_agg: bool = false,
    /// The projections, once `select` is lowered, so a bare name in
    /// `having` can name one of them.
    items: []const Item = &.{},

    fn err(c: *Ctx, line: u32, comptime fmt: []const u8, args: anytype) Error {
        return c.fs.c.err(line, fmt, args);
    }

    fn newNode(c: *Ctx, line: u32, kind: NodeKind) Error!*Node {
        const n = try c.arena.create(Node);
        n.* = .{ .kind = kind, .line = line };
        return n;
    }

    fn rowIndex(c: *Ctx, name: []const u8) ?u8 {
        for (c.aliases, 0..) |a, i| {
            if (std.mem.eql(u8, a, name)) return @intCast(i);
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Synthesized syntax

    fn mk(c: *Ctx, line: u32, kind: ast.Expr.Kind) Error!*ast.Expr {
        const e = try c.arena.create(ast.Expr);
        e.* = .{ .span = c.q.span, .line = line, .kind = kind };
        return e;
    }

    fn nameE(c: *Ctx, line: u32, text: []const u8) Error!*ast.Expr {
        return c.mk(line, .{ .name = .{ .text = text, .span = c.q.span } });
    }

    fn strE(c: *Ctx, line: u32, s: []const u8) Error!*ast.Expr {
        return c.mk(line, .{ .string = s });
    }

    fn intE(c: *Ctx, line: u32, v: i64) Error!*ast.Expr {
        return c.mk(line, .{ .integer = v });
    }

    fn binE(c: *Ctx, line: u32, op: ast.BinOp, a: *ast.Expr, b: *ast.Expr) Error!*ast.Expr {
        return c.mk(line, .{ .binop = .{ .op = op, .lhs = a, .rhs = b } });
    }

    fn fieldE(c: *Ctx, line: u32, obj: *ast.Expr, name: []const u8) Error!*ast.Expr {
        return c.mk(line, .{ .index = .{ .obj = obj, .key = try c.strE(line, name), .dot = true } });
    }

    fn parenE(c: *Ctx, e: *ast.Expr) Error!*ast.Expr {
        return c.mk(e.line, .{ .paren = e });
    }

    fn stat(c: *Ctx, line: u32, kind: ast.Stat.Kind) Error!*ast.Stat {
        const s = try c.arena.create(ast.Stat);
        s.* = .{ .span = c.q.span, .line = line, .kind = kind };
        return s;
    }

    fn blockOf(c: *Ctx, stats: []*ast.Stat) Error!*ast.Block {
        const b = try c.arena.create(ast.Block);
        b.* = .{ .stats = stats, .span = c.q.span, .end_line = c.line };
        return b;
    }

    fn names(c: *Ctx, texts: []const []const u8) Error![]ast.Name {
        const out = try c.arena.alloc(ast.Name, texts.len);
        for (texts, out) |t, *n| n.* = .{ .text = t, .span = c.q.span };
        return out;
    }

    fn attNames(c: *Ctx, texts: []const []const u8) Error![]ast.AttName {
        const out = try c.arena.alloc(ast.AttName, texts.len);
        for (texts, out) |t, *n| n.* = .{ .name = .{ .text = t, .span = c.q.span } };
        return out;
    }

    fn function(c: *Ctx, params: []const []const u8, stats: []*ast.Stat) Error!*ast.Function {
        const f = try c.arena.create(ast.Function);
        f.* = .{
            .params = try c.names(params),
            .is_vararg = false,
            .body = try c.blockOf(stats),
            .line = c.line,
            .end_line = c.line,
            .span = c.q.span,
            .name = "query",
        };
        return f;
    }

    fn hidden(c: *Ctx, comptime prefix: []const u8, i: usize) Error![]const u8 {
        return std.fmt.allocPrint(c.arena, "(" ++ prefix ++ "{d})", .{i});
    }

    // -----------------------------------------------------------------
    // Lowering clause expressions into plan nodes

    fn chainExpr(c: *Ctx, line: u32, chain: []const ast.Name) Error!*ast.Expr {
        var e = try c.nameE(line, chain[0].text);
        for (chain[1..]) |n| e = try c.fieldE(line, e, n.text);
        return e;
    }

    fn lower(c: *Ctx, qe: *ast.QExpr) Error!*Node {
        const line = qe.line;
        switch (qe.kind) {
            .literal => |e| return c.newNode(line, .{ .lit = e }),
            .paren => |inner| return c.lower(inner),
            .host => |e| return c.newNode(line, .{ .host = e }),
            .chain => |chain| {
                const head = chain[0].text;
                if (c.rowIndex(head)) |src| {
                    if (chain.len == 1) return c.newNode(line, .{ .rowvar = src });
                    if (chain.len == 2) return c.newNode(line, .{ .column = .{ .src = src, .name = chain[1].text } });
                    // A deeper row chain runs as a host expression.
                    return c.newNode(line, .{ .host = try c.chainExpr(line, chain) });
                }
                if (c.clause == .order and chain.len == 1) {
                    // A bare name in 'order by' names a projection field.
                    return c.newNode(line, .{ .nameref = head });
                }
                if (c.clause == .having and chain.len == 1) {
                    // A bare name in 'having' that names a projection
                    // stands for the expression of that projection.
                    for (c.items) |it| {
                        if (it.name) |n| if (std.mem.eql(u8, n, head)) return it.node;
                    }
                }
                for (c.param_chains.items, 0..) |pc, i| {
                    if (sameChain(pc, chain)) return c.newNode(line, .{ .param = @intCast(i) });
                }
                const idx: u32 = @intCast(c.params.items.len);
                try c.params.append(c.arena, try c.chainExpr(line, chain));
                try c.param_chains.append(c.arena, chain);
                return c.newNode(line, .{ .param = idx });
            },
            .unop => |u| {
                const operand = try c.lower(u.operand);
                return switch (u.op) {
                    .neg => c.newNode(line, .{ .neg = operand }),
                    .not => c.newNode(line, .{ .not_ = operand }),
                    else => c.err(line, "operator not supported in a query clause", .{}),
                };
            },
            .binop => |b| {
                const lhs = try c.lower(b.lhs);
                const rhs = try c.lower(b.rhs);
                return switch (b.op) {
                    .@"and" => c.newNode(line, .{ .and_ = .{ lhs, rhs } }),
                    .@"or" => c.newNode(line, .{ .or_ = .{ lhs, rhs } }),
                    .eq, .ne, .lt, .le, .gt, .ge => c.newNode(line, .{ .cmp = .{ .op = b.op, .a = lhs, .b = rhs } }),
                    .add, .sub, .mul, .div, .idiv, .mod, .pow => c.newNode(line, .{ .arith = .{ .op = b.op, .a = lhs, .b = rhs } }),
                    .concat => c.newNode(line, .{ .concat = .{ lhs, rhs } }),
                    else => c.err(line, "operator not supported in a query clause", .{}),
                };
            },
            .aggregate => |a| {
                if (c.clause != .select and c.clause != .having) {
                    return c.err(line, "aggregate '{s}' is only allowed in 'select' or 'having'", .{@tagName(a.func)});
                }
                if (c.in_agg) return c.err(line, "aggregates cannot nest", .{});
                var arg: ?*Node = null;
                if (a.arg) |ae| {
                    c.in_agg = true;
                    defer c.in_agg = false;
                    arg = try c.lower(ae);
                }
                const slot: u32 = @intCast(c.aggs.items.len);
                try c.aggs.append(c.arena, .{ .func = a.func, .arg = arg });
                return c.newNode(line, .{ .agg = .{ .func = a.func, .arg = arg, .slot = slot } });
            },
        }
    }
};

// ---------------------------------------------------------------------
// Static analysis

fn usesRow(n: *const Node) bool {
    return switch (n.kind) {
        .column, .rowvar, .host, .nameref, .agg => true,
        .lit, .param => false,
        .and_, .or_, .concat => |p| usesRow(p[0]) or usesRow(p[1]),
        .not_, .neg => |a| usesRow(a),
        .cmp => |x| usesRow(x.a) or usesRow(x.b),
        .arith => |x| usesRow(x.a) or usesRow(x.b),
    };
}

fn hasAgg(n: *const Node) bool {
    return switch (n.kind) {
        .agg => true,
        .lit, .param, .column, .rowvar, .host, .nameref => false,
        .and_, .or_, .concat => |p| hasAgg(p[0]) or hasAgg(p[1]),
        .not_, .neg => |a| hasAgg(a),
        .cmp => |x| hasAgg(x.a) or hasAgg(x.b),
        .arith => |x| hasAgg(x.a) or hasAgg(x.b),
    };
}

/// Sources referenced by a conjunct, and whether it holds a host
/// expression (which sees every row).
fn shape(n: *const Node, mask: *u32, opaque_: *bool) void {
    switch (n.kind) {
        .column => |col| mask.* |= @as(u32, 1) << @intCast(col.src),
        .rowvar => |src| mask.* |= @as(u32, 1) << @intCast(src),
        .host => {
            opaque_.* = true;
            mask.* = 0xff;
        },
        .and_, .or_, .concat => |p| {
            shape(p[0], mask, opaque_);
            shape(p[1], mask, opaque_);
        },
        .not_, .neg => |a| shape(a, mask, opaque_),
        .cmp => |x| {
            shape(x.a, mask, opaque_);
            shape(x.b, mask, opaque_);
        },
        .arith => |x| {
            shape(x.a, mask, opaque_);
            shape(x.b, mask, opaque_);
        },
        .agg => |a| if (a.arg) |x| shape(x, mask, opaque_),
        .lit, .param, .nameref => {},
    }
}

fn litEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    return switch (a.kind) {
        .nil, .true, .false => true,
        .integer => |v| v == b.kind.integer,
        .float => |v| v == b.kind.float,
        .string => |s| std.mem.eql(u8, s, b.kind.string),
        .bigint => |s| std.mem.eql(u8, s, b.kind.bigint),
        .decimal => |s| std.mem.eql(u8, s, b.kind.decimal),
        else => false,
    };
}

/// Whether two host expressions read the same value: names, field paths,
/// and literals, which read the same value wherever they appear in one
/// query. Any other expression equals only itself.
fn hostEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (a == b) return true;
    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    return switch (a.kind) {
        .name => |n| std.mem.eql(u8, n.text, b.kind.name.text),
        .paren => |e| hostEqual(e, b.kind.paren),
        .index => |ix| hostEqual(ix.obj, b.kind.index.obj) and hostEqual(ix.key, b.kind.index.key),
        else => litEqual(a, b),
    };
}

fn sameChain(a: []const ast.Name, b: []const ast.Name) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.text, y.text)) return false;
    return true;
}

/// Structural equality, used to match projections against group keys.
fn nodeEqual(a: *const Node, b: *const Node) bool {
    if (a == b) return true;
    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    return switch (a.kind) {
        .lit => |x| litEqual(x, b.kind.lit),
        .column => |x| x.src == b.kind.column.src and std.mem.eql(u8, x.name, b.kind.column.name),
        .rowvar => |x| x == b.kind.rowvar,
        .param => |x| x == b.kind.param,
        .host => |x| hostEqual(x, b.kind.host),
        .nameref => |x| std.mem.eql(u8, x, b.kind.nameref),
        .and_ => |x| nodeEqual(x[0], b.kind.and_[0]) and nodeEqual(x[1], b.kind.and_[1]),
        .or_ => |x| nodeEqual(x[0], b.kind.or_[0]) and nodeEqual(x[1], b.kind.or_[1]),
        .concat => |x| nodeEqual(x[0], b.kind.concat[0]) and nodeEqual(x[1], b.kind.concat[1]),
        .not_ => |x| nodeEqual(x, b.kind.not_),
        .neg => |x| nodeEqual(x, b.kind.neg),
        .cmp => |x| x.op == b.kind.cmp.op and nodeEqual(x.a, b.kind.cmp.a) and nodeEqual(x.b, b.kind.cmp.b),
        .arith => |x| x.op == b.kind.arith.op and nodeEqual(x.a, b.kind.arith.a) and nodeEqual(x.b, b.kind.arith.b),
        .agg => |x| blk: {
            const y = b.kind.agg;
            if (x.func != y.func) break :blk false;
            if ((x.arg == null) != (y.arg == null)) break :blk false;
            break :blk x.arg == null or nodeEqual(x.arg.?, y.arg.?);
        },
    };
}

/// In a grouped query an expression is valid when every row reference in
/// it sits inside an aggregate or the whole expression matches a group key.
fn groupValid(n: *const Node, keys: []const *Node) bool {
    for (keys) |k| if (nodeEqual(n, k)) return true;
    return switch (n.kind) {
        .agg, .lit, .param, .nameref => true,
        .column, .rowvar, .host => false,
        .and_, .or_, .concat => |p| groupValid(p[0], keys) and groupValid(p[1], keys),
        .not_, .neg => |a| groupValid(a, keys),
        .cmp => |x| groupValid(x.a, keys) and groupValid(x.b, keys),
        .arith => |x| groupValid(x.a, keys) and groupValid(x.b, keys),
    };
}

fn splitConjuncts(c: *Ctx, n: *Node, out: *std.ArrayList(*Node)) Error!void {
    switch (n.kind) {
        .and_ => |p| {
            try splitConjuncts(c, p[0], out);
            try splitConjuncts(c, p[1], out);
        },
        else => try out.append(c.arena, n),
    }
}

// ---------------------------------------------------------------------
// Clause expressions to syntax

/// True for operands that are cheap and free of side effects, so a
/// comparison may read them twice.
fn simple(n: *const Node) bool {
    return switch (n.kind) {
        .lit, .column, .rowvar, .param, .nameref => true,
        else => false,
    };
}

fn nonNilLit(n: *const Node) bool {
    return n.kind == .lit and n.kind.lit.kind != .nil;
}

fn nilLit(n: *const Node) bool {
    return n.kind == .lit and n.kind.lit.kind == .nil;
}

fn toExpr(c: *Ctx, n: *const Node) Error!*ast.Expr {
    const line = n.line;
    return switch (n.kind) {
        .lit => |e| e,
        .column => |col| c.fieldE(line, try c.nameE(line, c.aliases[col.src]), col.name),
        .rowvar => |src| c.nameE(line, c.aliases[src]),
        .param => |i| c.nameE(line, try c.hidden("qp", i)),
        .host => |e| c.parenE(e),
        .nameref => |s| c.fieldE(line, try c.nameE(line, "(rec)"), s),
        .and_ => |p| c.binE(line, .@"and", try toExpr(c, p[0]), try toExpr(c, p[1])),
        .or_ => |p| c.binE(line, .@"or", try toExpr(c, p[0]), try toExpr(c, p[1])),
        .not_ => |a| c.mk(line, .{ .unop = .{ .op = .not, .operand = try toExpr(c, a) } }),
        .neg => |a| c.mk(line, .{ .unop = .{ .op = .neg, .operand = try toExpr(c, a) } }),
        .arith => |x| c.binE(line, x.op, try toExpr(c, x.a), try toExpr(c, x.b)),
        .concat => |p| c.binE(line, .concat, try toExpr(c, p[0]), try toExpr(c, p[1])),
        .agg => |a| c.nameE(line, try c.hidden("a", a.slot)),
        .cmp => |x| cmpExpr(c, line, x.op, x.a, x.b),
    };
}

/// A comparison with a nil operand is false, whatever the operator.
fn cmpExpr(c: *Ctx, line: u32, op: ast.BinOp, a: *const Node, b: *const Node) Error!*ast.Expr {
    const nil_e = try c.mk(line, .nil);
    if (simple(a) and simple(b)) {
        if (nilLit(a) or nilLit(b)) return c.mk(line, .false);
        const ea = try toExpr(c, a);
        const eb = try toExpr(c, b);
        const plain = try c.binE(line, op, ea, eb);
        // Equality with a non-nil constant is already false for nil.
        if (op == .eq and (nonNilLit(a) or nonNilLit(b))) return plain;
        var guarded = plain;
        if (!nonNilLit(b)) guarded = try c.binE(line, .@"and", try c.binE(line, .ne, try toExpr(c, b), nil_e), guarded);
        if (!nonNilLit(a)) guarded = try c.binE(line, .@"and", try c.binE(line, .ne, try toExpr(c, a), nil_e), guarded);
        return guarded;
    }
    // General operands are evaluated once into hidden locals of a
    // do-expression.
    const xs = "(x)";
    const ys = "(y)";
    const decl = try c.stat(line, .{ .local = .{
        .names = try c.attNames(&.{ xs, ys }),
        .values = try c.arena.dupe(*ast.Expr, &.{ try toExpr(c, a), try toExpr(c, b) }),
    } });
    var res = try c.binE(line, op, try c.nameE(line, xs), try c.nameE(line, ys));
    res = try c.binE(line, .@"and", try c.binE(line, .ne, try c.nameE(line, ys), nil_e), res);
    res = try c.binE(line, .@"and", try c.binE(line, .ne, try c.nameE(line, xs), nil_e), res);
    const prov = try c.stat(line, .{ .provide = try c.arena.dupe(*ast.Expr, &.{res}) });
    return c.mk(line, .{ .do_ = try c.blockOf(try c.arena.dupe(*ast.Stat, &.{ decl, prov })) });
}

// ---------------------------------------------------------------------
// Plan string

const PlanWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    fn int(w: *PlanWriter, v: i64) Error!void {
        try w.buf.print(w.arena, "{d} ", .{v});
    }
    fn str(w: *PlanWriter, s: []const u8) Error!void {
        try w.buf.print(w.arena, "{d}:", .{s.len});
        try w.buf.appendSlice(w.arena, s);
        try w.buf.append(w.arena, ' ');
    }
    fn tag(w: *PlanWriter, t: u8) Error!void {
        try w.buf.append(w.arena, t);
        try w.buf.append(w.arena, ' ');
    }
};

/// Can this value-level node translate to SQL with identical semantics?
/// Parameters are checked again at run time, when their values are known.
fn sqlValue(n: *const Node) bool {
    return switch (n.kind) {
        .column, .param => true,
        .lit => |e| switch (e.kind) {
            .nil, .integer, .float, .string => true,
            else => false,
        },
        .arith => |x| switch (x.op) {
            .add, .sub, .mul => sqlValue(x.a) and sqlValue(x.b),
            else => false,
        },
        .neg => |a| sqlValue(a),
        .concat => |p| sqlValue(p[0]) and sqlValue(p[1]),
        else => false,
    };
}

/// Whether a limit or offset node is absent, a literal, or a captured
/// value, so that reading it raises nothing and runs nothing.
fn plainWindow(n: ?*const Node) bool {
    const x = n orelse return true;
    return switch (x.kind) {
        .lit, .param => true,
        else => false,
    };
}

/// Whether `n` compares a column of one source with a column of another
/// for equality.
fn isJoin(n: *const Node) bool {
    const x = switch (n.kind) {
        .cmp => |x| x,
        else => return false,
    };
    if (x.op != .eq) return false;
    const a = switch (x.a.kind) {
        .column => |col| col,
        else => return false,
    };
    const b = switch (x.b.kind) {
        .column => |col| col,
        else => return false,
    };
    return a.src != b.src;
}

fn sqlBool(n: *const Node) bool {
    return switch (n.kind) {
        .cmp => |x| sqlValue(x.a) and sqlValue(x.b),
        .and_, .or_ => |p| sqlBool(p[0]) and sqlBool(p[1]),
        else => false,
    };
}

const SqlOps = struct {
    /// Operand index of each parameter that a SQL translation reads.
    param_ops: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty,
    next: u32,
};

fn writeSql(c: *Ctx, w: *PlanWriter, n: *const Node, ops: *SqlOps) Error!void {
    switch (n.kind) {
        .column => |col| {
            try w.tag('C');
            try w.str(col.name);
        },
        .param => |p| {
            const gop = try ops.param_ops.getOrPut(c.arena, p);
            if (!gop.found_existing) {
                gop.value_ptr.* = ops.next;
                ops.next += 1;
            }
            try w.tag('P');
            try w.int(gop.value_ptr.*);
        },
        .lit => |e| switch (e.kind) {
            .nil => try w.tag('N'),
            .integer => |v| {
                try w.tag('I');
                try w.int(v);
            },
            .float => |v| {
                try w.tag('F');
                try w.int(@bitCast(v));
            },
            .string => |s| {
                try w.tag('S');
                try w.str(s);
            },
            else => unreachable,
        },
        .cmp => |x| {
            try w.tag(switch (x.op) {
                .eq => 'E',
                .ne => 'D',
                .lt => 'L',
                .le => 'M',
                .gt => 'G',
                .ge => 'H',
                else => unreachable,
            });
            try writeSql(c, w, x.a, ops);
            try writeSql(c, w, x.b, ops);
        },
        .and_, .or_ => |p| {
            try w.tag(if (n.kind == .and_) 'A' else 'O');
            try writeSql(c, w, p[0], ops);
            try writeSql(c, w, p[1], ops);
        },
        .arith => |x| {
            try w.tag(switch (x.op) {
                .add => 'a',
                .sub => 's',
                .mul => 'm',
                else => unreachable,
            });
            try writeSql(c, w, x.a, ops);
            try writeSql(c, w, x.b, ops);
        },
        .neg => |a| {
            try w.tag('u');
            try writeSql(c, w, a, ops);
        },
        .concat => |p| {
            try w.tag('c');
            try writeSql(c, w, p[0], ops);
            try writeSql(c, w, p[1], ops);
        },
        else => unreachable,
    }
}

// Plan flag bits, shared with vm/query.zig.
pub const flag_grouped = 1;
pub const flag_distinct = 2;
pub const flag_limit = 4;
pub const flag_offset = 8;
pub const flag_rec_err = 16;
/// The limit and the offset are literals or captured values, which the
/// runtime may read before the rows arrive.
pub const flag_plain_window = 32;

pub const agg_codes = struct {
    pub const count_star = 0;
    pub const count = 1;
    pub const sum = 2;
    pub const avg = 3;
    pub const min = 4;
    pub const max = 5;
};

fn aggCode(a: Agg) i64 {
    return switch (a.func) {
        .count => if (a.arg == null) agg_codes.count_star else agg_codes.count,
        .sum => agg_codes.sum,
        .avg => agg_codes.avg,
        .min => agg_codes.min,
        .max => agg_codes.max,
    };
}

// ---------------------------------------------------------------------
// Entry point

/// The number of conjuncts a plan lists. `vm/query.zig` rejects a plan with
/// more.
pub const max_conjuncts = 256;

/// The number of conjuncts the skip mask covers. `vm/query.zig` sets the bit
/// of conjunct `i` only when `i` is below this.
pub const max_skip_bits = 63;

pub fn queryExpr(fs: *FS, q: *ast.Query, v: *Exp) Error!void {
    const line = fs.line;
    var c: Ctx = .{
        .fs = fs,
        .q = q,
        .arena = fs.c.arena,
        .line = line,
        .aliases = try fs.c.arena.alloc([]const u8, q.sources.len),
    };
    for (q.sources, c.aliases) |s, *a| a.* = s.alias.text;
    const nsrc = q.sources.len;

    // Lower every clause into plan nodes.
    var conjuncts: std.ArrayList(*Node) = .empty;
    if (q.where) |w| {
        c.clause = .where;
        try splitConjuncts(&c, try c.lower(w), &conjuncts);
        // The plan lists at most `max_conjuncts` conjuncts. The rest join
        // the last one, which keeps the condition and its evaluation order.
        if (conjuncts.items.len > max_conjuncts) {
            const tail = conjuncts.items[max_conjuncts - 1 ..];
            var merged = tail[0];
            for (tail[1..]) |n| merged = try c.newNode(n.line, .{ .and_ = .{ merged, n } });
            conjuncts.shrinkRetainingCapacity(max_conjuncts - 1);
            try conjuncts.append(c.arena, merged);
        }
    }
    var items: std.ArrayList(Item) = .empty;
    if (q.select) |sel| {
        c.clause = .select;
        for (sel) |it| {
            const n = try c.lower(it.expr);
            if (it.alias) |a| {
                try items.append(c.arena, .{ .node = n, .name = a.text, .rowvar = false });
            } else switch (n.kind) {
                .rowvar => try items.append(c.arena, .{ .node = n, .name = null, .rowvar = true }),
                .column => |col| try items.append(c.arena, .{ .node = n, .name = col.name, .rowvar = false }),
                else => return c.err(it.expr.line, "'as' name expected for this projection", .{}),
            }
        }
    }
    var keys: std.ArrayList(*Node) = .empty;
    if (q.group_by) |g| {
        c.clause = .group;
        for (g) |k| try keys.append(c.arena, try c.lower(k));
    }
    var having: ?*Node = null;
    if (q.having) |h| {
        c.clause = .having;
        c.items = items.items;
        having = try c.lower(h);
    }
    var order: std.ArrayList(*Node) = .empty;
    if (q.order_by) |ob| {
        c.clause = .order;
        for (ob) |o| try order.append(c.arena, try c.lower(o.expr));
    }
    var limit: ?*Node = null;
    if (q.limit) |e| {
        c.clause = .limit;
        limit = try c.lower(e);
        if (usesRow(limit.?)) return c.err(e.line, "query limit must be row-independent", .{});
    }
    var offset: ?*Node = null;
    if (q.offset) |e| {
        c.clause = .offset;
        offset = try c.lower(e);
        if (usesRow(offset.?)) return c.err(e.line, "query offset must be row-independent", .{});
    }

    // Shape of the pipeline and the errors the runtime raises.
    var grouped = keys.items.len > 0 or (having != null and hasAgg(having.?));
    for (items.items) |it| {
        if (hasAgg(it.node)) grouped = true;
    }
    var deferred: []const u8 = "";
    if (grouped) {
        for (items.items) |it| {
            if (!groupValid(it.node, keys.items)) {
                deferred = "a grouped projection must be an aggregate or a group key";
                break;
            }
        }
        if (deferred.len == 0 and having != null and !groupValid(having.?, keys.items)) deferred = "'having' must use aggregates or group keys";
        if (deferred.len == 0 and items.items.len == 0) deferred = "a grouped query needs a 'select' clause";
    }
    const lone_row = items.items.len == 1 and items.items[0].rowvar;
    var rec_err = false;
    if (items.items.len > 1) {
        for (items.items) |it| {
            if (it.name == null) rec_err = true;
        }
    }

    // Classify the conjuncts.
    const Conj = struct { node: *Node, mask: u32, opaque_: bool, sql: bool, join: bool };
    const conj = try c.arena.alloc(Conj, conjuncts.items.len);
    for (conjuncts.items, conj, 0..) |n, *cj, i| {
        var mask: u32 = 0;
        var opq = false;
        shape(n, &mask, &opq);
        const single = mask != 0 and (mask & (mask - 1)) == 0;
        // The skip mask of the step function is an integer with one bit for
        // each of the first 63 conjuncts, so only those may move into SQL.
        const skippable = i < max_skip_bits;
        cj.* = .{ .node = n, .mask = mask, .opaque_ = opq, .sql = !opq and single and skippable and sqlBool(n), .join = isJoin(n) };
    }

    // Synthesize the clause functions.
    const rec_name = "(rec)";
    var record: *ast.Expr = undefined;
    if (rec_err) {
        record = try c.mk(line, .nil);
    } else if (items.items.len == 0) {
        record = try c.nameE(line, c.aliases[0]);
    } else if (lone_row) {
        record = try toExpr(&c, items.items[0].node);
    } else {
        const fields = try c.arena.alloc(ast.Field, items.items.len);
        for (items.items, fields) |it, *f| {
            f.* = .{ .kind = .{ .keyed = .{ .key = try c.strE(it.node.line, it.name.?), .value = try c.parenE(try toExpr(&c, it.node)) } } };
        }
        record = try c.mk(line, .{ .table = fields });
    }
    // Statements producing `true, record, order keys...`.
    const emitRecord = struct {
        fn f(cx: *Ctx, rec: *ast.Expr, ord: []const *Node, rn: []const u8) Error![]*ast.Stat {
            var stats: std.ArrayList(*ast.Stat) = .empty;
            var rets: std.ArrayList(*ast.Expr) = .empty;
            try rets.append(cx.arena, try cx.mk(cx.line, .true));
            if (ord.len > 0) {
                try stats.append(cx.arena, try cx.stat(cx.line, .{ .local = .{
                    .names = try cx.attNames(&.{rn}),
                    .values = try cx.arena.dupe(*ast.Expr, &.{rec}),
                } }));
                try rets.append(cx.arena, try cx.nameE(cx.line, rn));
                for (ord) |o| try rets.append(cx.arena, try cx.parenE(try toExpr(cx, o)));
            } else {
                try rets.append(cx.arena, try cx.parenE(rec));
            }
            try stats.append(cx.arena, try cx.stat(cx.line, .{ .return_ = try rets.toOwnedSlice(cx.arena) }));
            return stats.toOwnedSlice(cx.arena);
        }
    }.f;
    const guarded = struct {
        fn f(cx: *Ctx, cond: ?*ast.Expr, body: []*ast.Stat) Error![]*ast.Stat {
            const ret_false = try cx.stat(cx.line, .{ .return_ = try cx.arena.dupe(*ast.Expr, &.{try cx.mk(cx.line, .false)}) });
            const cnd = cond orelse return body;
            const clauses = try cx.arena.alloc(ast.IfClause, 1);
            clauses[0] = .{ .cond = .{ .expr = cnd }, .body = try cx.blockOf(body), .line = cx.line };
            const ifs = try cx.stat(cx.line, .{ .if_ = .{ .clauses = clauses, .else_ = null } });
            return cx.arena.dupe(*ast.Stat, &.{ ifs, ret_false });
        }
    }.f;

    // The where condition, with a skip test on every conjunct a provider
    // may push down.
    var cond: ?*ast.Expr = null;
    for (conj, 0..) |cj, i| {
        var e = try toExpr(&c, cj.node);
        if (cj.sql) {
            const bit = try c.binE(line, .band, try c.nameE(line, "(skip)"), try c.intE(line, @as(i64, 1) << @intCast(i)));
            e = try c.binE(line, .@"or", try c.binE(line, .ne, bit, try c.intE(line, 0)), e);
        }
        cond = if (cond) |prev| try c.binE(line, .@"and", prev, e) else e;
    }

    var step_params: std.ArrayList([]const u8) = .empty;
    try step_params.append(c.arena, "(skip)");
    try step_params.appendSlice(c.arena, c.aliases);
    var step_fn: *ast.Function = undefined;
    var final_fn: ?*ast.Function = null;
    if (!grouped) {
        step_fn = try c.function(step_params.items, try guarded(&c, cond, try emitRecord(&c, record, order.items, rec_name)));
    } else {
        var rets: std.ArrayList(*ast.Expr) = .empty;
        try rets.append(c.arena, try c.mk(line, .true));
        for (keys.items) |k| try rets.append(c.arena, try c.parenE(try toExpr(&c, k)));
        for (c.aggs.items) |a| {
            if (a.arg) |arg| try rets.append(c.arena, try c.parenE(try toExpr(&c, arg)));
        }
        const ret = try c.stat(line, .{ .return_ = try rets.toOwnedSlice(c.arena) });
        step_fn = try c.function(step_params.items, try guarded(&c, cond, try c.arena.dupe(*ast.Stat, &.{ret})));

        var final_params: std.ArrayList([]const u8) = .empty;
        try final_params.appendSlice(c.arena, c.aliases);
        for (0..c.aggs.items.len) |j| try final_params.append(c.arena, try c.hidden("a", j));
        const hcond: ?*ast.Expr = if (having) |h| try toExpr(&c, h) else null;
        final_fn = try c.function(final_params.items, try guarded(&c, hcond, try emitRecord(&c, record, order.items, rec_name)));
    }
    var lo_fn: ?*ast.Function = null;
    if (limit != null or offset != null) {
        const le = if (limit) |n| try c.parenE(try toExpr(&c, n)) else try c.mk(line, .nil);
        const oe = if (offset) |n| try c.parenE(try toExpr(&c, n)) else try c.mk(line, .nil);
        const ret = try c.stat(line, .{ .return_ = try c.arena.dupe(*ast.Expr, &.{ le, oe }) });
        lo_fn = try c.function(&.{}, try c.arena.dupe(*ast.Stat, &.{ret}));
    }

    // Operand layout: the clause functions, then the parameters that SQL
    // translations read.
    const op_step: i64 = 0;
    var nfn: u32 = 1;
    const op_final: i64 = if (final_fn != null) blk: {
        nfn += 1;
        break :blk nfn - 1;
    } else -1;
    const op_lo: i64 = if (lo_fn != null) blk: {
        nfn += 1;
        break :blk nfn - 1;
    } else -1;

    var w: PlanWriter = .{ .arena = c.arena };
    var sqlops: SqlOps = .{ .next = nfn };
    var conj_buf: PlanWriter = .{ .arena = c.arena };
    for (conj) |cj| {
        try conj_buf.int(cj.mask);
        try conj_buf.int(@intFromBool(cj.opaque_));
        if (cj.sql) {
            try writeSql(&c, &conj_buf, cj.node, &sqlops);
        } else if (cj.join) {
            const x = cj.node.kind.cmp;
            try conj_buf.tag('J');
            try conj_buf.int(x.a.kind.column.src);
            try conj_buf.str(x.a.kind.column.name);
            try conj_buf.int(x.b.kind.column.src);
            try conj_buf.str(x.b.kind.column.name);
        } else try conj_buf.tag('X');
    }
    const nops = sqlops.next;

    try w.buf.appendSlice(c.arena, "Q1 ");
    try w.int(@intCast(nsrc));
    try w.int(nops);
    var flags: i64 = 0;
    if (grouped) flags |= flag_grouped;
    if (q.distinct) flags |= flag_distinct;
    if (limit != null) flags |= flag_limit;
    if (offset != null) flags |= flag_offset;
    if (rec_err) flags |= flag_rec_err;
    if ((limit != null or offset != null) and plainWindow(limit) and plainWindow(offset)) flags |= flag_plain_window;
    try w.int(flags);
    try w.int(op_step);
    try w.int(op_final);
    try w.int(op_lo);
    try w.str(deferred);
    try w.int(@intCast(keys.items.len));
    try w.int(@intCast(c.aggs.items.len));
    for (c.aggs.items) |a| try w.int(aggCode(a));
    try w.int(@intCast(order.items.len));
    if (q.order_by) |ob| for (ob) |o| try w.int(@intFromBool(o.desc));
    try w.int(@intCast(items.items.len));
    for (items.items) |it| {
        if (it.name) |n| {
            try w.int(1);
            try w.str(n);
        } else try w.int(0);
    }
    try w.int(@intCast(conj.len));
    try w.buf.appendSlice(c.arena, conj_buf.buf.items);
    for (c.aliases) |a| try w.str(a);

    // Emit: hidden locals for the captured parameters, then the run of
    // sources and operands, then the query instruction.
    const base = fs.freereg;
    const has_params = c.params.items.len > 0;
    var bl: I.BlockCnt = undefined;
    const saved_floor = fs.reg_floor;
    if (has_params) {
        fs.reg_floor = fs.freereg;
        I.openBlock(fs, &bl, false);
        for (c.params.items, 0..) |pe, i| {
            _ = try I.declareLocal(fs, try c.hidden("qp", i), .regular);
            var e: Exp = .{};
            try I.genExpr(fs, pe, &e);
            try I.toNextReg(fs, &e);
            try I.activateLocals(fs, 1);
        }
    }
    const ra = fs.freereg;
    try I.reserve(fs, 1);
    for (q.sources) |s| {
        var e: Exp = .{};
        try I.genExpr(fs, s.expr, &e);
        try I.toNextReg(fs, &e);
    }
    var fe: Exp = .{};
    try I.genFunction(fs, step_fn, &fe);
    if (final_fn) |f| try I.genFunction(fs, f, &fe);
    if (lo_fn) |f| try I.genFunction(fs, f, &fe);
    var it = sqlops.param_ops.iterator();
    while (it.next()) |entry| {
        var e: Exp = .{};
        try I.genExpr(fs, try c.nameE(line, try c.hidden("qp", entry.key_ptr.*)), &e);
        try I.toNextReg(fs, &e);
    }
    fs.line = line;
    const k = try I.constString(fs, w.buf.items);
    _ = try I.emitBx(fs, .query, ra, k);
    if (has_params) {
        try I.closeBlock(fs);
        fs.reg_floor = saved_floor;
        try I.emitAbc(fs, .move, base, ra, 0);
    }
    fs.freereg = base;
    try I.reserve(fs, 1);
    v.* = .{ .kind = .nonreloc, .info = base };
}
