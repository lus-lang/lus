//! The Lus lexer. It turns a whole source buffer into a token array with
//! a side table of payloads (names, decoded strings, numbers), and keeps
//! comments as trivia for the formatter and the documentation generator.

const std = @import("std");
const token = @import("token.zig");
const Tag = token.Tag;
const Token = token.Token;
const Span = token.Span;
const Allocator = std.mem.Allocator;

pub const Payload = union(enum) {
    none,
    /// Names and decoded string contents. Interned per lexer run.
    text: []const u8,
    integer: i64,
    float: f64,
    /// Bigint and decimal literals keep their source digits, without the
    /// suffix and without `_` separators. The runtime converts them.
    digits: []const u8,
};

pub const Comment = struct {
    span: Span,
    line: u32,
    /// Text after the `--` marker, without long bracket delimiters.
    text: []const u8,
    long: bool,
};

pub const Diagnostic = struct {
    message: []const u8,
    line: u32,
    span: Span,
};

pub const Result = struct {
    tokens: []Token,
    payloads: []Payload,
    comments: []Comment,
};

pub const Error = error{SyntaxError} || Allocator.Error;

const Mode = union(enum) {
    /// Ordinary code. `depth` counts open parentheses since the `$(` that
    /// started this embedded expression, so the matching `)` resumes the
    /// interpolated string. The outermost code mode has no owner.
    code: struct { depth: u32, in_interp: bool },
};

pub const Lexer = struct {
    gpa: Allocator,
    arena: Allocator,
    src: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    tokens: std.ArrayList(Token) = .empty,
    payloads: std.ArrayList(Payload) = .empty,
    comments: std.ArrayList(Comment) = .empty,
    modes: std.ArrayList(Mode) = .empty,
    buf: std.ArrayList(u8) = .empty,
    diag: ?Diagnostic = null,
    /// Emit an `unknown` token for a byte that starts no token, instead
    /// of failing, as the reference lexer does. Used by the tooling.
    tolerant: bool = false,

    pub fn init(gpa: Allocator, arena: Allocator, src: []const u8) Lexer {
        return .{ .gpa = gpa, .arena = arena, .src = src };
    }

    pub fn deinit(lx: *Lexer) void {
        lx.tokens.deinit(lx.gpa);
        lx.payloads.deinit(lx.gpa);
        lx.comments.deinit(lx.gpa);
        lx.modes.deinit(lx.gpa);
        lx.buf.deinit(lx.gpa);
    }

    /// Lexes the whole source. On success the returned slices are owned by
    /// the arena.
    pub fn run(lx: *Lexer) Error!Result {
        try lx.payloads.append(lx.gpa, .none); // payload 0 means "none"
        try lx.modes.append(lx.gpa, .{ .code = .{ .depth = 0, .in_interp = false } });
        lx.skipShebang();
        while (true) {
            const done = try lx.next();
            if (done) break;
        }
        return .{
            .tokens = try lx.arena.dupe(Token, lx.tokens.items),
            .payloads = try lx.arena.dupe(Payload, lx.payloads.items),
            .comments = try lx.arena.dupe(Comment, lx.comments.items),
        };
    }

    fn skipShebang(lx: *Lexer) void {
        if (lx.src.len >= 1 and lx.src[0] == '#') {
            while (lx.pos < lx.src.len and lx.src[lx.pos] != '\n') lx.pos += 1;
        }
    }

    inline fn cur(lx: *Lexer) u8 {
        return if (lx.pos < lx.src.len) lx.src[lx.pos] else 0;
    }

    inline fn peekAt(lx: *Lexer, off: u32) u8 {
        const p = lx.pos + off;
        return if (p < lx.src.len) lx.src[p] else 0;
    }

    inline fn atEnd(lx: *Lexer) bool {
        return lx.pos >= lx.src.len;
    }

    fn fail(lx: *Lexer, start: u32, comptime fmt: []const u8, args: anytype) Error {
        const msg = std.fmt.allocPrint(lx.arena, fmt, args) catch return error.OutOfMemory;
        lx.diag = .{ .message = msg, .line = lx.line, .span = .{ .start = start, .end = @max(start, lx.pos) } };
        return error.SyntaxError;
    }

    fn nearText(lx: *Lexer, start: u32) []const u8 {
        const end = @min(lx.pos, @as(u32, @intCast(lx.src.len)));
        if (end <= start) return "";
        return lx.src[start..end];
    }

    fn push(lx: *Lexer, tag: Tag, start: u32, line: u32, payload: Payload) Error!void {
        var idx: u32 = 0;
        if (payload != .none) {
            idx = @intCast(lx.payloads.items.len);
            try lx.payloads.append(lx.gpa, payload);
        }
        try lx.tokens.append(lx.gpa, .{ .tag = tag, .span = .{ .start = start, .end = lx.pos }, .line = line, .payload = idx });
    }

    fn newline(lx: *Lexer) void {
        // Treat \n, \r, \r\n, and \n\r as a single line break, as Lua does.
        const c = lx.cur();
        lx.pos += 1;
        const d = lx.cur();
        if ((d == '\n' or d == '\r') and d != c) lx.pos += 1;
        lx.line += 1;
    }

    fn topMode(lx: *Lexer) *Mode {
        return &lx.modes.items[lx.modes.items.len - 1];
    }

    /// Lexes one token. Returns true after emitting `eof`.
    fn next(lx: *Lexer) Error!bool {
        while (true) {
            const start = lx.pos;
            const c = lx.cur();
            if (lx.atEnd()) {
                if (lx.modes.items.len > 1) return lx.fail(start, "unfinished interpolated string near <eof>", .{});
                try lx.push(.eof, start, lx.line, .none);
                return true;
            }
            switch (c) {
                '\n', '\r' => lx.newline(),
                ' ', '\t', '\x0b', '\x0c' => lx.pos += 1,
                '-' => {
                    if (lx.peekAt(1) != '-') {
                        lx.pos += 1;
                        try lx.push(.minus, start, lx.line, .none);
                        return false;
                    }
                    try lx.comment();
                },
                '[' => {
                    const sep = lx.longBracketLevel();
                    if (sep) |level| {
                        const line = lx.line;
                        const text = try lx.longString(level, start, false);
                        try lx.push(.string, start, line, .{ .text = text });
                        return false;
                    }
                    lx.pos += 1;
                    try lx.push(.lbracket, start, lx.line, .none);
                    return false;
                },
                '=' => return lx.op2(start, '=', .eq, .assign),
                '<' => {
                    lx.pos += 1;
                    if (lx.cur() == '=') {
                        lx.pos += 1;
                        try lx.push(.le, start, lx.line, .none);
                    } else if (lx.cur() == '<') {
                        lx.pos += 1;
                        try lx.push(.shl, start, lx.line, .none);
                    } else try lx.push(.lt, start, lx.line, .none);
                    return false;
                },
                '>' => {
                    lx.pos += 1;
                    if (lx.cur() == '=') {
                        lx.pos += 1;
                        try lx.push(.ge, start, lx.line, .none);
                    } else if (lx.cur() == '>') {
                        lx.pos += 1;
                        try lx.push(.shr, start, lx.line, .none);
                    } else try lx.push(.gt, start, lx.line, .none);
                    return false;
                },
                '/' => return lx.op2(start, '/', .idiv, .slash),
                '~' => return lx.op2(start, '=', .ne, .tilde),
                ':' => return lx.op2(start, ':', .dbcolon, .colon),
                '"', '\'' => {
                    const line = lx.line;
                    const text = try lx.shortString(c, start);
                    try lx.push(.string, start, line, .{ .text = text });
                    return false;
                },
                '`' => {
                    lx.pos += 1;
                    try lx.interpSection(start, true);
                    return false;
                },
                '.' => {
                    if (lx.peekAt(1) == '.') {
                        if (lx.peekAt(2) == '.') {
                            lx.pos += 3;
                            try lx.push(.dots, start, lx.line, .none);
                        } else {
                            lx.pos += 2;
                            try lx.push(.concat, start, lx.line, .none);
                        }
                        return false;
                    }
                    if (std.ascii.isDigit(lx.peekAt(1))) {
                        try lx.number(start);
                        return false;
                    }
                    lx.pos += 1;
                    try lx.push(.dot, start, lx.line, .none);
                    return false;
                },
                '0'...'9' => {
                    try lx.number(start);
                    return false;
                },
                '(' => {
                    lx.pos += 1;
                    switch (lx.topMode().*) {
                        .code => |*m| m.depth += 1,
                    }
                    try lx.push(.lparen, start, lx.line, .none);
                    return false;
                },
                ')' => {
                    const m = &lx.topMode().code;
                    if (m.in_interp and m.depth == 0) {
                        // End of a `$( ... )` embedded expression.
                        lx.pos += 1;
                        _ = lx.modes.pop();
                        try lx.interpSection(lx.pos, false);
                        return false;
                    }
                    if (m.depth > 0) m.depth -= 1;
                    lx.pos += 1;
                    try lx.push(.rparen, start, lx.line, .none);
                    return false;
                },
                else => {
                    if (isNameStart(c)) {
                        while (isNameChar(lx.cur())) lx.pos += 1;
                        const word = lx.src[start..lx.pos];
                        if (token.keyword_map.get(word)) |kw| {
                            try lx.push(kw, start, lx.line, .none);
                        } else {
                            try lx.push(.name, start, lx.line, .{ .text = word });
                        }
                        return false;
                    }
                    const single: ?Tag = switch (c) {
                        '+' => .plus,
                        '*' => .star,
                        '%' => .percent,
                        '^' => .caret,
                        '#' => .hash,
                        '&' => .amp,
                        '|' => .pipe,
                        '{' => .lbrace,
                        '}' => .rbrace,
                        ']' => .rbracket,
                        ';' => .semicolon,
                        ',' => .comma,
                        '?' => .question,
                        '@' => .at,
                        else => null,
                    };
                    if (single) |t| {
                        lx.pos += 1;
                        try lx.push(t, start, lx.line, .none);
                        return false;
                    }
                    lx.pos += 1;
                    if (lx.tolerant) {
                        try lx.push(.unknown, start, lx.line, .none);
                        return false;
                    }
                    return lx.fail(start, "unexpected symbol near '{s}'", .{lx.nearText(start)});
                },
            }
        }
    }

    fn op2(lx: *Lexer, start: u32, second: u8, two: Tag, one: Tag) Error!bool {
        lx.pos += 1;
        if (lx.cur() == second) {
            lx.pos += 1;
            try lx.push(two, start, lx.line, .none);
        } else {
            try lx.push(one, start, lx.line, .none);
        }
        return false;
    }

    fn comment(lx: *Lexer) Error!void {
        const start = lx.pos;
        const line = lx.line;
        lx.pos += 2; // skip `--`
        if (lx.cur() == '[') {
            if (lx.longBracketLevel()) |level| {
                const text = try lx.longString(level, start, true);
                try lx.comments.append(lx.gpa, .{ .span = .{ .start = start, .end = lx.pos }, .line = line, .text = text, .long = true });
                return;
            }
        }
        const text_start = lx.pos;
        while (!lx.atEnd() and lx.cur() != '\n' and lx.cur() != '\r') lx.pos += 1;
        try lx.comments.append(lx.gpa, .{ .span = .{ .start = start, .end = lx.pos }, .line = line, .text = lx.src[text_start..lx.pos], .long = false });
    }

    /// If the cursor is at `[` followed by zero or more `=` and another
    /// `[`, returns the number of `=` signs. Leaves the cursor unchanged.
    fn longBracketLevel(lx: *Lexer) ?u32 {
        var p = lx.pos + 1;
        var level: u32 = 0;
        while (p < lx.src.len and lx.src[p] == '=') : (p += 1) level += 1;
        if (p < lx.src.len and lx.src[p] == '[') return level;
        return null;
    }

    fn longString(lx: *Lexer, level: u32, start: u32, is_comment: bool) Error![]const u8 {
        const start_line = lx.line;
        lx.pos += level + 2; // skip `[`, `=`*level, `[`
        // A newline right after the opening bracket is skipped.
        if (lx.cur() == '\n' or lx.cur() == '\r') lx.newline();
        lx.buf.clearRetainingCapacity();
        while (true) {
            if (lx.atEnd()) {
                return lx.fail(start, "unfinished long {s} (starting at line {d}) near <eof>", .{ if (is_comment) "comment" else "string", start_line });
            }
            const c = lx.cur();
            if (c == ']') {
                var p = lx.pos + 1;
                var n: u32 = 0;
                while (p < lx.src.len and lx.src[p] == '=') : (p += 1) n += 1;
                if (n == level and p < lx.src.len and lx.src[p] == ']') {
                    lx.pos = p + 1;
                    break;
                }
                try lx.buf.append(lx.gpa, c);
                lx.pos += 1;
            } else if (c == '\n' or c == '\r') {
                try lx.buf.append(lx.gpa, '\n');
                lx.newline();
            } else {
                try lx.buf.append(lx.gpa, c);
                lx.pos += 1;
            }
        }
        return lx.arena.dupe(u8, lx.buf.items);
    }

    fn shortString(lx: *Lexer, delim: u8, start: u32) Error![]const u8 {
        lx.pos += 1;
        lx.buf.clearRetainingCapacity();
        while (true) {
            if (lx.atEnd()) return lx.fail(start, "unfinished string near <eof>", .{});
            const c = lx.cur();
            if (c == delim) {
                lx.pos += 1;
                break;
            }
            switch (c) {
                '\n', '\r' => return lx.fail(start, "unfinished string near '{s}'", .{lx.nearText(start)}),
                '\\' => try lx.escape(start),
                else => {
                    try lx.buf.append(lx.gpa, c);
                    lx.pos += 1;
                },
            }
        }
        return lx.arena.dupe(u8, lx.buf.items);
    }

    /// Decodes one escape sequence starting at `\`. Shared by quoted
    /// strings. Interpolated strings use a smaller escape set.
    fn escape(lx: *Lexer, start: u32) Error!void {
        lx.pos += 1; // skip backslash
        const c = lx.cur();
        const simple: ?u8 = switch (c) {
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '\\' => '\\',
            '"' => '"',
            '\'' => '\'',
            else => null,
        };
        if (simple) |s| {
            try lx.buf.append(lx.gpa, s);
            lx.pos += 1;
            return;
        }
        switch (c) {
            '\n', '\r' => {
                try lx.buf.append(lx.gpa, '\n');
                lx.newline();
            },
            'x' => {
                lx.pos += 1;
                var v: u8 = 0;
                var i: u32 = 0;
                while (i < 2) : (i += 1) {
                    const h = lx.cur();
                    const d = hexValue(h) orelse return lx.fail(start, "hexadecimal digit expected near '{s}'", .{lx.nearText(start)});
                    v = v * 16 + d;
                    lx.pos += 1;
                }
                try lx.buf.append(lx.gpa, v);
            },
            'z' => {
                lx.pos += 1;
                while (!lx.atEnd()) {
                    const w = lx.cur();
                    if (w == '\n' or w == '\r') {
                        lx.newline();
                    } else if (std.ascii.isWhitespace(w)) {
                        lx.pos += 1;
                    } else break;
                }
            },
            'u' => {
                lx.pos += 1;
                if (lx.cur() != '{') return lx.fail(start, "missing '{{' in \\u{{xxxx}} near '{s}'", .{lx.nearText(start)});
                lx.pos += 1;
                var v: u64 = 0;
                var digits: u32 = 0;
                while (hexValue(lx.cur())) |d| {
                    v = v * 16 + d;
                    digits += 1;
                    if (v > 0x7FFFFFFF) return lx.fail(start, "UTF-8 value too large near '{s}'", .{lx.nearText(start)});
                    lx.pos += 1;
                }
                if (digits == 0) return lx.fail(start, "hexadecimal digit expected near '{s}'", .{lx.nearText(start)});
                if (lx.cur() != '}') return lx.fail(start, "missing '}}' in \\u{{xxxx}} near '{s}'", .{lx.nearText(start)});
                lx.pos += 1;
                try appendUtf8Extended(lx.gpa, &lx.buf, @intCast(v));
            },
            '0'...'9' => {
                var v: u32 = 0;
                var i: u32 = 0;
                while (i < 3 and std.ascii.isDigit(lx.cur())) : (i += 1) {
                    v = v * 10 + (lx.cur() - '0');
                    lx.pos += 1;
                }
                if (v > 255) return lx.fail(start, "decimal escape too large near '{s}'", .{lx.nearText(start)});
                try lx.buf.append(lx.gpa, @intCast(v));
            },
            else => {
                if (lx.atEnd()) return lx.fail(start, "unfinished string near <eof>", .{});
                lx.pos += 1;
                return lx.fail(start, "invalid escape sequence near '{s}'", .{lx.nearText(start)});
            },
        }
    }

    /// Reads one literal section of an interpolated string, starting right
    /// after the opening backtick (`first`) or right after the end of an
    /// embedded expression.
    fn interpSection(lx: *Lexer, start: u32, first: bool) Error!void {
        const line = lx.line;
        lx.buf.clearRetainingCapacity();
        while (true) {
            if (lx.atEnd()) return lx.fail(start, "unfinished interpolated string near <eof>", .{});
            const c = lx.cur();
            switch (c) {
                '`' => {
                    lx.pos += 1;
                    const text = try lx.arena.dupe(u8, lx.buf.items);
                    try lx.push(if (first) .interp_simple else .interp_end, start, line, .{ .text = text });
                    return;
                },
                '$' => {
                    const n = lx.peekAt(1);
                    if (n == '$') {
                        try lx.buf.append(lx.gpa, '$');
                        lx.pos += 2;
                    } else if (n == '(') {
                        lx.pos += 2;
                        const text = try lx.arena.dupe(u8, lx.buf.items);
                        try lx.push(if (first) .interp_begin else .interp_mid, start, line, .{ .text = text });
                        try lx.modes.append(lx.gpa, .{ .code = .{ .depth = 0, .in_interp = true } });
                        return;
                    } else if (isNameStart(n)) {
                        const text = try lx.arena.dupe(u8, lx.buf.items);
                        lx.pos += 1;
                        try lx.push(if (first) .interp_begin else .interp_mid, start, line, .{ .text = text });
                        const name_start = lx.pos;
                        while (isNameChar(lx.cur())) lx.pos += 1;
                        const word = lx.src[name_start..lx.pos];
                        if (token.keyword_map.get(word) != null) {
                            return lx.fail(name_start, "invalid interpolation after '$'", .{});
                        }
                        try lx.push(.name, name_start, lx.line, .{ .text = word });
                        // Continue the string directly.
                        return lx.interpSection(lx.pos, false);
                    } else {
                        lx.pos += 1;
                        return lx.fail(start, "invalid interpolation after '$'", .{});
                    }
                },
                '\\' => {
                    lx.pos += 1;
                    const e = lx.cur();
                    const out: ?u8 = switch (e) {
                        '`' => '`',
                        '$' => '$',
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '\\' => '\\',
                        else => null,
                    };
                    if (out) |o| {
                        try lx.buf.append(lx.gpa, o);
                        lx.pos += 1;
                    } else if (e == '\n' or e == '\r') {
                        try lx.buf.append(lx.gpa, '\n');
                        lx.newline();
                    } else {
                        return lx.fail(start, "invalid escape sequence in interpolated string", .{});
                    }
                },
                '\n', '\r' => {
                    try lx.buf.append(lx.gpa, '\n');
                    lx.newline();
                },
                else => {
                    try lx.buf.append(lx.gpa, c);
                    lx.pos += 1;
                },
            }
        }
    }

    fn number(lx: *Lexer, start: u32) Error!void {
        var exp_chars: [2]u8 = .{ 'e', 'E' };
        const hex = lx.cur() == '0' and (lx.peekAt(1) == 'x' or lx.peekAt(1) == 'X');
        if (hex) {
            lx.pos += 2;
            exp_chars = .{ 'p', 'P' };
        }
        while (true) {
            const c = lx.cur();
            if (c == exp_chars[0] or c == exp_chars[1]) {
                lx.pos += 1;
                if (lx.cur() == '+' or lx.cur() == '-') lx.pos += 1;
            } else if ((if (hex) std.ascii.isHex(c) else std.ascii.isDigit(c)) or c == '.' or c == '_') {
                lx.pos += 1;
            } else break;
        }
        // Suffix: `n` for bigint, `d` for decimal (decimal notation only).
        var suffix: u8 = 0;
        if (lx.cur() == 'n') {
            suffix = 'n';
            lx.pos += 1;
        } else if (!hex and lx.cur() == 'd') {
            suffix = 'd';
            lx.pos += 1;
        }
        if (isNameChar(lx.cur())) {
            while (isNameChar(lx.cur())) lx.pos += 1;
            return lx.fail(start, "malformed number near '{s}'", .{lx.nearText(start)});
        }
        const raw = lx.src[start .. lx.pos - @as(u32, if (suffix != 0) 1 else 0)];
        // Strip `_` digit separators. They may only sit between digits.
        lx.buf.clearRetainingCapacity();
        for (raw, 0..) |ch, i| {
            if (ch == '_') {
                const ok = i > 0 and i + 1 < raw.len and std.ascii.isHex(raw[i - 1]) and std.ascii.isHex(raw[i + 1]);
                if (!ok or (i == 1 and hex)) return lx.fail(start, "malformed number near '{s}'", .{lx.nearText(start)});
                continue;
            }
            try lx.buf.append(lx.gpa, ch);
        }
        const text = lx.buf.items;
        switch (suffix) {
            'n' => {
                if (std.mem.indexOfAny(u8, text, ".pP") != null or (!hex and std.mem.indexOfAny(u8, text, "eE") != null))
                    return lx.fail(start, "malformed number near '{s}'", .{lx.nearText(start)});
                try lx.push(.bigint, start, lx.line, .{ .digits = try lx.arena.dupe(u8, text) });
            },
            'd' => {
                if (!isValidDecimalText(text)) return lx.fail(start, "malformed number near '{s}'", .{lx.nearText(start)});
                try lx.push(.decimal, start, lx.line, .{ .digits = try lx.arena.dupe(u8, text) });
            },
            else => {
                const parsed = parseNumber(text) orelse return lx.fail(start, "malformed number near '{s}'", .{lx.nearText(start)});
                switch (parsed) {
                    .integer => |v| try lx.push(.integer, start, lx.line, .{ .integer = v }),
                    .float => |v| try lx.push(.float, start, lx.line, .{ .float = v }),
                }
            },
        }
    }
};

pub const Number = union(enum) { integer: i64, float: f64 };

/// Parses a Lua numeral (decimal or hexadecimal, integer or float). Integer
/// literals that overflow fall back to float for decimal and wrap around
/// for hexadecimal, as in Lua. Shared with `tonumber`.
pub fn parseNumber(text: []const u8) ?Number {
    if (text.len == 0) return null;
    var s = text;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        s = s[1..];
    } else if (s[0] == '+') s = s[1..];
    if (s.len == 0) return null;
    const is_hex = s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X');
    if (is_hex) {
        const body = s[2..];
        if (body.len == 0) return null;
        if (std.mem.indexOfAny(u8, body, ".pP") == null) {
            var v: u64 = 0;
            for (body) |c| {
                const d = hexValue(c) orelse return null;
                v = v *% 16 +% d;
            }
            const iv: i64 = @bitCast(v);
            return .{ .integer = if (neg) 0 -% iv else iv };
        }
        const f = parseHexFloat(body) orelse return null;
        return .{ .float = if (neg) -f else f };
    }
    // Decimal.
    var all_digits = true;
    for (s) |c| if (!std.ascii.isDigit(c)) {
        all_digits = false;
        break;
    };
    if (all_digits) {
        if (std.fmt.parseInt(i64, s, 10)) |v| {
            return .{ .integer = if (neg) -v else v };
        } else |_| {
            // Special case: the magnitude of minint.
            if (neg and std.mem.eql(u8, s, "9223372036854775808")) return .{ .integer = std.math.minInt(i64) };
        }
    }
    // Validate the float syntax: digits [. digits] [e [+-] digits].
    var i: usize = 0;
    var mant_digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mant_digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mant_digits += 1;
    }
    if (mant_digits == 0) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return null;
    }
    if (i != s.len) return null;
    const f = std.fmt.parseFloat(f64, s) catch return null;
    return .{ .float = if (neg) -f else f };
}

fn parseHexFloat(body: []const u8) ?f64 {
    var mant: f64 = 0;
    var exp: i64 = 0;
    var any = false;
    var i: usize = 0;
    var seen_dot = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '.') {
            if (seen_dot) return null;
            seen_dot = true;
        } else if (hexValue(c)) |d| {
            mant = mant * 16 + @as(f64, @floatFromInt(d));
            if (seen_dot) exp -= 4;
            any = true;
        } else break;
    }
    if (!any) return null;
    if (i < body.len) {
        if (body[i] != 'p' and body[i] != 'P') return null;
        i += 1;
        var sign: i64 = 1;
        if (i < body.len and (body[i] == '+' or body[i] == '-')) {
            if (body[i] == '-') sign = -1;
            i += 1;
        }
        if (i >= body.len) return null;
        var e: i64 = 0;
        while (i < body.len) : (i += 1) {
            if (!std.ascii.isDigit(body[i])) return null;
            e = @min(e * 10 + (body[i] - '0'), 100000);
        }
        exp += sign * e;
    }
    return std.math.ldexp(mant, @intCast(std.math.clamp(exp, -100000, 100000)));
}

fn isValidDecimalText(text: []const u8) bool {
    var i: usize = 0;
    var digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) digits += 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        var ed: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) ed += 1;
        if (ed == 0) return false;
    }
    return i == text.len;
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub inline fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub inline fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Encodes a code point up to 0x7FFFFFFF with the extended UTF-8 scheme
/// Lua uses for `\u{...}` escapes. Surrogates are encoded as WTF-8.
pub fn appendUtf8Extended(gpa: Allocator, out: *std.ArrayList(u8), cp: u32) Allocator.Error!void {
    if (cp < 0x80) {
        try out.append(gpa, @intCast(cp));
        return;
    }
    var tmp: [6]u8 = undefined;
    var n: usize = 0;
    var x = cp;
    var mfb: u32 = 0x3f; // maximum that fits in the first byte
    while (true) {
        tmp[5 - n] = @intCast(0x80 | (x & 0x3f));
        n += 1;
        x >>= 6;
        mfb >>= 1;
        if (x <= mfb) break;
    }
    tmp[5 - n] = @intCast((~mfb << 1) & 0xff | x);
    n += 1;
    try out.appendSlice(gpa, tmp[6 - n ..]);
}

/// Convenience used by tests and tools.
pub fn lex(gpa: Allocator, arena: Allocator, src: []const u8) (Error)!Result {
    var lx = Lexer.init(gpa, arena, src);
    defer lx.deinit();
    return lx.run();
}

const testing = std.testing;

fn tagsOf(src: []const u8) ![]Tag {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try lex(testing.allocator, arena.allocator(), src);
    const out = try testing.allocator.alloc(Tag, r.tokens.len);
    for (r.tokens, 0..) |t, i| out[i] = t.tag;
    return out;
}

test "basic tokens" {
    const tags = try tagsOf("local x = 1 + 2.5 // 3 .. 'a' ~= b ?. @");
    defer testing.allocator.free(tags);
    const want = [_]Tag{ .kw_local, .name, .assign, .integer, .plus, .float, .idiv, .integer, .concat, .string, .ne, .name, .question, .dot, .at, .eof };
    try testing.expectEqualSlices(Tag, &want, tags);
}

test "interpolation with names and expressions" {
    const tags = try tagsOf("`a $x b $(f(1)) c`");
    defer testing.allocator.free(tags);
    const want = [_]Tag{ .interp_begin, .name, .interp_mid, .name, .lparen, .integer, .rparen, .interp_end, .eof };
    try testing.expectEqualSlices(Tag, &want, tags);
}

test "nested interpolation" {
    const tags = try tagsOf("`x $(`y $z`) w`");
    defer testing.allocator.free(tags);
    const want = [_]Tag{ .interp_begin, .interp_begin, .name, .interp_end, .interp_end, .eof };
    try testing.expectEqualSlices(Tag, &want, tags);
}

test "numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try lex(testing.allocator, arena.allocator(), "0xff 1e2 12n 1.50d 1_000 0x1p4 9223372036854775808");
    try testing.expectEqual(@as(i64, 255), r.payloads[r.tokens[0].payload].integer);
    try testing.expectEqual(@as(f64, 100), r.payloads[r.tokens[1].payload].float);
    try testing.expectEqual(Tag.bigint, r.tokens[2].tag);
    try testing.expectEqualStrings("1.50", r.payloads[r.tokens[3].payload].digits);
    try testing.expectEqual(@as(i64, 1000), r.payloads[r.tokens[4].payload].integer);
    try testing.expectEqual(@as(f64, 16), r.payloads[r.tokens[5].payload].float);
    try testing.expectEqual(Tag.float, r.tokens[6].tag);
}

test "strings and escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try lex(testing.allocator, arena.allocator(), "'a\\n\\x41\\u{48}\\65' [==[\nlong]]x]==]");
    try testing.expectEqualStrings("a\nAHA", r.payloads[r.tokens[0].payload].text);
    try testing.expectEqualStrings("long]]x", r.payloads[r.tokens[1].payload].text);
}

test "comments are trivia" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try lex(testing.allocator, arena.allocator(), "-- hi\nx --[[ block ]] y");
    try testing.expectEqual(@as(usize, 2), r.comments.len);
    try testing.expectEqualStrings(" hi", r.comments[0].text);
    try testing.expectEqual(@as(usize, 3), r.tokens.len);
}

test "errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(testing.allocator, arena.allocator(), "x = 'abc");
    defer lx.deinit();
    try testing.expectError(error.SyntaxError, lx.run());
    try testing.expect(std.mem.startsWith(u8, lx.diag.?.message, "unfinished string"));
}
