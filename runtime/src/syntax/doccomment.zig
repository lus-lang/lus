//! Doc comments. A doc comment is a run of `---` line comments, or one
//! `--[[- ... ]]` long comment, that sits on its own lines and ends on the
//! line directly above a declaration. Its text is Markdown, and lines that
//! start with an annotation describe the declaration:
//!
//!     --- Adds two numbers.
//!     --- @param a number The first addend.
//!     --- @param b? number The second addend, 0 by default.
//!     --- @return number The sum.
//!     local function add(a, b) ... end
//!
//! `@param NAME TYPE DESCRIPTION` documents a parameter. A `?` after the
//! name or after the type marks it optional. `...` documents unnamed
//! variable arguments, and `...NAME` documents variable arguments that the
//! declaration names, as in `local function f(...parts)`. `@return TYPE DESCRIPTION` documents one result, in order.
//! `@since VERSION` and `@stability LEVEL` fill the fields of the same name
//! in the specification frontmatter. A line indented under an annotation
//! continues its description. Every other line is free Markdown text.
//!
//! The doc comment at the start of the main module of a package is its
//! package header (`spec/design/modules.md`, section 6). `@package NAME`,
//! `@version VERSION`, `@lus LINE`, `@license EXPR`, `@flag NAME TYPE
//! [DEFAULT] DESCRIPTION`, `@permission PLEDGE DESCRIPTION`, `@includes
//! NAME URL VERSION`, `@homepage URL`, and `@repository URL` fill its
//! `package` field.
//!
//! The language server shows the comment above a declaration on hover, so
//! the same comments serve the editor, `lus check`, and `lus doc`.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const Allocator = std.mem.Allocator;

pub const Param = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    optional: bool = false,
    description: []const u8 = "",
    /// Line of the annotation, for diagnostics.
    line: u32 = 0,
};

pub const Return = struct {
    type: []const u8,
    description: []const u8 = "",
};

/// A build flag that a package declares.
pub const Flag = struct {
    name: []const u8,
    /// `boolean`, `number`, `string`, or a list of strings such as
    /// `"fast"|"small"`.
    type: []const u8,
    /// The default as written, or null.
    default: ?[]const u8 = null,
    description: []const u8 = "",
    line: u32 = 0,
};

pub const Permission = struct {
    pledge: []const u8,
    description: []const u8 = "",
};

/// A dependency copied into a self-contained bundle.
pub const Include = struct {
    name: []const u8,
    url: []const u8,
    version: []const u8,
};

/// The package header of a main module.
pub const Package = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    lus: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    flags: []Flag = &.{},
    permissions: []Permission = &.{},
    includes: []Include = &.{},

    pub fn flag(p: Package, name: []const u8) ?Flag {
        for (p.flags) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

/// Whether `word` is a default for a flag of type `ty`: `true` or `false`
/// for a boolean, a numeral for a number, and a double-quoted string for a
/// string or a list of strings.
fn isFlagDefault(ty: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (std.mem.eql(u8, ty, "boolean")) return std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false");
    if (std.mem.eql(u8, ty, "number")) {
        _ = std.fmt.parseFloat(f64, word) catch return false;
        return true;
    }
    return word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"';
}

pub const Doc = struct {
    /// First and last line of the comment.
    line: u32,
    end_line: u32,
    /// The free Markdown text, without annotations.
    text: []const u8,
    params: []Param = &.{},
    returns: []Return = &.{},
    since: ?[]const u8 = null,
    stability: ?[]const u8 = null,
    /// The package header, when the comment holds a package annotation.
    package: ?Package = null,

    pub fn param(d: Doc, name: []const u8) ?Param {
        for (d.params) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

pub const Index = struct {
    src: []const u8,
    comments: []const lexer.Comment,

    pub fn init(chunk: ast.Chunk) Index {
        return .{ .src = chunk.source, .comments = chunk.comments };
    }

    fn endLine(ix: Index, c: lexer.Comment) u32 {
        const end = @min(c.span.end, ix.src.len);
        return c.line + @as(u32, @intCast(std.mem.count(u8, ix.src[@min(c.span.start, end)..end], "\n")));
    }

    /// True when only blanks precede the comment on its line.
    fn standalone(ix: Index, c: lexer.Comment) bool {
        var i = @min(c.span.start, ix.src.len);
        while (i > 0) {
            i -= 1;
            switch (ix.src[i]) {
                '\n' => return true,
                ' ', '\t', '\r' => {},
                else => return false,
            }
        }
        return true;
    }

    /// True for a `---` line comment. Longer runs of dashes are rules,
    /// not documentation.
    fn isDocLine(c: lexer.Comment) bool {
        return !c.long and c.text.len >= 1 and c.text[0] == '-' and (c.text.len == 1 or c.text[1] != '-');
    }

    fn isDocLong(c: lexer.Comment) bool {
        return c.long and c.text.len >= 1 and c.text[0] == '-';
    }

    /// The doc comment ending on the line above `line`, if any.
    pub fn before(ix: Index, arena: Allocator, line: u32) Allocator.Error!?Doc {
        if (line < 2) return null;
        // Comments are in source order, so the last one ending on the
        // previous line is the candidate.
        var k: ?usize = null;
        for (ix.comments, 0..) |c, i| {
            if (c.line >= line) break;
            if (ix.endLine(c) == line - 1) k = i;
        }
        const last = k orelse return null;
        return ix.blockEndingAt(arena, last);
    }

    /// The doc comment at the very start of the file, when it is followed
    /// by a blank line, so it describes the module rather than the first
    /// declaration.
    pub fn moduleDoc(ix: Index, arena: Allocator) Allocator.Error!?Doc {
        if (ix.comments.len == 0) return null;
        // Skip a shebang line: the lexer does not report it as a comment.
        const first_code_line = firstCodeLine(ix.src);
        if (ix.comments[0].line != first_code_line) return null;
        var last: usize = 0;
        if (isDocLine(ix.comments[0])) {
            while (last + 1 < ix.comments.len) {
                const c = ix.comments[last + 1];
                if (!isDocLine(c) or !ix.standalone(c) or c.line != ix.comments[last].line + 1) break;
                last += 1;
            }
        }
        const d = (try ix.blockEndingAt(arena, last)) orelse return null;
        if (d.line != first_code_line) return null;
        // The next line must be blank.
        if (!lineBlank(ix.src, d.end_line + 1)) return null;
        return d;
    }

    fn blockEndingAt(ix: Index, arena: Allocator, last: usize) Allocator.Error!?Doc {
        const c = ix.comments[last];
        if (!ix.standalone(c)) return null;
        var lines: std.ArrayList([]const u8) = .empty;
        var first_line = c.line;
        if (isDocLong(c)) {
            var it = std.mem.splitScalar(u8, c.text[1..], '\n');
            while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, " \t\r"));
            dedent(lines.items);
        } else if (isDocLine(c)) {
            var first = last;
            while (first > 0) {
                const p = ix.comments[first - 1];
                if (!isDocLine(p) or !ix.standalone(p) or p.line + 1 != ix.comments[first].line) break;
                first -= 1;
            }
            first_line = ix.comments[first].line;
            for (ix.comments[first .. last + 1]) |lc| {
                var t = std.mem.trimEnd(u8, lc.text[1..], " \t\r");
                if (t.len > 0 and t[0] == ' ') t = t[1..];
                try lines.append(arena, t);
            }
        } else return null;
        return try parse(arena, lines.items, first_line, ix.endLine(c));
    }
};

fn firstCodeLine(src: []const u8) u32 {
    return if (src.len > 0 and src[0] == '#') 2 else 1;
}

fn lineBlank(src: []const u8, line: u32) bool {
    var cur: u32 = 1;
    var i: usize = 0;
    while (i < src.len and cur < line) : (i += 1) {
        if (src[i] == '\n') cur += 1;
    }
    if (cur < line) return true; // past the end of the file
    while (i < src.len and src[i] != '\n') : (i += 1) {
        if (src[i] != ' ' and src[i] != '\t' and src[i] != '\r') return false;
    }
    return true;
}

/// Removes the indentation common to every non-blank line.
fn dedent(lines: [][]const u8) void {
    var common: usize = std.math.maxInt(usize);
    for (lines) |l| {
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        var n: usize = 0;
        while (n < l.len and (l[n] == ' ' or l[n] == '\t')) n += 1;
        common = @min(common, n);
    }
    if (common == std.math.maxInt(usize)) return;
    for (lines) |*l| l.* = if (l.len >= common) l.*[common..] else "";
}

const Tok = struct { word: []const u8, rest: []const u8 };

fn nextWord(s: []const u8) Tok {
    const t = std.mem.trimStart(u8, s, " \t");
    var i: usize = 0;
    while (i < t.len and t[i] != ' ' and t[i] != '\t') i += 1;
    return .{ .word = t[0..i], .rest = std.mem.trim(u8, t[i..], " \t") };
}

/// Parses the stripped lines of a doc comment.
pub fn parse(arena: Allocator, lines: []const []const u8, first_line: u32, end_line: u32) Allocator.Error!Doc {
    var text: std.ArrayList(u8) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var returns: std.ArrayList(Return) = .empty;
    var flags: std.ArrayList(Flag) = .empty;
    var perms: std.ArrayList(Permission) = .empty;
    var includes: std.ArrayList(Include) = .empty;
    var pkg: Package = .{};
    var has_pkg = false;
    var doc: Doc = .{ .line = first_line, .end_line = end_line, .text = "" };
    // The description a continuation line extends.
    const Last = enum { none, param, ret };
    var last: Last = .none;
    for (lines, 0..) |line, i| {
        const lno = first_line + @as(u32, @intCast(i));
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '@') {
            const tag = nextWord(trimmed);
            if (std.mem.eql(u8, tag.word, "@param")) {
                const name = nextWord(tag.rest);
                const ty = nextWord(name.rest);
                var p: Param = .{ .name = name.word, .line = lno };
                if (p.name.len > 1 and p.name[p.name.len - 1] == '?') {
                    p.name = p.name[0 .. p.name.len - 1];
                    p.optional = true;
                }
                // `...name` documents named variable arguments under the
                // name the declaration gives them.
                if (p.name.len > 3 and std.mem.startsWith(u8, p.name, "...")) p.name = p.name[3..];
                if (ty.word.len > 0) {
                    var t = ty.word;
                    if (t.len > 1 and t[t.len - 1] == '?') {
                        t = t[0 .. t.len - 1];
                        p.optional = true;
                    }
                    p.type = t;
                    p.description = ty.rest;
                }
                if (p.name.len > 0) {
                    try params.append(arena, p);
                    last = .param;
                    continue;
                }
            } else if (std.mem.eql(u8, tag.word, "@return") or std.mem.eql(u8, tag.word, "@returns")) {
                const ty = nextWord(tag.rest);
                if (ty.word.len > 0) {
                    try returns.append(arena, .{ .type = ty.word, .description = ty.rest });
                    last = .ret;
                    continue;
                }
            } else if (std.mem.eql(u8, tag.word, "@since")) {
                doc.since = nextWord(tag.rest).word;
                last = .none;
                continue;
            } else if (std.mem.eql(u8, tag.word, "@stability")) {
                doc.stability = nextWord(tag.rest).word;
                last = .none;
                continue;
            } else if (packageField(&pkg, tag.word)) |field| {
                field.* = nextWord(tag.rest).word;
                has_pkg = true;
                last = .none;
                continue;
            } else if (std.mem.eql(u8, tag.word, "@flag")) {
                const name = nextWord(tag.rest);
                const ty = nextWord(name.rest);
                var f: Flag = .{ .name = name.word, .type = ty.word, .line = lno, .description = ty.rest };
                const dflt = nextWord(ty.rest);
                if (isFlagDefault(ty.word, dflt.word)) {
                    f.default = dflt.word;
                    f.description = dflt.rest;
                }
                if (f.name.len > 0 and f.type.len > 0) {
                    try flags.append(arena, f);
                    has_pkg = true;
                    last = .none;
                    continue;
                }
            } else if (std.mem.eql(u8, tag.word, "@permission")) {
                const pl = nextWord(tag.rest);
                if (pl.word.len > 0) {
                    try perms.append(arena, .{ .pledge = pl.word, .description = pl.rest });
                    has_pkg = true;
                    last = .none;
                    continue;
                }
            } else if (std.mem.eql(u8, tag.word, "@includes")) {
                const name = nextWord(tag.rest);
                const url = nextWord(name.rest);
                const ver = nextWord(url.rest);
                if (ver.word.len > 0) {
                    try includes.append(arena, .{ .name = name.word, .url = url.word, .version = ver.word });
                    has_pkg = true;
                    last = .none;
                    continue;
                }
            }
        }
        // An indented line continues the previous annotation.
        if (last != .none and trimmed.len > 0 and trimmed.len < line.len) {
            const target: *[]const u8 = switch (last) {
                .param => &params.items[params.items.len - 1].description,
                .ret => &returns.items[returns.items.len - 1].description,
                .none => unreachable,
            };
            target.* = if (target.len == 0) trimmed else try std.fmt.allocPrint(arena, "{s} {s}", .{ target.*, trimmed });
            continue;
        }
        last = .none;
        if (text.items.len > 0) try text.append(arena, '\n');
        try text.appendSlice(arena, line);
    }
    doc.text = std.mem.trim(u8, text.items, " \t\n");
    doc.params = params.items;
    doc.returns = returns.items;
    if (has_pkg) {
        pkg.flags = flags.items;
        pkg.permissions = perms.items;
        pkg.includes = includes.items;
        doc.package = pkg;
    }
    return doc;
}

/// The field of the package header that a one-word annotation fills.
fn packageField(p: *Package, word: []const u8) ?*?[]const u8 {
    if (std.mem.eql(u8, word, "@package")) return &p.name;
    if (std.mem.eql(u8, word, "@version")) return &p.version;
    if (std.mem.eql(u8, word, "@lus")) return &p.lus;
    if (std.mem.eql(u8, word, "@license")) return &p.license;
    if (std.mem.eql(u8, word, "@homepage")) return &p.homepage;
    if (std.mem.eql(u8, word, "@repository")) return &p.repository;
    return null;
}

test "parse a package header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const lines = [_][]const u8{
        "Parses dates.",
        "@package dates",
        "@version 1.4.1",
        "@lus 2.0",
        "@license 0BSD",
        "@flag tzdata string Path of a time zone database.",
        "@flag strict boolean false Reject unknown fields.",
        "@flag mode \"fast\"|\"small\" \"fast\" The tradeoff.",
        "@permission fs:read=/usr/share/zoneinfo/* Reads the time zone database.",
        "@includes strings https://atmosp.here/2.0/strings.lus 1.0.0",
    };
    const d = try parse(arena_state.allocator(), &lines, 1, 10);
    try testing.expectEqualStrings("Parses dates.", d.text);
    const p = d.package.?;
    try testing.expectEqualStrings("dates", p.name.?);
    try testing.expectEqualStrings("2.0", p.lus.?);
    try testing.expectEqual(@as(usize, 3), p.flags.len);
    try testing.expect(p.flags[0].default == null);
    try testing.expectEqualStrings("Path of a time zone database.", p.flags[0].description);
    try testing.expectEqualStrings("false", p.flags[1].default.?);
    try testing.expectEqualStrings("\"fast\"", p.flags[2].default.?);
    try testing.expectEqualStrings("fs:read=/usr/share/zoneinfo/*", p.permissions[0].pledge);
    try testing.expectEqualStrings("1.0.0", p.includes[0].version);
}

const testing = std.testing;

test "parse doc annotations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const lines = [_][]const u8{
        "Adds two numbers.",
        "@param a number The first addend.",
        "@param b? number The second",
        "  addend.",
        "@return number The sum.",
        "",
        "More text.",
    };
    const d = try parse(arena_state.allocator(), &lines, 1, 7);
    try testing.expectEqualStrings("Adds two numbers.\n\nMore text.", d.text);
    try testing.expectEqual(@as(usize, 2), d.params.len);
    try testing.expect(d.params[1].optional);
    try testing.expectEqualStrings("The second addend.", d.params[1].description);
    try testing.expectEqualStrings("number", d.returns[0].type);
}

test "parse named variable arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const lines = [_][]const u8{
        "@param ...parts string The strings to join.",
        "@param ... any The rest.",
    };
    const d = try parse(arena_state.allocator(), &lines, 1, 2);
    try testing.expectEqualStrings("parts", d.params[0].name);
    try testing.expectEqualStrings("The strings to join.", d.params[0].description);
    try testing.expectEqualStrings("...", d.params[1].name);
}
