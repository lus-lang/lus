//! Token definitions shared by the lexer, the parser, and the tooling.

const std = @import("std");

pub const Tag = enum(u8) {
    // Keywords. The order matches `keywords` below.
    kw_and,
    kw_break,
    kw_catch,
    kw_continue,
    kw_do,
    kw_else,
    kw_elseif,
    kw_end,
    kw_enum,
    kw_false,
    kw_for,
    kw_from,
    kw_function,
    kw_global,
    kw_goto,
    kw_if,
    kw_in,
    kw_local,
    kw_nil,
    kw_not,
    kw_or,
    kw_provide,
    kw_repeat,
    kw_return,
    kw_then,
    kw_true,
    kw_until,
    kw_while,

    // Multi-character operators.
    idiv, // //
    concat, // ..
    dots, // ...
    eq, // ==
    ge, // >=
    le, // <=
    ne, // ~=
    shl, // <<
    shr, // >>
    dbcolon, // ::

    // Single-character operators and punctuation.
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    hash,
    amp,
    tilde,
    pipe,
    lt,
    gt,
    assign,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semicolon,
    colon,
    comma,
    dot,
    question,
    at,

    // Literals and names.
    name,
    integer,
    float,
    bigint,
    decimal,
    string,

    // Interpolated strings. A backtick string without interpolation is
    // a plain `string` token. Otherwise the lexer emits `interp_begin`,
    // then the tokens of one embedded expression, then `interp_mid` or
    // `interp_end`. Each of the three carries the literal text before
    // the next embedded expression.
    interp_begin,
    interp_mid,
    interp_end,

    eof,
};

pub const keywords = [_][]const u8{
    "and",   "break",  "catch",  "continue", "do",     "else",  "elseif",
    "end",   "enum",   "false",  "for",      "from",   "function", "global",
    "goto",  "if",     "in",     "local",    "nil",    "not",   "or",
    "provide", "repeat", "return", "then",   "true",   "until", "while",
};

pub const keyword_map = std.StaticStringMap(Tag).initComptime(blk: {
    var entries: [keywords.len]struct { []const u8, Tag } = undefined;
    for (keywords, 0..) |kw, i| entries[i] = .{ kw, @enumFromInt(i) };
    break :blk entries;
});

/// Byte span into the source.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(s: Span) u32 {
        return s.end - s.start;
    }
};

pub const Token = struct {
    tag: Tag,
    span: Span,
    line: u32,
    /// Index into the lexer's payload table for names, strings, and
    /// numbers. Unused for other tokens.
    payload: u32 = 0,
};

pub fn describe(tag: Tag) []const u8 {
    return switch (tag) {
        .idiv => "//",
        .concat => "..",
        .dots => "...",
        .eq => "==",
        .ge => ">=",
        .le => "<=",
        .ne => "~=",
        .shl => "<<",
        .shr => ">>",
        .dbcolon => "::",
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .caret => "^",
        .hash => "#",
        .amp => "&",
        .tilde => "~",
        .pipe => "|",
        .lt => "<",
        .gt => ">",
        .assign => "=",
        .lparen => "(",
        .rparen => ")",
        .lbrace => "{",
        .rbrace => "}",
        .lbracket => "[",
        .rbracket => "]",
        .semicolon => ";",
        .colon => ":",
        .comma => ",",
        .dot => ".",
        .question => "?",
        .at => "@",
        .name => "<name>",
        .integer => "<integer>",
        .float => "<number>",
        .bigint => "<bigint>",
        .decimal => "<decimal>",
        .string => "<string>",
        .interp_begin, .interp_mid, .interp_end => "<interpolation>",
        .eof => "<eof>",
        else => keywords[@intFromEnum(tag)],
    };
}

test "keyword map covers every keyword" {
    try std.testing.expectEqual(Tag.kw_while, keyword_map.get("while").?);
    try std.testing.expectEqual(Tag.kw_and, keyword_map.get("and").?);
    try std.testing.expect(keyword_map.get("lambda") == null);
    try std.testing.expectEqualStrings("provide", describe(.kw_provide));
}
