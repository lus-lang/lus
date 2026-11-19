//! Recursive descent parser producing the syntax tree. It follows
//! spec/language/grammar.md, including its disambiguation rules. All nodes
//! are allocated in the arena passed to `parse`.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const Tag = token.Tag;
const Token = token.Token;
const Span = token.Span;
const Allocator = std.mem.Allocator;

pub const Error = error{SyntaxError} || Allocator.Error;

pub const Diagnostic = struct {
    message: []const u8,
    line: u32,
    span: Span,
    /// Index of the current token when the error was raised.
    tok: u32 = 0,
};

pub const Options = struct {
    /// Chunk name as given to `load` ("@file", "=stdin", or source text).
    chunkname: []const u8 = "?",
};

const max_depth = 200;
/// Depth limit for the expression tree. A chain of suffixes or of left
/// associative operators adds one level per link, and the later passes
/// recurse once per level, so this bounds their native stack use. A wasm
/// engine also keeps its own call stack of about a megabyte, which holds
/// fewer levels than the native main thread.
const max_tree: u32 = if (@import("builtin").cpu.arch.isWasm()) 2000 else 8000;

pub const Parser = struct {
    arena: Allocator,
    src: []const u8,
    toks: []Token,
    payloads: []lexer.Payload,
    pos: u32 = 0,
    depth: u32 = 0,
    /// Depth of the expression tree being built, counted per chain link.
    tree: u32 = 0,
    /// Nesting of do-expressions in the current function, for `provide`.
    do_depth: u32 = 0,
    /// Nesting of loops in the current function, for `break`.
    loop_depth: u32 = 0,
    in_query: bool = false,
    diag: ?Diagnostic = null,
    chunkname: []const u8,
    /// Error recovery for the tooling (`debug.parse`). A token that
    /// cannot start a statement becomes a `recovered` statement and the
    /// parser skips to the next synchronization token. A block closer
    /// with no open block at the top level is recovered the same way.
    recover: bool = false,
    /// Statements of the main chunk, kept here so that they survive a
    /// syntax error and the tooling can report a partial tree.
    top: std.ArrayList(*ast.Stat) = .empty,
    /// Every recovered statement, in the order the parser created them.
    recovered: std.ArrayList(*ast.Stat) = .empty,

    // -----------------------------------------------------------------
    // Token helpers

    inline fn cur(p: *Parser) Token {
        return p.toks[p.pos];
    }
    inline fn tag(p: *Parser) Tag {
        return p.toks[p.pos].tag;
    }
    inline fn peekTag(p: *Parser, n: u32) Tag {
        const i = @min(p.pos + n, @as(u32, @intCast(p.toks.len - 1)));
        return p.toks[i].tag;
    }
    inline fn advance(p: *Parser) Token {
        const t = p.toks[p.pos];
        if (p.pos + 1 < p.toks.len) p.pos += 1;
        return t;
    }
    fn prevLine(p: *Parser) u32 {
        return if (p.pos == 0) 1 else p.toks[p.pos - 1].line;
    }
    fn text(p: *Parser, t: Token) []const u8 {
        return switch (p.payloads[t.payload]) {
            .text => |s| s,
            .digits => |s| s,
            else => p.src[t.span.start..t.span.end],
        };
    }
    fn isName(p: *Parser, word: []const u8) bool {
        return p.tag() == .name and std.mem.eql(u8, p.text(p.cur()), word);
    }

    fn tokenDesc(p: *Parser, t: Token) ![]const u8 {
        return switch (t.tag) {
            .eof => "<eof>",
            .interp_begin => "<interp_begin>",
            .interp_mid => "<interp_mid>",
            .interp_end => "<interp_end>",
            .interp_simple => "<interp_simple>",
            .name, .string, .integer, .float, .bigint, .decimal => try std.fmt.allocPrint(p.arena, "'{s}'", .{p.src[t.span.start..t.span.end]}),
            .unknown => try p.unknownDesc(t),
            else => try std.fmt.allocPrint(p.arena, "'{s}'", .{token.describe(t.tag)}),
        };
    }

    /// An unrecognized byte in quotes, or its code when not printable.
    fn unknownDesc(p: *Parser, t: Token) ![]const u8 {
        const c = p.src[t.span.start];
        if (std.ascii.isPrint(c)) return std.fmt.allocPrint(p.arena, "'{c}'", .{c});
        return std.fmt.allocPrint(p.arena, "'<\\{d}>'", .{c});
    }

    /// Syntax error near the current token.
    fn errNear(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const t = p.cur();
        const near = try p.tokenDesc(t);
        const msg = try std.fmt.allocPrint(p.arena, fmt ++ " near {s}", args ++ .{near});
        p.diag = .{ .message = msg, .line = t.line, .span = t.span, .tok = p.pos };
        return error.SyntaxError;
    }

    /// Semantic error at the last consumed token, without a `near` part.
    pub fn errSem(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const msg = try std.fmt.allocPrint(p.arena, fmt, args);
        const t = if (p.pos == 0) p.cur() else p.toks[p.pos - 1];
        p.diag = .{ .message = msg, .line = t.line, .span = t.span, .tok = p.pos };
        return error.SyntaxError;
    }

    fn expect(p: *Parser, t: Tag) Error!Token {
        if (p.tag() != t) return p.errNear("'{s}' expected", .{token.describe(t)});
        return p.advance();
    }

    fn accept(p: *Parser, t: Tag) bool {
        if (p.tag() == t) {
            _ = p.advance();
            return true;
        }
        return false;
    }

    /// `check_match`: closes a construct opened at `line` by `what`.
    fn expectMatch(p: *Parser, t: Tag, what: Tag, line: u32) Error!Token {
        if (p.tag() == t) return p.advance();
        if (line == p.cur().line) return p.errNear("'{s}' expected", .{token.describe(t)});
        return p.errNear("'{s}' expected (to close '{s}' at line {d})", .{ token.describe(t), token.describe(what), line });
    }

    fn expectName(p: *Parser) Error!ast.Name {
        if (p.tag() != .name) return p.errNear("<name> expected", .{});
        const t = p.advance();
        return .{ .text = p.text(t), .span = t.span };
    }

    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > max_depth) return p.errSem("chunk has too many syntax levels (stack overflow)", .{});
    }
    fn leave(p: *Parser) void {
        p.depth -= 1;
    }

    fn grow(p: *Parser) Error!void {
        p.tree += 1;
        if (p.tree > max_tree) return p.errSem("chunk has too many syntax levels (stack overflow)", .{});
    }

    fn new(p: *Parser, comptime T: type, v: T) Error!*T {
        const n = try p.arena.create(T);
        n.* = v;
        return n;
    }

    fn mkExpr(p: *Parser, start: Span, line: u32, kind: ast.Expr.Kind) Error!*ast.Expr {
        const end = if (p.pos == 0) start.end else p.toks[p.pos - 1].span.end;
        return p.new(ast.Expr, .{ .span = .{ .start = start.start, .end = @max(end, start.end) }, .line = line, .kind = kind });
    }

    fn mkStat(p: *Parser, start: Span, line: u32, kind: ast.Stat.Kind) Error!*ast.Stat {
        const end = if (p.pos == 0) start.end else p.toks[p.pos - 1].span.end;
        return p.new(ast.Stat, .{ .span = .{ .start = start.start, .end = @max(end, start.end) }, .line = line, .kind = kind });
    }

    // -----------------------------------------------------------------
    // Blocks

    fn blockFollow(p: *Parser, with_until: bool) bool {
        return switch (p.tag()) {
            .kw_else, .kw_elseif, .kw_end, .eof => true,
            .kw_until => with_until,
            else => false,
        };
    }

    fn block(p: *Parser) Error!*ast.Block {
        return p.blockIn(false);
    }

    /// The body of a loop, where `break` is allowed.
    fn loopBody(p: *Parser) Error!*ast.Block {
        p.loop_depth += 1;
        defer p.loop_depth -= 1;
        return p.blockIn(false);
    }

    /// Parses a statement list. The main chunk (`top`) collects its
    /// statements in `p.top`.
    fn blockIn(p: *Parser, top: bool) Error!*ast.Block {
        const start = p.cur().span;
        var local: std.ArrayList(*ast.Stat) = .empty;
        const stats = if (top) &p.top else &local;
        while (true) {
            if (p.blockFollow(true)) {
                if (top and p.recover) switch (p.tag()) {
                    .kw_end, .kw_else, .kw_elseif, .kw_until => {
                        try stats.append(p.arena, try p.recoveredStat(" (no matching block)"));
                        _ = p.advance();
                        continue;
                    },
                    else => {},
                };
                break;
            }
            if (p.tag() == .kw_return or p.tag() == .kw_provide) {
                try stats.append(p.arena, try p.statement());
                break; // last statement
            }
            if (p.recover and !canStartStatement(p.tag())) {
                try stats.append(p.arena, try p.recoveredStat(""));
                while (!isSyncToken(p.tag())) _ = p.advance();
                _ = p.accept(.semicolon);
                continue;
            }
            try stats.append(p.arena, try p.statement());
        }
        const end_span = if (p.pos == 0) start else p.toks[p.pos - 1].span;
        return p.new(ast.Block, .{
            .stats = if (top) try p.arena.dupe(*ast.Stat, stats.items) else try stats.toOwnedSlice(p.arena),
            .span = .{ .start = start.start, .end = @max(start.start, end_span.end) },
            .end_line = p.cur().line,
        });
    }

    // -----------------------------------------------------------------
    // Error recovery

    fn canStartStatement(t: Tag) bool {
        return switch (t) {
            .semicolon, .kw_if, .kw_while, .kw_do, .kw_for, .kw_repeat, .kw_function, .kw_local, .kw_global, .dbcolon, .kw_return, .kw_provide, .kw_break, .kw_continue, .kw_catch, .kw_goto, .name, .lparen => true,
            else => false,
        };
    }

    fn isSyncToken(t: Tag) bool {
        return switch (t) {
            .semicolon, .kw_end, .kw_else, .kw_elseif, .kw_until, .kw_return, .kw_local, .kw_function, .kw_if, .kw_while, .kw_for, .kw_repeat, .kw_do, .kw_break, .kw_goto, .eof => true,
            else => false,
        };
    }

    /// Records a recovered statement for the current token. The message
    /// reads "unexpected 'X'", where X names the token the way the
    /// reference parser does: symbols and keywords keep their own quotes
    /// and other tokens are named by their class.
    fn recoveredStat(p: *Parser, suffix: []const u8) Error!*ast.Stat {
        const t = p.cur();
        const name: []const u8 = switch (t.tag) {
            .name => "<name>",
            .string => "<string>",
            .integer => "<integer>",
            .float, .bigint, .decimal => "<number>",
            .interp_begin => "<interp_begin>",
            .interp_mid => "<interp_mid>",
            .interp_end => "<interp_end>",
            .interp_simple => "<interp_simple>",
            .eof => "<eof>",
            .unknown => try p.unknownDesc(t),
            else => try std.fmt.allocPrint(p.arena, "'{s}'", .{token.describe(t.tag)}),
        };
        const msg = try std.fmt.allocPrint(p.arena, "unexpected '{s}'{s}", .{ name, suffix });
        const s = try p.new(ast.Stat, .{ .span = t.span, .line = t.line, .kind = .{ .recovered = msg } });
        try p.recovered.append(p.arena, s);
        return s;
    }

    fn setPartial(p: *Parser, partial: *Partial, chunkname: []const u8) void {
        partial.stats = p.top.items;
        partial.recovered = p.recovered.items;
        var d = p.diag.?;
        d.message = std.fmt.allocPrint(p.arena, "{s}:{d}: {s}", .{ chunkDisplay(p.arena, chunkname), d.line, d.message }) catch d.message;
        partial.diag = d;
    }

    // -----------------------------------------------------------------
    // Statements

    fn statement(p: *Parser) Error!*ast.Stat {
        try p.enter();
        defer p.leave();
        const t = p.cur();
        const line = t.line;
        switch (t.tag) {
            .semicolon => {
                _ = p.advance();
                return p.mkStat(t.span, line, .empty);
            },
            .kw_if => return p.ifStat(),
            .kw_while => return p.whileStat(),
            .kw_do => {
                _ = p.advance();
                const b = try p.block();
                _ = try p.expectMatch(.kw_end, .kw_do, line);
                return p.mkStat(t.span, line, .{ .do_ = b });
            },
            .kw_for => return p.forStat(),
            .kw_repeat => {
                _ = p.advance();
                const b = try p.loopBody();
                _ = try p.expectMatch(.kw_until, .kw_repeat, line);
                const cond = try p.expr();
                return p.mkStat(t.span, line, .{ .repeat_ = .{ .body = b, .cond = cond } });
            },
            .kw_function => return p.functionStat(),
            .kw_local => {
                _ = p.advance();
                if (p.accept(.kw_function)) {
                    const name = try p.expectName();
                    const f = try p.funcBody(false, line, name.text);
                    return p.mkStat(t.span, line, .{ .local_function = .{ .name = name, .func = f } });
                }
                return p.localStat(t.span, line);
            },
            .kw_global => {
                _ = p.advance();
                if (p.accept(.kw_function)) {
                    const name = try p.expectName();
                    const f = try p.funcBody(false, line, name.text);
                    return p.mkStat(t.span, line, .{ .global_function = .{ .name = name, .func = f } });
                }
                return p.globalStat(t.span, line);
            },
            .dbcolon => {
                _ = p.advance();
                const name = try p.expectName();
                _ = try p.expect(.dbcolon);
                return p.mkStat(t.span, line, .{ .label = name });
            },
            .kw_return => {
                _ = p.advance();
                var vals: []*ast.Expr = &.{};
                if (!p.blockFollow(true) and p.tag() != .semicolon) vals = try p.exprList();
                _ = p.accept(.semicolon);
                // The block ends here. Whatever follows is reported by
                // the construct that encloses the block.
                return p.mkStat(t.span, line, .{ .return_ = vals });
            },
            .kw_provide => {
                if (p.do_depth == 0) return p.errNear("'provide' outside do expression", .{});
                _ = p.advance();
                var vals: []*ast.Expr = &.{};
                if (!p.blockFollow(true) and p.tag() != .semicolon) vals = try p.exprList();
                return p.mkStat(t.span, line, .{ .provide = vals });
            },
            .kw_break => {
                if (p.loop_depth == 0) return p.errNear("break outside loop", .{});
                _ = p.advance();
                return p.mkStat(t.span, line, .break_);
            },
            .kw_continue => {
                _ = p.advance();
                return p.mkStat(t.span, line, .continue_);
            },
            .kw_goto => {
                _ = p.advance();
                const name = try p.expectName();
                return p.mkStat(t.span, line, .{ .goto_ = name });
            },
            .kw_catch => {
                const c = try p.catchBody();
                return p.mkStat(t.span, line, .{ .catch_ = c });
            },
            else => return p.exprStat(),
        }
    }

    fn exprStat(p: *Parser) Error!*ast.Stat {
        const start = p.cur().span;
        const line = p.cur().line;
        const first = try p.suffixedExpr();
        if (p.tag() == .assign or p.tag() == .comma or p.tag() == .kw_from) {
            var targets: std.ArrayList(*ast.Expr) = .empty;
            try p.checkTarget(first);
            try targets.append(p.arena, first);
            while (p.accept(.comma)) {
                const e = try p.suffixedExpr();
                try p.checkTarget(e);
                try targets.append(p.arena, e);
            }
            if (p.accept(.kw_from)) {
                const src = try p.expr();
                return p.mkStat(start, line, .{ .assign_from = .{ .targets = try targets.toOwnedSlice(p.arena), .source = src } });
            }
            _ = try p.expect(.assign);
            const vals = try p.exprList();
            return p.mkStat(start, line, .{ .assign = .{ .targets = try targets.toOwnedSlice(p.arena), .values = vals } });
        }
        switch (first.kind) {
            .call, .method => {},
            else => return p.errNear("syntax error", .{}),
        }
        return p.mkStat(start, line, .{ .expr = first });
    }

    fn checkTarget(p: *Parser, e: *ast.Expr) Error!void {
        switch (e.kind) {
            .name => {},
            .index => {},
            else => return p.errNear("syntax error", .{}),
        }
    }

    fn ifStat(p: *Parser) Error!*ast.Stat {
        const start = p.cur().span;
        const line = p.cur().line;
        var clauses: std.ArrayList(ast.IfClause) = .empty;
        _ = p.advance(); // if
        var cl_line = line;
        while (true) {
            const cond = try p.condition();
            _ = try p.expect(.kw_then);
            const b = try p.block();
            try clauses.append(p.arena, .{ .cond = cond, .body = b, .line = cl_line });
            if (p.tag() == .kw_elseif) {
                cl_line = p.cur().line;
                _ = p.advance();
                continue;
            }
            break;
        }
        var else_block: ?*ast.Block = null;
        if (p.accept(.kw_else)) else_block = try p.block();
        _ = try p.expectMatch(.kw_end, .kw_if, line);
        return p.mkStat(start, line, .{ .if_ = .{ .clauses = try clauses.toOwnedSlice(p.arena), .else_ = else_block } });
    }

    fn whileStat(p: *Parser) Error!*ast.Stat {
        const start = p.cur().span;
        const line = p.cur().line;
        _ = p.advance();
        const cond = try p.condition();
        _ = try p.expect(.kw_do);
        const b = try p.loopBody();
        _ = try p.expectMatch(.kw_end, .kw_while, line);
        return p.mkStat(start, line, .{ .while_ = .{ .cond = cond, .body = b } });
    }

    /// True when the condition after if/elseif/while is an assignment
    /// condition (grammar section 2.1).
    fn isAssignCond(p: *Parser) bool {
        if (p.tag() != .name) return false;
        const nt = p.peekTag(1);
        if (nt == .assign or nt == .comma or nt == .kw_from) return true;
        if (nt == .lt) {
            const lt = p.toks[p.pos + 1];
            const after = lt.span.end;
            if (after < p.src.len) {
                const ch = p.src[after];
                return std.ascii.isAlphabetic(ch) or ch == '_';
            }
        }
        return false;
    }

    fn condition(p: *Parser) Error!ast.Cond {
        if (!p.isAssignCond()) return .{ .expr = try p.expr() };
        const names = try p.attNameList();
        var any_group = false;
        for (names) |n| {
            if (n.has(.group)) any_group = true;
        }
        if (p.accept(.kw_from)) {
            const src = try p.expr();
            return .{ .from = .{ .names = names, .source = src } };
        }
        _ = try p.expect(.assign);
        if (any_group) {
            const inits = try p.groupInits();
            return .{ .group = .{ .names = names, .inits = inits } };
        }
        const vals = try p.exprList();
        return .{ .assign = .{ .names = names, .values = vals } };
    }

    fn forStat(p: *Parser) Error!*ast.Stat {
        const start = p.cur().span;
        const line = p.cur().line;
        _ = p.advance();
        const n1 = try p.expectName();
        if (p.accept(.assign)) {
            const s = try p.expr();
            _ = try p.expect(.comma);
            const lim = try p.expr();
            var step: ?*ast.Expr = null;
            if (p.accept(.comma)) step = try p.expr();
            _ = try p.expect(.kw_do);
            const b = try p.loopBody();
            _ = try p.expectMatch(.kw_end, .kw_for, line);
            return p.mkStat(start, line, .{ .numeric_for = .{ .name = n1, .start = s, .limit = lim, .step = step, .body = b } });
        }
        if (p.tag() != .comma and p.tag() != .kw_in) return p.errNear("'=' or 'in' expected", .{});
        var names: std.ArrayList(ast.Name) = .empty;
        try names.append(p.arena, n1);
        while (p.accept(.comma)) try names.append(p.arena, try p.expectName());
        _ = try p.expect(.kw_in);
        const exprs = try p.exprList();
        _ = try p.expect(.kw_do);
        const b = try p.loopBody();
        _ = try p.expectMatch(.kw_end, .kw_for, line);
        return p.mkStat(start, line, .{ .generic_for = .{ .names = try names.toOwnedSlice(p.arena), .exprs = exprs, .body = b } });
    }

    fn functionStat(p: *Parser) Error!*ast.Stat {
        const start = p.cur().span;
        const line = p.cur().line;
        _ = p.advance();
        var path: std.ArrayList(ast.Name) = .empty;
        try path.append(p.arena, try p.expectName());
        while (p.accept(.dot)) try path.append(p.arena, try p.expectName());
        var method: ?ast.Name = null;
        if (p.accept(.colon)) method = try p.expectName();
        const fname = blk: {
            var buf: std.ArrayList(u8) = .empty;
            for (path.items, 0..) |n, i| {
                if (i > 0) try buf.append(p.arena, '.');
                try buf.appendSlice(p.arena, n.text);
            }
            if (method) |m| {
                try buf.append(p.arena, ':');
                try buf.appendSlice(p.arena, m.text);
            }
            break :blk buf.items;
        };
        const f = try p.funcBody(method != null, line, fname);
        return p.mkStat(start, line, .{ .function = .{ .path = try path.toOwnedSlice(p.arena), .method = method, .func = f } });
    }

    fn localStat(p: *Parser, start: Span, line: u32) Error!*ast.Stat {
        const names = try p.attNameList();
        var any_group = false;
        for (names) |n| {
            if (n.has(.group)) any_group = true;
        }
        if (any_group) {
            _ = try p.expect(.assign);
            const inits = try p.groupInits();
            return p.mkStat(start, line, .{ .local_group = .{ .names = names, .inits = inits } });
        }
        if (p.accept(.kw_from)) {
            const src = try p.expr();
            return p.mkStat(start, line, .{ .local_from = .{ .names = names, .source = src } });
        }
        var vals: []*ast.Expr = &.{};
        if (p.accept(.assign)) vals = try p.exprList();
        return p.mkStat(start, line, .{ .local = .{ .names = names, .values = vals } });
    }

    fn globalStat(p: *Parser, start: Span, line: u32) Error!*ast.Stat {
        var defaults: []ast.Attrib = &.{};
        if (p.tag() == .lt) defaults = try p.attribs();
        if (p.accept(.star)) {
            return p.mkStat(start, line, .{ .global = .{ .default_attribs = defaults, .names = &.{}, .values = null, .star = true } });
        }
        const names = try p.attNameList();
        if (p.accept(.kw_from)) {
            const src = try p.expr();
            return p.mkStat(start, line, .{ .global_from = .{ .default_attribs = defaults, .names = names, .source = src } });
        }
        var vals: ?[]*ast.Expr = null;
        if (p.accept(.assign)) vals = try p.exprList();
        return p.mkStat(start, line, .{ .global = .{ .default_attribs = defaults, .names = names, .values = vals, .star = false } });
    }

    fn attNameList(p: *Parser) Error![]ast.AttName {
        var list: std.ArrayList(ast.AttName) = .empty;
        while (true) {
            const n = try p.expectName();
            var at: []ast.Attrib = &.{};
            if (p.tag() == .lt) at = try p.attribs();
            try list.append(p.arena, .{ .name = n, .attribs = at });
            if (!p.accept(.comma)) break;
        }
        return list.toOwnedSlice(p.arena);
    }

    fn attribs(p: *Parser) Error![]ast.Attrib {
        _ = try p.expect(.lt);
        var list: std.ArrayList(ast.Attrib) = .empty;
        var seen_runtime = false;
        var kind: ?std.meta.Tag(ast.Attrib) = null;
        while (true) {
            var a: ast.Attrib = undefined;
            if (p.isName("const")) {
                _ = p.advance();
                a = .@"const";
            } else if (p.isName("close")) {
                _ = p.advance();
                a = .close;
            } else if (p.isName("group")) {
                _ = p.advance();
                a = .group;
            } else {
                a = .{ .runtime = try p.subExpr(3) };
            }
            if (a != .runtime) {
                if (seen_runtime) return p.errSem("compile-time attribute '{s}' must come before runtime attributes", .{@tagName(a)});
                if (kind) |k| {
                    if (k != a) return p.errSem("conflicting attributes", .{});
                }
                kind = a;
            } else seen_runtime = true;
            try list.append(p.arena, a);
            if (!p.accept(.comma)) break;
        }
        _ = try p.expect(.gt);
        return list.toOwnedSlice(p.arena);
    }

    fn groupInits(p: *Parser) Error![]ast.GroupInit {
        var list: std.ArrayList(ast.GroupInit) = .empty;
        while (true) {
            if (p.tag() == .lbrace) {
                try list.append(p.arena, .{ .ctor = try p.groupCtor() });
            } else if (p.tag() == .name) {
                const n = try p.expectName();
                try list.append(p.arena, .{ .copy = n });
            } else {
                return p.errNear("unexpected symbol", .{});
            }
            if (!p.accept(.comma)) break;
        }
        return list.toOwnedSlice(p.arena);
    }

    fn groupCtor(p: *Parser) Error![]ast.GroupField {
        const line = p.cur().line;
        _ = try p.expect(.lbrace);
        var fields: std.ArrayList(ast.GroupField) = .empty;
        while (p.tag() != .rbrace) {
            const n = try p.expectName();
            var at: []ast.Attrib = &.{};
            if (p.tag() == .lt) at = try p.attribs();
            const an: ast.AttName = .{ .name = n, .attribs = at };
            _ = try p.expect(.assign);
            if (an.has(.group)) {
                if (p.tag() != .lbrace) return p.errNear("unexpected symbol", .{});
                try fields.append(p.arena, .{ .name = an, .value = .{ .group = try p.groupCtor() } });
            } else {
                try fields.append(p.arena, .{ .name = an, .value = .{ .expr = try p.expr() } });
            }
            if (p.tag() == .comma or p.tag() == .semicolon) {
                _ = p.advance();
            } else if (p.tag() != .rbrace) {
                return p.errSem("expected ',' or ';' in group constructor", .{});
            }
        }
        _ = try p.expectMatch(.rbrace, .lbrace, line);
        return fields.toOwnedSlice(p.arena);
    }

    // -----------------------------------------------------------------
    // Functions

    fn funcBody(p: *Parser, is_method: bool, line: u32, name: ?[]const u8) Error!*ast.Function {
        const start = p.cur().span;
        _ = try p.expect(.lparen);
        var params: std.ArrayList(ast.Name) = .empty;
        var is_vararg = false;
        var vararg_name: ?ast.Name = null;
        if (p.tag() != .rparen) {
            while (true) {
                if (p.tag() == .name) {
                    try params.append(p.arena, try p.expectName());
                } else if (p.tag() == .dots) {
                    _ = p.advance();
                    is_vararg = true;
                    if (p.tag() == .name) vararg_name = try p.expectName();
                    break;
                } else return p.errNear("<name> or '...' expected", .{});
                if (!p.accept(.comma)) break;
            }
        }
        _ = try p.expect(.rparen);
        // A function literal starts a new provide scope.
        const saved_do = p.do_depth;
        p.do_depth = 0;
        defer p.do_depth = saved_do;
        const saved_loop = p.loop_depth;
        p.loop_depth = 0;
        defer p.loop_depth = saved_loop;
        const b = try p.block();
        const end_line = p.cur().line;
        _ = try p.expectMatch(.kw_end, .kw_function, line);
        return p.new(ast.Function, .{
            .params = try params.toOwnedSlice(p.arena),
            .is_vararg = is_vararg,
            .vararg_name = vararg_name,
            .is_method = is_method,
            .body = b,
            .line = line,
            .end_line = end_line,
            .span = .{ .start = start.start, .end = p.toks[p.pos - 1].span.end },
            .name = name,
        });
    }

    // -----------------------------------------------------------------
    // Expressions

    pub fn exprList(p: *Parser) Error![]*ast.Expr {
        var list: std.ArrayList(*ast.Expr) = .empty;
        try list.append(p.arena, try p.expr());
        while (p.accept(.comma)) try list.append(p.arena, try p.expr());
        return list.toOwnedSlice(p.arena);
    }

    pub fn expr(p: *Parser) Error!*ast.Expr {
        return p.subExpr(0);
    }

    fn binOpOf(t: Tag) ?ast.BinOp {
        return switch (t) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .idiv => .idiv,
            .percent => .mod,
            .caret => .pow,
            .concat => .concat,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .kw_and => .@"and",
            .kw_or => .@"or",
            .amp => .band,
            .pipe => .bor,
            .tilde => .bxor,
            .shl => .shl,
            .shr => .shr,
            else => null,
        };
    }

    fn unOpOf(t: Tag) ?ast.UnOp {
        return switch (t) {
            .kw_not => .not,
            .minus => .neg,
            .hash => .len,
            .tilde => .bnot,
            else => null,
        };
    }

    fn subExpr(p: *Parser, limit: u8) Error!*ast.Expr {
        try p.enter();
        defer p.leave();
        const start = p.cur().span;
        const line = p.cur().line;
        var left: *ast.Expr = undefined;
        if (unOpOf(p.tag())) |op| {
            _ = p.advance();
            const operand = try p.subExpr(ast.unary_priority);
            left = try p.mkExpr(start, line, .{ .unop = .{ .op = op, .operand = operand } });
        } else {
            left = try p.simpleExpr();
        }
        const saved_tree = p.tree;
        defer p.tree = saved_tree;
        while (binOpOf(p.tag())) |op| {
            const pr = op.priority();
            if (pr[0] <= limit) break;
            try p.grow();
            const op_line = p.cur().line;
            _ = p.advance();
            const right = try p.subExpr(pr[1]);
            left = try p.mkExpr(start, op_line, .{ .binop = .{ .op = op, .lhs = left, .rhs = right } });
        }
        return left;
    }

    fn simpleExpr(p: *Parser) Error!*ast.Expr {
        const t = p.cur();
        const line = t.line;
        switch (t.tag) {
            .integer => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .{ .integer = p.payloads[t.payload].integer });
            },
            .float => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .{ .float = p.payloads[t.payload].float });
            },
            .bigint => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .{ .bigint = p.text(t) });
            },
            .decimal => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .{ .decimal = p.text(t) });
            },
            .string, .interp_simple => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .{ .string = p.text(t) });
            },
            .interp_begin => return p.interpString(),
            .kw_nil => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .nil);
            },
            .kw_true => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .true);
            },
            .kw_false => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .false);
            },
            .dots => {
                _ = p.advance();
                return p.mkExpr(t.span, line, .vararg);
            },
            .lbrace => return p.tableCtor(),
            .kw_function => {
                _ = p.advance();
                const f = try p.funcBody(false, line, null);
                return p.mkExpr(t.span, line, .{ .function = f });
            },
            .kw_catch => {
                const c = try p.catchBody();
                return p.mkExpr(t.span, line, .{ .catch_ = c });
            },
            .kw_do => {
                _ = p.advance();
                p.do_depth += 1;
                const b = try p.block();
                p.do_depth -= 1;
                _ = try p.expectMatch(.kw_end, .kw_do, line);
                return p.mkExpr(t.span, line, .{ .do_ = b });
            },
            .kw_enum => return p.enumExpr(),
            .at => return p.queryExpr(),
            else => return p.suffixedExpr(),
        }
    }

    fn catchBody(p: *Parser) Error!ast.Catch {
        _ = try p.expect(.kw_catch);
        var handler: ?*ast.Expr = null;
        if (p.tag() == .lbracket) {
            const line = p.cur().line;
            _ = p.advance();
            handler = try p.expr();
            _ = try p.expectMatch(.rbracket, .lbracket, line);
        }
        const body = try p.expr();
        return .{ .handler = handler, .body = body };
    }

    fn enumExpr(p: *Parser) Error!*ast.Expr {
        const t = p.advance();
        var names: std.ArrayList(ast.Name) = .empty;
        while (true) {
            const n = try p.expectName();
            for (names.items) |o| {
                if (std.mem.eql(u8, o.text, n.text)) return p.errSem("duplicate enum member '{s}'", .{n.text});
            }
            try names.append(p.arena, n);
            if (names.items.len > 255) return p.errNear("too many names in enum", .{});
            if (!p.accept(.comma)) break;
        }
        _ = try p.expect(.kw_end);
        return p.mkExpr(t.span, t.line, .{ .enum_ = try names.toOwnedSlice(p.arena) });
    }

    fn interpString(p: *Parser) Error!*ast.Expr {
        const start = p.cur();
        var parts: std.ArrayList(ast.InterpPart) = .empty;
        // interp_begin
        var t = p.advance();
        var lit = p.text(t);
        if (lit.len > 0) try parts.append(p.arena, .{ .text = lit });
        while (true) {
            const e = try p.expr();
            try parts.append(p.arena, .{ .expr = e });
            if (p.tag() != .interp_mid and p.tag() != .interp_end) {
                return p.errNear("')' expected", .{});
            }
            t = p.advance();
            lit = p.text(t);
            if (lit.len > 0) try parts.append(p.arena, .{ .text = lit });
            if (t.tag == .interp_end) break;
        }
        return p.mkExpr(start.span, start.line, .{ .interp = try parts.toOwnedSlice(p.arena) });
    }

    fn tableCtor(p: *Parser) Error!*ast.Expr {
        const start = p.cur();
        _ = p.advance();
        var fields: std.ArrayList(ast.Field) = .empty;
        while (p.tag() != .rbrace) {
            if (p.tag() == .lbracket) {
                const bl = p.cur().line;
                _ = p.advance();
                const k = try p.expr();
                _ = try p.expectMatch(.rbracket, .lbracket, bl);
                _ = try p.expect(.assign);
                const v = try p.expr();
                try fields.append(p.arena, .{ .kind = .{ .keyed = .{ .key = k, .value = v } } });
            } else if (p.tag() == .name and p.peekTag(1) == .assign) {
                const n = try p.expectName();
                _ = p.advance();
                const v = try p.expr();
                try fields.append(p.arena, .{ .kind = .{ .named = .{ .name = n, .value = v } } });
            } else {
                try fields.append(p.arena, .{ .kind = .{ .positional = try p.expr() } });
            }
            if (!p.accept(.comma) and !p.accept(.semicolon)) break;
        }
        _ = try p.expectMatch(.rbrace, .lbrace, start.line);
        return p.mkExpr(start.span, start.line, .{ .table = try fields.toOwnedSlice(p.arena) });
    }

    fn primaryExpr(p: *Parser) Error!*ast.Expr {
        const t = p.cur();
        switch (t.tag) {
            .name => {
                const n = try p.expectName();
                return p.mkExpr(t.span, t.line, .{ .name = n });
            },
            .lparen => {
                _ = p.advance();
                const e = try p.expr();
                _ = try p.expectMatch(.rparen, .lparen, t.line);
                return p.mkExpr(t.span, t.line, .{ .paren = e });
            },
            else => return p.errNear("unexpected symbol", .{}),
        }
    }

    pub fn suffixedExpr(p: *Parser) Error!*ast.Expr {
        const start = p.cur();
        const prim = try p.primaryExpr();
        return p.suffixes(prim, start);
    }

    fn suffixes(p: *Parser, base: *ast.Expr, start: Token) Error!*ast.Expr {
        var e = base;
        var has_optional = false;
        const saved_tree = p.tree;
        defer p.tree = saved_tree;
        while (true) {
            const t = p.cur();
            switch (t.tag) {
                .question, .dot, .lbracket, .colon, .lparen, .lbrace, .string => try p.grow(),
                else => {},
            }
            switch (t.tag) {
                .question => {
                    _ = p.advance();
                    has_optional = true;
                    e = try p.mkExpr(start.span, t.line, .{ .optional = e });
                },
                .dot => {
                    _ = p.advance();
                    const n = try p.expectName();
                    const key = try p.mkExpr(n.span, t.line, .{ .string = n.text });
                    e = try p.mkExpr(start.span, t.line, .{ .index = .{ .obj = e, .key = key, .dot = true } });
                },
                .lbracket => {
                    _ = p.advance();
                    if (p.tag() == .comma) {
                        _ = p.advance();
                        var to: ?*ast.Expr = null;
                        if (p.tag() != .rbracket) to = try p.expr();
                        _ = try p.expect(.rbracket);
                        e = try p.mkExpr(start.span, t.line, .{ .slice = .{ .obj = e, .from = null, .to = to } });
                        continue;
                    }
                    const k = try p.expr();
                    if (p.accept(.comma)) {
                        var to: ?*ast.Expr = null;
                        if (p.tag() != .rbracket) to = try p.expr();
                        _ = try p.expect(.rbracket);
                        e = try p.mkExpr(start.span, t.line, .{ .slice = .{ .obj = e, .from = k, .to = to } });
                        continue;
                    }
                    _ = try p.expect(.rbracket);
                    e = try p.mkExpr(start.span, t.line, .{ .index = .{ .obj = e, .key = k, .dot = false } });
                },
                .colon => {
                    _ = p.advance();
                    const n = try p.expectName();
                    const args = try p.callArgs();
                    e = try p.mkExpr(start.span, t.line, .{ .method = .{ .obj = e, .name = n, .args = args.args, .args_kind = args.kind } });
                },
                .lparen, .lbrace, .string => {
                    const args = try p.callArgs();
                    e = try p.mkExpr(start.span, t.line, .{ .call = .{ .callee = e, .args = args.args, .args_kind = args.kind } });
                },
                else => break,
            }
        }
        if (has_optional) e = try p.mkExpr(start.span, start.line, .{ .chain = e });
        return e;
    }

    const Args = struct { args: []*ast.Expr, kind: ast.ArgsKind };

    fn callArgs(p: *Parser) Error!Args {
        const t = p.cur();
        switch (t.tag) {
            .string => {
                _ = p.advance();
                const e = try p.mkExpr(t.span, t.line, .{ .string = p.text(t) });
                const a = try p.arena.alloc(*ast.Expr, 1);
                a[0] = e;
                return .{ .args = a, .kind = .string };
            },
            .lbrace => {
                const e = try p.tableCtor();
                const a = try p.arena.alloc(*ast.Expr, 1);
                a[0] = e;
                return .{ .args = a, .kind = .table };
            },
            .lparen => {
                _ = p.advance();
                var args: []*ast.Expr = &.{};
                if (p.tag() != .rparen) args = try p.exprList();
                _ = try p.expectMatch(.rparen, .lparen, t.line);
                return .{ .args = args, .kind = .parens };
            },
            else => return p.errNear("function arguments expected", .{}),
        }
    }

    // -----------------------------------------------------------------
    // Queries (grammar section 5.12)

    const clause_words = [_][]const u8{ "where", "select", "group", "having", "order", "limit", "offset" };

    fn isClauseWord(p: *Parser) bool {
        if (p.tag() != .name) return false;
        const w = p.text(p.cur());
        for (clause_words) |c| if (std.mem.eql(u8, c, w)) return true;
        return false;
    }

    fn queryExpr(p: *Parser) Error!*ast.Expr {
        const start = p.cur();
        if (p.in_query) return p.errSem("nested queries are not supported", .{});
        _ = p.advance();
        p.in_query = true;
        defer p.in_query = false;
        const q = try p.arena.create(ast.Query);
        q.* = .{ .sources = &.{}, .span = start.span };
        var sources: std.ArrayList(ast.QSource) = .empty;
        while (true) {
            const src = try p.querySource();
            for (sources.items) |o| {
                if (std.mem.eql(u8, o.alias.text, src.alias.text)) return p.errSem("duplicate row variable '{s}' in query", .{src.alias.text});
            }
            try sources.append(p.arena, src);
            if (sources.items.len > 8) return p.errSem("too many sources in query", .{});
            if (!p.accept(.comma)) break;
        }
        q.sources = try sources.toOwnedSlice(p.arena);
        while (p.isClauseWord()) {
            const w = p.text(p.advance());
            if (std.mem.eql(u8, w, "where")) {
                if (q.where != null) return p.errSem("duplicate 'where' clause in query", .{});
                q.where = try p.qExpr(0);
            } else if (std.mem.eql(u8, w, "select")) {
                if (q.select != null) return p.errSem("duplicate 'select' clause in query", .{});
                if (p.isName("distinct")) {
                    _ = p.advance();
                    q.distinct = true;
                }
                var items: std.ArrayList(ast.QItem) = .empty;
                while (true) {
                    const e = try p.qExpr(0);
                    var alias: ?ast.Name = null;
                    if (p.isName("as")) {
                        _ = p.advance();
                        alias = try p.expectName();
                    } else if (!namesItself(e, q.sources)) {
                        return p.errSem("'as' name expected for this projection", .{});
                    }
                    try items.append(p.arena, .{ .expr = e, .alias = alias });
                    if (items.items.len > 32) return p.errSem("query too complex", .{});
                    if (!p.accept(.comma)) break;
                }
                q.select = try items.toOwnedSlice(p.arena);
            } else if (std.mem.eql(u8, w, "group")) {
                if (q.group_by != null) return p.errSem("duplicate 'group' clause in query", .{});
                if (!p.isName("by")) return p.errSem("'by' expected after 'group'", .{});
                _ = p.advance();
                var keys: std.ArrayList(*ast.QExpr) = .empty;
                while (true) {
                    try keys.append(p.arena, try p.qExpr(0));
                    if (keys.items.len > 16) return p.errSem("query too complex", .{});
                    if (!p.accept(.comma)) break;
                }
                q.group_by = try keys.toOwnedSlice(p.arena);
            } else if (std.mem.eql(u8, w, "having")) {
                if (q.having != null) return p.errSem("duplicate 'having' clause in query", .{});
                q.having = try p.qExpr(0);
            } else if (std.mem.eql(u8, w, "order")) {
                if (q.order_by != null) return p.errSem("duplicate 'order' clause in query", .{});
                if (!p.isName("by")) return p.errSem("'by' expected after 'order'", .{});
                _ = p.advance();
                var items: std.ArrayList(ast.QOrder) = .empty;
                while (true) {
                    const e = try p.qExpr(0);
                    var desc = false;
                    if (p.isName("asc")) {
                        _ = p.advance();
                    } else if (p.isName("desc")) {
                        _ = p.advance();
                        desc = true;
                    }
                    try items.append(p.arena, .{ .expr = e, .desc = desc });
                    if (items.items.len > 16) return p.errSem("query too complex", .{});
                    if (!p.accept(.comma)) break;
                }
                q.order_by = try items.toOwnedSlice(p.arena);
            } else if (std.mem.eql(u8, w, "limit")) {
                if (q.limit != null) return p.errSem("duplicate 'limit' clause in query", .{});
                q.limit = try p.qExpr(0);
            } else if (std.mem.eql(u8, w, "offset")) {
                if (q.offset != null) return p.errSem("duplicate 'offset' clause in query", .{});
                q.offset = try p.qExpr(0);
            }
        }
        if (q.sources.len > 1 and q.select == null) return p.errSem("a join requires a 'select' clause", .{});
        q.span = .{ .start = start.span.start, .end = p.toks[p.pos - 1].span.end };
        return p.mkExpr(start.span, start.line, .{ .query = q });
    }

    /// A projection without `as` must name itself: a row variable or a
    /// column of one (`p` or `p.name`).
    fn namesItself(e: *ast.QExpr, sources: []const ast.QSource) bool {
        switch (e.kind) {
            .paren => |inner| return namesItself(inner, sources),
            .chain => |names| {
                if (names.len > 2) return false;
                for (sources) |s| {
                    if (std.mem.eql(u8, s.alias.text, names[0].text)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn querySource(p: *Parser) Error!ast.QSource {
        const t = p.cur();
        var e: *ast.Expr = undefined;
        var alias: ?ast.Name = null;
        var needs_as = false;
        if (t.tag == .lparen) {
            _ = p.advance();
            p.in_query = false;
            const inner = try p.expr();
            p.in_query = true;
            _ = try p.expectMatch(.rparen, .lparen, t.line);
            e = try p.mkExpr(t.span, t.line, .{ .paren = inner });
            needs_as = true;
        } else {
            const n = try p.expectName();
            e = try p.mkExpr(n.span, t.line, .{ .name = n });
            alias = n;
            while (true) {
                if (p.tag() == .dot) {
                    _ = p.advance();
                    const f = try p.expectName();
                    const key = try p.mkExpr(f.span, t.line, .{ .string = f.text });
                    e = try p.mkExpr(t.span, t.line, .{ .index = .{ .obj = e, .key = key, .dot = true } });
                    alias = f;
                    needs_as = false;
                } else if (p.tag() == .lbracket) {
                    _ = p.advance();
                    const k = p.cur();
                    if (k.tag != .string and k.tag != .integer) return p.errSem("query source index must be a literal", .{});
                    if (k.tag == .integer and p.payloads[k.payload].integer < 0) return p.errSem("query source index must be a literal", .{});
                    const key = try p.simpleExpr();
                    _ = try p.expect(.rbracket);
                    e = try p.mkExpr(t.span, t.line, .{ .index = .{ .obj = e, .key = key, .dot = false } });
                    needs_as = true;
                } else break;
            }
        }
        if (p.isName("as")) {
            _ = p.advance();
            alias = try p.expectName();
        } else if (needs_as or alias == null) {
            return p.errSem("query source needs an 'as' name", .{});
        }
        return .{ .expr = e, .alias = alias.? };
    }

    fn mkQ(p: *Parser, start: Span, line: u32, kind: @FieldType(ast.QExpr, "kind")) Error!*ast.QExpr {
        const end = p.toks[p.pos - 1].span.end;
        return p.new(ast.QExpr, .{ .span = .{ .start = start.start, .end = @max(end, start.end) }, .line = line, .kind = kind });
    }

    fn qExpr(p: *Parser, limit: u8) Error!*ast.QExpr {
        try p.enter();
        defer p.leave();
        if (p.depth > 64 + 20) return p.errSem("query too complex", .{});
        const start = p.cur();
        var left: *ast.QExpr = undefined;
        switch (p.tag()) {
            .minus, .kw_not => {
                const op: ast.UnOp = if (p.tag() == .minus) .neg else .not;
                _ = p.advance();
                const operand = try p.qExpr(ast.unary_priority);
                left = try p.mkQ(start.span, start.line, .{ .unop = .{ .op = op, .operand = operand } });
            },
            .hash, .tilde => return p.errSem("operator not supported in a query clause", .{}),
            else => left = try p.qSimple(),
        }
        while (binOpOf(p.tag())) |op| {
            switch (op) {
                .band, .bor, .bxor, .shl, .shr => return p.errSem("operator not supported in a query clause", .{}),
                else => {},
            }
            const pr = op.priority();
            if (pr[0] <= limit) break;
            _ = p.advance();
            const right = try p.qExpr(pr[1]);
            left = try p.mkQ(start.span, start.line, .{ .binop = .{ .op = op, .lhs = left, .rhs = right } });
        }
        return left;
    }

    fn qSimple(p: *Parser) Error!*ast.QExpr {
        const t = p.cur();
        switch (t.tag) {
            .integer, .float, .string, .kw_nil, .kw_true, .kw_false, .bigint, .decimal => {
                const lit = try p.simpleExpr();
                return p.mkQ(t.span, t.line, .{ .literal = lit });
            },
            .lparen => {
                _ = p.advance();
                const inner = try p.qExpr(0);
                _ = try p.expectMatch(.rparen, .lparen, t.line);
                switch (p.tag()) {
                    .dot, .lbracket, .colon, .question, .lparen, .string, .lbrace => return p.errSem("a suffix on a parenthesized expression is not supported in a query clause", .{}),
                    else => {},
                }
                return p.mkQ(t.span, t.line, .{ .paren = inner });
            },
            .name => {
                const w = p.text(t);
                if (p.peekTag(1) == .lparen) {
                    const agg: ?ast.Aggregate = std.meta.stringToEnum(ast.Aggregate, w);
                    if (agg) |a| {
                        _ = p.advance();
                        _ = p.advance();
                        var arg: ?*ast.QExpr = null;
                        if (p.tag() == .star) {
                            if (a != .count) return p.errSem("'*' is only allowed in count", .{});
                            _ = p.advance();
                        } else {
                            arg = try p.qExpr(0);
                        }
                        _ = try p.expectMatch(.rparen, .lparen, t.line);
                        return p.mkQ(t.span, t.line, .{ .aggregate = .{ .func = a, .arg = arg } });
                    }
                }
                // Name chain.
                var names: std.ArrayList(ast.Name) = .empty;
                try names.append(p.arena, try p.expectName());
                while (p.tag() == .dot and p.peekTag(1) == .name) {
                    _ = p.advance();
                    try names.append(p.arena, try p.expectName());
                    if (names.items.len > 10) return p.errSem("query too complex", .{});
                }
                switch (p.tag()) {
                    .lparen, .lbracket, .colon, .question, .lbrace, .string => {
                        // Host closure resuming the full suffix chain.
                        var e = try p.mkExpr(names.items[0].span, t.line, .{ .name = names.items[0] });
                        for (names.items[1..]) |n| {
                            const key = try p.mkExpr(n.span, t.line, .{ .string = n.text });
                            e = try p.mkExpr(t.span, t.line, .{ .index = .{ .obj = e, .key = key, .dot = true } });
                        }
                        const full = try p.suffixes(e, t);
                        return p.mkQ(t.span, t.line, .{ .host = full });
                    },
                    else => {},
                }
                return p.mkQ(t.span, t.line, .{ .chain = try names.toOwnedSlice(p.arena) });
            },
            .at => return p.errSem("nested queries are not supported", .{}),
            else => {
                const e = try p.simpleExpr();
                return p.mkQ(t.span, t.line, .{ .host = e });
            },
        }
    }
};

pub const Result = struct {
    chunk: ast.Chunk,
};

/// What a parse for the tooling leaves behind, including when it stops
/// at a syntax error.
pub const Partial = struct {
    /// Completed statements of the main chunk.
    stats: []*ast.Stat = &.{},
    /// Recovered statements, in the order they were created.
    recovered: []*ast.Stat = &.{},
    /// The error, with the message formatted as "chunk:line: message".
    diag: ?Diagnostic = null,
};

/// Parses an already lexed token stream for the tooling. With `recover`
/// set, invalid statement starts become `recovered` statements. On a
/// syntax error `partial` describes what was parsed before it.
pub fn parseLexed(arena: Allocator, src: []const u8, lexed: lexer.Result, opts: Options, recover: bool, partial: *Partial) Error!ast.Chunk {
    var p = Parser{
        .arena = arena,
        .src = src,
        .toks = lexed.tokens,
        .payloads = lexed.payloads,
        .chunkname = opts.chunkname,
        .recover = recover,
    };
    const b = p.blockIn(true) catch |e| {
        if (e == error.SyntaxError) p.setPartial(partial, opts.chunkname);
        return e;
    };
    if (p.tag() != .eof) {
        _ = p.errNear("<eof> expected", .{}) catch {};
        p.setPartial(partial, opts.chunkname);
        return error.SyntaxError;
    }
    partial.stats = b.stats;
    partial.recovered = p.recovered.items;
    return .{ .block = b, .source = src, .comments = lexed.comments };
}

/// Parses a whole chunk. On failure `diag` holds a message already
/// formatted as "chunk:line: message".
pub fn parse(gpa: Allocator, arena: Allocator, src: []const u8, opts: Options, diag: *?[]const u8) Error!ast.Chunk {
    var lx = lexer.Lexer.init(gpa, arena, src);
    defer lx.deinit();
    const lexed = lx.run() catch |e| {
        if (e == error.SyntaxError) {
            const d = lx.diag.?;
            diag.* = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ chunkDisplay(arena, opts.chunkname), d.line, d.message });
        }
        return e;
    };
    var p = Parser{
        .arena = arena,
        .src = src,
        .toks = lexed.tokens,
        .payloads = lexed.payloads,
        .chunkname = opts.chunkname,
    };
    const b = p.block() catch |e| {
        if (e == error.SyntaxError) {
            const d = p.diag.?;
            diag.* = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ chunkDisplay(arena, opts.chunkname), d.line, d.message });
        }
        return e;
    };
    if (p.tag() != .eof) {
        _ = p.errNear("<eof> expected", .{}) catch {};
        const d = p.diag.?;
        diag.* = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ chunkDisplay(arena, opts.chunkname), d.line, d.message });
        return error.SyntaxError;
    }
    return .{ .block = b, .source = src, .comments = lexed.comments };
}

/// Formats a chunk name for messages (Lua's luaO_chunkid).
pub fn chunkDisplay(arena: Allocator, name: []const u8) []const u8 {
    if (name.len > 0 and (name[0] == '=' or name[0] == '@')) return name[1..];
    // Source text: [string "first line..."]
    const nl = std.mem.indexOfScalar(u8, name, '\n');
    const max = 45;
    var first = if (nl) |i| name[0..i] else name;
    const truncated = nl != null or first.len > max;
    if (first.len > max) first = first[0..max];
    return std.fmt.allocPrint(arena, "[string \"{s}{s}\"]", .{ first, if (truncated) "..." else "" }) catch "?";
}

const testing = std.testing;

fn parseOk(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    _ = parse(testing.allocator, arena.allocator(), src, .{ .chunkname = "=t" }, &diag) catch |e| {
        std.debug.print("unexpected parse error: {s}\n", .{diag orelse "?"});
        return e;
    };
}

fn parseErr(src: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?[]const u8 = null;
    _ = parse(testing.allocator, arena.allocator(), src, .{ .chunkname = "=t" }, &diag) catch {
        if (std.mem.indexOf(u8, diag.?, want) == null) {
            std.debug.print("got: {s}\nwant substring: {s}\n", .{ diag.?, want });
            return error.TestUnexpectedResult;
        }
        return;
    };
    return error.TestExpectedError;
}

test "parse base language" {
    try parseOk("local x, y = 1, 2 print(x + y * 3 ^ 2) function a.b:c(...) return ... end");
    try parseOk("for i = 1, 10, 2 do if i > 5 then break elseif i == 3 then goto x end ::x:: end");
    try parseOk("for k, v in pairs(t) do t[k] = nil end repeat local z = 1 until z");
    try parseOk("local t = { 1, 2, [3] = 4, a = 5; f(), } local s = t.a .. 'x' .. #t");
    try parseOk("local function f(a, ...rest) return a end global x <const> = 1 global *");
}

test "parse extensions" {
    try parseOk("local ok, err = catch f() catch[h] g() local v = catch a + b");
    try parseOk("local h = cfg?.db?.host local s = t[2,4] local u = t[,] local w = t?.list[2,]");
    try parseOk("local s = `hello $name and $(1 + 2) done` local e = enum a, b, c end");
    try parseOk("local a, b from t x, y from src if v = f() then print(v) end while l = r() do end");
    try parseOk("local x = do local y = 1 provide y * 2 end local n <h> = 1 local z <group> = { a = 1, c <group> = { d = 3 } }");
    try parseOk("local q = @people as p where p.age > 18 select p.name, p.age order by p.age desc limit 10");
    try parseOk("for i = 1, 3 do continue end");
}

test "parse errors" {
    try parseErr("t?.a = 1", "syntax error near '='");
    try parseErr("local x = do provide 1; end", "'end' expected near ';'");
    try parseErr("provide 1", "'provide' outside do expression");
    try parseErr("local e = enum a, b, end", "<name> expected near 'end'");
    try parseErr("local e = enum a, a end", "duplicate enum member 'a'");
    try parseErr("x = t[1, 2, 3]", "']' expected near ','");
    try parseErr("if a <b then end", "'>' expected near 'then'");
    try parseErr("local t = {} t?.a", "syntax error near <eof>");
    try parseErr("return `x $()`", "unexpected symbol near <interp_end>");
}
