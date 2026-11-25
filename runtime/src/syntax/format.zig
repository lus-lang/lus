//! The source formatter behind `debug.format` and `lus fmt`.
//!
//! The output follows the 1.7 reference formatter (`lus/src/lformat.c` at
//! the `v1.7-legacy` tag) byte for byte on valid input, so that the
//! language server and the idempotence tests see the same text. The
//! formatter walks the syntax tree of `parser.zig` and takes every line
//! number from the token stream, the way the reference parser records
//! them: a statement sits on the line where the lexer stood after reading
//! its first token, and it ends on the line of its last token.
//!
//! Layout rules, all inherited from the reference:
//!
//! - Statements go one per line, indented by `indent_width` spaces per
//!   block level. Blank lines between top level statements are kept (at
//!   most one), and nested blocks lose theirs.
//! - Comments are emitted before the first statement that starts after
//!   them. A short comment on the last line of a statement, or on the line
//!   of a block header, stays on that line after two spaces.
//! - Tables with more than three fields go one field per line with a
//!   trailing comma. Smaller tables stay on one line.
//! - Binary operators get one space on each side. Parentheses from the
//!   source are kept, one pair for any number of nested pairs, and a pair
//!   is added only where precedence requires one and the source has none.
//! - Numbers are respelled from their value. Every string literal keeps
//!   its source text, with its quotes, long brackets, and escapes exactly
//!   as written, since the layout is all that a formatter changes.
//!
//! The reference formatter changes the meaning of a program in a few places.
//! It drops global functions, `global *`, global values and attributes,
//! catch handlers, the `?` of optional chaining, the condition of some
//! `repeat` loops and of group conditions, and the attributes of group
//! fields. It writes reserved words as bare table keys, `inf` for an
//! overflowing literal, `-1` for a wrapped hexadecimal literal, `$x` for
//! `$(x)` before a name character, and `\0` before a digit. This formatter
//! writes all of those constructs out in full instead, and escapes the bytes
//! of a string that are not UTF-8, so that formatting never changes what a
//! program means. A shebang line, a long comment, and a short comment that
//! starts with punctuation, such as `--[ note` or the `-->` of an expected
//! output, are kept as they are.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const astexport = @import("astexport.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const strict_rules = @import("strict.zig");
const walk = @import("walk.zig");
const Allocator = std.mem.Allocator;
const Token = token.Token;
const Tag = token.Tag;

pub const Options = struct {
    /// Chunk name used in error messages ("@file", "=name").
    chunkname: []const u8 = "=format",
    /// Spaces per indentation level. Zero selects the default of 4.
    indent_width: u32 = 4,
    /// Optional compiler pass that reports the errors found after parsing
    /// (an undeclared global under a `global` declaration, assignment to a
    /// constant), which the reference formatter also refuses.
    checker: ?astexport.Checker = null,
    /// Write the strict style of `syntax/strict.zig`: a blank line around
    /// every block that spans several lines, double quotes, tables on one
    /// line only when they fit, and calls, tables, and chains of operators
    /// wrapped at 100 columns.
    strict: bool = false,
};

pub const Outcome = union(enum) {
    /// The formatted source, allocated in the arena.
    ok: []const u8,
    /// Why the source could not be formatted.
    fail: []const u8,
};

const Error = Allocator.Error;

/// Formats `src`. Everything is allocated in `arena`, and `gpa` backs the
/// lexer's scratch lists only.
pub fn format(gpa: Allocator, arena: Allocator, src: []const u8, opts: Options) Error!Outcome {
    if (!opts.strict) return formatOnce(gpa, arena, src, opts);
    // A table or a call that one pass breaks over several lines can let
    // the next pass keep an enclosing construct on the line it opens on,
    // so the strict style is written until a pass changes nothing.
    var text = src;
    var round: usize = 0;
    while (true) : (round += 1) {
        const r = try formatOnce(gpa, arena, text, opts);
        switch (r) {
            .fail => return if (round == 0) r else .{ .ok = text },
            .ok => |out| {
                if (std.mem.eql(u8, out, text) or round == 3) return r;
                text = out;
            },
        }
    }
}

fn formatOnce(gpa: Allocator, arena: Allocator, src: []const u8, opts: Options) Error!Outcome {
    if (src.len > 0 and src[0] == 0x1b) return .{ .fail = "cannot format binary chunk" };

    var lx = lexer.Lexer.init(gpa, arena, src);
    defer lx.deinit();
    const lexed = lx.run() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            const d = lx.diag.?;
            return .{ .fail = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ parser.chunkDisplay(arena, opts.chunkname), d.line, d.message }) };
        },
    };
    var partial: parser.Partial = .{};
    const chunk = parser.parseLexed(arena, src, lexed, .{ .chunkname = opts.chunkname }, false, &partial) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return .{ .fail = partial.diag.?.message },
    };
    if (opts.checker) |c| {
        if (try c.check(c.ctx, arena, chunk, opts.chunkname)) |msg| {
            // Raw bytes in a string literal (a limit of the runtime's
            // string type) and constructs the compiler does not generate
            // yet are not errors of the source.
            if (std.mem.indexOf(u8, msg, "invalid UTF-8 in string literal") == null and
                std.mem.indexOf(u8, msg, "not supported yet") == null)
            {
                return .{ .fail = msg };
            }
        }
    }

    var f = try Formatter.init(arena, src, lexed, if (opts.indent_width > 0) opts.indent_width else 4);
    f.strict = opts.strict;
    // A shebang line is not part of the token stream. Keep it verbatim.
    if (src.len > 0 and src[0] == '#') {
        const end = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
        try f.out.appendSlice(arena, std.mem.trimEnd(u8, src[0..end], "\r"));
        try f.nl();
    }
    try f.chunk(chunk.block.stats);

    // Trim trailing whitespace and end with exactly one newline.
    var n = f.out.items.len;
    while (n > 0 and (f.out.items[n - 1] == ' ' or f.out.items[n - 1] == '\n' or f.out.items[n - 1] == '\r')) n -= 1;
    f.out.items.len = n;
    try f.out.append(arena, '\n');
    return .{ .ok = f.out.items };
}

// ---------------------------------------------------------------------
// Formatter state

const Formatter = struct {
    arena: Allocator,
    src: []const u8,
    toks: []Token,
    payloads: []lexer.Payload,
    comments: []lexer.Comment,
    /// Byte offset where each line starts. Line 1 starts at 0.
    line_starts: []u32,
    /// The quote character the reference lexer last saw when each token
    /// was read, or 0. A long string literal has no quote of its own and
    /// is requoted with the quote of the last short string before it.
    quotes: []u8,
    out: std.ArrayList(u8) = .empty,
    indent: u32 = 0,
    width: u32,
    /// Index of the next comment to emit.
    next_comment: usize = 0,
    /// Writes the strict style (`Options.strict`).
    strict: bool = false,
    /// Above zero while an enclosing construct tries one line, during
    /// which the constructs inside it stay on one line too.
    flat: u32 = 0,
    /// The columns that follow on the current line once the construct
    /// being written ends, such as ` then` after a condition.
    reserve: u32 = 0,

    fn init(arena: Allocator, src: []const u8, lexed: lexer.Result, width: u32) Error!Formatter {
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
        const quotes = try arena.alloc(u8, lexed.tokens.len);
        var q: u8 = 0;
        for (lexed.tokens, 0..) |t, k| {
            if (t.tag == .string and t.span.start < src.len) {
                const c = src[t.span.start];
                if (c == '"' or c == '\'') q = c;
            }
            quotes[k] = q;
        }
        return .{
            .arena = arena,
            .src = src,
            .toks = lexed.tokens,
            .payloads = lexed.payloads,
            .comments = lexed.comments,
            .line_starts = starts.items,
            .quotes = quotes,
            .width = width,
        };
    }

    // -----------------------------------------------------------------
    // Positions

    fn lineOf(f: *const Formatter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = f.line_starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (f.line_starts[mid] <= off) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    /// Index of the token starting at `off` (or the first one after it).
    fn tokAt(f: *const Formatter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = f.toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (f.toks[mid].span.start < off) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, f.toks.len - 1));
    }

    /// Index of the last token starting before `off`.
    fn tokEnd(f: *const Formatter, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = f.toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (f.toks[mid].span.start < off) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else @intCast(lo - 1);
    }

    /// The line the reference lexer reports while token `k` is current:
    /// the line where the token ends.
    fn tokLine(f: *const Formatter, k: u32) u32 {
        return f.lineOf(f.toks[k].span.end);
    }

    /// Line of the first token at or after `off`.
    fn startLine(f: *const Formatter, off: u32) u32 {
        return f.tokLine(f.tokAt(off));
    }

    /// Line of the last token before `off`.
    fn endLine(f: *const Formatter, off: u32) u32 {
        return f.tokLine(f.tokEnd(off));
    }

    // -----------------------------------------------------------------
    // Output

    fn put(f: *Formatter, s: []const u8) Error!void {
        try f.out.appendSlice(f.arena, s);
    }

    fn putc(f: *Formatter, c: u8) Error!void {
        try f.out.append(f.arena, c);
    }

    fn nl(f: *Formatter) Error!void {
        try f.out.append(f.arena, '\n');
    }

    fn emitIndent(f: *Formatter) Error!void {
        try f.out.appendNTimes(f.arena, ' ', f.indent * f.width);
    }

    /// A point of the output to come back to when a layout does not fit.
    const Mark = struct { len: usize, comment: usize };

    fn mark(f: *const Formatter) Mark {
        return .{ .len = f.out.items.len, .comment = f.next_comment };
    }

    fn reset(f: *Formatter, m: Mark) void {
        f.out.items.len = m.len;
        f.next_comment = m.comment;
    }

    /// The columns of `text`, one per character.
    fn columns(text: []const u8) usize {
        var n: usize = 0;
        for (text) |c| {
            if (c & 0xc0 != 0x80) n += 1;
        }
        return n;
    }

    /// The columns of the last line of the output.
    fn column(f: *const Formatter) usize {
        const items = f.out.items;
        const start = if (std.mem.lastIndexOfScalar(u8, items, '\n')) |i| i + 1 else 0;
        return columns(items[start..]);
    }

    /// Whether the line of the output that holds `pos` fits from its start
    /// to its end, or to the end of the output.
    fn lineFits(f: *const Formatter, pos: usize) bool {
        const items = f.out.items;
        const start = if (std.mem.lastIndexOfScalar(u8, items[0..pos], '\n')) |i| i + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, items, pos, '\n') orelse items.len;
        return columns(items[start..end]) <= strict_rules.max_width;
    }

    /// Whether the text written since `m` keeps its first and its last
    /// line within the limit.
    fn fitsSince(f: *const Formatter, m: Mark) bool {
        if (!f.lineFits(m.len)) return false;
        const items = f.out.items;
        const start = if (std.mem.lastIndexOfScalar(u8, items, '\n')) |i| i + 1 else 0;
        return columns(items[start..]) + f.reserve <= strict_rules.max_width;
    }

    /// Whether the text written since `m` is one line.
    fn flatSince(f: *const Formatter, m: Mark) bool {
        return std.mem.indexOfScalar(u8, f.out.items[m.len..], '\n') == null;
    }

    /// Arguments in parentheses. In the strict style, arguments that do
    /// not fit on the line of the call go one per line.
    fn args(f: *Formatter, es: []*ast.Expr) Error!void {
        const m = f.mark();
        const trying = f.strict and f.flat == 0 and es.len > 0;
        if (trying) f.flat += 1;
        try f.putc('(');
        try f.exprList(es);
        try f.putc(')');
        if (trying) f.flat -= 1;
        if (!trying or f.fitsSince(m)) return;
        f.reset(m);
        // A last argument that is a table or a function opens on the line
        // of the call and takes the lines it needs, when the line fits.
        const last = strip(es[es.len - 1]).e;
        if (last.kind == .table or last.kind == .function) {
            f.flat += 1;
            try f.putc('(');
            for (es[0 .. es.len - 1]) |e| {
                try f.expr(e);
                try f.put(", ");
            }
            f.flat -= 1;
            try f.expr(es[es.len - 1]);
            try f.putc(')');
            if (f.fitsSince(m)) return;
            f.reset(m);
        }
        try f.putc('(');
        try f.nl();
        f.indent += 1;
        const reserve = f.reserve;
        defer f.reserve = reserve;
        for (es, 0..) |e, i| {
            try f.emitIndent();
            f.reserve = if (i + 1 < es.len) 1 else 0;
            try f.expr(e);
            if (i + 1 < es.len) try f.putc(',');
            try f.nl();
        }
        f.indent -= 1;
        try f.emitIndent();
        try f.putc(')');
    }

    // -----------------------------------------------------------------
    // Comments

    fn commentLine(f: *const Formatter, c: lexer.Comment) u32 {
        return f.lineOf(c.span.start);
    }

    fn commentEndLine(f: *const Formatter, c: lexer.Comment) u32 {
        return f.lineOf(c.span.end);
    }

    /// A short comment gets a space after `--` when its text starts with a
    /// letter or a digit. Text that starts with punctuation is a marker,
    /// such as the `-->` of an expected output, and stays as written.
    fn shortCommentText(f: *Formatter, text: []const u8) Error!void {
        try f.put("--");
        if (text.len > 0 and (std.ascii.isAlphanumeric(text[0]) or text[0] >= 0x80)) try f.putc(' ');
        try f.put(text);
    }

    /// Emits the comments that start before `line` (all of them when
    /// `line` is null). Returns the end line of the last one, or 0.
    fn commentsBefore(f: *Formatter, line: ?u32) Error!u32 {
        var last_end: u32 = 0;
        while (f.next_comment < f.comments.len) {
            const c = f.comments[f.next_comment];
            const cl = f.commentLine(c);
            if (line) |l| {
                if (cl >= l) break;
            }
            // Keep a gap between consecutive comments.
            if (last_end > 0 and cl > last_end + 1) try f.nl();
            try f.emitIndent();
            if (c.long) {
                // A long comment keeps its source text, brackets and
                // layout included, with line breaks written as LF.
                const raw = f.src[c.span.start..c.span.end];
                var rest = raw;
                while (std.mem.indexOfScalar(u8, rest, '\r')) |i| {
                    try f.put(rest[0..i]);
                    if (i + 1 >= rest.len or rest[i + 1] != '\n') try f.putc('\n');
                    rest = rest[i + 1 ..];
                }
                try f.put(rest);
            } else {
                try f.shortCommentText(c.text);
            }
            try f.nl();
            last_end = f.commentEndLine(c);
            f.next_comment += 1;
        }
        return last_end;
    }

    /// Emits a short comment that sits on `line` after code.
    fn trailingComment(f: *Formatter, line: u32) Error!void {
        if (f.next_comment >= f.comments.len) return;
        const c = f.comments[f.next_comment];
        if (c.long or f.commentLine(c) != line) return;
        try f.put("  ");
        try f.shortCommentText(c.text);
        f.next_comment += 1;
    }

    // -----------------------------------------------------------------
    // Blocks and statements

    fn chunk(f: *Formatter, stats: []*ast.Stat) Error!void {
        try f.statements(stats);
        _ = try f.commentsBefore(null);
    }

    /// A list of statements. One blank line separates two statements, or
    /// a statement and the comments before the next one, wherever the
    /// source has at least one.
    fn statements(f: *Formatter, stats: []*ast.Stat) Error!void {
        var prev_end: u32 = 0;
        var prev_block = false;
        var first = true;
        for (stats) |s| {
            if (s.kind == .empty) continue;
            const line = f.startLine(s.span.start);
            // A statement starts at its first preceding comment.
            var effective = line;
            if (f.next_comment < f.comments.len) {
                const cl = f.commentLine(f.comments[f.next_comment]);
                if (cl < line) effective = cl;
            }
            const blank = prev_end > 0 and effective > prev_end + 1;
            if (blank) try f.nl();
            prev_end = f.endLine(s.span.end);
            const at = f.out.items.len;
            try f.stat(s);
            if (f.strict) {
                // A blank line separates a block that spans several lines
                // from the statements around it in its scope.
                const is_block = try holdsBlock(f.arena, s);
                if (!first and !blank and (is_block or prev_block)) try f.out.insert(f.arena, at, '\n');
                prev_block = is_block;
            }
            first = false;
        }
    }

    /// Whether `s` is a control structure or a function, or holds a
    /// function or a do-expression, which the formatter always writes on
    /// several lines.
    fn holdsBlock(arena: Allocator, s: *ast.Stat) Error!bool {
        switch (s.kind) {
            .do_, .while_, .repeat_, .if_, .numeric_for, .generic_for, .local_function, .global_function, .function => return true,
            .empty, .break_, .continue_, .goto_, .label, .recovered => return false,
            else => {},
        }
        const Finder = struct {
            found: bool = false,
            fn visit(fd: *@This(), slot: **ast.Expr) anyerror!void {
                switch (slot.*.kind) {
                    .function, .do_ => fd.found = true,
                    else => {},
                }
            }
        };
        var fd: Finder = .{};
        const v: walk.Visitor(*Finder) = .{ .ctx = &fd, .func = Finder.visit };
        v.stat(s) catch return error.OutOfMemory;
        _ = arena;
        return fd.found;
    }

    /// The statements of `b`, one level in, then the comments that come
    /// after the last statement and before the token that closes the block.
    fn block(f: *Formatter, b: anytype) Error!void {
        // The statements of a block lay out on lines of their own, whatever
        // the line of the construct that holds the block tries.
        const flat = f.flat;
        const reserve = f.reserve;
        f.flat = 0;
        f.reserve = 0;
        defer {
            f.flat = flat;
            f.reserve = reserve;
        }
        f.indent += 1;
        try f.statements(b.stats);
        _ = try f.commentsBefore(b.end_line);
        f.indent -= 1;
    }

    fn stat(f: *Formatter, s: *ast.Stat) Error!void {
        if (s.kind == .empty) return;
        const line = f.startLine(s.span.start);
        const comment_end = try f.commentsBefore(line);
        if (comment_end > 0 and line > comment_end + 1) try f.nl();
        try f.emitIndent();

        switch (s.kind) {
            .empty => unreachable,
            .recovered => |msg| {
                try f.put("-- [FORMAT ERROR: ");
                try f.put(msg);
                try f.putc(']');
            },
            .expr => |e| switch (e.kind) {
                // A call statement always takes parenthesized arguments.
                .call => |c| {
                    try f.expr(c.callee);
                    try f.args(c.args);
                },
                .method => |m| try f.methodCall(m.obj, m.name, m.args),
                else => try f.expr(e),
            },
            .local => |l| {
                try f.put("local ");
                try f.attNames(l.names);
                if (l.values.len > 0) {
                    try f.put(" = ");
                    try f.exprList(l.values);
                }
            },
            .local_from => |l| {
                try f.put("local ");
                try f.attNames(l.names);
                try f.put(" from ");
                try f.expr(l.source);
            },
            .local_group => |l| {
                try f.put("local ");
                try f.attNames(l.names);
                try f.put(" = ");
                try f.groupInits(l.inits);
            },
            .local_function => |lf| {
                try f.put("local function ");
                try f.put(lf.name.text);
                try f.funcBody(lf.func, line);
            },
            .global => |g| {
                try f.put("global ");
                try f.defaultAttribs(g.default_attribs);
                if (g.star) {
                    try f.putc('*');
                } else {
                    try f.attNames(g.names);
                    if (g.values) |vals| {
                        try f.put(" = ");
                        try f.exprList(vals);
                    }
                }
            },
            .global_from => |g| {
                try f.put("global ");
                try f.defaultAttribs(g.default_attribs);
                try f.attNames(g.names);
                try f.put(" from ");
                try f.expr(g.source);
            },
            .global_function => |gf| {
                try f.put("global function ");
                try f.put(gf.name.text);
                try f.funcBody(gf.func, line);
            },
            .assign => |a| {
                try f.exprList(a.targets);
                try f.put(" = ");
                try f.exprList(a.values);
            },
            .assign_from => |a| {
                try f.exprList(a.targets);
                try f.put(" from ");
                try f.expr(a.source);
            },
            .function => |fs| {
                try f.put("function ");
                for (fs.path, 0..) |seg, i| {
                    if (i > 0) try f.putc('.');
                    try f.put(seg.text);
                }
                if (fs.method) |m| {
                    try f.putc(':');
                    try f.put(m.text);
                }
                try f.funcBody(fs.func, line);
            },
            .do_ => |b| {
                try f.put("do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(b);
                try f.emitIndent();
                try f.put("end");
            },
            .while_ => |w| {
                try f.put("while ");
                f.reserve = 3;
                try f.cond(w.cond);
                f.reserve = 0;
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(w.body);
                try f.emitIndent();
                try f.put("end");
            },
            .repeat_ => |r| {
                try f.put("repeat");
                try f.trailingComment(line);
                try f.nl();
                try f.block(r.body);
                try f.emitIndent();
                try f.put("until ");
                try f.expr(r.cond);
            },
            .if_ => |ifs| {
                for (ifs.clauses, 0..) |cl, i| {
                    var cl_line = line;
                    if (i == 0) {
                        try f.put("if ");
                    } else {
                        const kw = f.tokAt(condStart(cl.cond)) - 1;
                        cl_line = f.tokLine(kw);
                        try f.emitIndent();
                        try f.put("elseif ");
                    }
                    f.reserve = 5;
                    try f.cond(cl.cond);
                    f.reserve = 0;
                    try f.put(" then");
                    try f.trailingComment(cl_line);
                    try f.nl();
                    try f.block(cl.body);
                }
                if (ifs.else_) |b| {
                    const kw = f.tokAt(b.span.start) - 1;
                    try f.emitIndent();
                    try f.put("else");
                    try f.trailingComment(f.tokLine(kw));
                    try f.nl();
                    try f.block(b);
                }
                try f.emitIndent();
                try f.put("end");
            },
            .numeric_for => |nf| {
                try f.put("for ");
                try f.put(nf.name.text);
                try f.put(" = ");
                f.reserve = 3;
                try f.expr(nf.start);
                try f.put(", ");
                try f.expr(nf.limit);
                if (nf.step) |st| {
                    try f.put(", ");
                    try f.expr(st);
                }
                f.reserve = 0;
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(nf.body);
                try f.emitIndent();
                try f.put("end");
            },
            .generic_for => |gf| {
                try f.put("for ");
                for (gf.names, 0..) |nm, i| {
                    if (i > 0) try f.put(", ");
                    try f.put(nm.text);
                }
                try f.put(if (gf.from) " from " else " in ");
                f.reserve = 3;
                try f.exprList(gf.exprs);
                f.reserve = 0;
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(gf.body);
                try f.emitIndent();
                try f.put("end");
            },
            .return_ => |vals| {
                try f.put("return");
                if (vals.len > 0) {
                    try f.putc(' ');
                    try f.exprList(vals);
                }
            },
            .provide => |vals| {
                try f.put("provide");
                if (vals.len > 0) {
                    try f.putc(' ');
                    try f.exprList(vals);
                }
            },
            .break_ => try f.put("break"),
            .continue_ => try f.put("continue"),
            .goto_ => |g| {
                try f.put("goto ");
                try f.put(g.text);
            },
            .label => |lb| {
                try f.put("::");
                try f.put(lb.text);
                try f.put("::");
            },
            .catch_ => |c| try f.catchExpr(c),
        }

        try f.trailingComment(f.endLine(s.span.end));
        try f.nl();
    }

    fn condStart(c: ast.Cond) u32 {
        return switch (c) {
            .expr => |e| e.span.start,
            .assign => |a| a.names[0].name.span.start,
            .from => |a| a.names[0].name.span.start,
            .group => |a| a.names[0].name.span.start,
        };
    }

    fn cond(f: *Formatter, c: ast.Cond) Error!void {
        switch (c) {
            .expr => |e| try f.expr(e),
            .assign => |a| {
                try f.attNames(a.names);
                try f.put(" = ");
                try f.exprList(a.values);
            },
            .from => |a| {
                try f.attNames(a.names);
                try f.put(" from ");
                try f.expr(a.source);
            },
            .group => |g| {
                try f.attNames(g.names);
                try f.put(" = ");
                try f.groupInits(g.inits);
            },
        }
    }

    /// Declared names, each followed by its attributes in one `< >` list:
    /// the attributes the language names first, in source order, then the
    /// runtime ones.
    fn attNames(f: *Formatter, names: []ast.AttName) Error!void {
        var wrapped = false;
        defer if (wrapped) {
            f.indent -= 1;
        };
        for (names, 0..) |an, i| {
            if (i > 0) {
                // In the strict style a list of names fills its lines and
                // goes on one level in.
                if (f.strict and f.column() + 2 + an.name.text.len + 1 > strict_rules.max_width) {
                    try f.putc(',');
                    try f.nl();
                    if (!wrapped) f.indent += 1;
                    wrapped = true;
                    try f.emitIndent();
                } else {
                    try f.put(", ");
                }
            }
            try f.put(an.name.text);
            try f.attribList(an.attribs, true);
        }
    }

    fn attribList(f: *Formatter, attribs: []ast.Attrib, leading_space: bool) Error!void {
        if (attribs.len == 0) return;
        if (leading_space) try f.putc(' ');
        try f.putc('<');
        var first = true;
        for (attribs) |a| {
            const word: ?[]const u8 = switch (a) {
                .@"const" => "const",
                .close => "close",
                .group => "group",
                .meta => "meta",
                .lazy => "lazy",
                .observe => "observe",
                .context => "context",
                .runtime => null,
            };
            if (word) |w| {
                if (!first) try f.put(", ");
                try f.put(w);
                first = false;
            }
        }
        for (attribs) |a| switch (a) {
            .runtime => |e| {
                if (!first) try f.put(", ");
                first = false;
                try f.expr(e);
            },
            else => {},
        };
        try f.putc('>');
    }

    fn defaultAttribs(f: *Formatter, attribs: []ast.Attrib) Error!void {
        if (attribs.len == 0) return;
        try f.attribList(attribs, false);
        try f.putc(' ');
    }

    fn groupInits(f: *Formatter, inits: []ast.GroupInit) Error!void {
        for (inits, 0..) |gi, i| {
            if (i > 0) try f.put(", ");
            switch (gi) {
                .ctor => |fields| try f.groupCtor(fields),
                .copy => |n| try f.put(n.text),
            }
        }
    }

    /// A group constructor, laid out like a table.
    fn groupCtor(f: *Formatter, fields: []ast.GroupField) Error!void {
        if (fields.len == 0) return f.put("{}");
        const multiline = fields.len > 3;
        if (multiline) {
            try f.putc('{');
            try f.nl();
            f.indent += 1;
        } else {
            try f.put("{ ");
        }
        for (fields, 0..) |fld, i| {
            if (multiline) {
                try f.emitIndent();
            } else if (i > 0) {
                try f.put(", ");
            }
            try f.put(fld.name.name.text);
            try f.attribList(fld.name.attribs, true);
            try f.put(" = ");
            switch (fld.value) {
                .expr => |e| try f.expr(e),
                .group => |sub| try f.groupCtor(sub),
            }
            if (multiline) {
                try f.putc(',');
                try f.nl();
            }
        }
        if (multiline) {
            f.indent -= 1;
            try f.emitIndent();
            try f.putc('}');
        } else {
            try f.put(" }");
        }
    }

    /// Parameters, header comment, body, and `end` of a function. The
    /// caller has written everything up to the parameter list. `line` is
    /// the line of the node that owns the function.
    fn funcBody(f: *Formatter, func: *ast.Function, line: u32) Error!void {
        const m = f.mark();
        try f.params(func, false);
        if (f.strict and !f.fitsSince(m)) {
            f.reset(m);
            try f.params(func, true);
        }
        try f.trailingComment(line);
        try f.nl();
        try f.block(func.body);
        try f.emitIndent();
        try f.put("end");
    }

    /// The parameter list of a function, one parameter per line when
    /// `broken`.
    fn params(f: *Formatter, func: *ast.Function, broken: bool) Error!void {
        try f.putc('(');
        if (broken) {
            try f.nl();
            f.indent += 1;
        }
        const count = func.params.len + @intFromBool(func.vararg_name != null or func.is_vararg);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (broken) {
                try f.emitIndent();
            } else if (i > 0) {
                try f.put(", ");
            }
            if (i < func.params.len) {
                try f.put(func.params[i].text);
            } else {
                try f.put("...");
                if (func.vararg_name) |vn| try f.put(vn.text);
            }
            if (broken) {
                if (i + 1 < count) try f.putc(',');
                try f.nl();
            }
        }
        if (broken) {
            f.indent -= 1;
            try f.emitIndent();
        }
        try f.putc(')');
    }

    // -----------------------------------------------------------------
    // Expressions

    const Stripped = struct { e: *ast.Expr, paren: bool };

    /// Removes the parentheses around an expression. The reference keeps
    /// one flag for any number of them.
    fn strip(e: *ast.Expr) Stripped {
        var cur = e;
        var paren = false;
        while (cur.kind == .paren) {
            cur = cur.kind.paren;
            paren = true;
        }
        return .{ .e = cur, .paren = paren };
    }

    fn exprList(f: *Formatter, es: []*ast.Expr) Error!void {
        for (es, 0..) |e, i| {
            if (i > 0) try f.put(", ");
            try f.expr(e);
        }
    }

    fn expr(f: *Formatter, e0: *ast.Expr) Error!void {
        const st = strip(e0);
        const e = st.e;
        if (st.paren) try f.putc('(');
        switch (e.kind) {
            .paren => unreachable,
            .nil => try f.put("nil"),
            .true => try f.put("true"),
            .false => try f.put("false"),
            .vararg => try f.put("..."),
            .integer => |v| if (f.numeralSource(e)) |src| try f.put(src) else try f.integer(v),
            .float => |v| if (f.numeralSource(e)) |src| try f.put(src) else try f.float(v),
            .bigint => |d| if (f.numeralSource(e)) |src| try f.put(src) else {
                try f.put(d);
                try f.putc('n');
            },
            .decimal => |d| if (f.numeralSource(e)) |src| try f.put(src) else {
                try f.put(d);
                try f.putc('d');
            },
            .string => |s| {
                const k = f.tokAt(e.span.start);
                const double = if (f.strict and e.span.end <= f.src.len) try strict_rules.doubleQuoted(f.arena, f.src[e.span.start..e.span.end]) else null;
                if (double) |text| {
                    try f.put(text);
                } else if (f.literalSource(k, e.span.end)) |src| {
                    try f.put(src);
                } else if (f.toks[k].tag == .interp_simple) {
                    try f.putc('`');
                    try f.interpText(s);
                    try f.putc('`');
                } else {
                    try f.stringLit(s, f.quotes[k]);
                }
            },
            .interp => |parts| try f.interp(parts, e.span.start),
            .function => |func| {
                try f.put("function");
                try f.funcBody(func, f.startLine(e.span.start));
            },
            .table => |fields| try f.table(fields, e.span),
            .binop => |b| try f.binop(b.op, b.lhs, b.rhs),
            .unop => |u| try f.unop(u.op, u.operand),
            .name => |n| try f.put(n.text),
            .index => |ix| {
                try f.expr(ix.obj);
                if (ix.dot) {
                    try f.putc('.');
                    try f.put(ix.key.kind.string);
                } else {
                    try f.putc('[');
                    try f.expr(ix.key);
                    try f.putc(']');
                }
            },
            .call => |c| {
                try f.expr(c.callee);
                switch (c.args_kind) {
                    .string => {
                        try f.putc(' ');
                        try f.expr(c.args[0]);
                    },
                    .table => try f.expr(c.args[0]),
                    .parens => {
                        try f.args(c.args);
                    },
                }
            },
            .method => |m| try f.methodCall(m.obj, m.name, m.args),
            .slice => |sl| {
                try f.expr(sl.obj);
                try f.putc('[');
                if (sl.from) |x| try f.expr(x);
                try f.putc(',');
                if (sl.to) |x| {
                    try f.putc(' ');
                    try f.expr(x);
                }
                try f.putc(']');
            },
            .optional => |inner| {
                try f.expr(inner);
                try f.putc('?');
            },
            .chain => |inner| try f.expr(inner),
            .catch_ => |c| try f.catchExpr(c),
            .do_ => |b| {
                try f.put("do");
                try f.trailingComment(f.startLine(e.span.start));
                try f.nl();
                try f.block(b);
                try f.emitIndent();
                try f.put("end");
            },
            .enum_ => |names| {
                try f.put("enum ");
                for (names, 0..) |n, i| {
                    if (i > 0) try f.put(", ");
                    try f.put(n.text);
                }
                try f.put(" end");
            },
            .query => |q| try f.query(q),
        }
        if (st.paren) try f.putc(')');
    }

    fn methodCall(f: *Formatter, obj: *ast.Expr, name: ast.Name, arg_list: []*ast.Expr) Error!void {
        try f.expr(obj);
        try f.putc(':');
        try f.put(name.text);
        try f.args(arg_list);
    }

    fn catchExpr(f: *Formatter, c: ast.Catch) Error!void {
        try f.put("catch");
        if (c.handler) |h| {
            try f.putc('[');
            try f.expr(h);
            try f.putc(']');
        }
        try f.putc(' ');
        try f.expr(c.body);
    }

    /// The numeral as the source writes it, so hexadecimal, digit
    /// separators, and exponents stay as written. Null for a number that
    /// has no numeral of its own in the source.
    fn numeralSource(f: *const Formatter, e: *ast.Expr) ?[]const u8 {
        if (e.span.end <= e.span.start or e.span.end > f.src.len) return null;
        const text = f.src[e.span.start..e.span.end];
        if (!std.ascii.isDigit(text[0]) and text[0] != '.') return null;
        for (text) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '+' and c != '-') return null;
        }
        return text;
    }

    fn integer(f: *Formatter, v: i64) Error!void {
        var buf: [24]u8 = undefined;
        // A literal is never negative in the source. A negative value comes
        // from a hexadecimal literal that wrapped around, and is written
        // back in hexadecimal so that it stays one literal.
        if (v < 0) return f.put(std.fmt.bufPrint(&buf, "0x{x}", .{@as(u64, @bitCast(v))}) catch unreachable);
        try f.put(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }

    fn float(f: *Formatter, v: f64) Error!void {
        // An overflowing literal reads as infinity, which has no spelling
        // of its own.
        if (std.math.isInf(v)) return f.put(if (v > 0) "1e999" else "-1e999");
        // The reference spelling: "%.15g", or "%.17g" when 15 digits do
        // not read back as the same value, and a ".0" when the result
        // looks like an integer.
        const start = f.out.items.len;
        ops.formatG(f.arena, &f.out, v, 15) catch return error.OutOfMemory;
        const back = std.fmt.parseFloat(f64, f.out.items[start..]) catch v;
        if (back != v) {
            f.out.items.len = start;
            ops.formatG(f.arena, &f.out, v, 17) catch return error.OutOfMemory;
        }
        const s = f.out.items[start..];
        if (std.mem.indexOfNone(u8, s, "-0123456789") == null) try f.put(".0");
    }

    fn stringLit(f: *Formatter, s: []const u8, quote: u8) Error!void {
        const q: u8 = if (quote == '\'' or quote == '"') quote else blk: {
            const dq = std.mem.indexOfScalar(u8, s, '"') != null;
            const sq = std.mem.indexOfScalar(u8, s, '\'') != null;
            break :blk if (dq and !sq) '\'' else '"';
        };
        try f.putc(q);
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '\\' => try f.put("\\\\"),
                '\n' => try f.put("\\n"),
                '\r' => try f.put("\\r"),
                '\t' => try f.put("\\t"),
                // A digit after `\0` would extend the escape.
                0 => try f.put(if (i + 1 < s.len and std.ascii.isDigit(s[i + 1])) "\\x00" else "\\0"),
                else => {
                    if (c == q) {
                        try f.putc('\\');
                        try f.putc(q);
                    } else if (c < 32) {
                        try f.hexByte(c);
                    } else if (c < 0x80) {
                        try f.putc(c);
                    } else if (wtf8.decodeAt(s, i)) |d| {
                        try f.put(s[i .. i + d.len]);
                        i += d.len;
                        continue;
                    } else {
                        // A byte outside any UTF-8 sequence is escaped,
                        // so that the output stays valid text.
                        try f.hexByte(c);
                    }
                },
            }
            i += 1;
        }
        try f.putc(q);
    }

    fn hexByte(f: *Formatter, c: u8) Error!void {
        var buf: [4]u8 = undefined;
        try f.put(std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable);
    }

    /// Literal text of an interpolated string, with `$`, the backtick, and
    /// the backslash escaped. A carriage return is written as `\r`,
    /// because a raw one would read back as a line break. Other control
    /// characters and bytes outside any UTF-8 sequence are written as
    /// `\xXX`, which backtick strings accept like quoted strings.
    fn interpText(f: *Formatter, s: []const u8) Error!void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '$' => try f.put("$$"),
                '`' => try f.put("\\`"),
                '\\' => try f.put("\\\\"),
                '\r' => try f.put("\\r"),
                '\n', '\t' => try f.putc(c),
                else => {
                    if (c < 32 or c == 0x7f) {
                        try f.hexByte(c);
                    } else if (c < 0x80) {
                        try f.putc(c);
                    } else if (wtf8.decodeAt(s, i)) |d| {
                        try f.put(s[i .. i + d.len]);
                        i += d.len;
                        continue;
                    } else try f.hexByte(c);
                },
            }
            i += 1;
        }
    }

    /// The source text of the string literal token `k`, when the literal
    /// is that one token and ends at `end`.
    fn literalSource(f: *Formatter, k: usize, end: u32) ?[]const u8 {
        const t = f.toks[k];
        if (t.tag != .string and t.tag != .interp_simple) return null;
        if (t.span.end != end or t.span.end > f.src.len) return null;
        return f.src[t.span.start..t.span.end];
    }

    /// The source text of the literal sections of the interpolated string
    /// that starts at token `k`, without the backticks and the `$(` or `$`
    /// that end a section. Sections inside a nested interpolated string
    /// belong to that string, and empty sections are left out, as the
    /// parser leaves out their parts.
    fn interpSections(f: *Formatter, k: usize) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var level: usize = 0;
        var i = k;
        while (i < f.toks.len) : (i += 1) {
            const t = f.toks[i];
            switch (t.tag) {
                .interp_begin, .interp_mid, .interp_end => {},
                .eof => break,
                else => continue,
            }
            if (t.tag == .interp_begin) level += 1;
            if (level == 1) {
                var a = t.span.start;
                var b = t.span.end;
                if (t.tag == .interp_begin and i == k) a += 1;
                if (t.tag == .interp_end) {
                    b -= 1;
                } else if (b >= 2 and f.src[b - 2] == '$' and f.src[b - 1] == '(') {
                    b -= 2;
                } else {
                    b -= 1;
                }
                if (b > a) try out.append(f.arena, f.src[a..b]);
            }
            if (t.tag == .interp_end) {
                level -= 1;
                if (level == 0) break;
            }
        }
        return out.items;
    }

    fn interp(f: *Formatter, parts: []ast.InterpPart, start: u32) Error!void {
        const sections = try f.interpSections(f.tokAt(start));
        var text_count: usize = 0;
        for (parts) |p| {
            if (p == .text) text_count += 1;
        }
        const raw = sections.len == text_count;
        var next_section: usize = 0;
        try f.putc('`');
        for (parts, 0..) |p, i| switch (p) {
            .text => |s| {
                if (raw) {
                    try f.put(sections[next_section]);
                    next_section += 1;
                } else try f.interpText(s);
            },
            .expr => |e| {
                // A bare name is written `$name`, unless the text after it
                // would continue the name.
                const next_continues = i + 1 < parts.len and parts[i + 1] == .text and
                    parts[i + 1].text.len > 0 and isNameChar(parts[i + 1].text[0]);
                if (e.kind == .name and !next_continues) {
                    try f.putc('$');
                    try f.put(e.kind.name.text);
                } else {
                    try f.put("$(");
                    try f.expr(e);
                    try f.putc(')');
                }
            },
        };
        try f.putc('`');
    }

    fn fieldStart(fld: ast.Field) u32 {
        return switch (fld.kind) {
            .positional => |v| v.span.start,
            .named => |nv| nv.name.span.start,
            .keyed => |kv| kv.key.span.start,
        };
    }

    fn holdsFunction(fields: []ast.Field) bool {
        for (fields) |fld| {
            const v = switch (fld.kind) {
                .positional => |v| v,
                .named => |nv| nv.value,
                .keyed => |kv| kv.value,
            };
            if (strip(v).e.kind == .function) return true;
        }
        return false;
    }

    fn fieldEnd(fld: ast.Field) u32 {
        return switch (fld.kind) {
            .positional => |v| v.span.end,
            .named => |nv| nv.value.span.end,
            .keyed => |kv| kv.value.span.end,
        };
    }

    /// A table constructor. Tables with more than three fields, tables
    /// that hold a comment, and tables with a function as a value go one
    /// field per line with a trailing comma. Each comment stays next to the
    /// field it was written by.
    /// A table on one line.
    fn tableFlat(f: *Formatter, fields: []ast.Field) Error!void {
        try f.put("{ ");
        for (fields, 0..) |fld, i| {
            if (i > 0) try f.put(", ");
            try f.field(fld);
        }
        try f.put(" }");
    }

    fn field(f: *Formatter, fld: ast.Field) Error!void {
        switch (fld.kind) {
            .positional => |v| try f.expr(v),
            .named => |nv| {
                try f.put(nv.name.text);
                try f.put(" = ");
                try f.expr(nv.value);
            },
            .keyed => |kv| {
                try f.tableKey(kv.key);
                try f.put(" = ");
                try f.expr(kv.value);
            },
        }
    }

    fn table(f: *Formatter, fields: []ast.Field, span: ast.Span) Error!void {
        if (fields.len == 0) return f.put("{}");
        const close_line = f.endLine(span.end);
        // Only a comment before the closing brace is inside the table. A
        // comment after it on the same line belongs to the statement.
        const has_comment = f.next_comment < f.comments.len and f.comments[f.next_comment].span.start < span.end;
        var multiline = fields.len > 3 or has_comment or holdsFunction(fields);
        if (f.strict) {
            // A table that its source opens on a line of its own stays on
            // several lines, and any other goes on one line if it fits.
            const broken = f.startLine(span.start) != f.startLine(fieldStart(fields[0]));
            multiline = has_comment or holdsFunction(fields) or broken;
            if (!multiline and f.flat > 0) return f.tableFlat(fields);
            if (!multiline) {
                const m = f.mark();
                f.flat += 1;
                try f.tableFlat(fields);
                f.flat -= 1;
                if (f.flatSince(m) and f.fitsSince(m)) return;
                f.reset(m);
                multiline = true;
            }
        }
        const flat = f.flat;
        defer f.flat = flat;
        if (multiline) {
            // The fields of a table on several lines lay out on lines of
            // their own.
            f.flat = 0;
            try f.putc('{');
            try f.trailingComment(f.startLine(span.start));
            try f.nl();
            f.indent += 1;
        } else {
            try f.put("{ ");
        }
        for (fields, 0..) |fld, i| {
            if (multiline) {
                _ = try f.commentsBefore(f.startLine(fieldStart(fld)));
                try f.emitIndent();
            } else if (i > 0) {
                try f.put(", ");
            }
            const reserve = f.reserve;
            if (multiline) f.reserve = 1;
            try f.field(fld);
            f.reserve = reserve;
            if (multiline) {
                try f.putc(',');
                try f.trailingComment(f.endLine(fieldEnd(fld)));
                try f.nl();
            }
        }
        if (multiline) {
            _ = try f.commentsBefore(close_line);
            f.indent -= 1;
            try f.emitIndent();
            try f.putc('}');
        } else {
            try f.put(" }");
        }
    }

    /// A bracketed key. A string key that is a valid name is written as
    /// a plain name.
    fn tableKey(f: *Formatter, key: *ast.Expr) Error!void {
        const st = strip(key);
        if (st.e.kind == .string) {
            const k = f.tokAt(st.e.span.start);
            if (f.toks[k].tag != .interp_simple) {
                const s = st.e.kind.string;
                const src = f.literalSource(k, st.e.span.end);
                // A key spelled with escapes keeps them, so it stays in
                // brackets.
                const plain = if (src) |text| text.len == s.len + 2 else true;
                if (isIdentifier(s) and plain) return f.put(s);
                try f.putc('[');
                if (src) |text| try f.put(text) else try f.stringLit(s, f.quotes[k]);
                try f.putc(']');
                return;
            }
        }
        try f.putc('[');
        try f.expr(key);
        try f.putc(']');
    }

    /// Priorities of the reference formatter. Only their order matters.
    fn prec(op: ast.BinOp) u8 {
        return switch (op) {
            .@"or" => 1,
            .@"and" => 2,
            .lt, .gt, .le, .ge, .eq, .ne => 3,
            .bor => 4,
            .bxor => 5,
            .band => 6,
            .shl, .shr => 7,
            .concat => 8,
            .add, .sub => 9,
            .mul, .div, .idiv, .mod => 10,
            .pow => 12,
        };
    }

    fn rightAssoc(op: ast.BinOp) bool {
        return op == .concat or op == .pow;
    }

    fn needsParens(child_op: ?ast.BinOp, parent: u8, on_right: bool) bool {
        const op = child_op orelse return false;
        const cp = prec(op);
        if (cp < parent) return true;
        return cp == parent and on_right and !rightAssoc(op);
    }

    /// The operator of an operand that needs parentheses the source does
    /// not already give it. An operand in parentheses keeps the ones its
    /// author wrote, and the formatter adds none around them.
    fn binopOf(e: *ast.Expr) ?ast.BinOp {
        const st = strip(e);
        if (st.paren) return null;
        return if (st.e.kind == .binop) st.e.kind.binop.op else null;
    }

    fn binop(f: *Formatter, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) Error!void {
        if (!f.strict or f.flat > 0) return f.binopFlat(op, lhs, rhs);
        var operands: std.ArrayList(*ast.Expr) = .empty;
        try collectChain(f.arena, op, lhs, &operands);
        try collectChain(f.arena, op, rhs, &operands);
        const p = prec(op);
        const m = f.mark();
        f.flat += 1;
        for (operands.items, 0..) |e, i| {
            if (i > 0) {
                try f.putc(' ');
                try f.put(op.symbol());
                try f.putc(' ');
            }
            const wrap = needsParens(binopOf(e), p, i > 0);
            if (wrap) try f.putc('(');
            try f.expr(e);
            if (wrap) try f.putc(')');
        }
        f.flat -= 1;
        if (f.fitsSince(m)) return;
        f.reset(m);
        // A chain of one operator that does not fit breaks before each
        // operator, one level in.
        for (operands.items, 0..) |e, i| {
            if (i > 0) {
                try f.nl();
                if (i == 1) f.indent += 1;
                try f.emitIndent();
                try f.put(op.symbol());
                try f.putc(' ');
            }
            const wrap = needsParens(binopOf(e), p, i > 0);
            if (wrap) try f.putc('(');
            try f.expr(e);
            if (wrap) try f.putc(')');
        }
        if (operands.items.len > 1) f.indent -= 1;
    }

    /// The operands of a chain of `op` without parentheses, in order.
    fn collectChain(arena: Allocator, op: ast.BinOp, e: *ast.Expr, out: *std.ArrayList(*ast.Expr)) Error!void {
        if (binopOf(e)) |inner| if (inner == op) {
            const b = strip(e).e.kind.binop;
            try collectChain(arena, op, b.lhs, out);
            return collectChain(arena, op, b.rhs, out);
        };
        try out.append(arena, e);
    }

    fn binopFlat(f: *Formatter, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) Error!void {
        const p = prec(op);
        const lp = needsParens(binopOf(lhs), p, false);
        if (lp) try f.putc('(');
        try f.expr(lhs);
        if (lp) try f.putc(')');
        try f.putc(' ');
        try f.put(op.symbol());
        try f.putc(' ');
        const rp = needsParens(binopOf(rhs), p, true);
        if (rp) try f.putc('(');
        try f.expr(rhs);
        if (rp) try f.putc(')');
    }

    fn unop(f: *Formatter, op: ast.UnOp, operand: *ast.Expr) Error!void {
        const st = strip(operand);
        try f.put(op.symbol());
        if (op == .neg) {
            // Two minus signs in a row would start a comment.
            const minus = switch (st.e.kind) {
                .unop => |u| u.op == .neg,
                .float => |v| v < 0,
                else => false,
            };
            if (minus) try f.putc(' ');
        }
        const wrap = st.e.kind == .binop and !st.paren;
        if (wrap) try f.putc('(');
        try f.expr(operand);
        if (wrap) try f.putc(')');
    }

    // -----------------------------------------------------------------
    // Queries

    fn query(f: *Formatter, q: *ast.Query) Error!void {
        const m = f.mark();
        try f.queryLayout(q, false);
        if (!f.strict or f.flat > 0 or f.fitsSince(m)) return;
        f.reset(m);
        try f.queryLayout(q, true);
    }

    /// A query with each clause on a line of its own, one level in, when
    /// `broken`.
    fn queryLayout(f: *Formatter, q: *ast.Query, broken: bool) Error!void {
        try f.putc('@');
        for (q.sources, 0..) |src, i| {
            if (i > 0) try f.put(", ");
            try f.expr(src.expr);
            const after = f.tokEnd(src.expr.span.end) + 1;
            if (after < f.toks.len and f.toks[after].tag == .name and std.mem.eql(u8, f.tokText(after), "as")) {
                try f.put(" as ");
                try f.put(src.alias.text);
            }
        }

        // Clauses in source order, found by the position of their keyword.
        const Cl = struct { kw: u32, idx: u8 };
        var cls: [7]Cl = undefined;
        var n: usize = 0;
        if (q.where) |w| {
            cls[n] = .{ .kw = w.span.start, .idx = 0 };
            n += 1;
        }
        if (q.select) |items| {
            cls[n] = .{ .kw = items[0].expr.span.start, .idx = 1 };
            n += 1;
        }
        if (q.group_by) |keys| {
            cls[n] = .{ .kw = keys[0].span.start, .idx = 2 };
            n += 1;
        }
        if (q.having) |h| {
            cls[n] = .{ .kw = h.span.start, .idx = 3 };
            n += 1;
        }
        if (q.order_by) |items| {
            cls[n] = .{ .kw = items[0].expr.span.start, .idx = 4 };
            n += 1;
        }
        if (q.limit) |l| {
            cls[n] = .{ .kw = l.span.start, .idx = 5 };
            n += 1;
        }
        if (q.offset) |o| {
            cls[n] = .{ .kw = o.span.start, .idx = 6 };
            n += 1;
        }
        std.mem.sort(Cl, cls[0..n], {}, struct {
            fn lt(_: void, a: Cl, b: Cl) bool {
                return a.kw < b.kw;
            }
        }.lt);

        const words = [_][]const u8{ "where", "select", "group by", "having", "order by", "limit", "offset" };
        if (broken) f.indent += 1;
        defer if (broken) {
            f.indent -= 1;
        };
        for (cls[0..n]) |c| {
            if (broken) {
                try f.nl();
                try f.emitIndent();
            } else {
                try f.putc(' ');
            }
            try f.put(words[c.idx]);
            if (c.idx == 1 and q.distinct) try f.put(" distinct");
            try f.putc(' ');
            switch (c.idx) {
                0 => try f.qexpr(q.where.?),
                1 => for (q.select.?, 0..) |it, i| {
                    if (i > 0) try f.put(", ");
                    try f.qexpr(it.expr);
                    if (it.alias) |a| {
                        try f.put(" as ");
                        try f.put(a.text);
                    }
                },
                2 => for (q.group_by.?, 0..) |k, i| {
                    if (i > 0) try f.put(", ");
                    try f.qexpr(k);
                },
                3 => try f.qexpr(q.having.?),
                4 => for (q.order_by.?, 0..) |it, i| {
                    if (i > 0) try f.put(", ");
                    try f.qexpr(it.expr);
                    if (it.desc) try f.put(" desc");
                },
                5 => try f.qexpr(q.limit.?),
                else => try f.qexpr(q.offset.?),
            }
        }
    }

    fn tokText(f: *const Formatter, k: u32) []const u8 {
        const t = f.toks[k];
        return switch (f.payloads[t.payload]) {
            .text => |s| s,
            else => f.src[t.span.start..t.span.end],
        };
    }

    const QStripped = struct { e: *ast.QExpr, paren: bool };

    fn qstrip(e: *ast.QExpr) QStripped {
        var cur = e;
        var paren = false;
        while (cur.kind == .paren) {
            cur = cur.kind.paren;
            paren = true;
        }
        return .{ .e = cur, .paren = paren };
    }

    fn qbinopOf(e: *ast.QExpr) ?ast.BinOp {
        const st = qstrip(e);
        if (st.paren) return null;
        return switch (st.e.kind) {
            .binop => |b| b.op,
            .host, .literal => |h| binopOf(h),
            else => null,
        };
    }

    fn qexpr(f: *Formatter, e0: *ast.QExpr) Error!void {
        const st = qstrip(e0);
        const e = st.e;
        if (st.paren) try f.putc('(');
        switch (e.kind) {
            .paren => unreachable,
            .literal, .host => |x| try f.expr(x),
            .chain => |names| for (names, 0..) |nm, i| {
                if (i > 0) try f.putc('.');
                try f.put(nm.text);
            },
            .unop => |u| {
                const os = qstrip(u.operand);
                try f.put(u.op.symbol());
                if (u.op == .neg and os.e.kind == .unop and os.e.kind.unop.op == .neg) try f.putc(' ');
                const wrap = os.e.kind == .binop and !os.paren;
                if (wrap) try f.putc('(');
                try f.qexpr(u.operand);
                if (wrap) try f.putc(')');
            },
            .binop => |b| {
                const p = prec(b.op);
                const lp = needsParens(qbinopOf(b.lhs), p, false);
                if (lp) try f.putc('(');
                try f.qexpr(b.lhs);
                if (lp) try f.putc(')');
                try f.putc(' ');
                try f.put(b.op.symbol());
                try f.putc(' ');
                const rp = needsParens(qbinopOf(b.rhs), p, true);
                if (rp) try f.putc('(');
                try f.qexpr(b.rhs);
                if (rp) try f.putc(')');
            },
            .aggregate => |a| {
                try f.put(@tagName(a.func));
                try f.putc('(');
                if (a.arg) |x| try f.qexpr(x) else try f.putc('*');
                try f.putc(')');
            },
        }
        if (st.paren) try f.putc(')');
    }
};

fn isNameChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// A string that can be written as a plain table key: an ASCII name that
/// is not a reserved word.
fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] == '_' or std.ascii.isAlphabetic(s[0]))) return false;
    for (s[1..]) |c| if (!isNameChar(c)) return false;
    return token.keyword_map.get(s) == null;
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectFormat(src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try format(testing.allocator, arena_state.allocator(), src, .{});
    try testing.expectEqualStrings(want, res.ok);
}

test "format statements and comments" {
    try expectFormat("local x=1 -- one\n\n\nprint 'hi'", "local x = 1  -- one\n\nprint('hi')\n");
    try expectFormat("if a then b() elseif c then else d() end", "if a then\n    b()\nelseif c then\nelse\n    d()\nend\n");
    try expectFormat("--[[\nlong]]\nx = {1,2,3,4}", "--[[\nlong]]\nx = {\n    1,\n    2,\n    3,\n    4,\n}\n");
}

test "format keeps the escapes of interpolated strings as written" {
    try expectFormat("x = `a\\r\\n$(b)`", "x = `a\\r\\n$b`\n");
}

test "format keeps the escapes of interpolated strings" {
    try expectFormat("x = `\\27[$(code)m \\u{e9}\\x07 $$`", "x = `\\27[$(code)m \\u{e9}\\x07 $$`\n");
    try expectFormat("x = `a $(`b $(c)`) d`", "x = `a $(`b $c`) d`\n");
}

test "format keeps comments inside table constructors" {
    try expectFormat("local t = {\n    a = 1, -- first\n    b = 2, -- second\n}\n", "local t = {\n    a = 1,  -- first\n    b = 2,  -- second\n}\n");
    try expectFormat("local t = { -- head\n    1,\n    -- before two\n    2,\n    -- last\n}\n", "local t = {  -- head\n    1,\n    -- before two\n    2,\n    -- last\n}\n");
}

test "format keeps a comment after the last statement inside its block" {
    try expectFormat("for i = 1, 3 do\n    x()\n    -- note\nend\n", "for i = 1, 3 do\n    x()\n    -- note\nend\n");
    try expectFormat("if a then\n    b()\n    -- one\nelse\n    c()\n    -- two\nend\n", "if a then\n    b()\n    -- one\nelse\n    c()\n    -- two\nend\n");
}

test "format keeps comment markers and long comments as written" {
    try expectFormat("print(1) --> 1", "print(1)  --> 1\n");
    try expectFormat("--!marker\n--x\nf()", "--!marker\n-- x\nf()\n");
    try expectFormat("--[[ one line ]]\nf()", "--[[ one line ]]\nf()\n");
    try expectFormat("--[==[\na ]] b\n]==]\nf()", "--[==[\na ]] b\n]==]\nf()\n");
    try expectFormat("--[[ a\r\nb ]]\nf()", "--[[ a\nb ]]\nf()\n");
}

test "format expressions" {
    try expectFormat("x = (1+2)*3", "x = (1 + 2) * 3\n");
    try expectFormat("x = a - (b - c)", "x = a - (b - c)\n");
    try expectFormat("x = ((a + b)) * c", "x = (a + b) * c\n");
    try expectFormat("x = (a * b) + c", "x = (a * b) + c\n");
    try expectFormat("x = (a or b) and c", "x = (a or b) and c\n");
    try expectFormat("x = 2 ^ (3 ^ 2) .. (s .. t)", "x = 2 ^ (3 ^ 2) .. (s .. t)\n");
    try expectFormat("x = -(-1)", "x = - (-1)\n");
    try expectFormat("x = 0x10 + 1.5e300", "x = 0x10 + 1.5e300\n");
    try expectFormat("x = 0xff_ff + 1_000 + 12n + 1.50d", "x = 0xff_ff + 1_000 + 12n + 1.50d\n");
    try expectFormat("x = t[1,3], t[,3], t[2,]", "x = t[1, 3], t[, 3], t[2,]\n");
    // A table that holds a function goes one field per line.
    try expectFormat("local t = { start = function(n) return n end }", "local t = {\n    start = function(n)\n        return n\n    end,\n}\n");
    // A comment after the closing brace belongs to the statement.
    try expectFormat("print(#{ 1, 2 })  --> 2", "print(#{ 1, 2 })  --> 2\n");
    // A blank line inside a block stays.
    try expectFormat("local function f()\n    local a = 1\n\n    return a\nend", "local function f()\n    local a = 1\n\n    return a\nend\n");
    try expectFormat("x = f 'a' .. g {1}", "x = f 'a' .. g{ 1 }\n");
    try expectFormat("x = { ['end'] = 1, ['a'] = 2 }", "x = { ['end'] = 1, a = 2 }\n");
    try expectFormat("x = a?.b", "x = a?.b\n");
}

test "format keeps constructs the reference loses" {
    try expectFormat("global function f(a, ...) return a end", "global function f(a, ...)\n    return a\nend\n");
    try expectFormat("global *", "global *\n");
    try expectFormat("global <const> x = 1", "global <const> x = 1\n");
    try expectFormat("repeat local z = 1 until z", "repeat\n    local z = 1\nuntil z\n");
    try expectFormat("local ok = catch[h] f()", "local ok = catch[h] f()\n");
}

test "format keeps every attribute of a name" {
    try expectFormat("local r <lazy,close> = f()", "local r <lazy, close> = f()\n");
    try expectFormat("local r <close, lazy> = f()", "local r <close, lazy> = f()\n");
    try expectFormat("local v <const, check(v)> = 1", "local v <const, check(v)> = 1\n");
}

test "format rejects invalid source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try format(testing.allocator, arena_state.allocator(), "local = 1", .{ .chunkname = "=t" });
    try testing.expect(res == .fail);
}

fn expectStrict(src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try format(testing.allocator, arena_state.allocator(), src, .{ .strict = true });
    try testing.expectEqualStrings(want, res.ok);
}

test "format the strict style" {
    // A blank line separates a block that spans several lines from the
    // statements around it, except at the start and the end of a scope.
    try expectStrict("local a = 1\nif a then b() end\nc()\n", "local a = 1\n\nif a then\n    b()\nend\n\nc()\n");
    try expectStrict("do\n    if a then b() end\nend\n", "do\n    if a then\n        b()\n    end\nend\n");
    try expectStrict("local a = 1\n-- note\nwhile a do end\n", "local a = 1\n\n-- note\nwhile a do\nend\n");
    // Short strings take double quotes unless they hold one.
    try expectStrict("x = 'pear' .. 'say \"hi\"' .. 'it\\'s'", "x = \"pear\" .. 'say \"hi\"' .. \"it's\"\n");
    // A table stays on one line when it fits and its source has it there.
    try expectStrict("x = { 1, 2, 3, 4, 5 }", "x = { 1, 2, 3, 4, 5 }\n");
    try expectStrict("x = {\n    a = 1 }", "x = {\n    a = 1,\n}\n");
    // Calls, tables, and chains that do not fit wrap at 100 columns.
    try expectStrict(
        "local result = call_something_with_a_long_name(first_argument_value, second_argument_value, third_value)",
        "local result = call_something_with_a_long_name(\n    first_argument_value,\n    second_argument_value,\n    third_value\n)\n",
    );
    try expectStrict(
        "local message = \"the first part of the message \" .. first_name .. \" and then the rest of it \" .. last_name",
        "local message = \"the first part of the message \"\n    .. first_name\n    .. \" and then the rest of it \"\n    .. last_name\n",
    );
    try expectStrict(
        "local config = { name = \"server\", host = \"localhost\", port = 8080, timeout = 30, retries = 5, verbose = true }",
        "local config = {\n    name = \"server\",\n    host = \"localhost\",\n    port = 8080,\n    timeout = 30,\n    retries = 5,\n    verbose = true,\n}\n",
    );
}
