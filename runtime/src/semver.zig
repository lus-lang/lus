//! Version numbers of Lus releases and atmosphere packages, ordered as
//! Semantic Versioning 2.0.0 orders them (`spec/design/modules.md`).
//!
//! A version is `MAJOR.MINOR.PATCH`, optionally followed by `-` and a
//! prerelease label of dot-separated identifiers, such as
//! `2.1.0-unstable.7`. Build metadata after `+` is not accepted.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// The prerelease label without its `-`, or empty. Points into the
    /// parsed text.
    pre: []const u8 = "",

    /// Orders two versions by precedence.
    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        // A version without a prerelease label outranks one with a label.
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const xa = ia.next();
            const xb = ib.next();
            if (xa == null and xb == null) return .eq;
            if (xa == null) return .lt;
            if (xb == null) return .gt;
            const o = orderIdent(xa.?, xb.?);
            if (o != .eq) return o;
        }
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len > 0) try w.print("-{s}", .{v.pre});
    }
};

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Numeric identifiers compare numerically and rank below alphanumeric
/// ones, which compare by bytes.
fn orderIdent(a: []const u8, b: []const u8) std.math.Order {
    const na = isNumeric(a);
    const nb = isNumeric(b);
    if (na and nb) {
        if (a.len != b.len) return std.math.order(a.len, b.len);
        return std.mem.order(u8, a, b);
    }
    if (na) return .lt;
    if (nb) return .gt;
    return std.mem.order(u8, a, b);
}

/// Parses a decimal component without a leading zero.
fn component(s: []const u8) ?u32 {
    if (!isNumeric(s)) return null;
    if (s.len > 1 and s[0] == '0') return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn validPre(pre: []const u8) bool {
    if (pre.len == 0) return false;
    var it = std.mem.splitScalar(u8, pre, '.');
    while (it.next()) |id| {
        if (id.len == 0) return false;
        for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        if (isNumeric(id) and id.len > 1 and id[0] == '0') return false;
    }
    return true;
}

/// Parses a full version. Returns null for any other text.
pub fn parse(text: []const u8) ?Version {
    var core = text;
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        core = text[0..dash];
        pre = text[dash + 1 ..];
        if (!validPre(pre)) return null;
    }
    var it = std.mem.splitScalar(u8, core, '.');
    const ma = component(it.next() orelse return null) orelse return null;
    const mi = component(it.next() orelse return null) orelse return null;
    const pa = component(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .major = ma, .minor = mi, .patch = pa, .pre = pre };
}

/// A release line, `MAJOR.MINOR`.
pub const Line = struct {
    major: u32,
    minor: u32,
};

pub fn parseLine(text: []const u8) ?Line {
    var it = std.mem.splitScalar(u8, text, '.');
    const ma = component(it.next() orelse return null) orelse return null;
    const mi = component(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .major = ma, .minor = mi };
}

/// A version request of `lus version` and `lus +REQUEST`.
pub const Request = union(enum) {
    exact: Version,
    line: Line,
    major: u32,
    channel: Channel,

    /// Whether `v`, which belongs to `channel`, satisfies the request. A
    /// line or major request selects only versions without a prerelease
    /// label.
    pub fn matches(r: Request, v: Version, channel: ?Channel) bool {
        return switch (r) {
            .exact => |e| e.order(v) == .eq and std.mem.eql(u8, e.pre, v.pre),
            .line => |ln| v.pre.len == 0 and v.major == ln.major and v.minor == ln.minor,
            .major => |m| v.pre.len == 0 and v.major == m,
            .channel => |c| channel == c,
        };
    }
};

pub const Channel = enum {
    stable,
    unstable,

    pub fn parse(s: []const u8) ?Channel {
        return std.meta.stringToEnum(Channel, s);
    }
};

pub fn parseRequest(text: []const u8) ?Request {
    if (Channel.parse(text)) |c| return .{ .channel = c };
    if (parse(text)) |v| return .{ .exact = v };
    if (parseLine(text)) |l| return .{ .line = l };
    if (component(text)) |m| return .{ .major = m };
    return null;
}

/// The Lus version check of atmosphere release documents: a package for
/// line `lus` with oldest release `min` runs on `running` when the major
/// versions are equal, the running minor version is at least the line's,
/// and the running release is at least `min`.
pub fn runsOn(lus: Line, min: ?Version, running: Version) bool {
    if (running.major != lus.major) return false;
    if (running.minor < lus.minor) return false;
    if (min) |m| {
        // Compare the release numbers only, so a development build of a
        // release satisfies the minimum of that release.
        const r: Version = .{ .major = running.major, .minor = running.minor, .patch = running.patch };
        if (r.order(m) == .lt) return false;
    }
    return true;
}

test "parse and order" {
    const t = std.testing;
    try t.expect(parse("2.0.3") != null);
    try t.expect(parse("2.0") == null);
    try t.expect(parse("02.0.0") == null);
    try t.expect(parse("2.0.0-") == null);
    try t.expect(parse("2.0.0+meta") == null);
    const cases = [_][2][]const u8{
        .{ "2.0.0-unstable.2", "2.0.0-unstable.10" },
        .{ "2.0.0-unstable.10", "2.0.0" },
        .{ "2.0.0", "2.0.1" },
        .{ "2.0.9", "2.1.0" },
        .{ "1.0.0-alpha", "1.0.0-alpha.1" },
        .{ "1.0.0-1", "1.0.0-alpha" },
    };
    for (cases) |c| try t.expectEqual(std.math.Order.lt, parse(c[0]).?.order(parse(c[1]).?));
}

test "requests" {
    const t = std.testing;
    try t.expect(parseRequest("stable").? == .channel);
    try t.expect(parseRequest("2.0").? == .line);
    try t.expect(parseRequest("2").? == .major);
    try t.expect(parseRequest("2.0.3").? == .exact);
    try t.expect(parseRequest("two") == null);
    const r = parseRequest("2.0").?;
    try t.expect(r.matches(parse("2.0.5").?, .stable));
    try t.expect(!r.matches(parse("2.0.5-unstable.1").?, .unstable));
}

test "runs on" {
    const t = std.testing;
    const l = parseLine("2.0").?;
    try t.expect(runsOn(l, parse("2.0.0").?, parse("2.0.3").?));
    try t.expect(runsOn(l, parse("2.0.0").?, parse("2.1.0").?));
    try t.expect(!runsOn(l, parse("2.0.4").?, parse("2.0.3").?));
    try t.expect(!runsOn(parseLine("2.1").?, null, parse("2.0.3").?));
    try t.expect(!runsOn(l, null, parse("3.0.0").?));
}
