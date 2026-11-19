//! Syntax tree export for the tooling: `debug.parse` and `lus ast`.
//!
//! The exported tree is the one the language server consumes. Its shape
//! (node types, field names, positions, error reporting) follows the
//! reference implementation in `legacy/lus/src/last.c` and the AST
//! building code of `legacy/lus/src/lparser.c`. The export walks the
//! syntax tree of `parser.zig` and recovers every position from the
//! token stream, because the reference positions are token positions:
//! a node sits on the line where the lexer stood after reading the token
//! that started it, at the byte column where that token began.
//!
//! The result is a small generic tree (`Node`) that the runtime converts
//! to Lus tables and the CLI prints as JSON. The JSON schema lives in
//! `spec/language/ast.schema.json`.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const wtf8 = @import("../vm/wtf8.zig");
const Allocator = std.mem.Allocator;
const Token = token.Token;
const Tag = token.Tag;

// ---------------------------------------------------------------------
// Exported tree

pub const Val = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    node: *Node,
    list: []*Node,
};

pub const Field = struct {
    key: []const u8,
    val: Val,
};

/// One exported node. Records without a `type` (comments and errors on
/// the root) use the same structure.
pub const Node = struct {
    type: ?[]const u8,
    line: u32,
    column: u32,
    endline: u32 = 0,
    endcolumn: u32 = 0,
    fields: std.ArrayList(Field) = .empty,
    children: std.ArrayList(*Node) = .empty,
};

pub const Options = struct {
    /// Chunk name as given to `load` ("@file", "=name", or plain text).
    chunkname: []const u8,
    /// Attach the `comments` array to the root.
    comments: bool = true,
    /// Recover from invalid statement starts and return a partial tree
    /// with an `errors` array when parsing stops at an error.
    recover: bool = true,
};

/// Compiles a parsed chunk to find the errors the reference parser
/// reports while parsing (constant assignment, missing labels, and so
/// on). Returns the formatted message of the first error, or null.
pub const Checker = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, arena: Allocator, chunk: ast.Chunk, chunkname: []const u8) Allocator.Error!?[]const u8,
};

pub const Outcome = union(enum) {
    tree: *Node,
    /// Total failure: the message that `debug.parse` returns after nil.
    fail: []const u8,
};

const Error = Allocator.Error;

// ---------------------------------------------------------------------
// Driver

/// Parses `src` and exports its tree. Everything is allocated in
/// `arena`. `gpa` backs the lexer's scratch lists only.
pub fn run(gpa: Allocator, arena: Allocator, src: []const u8, opts: Options, checker: ?Checker) Error!Outcome {
    if (src.len > 0 and src[0] == 0x1b) return .{ .fail = "cannot parse binary chunk" };

    // Lex. On a lexical error the tokens read so far are kept, followed
    // by an end of stream token where the bad token starts.
    var lx = lexer.Lexer.init(gpa, arena, src);
    lx.tolerant = true;
    defer lx.deinit();
    var lexed: lexer.Result = undefined;
    var lex_fail: ?[]const u8 = null;
    var bad_tok: u32 = std.math.maxInt(u32);
    if (lx.run()) |r| {
        lexed = r;
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            const d = lx.diag.?;
            lex_fail = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ parser.chunkDisplay(arena, opts.chunkname), d.line, d.message });
            var toks: std.ArrayList(Token) = .empty;
            try toks.appendSlice(arena, lx.tokens.items);
            bad_tok = @intCast(toks.items.len);
            const at: u32 = @intCast(@min(d.span.start, src.len));
            try toks.append(arena, .{ .tag = .eof, .span = .{ .start = at, .end = at }, .line = d.line });
            lexed = .{
                .tokens = toks.items,
                .payloads = try arena.dupe(lexer.Payload, lx.payloads.items),
                .comments = try arena.dupe(lexer.Comment, lx.comments.items),
            };
        },
    }

    var partial: parser.Partial = .{};
    var fatal: ?[]const u8 = lex_fail;
    var source: enum { lexer, parser, compiler } = .lexer;
    var stats: []*ast.Stat = &.{};
    var recovered: []*ast.Stat = &.{};
    var comment_cut: u32 = std.math.maxInt(u32);

    if (parser.parseLexed(arena, src, lexed, .{ .chunkname = opts.chunkname }, opts.recover, &partial)) |chunk| {
        stats = partial.stats;
        recovered = partial.recovered;
        if (fatal == null) {
            if (checker) |c| {
                if (try c.check(c.ctx, arena, chunk, opts.chunkname)) |msg| {
                    // Raw bytes in a string literal (a limit of the
                    // runtime's string type) and constructs the compiler
                    // does not generate yet are not errors of the source.
                    if (std.mem.indexOf(u8, msg, "invalid UTF-8 in string literal") == null and
                        std.mem.indexOf(u8, msg, "not supported yet") == null)
                    {
                        fatal = msg;
                        source = .compiler;
                    }
                }
            }
        }
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            stats = partial.stats;
            recovered = partial.recovered;
            if (fatal == null) {
                const d = partial.diag.?;
                fatal = d.message;
                source = .parser;
                if (d.tok < lexed.tokens.len) comment_cut = lexed.tokens[d.tok].span.start;
            }
        },
    }

    var x = try Exporter.init(arena, src, lexed);

    if (fatal) |msg| {
        if (!opts.recover) return .{ .fail = msg };
        const errline = errorLine(msg);
        // Keep what the reference parser would have finished before the
        // error, which it raises while reading the bad token.
        var kept: std.ArrayList(*ast.Stat) = .empty;
        var kept_rec: std.ArrayList(*ast.Stat) = .empty;
        switch (source) {
            .lexer => {
                for (stats) |s| {
                    const last = x.tokEnd(s.span.end);
                    const first = x.tokAt(s.span.start);
                    const ok = if (s.kind == .recovered) first < bad_tok else last + 1 < bad_tok;
                    if (ok) try kept.append(arena, s);
                }
                for (recovered) |s| if (x.tokAt(s.span.start) < bad_tok) try kept_rec.append(arena, s);
            },
            .compiler => {
                // Only the line of a compiler error is known. A missing
                // label is reported when its block closes, after the
                // statements before it are complete.
                const all = std.mem.indexOf(u8, msg, "no visible label") != null;
                for (stats) |s| {
                    if (all or x.curLine(x.tokEnd(s.span.end)) < errline) try kept.append(arena, s);
                }
                for (recovered) |s| if (x.lineOf(s.span.start) <= errline) try kept_rec.append(arena, s);
                comment_cut = cutForLine(&x, errline);
            },
            .parser => {
                try kept.appendSlice(arena, stats);
                try kept_rec.appendSlice(arena, recovered);
            },
        }
        const root = try x.chunk(kept.items);
        if (opts.comments) try x.attachComments(root, comment_cut);
        try x.attachErrors(root, kept_rec.items, msg, errline);
        return .{ .tree = root };
    }

    const root = try x.chunk(stats);
    if (opts.comments) try x.attachComments(root, comment_cut);
    try x.attachErrors(root, recovered, null, 0);
    return .{ .tree = root };
}

/// The line number of an error message, extracted the way the reference
/// does: after `]:` for string chunks, else after the first colon.
fn errorLine(msg: []const u8) u32 {
    var rest: []const u8 = "";
    if (std.mem.indexOf(u8, msg, "]:")) |i| {
        rest = msg[i + 2 ..];
    } else if (std.mem.indexOfScalar(u8, msg, ':')) |i| {
        rest = msg[i + 1 ..];
    }
    var n: u32 = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
    }
    return if (n == 0) 1 else n;
}

/// Byte offset of the first character after line `line`, so that the
/// comments on that line and before it are kept.
fn cutForLine(x: *const Exporter, line: u32) u32 {
    if (line >= x.line_starts.len) return std.math.maxInt(u32);
    return x.line_starts[line];
}

// ---------------------------------------------------------------------
// Exporter

const Pos = struct { line: u32, col: u32 };

const Exporter = struct {
    arena: Allocator,
    src: []const u8,
    toks: []Token,
    payloads: []lexer.Payload,
    comments: []lexer.Comment,
    /// Byte offset where each line starts. Line 1 starts at 0.
    line_starts: []u32,
    /// Tokens that the reference parser read as a lookahead. While such
    /// a token is current, the reference lexer still reports the column
    /// of the token before it.
    la: []bool,
    /// The reference lexer's token column of every token.
    cols: []u32,
    /// Query context: row variable names and whether an `order by` item
    /// is being exported.
    q_aliases: []const []const u8 = &.{},
    q_order: bool = false,
    /// Visible local names, innermost last, with the value of the ones
    /// that are compile-time constants.
    scope: std.ArrayList(Binding) = .empty,
    /// Folded constants of binary operations, by node.
    const_cache: *std.AutoHashMapUnmanaged(*ast.Expr, ?Const),

    const Binding = struct { name: []const u8, value: ?Const };

    fn lookupConst(x: *const Exporter, name: []const u8) ?Const {
        var i = x.scope.items.len;
        while (i > 0) {
            i -= 1;
            const b = x.scope.items[i];
            if (std.mem.eql(u8, b.name, name)) return b.value;
        }
        return null;
    }

    fn bind(x: *Exporter, name: []const u8, value: ?Const) Error!void {
        try x.scope.append(x.arena, .{ .name = name, .value = value });
    }

    fn bindNames(x: *Exporter, names: []ast.AttName) Error!void {
        for (names) |n| try x.bind(n.name.text, null);
    }

    fn bindGroupFields(x: *Exporter, fields: []ast.GroupField) Error!void {
        for (fields) |f| switch (f.value) {
            .expr => try x.bind(f.name.name.text, null),
            .group => |sub| try x.bindGroupFields(sub),
        };
    }

    /// Declares the locals a statement introduces for what follows it.
    fn declare(x: *Exporter, s: *ast.Stat) Error!void {
        switch (s.kind) {
            .local => |l| {
                // Only the last name can become a compile-time constant,
                // when every name has its own value.
                var last: ?Const = null;
                const an = l.names[l.names.len - 1];
                if (l.names.len == l.values.len and an.has(.@"const")) {
                    var runtime = false;
                    for (an.attribs) |a| {
                        if (a == .runtime) runtime = true;
                    }
                    if (!runtime) last = constOf(x, l.values[l.values.len - 1]);
                }
                for (l.names, 0..) |n, i| try x.bind(n.name.text, if (i + 1 == l.names.len) last else null);
            },
            .local_from => |l| try x.bindNames(l.names),
            .local_group => |l| {
                try x.bindNames(l.names);
                for (l.inits) |gi| switch (gi) {
                    .ctor => |fields| try x.bindGroupFields(fields),
                    .copy => {},
                };
            },
            .global => |g| try x.bindNames(g.names),
            .global_from => |g| try x.bindNames(g.names),
            .local_function => |lf| try x.bind(lf.name.text, null),
            .global_function => |gf| try x.bind(gf.name.text, null),
            else => {},
        }
    }

    fn init(arena: Allocator, src: []const u8, lexed: lexer.Result) Error!Exporter {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        var i: usize = 0;
        while (i < src.len) {
            const c = src[i];
            if (c == '\n' or c == '\r') {
                if (i + 1 < src.len and (src[i + 1] == '\n' or src[i + 1] == '\r') and src[i + 1] != c) i += 2 else i += 1;
                try starts.append(arena, @intCast(i));
            } else i += 1;
        }
        const la = try arena.alloc(bool, lexed.tokens.len + 1);
        @memset(la, false);
        var x: Exporter = .{
            .arena = arena,
            .src = src,
            .toks = lexed.tokens,
            .payloads = lexed.payloads,
            .comments = lexed.comments,
            .line_starts = starts.items,
            .la = la,
            .cols = try arena.alloc(u32, lexed.tokens.len),
            .const_cache = try arena.create(std.AutoHashMapUnmanaged(*ast.Expr, ?Const)),
        };
        x.const_cache.* = .empty;
        // The reference lexer starts the section after `$(...)` at the
        // closing parenthesis, and resumes the section after `$name`
        // without moving its token column.
        const toks = lexed.tokens;
        for (toks, 0..) |t, k| {
            x.cols[k] = x.colOf(t.span.start);
            if ((t.tag == .interp_mid or t.tag == .interp_end) and k >= 2) {
                const prev = toks[k - 1];
                const sec = toks[k - 2];
                if (prev.tag == .name and (sec.tag == .interp_begin or sec.tag == .interp_mid) and src[sec.span.end - 1] == '$' and prev.span.end == t.span.start) {
                    x.cols[k] = x.cols[k - 2];
                } else if (t.span.start > 0) {
                    x.cols[k] = x.colOf(t.span.start - 1);
                }
            }
        }
        return x;
    }

    // -----------------------------------------------------------------
    // Positions

    fn lineOf(x: *const Exporter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = x.line_starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (x.line_starts[mid] <= off) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    fn colOf(x: *const Exporter, off: u32) u32 {
        const ln = x.lineOf(off);
        return off - x.line_starts[ln - 1] + 1;
    }

    /// Index of the token starting at `off` (or the first one after it).
    fn tokAt(x: *const Exporter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = x.toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (x.toks[mid].span.start < off) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, x.toks.len - 1));
    }

    /// Index of the token ending at `off`: the last one starting before.
    fn tokEnd(x: *const Exporter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = x.toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (x.toks[mid].span.start < off) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else @intCast(lo - 1);
    }

    /// Index of the token right after the token ending at `off`.
    fn tokAfter(x: *const Exporter, off: u32) u32 {
        return @min(x.tokEnd(off) + 1, @as(u32, @intCast(x.toks.len - 1)));
    }

    fn endLine(x: *const Exporter, k: u32) u32 {
        return x.lineOf(x.toks[k].span.end);
    }

    /// The reference lexer's line while token `k` is current: the line
    /// where reading stopped, which is past a pending lookahead.
    fn curLine(x: *const Exporter, k: u32) u32 {
        if (k + 1 < x.toks.len and x.la[k + 1]) return x.endLine(k + 1);
        return x.endLine(k);
    }

    /// The reference lexer's column while token `k` is current.
    fn curCol(x: *const Exporter, k: u32) u32 {
        if (x.la[k] and k > 0) return x.cols[k - 1];
        return x.cols[k];
    }

    fn pos(x: *const Exporter, k: u32) Pos {
        return .{ .line = x.curLine(k), .col = x.curCol(k) };
    }

    /// Marks that the parser peeked at the token after `k`.
    fn lookahead(x: *Exporter, k: u32) void {
        if (k + 1 < x.la.len) x.la[k + 1] = true;
    }

    fn tagAt(x: *const Exporter, k: u32) Tag {
        return x.toks[k].tag;
    }

    fn text(x: *const Exporter, k: u32) []const u8 {
        const t = x.toks[k];
        return switch (x.payloads[t.payload]) {
            .text => |s| s,
            .digits => |s| s,
            else => x.src[t.span.start..t.span.end],
        };
    }

    // -----------------------------------------------------------------
    // Node building

    fn node(x: *Exporter, ty: []const u8, p: Pos) Error!*Node {
        const n = try x.arena.create(Node);
        n.* = .{ .type = ty, .line = p.line, .column = p.col };
        return n;
    }

    fn set(x: *Exporter, n: *Node, key: []const u8, v: Val) Error!void {
        try n.fields.append(x.arena, .{ .key = key, .val = v });
    }

    fn setNode(x: *Exporter, n: *Node, key: []const u8, v: ?*Node) Error!void {
        if (v) |c| try x.set(n, key, .{ .node = c });
    }

    fn setList(x: *Exporter, n: *Node, key: []const u8, list: []*Node) Error!void {
        if (list.len > 0) try x.set(n, key, .{ .list = list });
    }

    fn setEnd(n: *Node, p: Pos) void {
        n.endline = p.line;
        n.endcolumn = p.col;
    }

    /// End at the last consumed token: its line and its start column.
    fn endAt(x: *const Exporter, n: *Node, off: u32) void {
        setEnd(n, x.pos(x.tokEnd(off)));
    }

    /// End of a literal token: the line and column of its last byte.
    fn literalEnd(x: *const Exporter, n: *Node, k: u32) void {
        const t = x.toks[k];
        n.endline = x.lineOf(t.span.end);
        n.endcolumn = x.colOf(t.span.end) -| 1;
    }

    fn nameNode(x: *Exporter, name: []const u8, p: Pos) Error!*Node {
        const n = try x.node("name", p);
        try x.set(n, "value", .{ .str = name });
        return n;
    }

    fn strNode(x: *Exporter, s: []const u8, p: Pos) Error!*Node {
        const n = try x.node("string", p);
        try x.set(n, "value", .{ .str = s });
        return n;
    }

    // -----------------------------------------------------------------
    // Root, comments, errors

    fn chunk(x: *Exporter, stats: []*ast.Stat) Error!*Node {
        const root = try x.node("chunk", .{ .line = 1, .col = 1 });
        try x.statList(root, stats);
        return root;
    }

    fn attachComments(x: *Exporter, root: *Node, cut: u32) Error!void {
        var list: std.ArrayList(*Node) = .empty;
        for (x.comments) |c| {
            if (c.span.start >= cut) break;
            const n = try x.arena.create(Node);
            n.* = .{
                .type = null,
                .line = x.lineOf(c.span.start),
                .column = x.colOf(c.span.start),
                .endline = x.lineOf(c.span.end),
                .endcolumn = x.colOf(c.span.end),
            };
            try x.set(n, "islong", .{ .boolean = c.long });
            var t = c.text;
            if (!c.long and t.len > 0 and t[0] == '[') {
                // The reference lexer consumes the bracket and its equal
                // signs while checking for a long comment.
                var i: usize = 1;
                while (i < t.len and t[i] == '=') i += 1;
                t = t[i..];
            }
            try x.set(n, "text", .{ .str = t });
            try list.append(x.arena, n);
        }
        if (list.items.len > 0) try x.set(root, "comments", .{ .list = list.items });
    }

    fn attachErrors(x: *Exporter, root: *Node, recovered: []*ast.Stat, fatal: ?[]const u8, fatal_line: u32) Error!void {
        var list: std.ArrayList(*Node) = .empty;
        for (recovered) |s| {
            const p = x.pos(x.tokAt(s.span.start));
            const n = try x.arena.create(Node);
            n.* = .{ .type = null, .line = p.line, .column = p.col };
            try x.set(n, "message", .{ .str = s.kind.recovered });
            try list.append(x.arena, n);
        }
        if (fatal) |msg| {
            const n = try x.arena.create(Node);
            n.* = .{ .type = null, .line = fatal_line, .column = 1 };
            try x.set(n, "message", .{ .str = msg });
            try list.append(x.arena, n);
        }
        if (list.items.len > 0) try x.set(root, "errors", .{ .list = list.items });
    }

    // -----------------------------------------------------------------
    // Statements

    /// Exports a statement list into `parent.children`. The reference
    /// parser reads the empty statements and labels that follow a label
    /// as part of it, so a run of labels comes out in reverse order and
    /// every label in it ends where the run ends.
    fn statList(x: *Exporter, parent: *Node, stats: []*ast.Stat) Error!void {
        const mark = x.scope.items.len;
        defer x.scope.shrinkRetainingCapacity(mark);
        try x.statListOpen(parent, stats);
    }

    /// A statement list whose locals stay visible afterwards.
    fn statListOpen(x: *Exporter, parent: *Node, stats: []*ast.Stat) Error!void {
        var i: usize = 0;
        while (i < stats.len) : (i += 1) {
            const s = stats[i];
            switch (s.kind) {
                .empty => continue,
                .label => {
                    var j = i + 1;
                    while (j < stats.len and (stats[j].kind == .empty or stats[j].kind == .label)) j += 1;
                    const run_end = stats[j - 1].span.end;
                    var k = j;
                    while (k > i) {
                        k -= 1;
                        const ls = stats[k];
                        if (ls.kind != .label) continue;
                        const n = try x.node("label", x.pos(x.tokAt(ls.span.start)));
                        try x.set(n, "value", .{ .str = ls.kind.label.text });
                        x.endAt(n, run_end);
                        try parent.children.append(x.arena, n);
                    }
                    i = j - 1;
                },
                else => {
                    try parent.children.append(x.arena, try x.stat(s));
                    try x.declare(s);
                },
            }
        }
    }

    fn stat(x: *Exporter, s: *ast.Stat) Error!*Node {
        const first = x.tokAt(s.span.start);
        const p = x.pos(first);
        // Names declared inside the statement (loop variables, condition
        // variables) end with it. `declare` adds the ones that outlive it.
        const mark = x.scope.items.len;
        defer x.scope.shrinkRetainingCapacity(mark);
        const n: *Node = switch (s.kind) {
            .empty, .label => unreachable,
            .recovered => |msg| {
                const n = try x.node("error_stat", p);
                try x.set(n, "message", .{ .str = msg });
                return n;
            },
            .expr => |e| blk: {
                const n = try x.node("callstat", p);
                switch (e.kind) {
                    .call => |c| {
                        try x.setNode(n, "func", try x.expr(c.callee));
                        try x.setList(n, "args", try x.callArgs(c.args, c.args_kind));
                    },
                    .method => |m| {
                        try x.setNode(n, "func", try x.expr(m.obj));
                        try x.setList(n, "args", try x.callArgs(m.args, m.args_kind));
                    },
                    else => {},
                }
                break :blk n;
            },
            .local => |l| blk: {
                const n = try x.node("local", p);
                try x.setList(n, "names", try x.attNames(l.names, true));
                try x.setList(n, "values", try x.exprList(l.values));
                try x.set(n, "isfrom", .{ .boolean = false });
                break :blk n;
            },
            .local_from => |l| blk: {
                const n = try x.node("local", p);
                try x.setList(n, "names", try x.attNames(l.names, true));
                try x.setList(n, "values", try x.one(try x.expr(l.source)));
                try x.set(n, "isfrom", .{ .boolean = true });
                break :blk n;
            },
            .local_group => |l| blk: {
                const n = try x.node("local", p);
                try x.setList(n, "names", try x.attNames(l.names, true));
                const last_name = x.tokAt(l.names[l.names.len - 1].name.span.start);
                if (try x.groupInits(last_name, l.inits)) |v| try x.setList(n, "values", try x.one(v));
                try x.set(n, "isfrom", .{ .boolean = false });
                break :blk n;
            },
            .local_function => |lf| blk: {
                const n = try x.node("localfunc", p);
                const np = x.pos(x.tokAt(lf.name.span.start));
                try x.set(n, "name", .{ .str = lf.name.text });
                try x.set(n, "nameline", .{ .int = np.line });
                try x.set(n, "namecolumn", .{ .int = np.col });
                try x.bind(lf.name.text, null);
                try x.function(n, lf.func, false);
                break :blk n;
            },
            .global => |g| blk: {
                const n = try x.node("global", p);
                if (!g.star and g.values == null) try x.setList(n, "names", try x.globalNames(g.names));
                try x.set(n, "isfrom", .{ .boolean = false });
                break :blk n;
            },
            .global_from => |g| blk: {
                const n = try x.node("global", p);
                try x.setList(n, "names", try x.globalNames(g.names));
                try x.setList(n, "values", try x.one(try x.expr(g.source)));
                try x.set(n, "isfrom", .{ .boolean = true });
                break :blk n;
            },
            .global_function => |gf| blk: {
                // The reference parser builds a `global` node and lets the
                // function body fill it: the statements become children
                // and the parameter list lands where `isfrom` is read.
                const n = try x.node("global", p);
                const plist = try x.params(gf.func);
                try x.set(n, "isfrom", .{ .boolean = plist.len > 0 });
                try x.bind(gf.name.text, null);
                for (gf.func.params) |pn| try x.bind(pn.text, null);
                if (gf.func.vararg_name) |vn| try x.bind(vn.text, null);
                try x.statList(n, gf.func.body.stats);
                break :blk n;
            },
            .assign => |a| blk: {
                const n = try x.node("assign", p);
                try x.setList(n, "lhs", try x.exprList(a.targets));
                try x.setList(n, "rhs", try x.exprList(a.values));
                try x.set(n, "isfrom", .{ .boolean = false });
                break :blk n;
            },
            .assign_from => |a| blk: {
                const n = try x.node("assign", p);
                try x.setList(n, "lhs", try x.exprList(a.targets));
                try x.setList(n, "rhs", try x.one(try x.expr(a.source)));
                try x.set(n, "isfrom", .{ .boolean = true });
                break :blk n;
            },
            .function => |f| blk: {
                const n = try x.node("funcstat", p);
                var ne = try x.nameNode(f.path[0].text, x.pos(x.tokAt(f.path[0].span.start)));
                for (f.path[1..]) |seg| ne = try x.fieldOf(ne, seg);
                if (f.method) |m| ne = try x.fieldOf(ne, m);
                try x.setNode(n, "nameexpr", ne);
                try x.function(n, f.func, f.method != null);
                break :blk n;
            },
            .do_ => |b| blk: {
                const n = try x.node("do", p);
                try x.statList(n, b.stats);
                break :blk n;
            },
            .while_ => |w| blk: {
                const n = try x.node("while", p);
                try x.setNode(n, "cond", try x.cond(w.cond));
                try x.statList(n, w.body.stats);
                break :blk n;
            },
            .repeat_ => |r| blk: {
                const n = try x.node("repeat", p);
                // The condition sees the locals of the body.
                try x.statListOpen(n, r.body.stats);
                // The reference parser stores the condition through its
                // "current statement" pointer, which most statements of
                // the body reset.
                if (!resetsCurrent(r.body.stats)) try x.setNode(n, "cond", try x.expr(r.cond));
                break :blk n;
            },
            .if_ => |f| blk: {
                const n = try x.node("if", p);
                try x.setNode(n, "cond", try x.cond(f.clauses[0].cond));
                try x.statList(n, f.clauses[0].body.stats);
                for (f.clauses[1..]) |cl| {
                    const kw = x.tokAt(condStart(cl.cond)) - 1;
                    const e = try x.node("elseif", x.pos(kw));
                    try x.setNode(e, "cond", try x.cond(cl.cond));
                    try x.statList(e, cl.body.stats);
                    try n.children.append(x.arena, e);
                }
                if (f.else_) |b| {
                    const kw = x.tokAt(b.span.start) - 1;
                    const e = try x.node("else", x.pos(kw));
                    try x.statList(e, b.stats);
                    try n.children.append(x.arena, e);
                }
                break :blk n;
            },
            .numeric_for => |f| blk: {
                const n = try x.node("fornum", p);
                try x.setNode(n, "var", try x.nameNode(f.name.text, x.pos(x.tokAt(f.name.span.start))));
                try x.setNode(n, "init", try x.expr(f.start));
                try x.setNode(n, "limit", try x.expr(f.limit));
                if (f.step) |st| try x.setNode(n, "step", try x.expr(st));
                try x.bind(f.name.text, null);
                try x.statList(n, f.body.stats);
                break :blk n;
            },
            .generic_for => |f| blk: {
                const n = try x.node("forgen", p);
                var names: std.ArrayList(*Node) = .empty;
                for (f.names) |nm| try names.append(x.arena, try x.nameNode(nm.text, x.pos(x.tokAt(nm.span.start))));
                try x.setList(n, "names", names.items);
                try x.setList(n, "explist", try x.exprList(f.exprs));
                for (f.names) |nm| try x.bind(nm.text, null);
                try x.statList(n, f.body.stats);
                break :blk n;
            },
            .return_ => |vals| blk: {
                const n = try x.node("return", p);
                try x.setList(n, "values", try x.exprList(vals));
                break :blk n;
            },
            .provide => |vals| blk: {
                const n = try x.node("provide", p);
                try x.setList(n, "values", try x.exprList(vals));
                break :blk n;
            },
            .break_ => try x.node("break", p),
            .continue_ => try x.node("continue", p),
            .goto_ => |g| blk: {
                const n = try x.node("goto", p);
                try x.set(n, "value", .{ .str = g.text });
                break :blk n;
            },
            .catch_ => |c| blk: {
                const n = try x.node("catchstat", p);
                try x.setNode(n, "expr", try x.expr(c.body));
                if (c.handler) |h| try x.setNode(n, "handler", try x.expr(h));
                break :blk n;
            },
        };
        x.endAt(n, s.span.end);
        return n;
    }

    /// True when one of `stats` resets the reference parser's current
    /// statement: every statement but empty ones, `break`, labels,
    /// recovered tokens, and `do` blocks made only of those.
    fn resetsCurrent(stats: []*ast.Stat) bool {
        for (stats) |s| switch (s.kind) {
            .empty, .break_, .label, .recovered => {},
            .do_ => |b| if (resetsCurrent(b.stats)) return true,
            else => return true,
        };
        return false;
    }

    fn condStart(c: ast.Cond) u32 {
        return switch (c) {
            .expr => |e| e.span.start,
            .assign => |a| a.names[0].name.span.start,
            .from => |a| a.names[0].name.span.start,
            .group => |a| a.names[0].name.span.start,
        };
    }

    /// The condition of `if`, `elseif`, or `while`. A leading name makes
    /// the reference parser peek at the next token.
    fn cond(x: *Exporter, c: ast.Cond) Error!?*Node {
        const first = x.tokAt(condStart(c));
        if (x.tagAt(first) == .name) x.lookahead(first);
        switch (c) {
            .expr => |e| return try x.expr(e),
            .assign => |a| {
                const n = try x.node("assign", x.pos(first));
                try x.setList(n, "lhs", try x.attNames(a.names, false));
                try x.setList(n, "rhs", try x.exprList(a.values));
                try x.set(n, "isfrom", .{ .boolean = false });
                try x.bindNames(a.names);
                return n;
            },
            .from => |a| {
                const n = try x.node("assign", x.pos(first));
                try x.setList(n, "lhs", try x.attNames(a.names, false));
                try x.setList(n, "rhs", try x.one(try x.expr(a.source)));
                try x.set(n, "isfrom", .{ .boolean = true });
                try x.bindNames(a.names);
                return n;
            },
            .group => |g| {
                try x.bindNames(g.names);
                for (g.inits) |gi| switch (gi) {
                    .ctor => |fields| try x.bindGroupFields(fields),
                    .copy => {},
                };
                return null;
            },
        }
    }

    /// Declared names with their attribute kind. `runtime` exports the
    /// runtime attribute expressions too (local declarations only).
    fn attNames(x: *Exporter, names: []ast.AttName, runtime: bool) Error![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        for (names) |an| {
            const n = try x.nameNode(an.name.text, x.pos(x.tokAt(an.name.span.start)));
            var attr: ?[]const u8 = null;
            var rt: std.ArrayList(*Node) = .empty;
            for (an.attribs) |a| switch (a) {
                .@"const" => attr = "const",
                .close => attr = "close",
                .group => attr = "group",
                .runtime => |e| if (runtime) try rt.append(x.arena, try x.expr(e)),
            };
            if (attr) |s| try x.set(n, "attr", .{ .str = s });
            try x.setList(n, "runtimeattrs", rt.items);
            try list.append(x.arena, n);
        }
        return list.items;
    }

    /// Global names end at the last token of their attribute list.
    fn globalNames(x: *Exporter, names: []ast.AttName) Error![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        for (names) |an| {
            const k = x.tokAt(an.name.span.start);
            const n = try x.nameNode(an.name.text, x.pos(k));
            var last = k;
            if (an.attribs.len > 0) {
                var j = k + 1;
                while (j + 1 < x.toks.len and x.tagAt(j) != .gt) j += 1;
                last = j;
            }
            setEnd(n, x.pos(last));
            try list.append(x.arena, n);
        }
        return list.items;
    }

    /// Group initializers of a local group declaration. Returns the node
    /// of the last one, which is what the reference parser keeps.
    fn groupInits(x: *Exporter, last_name: u32, inits: []ast.GroupInit) Error!?*Node {
        // Find the '=' after the names and their attributes.
        var k = last_name + 1;
        var depth: u32 = 0;
        while (k + 1 < x.toks.len) : (k += 1) {
            switch (x.tagAt(k)) {
                .lparen, .lbrace, .lbracket => depth += 1,
                .rparen, .rbrace, .rbracket => depth -|= 1,
                .assign => if (depth == 0) break,
                else => {},
            }
        }
        k += 1;
        var result: ?*Node = null;
        for (inits, 0..) |gi, i| {
            switch (gi) {
                .ctor => |fields| {
                    const r = try x.groupCtor(k, fields);
                    result = r.node;
                    k = r.next;
                },
                .copy => |n| {
                    const t = x.tokAt(n.span.start);
                    result = try x.nameNode(n.text, x.pos(t));
                    k = t + 1;
                },
            }
            if (i + 1 < inits.len and x.tagAt(k) == .comma) k += 1;
        }
        return result;
    }

    const CtorResult = struct { node: *Node, next: u32 };

    /// A group constructor starting at token `lbrace`. Subgroup fields
    /// carry no value, as in the reference.
    fn groupCtor(x: *Exporter, lbrace: u32, fields: []ast.GroupField) Error!CtorResult {
        const tbl = try x.node("table", x.pos(lbrace));
        var k = lbrace + 1;
        for (fields) |f| {
            const nt = x.tokAt(f.name.name.span.start);
            const tf = try x.node("tablefield", x.pos(nt));
            try x.setNode(tf, "key", try x.strNode(f.name.name.text, x.pos(nt)));
            var eq = nt + 1;
            while (eq + 1 < x.toks.len and x.tagAt(eq) != .assign) eq += 1;
            switch (f.value) {
                .expr => |e| {
                    try x.setNode(tf, "value", try x.expr(e));
                    k = x.tokAfter(e.span.end);
                },
                .group => |sub| {
                    const r = try x.groupCtor(eq + 1, sub);
                    k = r.next;
                },
            }
            try tbl.children.append(x.arena, tf);
            if (x.tagAt(k) == .comma or x.tagAt(k) == .semicolon) k += 1;
        }
        setEnd(tbl, x.pos(k));
        return .{ .node = tbl, .next = k + 1 };
    }

    /// Parameters, vararg flags, and body of a function-like node.
    fn function(x: *Exporter, n: *Node, f: *ast.Function, is_method: bool) Error!void {
        try x.setList(n, "params", try x.params(f));
        try x.set(n, "isvararg", .{ .boolean = f.is_vararg });
        try x.set(n, "ismethod", .{ .boolean = is_method });
        const mark = x.scope.items.len;
        defer x.scope.shrinkRetainingCapacity(mark);
        if (is_method) try x.bind("self", null);
        for (f.params) |pn| try x.bind(pn.text, null);
        if (f.vararg_name) |vn| try x.bind(vn.text, null);
        try x.statList(n, f.body.stats);
    }

    fn params(x: *Exporter, f: *ast.Function) Error![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        for (f.params) |pn| {
            const k = x.tokAt(pn.span.start);
            const n = try x.nameNode(pn.text, x.pos(k));
            setEnd(n, x.pos(k));
            try list.append(x.arena, n);
        }
        if (f.vararg_name) |vn| {
            const k = x.tokAt(vn.span.start);
            const n = try x.nameNode(vn.text, x.pos(k));
            setEnd(n, x.pos(k));
            try list.append(x.arena, n);
        } else if (f.is_vararg) {
            var k = x.tokAt(f.span.start);
            while (k + 1 < x.toks.len and x.tagAt(k) != .dots) k += 1;
            try list.append(x.arena, try x.node("vararg", x.pos(k)));
        }
        return list.items;
    }

    /// `base.name` as built by `fieldsel`: a field node at the separator
    /// with a string key at the name.
    fn fieldOf(x: *Exporter, base: *Node, name: ast.Name) Error!*Node {
        const nk = x.tokAt(name.span.start);
        const n = try x.node("field", x.pos(nk - 1));
        try x.setNode(n, "table", base);
        try x.setNode(n, "key", try x.strNode(name.text, x.pos(nk)));
        return n;
    }

    // -----------------------------------------------------------------
    // Expressions

    fn one(x: *Exporter, n: *Node) Error![]*Node {
        const list = try x.arena.alloc(*Node, 1);
        list[0] = n;
        return list;
    }

    fn exprList(x: *Exporter, es: []*ast.Expr) Error![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        for (es) |e| try list.append(x.arena, try x.expr(e));
        return list.items;
    }

    fn callArgs(x: *Exporter, args: []*ast.Expr, kind: ast.ArgsKind) Error![]*Node {
        if (kind == .string) {
            const k = x.tokAt(args[0].span.start);
            return x.one(try x.strNode(args[0].kind.string, x.pos(k)));
        }
        return x.exprList(args);
    }

    fn literal(x: *Exporter, ty: []const u8, k: u32) Error!*Node {
        const n = try x.node(ty, x.pos(k));
        x.literalEnd(n, k);
        return n;
    }

    fn expr(x: *Exporter, e: *ast.Expr) Error!*Node {
        const first = x.tokAt(e.span.start);
        switch (e.kind) {
            .paren, .optional, .chain => |inner| return x.expr(inner),
            .nil => return x.literal("nil", first),
            .true => return x.literal("true", first),
            .false => return x.literal("false", first),
            .vararg => return x.literal("vararg", first),
            .integer => |v| {
                const n = try x.literal("number", first);
                try x.set(n, "value", .{ .int = v });
                return n;
            },
            .float => |v| {
                const n = try x.literal("number", first);
                try x.set(n, "value", .{ .float = v });
                return n;
            },
            .bigint, .decimal => |digits| {
                const n = try x.literal("number", first);
                try x.set(n, "value", .{ .str = digits });
                try x.set(n, "kind", .{ .str = if (e.kind == .bigint) "bigint" else "decimal" });
                return n;
            },
            .string => |s| {
                if (x.tagAt(first) == .interp_simple) return x.interp(e, first);
                const n = try x.literal("string", first);
                try x.set(n, "value", .{ .str = s });
                return n;
            },
            .interp => return x.interp(e, first),
            .function => |f| {
                const n = try x.node("funcexpr", x.pos(first));
                try x.function(n, f, false);
                return n;
            },
            .table => |fields| return x.table(e, fields),
            .binop => |b| {
                const op = x.tokAfter(b.lhs.span.end);
                const left = try x.expr(b.lhs);
                const n = try x.node("binop", x.pos(op));
                try x.set(n, "op", .{ .str = b.op.symbol() });
                try x.setNode(n, "left", left);
                const right = try x.expr(b.rhs);
                try x.setNode(n, "right", right);
                // The reference copies the end of its second operand
                // descriptor, which the code generator swaps with the
                // first one for some operators.
                const from = if (swapsOperands(x, b.op, b.lhs, b.rhs)) left else right;
                n.endline = from.endline;
                n.endcolumn = from.endcolumn;
                return n;
            },
            .unop => |u| {
                const n = try x.node("unop", x.pos(first));
                try x.set(n, "op", .{ .str = unopSymbol(u.op) });
                const operand = try x.expr(u.operand);
                try x.setNode(n, "operand", operand);
                n.endline = operand.endline;
                n.endcolumn = operand.endcolumn;
                return n;
            },
            .name => |nm| return x.nameNode(nm.text, x.pos(first)),
            .index => |ix| {
                const sep = x.tokAfter(ix.obj.span.end);
                const obj = try x.expr(ix.obj);
                if (ix.dot) {
                    const n = try x.node("field", x.pos(sep));
                    try x.setNode(n, "table", obj);
                    try x.setNode(n, "key", try x.strNode(ix.key.kind.string, x.pos(x.tokAt(ix.key.span.start))));
                    return n;
                }
                const n = try x.node("index", x.pos(sep));
                try x.setNode(n, "table", obj);
                try x.setNode(n, "key", try x.expr(ix.key));
                return n;
            },
            .call => |c| {
                const at = x.tokAfter(c.callee.span.end);
                const func = try x.expr(c.callee);
                const n = try x.node("callexpr", x.pos(at));
                try x.setNode(n, "func", func);
                try x.setList(n, "args", try x.callArgs(c.args, c.args_kind));
                x.endAt(n, e.span.end);
                return n;
            },
            .method => |m| {
                const colon = x.tokAfter(m.obj.span.end);
                const obj = try x.expr(m.obj);
                const n = try x.node("methodcall", x.pos(colon));
                try x.setNode(n, "func", obj);
                try x.setList(n, "args", try x.callArgs(m.args, m.args_kind));
                try x.set(n, "method", .{ .str = m.name.text });
                return n;
            },
            .slice => |sl| {
                const br = x.tokAfter(sl.obj.span.end);
                const obj = try x.expr(sl.obj);
                const n = try x.node("slice", x.pos(br));
                try x.setNode(n, "table", obj);
                if (sl.from) |f| try x.setNode(n, "start", try x.expr(f));
                if (sl.to) |t| try x.setNode(n, "finish", try x.expr(t));
                return n;
            },
            .catch_ => |c| {
                const n = try x.node("catchexpr", x.pos(first));
                const handler = if (c.handler) |h| try x.expr(h) else null;
                try x.setNode(n, "expr", try x.expr(c.body));
                try x.setNode(n, "handler", handler);
                x.endAt(n, e.span.end);
                return n;
            },
            .do_ => |b| {
                const n = try x.node("doexpr", x.pos(first));
                try x.statList(n, b.stats);
                x.endAt(n, e.span.end);
                return n;
            },
            .enum_ => |names| {
                const p = x.pos(first);
                const n = try x.node("enum", p);
                var list: std.ArrayList(*Node) = .empty;
                for (names) |nm| try list.append(x.arena, try x.nameNode(nm.text, p));
                try x.setList(n, "names", list.items);
                x.endAt(n, e.span.end);
                return n;
            },
            .query => |q| return x.query(e, q),
        }
    }

    fn unopSymbol(op: ast.UnOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .not => "not",
            .len => "#",
            .bnot => "~",
        };
    }

    fn table(x: *Exporter, e: *ast.Expr, fields: []ast.Field) Error!*Node {
        const n = try x.node("table", x.pos(x.tokAt(e.span.start)));
        for (fields) |f| {
            const tf: *Node = switch (f.kind) {
                .positional => |v| blk: {
                    const k = x.tokAt(v.span.start);
                    if (x.tagAt(k) == .name) x.lookahead(k);
                    const tf = try x.node("tablefield", x.pos(k));
                    try x.setNode(tf, "value", try x.expr(v));
                    break :blk tf;
                },
                .named => |nv| blk: {
                    const k = x.tokAt(nv.name.span.start);
                    x.lookahead(k);
                    const p = x.pos(k);
                    const tf = try x.node("tablefield", p);
                    try x.setNode(tf, "key", try x.strNode(nv.name.text, p));
                    try x.setNode(tf, "value", try x.expr(nv.value));
                    break :blk tf;
                },
                .keyed => |kv| blk: {
                    const k = x.tokAt(kv.key.span.start) - 1;
                    const tf = try x.node("tablefield", x.pos(k));
                    try x.setNode(tf, "key", try x.expr(kv.key));
                    try x.setNode(tf, "value", try x.expr(kv.value));
                    break :blk tf;
                },
            };
            try n.children.append(x.arena, tf);
        }
        x.endAt(n, e.span.end);
        return n;
    }

    /// An interpolated string. The parts come from the token stream: each
    /// literal section is a token, `$name` is a name token right after
    /// a section ending in `$`, and `$(...)` holds an expression.
    fn interp(x: *Exporter, e: *ast.Expr, begin: u32) Error!*Node {
        const n = try x.node("interp", x.pos(begin));
        var parts: std.ArrayList(*Node) = .empty;
        const exprs: []ast.InterpPart = if (e.kind == .interp) e.kind.interp else &.{};
        var pi: usize = 0;
        var k = begin;
        while (true) {
            const t = x.toks[k];
            const lit = x.text(k);
            const p: Pos = .{ .line = x.endLine(k), .col = x.curCol(k) };
            if (lit.len > 0) {
                try parts.append(x.arena, try x.strNode(lit, p));
                if (pi < exprs.len and exprs[pi] == .text) pi += 1;
            }
            if (t.tag == .interp_end or t.tag == .interp_simple or t.tag == .string) break;
            if (t.tag != .interp_begin and t.tag != .interp_mid) break;
            if (x.src[t.span.end - 1] == '$' and k + 1 < x.toks.len and x.tagAt(k + 1) == .name) {
                const nk = k + 1;
                const off = x.toks[nk].span.start;
                try parts.append(x.arena, try x.nameNode(x.text(nk), .{ .line = x.lineOf(off), .col = x.colOf(off) }));
                if (pi < exprs.len) pi += 1;
                k = nk + 1;
                continue;
            }
            while (pi < exprs.len and exprs[pi] == .text) pi += 1;
            if (pi >= exprs.len) break;
            const sub = exprs[pi].expr;
            pi += 1;
            try parts.append(x.arena, try x.expr(sub));
            k = x.tokAfter(sub.span.end);
        }
        try x.setList(n, "parts", parts.items);
        try x.set(n, "nparts", .{ .int = @intCast(parts.items.len) });
        return n;
    }

    // -----------------------------------------------------------------
    // Queries

    fn query(x: *Exporter, e: *ast.Expr, q: *ast.Query) Error!*Node {
        const n = try x.node("query", x.pos(x.tokAt(e.span.start)));
        var aliases: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList(*Node) = .empty;
        for (q.sources) |src| {
            try sources.append(x.arena, try x.querySource(src));
            try aliases.append(x.arena, src.alias.text);
        }
        const saved = x.q_aliases;
        x.q_aliases = aliases.items;
        defer x.q_aliases = saved;
        // Clause expressions run with the row variables as parameters.
        const mark = x.scope.items.len;
        defer x.scope.shrinkRetainingCapacity(mark);
        for (aliases.items) |a| try x.bind(a, null);
        try x.setList(n, "sources", sources.items);

        // Clauses in source order. The keyword sits before the first
        // expression of the clause ('by' and 'distinct' included).
        const Cl = struct { kw: u32, kind: []const u8, idx: u8 };
        var cls: std.ArrayList(Cl) = .empty;
        if (q.where) |w| try cls.append(x.arena, .{ .kw = x.tokAt(w.span.start) - 1, .kind = "where", .idx = 0 });
        if (q.select) |items| try cls.append(x.arena, .{ .kw = x.tokAt(items[0].expr.span.start) - 1 - @as(u32, @intFromBool(q.distinct)), .kind = "select", .idx = 1 });
        if (q.group_by) |keys| try cls.append(x.arena, .{ .kw = x.tokAt(keys[0].span.start) - 2, .kind = "group", .idx = 2 });
        if (q.having) |h| try cls.append(x.arena, .{ .kw = x.tokAt(h.span.start) - 1, .kind = "having", .idx = 3 });
        if (q.order_by) |items| try cls.append(x.arena, .{ .kw = x.tokAt(items[0].expr.span.start) - 2, .kind = "order", .idx = 4 });
        if (q.limit) |l| try cls.append(x.arena, .{ .kw = x.tokAt(l.span.start) - 1, .kind = "limit", .idx = 5 });
        if (q.offset) |o| try cls.append(x.arena, .{ .kw = x.tokAt(o.span.start) - 1, .kind = "offset", .idx = 6 });
        std.mem.sort(Cl, cls.items, {}, struct {
            fn lt(_: void, a: Cl, b: Cl) bool {
                return a.kw < b.kw;
            }
        }.lt);

        var clauses: std.ArrayList(*Node) = .empty;
        for (cls.items) |c| {
            const cn = try x.node("qclause", x.pos(c.kw));
            try x.set(cn, "kind", .{ .str = c.kind });
            var items: std.ArrayList(*Node) = .empty;
            switch (c.idx) {
                0 => try items.append(x.arena, try x.qexpr(q.where.?)),
                1 => {
                    if (q.distinct) try x.set(cn, "distinct", .{ .boolean = true });
                    for (q.select.?) |it| {
                        const itn = try x.node("qitem", x.pos(x.tokAt(it.expr.span.start)));
                        try x.setNode(itn, "expr", try x.qexpr(it.expr));
                        if (it.alias) |a| try x.set(itn, "name", .{ .str = a.text });
                        try items.append(x.arena, itn);
                    }
                },
                2 => for (q.group_by.?) |k| try items.append(x.arena, try x.qexpr(k)),
                3 => try items.append(x.arena, try x.qexpr(q.having.?)),
                4 => for (q.order_by.?) |it| {
                    const itn = try x.node("qitem", x.pos(x.tokAt(it.expr.span.start)));
                    x.q_order = true;
                    const ex = try x.qexpr(it.expr);
                    x.q_order = false;
                    try x.setNode(itn, "expr", ex);
                    if (it.desc) try x.set(itn, "desc", .{ .boolean = true });
                    try items.append(x.arena, itn);
                },
                5 => try items.append(x.arena, try x.qexpr(q.limit.?)),
                else => try items.append(x.arena, try x.qexpr(q.offset.?)),
            }
            try x.setList(cn, "items", items.items);
            try clauses.append(x.arena, cn);
        }
        try x.setList(n, "clauses", clauses.items);
        x.endAt(n, e.span.end);
        return n;
    }

    /// One query source. Field and index steps take the line of the
    /// token after the step and the column of the whole source.
    fn querySource(x: *Exporter, src: ast.QSource) Error!*Node {
        const first = x.tokAt(src.expr.span.start);
        const p = x.pos(first);
        const n = try x.node("qsource", p);
        var hasas = false;
        if (x.tagAt(first) == .lparen) {
            const inner = src.expr.kind.paren;
            try x.setNode(n, "expr", try x.expr(inner));
            hasas = true;
        } else {
            try x.setNode(n, "expr", try x.qsourceExpr(src.expr, p.col));
            // An `as` alias differs from the implicit one when the
            // token after the source expression is the word `as`.
            const after = x.tokAfter(src.expr.span.end);
            hasas = x.tagAt(after) == .name and std.mem.eql(u8, x.text(after), "as");
        }
        try x.set(n, "alias", .{ .str = src.alias.text });
        try x.set(n, "hasas", .{ .boolean = hasas });
        return n;
    }

    fn qsourceExpr(x: *Exporter, e: *ast.Expr, col: u32) Error!*Node {
        switch (e.kind) {
            .name => |nm| return x.nameNode(nm.text, x.pos(x.tokAt(e.span.start))),
            .index => |ix| {
                const base = try x.qsourceExpr(ix.obj, col);
                const after = x.tokAfter(e.span.end);
                const line = x.curLine(after);
                if (ix.dot) {
                    const n = try x.node("field", .{ .line = line, .col = col });
                    try x.setNode(n, "table", base);
                    try x.setNode(n, "key", try x.strNode(ix.key.kind.string, .{ .line = line, .col = col }));
                    return n;
                }
                const kt = x.tokAt(ix.key.span.start);
                const kp: Pos = .{ .line = x.curLine(kt), .col = col };
                const key = try x.node(if (ix.key.kind == .integer) "number" else "string", kp);
                switch (ix.key.kind) {
                    .integer => |v| try x.set(key, "value", .{ .int = v }),
                    .string => |s| try x.set(key, "value", .{ .str = s }),
                    else => {},
                }
                const n = try x.node("index", .{ .line = line, .col = col });
                try x.setNode(n, "table", base);
                try x.setNode(n, "key", key);
                return n;
            },
            else => return x.expr(e),
        }
    }

    fn isRowVar(x: *const Exporter, name: []const u8) bool {
        for (x.q_aliases) |a| if (std.mem.eql(u8, a, name)) return true;
        return false;
    }

    /// A name chain `a.b.c` built at one position, as the reference
    /// query parser does.
    fn chainNodes(x: *Exporter, names: []const []const u8, p: Pos) Error!*Node {
        var n = try x.nameNode(names[0], p);
        for (names[1..]) |nm| {
            const f = try x.node("field", p);
            try x.setNode(f, "table", n);
            try x.setNode(f, "key", try x.strNode(nm, p));
            n = f;
        }
        return n;
    }

    fn qexpr(x: *Exporter, qe: *ast.QExpr) Error!*Node {
        const first = x.tokAt(qe.span.start);
        switch (qe.kind) {
            .literal => |lit| {
                const p = x.pos(first);
                return switch (lit.kind) {
                    .nil => x.node("nil", p),
                    .true => x.node("true", p),
                    .false => x.node("false", p),
                    .integer => |v| blk: {
                        const n = try x.node("number", p);
                        try x.set(n, "value", .{ .int = v });
                        break :blk n;
                    },
                    .float => |v| blk: {
                        const n = try x.node("number", p);
                        try x.set(n, "value", .{ .float = v });
                        break :blk n;
                    },
                    .string => |s| x.strNode(s, p),
                    .bigint, .decimal => |d| blk: {
                        const n = try x.node("number", p);
                        try x.set(n, "value", .{ .str = d });
                        try x.set(n, "kind", .{ .str = if (lit.kind == .bigint) "bigint" else "decimal" });
                        break :blk n;
                    },
                    else => x.expr(lit),
                };
            },
            .paren => |inner| return x.qexpr(inner),
            .unop => |u| {
                const n = try x.node("unop", x.pos(first));
                try x.set(n, "op", .{ .str = unopSymbol(u.op) });
                try x.setNode(n, "operand", try x.qexpr(u.operand));
                return n;
            },
            .binop => |b| {
                const op = x.tokAfter(b.lhs.span.end);
                const left = try x.qexpr(b.lhs);
                const n = try x.node("binop", x.pos(op));
                try x.set(n, "op", .{ .str = b.op.symbol() });
                try x.setNode(n, "left", left);
                try x.setNode(n, "right", try x.qexpr(b.rhs));
                return n;
            },
            .aggregate => |a| {
                const p = x.pos(first + 1);
                const n = try x.node("callexpr", p);
                try x.setNode(n, "func", try x.nameNode(@tagName(a.func), p));
                const arg = if (a.arg) |ae| try x.qexpr(ae) else try x.node("qstar", p);
                try x.setList(n, "args", try x.one(arg));
                return n;
            },
            .chain => |names| {
                var strs = try x.arena.alloc([]const u8, names.len);
                for (names, 0..) |nm, i| strs[i] = nm.text;
                const row = x.isRowVar(strs[0]);
                if ((row and names.len <= 2) or (!row and x.q_order and names.len == 1)) {
                    return x.chainNodes(strs, x.pos(first));
                }
                // Deeper row chains and outer names: built at the token
                // after the chain.
                return x.chainNodes(strs, x.pos(x.tokAfter(qe.span.end)));
            },
            .host => |h| {
                if (x.tagAt(first) != .name) return x.expr(h);
                return x.hostChain(h);
            },
        }
    }

    /// A host expression that starts with a name chain followed by
    /// suffixes. The chain prefix is built at the first suffix token,
    /// and the suffixes are ordinary expressions.
    fn hostChain(x: *Exporter, e: *ast.Expr) Error!*Node {
        // The parser reads every `.name` step into the chain, so the
        // outermost node is always a suffix.
        if (isPlainChain(e)) return x.chainExpr(e, x.pos(x.tokAfter(e.span.end)));
        return x.hostSuffix(e);
    }

    fn isPlainChain(e: *ast.Expr) bool {
        return switch (e.kind) {
            .name => true,
            .index => |ix| ix.dot and isPlainChain(ix.obj),
            else => false,
        };
    }

    fn chainExpr(x: *Exporter, e: *ast.Expr, p: Pos) Error!*Node {
        switch (e.kind) {
            .name => |nm| return x.nameNode(nm.text, p),
            .index => |ix| {
                const n = try x.node("field", p);
                try x.setNode(n, "table", try x.chainExpr(ix.obj, p));
                try x.setNode(n, "key", try x.strNode(ix.key.kind.string, p));
                return n;
            },
            else => return x.expr(e),
        }
    }

    /// Exports a suffix node of a host expression whose innermost
    /// prefix is a plain name chain.
    fn hostSuffix(x: *Exporter, e: *ast.Expr) Error!*Node {
        const inner: ?*ast.Expr = switch (e.kind) {
            .index => |ix| ix.obj,
            .call => |c| c.callee,
            .method => |m| m.obj,
            .slice => |s| s.obj,
            .optional, .chain => |i| i,
            else => null,
        };
        const obj = inner orelse return x.expr(e);
        // Export the object first, recursively, then this suffix with
        // the ordinary positions.
        const objn = if (isPlainChain(obj)) try x.chainExpr(obj, x.pos(x.tokAfter(obj.span.end))) else try x.hostSuffix(obj);
        switch (e.kind) {
            .optional, .chain => return objn,
            .index => |ix| {
                const sep = x.tokAfter(ix.obj.span.end);
                if (ix.dot) {
                    const n = try x.node("field", x.pos(sep));
                    try x.setNode(n, "table", objn);
                    try x.setNode(n, "key", try x.strNode(ix.key.kind.string, x.pos(x.tokAt(ix.key.span.start))));
                    return n;
                }
                const n = try x.node("index", x.pos(sep));
                try x.setNode(n, "table", objn);
                try x.setNode(n, "key", try x.expr(ix.key));
                return n;
            },
            .call => |c| {
                const n = try x.node("callexpr", x.pos(x.tokAfter(c.callee.span.end)));
                try x.setNode(n, "func", objn);
                try x.setList(n, "args", try x.callArgs(c.args, c.args_kind));
                x.endAt(n, e.span.end);
                return n;
            },
            .method => |m| {
                const n = try x.node("methodcall", x.pos(x.tokAfter(m.obj.span.end)));
                try x.setNode(n, "func", objn);
                try x.setList(n, "args", try x.callArgs(m.args, m.args_kind));
                try x.set(n, "method", .{ .str = m.name.text });
                return n;
            },
            .slice => |sl| {
                const n = try x.node("slice", x.pos(x.tokAfter(sl.obj.span.end)));
                try x.setNode(n, "table", objn);
                if (sl.from) |f| try x.setNode(n, "start", try x.expr(f));
                if (sl.to) |t| try x.setNode(n, "finish", try x.expr(t));
                return n;
            },
            else => unreachable,
        }
    }
};

// ---------------------------------------------------------------------
// Operand order of the reference code generator
//
// The reference parser takes the end position of a binary operation
// from its second operand descriptor after code generation, and the code
// generator swaps the two descriptors in some cases: `>` and `>=` always,
// commutative arithmetic and bitwise operators when the first operand is
// a numeric constant, and equality when the first operand is a constant.
// Constant folding runs first and never swaps. The functions below decide
// which operand that is, with the same folding rules.

const Num = union(enum) { int: i64, float: f64 };

/// A compile-time constant: what an expression descriptor holds when it
/// has no code and no jumps.
const Const = union(enum) {
    num: Num,
    str,
    nil,
    true,
    false,

    fn truthy(c: Const) bool {
        return c != .nil and c != .false;
    }
};

fn swapsOperands(x: *const Exporter, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) bool {
    const ca = constOf(x, lhs);
    const a: ?Num = if (ca) |c| (if (c == .num) c.num else null) else null;
    switch (op) {
        .gt, .ge => return true,
        .eq, .ne => return ca != null,
        .add, .mul => return a != null and foldBin(op, a, numeral(x, rhs)) == null,
        .band, .bor, .bxor => return a != null and a.? == .int and foldBin(op, a, numeral(x, rhs)) == null,
        .shl => {
            if (a == null or a.? != .int or foldBin(op, a, numeral(x, rhs)) != null) return false;
            return a.?.int >= -127 and a.?.int <= 128;
        },
        else => return false,
    }
}

fn numeral(x: *const Exporter, e: *ast.Expr) ?Num {
    const c = constOf(x, e) orelse return null;
    return if (c == .num) c.num else null;
}

/// The constant an expression folds to in the reference code generator,
/// if any. Names of compile-time constant locals count, as do `and` and
/// `or` whose first operand decides the result at compile time.
fn constOf(x: *const Exporter, e: *ast.Expr) ?Const {
    // Operator chains would revisit their left operands at every level.
    if (e.kind != .binop) return constOfUncached(x, e);
    if (x.const_cache.get(e)) |c| return c;
    const c = constOfUncached(x, e);
    x.const_cache.put(x.arena, e, c) catch {};
    return c;
}

fn constOfUncached(x: *const Exporter, e: *ast.Expr) ?Const {
    return switch (e.kind) {
        .integer => |i| .{ .num = .{ .int = i } },
        .float => |f| .{ .num = .{ .float = f } },
        .nil => .nil,
        .true => .true,
        .false => .false,
        // A backtick string with text compiles to code.
        .string => |s| if (x.tagAt(x.tokAt(e.span.start)) != .interp_simple or s.len == 0) .str else null,
        .paren => |inner| constOf(x, inner),
        .name => |n| x.lookupConst(n.text),
        .unop => |u| blk: {
            const v = constOf(x, u.operand) orelse break :blk null;
            switch (u.op) {
                .not => break :blk if (v.truthy()) .false else .true,
                .neg => {
                    if (v != .num) break :blk null;
                    break :blk switch (v.num) {
                        .int => |i| Const{ .num = .{ .int = 0 -% i } },
                        .float => |f| if (checkFloat(-f)) |r| Const{ .num = r } else null,
                    };
                },
                .bnot => {
                    if (v != .num) break :blk null;
                    const i = toInt(v.num) orelse break :blk null;
                    break :blk Const{ .num = .{ .int = ~i } };
                },
                .len => break :blk null,
            }
        },
        .binop => |b| switch (b.op) {
            .@"and" => blk: {
                const l = constOf(x, b.lhs) orelse break :blk null;
                break :blk if (l != .nil and l != .false) constOf(x, b.rhs) else null;
            },
            .@"or" => blk: {
                const l = constOf(x, b.lhs) orelse break :blk null;
                break :blk if (l == .nil or l == .false) constOf(x, b.rhs) else null;
            },
            else => if (foldBin(b.op, numeral(x, b.lhs), numeral(x, b.rhs))) |r| Const{ .num = r } else null,
        },
        else => null,
    };
}

/// Folding never produces NaN or a float zero.
fn checkFloat(f: f64) ?Num {
    if (std.math.isNan(f) or f == 0) return null;
    return .{ .float = f };
}

fn toFloat(v: Num) f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
    };
}

/// Exact conversion to an integer, as the bitwise operators require.
fn toInt(v: Num) ?i64 {
    switch (v) {
        .int => |i| return i,
        .float => |f| {
            if (@floor(f) != f) return null;
            if (f < -9223372036854775808.0 or f >= 9223372036854775808.0) return null;
            return @intFromFloat(f);
        },
    }
}

fn shiftLeft(a: i64, b: i64) i64 {
    const ua: u64 = @bitCast(a);
    if (b <= -64 or b >= 64) return 0;
    if (b >= 0) return @bitCast(ua << @intCast(b));
    return @bitCast(ua >> @intCast(-b));
}

fn foldBin(op: ast.BinOp, oa: ?Num, ob: ?Num) ?Num {
    const a = oa orelse return null;
    const b = ob orelse return null;
    switch (op) {
        .band, .bor, .bxor, .shl, .shr => {
            const i = toInt(a) orelse return null;
            const j = toInt(b) orelse return null;
            return .{ .int = switch (op) {
                .band => i & j,
                .bor => i | j,
                .bxor => i ^ j,
                .shl => shiftLeft(i, j),
                else => shiftLeft(i, 0 -% j),
            } };
        },
        .div, .idiv, .mod => if (toFloat(b) == 0) return null,
        .add, .sub, .mul, .pow => {},
        else => return null,
    }
    if (op == .div) return checkFloat(toFloat(a) / toFloat(b));
    if (op == .pow) {
        const fb = toFloat(b);
        const fa = toFloat(a);
        return checkFloat(if (fb == 2) fa * fa else std.math.pow(f64, fa, fb));
    }
    if (a == .int and b == .int) {
        const i = a.int;
        const j = b.int;
        return .{ .int = switch (op) {
            .add => i +% j,
            .sub => i -% j,
            .mul => i *% j,
            .mod => blk: {
                if (j == -1) break :blk 0;
                const m = @rem(i, j);
                break :blk if (m != 0 and (m ^ j) < 0) m + j else m;
            },
            .idiv => blk: {
                if (j == -1) break :blk 0 -% i;
                const q = @divTrunc(i, j);
                break :blk if ((i ^ j) < 0 and @rem(i, j) != 0) q - 1 else q;
            },
            else => unreachable,
        } };
    }
    const fa = toFloat(a);
    const fb = toFloat(b);
    return checkFloat(switch (op) {
        .add => fa + fb,
        .sub => fa - fb,
        .mul => fa * fb,
        .mod => blk: {
            var m = @rem(fa, fb);
            if (if (m > 0) fb < 0 else (m < 0 and fb != m)) m += fb;
            break :blk m;
        },
        .idiv => @floor(fa / fb),
        else => unreachable,
    });
}

// ---------------------------------------------------------------------
// JSON output

/// Writes the tree as indented JSON. Fields keep their export order.
pub fn writeJson(w: *std.Io.Writer, n: *const Node) std.Io.Writer.Error!void {
    try jsonNode(w, n, 0);
    try w.writeByte('\n');
}

fn indent(w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * 2);
}

/// Writes a JSON string. A surrogate code point is written as an escape
/// and a byte that starts no valid sequence as U+FFFD, so that the output
/// is always valid UTF-8.
pub fn jsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{c}),
                else => try w.writeByte(c),
            }
            i += 1;
            continue;
        }
        if (wtf8.decodeAt(s, i)) |d| {
            if (d.cp >= 0xD800 and d.cp <= 0xDFFF) {
                try w.print("\\u{x:0>4}", .{d.cp});
            } else {
                try w.writeAll(s[i .. i + d.len]);
            }
            i += d.len;
        } else {
            try w.writeAll("\u{FFFD}");
            i += 1;
        }
    }
    try w.writeByte('"');
}

fn jsonNode(w: *std.Io.Writer, n: *const Node, depth: usize) std.Io.Writer.Error!void {
    try w.writeAll("{\n");
    var first = true;
    const Sep = struct {
        fn key(wr: *std.Io.Writer, f: *bool, d: usize, k: []const u8) std.Io.Writer.Error!void {
            if (!f.*) try wr.writeAll(",\n");
            f.* = false;
            try indent(wr, d + 1);
            try jsonString(wr, k);
            try wr.writeAll(": ");
        }
    };
    if (n.type) |t| {
        try Sep.key(w, &first, depth, "type");
        try jsonString(w, t);
    }
    try Sep.key(w, &first, depth, "line");
    try w.print("{d}", .{n.line});
    try Sep.key(w, &first, depth, "column");
    try w.print("{d}", .{n.column});
    if (n.endline > 0) {
        try Sep.key(w, &first, depth, "endline");
        try w.print("{d}", .{n.endline});
        try Sep.key(w, &first, depth, "endcolumn");
        try w.print("{d}", .{n.endcolumn});
    }
    for (n.fields.items) |f| {
        try Sep.key(w, &first, depth, f.key);
        try jsonVal(w, f.val, depth + 1);
    }
    if (n.children.items.len > 0) {
        try Sep.key(w, &first, depth, "children");
        try jsonList(w, n.children.items, depth + 1);
    }
    try w.writeByte('\n');
    try indent(w, depth);
    try w.writeByte('}');
}

fn jsonList(w: *std.Io.Writer, list: []const *Node, depth: usize) std.Io.Writer.Error!void {
    try w.writeAll("[\n");
    for (list, 0..) |c, i| {
        if (i > 0) try w.writeAll(",\n");
        try indent(w, depth + 1);
        try jsonNode(w, c, depth + 1);
    }
    try w.writeByte('\n');
    try indent(w, depth);
    try w.writeByte(']');
}

fn jsonVal(w: *std.Io.Writer, v: Val, depth: usize) std.Io.Writer.Error!void {
    switch (v) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isFinite(f)) try w.print("{d}", .{f}) else try w.writeAll("null");
        },
        .str => |s| try jsonString(w, s),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .node => |c| try jsonNode(w, c, depth),
        .list => |l| try jsonList(w, l, depth),
    }
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

fn findField(n: *const Node, key: []const u8) ?Val {
    for (n.fields.items) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.val;
    }
    return null;
}

test "export positions follow the reference parser" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try run(testing.allocator, arena, "local x = 1 + y -- note\nprint(x)", .{ .chunkname = "=t" }, null);
    const root = res.tree;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    const local = root.children.items[0];
    try testing.expectEqualStrings("local", local.type.?);
    try testing.expectEqual(@as(u32, 15), local.endcolumn);
    const bin = findField(local, "values").?.list[0];
    try testing.expectEqualStrings("binop", bin.type.?);
    // The operator token starts the node. A constant first operand is
    // swapped with the second one, so the end is the end of `1`.
    try testing.expectEqual(@as(u32, 13), bin.column);
    try testing.expectEqual(@as(u32, 11), bin.endcolumn);
    const call = root.children.items[1];
    try testing.expectEqualStrings("callstat", call.type.?);
    const comments = findField(root, "comments").?.list;
    try testing.expectEqualStrings(" note", findField(comments[0], "text").?.str);
}

test "recovery keeps the statements before an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try run(testing.allocator, arena, "x = 1 2 y = 3\nlocal z = (", .{ .chunkname = "=t" }, null);
    const root = res.tree;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqualStrings("error_stat", root.children.items[1].type.?);
    const errors = findField(root, "errors").?.list;
    try testing.expectEqual(@as(usize, 2), errors.len);
    try testing.expectEqualStrings("unexpected '<integer>'", findField(errors[0], "message").?.str);
    try testing.expectEqual(@as(u32, 2), errors[1].line);

    const strict = try run(testing.allocator, arena, "local z = (", .{ .chunkname = "=t", .recover = false }, null);
    try testing.expectEqualStrings("t:1: unexpected symbol near <eof>", strict.fail);
}

test "error line extraction" {
    try testing.expectEqual(@as(u32, 12), errorLine("[string \"a:b\"]:12: oops"));
    try testing.expectEqual(@as(u32, 3), errorLine("file.lus:3: oops"));
    try testing.expectEqual(@as(u32, 1), errorLine("no line here"));
}
