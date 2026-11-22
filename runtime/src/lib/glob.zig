//! File globs for `fs.list` and `fs.walk`. A glob is a list of segments
//! separated by `/`. In a segment, `*` matches any sequence of characters,
//! `?` matches one character, and `[abc]`, `[a-z]` and `[!abc]` match one
//! character of a class. A segment that is exactly `**` matches any number
//! of directories, including none. `{a,b}` expands to one glob for each
//! alternative before anything else, and braces nest. A `[` without its
//! `]` and a `{` without its `}` stand for themselves.
//!
//! Matching a path runs the segments as a small automaton over the path
//! segments, so a glob with several `**` takes time proportional to the
//! path times the glob. The glob matcher of pledge values in
//! `vm/pledge.zig` is a separate, simpler matcher.

const std = @import("std");

/// The most globs one pattern may expand to through braces.
pub const max_alternatives = 256;

pub const Error = error{ TooManyAlternatives, OutOfMemory };

const Seg = union(enum) {
    any_dirs,
    pat: []const u8,
};

pub const Glob = struct {
    arena: std.heap.ArenaAllocator,
    alts: []const []const Seg,
    /// Whether some alternative has more than one segment or a `**`, so that
    /// it can match paths below the directory it is applied to.
    deep: bool,

    pub fn deinit(g: *Glob) void {
        g.arena.deinit();
    }

    /// Whether the relative path `path`, with `/` between its segments,
    /// matches the glob.
    pub fn match(g: *const Glob, path: []const u8) bool {
        var buf: [256]bool = undefined;
        for (g.alts) |segs| {
            if (segs.len + 1 > buf.len) continue;
            if (run(segs, path, buf[0 .. segs.len + 1], false)) return true;
        }
        return false;
    }

    /// Whether some path below the directory `dir` (relative, `/` between
    /// segments, empty for the starting directory) can match the glob. A
    /// walk skips directories for which this is false.
    pub fn mayContain(g: *const Glob, dir: []const u8) bool {
        var buf: [256]bool = undefined;
        for (g.alts) |segs| {
            if (segs.len + 1 > buf.len) return true;
            if (run(segs, dir, buf[0 .. segs.len + 1], true)) return true;
        }
        return false;
    }
};

/// Compiles `pattern`. A leading `./` and empty segments are dropped.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8) Error!Glob {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var expanded: std.ArrayList([]const u8) = .empty;
    try expand(a, pattern, &expanded);
    const alts = try a.alloc([]const Seg, expanded.items.len);
    var deep = false;
    for (expanded.items, 0..) |p, i| {
        var segs: std.ArrayList(Seg) = .empty;
        var it = std.mem.splitScalar(u8, p, '/');
        var first = true;
        while (it.next()) |s| {
            defer first = false;
            if (s.len == 0) continue;
            if (first and std.mem.eql(u8, s, ".")) continue;
            if (std.mem.eql(u8, s, "**")) {
                // Consecutive `**` segments mean the same as one.
                if (segs.items.len > 0 and segs.items[segs.items.len - 1] == .any_dirs) continue;
                try segs.append(a, .any_dirs);
            } else try segs.append(a, .{ .pat = s });
        }
        if (segs.items.len > 1) deep = true;
        for (segs.items) |s| if (s == .any_dirs) {
            deep = true;
        };
        alts[i] = segs.items;
    }
    return .{ .arena = arena, .alts = alts, .deep = deep };
}

/// The index of the `]` that closes the class opened at `p[i]`, or null
/// when the class is not closed.
fn classEnd(p: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j < p.len and (p[j] == '!' or p[j] == '^')) j += 1;
    // A `]` right after the opening is a member of the class.
    if (j < p.len and p[j] == ']') j += 1;
    while (j < p.len) : (j += 1) if (p[j] == ']') return j;
    return null;
}

/// The index of the `}` that closes the group opened at `p[i]`, skipping
/// nested groups and classes, or null when the group is not closed.
fn braceEnd(p: []const u8, i: usize) ?usize {
    var depth: usize = 0;
    var j = i;
    while (j < p.len) : (j += 1) switch (p[j]) {
        '[' => if (classEnd(p, j)) |e| {
            j = e;
        },
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return j;
        },
        else => {},
    };
    return null;
}

/// Appends every brace expansion of `p` to `out`.
fn expand(a: std.mem.Allocator, p: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    var i: usize = 0;
    while (i < p.len) : (i += 1) switch (p[i]) {
        '[' => if (classEnd(p, i)) |e| {
            i = e;
        },
        '{' => if (braceEnd(p, i)) |e| {
            // Split the group at its top-level commas.
            var start = i + 1;
            var j = i + 1;
            var depth: usize = 0;
            while (j <= e) : (j += 1) {
                const c = if (j == e) ',' else p[j];
                switch (c) {
                    '[' => if (classEnd(p, j)) |ce| {
                        if (ce < e) j = ce;
                    },
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    ',' => if (depth == 0) {
                        const alt = try std.mem.concat(a, u8, &.{ p[0..i], p[start..j], p[e + 1 ..] });
                        try expand(a, alt, out);
                        if (out.items.len > max_alternatives) return error.TooManyAlternatives;
                        start = j + 1;
                    },
                    else => {},
                }
            }
            return;
        },
        else => {},
    };
    if (out.items.len >= max_alternatives) return error.TooManyAlternatives;
    try out.append(a, p);
}

/// Runs the automaton of `segs` over the segments of `path`. With `prefix`
/// set it reports whether a longer path could still match.
fn run(segs: []const Seg, path: []const u8, states: []bool, prefix: bool) bool {
    @memset(states, false);
    states[0] = true;
    close(segs, states);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        // Walk the positions downwards, so that a step from k to k + 1 is not
        // taken twice for one segment.
        var k = segs.len;
        var any = false;
        states[segs.len] = false;
        while (k > 0) {
            k -= 1;
            if (!states[k]) continue;
            switch (segs[k]) {
                .any_dirs => {}, // stays in k
                .pat => |pat| {
                    states[k] = false;
                    if (matchSegment(pat, name)) states[k + 1] = true;
                },
            }
        }
        close(segs, states);
        for (states) |s| any = any or s;
        if (!any) return false;
    }
    if (prefix) {
        // Some position before the end means a child can match.
        for (states[0..segs.len]) |s| if (s) return true;
        return false;
    }
    return states[segs.len];
}

/// Adds the positions reachable by skipping `**` segments.
fn close(segs: []const Seg, states: []bool) void {
    for (segs, 0..) |s, k| {
        if (states[k] and s == .any_dirs) states[k + 1] = true;
    }
}

fn charLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    return if (i + n <= s.len) n else 1;
}

fn codePoint(s: []const u8, i: usize) u21 {
    const n = charLen(s, i);
    if (n == 1) return s[i];
    return std.unicode.utf8Decode(s[i .. i + n]) catch s[i];
}

/// Whether the class `c`, the text between `[` and `]`, matches `cp`.
fn classMatch(c: []const u8, cp: u21) bool {
    var i: usize = 0;
    var negate = false;
    if (i < c.len and (c[i] == '!' or c[i] == '^')) {
        negate = true;
        i += 1;
    }
    var hit = false;
    while (i < c.len) {
        const lo = codePoint(c, i);
        i += charLen(c, i);
        if (i + 1 < c.len and c[i] == '-') {
            const hi = codePoint(c, i + 1);
            i += 1 + charLen(c, i + 1);
            if (cp >= lo and cp <= hi) hit = true;
        } else if (cp == lo) hit = true;
    }
    return hit != negate;
}

/// Whether the single segment pattern `p` matches the name `s`.
pub fn matchSegment(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < p.len) step: {
            switch (p[pi]) {
                '*' => {
                    star_p = pi;
                    star_s = si;
                    pi += 1;
                    continue;
                },
                '?' => {
                    pi += 1;
                    si += charLen(s, si);
                    continue;
                },
                '[' => if (classEnd(p, pi)) |e| {
                    if (!classMatch(p[pi + 1 .. e], codePoint(s, si))) break :step;
                    pi = e + 1;
                    si += charLen(s, si);
                    continue;
                },
                else => {},
            }
            if (p[pi] == s[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            star_s += charLen(s, star_s);
            si = star_s;
            pi = sp + 1;
            continue;
        }
        return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

fn testMatch(pattern: []const u8, path: []const u8) !bool {
    var g = try compile(std.testing.allocator, pattern);
    defer g.deinit();
    return g.match(path);
}

test "segments" {
    try std.testing.expect(matchSegment("*.lus", "a.lus"));
    try std.testing.expect(matchSegment("*", ".hidden"));
    try std.testing.expect(!matchSegment("*.lus", "a.lua"));
    try std.testing.expect(matchSegment("?.txt", "é.txt"));
    try std.testing.expect(matchSegment("[abc]x", "bx"));
    try std.testing.expect(!matchSegment("[!abc]x", "bx"));
    try std.testing.expect(matchSegment("[a-c]*", "cat"));
    try std.testing.expect(matchSegment("[]]", "]"));
    try std.testing.expect(matchSegment("[*]", "*"));
    try std.testing.expect(!matchSegment("[*]", "a"));
    try std.testing.expect(matchSegment("[éè]", "è"));
    try std.testing.expect(matchSegment("a[", "a["));
    try std.testing.expect(matchSegment("*a*b*c", "xaybzc"));
}

test "paths" {
    try std.testing.expect(try testMatch("**/*.lus", "a.lus"));
    try std.testing.expect(try testMatch("**/*.lus", "x/y/a.lus"));
    try std.testing.expect(!try testMatch("**/*.lus", "x/y/a.lua"));
    try std.testing.expect(try testMatch("src/**", "src/a/b"));
    try std.testing.expect(try testMatch("src/**", "src"));
    try std.testing.expect(try testMatch("a/**/b/**/c", "a/b/c"));
    try std.testing.expect(try testMatch("a/**/b/**/c", "a/x/b/y/z/c"));
    try std.testing.expect(!try testMatch("a/**/b/**/c", "a/x/c"));
    try std.testing.expect(try testMatch("*.{lus,md}", "x.md"));
    try std.testing.expect(try testMatch("{src,test}/**/*.lus", "test/a.lus"));
    try std.testing.expect(try testMatch("a{b,c{d,e}}", "ace"));
    try std.testing.expect(try testMatch("[{]", "{"));
    try std.testing.expect(try testMatch("a{b", "a{b"));
    try std.testing.expect(try testMatch("./x/*", "x/y"));
    try std.testing.expect(!try testMatch("*", "x/y"));
}

test "prefixes" {
    var g = try compile(std.testing.allocator, "src/**/*.lus");
    defer g.deinit();
    try std.testing.expect(g.deep);
    try std.testing.expect(g.mayContain(""));
    try std.testing.expect(g.mayContain("src"));
    try std.testing.expect(g.mayContain("src/a/b"));
    try std.testing.expect(!g.mayContain("test"));
    var h = try compile(std.testing.allocator, "*.lus");
    defer h.deinit();
    try std.testing.expect(!h.deep);
    try std.testing.expect(!h.mayContain("a"));
}

test "too many alternatives" {
    try std.testing.expectError(error.TooManyAlternatives, compile(std.testing.allocator, "{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}"));
}
