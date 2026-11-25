//! Static diagnostics on the syntax tree, behind `lus check`. The checks
//! use the bindings of `resolve.zig` and a few structural patterns. Each
//! diagnostic has a stable code so tools can filter and suppress it.
//!
//! Errors are programs the compiler rejects: assignments to constants,
//! undeclared names in the scope of a global declaration, missing or
//! duplicate labels, and misplaced `continue`. Warnings are programs that
//! run but probably do not do what their author meant. Hints suggest a
//! faster or shorter form of correct code, each backed by a measured case
//! in `tests/bench/hints/cases.lus` (`spec/design/hints.md`).

const std = @import("std");
const ast = @import("ast.zig");
const resolve = @import("resolve.zig");
const doccomment = @import("doccomment.zig");
const Allocator = std.mem.Allocator;
const Span = ast.Span;

pub const Severity = enum {
    @"error",
    warning,
    /// A faster or shorter form of correct code (`spec/design/hints.md`).
    /// A hint never changes the exit status of `lus check`.
    hint,

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
    /// The edits of a rewrite that resolves the diagnostic without changing
    /// what the program does, which `lus check --fix` applies together
    /// (`syntax/fix.zig`). Empty when the diagnostic has no such rewrite.
    fix: []const Edit = &.{},
};

/// Replaces the bytes of `span` with `text`. An empty span inserts.
pub const Edit = struct {
    span: Span,
    text: []const u8,
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
    .{ .code = "use-from", .severity = .hint, .summary = "Fields of one table are copied into same-named locals one by one." },
    .{ .code = "use-optional-chain", .severity = .hint, .summary = "Nested nil checks or an and-chain spell out optional chaining." },
    .{ .code = "use-if-assign", .severity = .hint, .summary = "A local exists only for the truth test of the next if." },
    .{ .code = "use-interpolation", .severity = .hint, .summary = "A chain of three or more concatenations mixes literals and values." },
    .{ .code = "use-for-from", .severity = .hint, .summary = "A generic for copies fields of its only loop variable into same-named locals." },
    .{ .code = "concat-in-loop", .severity = .hint, .summary = "A string grows by concatenation in a loop, which copies it on every pass." },
    .{ .code = "insert-front-in-loop", .severity = .hint, .summary = "table.insert(t, 1, v) in a loop moves the whole list on every pass." },
    .{ .code = "closure-in-loop", .severity = .hint, .summary = "A function created in a loop captures nothing the loop declares." },
    .{ .code = "select-in-loop", .severity = .hint, .summary = "select(i, ...) in a loop copies the arguments on every pass." },
    .{ .code = "table-to-group", .severity = .hint, .summary = "A table that never leaves its function holds only named fields." },
    .{ .code = "pairs-over-list", .severity = .hint, .summary = "pairs iterates a table built as a list." },
    .{ .code = "format-to-interpolation", .severity = .hint, .summary = "string.format has a format of literal text and %s only." },
    .{ .code = "redundant-tostring", .severity = .hint, .summary = "tostring of a number is an operand of a concatenation." },
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
        try l.reportFix(span, severity, code, &.{}, fmt, args);
    }

    fn reportFix(l: *Linter, span: Span, severity: Severity, code: []const u8, fix: []const Edit, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try l.out.append(l.arena, .{
            .span = span,
            .severity = severity,
            .code = code,
            .message = try std.fmt.allocPrint(l.arena, fmt, args),
            .fix = fix,
        });
    }

    /// One edit that replaces `span` with `text`.
    fn edit(l: *Linter, span: Span, text_: []const u8) Allocator.Error![]const Edit {
        const list = try l.arena.alloc(Edit, 1);
        list[0] = .{ .span = span, .text = text_ };
        return list;
    }

    /// The edit that starts the name of an unused binding with `_`. A
    /// binding that is assigned keeps its name, because the assignments
    /// would then reach another variable. So does a local group or a local
    /// with attributes, whose handlers receive the name. The debug library
    /// sees the new name, as `debug.getlocal` does.
    fn underscore(l: *Linter, b: *const resolve.Binding) Allocator.Error![]const Edit {
        if (b.writes > 0 or b.kind == .group) return &.{};
        const after = std.mem.trimStart(u8, l.chunk.source[@min(b.span.end, l.chunk.source.len)..], " \t");
        if (after.len > 0 and after[0] == '<') return &.{};
        return l.edit(.{ .start = b.span.start, .end = b.span.start }, "_");
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
                .param => try l.reportFix(b.span, .warning, "unused-param", try l.underscore(b), "unused parameter '{s}'", .{b.name}),
                .loop_var => try l.reportFix(b.span, .warning, "unused-loop-var", try l.underscore(b), "unused loop variable '{s}'", .{b.name}),
                .function => try l.reportFix(b.span, .warning, "unused-function", try l.underscore(b), "unused local function '{s}'", .{b.name}),
                else => if (b.writes > 0)
                    try l.report(b.span, .warning, "unused-local", "local '{s}' is assigned but never read", .{b.name})
                else
                    try l.reportFix(b.span, .warning, "unused-local", try l.underscore(b), "unused local '{s}'", .{b.name}),
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
        var rewrite: std.ArrayList(u8) = .empty;
        try rewrite.appendSlice(l.arena, "local ");
        for (names, 0..) |n, i| {
            if (i > 0) try rewrite.appendSlice(l.arena, ", ");
            try rewrite.appendSlice(l.arena, n.name.text);
        }
        try rewrite.print(l.arena, " from {s}", .{base.?});
        try l.reportFix(s.span, .hint, "use-from", try l.edit(s.span, rewrite.items), "use 'from' destructuring: local ... from {s}", .{base.?});
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
            try l.report(s.span, .hint, "use-optional-chain", "nested nil checks can use optional chaining: x?.y?.z", .{});
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
        try l.report(s.span, .hint, "use-if-assign", "local declaration can be moved to the if condition (use if-assignment)", .{});
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
        // The chain is whole when every operand indexes the one before,
        // down to the first, which a rewrite then keeps as its root.
        var root: ?*ast.Expr = null;
        while (cur.kind == .binop and cur.kind.binop.op == .@"and") {
            const lhs = cur.kind.binop.lhs;
            const rhs = cur.kind.binop.rhs;
            const prev = if (lhs.kind == .binop and lhs.kind.binop.op == .@"and") lhs.kind.binop.rhs else lhs;
            if (rhs.kind != .index or !exprEqual(rhs.kind.index.obj, prev)) break;
            depth += 1;
            if (lhs.kind == .binop and lhs.kind.binop.op == .@"and") {
                try l.inner_ands.put(l.arena, lhs, {});
                cur = lhs;
            } else {
                root = lhs;
                break;
            }
        }
        if (depth >= 2) {
            // `a and a.b and a.b.c` yields what `a?.b?.c` yields, `nil` or
            // `false` included, when every step is a field named by `.`.
            var fix: []const Edit = &.{};
            if (root) |r| {
                var steps: std.ArrayList([]const u8) = .empty;
                var x = e.kind.binop.rhs;
                var ok = true;
                for (0..depth) |_| {
                    if (x.kind != .index or !x.kind.index.dot or x.kind.index.key.kind != .string) {
                        ok = false;
                        break;
                    }
                    try steps.append(l.arena, x.kind.index.key.kind.string);
                    x = x.kind.index.obj;
                }
                if (ok and exprEqual(x, r)) {
                    var rewrite: std.ArrayList(u8) = .empty;
                    try rewrite.appendSlice(l.arena, l.text(r.span));
                    var i = steps.items.len;
                    while (i > 0) {
                        i -= 1;
                        try rewrite.print(l.arena, "?.{s}", .{steps.items[i]});
                    }
                    fix = try l.edit(e.span, rewrite.items);
                }
            }
            try l.reportFix(e.span, .hint, "use-optional-chain", fix, "and-chain can use optional chaining: x?.y?.z", .{});
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

// ---------------------------------------------------------------------
// Hints (`spec/design/hints.md`)

/// Walks the tree once for the hints, knowing the innermost loop body of
/// the current function. A function body starts outside every loop, since
/// creating a function does not run it.
const Hints = struct {
    l: *Linter,
    /// The body of the innermost loop of the current function.
    loop: ?Span = null,
    /// The whole statement of that loop, which also holds the variables
    /// its header declares.
    loop_stat: ?Span = null,
    /// The span of the current function, or the whole chunk.
    func: ?Span = null,
    /// Concatenations that are the right operand of another one, which
    /// the outermost one reports.
    inner_concats: std.AutoHashMapUnmanaged(*const ast.Expr, void) = .empty,
    /// Every function span, computed on first use.
    funcs: ?[]Span = null,
    /// The control variables of numeric loops, by the start of their span.
    numeric_vars: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The initializer of each local declared alone, by its span start.
    inits: std.AutoHashMapUnmanaged(u32, *ast.Expr) = .empty,
    /// Locals used in a way that may make them something other than a
    /// list, and the count of reads that keep a list a list.
    not_list: std.AutoHashMapUnmanaged(*resolve.Binding, void) = .empty,
    list_reads: std.AutoHashMapUnmanaged(*resolve.Binding, u32) = .empty,
    /// `for ... in pairs(t)` loops, judged once the walk has seen every
    /// use of `t`.
    pairs_loops: std.ArrayList(struct { span: Span, b: *resolve.Binding }) = .empty,

    fn run(h: *Hints) Allocator.Error!void {
        try h.block(h.l.chunk.block);
        try h.judgePairs();
    }

    fn block(h: *Hints, b: *ast.Block) Allocator.Error!void {
        for (b.stats) |s| try h.stat(s);
    }

    fn loopBody(h: *Hints, b: *ast.Block, stat_span: Span) Allocator.Error!void {
        const saved = h.loop;
        const saved_stat = h.loop_stat;
        h.loop = b.span;
        h.loop_stat = stat_span;
        defer {
            h.loop = saved;
            h.loop_stat = saved_stat;
        }
        try h.block(b);
    }

    fn function(h: *Hints, f: *ast.Function) Allocator.Error!void {
        const sl = h.loop;
        const sls = h.loop_stat;
        const sf = h.func;
        h.loop = null;
        h.loop_stat = null;
        h.func = f.span;
        defer {
            h.loop = sl;
            h.loop_stat = sls;
            h.func = sf;
        }
        try h.block(f.body);
    }

    fn exprs(h: *Hints, list: []*ast.Expr) Allocator.Error!void {
        for (list) |e| try h.expr(e);
    }

    fn cond(h: *Hints, c: ast.Cond) Allocator.Error!void {
        switch (c) {
            .expr => |e| try h.expr(e),
            .assign => |a| try h.exprs(a.values),
            .from => |f| try h.expr(f.source),
            .group => |g| for (g.inits) |init| switch (init) {
                .ctor => |fields| try h.groupFields(fields),
                .copy => {},
            },
        }
    }

    fn groupFields(h: *Hints, fields: []ast.GroupField) Allocator.Error!void {
        for (fields) |f| switch (f.value) {
            .expr => |e| try h.expr(e),
            .group => |sub| try h.groupFields(sub),
        };
    }

    fn stat(h: *Hints, s: *ast.Stat) Allocator.Error!void {
        switch (s.kind) {
            .empty, .break_, .continue_, .goto_, .label, .recovered => {},
            .expr => |e| try h.expr(e),
            .local => |loc| {
                if (loc.names.len == 1 and loc.values.len == 1) try h.inits.put(h.l.arena, loc.names[0].name.span.start, loc.values[0]);
                try h.exprs(loc.values);
                try h.tableToGroup(loc.names, loc.values);
            },
            .local_from => |loc| try h.expr(loc.source),
            .local_group => |loc| for (loc.inits) |init| switch (init) {
                .ctor => |fields| try h.groupFields(fields),
                .copy => {},
            },
            .local_function => |f| {
                try h.closureInLoop(f.func, s.span);
                try h.function(f.func);
            },
            .global => |g| if (g.values) |vals| try h.exprs(vals),
            .global_from => |g| try h.expr(g.source),
            .global_function => |g| try h.function(g.func),
            .assign => |a| {
                for (a.targets) |t| try h.listStore(t);
                try h.exprs(a.targets);
                try h.exprs(a.values);
                try h.concatInLoop(a.targets, a.values, s.span);
            },
            .assign_from => |a| {
                try h.exprs(a.targets);
                try h.expr(a.source);
            },
            .function => |f| try h.function(f.func),
            .do_ => |b| try h.block(b),
            .while_ => |w| {
                try h.cond(w.cond);
                try h.loopBody(w.body, s.span);
            },
            .repeat_ => |r| {
                try h.loopBody(r.body, s.span);
                try h.expr(r.cond);
            },
            .if_ => |i| {
                for (i.clauses) |cl| {
                    try h.cond(cl.cond);
                    try h.block(cl.body);
                }
                if (i.else_) |b| try h.block(b);
            },
            .numeric_for => |f| {
                try h.numeric_vars.put(h.l.arena, f.name.span.start, {});
                try h.expr(f.start);
                try h.expr(f.limit);
                if (f.step) |st| try h.expr(st);
                try h.loopBody(f.body, s.span);
            },
            .generic_for => |f| {
                try h.exprs(f.exprs);
                try h.pairsOverList(f.exprs, s.span);
                try h.forFrom(f.names, f.body, f.from, s.span);
                try h.loopBody(f.body, s.span);
            },
            .return_ => |vals| try h.exprs(vals),
            .provide => |vals| try h.exprs(vals),
            .catch_ => |c| {
                if (c.handler) |hd| try h.expr(hd);
                try h.expr(c.body);
            },
        }
    }

    fn expr(h: *Hints, e: *ast.Expr) Allocator.Error!void {
        switch (e.kind) {
            .nil, .true, .false, .vararg, .integer, .float, .bigint, .decimal, .string, .name, .enum_ => {},
            .interp => |parts| for (parts) |p| switch (p) {
                .text => {},
                .expr => |x| try h.expr(x),
            },
            .function => |f| {
                try h.closureInLoop(f, e.span);
                try h.function(f);
            },
            .table => |fields| for (fields) |f| switch (f.kind) {
                .positional => |x| try h.expr(x),
                .named => |n| try h.expr(n.value),
                .keyed => |k| {
                    try h.expr(k.key);
                    try h.expr(k.value);
                },
            },
            .binop => |b| {
                if (b.op == .concat) try h.concat(e);
                try h.expr(b.lhs);
                try h.expr(b.rhs);
            },
            .unop => |u| {
                if (u.op == .len) if (h.localOf(unparen(u.operand))) |b| try h.listRead(b);
                try h.expr(u.operand);
            },
            .paren => |p| try h.expr(p),
            .index => |ix| {
                if (h.localOf(unparen(ix.obj))) |b| {
                    if (ix.dot) try h.not_list.put(h.l.arena, b, {}) else try h.listRead(b);
                }
                try h.expr(ix.obj);
                try h.expr(ix.key);
            },
            .call => |c| {
                if (c.args.len == 1 and (h.l.isFree(c.callee, "pairs") or h.l.isFree(c.callee, "ipairs"))) {
                    if (h.localOf(unparen(c.args[0]))) |b| try h.listRead(b);
                }
                try h.callHints(e);
                try h.expr(c.callee);
                try h.exprs(c.args);
            },
            .method => |m| {
                try h.methodHints(e);
                try h.expr(m.obj);
                try h.exprs(m.args);
            },
            .slice => |sl| {
                try h.expr(sl.obj);
                if (sl.from) |f| try h.expr(f);
                if (sl.to) |t| try h.expr(t);
            },
            .optional => |o| try h.expr(o),
            .chain => |c| try h.expr(c),
            .catch_ => |c| {
                if (c.handler) |hd| try h.expr(hd);
                try h.expr(c.body);
            },
            .do_ => |b| try h.block(b),
            .query => |q| for (q.sources) |src| try h.expr(src.expr),
        }
    }

    fn report(h: *Hints, span: Span, code: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try h.l.report(span, .hint, code, fmt, args);
    }

    fn reportFix(h: *Hints, span: Span, code: []const u8, fix: []const Edit, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try h.l.reportFix(span, .hint, code, fix, fmt, args);
    }

    /// Whether `e` is a number whatever its operands hold: a numeric
    /// literal, a numeric `for` variable, or arithmetic on such values,
    /// which no metamethod can turn into another type.
    fn isNumberStrict(h: *Hints, e: *const ast.Expr) bool {
        const x = unparen(e);
        return switch (x.kind) {
            .integer, .float => true,
            .binop => |b| switch (b.op) {
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => h.isNumberStrict(b.lhs) and h.isNumberStrict(b.rhs),
                else => false,
            },
            .unop => |u| (u.op == .neg or u.op == .bnot) and h.isNumberStrict(u.operand),
            .name => blk: {
                const b = h.localOf(x) orelse break :blk false;
                break :blk b.kind == .loop_var and h.isNumericForVar(b);
            },
            else => false,
        };
    }

    /// Appends `value` as the text of a string with interpolation.
    fn interpText(h: *Hints, out: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
        for (value) |c| switch (c) {
            '\\' => try out.appendSlice(h.l.arena, "\\\\"),
            '`' => try out.appendSlice(h.l.arena, "\\`"),
            '$' => try out.appendSlice(h.l.arena, "\\$"),
            '\n' => try out.appendSlice(h.l.arena, "\\n"),
            '\r' => try out.appendSlice(h.l.arena, "\\r"),
            '\t' => try out.appendSlice(h.l.arena, "\\t"),
            0...8, 11, 12, 14...31, 127 => try out.print(h.l.arena, "\\{d:0>3}", .{c}),
            else => try out.append(h.l.arena, c),
        };
    }

    /// Appends `e` as an interpolated value: `$name` for a name that the
    /// next text cannot extend, `$(expression)` otherwise.
    fn interpValue(h: *Hints, out: *std.ArrayList(u8), e: *const ast.Expr, next: []const u8) Allocator.Error!void {
        const x = unparen(e);
        const extends = next.len > 0 and (std.ascii.isAlphanumeric(next[0]) or next[0] == '_' or next[0] == '.' or next[0] == '(' or next[0] == '[' or next[0] == ':');
        if (x.kind == .name and !extends) {
            try out.print(h.l.arena, "${s}", .{x.kind.name.text});
        } else try out.print(h.l.arena, "$({s})", .{h.l.text(e.span)});
    }

    fn inLoop(h: *Hints) bool {
        return h.loop != null;
    }

    fn contains(outer: Span, inner: Span) bool {
        return outer.start <= inner.start and inner.end <= outer.end;
    }

    /// The local binding a name refers to, or null for a global.
    fn localOf(h: *Hints, e: *const ast.Expr) ?*resolve.Binding {
        if (e.kind != .name) return null;
        const ref = h.l.res.refAt(e.kind.name.span.start) orelse return null;
        const b = ref.binding orelse return null;
        return switch (b.kind) {
            .local, .param, .loop_var, .function => b,
            else => null,
        };
    }

    /// Whether `e` names the global library function `lib.name`.
    fn isLibCall(h: *Hints, callee: *const ast.Expr, lib: []const u8, name: []const u8) bool {
        if (callee.kind != .index) return false;
        const ix = callee.kind.index;
        if (ix.key.kind != .string or !std.mem.eql(u8, ix.key.kind.string, name)) return false;
        return h.l.isFree(ix.obj, lib);
    }

    // --- speed ---------------------------------------------------------

    /// `s = s .. x` in a loop, with `s` a local declared outside the loop.
    fn concatInLoop(h: *Hints, targets: []*ast.Expr, values: []*ast.Expr, span: Span) Allocator.Error!void {
        if (h.loop == null) return;
        const loop = h.loop_stat.?;
        if (targets.len != 1 or values.len != 1) return;
        const t = targets[0];
        const v = unparen(values[0]);
        if (t.kind != .name or v.kind != .binop or v.kind.binop.op != .concat) return;
        const first = unparen(v.kind.binop.lhs);
        if (first.kind != .name or !std.mem.eql(u8, first.kind.name.text, t.kind.name.text)) return;
        const b = h.localOf(t) orelse return;
        if (contains(loop, b.span)) return;
        try h.report(span, "concat-in-loop", "'{s}' grows by concatenation in a loop: collect the parts in a list and call table.concat once", .{t.kind.name.text});
    }

    /// A function created in a loop that reads nothing the loop declares.
    fn closureInLoop(h: *Hints, f: *ast.Function, span: Span) Allocator.Error!void {
        if (h.loop == null) return;
        const loop = h.loop_stat.?;
        for (h.l.res.refs) |ref| {
            if (!contains(f.span, ref.span)) continue;
            const b = ref.binding orelse continue;
            if (contains(f.span, b.span)) continue;
            if (contains(loop, b.span)) return;
        }
        try h.report(span, "closure-in-loop", "this function captures nothing the loop declares: create it once before the loop", .{});
    }

    fn callHints(h: *Hints, e: *ast.Expr) Allocator.Error!void {
        const c = e.kind.call;
        if (h.inLoop()) {
            if (h.isLibCall(c.callee, "table", "insert") and c.args.len == 3 and c.args[1].kind == .integer and c.args[1].kind.integer == 1) {
                try h.report(e.span, "insert-front-in-loop", "table.insert(t, 1, v) in a loop moves every element on each pass: append, then reverse the list once", .{});
            }
            if (h.l.isFree(c.callee, "select") and c.args.len == 2 and c.args[1].kind == .vararg and !(c.args[0].kind == .string and std.mem.eql(u8, c.args[0].kind.string, "#"))) {
                try h.report(e.span, "select-in-loop", "select(i, ...) in a loop copies the arguments on each pass: call table.pack(...) once and index it", .{});
            }
        }
        if (h.isLibCall(c.callee, "string", "format") and c.args.len >= 1) try h.formatHint(e, c.args[0], c.args[1..]);
    }

    fn methodHints(h: *Hints, e: *ast.Expr) Allocator.Error!void {
        const m = e.kind.method;
        if (std.mem.eql(u8, m.name.text, "format")) {
            const obj = unparen(m.obj);
            if (obj.kind == .string) try h.formatHint(e, obj, m.args);
        }
    }

    /// `string.format` with a literal format of text and `%s` only.
    fn formatHint(h: *Hints, e: *ast.Expr, fmt: *const ast.Expr, args: []*ast.Expr) Allocator.Error!void {
        const nargs = args.len;
        const f = unparen(fmt);
        if (f.kind != .string) return;
        const text = f.kind.string;
        var n: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '%') continue;
            if (i + 1 >= text.len) return;
            switch (text[i + 1]) {
                's' => n += 1,
                '%' => {},
                else => return,
            }
            i += 1;
        }
        if (n == 0 or n != nargs) return;
        // `%s` converts a value as interpolation does, so the rewrite
        // writes the same string.
        var rewrite: std.ArrayList(u8) = .empty;
        try rewrite.append(h.l.arena, '`');
        var arg: usize = 0;
        var j: usize = 0;
        while (j < text.len) : (j += 1) {
            if (text[j] == '%' and text[j + 1] == '%') {
                try h.interpText(&rewrite, "%");
                j += 1;
            } else if (text[j] == '%') {
                const next_text = blk: {
                    const rest = text[j + 2 ..];
                    break :blk if (rest.len > 0 and rest[0] == '%' and rest.len > 1 and rest[1] == 's') "" else rest;
                };
                try h.interpValue(&rewrite, args[arg], next_text);
                arg += 1;
                j += 1;
            } else try h.interpText(&rewrite, text[j .. j + 1]);
        }
        try rewrite.append(h.l.arena, '`');
        try h.reportFix(e.span, "format-to-interpolation", try h.l.edit(e.span, rewrite.items), "this format holds only %s: a string with interpolation is faster", .{});
    }

    /// `local t = { a = ..., b = ... }` in a function, where every use of
    /// `t` reads or writes one of those fields with a dot.
    fn tableToGroup(h: *Hints, names: []ast.AttName, values: []*ast.Expr) Allocator.Error!void {
        if (h.func == null or names.len != 1 or values.len != 1) return;
        if (names[0].attribs.len != 0) return;
        const ctor = unparen(values[0]);
        if (ctor.kind != .table or ctor.kind.table.len == 0) return;
        for (ctor.kind.table) |f| if (f.kind != .named) return;
        const b = h.l.bindingAt(names[0].name.span) orelse return;
        if (b.writes != 0 or b.reads == 0) return;
        const func = h.func.?;
        var uses: Uses = .{ .h = h, .b = b, .ctor = ctor, .func = func };
        const v: @import("walk.zig").Visitor(*Uses) = .{ .ctx = &uses, .func = Uses.visit };
        v.block(h.l.chunk.block) catch return error.OutOfMemory;
        if (uses.bad or uses.dotted != b.reads) return;
        try h.report(names[0].name.span, "table-to-group", "'{s}' never leaves this function: declare it <group> to keep its fields in locals", .{b.name});
    }

    const Uses = struct {
        h: *Hints,
        b: *resolve.Binding,
        ctor: *const ast.Expr,
        func: Span,
        dotted: u32 = 0,
        bad: bool = false,

        fn visit(u: *Uses, slot: **ast.Expr) anyerror!void {
            const e = slot.*;
            if (e.kind != .index or !e.kind.index.dot) return;
            const obj = e.kind.index.obj;
            if (obj.kind != .name) return;
            const ref = u.h.l.res.refAt(obj.kind.name.span.start) orelse return;
            if (ref.binding != u.b) return;
            // A use in a nested function captures the table.
            if (u.h.innermostFunction(ref.span)) |fs| if (fs.start != u.func.start) {
                u.bad = true;
            };
            const key = e.kind.index.key.kind.string;
            var known = false;
            for (u.ctor.kind.table) |f| if (std.mem.eql(u8, f.kind.named.name.text, key)) {
                known = true;
            };
            if (!known) u.bad = true;
            u.dotted += 1;
        }
    };

    /// The span of the innermost function that contains `span`.
    fn innermostFunction(h: *Hints, span: Span) ?Span {
        if (h.funcs == null) {
            var f: FuncFinder = .{ .arena = h.l.arena };
            const v: @import("walk.zig").Visitor(*FuncFinder) = .{ .ctx = &f, .func = FuncFinder.visit };
            v.block(h.l.chunk.block) catch {};
            for (h.l.chunk.block.stats) |s| f.stat(s);
            h.funcs = f.spans.items;
        }
        var best: ?Span = null;
        for (h.funcs.?) |fs| {
            if (!contains(fs, span)) continue;
            if (best) |b| if (b.end - b.start <= fs.end - fs.start) continue;
            best = fs;
        }
        return best;
    }

    const FuncFinder = struct {
        arena: Allocator,
        spans: std.ArrayList(Span) = .empty,

        fn consider(f: *FuncFinder, span: Span) void {
            f.spans.append(f.arena, span) catch {};
        }
        fn visit(f: *FuncFinder, slot: **ast.Expr) anyerror!void {
            if (slot.*.kind == .function) f.consider(slot.*.kind.function.span);
        }
        fn stat(f: *FuncFinder, s: *ast.Stat) void {
            switch (s.kind) {
                .local_function => |x| f.consider(x.func.span),
                .global_function => |x| f.consider(x.func.span),
                .function => |x| f.consider(x.func.span),
                else => {},
            }
            switch (s.kind) {
                .local_function => |x| for (x.func.body.stats) |c| f.stat(c),
                .global_function => |x| for (x.func.body.stats) |c| f.stat(c),
                .function => |x| for (x.func.body.stats) |c| f.stat(c),
                .do_ => |b| for (b.stats) |c| f.stat(c),
                .while_ => |w| for (w.body.stats) |c| f.stat(c),
                .repeat_ => |r| for (r.body.stats) |c| f.stat(c),
                .numeric_for => |n| for (n.body.stats) |c| f.stat(c),
                .generic_for => |g| for (g.body.stats) |c| f.stat(c),
                .if_ => |i| {
                    for (i.clauses) |cl| for (cl.body.stats) |c| f.stat(c);
                    if (i.else_) |b| for (b.stats) |c| f.stat(c);
                },
                else => {},
            }
        }
    };

    fn listRead(h: *Hints, b: *resolve.Binding) Allocator.Error!void {
        const gop = try h.list_reads.getOrPut(h.l.arena, b);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    /// A store into `t[k]` keeps `t` a list only when `k` is `#t + 1`.
    fn listStore(h: *Hints, target: *const ast.Expr) Allocator.Error!void {
        if (target.kind != .index) return;
        const b = h.localOf(unparen(target.kind.index.obj)) orelse return;
        if (!isLenPlusOne(target.kind.index.key, target.kind.index.obj)) try h.not_list.put(h.l.arena, b, {});
    }

    /// `pairs(t)` where `t` is a local list: built by a constructor of
    /// positional items and grown only by `t[#t + 1] = v`.
    fn pairsOverList(h: *Hints, exprs_: []*ast.Expr, span: Span) Allocator.Error!void {
        if (exprs_.len != 1) return;
        const call = unparen(exprs_[0]);
        if (call.kind != .call or !h.l.isFree(call.kind.call.callee, "pairs") or call.kind.call.args.len != 1) return;
        const b = h.localOf(unparen(call.kind.call.args[0])) orelse return;
        if (b.kind != .local or b.writes != 0) return;
        try h.pairs_loops.append(h.l.arena, .{ .span = span, .b = b });
    }

    /// Reports the `pairs` loops over lists. Every read of the list must
    /// index it, take its length, or pass it to `pairs` or `ipairs`, since
    /// any other use, such as passing it to a function, may add keys.
    fn judgePairs(h: *Hints) Allocator.Error!void {
        for (h.pairs_loops.items) |pl| {
            const init = h.inits.get(pl.b.span.start) orelse continue;
            const ctor = unparen(init);
            if (ctor.kind != .table) continue;
            var positional = true;
            for (ctor.kind.table) |f| if (f.kind != .positional) {
                positional = false;
            };
            if (!positional or h.not_list.contains(pl.b)) continue;
            if ((h.list_reads.get(pl.b) orelse 0) != pl.b.reads) continue;
            try h.report(pl.span, "pairs-over-list", "'{s}' is a list: ipairs walks it faster and in order", .{pl.b.name});
        }
    }

    fn isLenPlusOne(key: *const ast.Expr, obj: *const ast.Expr) bool {
        const k = unparen(key);
        if (k.kind != .binop or k.kind.binop.op != .add) return false;
        const l = unparen(k.kind.binop.lhs);
        const r = unparen(k.kind.binop.rhs);
        if (r.kind != .integer or r.kind.integer != 1) return false;
        if (l.kind != .unop or l.kind.unop.op != .len) return false;
        return exprEqual(l.kind.unop.operand, obj);
    }

    // --- concatenation -------------------------------------------------

    /// The outermost node of a concatenation chain reports both
    /// concatenation hints.
    fn concat(h: *Hints, e: *ast.Expr) Allocator.Error!void {
        if (h.inner_concats.contains(e)) return;
        var operands: std.ArrayList(*ast.Expr) = .empty;
        try h.flattenConcat(e, &operands);
        var literals: usize = 0;
        var values: usize = 0;
        for (operands.items) |op| {
            const x = unparen(op);
            if (x.kind == .string) literals += 1 else values += 1;
            if (x.kind == .call and h.l.isFree(x.kind.call.callee, "tostring") and x.kind.call.args.len == 1 and h.isNumber(x.kind.call.args[0])) {
                // Without tostring, `..` converts the number to the same
                // text. Only a number that no metamethod can replace keeps
                // the rewrite exact.
                const arg = x.kind.call.args[0];
                var fix: []const Edit = &.{};
                if (h.isNumberStrict(arg)) {
                    const inner = h.l.text(arg.span);
                    const a = unparen(arg);
                    fix = try h.l.edit(x.span, if (a.kind == .binop) try std.fmt.allocPrint(h.l.arena, "({s})", .{inner}) else inner);
                }
                try h.reportFix(x.span, "redundant-tostring", fix, "concatenation converts the number itself: tostring is redundant here", .{});
            }
        }
        if (operands.items.len >= 3 and literals > 0 and values > 0) {
            // `..` raises an error for a value that is no string or number,
            // which interpolation would write, so the rewrite applies only
            // when every value is known to be a number.
            var exact = true;
            for (operands.items) |op| {
                const x = unparen(op);
                if (x.kind != .string and !h.isNumberStrict(x)) exact = false;
            }
            var fix: []const Edit = &.{};
            if (exact) {
                var rewrite: std.ArrayList(u8) = .empty;
                try rewrite.append(h.l.arena, '`');
                for (operands.items, 0..) |op, i| {
                    const x = unparen(op);
                    if (x.kind == .string) {
                        try h.interpText(&rewrite, x.kind.string);
                    } else {
                        const next = if (i + 1 < operands.items.len and unparen(operands.items[i + 1]).kind == .string) unparen(operands.items[i + 1]).kind.string else "";
                        try h.interpValue(&rewrite, op, next);
                    }
                }
                try rewrite.append(h.l.arena, '`');
                fix = try h.l.edit(e.span, rewrite.items);
            }
            try h.reportFix(e.span, "use-interpolation", fix, "a string with interpolation writes this concatenation in one piece", .{});
        }
    }

    fn flattenConcat(h: *Hints, e: *ast.Expr, out: *std.ArrayList(*ast.Expr)) Allocator.Error!void {
        if (e.kind == .binop and e.kind.binop.op == .concat) {
            const b = e.kind.binop;
            try h.flattenConcat(b.lhs, out);
            if (b.rhs.kind == .binop and b.rhs.kind.binop.op == .concat) try h.inner_concats.put(h.l.arena, b.rhs, {});
            if (b.lhs.kind == .binop and b.lhs.kind.binop.op == .concat) try h.inner_concats.put(h.l.arena, b.lhs, {});
            try h.flattenConcat(b.rhs, out);
            return;
        }
        try out.append(h.l.arena, e);
    }

    /// Whether `e` is known to be a number: a numeral, arithmetic, or a
    /// numeric `for` variable.
    fn isNumber(h: *Hints, e: *const ast.Expr) bool {
        const x = unparen(e);
        return switch (x.kind) {
            .integer, .float => true,
            .binop => |b| switch (b.op) {
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => true,
                else => false,
            },
            .unop => |u| u.op == .neg or u.op == .len or u.op == .bnot,
            .name => blk: {
                const b = h.localOf(x) orelse break :blk false;
                break :blk b.kind == .loop_var and h.isNumericForVar(b);
            },
            else => false,
        };
    }

    fn isNumericForVar(h: *Hints, b: *resolve.Binding) bool {
        return h.numeric_vars.contains(b.span.start);
    }

    // --- concise code --------------------------------------------------

    /// `for r in it do local a, b = r.a, r.b ... end`, where `r` serves
    /// only those copies.
    fn forFrom(h: *Hints, names: []ast.Name, body: *ast.Block, from: bool, span: Span) Allocator.Error!void {
        if (from or names.len != 1 or body.stats.len == 0) return;
        const first = body.stats[0];
        const loc = switch (first.kind) {
            .local => |x| x,
            else => return,
        };
        if (loc.names.len == 0 or loc.names.len != loc.values.len) return;
        for (loc.names, loc.values) |n, v| {
            if (n.attribs.len != 0) return;
            if (v.kind != .index or !v.kind.index.dot) return;
            const obj = v.kind.index.obj;
            if (obj.kind != .name or !std.mem.eql(u8, obj.kind.name.text, names[0].text)) return;
            if (!std.mem.eql(u8, v.kind.index.key.kind.string, n.name.text)) return;
        }
        const b = h.l.bindingAt(names[0].span) orelse return;
        if (b.reads != loc.names.len or b.writes != 0) return;
        try h.report(span, "use-for-from", "the loop copies fields of '{s}' into locals: for ... from reads them directly", .{names[0].text});
        // The same copy also matches use-from, which this hint replaces.
        var i: usize = 0;
        while (i < h.l.out.items.len) {
            const d = h.l.out.items[i];
            if (std.mem.eql(u8, d.code, "use-from") and d.span.start == first.span.start) {
                _ = h.l.out.orderedRemove(i);
            } else i += 1;
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

pub const Position = struct { line: u32, column: u32 };

/// The one-based line and column of a byte offset. Columns count
/// characters.
pub fn position(src: []const u8, offset: u32) Position {
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
    var hw: Hints = .{ .l = &l };
    try hw.run();

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
