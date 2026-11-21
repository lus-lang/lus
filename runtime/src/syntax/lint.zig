//! Static diagnostics on the syntax tree, behind `lus check`. The checks
//! use the bindings of `resolve.zig` and a few structural patterns. Each
//! diagnostic has a stable code so tools can filter and suppress it.
//!
//! Errors are programs the compiler rejects: assignments to constants,
//! undeclared names in the scope of a global declaration, missing or
//! duplicate labels, and misplaced `continue`. Warnings are programs that
//! run but probably do not do what their author meant, and idioms that a
//! Lus feature expresses directly.

const std = @import("std");
const ast = @import("ast.zig");
const resolve = @import("resolve.zig");
const doccomment = @import("doccomment.zig");
const Allocator = std.mem.Allocator;
const Span = ast.Span;

pub const Severity = enum {
    @"error",
    warning,

    pub fn label(s: Severity) []const u8 {
        return @tagName(s);
    }
};

pub const Diagnostic = struct {
    /// Byte offsets into the source.
    span: Span,
    /// One-based line and column. Columns count characters.
    line: u32 = 0,
    column: u32 = 0,
    end_line: u32 = 0,
    end_column: u32 = 0,
    severity: Severity,
    code: []const u8,
    message: []const u8,
};

pub const Options = struct {
    /// Names the runtime defines in the global table. A free name in this
    /// set is not reported as undefined.
    builtins: ?*const std.StringHashMapUnmanaged(void) = null,
    /// The file is a test file (`*_test.lus`). Its top-level locals named
    /// `NAME_test` and `NAME_cases` are read by the test runner, so they
    /// count as used.
    test_file: bool = false,
};

/// Every code `lint` can report, with its severity and a summary. The
/// list is the reference for `lus check --list`.
pub const codes = [_]struct { code: []const u8, severity: Severity, summary: []const u8 }{
    .{ .code = "unused-local", .severity = .warning, .summary = "A local variable is never read." },
    .{ .code = "unused-function", .severity = .warning, .summary = "A local function is never used." },
    .{ .code = "unused-param", .severity = .warning, .summary = "A function parameter is never read." },
    .{ .code = "unused-loop-var", .severity = .warning, .summary = "A loop variable is never read." },
    .{ .code = "unused-label", .severity = .warning, .summary = "No goto jumps to a label." },
    .{ .code = "shadowed-local", .severity = .warning, .summary = "A local hides another visible local of the same name." },
    .{ .code = "undefined-global", .severity = .warning, .summary = "A free name is read but never defined in the file nor by the runtime." },
    .{ .code = "implicit-global", .severity = .warning, .summary = "A global is assigned without a 'global' declaration." },
    .{ .code = "unreachable-code", .severity = .warning, .summary = "A statement follows a break, continue, or goto in the same block." },
    .{ .code = "duplicate-key", .severity = .warning, .summary = "A table constructor sets the same constant key twice." },
    .{ .code = "self-assign", .severity = .warning, .summary = "A variable or field is assigned to itself." },
    .{ .code = "deprecated-pcall", .severity = .warning, .summary = "'pcall' or 'xpcall' is used where Lus has 'catch'." },
    .{ .code = "pledge-after-seal", .severity = .warning, .summary = "A pledge follows pledge(\"seal\") and has no effect." },
    .{ .code = "use-from", .severity = .warning, .summary = "Fields of one table are copied into same-named locals one by one." },
    .{ .code = "use-optional-chain", .severity = .warning, .summary = "Nested nil checks or an and-chain spell out optional chaining." },
    .{ .code = "use-if-assign", .severity = .warning, .summary = "A local exists only for the truth test of the next if." },
    .{ .code = "doc-unknown-param", .severity = .warning, .summary = "A doc comment documents a parameter the function does not have." },
    .{ .code = "package-flag", .severity = .warning, .summary = "A package reads a flag that its header does not declare." },
    .{ .code = "package-pledge", .severity = .warning, .summary = "A package calls pledge at the top level, which acts on the permissions of the program." },
    .{ .code = "package-header", .severity = .@"error", .summary = "A package header lacks a required annotation or has a malformed one." },
    .{ .code = "assign-const", .severity = .@"error", .summary = "A constant, a close variable, or a loop control variable is assigned." },
    .{ .code = "undeclared-global", .severity = .@"error", .summary = "A free name is used in the scope of a named global declaration." },
    .{ .code = "undefined-label", .severity = .@"error", .summary = "A goto names no visible label." },
    .{ .code = "duplicate-label", .severity = .@"error", .summary = "A label repeats a visible label of the same function." },
    .{ .code = "continue-outside-loop", .severity = .@"error", .summary = "A continue appears outside every loop." },
    .{ .code = "continue-into-scope", .severity = .@"error", .summary = "A continue in a repeat loop skips a local the condition can see." },
};

const Linter = struct {
    arena: Allocator,
    chunk: ast.Chunk,
    res: resolve.Result,
    opts: Options,
    docs: doccomment.Index,
    out: std.ArrayList(Diagnostic) = .empty,
    /// Free names assigned somewhere in the file.
    assigned: std.StringHashMapUnmanaged(void) = .empty,
    /// Reads `flags.NAME` of the reserved global `flags`.
    flag_reads: std.ArrayList(*ast.Expr) = .empty,
    /// Bodies of function and do expressions, checked as blocks of their
    /// own after the main walk.
    nested: std.ArrayList(Nested) = .empty,
    /// `and` nodes inside a longer chain, which the outermost one reports.
    inner_ands: std.AutoHashMapUnmanaged(*ast.Expr, void) = .empty,
    /// Calls of the global `pledge`.
    calls: std.ArrayList(*ast.Expr) = .empty,

    const Nested = struct { block: *ast.Block, in_loop: LoopCtx };

    fn report(l: *Linter, span: Span, severity: Severity, code: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try l.out.append(l.arena, .{
            .span = span,
            .severity = severity,
            .code = code,
            .message = try std.fmt.allocPrint(l.arena, fmt, args),
        });
    }

    fn text(l: *Linter, span: Span) []const u8 {
        return l.chunk.source[@min(span.start, l.chunk.source.len)..@min(span.end, l.chunk.source.len)];
    }

    fn isFree(l: *Linter, e: *const ast.Expr, name: []const u8) bool {
        if (e.kind != .name or !std.mem.eql(u8, e.kind.name.text, name)) return false;
        const ref = l.res.refAt(e.kind.name.span.start) orelse return false;
        return ref.binding == null or ref.binding.?.kind == .global or ref.binding.?.kind == .global_star;
    }

    // -----------------------------------------------------------------
    // Binding checks

    fn bindings(l: *Linter) Allocator.Error!void {
        for (l.res.bindings) |b| {
            const ignored = b.name.len > 0 and b.name[0] == '_';
            switch (b.kind) {
                .global, .global_star, .query_alias, .implicit => continue,
                else => {},
            }
            if (b.shadows) |prev| if (!ignored and !b.cond) {
                try l.report(b.span, .warning, "shadowed-local", "'{s}' shadows the local declared on line {d}", .{ b.name, prev.line });
            };
            if (ignored or b.close or b.cond or b.reads > 0) continue;
            if (b.kind == .param and std.mem.eql(u8, b.name, "self")) continue;
            if (l.opts.test_file and l.isTestEntry(b)) continue;
            switch (b.kind) {
                .param => try l.report(b.span, .warning, "unused-param", "unused parameter '{s}'", .{b.name}),
                .loop_var => try l.report(b.span, .warning, "unused-loop-var", "unused loop variable '{s}'", .{b.name}),
                .function => try l.report(b.span, .warning, "unused-function", "unused local function '{s}'", .{b.name}),
                else => if (b.writes > 0)
                    try l.report(b.span, .warning, "unused-local", "local '{s}' is assigned but never read", .{b.name})
                else
                    try l.report(b.span, .warning, "unused-local", "unused local '{s}'", .{b.name}),
            }
        }
    }

    /// A top-level local of a test file that the runner reads: a test
    /// function `NAME_test` or a case table `NAME_cases`.
    fn isTestEntry(l: *Linter, b: *const resolve.Binding) bool {
        const named = std.mem.endsWith(u8, b.name, "_test") or std.mem.endsWith(u8, b.name, "_cases");
        if (!named) return false;
        for (l.chunk.block.stats) |s| switch (s.kind) {
            .local_function => |lf| if (lf.name.span.start == b.span.start) return true,
            .local => |loc| for (loc.names) |n| if (n.name.span.start == b.span.start) return true,
            else => {},
        };
        return false;
    }

    fn references(l: *Linter) Allocator.Error!void {
        for (l.res.refs) |ref| {
            if (ref.binding == null and !ref.strict and ref.write) try l.assigned.put(l.arena, ref.name, {});
        }
        var warned_implicit: std.StringHashMapUnmanaged(void) = .empty;
        var warned_undefined: std.StringHashMapUnmanaged(void) = .empty;
        for (l.res.refs) |ref| {
            if (ref.binding) |b| {
                if (ref.write and b.readonly) {
                    try l.report(ref.span, .@"error", "assign-const", "attempt to assign to const variable '{s}'", .{ref.name});
                }
                continue;
            }
            if (ref.strict) {
                if (std.mem.eql(u8, ref.name, "flags") or std.mem.startsWith(u8, ref.name, "__lus_")) continue;
                try l.report(ref.span, .@"error", "undeclared-global", "variable '{s}' not declared", .{ref.name});
                continue;
            }
            if (ref.write) {
                if ((try warned_implicit.fetchPut(l.arena, ref.name, {})) == null) {
                    try l.report(ref.span, .warning, "implicit-global", "global '{s}' is assigned without a 'global' declaration", .{ref.name});
                }
                continue;
            }
            if (std.mem.eql(u8, ref.name, "pcall") or std.mem.eql(u8, ref.name, "xpcall")) {
                try l.report(ref.span, .warning, "deprecated-pcall", "'{s}' no longer exists, use a 'catch' expression instead", .{ref.name});
                continue;
            }
            if (l.assigned.contains(ref.name)) continue;
            if (l.opts.builtins) |set| if (set.contains(ref.name)) continue;
            if (std.mem.eql(u8, ref.name, "flags")) continue;
            if ((try warned_undefined.fetchPut(l.arena, ref.name, {})) == null) {
                if (std.mem.eql(u8, ref.name, "null")) {
                    try l.report(ref.span, .warning, "undefined-global", "undefined global 'null' (the absent value is written 'nil')", .{});
                } else {
                    try l.report(ref.span, .warning, "undefined-global", "undefined global '{s}'", .{ref.name});
                }
            }
        }
    }

    fn labels(l: *Linter) Allocator.Error!void {
        for (l.res.labels) |lb| {
            if (lb.duplicate_of) |prev| {
                try l.report(lb.span, .@"error", "duplicate-label", "label '{s}' already defined on line {d}", .{ lb.name, prev.line });
            } else if (!lb.used) {
                try l.report(lb.span, .warning, "unused-label", "unused label '{s}'", .{lb.name});
            }
        }
        for (l.res.gotos) |g| {
            if (g.label == null) try l.report(g.span, .@"error", "undefined-label", "no visible label '{s}' for goto", .{g.name});
        }
    }

    // -----------------------------------------------------------------
    // Statement checks

    const LoopCtx = enum { none, loop, unknown };

    fn block(l: *Linter, b: *ast.Block, loop: LoopCtx) Allocator.Error!void {
        var dead: ?*ast.Stat = null;
        for (b.stats, 0..) |s, i| {
            if (dead != null) switch (s.kind) {
                .label, .empty => dead = null,
                else => {
                    try l.report(s.span, .warning, "unreachable-code", "unreachable code", .{});
                    dead = null;
                },
            };
            switch (s.kind) {
                .break_, .continue_, .goto_ => dead = s,
                else => {},
            }
            try l.stat(s, loop);
            if (i + 1 < b.stats.len) try l.moveableLocal(s, b.stats[i + 1]);
        }
    }

    fn stat(l: *Linter, s: *ast.Stat, loop: LoopCtx) Allocator.Error!void {
        try l.docParams(s);
        switch (s.kind) {
            .continue_ => if (loop == .none) {
                try l.report(s.span, .@"error", "continue-outside-loop", "continue outside loop", .{});
            },
            .local => |loc| try l.manualFrom(s, loc.names, loc.values),
            .assign => |a| try l.selfAssign(a.targets, a.values),
            .do_ => |b| try l.block(b, loop),
            .while_ => |w| try l.block(w.body, .loop),
            .repeat_ => |r| {
                try l.continueIntoScope(r.body);
                try l.block(r.body, .loop);
            },
            .if_ => |i| {
                try l.nestedNilChecks(s);
                for (i.clauses) |cl| try l.block(cl.body, loop);
                if (i.else_) |b| try l.block(b, loop);
            },
            .numeric_for => |f| try l.block(f.body, .loop),
            .generic_for => |f| try l.block(f.body, .loop),
            .local_function => |f| try l.nested.append(l.arena, .{ .block = f.func.body, .in_loop = .none }),
            .global_function => |f| try l.nested.append(l.arena, .{ .block = f.func.body, .in_loop = .none }),
            .function => |f| try l.nested.append(l.arena, .{ .block = f.func.body, .in_loop = .none }),
            else => {},
        }
    }

    /// `local a, b = t.a, t.b`, which `local a, b from t` expresses.
    fn manualFrom(l: *Linter, s: *ast.Stat, names: []ast.AttName, values: []*ast.Expr) Allocator.Error!void {
        if (names.len < 2 or names.len != values.len) return;
        var base: ?[]const u8 = null;
        for (names, values) |n, v| {
            if (n.attribs.len != 0) return;
            if (v.kind != .index or !v.kind.index.dot) return;
            const obj = v.kind.index.obj;
            const key = v.kind.index.key;
            if (obj.kind != .name or key.kind != .string) return;
            if (!std.mem.eql(u8, key.kind.string, n.name.text)) return;
            if (base) |bn| {
                if (!std.mem.eql(u8, bn, obj.kind.name.text)) return;
            } else base = obj.kind.name.text;
        }
        try l.report(s.span, .warning, "use-from", "use 'from' destructuring: local ... from {s}", .{base.?});
    }

    fn selfAssign(l: *Linter, targets: []*ast.Expr, values: []*ast.Expr) Allocator.Error!void {
        for (targets, 0..) |t, i| {
            if (i >= values.len) break;
            if (exprEqual(t, values[i])) {
                try l.report(t.span, .warning, "self-assign", "'{s}' is assigned to itself", .{l.text(t.span)});
            }
        }
    }

    /// `if x ~= nil then if x.y ~= nil then ... end end`.
    fn nestedNilChecks(l: *Linter, s: *ast.Stat) Allocator.Error!void {
        var depth: u32 = 0;
        var cur = s;
        while (true) {
            const i = switch (cur.kind) {
                .if_ => |i| i,
                else => break,
            };
            if (i.clauses.len != 1 or i.else_ != null) break;
            const c = switch (i.clauses[0].cond) {
                .expr => |e| e,
                else => break,
            };
            if (!isNotNil(c)) break;
            depth += 1;
            const body = i.clauses[0].body.stats;
            if (body.len != 1) break;
            cur = body[0];
        }
        if (depth >= 2) {
            try l.report(s.span, .warning, "use-optional-chain", "nested nil checks can use optional chaining: x?.y?.z", .{});
        }
    }

    fn isNotNil(e: *const ast.Expr) bool {
        if (e.kind != .binop or e.kind.binop.op != .ne) return false;
        return e.kind.binop.rhs.kind == .nil or e.kind.binop.lhs.kind == .nil;
    }

    /// `local x = f()` followed by `if x then`, where `x` is used nowhere
    /// after the `if`. The assignment condition `if x = f() then` tests
    /// the same values and keeps `x` inside the statement. The condition
    /// must test exactly the declared names, joined by `and`, because an
    /// assignment condition passes when every value is truthy.
    fn moveableLocal(l: *Linter, s: *ast.Stat, next: *ast.Stat) Allocator.Error!void {
        const loc = switch (s.kind) {
            .local => |loc| loc,
            else => return,
        };
        if (loc.values.len == 0) return;
        for (loc.names) |n| if (n.attribs.len != 0) return;
        const i = switch (next.kind) {
            .if_ => |i| i,
            else => return,
        };
        const cond = switch (i.clauses[0].cond) {
            .expr => |e| e,
            else => return,
        };
        var tested: std.ArrayList([]const u8) = .empty;
        if (!try collectAnd(l.arena, cond, &tested)) return;
        if (tested.items.len != loc.names.len) return;
        for (loc.names) |n| {
            var found = false;
            for (tested.items) |t| if (std.mem.eql(u8, t, n.name.text)) {
                found = true;
            };
            if (!found) return;
            const b = l.bindingAt(n.name.span) orelse return;
            if (b.last_use > next.span.end) return;
        }
        try l.report(s.span, .warning, "use-if-assign", "local declaration can be moved to the if condition (use if-assignment)", .{});
    }

    /// Collects the names of `a and b and c`. False for any other shape.
    fn collectAnd(arena: Allocator, e: *const ast.Expr, out: *std.ArrayList([]const u8)) Allocator.Error!bool {
        const x = unparen(e);
        switch (x.kind) {
            .name => |n| {
                try out.append(arena, n.text);
                return true;
            },
            .binop => |b| {
                if (b.op != .@"and") return false;
                return try collectAnd(arena, b.lhs, out) and try collectAnd(arena, b.rhs, out);
            },
            else => return false,
        }
    }

    fn bindingAt(l: *Linter, span: Span) ?*resolve.Binding {
        for (l.res.bindings) |b| if (b.span.start == span.start) return b;
        return null;
    }

    /// In `repeat ... until cond`, `continue` jumps to the condition, so it
    /// may not skip a local declared at the top level of the body.
    fn continueIntoScope(l: *Linter, body: *ast.Block) Allocator.Error!void {
        for (body.stats, 0..) |s, i| {
            var found: std.ArrayList(*ast.Stat) = .empty;
            try collectContinues(l.arena, s, &found);
            if (found.items.len == 0) continue;
            for (body.stats[i + 1 ..]) |later| {
                const name: ?[]const u8 = switch (later.kind) {
                    .local => |x| x.names[0].name.text,
                    .local_from => |x| x.names[0].name.text,
                    .local_group => |x| x.names[0].name.text,
                    .local_function => |x| x.name.text,
                    else => null,
                };
                if (name) |n| {
                    for (found.items) |c| {
                        try l.report(c.span, .@"error", "continue-into-scope", "continue at line {d} jumps into the scope of '{s}'", .{ c.line, n });
                    }
                    break;
                }
            }
        }
    }

    fn collectContinues(arena: Allocator, s: *ast.Stat, out: *std.ArrayList(*ast.Stat)) Allocator.Error!void {
        switch (s.kind) {
            .continue_ => try out.append(arena, s),
            .do_ => |b| for (b.stats) |x| try collectContinues(arena, x, out),
            .if_ => |i| {
                for (i.clauses) |cl| for (cl.body.stats) |x| try collectContinues(arena, x, out);
                if (i.else_) |b| for (b.stats) |x| try collectContinues(arena, x, out);
            },
            else => {},
        }
    }

    /// Reports `@param` annotations that name no parameter.
    fn docParams(l: *Linter, s: *ast.Stat) Allocator.Error!void {
        const f: *ast.Function = switch (s.kind) {
            .local_function => |x| x.func,
            .global_function => |x| x.func,
            .function => |x| x.func,
            .local => |x| if (x.values.len == 1 and x.values[0].kind == .function) x.values[0].kind.function else return,
            else => return,
        };
        const d = (try l.docs.before(l.arena, s.line)) orelse return;
        outer: for (d.params) |p| {
            if (std.mem.eql(u8, p.name, "...") and f.is_vararg) continue;
            if (std.mem.eql(u8, p.name, "self") and f.is_method) continue;
            for (f.params) |fp| if (std.mem.eql(u8, fp.text, p.name)) continue :outer;
            if (f.vararg_name) |v| if (std.mem.eql(u8, v.text, p.name)) continue;
            const off = lineOffset(l.chunk.source, p.line);
            try l.report(.{ .start = off, .end = off }, .warning, "doc-unknown-param", "doc comment names unknown parameter '{s}'", .{p.name});
        }
    }

    // -----------------------------------------------------------------
    // Expression checks

    fn visit(l: *Linter, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        switch (e.kind) {
            .table => |fields| try l.duplicateKeys(fields),
            .binop => |b| if (b.op == .@"and") try l.andChain(e),
            .function => |f| try l.nested.append(l.arena, .{ .block = f.body, .in_loop = .none }),
            .do_ => |b| try l.nested.append(l.arena, .{ .block = b, .in_loop = .unknown }),
            else => {},
        }
    }

    fn duplicateKeys(l: *Linter, fields: []ast.Field) Allocator.Error!void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var positional: i64 = 0;
        for (fields) |f| {
            const key: ?[]const u8, const span: Span = switch (f.kind) {
                .positional => |e| blk: {
                    positional += 1;
                    break :blk .{ try std.fmt.allocPrint(l.arena, "{d}", .{positional}), e.span };
                },
                .named => |n| .{ try std.fmt.allocPrint(l.arena, "\"{s}\"", .{n.name.text}), n.name.span },
                .keyed => |k| .{ try l.constKey(k.key), k.key.span },
            };
            const k = key orelse continue;
            if ((try seen.fetchPut(l.arena, k, {})) != null) {
                try l.report(span, .warning, "duplicate-key", "duplicate key {s} in table constructor", .{k});
            }
        }
    }

    /// A canonical spelling for a constant key, or null.
    fn constKey(l: *Linter, e: *const ast.Expr) Allocator.Error!?[]const u8 {
        return switch (e.kind) {
            .string => |s| try std.fmt.allocPrint(l.arena, "\"{s}\"", .{s}),
            .integer => |n| try std.fmt.allocPrint(l.arena, "{d}", .{n}),
            .float => |x| if (x == @trunc(x) and @abs(x) < 9.0e15) try std.fmt.allocPrint(l.arena, "{d}", .{@as(i64, @intFromFloat(x))}) else null,
            .true => "true",
            .false => "false",
            .paren => |p| l.constKey(p),
            else => null,
        };
    }

    /// `x and x.y and x.y.z`, where each operand indexes the previous one.
    fn andChain(l: *Linter, e: *ast.Expr) Allocator.Error!void {
        // Only the outermost `and` of a chain reports.
        if (l.inner_ands.contains(e)) return;
        var depth: u32 = 0;
        var cur = e;
        while (cur.kind == .binop and cur.kind.binop.op == .@"and") {
            const lhs = cur.kind.binop.lhs;
            const rhs = cur.kind.binop.rhs;
            const prev = if (lhs.kind == .binop and lhs.kind.binop.op == .@"and") lhs.kind.binop.rhs else lhs;
            if (rhs.kind != .index or !exprEqual(rhs.kind.index.obj, prev)) break;
            depth += 1;
            if (lhs.kind == .binop and lhs.kind.binop.op == .@"and") {
                try l.inner_ands.put(l.arena, lhs, {});
                cur = lhs;
            } else break;
        }
        if (depth >= 2) {
            try l.report(e.span, .warning, "use-optional-chain", "and-chain can use optional chaining: x?.y?.z", .{});
        }
    }

    /// `pledge(...)` after `pledge("seal")`, in source order.
    fn pledges(l: *Linter) Allocator.Error!void {
        std.mem.sort(*ast.Expr, l.calls.items, {}, struct {
            fn lt(_: void, a: *ast.Expr, b: *ast.Expr) bool {
                return a.span.start < b.span.start;
            }
        }.lt);
        var sealed = false;
        for (l.calls.items) |c| {
            if (sealed) {
                try l.report(c.span, .warning, "pledge-after-seal", "pledge() after pledge(\"seal\") has no effect, permissions are frozen", .{});
                continue;
            }
            const args = c.kind.call.args;
            if (args.len >= 1 and args[0].kind == .string and std.mem.eql(u8, args[0].kind.string, "seal")) sealed = true;
        }
    }

    fn collectCall(l: *Linter, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        if (e.kind == .call and l.isFree(e.kind.call.callee, "pledge")) try l.calls.append(l.arena, e);
        if (e.kind == .index and e.kind.index.key.kind == .string and l.isFree(e.kind.index.obj, "flags")) try l.flag_reads.append(l.arena, e);
    }

    /// The checks of a package header (`spec/design/modules.md`, section
    /// 6). They apply to a file whose module comment holds a package
    /// annotation.
    fn packageHeader(l: *Linter) Allocator.Error!void {
        const md = (try l.docs.moduleDoc(l.arena)) orelse return;
        const pkg = md.package orelse return;
        const at = lineSpan(l.chunk.source, md.line);
        const required = [_]struct { v: ?[]const u8, tag: []const u8 }{
            .{ .v = pkg.name, .tag = "@package" },
            .{ .v = pkg.version, .tag = "@version" },
            .{ .v = pkg.lus, .tag = "@lus" },
            .{ .v = pkg.license, .tag = "@license" },
        };
        for (required) |r| if (r.v == null) try l.report(at, .@"error", "package-header", "the package header lacks {s}", .{r.tag});
        if (pkg.name) |n| if (!validPackageName(n))
            try l.report(at, .@"error", "package-header", "the package name '{s}' must be 2 to 40 characters from a-z, 0-9, and _, starting with a letter", .{n});
        if (pkg.version) |v| if (!validVersion(v))
            try l.report(at, .@"error", "package-header", "the package version '{s}' must be MAJOR.MINOR.PATCH", .{v});
        if (pkg.lus) |v| if (!validLine(v))
            try l.report(at, .@"error", "package-header", "@lus '{s}' must be a line such as 2.0, or a release such as 2.0.3", .{v});
        // A top-level pledge runs when the program loads the package.
        for (l.chunk.block.stats) |st| switch (st.kind) {
            .expr => |e| if (e.kind == .call and l.isFree(e.kind.call.callee, "pledge"))
                try l.report(e.span, .warning, "package-pledge", "a package must not call pledge at the top level, which acts on the permissions of the program", .{}),
            else => {},
        };
        for (l.flag_reads.items) |e| {
            const name = e.kind.index.key.kind.string;
            if (pkg.flag(name) == null) try l.report(e.span, .warning, "package-flag", "the package header declares no flag '{s}'", .{name});
        }
    }
};

/// The span of the first character of `line`.
fn lineSpan(src: []const u8, line: u32) Span {
    var cur: u32 = 1;
    var i: u32 = 0;
    while (i < src.len and cur < line) : (i += 1) {
        if (src[i] == '\n') cur += 1;
    }
    return .{ .start = i, .end = i };
}

fn validPackageName(n: []const u8) bool {
    if (n.len < 2 or n.len > 40 or !std.ascii.isLower(n[0])) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

fn allDigits(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validVersion(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) if (!allDigits(part)) return false;
    return n == 3;
}

fn validLine(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) if (!allDigits(part)) return false;
    return n == 2 or n == 3;
}

/// Structural equality of side-effect-free expressions: names, constant
/// literals, and field accesses built from them.
pub fn exprEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    const x = unparen(a);
    const y = unparen(b);
    return switch (x.kind) {
        .name => |n| y.kind == .name and std.mem.eql(u8, n.text, y.kind.name.text),
        .string => |s| y.kind == .string and std.mem.eql(u8, s, y.kind.string),
        .integer => |n| y.kind == .integer and n == y.kind.integer,
        .true => y.kind == .true,
        .false => y.kind == .false,
        .nil => y.kind == .nil,
        .index => |ix| y.kind == .index and exprEqual(ix.obj, y.kind.index.obj) and exprEqual(ix.key, y.kind.index.key),
        else => false,
    };
}

fn unparen(e: *const ast.Expr) *const ast.Expr {
    var cur = e;
    while (cur.kind == .paren) cur = cur.kind.paren;
    return cur;
}

fn lineOffset(src: []const u8, line: u32) u32 {
    var cur: u32 = 1;
    for (src, 0..) |c, i| {
        if (cur == line) return @intCast(i);
        if (c == '\n') cur += 1;
    }
    return @intCast(src.len);
}

/// Fills the line and column fields of `d` from its span.
pub fn locate(src: []const u8, list: []Diagnostic) void {
    for (list) |*d| {
        const s = position(src, d.span.start);
        const e = position(src, d.span.end);
        d.line = s.line;
        d.column = s.column;
        d.end_line = e.line;
        d.end_column = e.column;
    }
}

const Position = struct { line: u32, column: u32 };

fn position(src: []const u8, offset: u32) Position {
    var line: u32 = 1;
    var col: u32 = 1;
    const end = @min(offset, src.len);
    for (src[0..end]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else if (c & 0xC0 != 0x80) {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

/// Runs every check on `chunk` and returns the diagnostics sorted by
/// position.
pub fn lint(arena: Allocator, chunk: ast.Chunk, opts: Options) Allocator.Error![]Diagnostic {
    const res = try resolve.resolve(arena, chunk);
    var l: Linter = .{ .arena = arena, .chunk = chunk, .res = res, .opts = opts, .docs = doccomment.Index.init(chunk) };
    try l.bindings();
    try l.references();
    try l.labels();

    const walk = @import("walk.zig");
    const v: walk.Visitor(*Linter) = .{ .ctx = &l, .func = Linter.visit };
    v.block(chunk.block) catch return error.OutOfMemory;
    const vc: walk.Visitor(*Linter) = .{ .ctx = &l, .func = Linter.collectCall };
    vc.block(chunk.block) catch return error.OutOfMemory;
    try l.pledges();
    try l.packageHeader();

    try l.block(chunk.block, .none);
    var i: usize = 0;
    while (i < l.nested.items.len) : (i += 1) {
        const n = l.nested.items[i];
        try l.block(n.block, n.in_loop);
    }

    locate(chunk.source, l.out.items);
    std.mem.sort(Diagnostic, l.out.items, {}, struct {
        fn lt(_: void, a: Diagnostic, b: Diagnostic) bool {
            if (a.span.start != b.span.start) return a.span.start < b.span.start;
            return std.mem.order(u8, a.code, b.code) == .lt;
        }
    }.lt);
    return l.out.items;
}

const testing = std.testing;

fn lintCodes(src: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: ?[]const u8 = null;
    const chunk = try @import("parser.zig").parse(testing.allocator, arena, src, .{ .chunkname = "=t" }, &diag);
    const list = try lint(arena, chunk, .{});
    var buf: std.ArrayList(u8) = .empty;
    for (list) |d| {
        if (buf.items.len > 0) try buf.append(arena, ' ');
        try buf.appendSlice(arena, d.code);
    }
    return testing.allocator.dupe(u8, buf.items);
}

fn expectCodes(src: []const u8, want: []const u8) !void {
    const got = try lintCodes(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "package header checks" {
    try expectCodes(
        \\--- A package.
        \\--- @package dates
        \\--- @version 1.4.1
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\--- @flag strict boolean Reject unknown fields.
        \\
        \\global flags, pledge
        \\pledge("fs:read")
        \\local a = flags.strict
        \\local b = flags.loud
        \\return { a = a, b = b }
    , "package-pledge package-flag");
    try expectCodes(
        \\--- @package Dates
        \\--- @version 1.4
        \\
        \\return {}
    , "package-header package-header package-header package-header");
}

test "lint bindings" {
    try expectCodes("local x = 1", "unused-local");
    try expectCodes("local _x = 1", "");
    try expectCodes("local function f(a) end", "unused-function unused-param");
    try expectCodes("global print local x <const> = 1 x = 2 print(x)", "assign-const");
    try expectCodes("global print local x = 1 do local x = 2 print(x) end print(x)", "shadowed-local");
}

test "lint statements" {
    try expectCodes("global print for i = 1, 2 do print(i) break print(i) end", "unreachable-code");
    try expectCodes("global print local t = { a = 1, a = 2, [1] = 3, 4 } print(t)", "duplicate-key duplicate-key");
    try expectCodes("global t t.a = t.a", "self-assign");
    try expectCodes("goto x", "undefined-label");
}
