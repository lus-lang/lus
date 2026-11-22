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
//!   source are kept, and a parenthesis is added wherever precedence
//!   requires one.
//! - Numbers are respelled from their value and strings are requoted with
//!   their original quote character.
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
        var prev_end: u32 = 0;
        for (stats) |s| {
            if (s.kind == .empty) continue;
            const line = f.startLine(s.span.start);
            // A statement starts at its first preceding comment.
            var effective = line;
            if (f.next_comment < f.comments.len) {
                const cl = f.commentLine(f.comments[f.next_comment]);
                if (cl < line) effective = cl;
            }
            if (prev_end > 0 and effective > prev_end + 1) try f.nl();
            prev_end = f.endLine(s.span.end);
            try f.stat(s);
        }
        _ = try f.commentsBefore(null);
    }

    fn block(f: *Formatter, stats: []*ast.Stat) Error!void {
        f.indent += 1;
        for (stats) |s| try f.stat(s);
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
                    try f.putc('(');
                    try f.exprList(c.args);
                    try f.putc(')');
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
                try f.block(b.stats);
                try f.emitIndent();
                try f.put("end");
            },
            .while_ => |w| {
                try f.put("while ");
                try f.cond(w.cond);
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(w.body.stats);
                try f.emitIndent();
                try f.put("end");
            },
            .repeat_ => |r| {
                try f.put("repeat");
                try f.trailingComment(line);
                try f.nl();
                try f.block(r.body.stats);
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
                    try f.cond(cl.cond);
                    try f.put(" then");
                    try f.trailingComment(cl_line);
                    try f.nl();
                    try f.block(cl.body.stats);
                }
                if (ifs.else_) |b| {
                    const kw = f.tokAt(b.span.start) - 1;
                    try f.emitIndent();
                    try f.put("else");
                    try f.trailingComment(f.tokLine(kw));
                    try f.nl();
                    try f.block(b.stats);
                }
                try f.emitIndent();
                try f.put("end");
            },
            .numeric_for => |nf| {
                try f.put("for ");
                try f.put(nf.name.text);
                try f.put(" = ");
                try f.expr(nf.start);
                try f.put(", ");
                try f.expr(nf.limit);
                if (nf.step) |st| {
                    try f.put(", ");
                    try f.expr(st);
                }
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(nf.body.stats);
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
                try f.exprList(gf.exprs);
                try f.put(" do");
                try f.trailingComment(line);
                try f.nl();
                try f.block(gf.body.stats);
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
    /// the compile-time attribute first, then the runtime ones.
    fn attNames(f: *Formatter, names: []ast.AttName) Error!void {
        for (names, 0..) |an, i| {
            if (i > 0) try f.put(", ");
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
                .runtime => null,
            };
            if (word) |w| {
                try f.put(w);
                first = false;
                break;
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
        try f.putc('(');
        for (func.params, 0..) |p, i| {
            if (i > 0) try f.put(", ");
            try f.put(p.text);
        }
        if (func.vararg_name != null or func.is_vararg) {
            if (func.params.len > 0) try f.put(", ");
            try f.put("...");
            if (func.vararg_name) |vn| try f.put(vn.text);
        }
        try f.putc(')');
        try f.trailingComment(line);
        try f.nl();
        try f.block(func.body.stats);
        try f.emitIndent();
        try f.put("end");
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
            .integer => |v| try f.integer(v),
            .float => |v| try f.float(v),
            .bigint => |d| {
                try f.put(d);
                try f.putc('n');
            },
            .decimal => |d| {
                try f.put(d);
                try f.putc('d');
            },
            .string => |s| {
                const k = f.tokAt(e.span.start);
                if (f.toks[k].tag == .interp_simple) {
                    try f.putc('`');
                    try f.interpText(s);
                    try f.putc('`');
                } else {
                    try f.stringLit(s, f.quotes[k]);
                }
            },
            .interp => |parts| try f.interp(parts),
            .function => |func| {
                try f.put("function");
                try f.funcBody(func, f.startLine(e.span.start));
            },
            .table => |fields| try f.table(fields),
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
                        try f.putc('(');
                        try f.exprList(c.args);
                        try f.putc(')');
                    },
                }
            },
            .method => |m| try f.methodCall(m.obj, m.name, m.args),
            .slice => |sl| {
                try f.expr(sl.obj);
                try f.putc('[');
                if (sl.from) |x| try f.expr(x);
                try f.putc(',');
                if (sl.to) |x| try f.expr(x);
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
                try f.block(b.stats);
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

    fn methodCall(f: *Formatter, obj: *ast.Expr, name: ast.Name, args: []*ast.Expr) Error!void {
        try f.expr(obj);
        try f.putc(':');
        try f.put(name.text);
        try f.putc('(');
        try f.exprList(args);
        try f.putc(')');
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
    /// because a raw one would read back as a line break.
    fn interpText(f: *Formatter, s: []const u8) Error!void {
        for (s) |c| {
            switch (c) {
                '$' => try f.putc('$'),
                '`', '\\' => try f.putc('\\'),
                '\r' => {
                    try f.put("\\r");
                    continue;
                },
                else => {},
            }
            try f.putc(c);
        }
    }

    fn interp(f: *Formatter, parts: []ast.InterpPart) Error!void {
        try f.putc('`');
        for (parts, 0..) |p, i| switch (p) {
            .text => |s| try f.interpText(s),
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

    fn table(f: *Formatter, fields: []ast.Field) Error!void {
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

    /// A bracketed key. A string key that is a valid name is written as
    /// a plain name.
    fn tableKey(f: *Formatter, key: *ast.Expr) Error!void {
        const st = strip(key);
        if (st.e.kind == .string) {
            const k = f.tokAt(st.e.span.start);
            if (f.toks[k].tag != .interp_simple) {
                const s = st.e.kind.string;
                if (isIdentifier(s)) return f.put(s);
                try f.putc('[');
                try f.stringLit(s, f.quotes[k]);
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

    fn binopOf(e: *ast.Expr) ?ast.BinOp {
        const st = strip(e);
        return if (st.e.kind == .binop) st.e.kind.binop.op else null;
    }

    fn binop(f: *Formatter, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr) Error!void {
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
        for (cls[0..n]) |c| {
            try f.putc(' ');
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

test "format escapes a carriage return in interpolated strings" {
    try expectFormat("x = `a\\r\\n$(b)`", "x = `a\\r\n$b`\n");
}

test "format keeps comment markers and long comments as written" {
    try expectFormat("print(1) --> 1", "print(1)  --> 1\n");
    try expectFormat("--!marker\n--x\nf()", "--!marker\n-- x\nf()\n");
    try expectFormat("--[[ one line ]]\nf()", "--[[ one line ]]\nf()\n");
    try expectFormat("--[==[\na ]] b\n]==]\nf()", "--[==[\na ]] b\n]==]\nf()\n");
    try expectFormat("--[[ a\r\nb ]]\nf()", "--[[ a\nb ]]\nf()\n");
}

test "format expressions" {
    try expectFormat("x = (1+2)*3", "x = ((1 + 2)) * 3\n");
    try expectFormat("x = a - (b - c)", "x = a - ((b - c))\n");
    try expectFormat("x = -(-1)", "x = - (-1)\n");
    try expectFormat("x = 0x10 + 1.5e300", "x = 16 + 1.5e+300\n");
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

test "format rejects invalid source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try format(testing.allocator, arena_state.allocator(), "local = 1", .{ .chunkname = "=t" });
    try testing.expect(res == .fail);
}
