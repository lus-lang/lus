//! Generic traversal of the syntax tree. `visitExprs` calls a function on
//! every expression slot (as a pointer to the slot, so visitors can
//! replace nodes), children before parents.

const std = @import("std");
const ast = @import("ast.zig");

pub fn Visitor(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        func: *const fn (Ctx, **ast.Expr) anyerror!void,

        const Self = @This();

        pub fn block(v: Self, b: *ast.Block) anyerror!void {
            for (b.stats) |s| try v.stat(s);
        }

        fn exprs(v: Self, list: []*ast.Expr) anyerror!void {
            for (list) |*e| try v.slot(e);
        }

        fn cond(v: Self, c: *ast.Cond) anyerror!void {
            switch (c.*) {
                .expr => |*e| try v.slot(e),
                .assign => |a| try v.exprs(a.values),
                .from => |*f| try v.slot(&f.source),
                .group => |g| for (g.inits) |init| try v.groupInit(init),
            }
        }

        fn groupInit(v: Self, init: ast.GroupInit) anyerror!void {
            switch (init) {
                .ctor => |fields| try v.groupFields(fields),
                .copy => {},
            }
        }

        fn groupFields(v: Self, fields: []ast.GroupField) anyerror!void {
            for (fields) |*f| switch (f.value) {
                .expr => |*e| try v.slot(e),
                .group => |sub| try v.groupFields(sub),
            };
        }

        fn function(v: Self, f: *ast.Function) anyerror!void {
            try v.block(f.body);
        }

        pub fn stat(v: Self, s: *ast.Stat) anyerror!void {
            switch (s.kind) {
                .empty, .break_, .continue_, .goto_, .label, .recovered => {},
                .expr => |*e| try v.slot(e),
                .local => |l| try v.exprs(l.values),
                .local_from => |*l| try v.slot(&l.source),
                .local_group => |l| for (l.inits) |init| try v.groupInit(init),
                .local_function => |l| try v.function(l.func),
                .global => |g| if (g.values) |vals| try v.exprs(vals),
                .global_from => |*g| try v.slot(&g.source),
                .global_function => |g| try v.function(g.func),
                .assign => |a| {
                    try v.exprs(a.targets);
                    try v.exprs(a.values);
                },
                .assign_from => |*a| {
                    try v.exprs(a.targets);
                    try v.slot(&a.source);
                },
                .function => |f| try v.function(f.func),
                .do_ => |b| try v.block(b),
                .while_ => |*w| {
                    try v.cond(&w.cond);
                    try v.block(w.body);
                },
                .repeat_ => |*r| {
                    try v.block(r.body);
                    try v.slot(&r.cond);
                },
                .if_ => |i| {
                    for (i.clauses) |*cl| {
                        try v.cond(&cl.cond);
                        try v.block(cl.body);
                    }
                    if (i.else_) |b| try v.block(b);
                },
                .numeric_for => |*f| {
                    try v.slot(&f.start);
                    try v.slot(&f.limit);
                    if (f.step) |*st| try v.slot(st);
                    try v.block(f.body);
                },
                .generic_for => |f| {
                    try v.exprs(f.exprs);
                    try v.block(f.body);
                },
                .return_ => |vals| try v.exprs(vals),
                .provide => |vals| try v.exprs(vals),
                .catch_ => |*c| {
                    if (c.handler) |*h| try v.slot(h);
                    try v.slot(&c.body);
                },
            }
        }

        pub fn slot(v: Self, e: **ast.Expr) anyerror!void {
            switch (e.*.kind) {
                .nil, .true, .false, .vararg, .integer, .float, .bigint, .decimal, .string, .name, .enum_ => {},
                .interp => |parts| for (parts) |*p| switch (p.*) {
                    .text => {},
                    .expr => |*x| try v.slot(x),
                },
                .function => |f| try v.function(f),
                .table => |fields| for (fields) |*f| switch (f.kind) {
                    .positional => |*x| try v.slot(x),
                    .named => |*n| try v.slot(&n.value),
                    .keyed => |*k| {
                        try v.slot(&k.key);
                        try v.slot(&k.value);
                    },
                },
                .binop => |*b| {
                    try v.slot(&b.lhs);
                    try v.slot(&b.rhs);
                },
                .unop => |*u| try v.slot(&u.operand),
                .paren => |*p| try v.slot(p),
                .index => |*ix| {
                    try v.slot(&ix.obj);
                    try v.slot(&ix.key);
                },
                .call => |*c| {
                    try v.slot(&c.callee);
                    try v.exprs(c.args);
                },
                .method => |*m| {
                    try v.slot(&m.obj);
                    try v.exprs(m.args);
                },
                .slice => |*s| {
                    try v.slot(&s.obj);
                    if (s.from) |*f| try v.slot(f);
                    if (s.to) |*t| try v.slot(t);
                },
                .optional => |*o| try v.slot(o),
                .chain => |*c| try v.slot(c),
                .catch_ => |*c| {
                    if (c.handler) |*h| try v.slot(h);
                    try v.slot(&c.body);
                },
                .do_ => |b| try v.block(b),
                .query => |q| for (q.sources) |*src| try v.slot(&src.expr),
            }
            try v.func(v.ctx, e);
        }
    };
}
