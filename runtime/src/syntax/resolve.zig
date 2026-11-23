//! Binding resolution on the syntax tree. The resolver follows the scoping
//! rules of the code generator and records facts in side tables: every
//! declared binding with its read and write counts, every name reference
//! with the binding it resolves to, and every label and `goto`. The
//! linter (`lint.zig`) turns these facts into diagnostics, and the
//! language server can consume the same tables.
//!
//! Global declarations take part in scoping exactly as in the compiler. A
//! named `global x` declares `x` and makes every other free name in its
//! scope an error, and `global *` declares every name. A reference that
//! resolves to nothing is a free global access.

const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const Span = ast.Span;

pub const Kind = enum {
    local,
    function,
    param,
    /// A name the language declares: the `self` of a method definition
    /// and the `_ENV` of the main chunk.
    implicit,
    loop_var,
    group,
    global,
    global_star,
    query_alias,
};

pub const Binding = struct {
    name: []const u8,
    span: Span,
    line: u32,
    kind: Kind,
    readonly: bool = false,
    close: bool = false,
    reads: u32 = 0,
    /// Assignments after the declaration. The initial value is not one.
    writes: u32 = 0,
    /// End offset of the last reference, read or write.
    last_use: u32 = 0,
    /// The local binding of an enclosing scope this one hides, if any.
    /// Redeclaring a name in the same scope is not shadowing.
    shadows: ?*Binding = null,
    /// Scope number, unique within the chunk.
    scope: u32 = 0,
    /// Declared by an assignment condition (`if x = f() then`), which
    /// tests the value, so the binding counts as read.
    cond: bool = false,
};

pub const Ref = struct {
    name: []const u8,
    span: Span,
    line: u32,
    write: bool,
    /// The local, the named global, or the `global *` declaration the
    /// name resolves to. Null for a free name.
    binding: ?*Binding,
    /// A free name inside the scope of a named global declaration, which
    /// the compiler rejects.
    strict: bool = false,
};

pub const Label = struct {
    name: []const u8,
    span: Span,
    line: u32,
    used: bool = false,
    /// The label with the same name visible where this one is declared.
    duplicate_of: ?*Label = null,
};

pub const Goto = struct {
    name: []const u8,
    span: Span,
    line: u32,
    label: ?*Label = null,
};

pub const Result = struct {
    bindings: []*Binding,
    refs: []Ref,
    labels: []*Label,
    gotos: []*Goto,

    /// The reference recorded for the name expression starting at `start`.
    pub fn refAt(r: Result, start: u32) ?*const Ref {
        // References are recorded in traversal order, which is close to
        // source order, so a linear scan is fine for the linter's few
        // lookups.
        for (r.refs) |*ref| if (ref.span.start == start) return ref;
        return null;
    }
};

const Mark = struct {
    scope: u32,
    bindings: usize,
    labels: usize,
    gotos: usize,
};

const Resolver = struct {
    arena: Allocator,
    bindings: std.ArrayList(*Binding) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    labels: std.ArrayList(*Label) = .empty,
    gotos: std.ArrayList(*Goto) = .empty,
    /// Bindings in scope, innermost last.
    active: std.ArrayList(*Binding) = .empty,
    /// Labels in scope in the current function, innermost last.
    active_labels: std.ArrayList(*Label) = .empty,
    /// Gotos of the current function not matched yet.
    pending: std.ArrayList(*Goto) = .empty,
    /// Index in `active_labels` where the current function starts.
    func_labels: usize = 0,
    /// How many `<meta>` initializers enclose the expression being
    /// resolved. A free name there is a global of the meta environment,
    /// which the declarations of the chunk do not cover.
    meta_depth: u32 = 0,
    scope: u32 = 0,
    scopes: u32 = 0,

    /// Opens a scope.
    fn mark(r: *Resolver) Mark {
        const outer = r.scope;
        r.scopes += 1;
        r.scope = r.scopes;
        return .{ .scope = outer, .bindings = r.active.items.len, .labels = r.active_labels.items.len, .gotos = r.pending.items.len };
    }

    /// Closes a block: gotos pending since `m` find their labels among the
    /// labels of the block, then the block's bindings and labels go out of
    /// scope. Unmatched gotos move to the enclosing block.
    fn leave(r: *Resolver, m: Mark) void {
        var i: usize = m.gotos;
        while (i < r.pending.items.len) {
            const g = r.pending.items[i];
            if (findLabel(r.active_labels.items[m.labels..], g.name)) |lb| {
                g.label = lb;
                lb.used = true;
                _ = r.pending.orderedRemove(i);
            } else i += 1;
        }
        r.active.items.len = m.bindings;
        r.active_labels.items.len = m.labels;
        r.scope = m.scope;
    }

    fn findLabel(list: []*Label, name: []const u8) ?*Label {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, list[i].name, name)) return list[i];
        }
        return null;
    }

    fn declare(r: *Resolver, name: ast.Name, line: u32, kind: Kind) Allocator.Error!*Binding {
        const b = try r.arena.create(Binding);
        b.* = .{ .name = name.text, .span = name.span, .line = line, .kind = kind, .scope = r.scope };
        switch (kind) {
            .global, .global_star, .query_alias => {},
            else => if (r.lookupLocal(name.text)) |prev| {
                if (prev.scope != r.scope and prev.kind != .implicit) b.shadows = prev;
            },
        }
        try r.bindings.append(r.arena, b);
        return b;
    }

    fn push(r: *Resolver, b: *Binding) Allocator.Error!void {
        try r.active.append(r.arena, b);
    }

    fn declarePush(r: *Resolver, name: ast.Name, line: u32, kind: Kind) Allocator.Error!*Binding {
        const b = try r.declare(name, line, kind);
        try r.push(b);
        return b;
    }

    fn lookupLocal(r: *Resolver, name: []const u8) ?*Binding {
        var i = r.active.items.len;
        while (i > 0) {
            i -= 1;
            const b = r.active.items[i];
            switch (b.kind) {
                .global, .global_star => {},
                else => if (std.mem.eql(u8, b.name, name)) return b,
            }
        }
        return null;
    }

    /// Resolves a name as the compiler does. A named global declaration
    /// of another name makes the scope strict. A `global *` covers every
    /// name but does not hide an outer local of the same name.
    fn reference(r: *Resolver, name: []const u8, span: Span, line: u32, write: bool) Allocator.Error!void {
        var strict = false;
        var star: ?*Binding = null;
        var found: ?*Binding = null;
        var i = r.active.items.len;
        while (i > 0) {
            i -= 1;
            const b = r.active.items[i];
            switch (b.kind) {
                .global => {
                    if (std.mem.eql(u8, b.name, name)) {
                        found = b;
                        break;
                    }
                    strict = true;
                },
                .global_star => if (star == null and !strict) {
                    star = b;
                },
                else => if (std.mem.eql(u8, b.name, name)) {
                    found = b;
                    break;
                },
            }
        }
        const resolved = found orelse star;
        if (resolved) |b| {
            if (write) b.writes += 1 else b.reads += 1;
            b.last_use = @max(b.last_use, span.end);
        }
        try r.refs.append(r.arena, .{
            .name = name,
            .span = span,
            .line = line,
            .write = write,
            .binding = resolved,
            .strict = resolved == null and strict and r.meta_depth == 0,
        });
    }

    // -----------------------------------------------------------------
    // Statements

    fn block(r: *Resolver, b: *ast.Block) Allocator.Error!void {
        const m = r.mark();
        try r.stats(b.stats);
        r.leave(m);
    }

    fn stats(r: *Resolver, list: []*ast.Stat) Allocator.Error!void {
        for (list) |s| try r.stat(s);
    }

    fn attribs(r: *Resolver, list: []ast.Attrib) Allocator.Error!void {
        for (list) |a| switch (a) {
            .runtime => |e| try r.expr(e),
            else => {},
        };
    }

    fn declareNames(r: *Resolver, names: []ast.AttName, line: u32, kind: Kind) Allocator.Error!void {
        for (names) |an| try r.attribs(an.attribs);
        // All names come into scope together, after the values.
        const first = r.bindings.items.len;
        for (names) |an| {
            const k: Kind = if (an.has(.group)) .group else kind;
            const b = try r.declare(an.name, line, k);
            b.readonly = an.has(.@"const") or an.has(.close) or an.has(.meta) or an.has(.lazy);
            b.close = an.has(.close);
        }
        for (r.bindings.items[first..]) |b| try r.push(b);
    }

    fn declareGlobals(r: *Resolver, defaults: []ast.Attrib, names: []ast.AttName, line: u32) Allocator.Error!void {
        var default_const = false;
        for (defaults) |a| if (a == .@"const") {
            default_const = true;
        };
        try r.attribs(defaults);
        for (names) |an| {
            try r.attribs(an.attribs);
            const b = try r.declarePush(an.name, line, .global);
            b.readonly = default_const or an.has(.@"const");
        }
    }

    fn groupInits(r: *Resolver, inits: []ast.GroupInit, line: u32) Allocator.Error!void {
        for (inits) |init| switch (init) {
            .ctor => |fields| try r.groupFields(fields),
            .copy => |n| try r.reference(n.text, n.span, line, false),
        };
    }

    fn groupFields(r: *Resolver, fields: []ast.GroupField) Allocator.Error!void {
        for (fields) |f| {
            try r.attribs(f.name.attribs);
            switch (f.value) {
                .expr => |e| try r.expr(e),
                .group => |sub| try r.groupFields(sub),
            }
        }
    }

    fn cond(r: *Resolver, c: ast.Cond, line: u32) Allocator.Error!void {
        switch (c) {
            .expr => |e| try r.expr(e),
            .assign => |a| {
                try r.exprs(a.values);
                try r.declareNames(a.names, line, .local);
            },
            .from => |f| {
                try r.expr(f.source);
                try r.declareNames(f.names, line, .local);
            },
            .group => |g| {
                try r.groupInits(g.inits, line);
                try r.declareNames(g.names, line, .group);
            },
        }
        if (c != .expr) {
            for (r.active.items[r.active.items.len - condNames(c).len ..]) |b| b.cond = true;
        }
    }

    fn condNames(c: ast.Cond) []ast.AttName {
        return switch (c) {
            .expr => &.{},
            .assign => |a| a.names,
            .from => |f| f.names,
            .group => |g| g.names,
        };
    }

    fn assignTarget(r: *Resolver, e: *ast.Expr) Allocator.Error!void {
        switch (e.kind) {
            .name => |n| try r.reference(n.text, n.span, e.line, true),
            else => try r.expr(e),
        }
    }

    fn stat(r: *Resolver, s: *ast.Stat) Allocator.Error!void {
        switch (s.kind) {
            .empty, .recovered, .break_, .continue_ => {},
            .expr => |e| try r.expr(e),
            .local => |l| {
                const meta = for (l.names) |an| {
                    if (an.has(.meta)) break true;
                } else false;
                if (meta) r.meta_depth += 1;
                try r.exprs(l.values);
                if (meta) r.meta_depth -= 1;
                try r.declareNames(l.names, s.line, .local);
            },
            .local_from => |l| {
                try r.expr(l.source);
                try r.declareNames(l.names, s.line, .local);
            },
            .local_group => |l| {
                try r.groupInits(l.inits, s.line);
                try r.declareNames(l.names, s.line, .group);
            },
            .local_function => |l| {
                _ = try r.declarePush(l.name, s.line, .function);
                try r.function(l.func);
            },
            .global => |g| {
                if (g.star) {
                    try r.attribs(g.default_attribs);
                    var ro = false;
                    for (g.default_attribs) |a| if (a == .@"const") {
                        ro = true;
                    };
                    const b = try r.declarePush(.{ .text = "*", .span = s.span }, s.line, .global_star);
                    b.readonly = ro;
                    return;
                }
                if (g.values) |vals| try r.exprs(vals);
                try r.declareGlobals(g.default_attribs, g.names, s.line);
            },
            .global_from => |g| {
                try r.expr(g.source);
                try r.declareGlobals(g.default_attribs, g.names, s.line);
            },
            .global_function => |g| {
                _ = try r.declarePush(g.name, s.line, .global);
                try r.function(g.func);
            },
            .assign => |a| {
                try r.exprs(a.values);
                for (a.targets) |t| try r.assignTarget(t);
            },
            .assign_from => |a| {
                try r.expr(a.source);
                for (a.targets) |t| try r.assignTarget(t);
            },
            .function => |f| {
                const head = f.path[0];
                const plain = f.path.len == 1 and f.method == null;
                try r.reference(head.text, head.span, s.line, plain);
                try r.function(f.func);
            },
            .do_ => |b| try r.block(b),
            .while_ => |w| {
                const m = r.mark();
                try r.cond(w.cond, s.line);
                try r.block(w.body);
                r.leave(m);
            },
            .repeat_ => |rp| {
                // The condition sees the body's locals.
                const m = r.mark();
                try r.stats(rp.body.stats);
                try r.expr(rp.cond);
                r.leave(m);
            },
            .if_ => |i| {
                // Condition variables stay visible in later clauses.
                const m = r.mark();
                for (i.clauses) |cl| {
                    try r.cond(cl.cond, cl.line);
                    try r.block(cl.body);
                }
                if (i.else_) |b| try r.block(b);
                r.leave(m);
            },
            .numeric_for => |f| {
                try r.expr(f.start);
                try r.expr(f.limit);
                if (f.step) |st| try r.expr(st);
                const m = r.mark();
                const b = try r.declarePush(f.name, s.line, .loop_var);
                b.readonly = true;
                try r.block(f.body);
                r.leave(m);
            },
            .generic_for => |f| {
                try r.exprs(f.exprs);
                const m = r.mark();
                for (f.names, 0..) |n, idx| {
                    const b = try r.declare(n, s.line, .loop_var);
                    b.readonly = idx == 0 and !f.from;
                }
                for (r.bindings.items[r.bindings.items.len - f.names.len ..]) |b| try r.push(b);
                try r.block(f.body);
                r.leave(m);
            },
            .return_ => |vals| try r.exprs(vals),
            .provide => |vals| try r.exprs(vals),
            .goto_ => |n| {
                const g = try r.arena.create(Goto);
                g.* = .{ .name = n.text, .span = n.span, .line = s.line };
                try r.gotos.append(r.arena, g);
                try r.pending.append(r.arena, g);
            },
            .label => |n| {
                const lb = try r.arena.create(Label);
                lb.* = .{ .name = n.text, .span = n.span, .line = s.line };
                lb.duplicate_of = findLabel(r.active_labels.items[r.func_labels..], n.text);
                try r.labels.append(r.arena, lb);
                try r.active_labels.append(r.arena, lb);
            },
            .catch_ => |c| {
                if (c.handler) |h| try r.expr(h);
                try r.expr(c.body);
            },
        }
    }

    fn function(r: *Resolver, f: *ast.Function) Allocator.Error!void {
        // Gotos and labels never cross a function boundary.
        const saved_pending = r.pending;
        const saved_func_labels = r.func_labels;
        r.pending = .empty;
        r.func_labels = r.active_labels.items.len;
        const m = r.mark();
        if (f.is_method) _ = try r.declarePush(.{ .text = "self", .span = f.span }, f.line, .implicit);
        for (f.params) |p| _ = try r.declarePush(p, f.line, .param);
        if (f.vararg_name) |v| _ = try r.declarePush(v, f.line, .param);
        try r.stats(f.body.stats);
        r.leave(m);
        r.pending = saved_pending;
        r.func_labels = saved_func_labels;
    }

    // -----------------------------------------------------------------
    // Expressions

    fn exprs(r: *Resolver, list: []*ast.Expr) Allocator.Error!void {
        for (list) |e| try r.expr(e);
    }

    fn expr(r: *Resolver, e: *ast.Expr) Allocator.Error!void {
        switch (e.kind) {
            .nil, .true, .false, .vararg, .integer, .float, .bigint, .decimal, .string, .enum_ => {},
            .name => |n| try r.reference(n.text, n.span, e.line, false),
            .interp => |parts| for (parts) |p| switch (p) {
                .text => {},
                .expr => |x| try r.expr(x),
            },
            .function => |f| try r.function(f),
            .table => |fields| for (fields) |f| switch (f.kind) {
                .positional => |x| try r.expr(x),
                .named => |n| try r.expr(n.value),
                .keyed => |k| {
                    try r.expr(k.key);
                    try r.expr(k.value);
                },
            },
            .binop => |b| {
                try r.expr(b.lhs);
                try r.expr(b.rhs);
            },
            .unop => |u| try r.expr(u.operand),
            .paren => |p| try r.expr(p),
            .index => |ix| {
                try r.expr(ix.obj);
                try r.expr(ix.key);
            },
            .call => |c| {
                try r.expr(c.callee);
                try r.exprs(c.args);
            },
            .method => |mt| {
                try r.expr(mt.obj);
                try r.exprs(mt.args);
            },
            .slice => |s| {
                try r.expr(s.obj);
                if (s.from) |x| try r.expr(x);
                if (s.to) |x| try r.expr(x);
            },
            .optional => |o| try r.expr(o),
            .chain => |c| try r.expr(c),
            .catch_ => |c| {
                if (c.handler) |h| try r.expr(h);
                try r.expr(c.body);
            },
            .do_ => |b| try r.block(b),
            .query => |q| try r.query(q),
        }
    }

    fn query(r: *Resolver, q: *ast.Query) Allocator.Error!void {
        for (q.sources) |src| try r.expr(src.expr);
        const m = r.mark();
        for (q.sources) |src| _ = try r.declarePush(src.alias, src.expr.line, .query_alias);
        if (q.where) |w| try r.qexpr(w);
        if (q.select) |items| for (items) |it| try r.qexpr(it.expr);
        if (q.group_by) |list| for (list) |x| try r.qexpr(x);
        if (q.having) |h| try r.qexpr(h);
        if (q.order_by) |list| for (list) |o| try r.qexpr(o.expr);
        if (q.limit) |x| try r.qexpr(x);
        if (q.offset) |x| try r.qexpr(x);
        r.leave(m);
    }

    fn qexpr(r: *Resolver, q: *ast.QExpr) Allocator.Error!void {
        switch (q.kind) {
            .literal => |e| try r.expr(e),
            .host => |e| try r.expr(e),
            // A chain names a row, a column, a select alias, or a bound
            // local. Only the last counts as a reference, and only when a
            // binding of that name is visible.
            .chain => |names| if (r.lookupLocal(names[0].text) != null) {
                try r.reference(names[0].text, names[0].span, q.line, false);
            },
            .paren => |p| try r.qexpr(p),
            .unop => |u| try r.qexpr(u.operand),
            .binop => |b| {
                try r.qexpr(b.lhs);
                try r.qexpr(b.rhs);
            },
            .aggregate => |a| if (a.arg) |x| try r.qexpr(x),
        }
    }
};

/// Resolves every name of `chunk`. The tables live in `arena`.
pub fn resolve(arena: Allocator, chunk: ast.Chunk) Allocator.Error!Result {
    var r: Resolver = .{ .arena = arena };
    const m = r.mark();
    _ = try r.declarePush(.{ .text = "_ENV", .span = .{ .start = 0, .end = 0 } }, 0, .implicit);
    try r.stats(chunk.block.stats);
    r.leave(m);
    return .{
        .bindings = r.bindings.items,
        .refs = r.refs.items,
        .labels = r.labels.items,
        .gotos = r.gotos.items,
    };
}

const testing = std.testing;
const parser = @import("parser.zig");

fn resolveSrc(arena: Allocator, src: []const u8) !Result {
    var diag: ?[]const u8 = null;
    const chunk = try parser.parse(testing.allocator, arena, src, .{ .chunkname = "=t" }, &diag);
    return resolve(arena, chunk);
}

test "resolve locals, shadowing, and globals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try resolveSrc(arena_state.allocator(), "local x = 1 do local x = x + 1 print(x) end global y y = 2 z = 3");
    try testing.expectEqual(@as(usize, 4), res.bindings.len);
    try testing.expect(res.bindings[2].shadows == res.bindings[1]);
    try testing.expectEqual(@as(u32, 1), res.bindings[1].reads);
    var strict_z = false;
    for (res.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "z")) strict_z = ref.strict;
    }
    try testing.expect(strict_z);
}

test "resolve labels and gotos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try resolveSrc(arena_state.allocator(), "do goto a end ::a:: ::b:: goto c");
    try testing.expect(res.gotos[0].label == res.labels[0]);
    try testing.expect(!res.labels[1].used);
    try testing.expect(res.gotos[1].label == null);
}
