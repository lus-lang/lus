//! Pledge: the capability system (spec/design/pledge.md). Capabilities
//! are declared in a registry with a value kind. A permission set holds
//! grants and rejections and is shared between threads copy-on-write.

const std = @import("std");
const state = @import("state.zig");
const value = @import("value.zig");
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;
const Allocator = std.mem.Allocator;

pub const Kind = enum { none, path, host, pattern, custom };

pub const Matcher = *const fn (granted: []const u8, requested: []const u8) bool;

pub const Capability = struct {
    name: []const u8,
    subs: []const []const u8 = &.{},
    kind: Kind,
    match: ?Matcher = null,
};

/// Capabilities the runtime declares. Extensions add theirs with
/// `define`.
const builtin_caps = [_]Capability{
    .{ .name = "fs", .subs = &.{ "read", "write", "exec" }, .kind = .path },
    .{ .name = "network", .subs = &.{ "tcp", "udp", "http", "tls", "server" }, .kind = .host },
    .{ .name = "exec", .kind = .none },
    .{ .name = "env", .kind = .pattern },
    .{ .name = "load", .kind = .none },
    .{ .name = "ffi", .kind = .none },
    .{ .name = "worker", .kind = .none },
};

pub const Entry = struct {
    name: []u8,
    rejected: bool = false,
    /// Granted without a value restriction.
    unrestricted: bool = false,
    /// Granted value patterns, canonicalized for path capabilities.
    values: std.ArrayList([]u8) = .empty,
};

pub const Set = struct {
    refs: u32 = 1,
    sealed: bool = false,
    entries: std.ArrayList(Entry) = .empty,

    fn find(s: *Set, name: []const u8) ?*Entry {
        for (s.entries.items) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    fn clone(s: *Set, gpa: Allocator) !*Set {
        const n = try gpa.create(Set);
        n.* = .{ .sealed = s.sealed };
        for (s.entries.items) |e| {
            var ne: Entry = .{ .name = try gpa.dupe(u8, e.name), .rejected = e.rejected, .unrestricted = e.unrestricted };
            for (e.values.items) |v| try ne.values.append(gpa, try gpa.dupe(u8, v));
            try n.entries.append(gpa, ne);
        }
        return n;
    }

    fn destroy(s: *Set, gpa: Allocator) void {
        for (s.entries.items) |*e| {
            gpa.free(e.name);
            for (e.values.items) |v| gpa.free(v);
            e.values.deinit(gpa);
        }
        s.entries.deinit(gpa);
        gpa.destroy(s);
    }
};

/// Per-state pledge data: the registry and the ceiling set by the host.
const Registry = struct {
    caps: std.ArrayList(Capability) = .empty,
    /// When the host granted capabilities (`-P`), scripts may only pledge
    /// what the ceiling allows.
    ceiling: ?*Set = null,
};

fn registry(g: *Global) *Registry {
    if (g.ext.get("pledge.registry")) |p| return @ptrCast(@alignCast(p));
    const r = g.gpa.create(Registry) catch @panic("out of memory");
    r.* = .{};
    for (builtin_caps) |c| r.caps.append(g.gpa, c) catch @panic("out of memory");
    g.ext.put(g.gpa, "pledge.registry", r) catch @panic("out of memory");
    return r;
}

pub fn deinit(g: *Global) void {
    const p = g.ext.get("pledge.registry") orelse return;
    const r: *Registry = @ptrCast(@alignCast(p));
    if (r.ceiling) |c| c.destroy(g.gpa);
    r.caps.deinit(g.gpa);
    g.gpa.destroy(r);
}

/// Declares a capability. Extension modules call this once per state.
pub fn define(g: *Global, cap: Capability) !void {
    try registry(g).caps.append(g.gpa, cap);
}

fn findCap(g: *Global, base: []const u8) ?Capability {
    for (registry(g).caps.items) |c| if (std.mem.eql(u8, c.name, base)) return c;
    return null;
}

// ---------------------------------------------------------------------
// Thread sets

fn setOf(l: *Thread) ?*Set {
    const p = l.pledges orelse return null;
    return @ptrCast(@alignCast(p));
}

/// A writable set for `l`, cloning a shared one first.
fn writable(l: *Thread) Error!*Set {
    const gpa = l.g.gpa;
    if (setOf(l)) |s| {
        if (s.refs == 1) return s;
        const n = s.clone(gpa) catch return l.raiseMem();
        s.refs -= 1;
        l.pledges = n;
        return n;
    }
    const n = gpa.create(Set) catch return l.raiseMem();
    n.* = .{};
    l.pledges = n;
    return n;
}

/// Called when a thread is created from `parent`: shares its set.
pub fn inherit(child: *Thread, parent: *Thread) void {
    if (setOf(parent)) |s| {
        s.refs += 1;
        child.pledges = s;
    }
}

/// Called when a thread is freed.
pub fn release(l: *Thread) void {
    if (setOf(l)) |s| {
        s.refs -= 1;
        if (s.refs == 0) s.destroy(l.g.gpa);
        l.pledges = null;
    }
}

/// A sealed copy of the permission set of `l`, for a worker state. The
/// worker runs with its creator's permissions and can never grant itself
/// more. Sets are not shared across states, since each state frees its
/// own.
pub fn snapshot(l: *Thread) Allocator.Error!*anyopaque {
    const gpa = l.g.gpa;
    const n = if (setOf(l)) |s| try s.clone(gpa) else blk: {
        const n = try gpa.create(Set);
        n.* = .{};
        break :blk n;
    };
    n.sealed = true;
    return n;
}

/// Installs a set made by `snapshot` as the permissions of `l`.
pub fn adopt(l: *Thread, p: *anyopaque) void {
    release(l);
    l.pledges = p;
}

/// Frees a set made by `snapshot` that was never adopted.
pub fn discard(gpa: Allocator, p: *anyopaque) void {
    const s: *Set = @ptrCast(@alignCast(p));
    s.destroy(gpa);
}

// ---------------------------------------------------------------------
// Matching

/// Glob match where `*` matches any sequence (slashes included) and `?`
/// one byte. Greedy with single-star backtracking: O(|s| * |p|) worst
/// case, never exponential.
pub fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_i = i;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_i += 1;
            i = star_i;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn skipScheme(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "http://")) return url[7..];
    if (std.mem.startsWith(u8, url, "https://")) return url[8..];
    return url;
}

/// Matches a `host` capability value. A granted value without a scheme is
/// `host[:port][/path]`. Its host part is matched against the host of the
/// requested value (a URL or `host:port`), and against the whole authority
/// when the granted value names a port. A path in the granted value is
/// matched against the requested path. A granted value with a scheme is
/// matched against the whole requested URL. Anchoring the match on the
/// host keeps a grant such as `example.com` from matching a different
/// host like `example.com.attacker.test`.
pub fn hostMatch(granted: []const u8, requested: []const u8) bool {
    if (std.mem.startsWith(u8, granted, "http://") or std.mem.startsWith(u8, granted, "https://"))
        return globMatch(granted, requested);
    const rest = skipScheme(requested);
    const auth_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..auth_end];
    const host = authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len];
    const slash = std.mem.indexOfScalar(u8, granted, '/');
    const g_auth = granted[0 .. slash orelse granted.len];
    const subject = if (std.mem.indexOfScalar(u8, g_auth, ':') != null) authority else host;
    // Authorities longer than any valid host name never match.
    if (g_auth.len >= 256 or subject.len >= 256) return false;
    if (!globMatch(g_auth, subject)) return false;
    if (slash) |sl| {
        var path = rest[auth_end..];
        if (path.len == 0 or path[0] == '?') path = "/";
        return globMatch(granted[sl..], path);
    }
    return true;
}

/// Canonical absolute path: realpath when the file exists, otherwise the
/// realpath of its parent plus the final component. Returns null when the
/// path cannot be resolved (which callers treat as denied).
pub fn canonicalize(g: *Global, path: []const u8) ?[]u8 {
    const io = g.io;
    const gpa = g.gpa;
    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, path, gpa)) |r| {
        defer gpa.free(r);
        return gpa.dupe(u8, r) catch null;
    } else |_| {}
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent = if (slash) |sl| (if (sl == 0) "/" else path[0..sl]) else ".";
    const base = if (slash) |sl| path[sl + 1 ..] else path;
    const rp = cwd.realPathFileAlloc(io, parent, gpa) catch return null;
    defer gpa.free(rp);
    return std.fs.path.join(gpa, &.{ rp, base }) catch null;
}

/// Canonicalizes a granted path pattern. The directory part before the
/// first wildcard (or the whole path without one) resolves through its
/// deepest existing ancestor, so a grant made before its directory exists
/// stays attached to the right place.
fn canonicalPattern(g: *Global, pattern: []const u8) []u8 {
    const gpa = g.gpa;
    if (pattern.len == 0 or (pattern[0] != '/' and pattern[0] != '.')) return gpa.dupe(u8, pattern) catch @panic("oom");
    const wild = std.mem.indexOfAny(u8, pattern, "*?") orelse pattern.len;
    // Split at the last separator before the first wildcard.
    const head = pattern[0..wild];
    var cut = std.mem.lastIndexOfScalar(u8, head, '/') orelse return gpa.dupe(u8, pattern) catch @panic("oom");
    if (wild == pattern.len) cut = pattern.len; // no wildcard: resolve it all
    var dir_end = cut;
    while (true) {
        const dir = if (dir_end == 0) "/" else pattern[0..dir_end];
        if (std.Io.Dir.cwd().realPathFileAlloc(g.io, dir, gpa)) |rp| {
            defer gpa.free(rp);
            const rest = pattern[dir_end..];
            if (rest.len > 0 and rest[0] != '/') return std.mem.concat(gpa, u8, &.{ rp, "/", rest }) catch @panic("oom");
            return std.mem.concat(gpa, u8, &.{ rp, rest }) catch @panic("oom");
        } else |_| {}
        const up = std.mem.lastIndexOfScalar(u8, pattern[0..dir_end], '/') orelse return gpa.dupe(u8, pattern) catch @panic("oom");
        if (up == dir_end) return gpa.dupe(u8, pattern) catch @panic("oom");
        dir_end = up;
        if (dir_end == 0) dir_end = 0;
    }
}

fn valueMatches(cap: Capability, granted: []const u8, requested: []const u8, canon_req: ?[]const u8) bool {
    return switch (cap.kind) {
        .none => true,
        .path => if (canon_req) |c| globMatch(granted, c) else false,
        .host => hostMatch(granted, requested),
        .pattern => globMatch(granted, requested),
        .custom => if (cap.match) |m| m(granted, requested) else false,
    };
}

fn split(spec: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, spec, ':')) |c| return .{ spec[0..c], spec[c + 1 ..] };
    return .{ spec, "" };
}

/// Whether set `s` allows `perm` (e.g. "fs:read") for `requested` (or for
/// any value when null).
fn setAllows(g: *Global, s: *Set, perm: []const u8, requested: ?[]const u8) bool {
    const parts = split(perm);
    const base = parts[0];
    const cap = findCap(g, base) orelse return false;
    if (s.find(perm)) |e| if (e.rejected) return false;
    if (s.find(base)) |e| if (e.rejected) return false;
    var canon: ?[]u8 = null;
    defer if (canon) |c| g.gpa.free(c);
    if (cap.kind == .path) {
        if (requested) |r| canon = canonicalize(g, r);
    }
    const candidates = [_][]const u8{ perm, base };
    for (candidates, 0..) |name, ci| {
        if (ci == 1 and std.mem.eql(u8, perm, base)) break;
        const e = s.find(name) orelse continue;
        if (e.unrestricted) return true;
        const req = requested orelse {
            // A value-restricted grant allows checks that name no value.
            if (e.values.items.len > 0) return true;
            continue;
        };
        for (e.values.items) |v| if (valueMatches(cap, v, req, canon)) return true;
        // A specific sub-permission entry decides on its own.
        if (ci == 0) return false;
    }
    if (s.find("all")) |e| if (e.unrestricted) return true;
    return false;
}

/// Non-raising check.
pub fn allowed(l: *Thread, perm: []const u8, requested: ?[]const u8) bool {
    const s = setOf(l) orelse return false;
    return setAllows(l.g, s, perm, requested);
}

/// Raising check with the standard message.
pub fn require(l: *Thread, perm: []const u8, requested: ?[]const u8) Error!void {
    if (allowed(l, perm, requested)) return;
    if (requested) |r| return l.raiseFmt("permission \"{s}\" denied for '{s}'", .{ perm, r });
    return l.raiseFmt("permission \"{s}\" denied", .{perm});
}

// ---------------------------------------------------------------------
// Granting

pub const GrantResult = enum { granted, refused };

/// Applies one pledge string: "name[:sub][=value]", "~name", or "seal".
pub fn apply(l: *Thread, spec: []const u8, from_host: bool) Error!GrantResult {
    const g = l.g;
    const gpa = g.gpa;
    var s_spec = spec;
    var reject = false;
    if (s_spec.len > 0 and s_spec[0] == '~') {
        reject = true;
        s_spec = s_spec[1..];
    }
    var name = s_spec;
    var val: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, s_spec, '=')) |eq| {
        name = s_spec[0..eq];
        val = s_spec[eq + 1 ..];
        if (val.?.len == 0) val = null;
    }
    if (name.len >= 64) return l.raiseFmt("permission name too long: '{s}'", .{spec});
    if (std.mem.eql(u8, name, "seal")) {
        const set = try writable(l);
        set.sealed = true;
        return .granted;
    }
    if (std.mem.eql(u8, name, "all")) {
        if (!from_host) return l.raiseFmt("permission \"all\" cannot be requested from scripts", .{});
    } else {
        const parts = split(name);
        const cap = findCap(g, parts[0]) orelse return l.raiseFmt("unknown permission: '{s}'", .{name});
        if (std.mem.indexOfScalar(u8, name, ':') != null) {
            var ok = false;
            for (cap.subs) |sub| if (std.mem.eql(u8, sub, parts[1])) {
                ok = true;
            };
            if (!ok) return l.raiseFmt("invalid {s} subpermission '{s}'", .{ parts[0], parts[1] });
        }
        if (cap.kind == .path) if (val) |v| {
            if (v[0] != '/' and v[0] != '.') return l.raiseFmt("filesystem permission values must be an absolute path or start with '.' (got '{s}')", .{v});
        };
    }
    if (setOf(l)) |s| if (s.sealed) return .refused;
    if (!reject) {
        if (setOf(l)) |s| if (s.find(name)) |e| if (e.rejected) return l.raiseFmt("permission \"{s}\" was rejected", .{name});
        // The host ceiling bounds what scripts may grant.
        if (!from_host) {
            if (registry(g).ceiling) |ceil| {
                if (!setAllows(g, ceil, name, val)) return .refused;
            }
        }
    }
    const set = try writable(l);
    const e = set.find(name) orelse blk: {
        set.entries.append(gpa, .{ .name = gpa.dupe(u8, name) catch return l.raiseMem() }) catch return l.raiseMem();
        break :blk &set.entries.items[set.entries.items.len - 1];
    };
    if (reject) {
        e.rejected = true;
        return .granted;
    }
    if (val == null and e.values.items.len > 0) {
        // A valueless re-pledge keeps an existing scoped grant as it is.
        return .granted;
    }
    if (val) |v| {
        const cap = findCap(g, split(name)[0]);
        const stored = if (cap != null and cap.?.kind == .path) canonicalPattern(g, v) else gpa.dupe(u8, v) catch return l.raiseMem();
        e.values.append(gpa, stored) catch return l.raiseMem();
    } else e.unrestricted = true;
    return .granted;
}

/// Host grants from the command line: applied to the main thread and
/// recorded as the ceiling for script pledges.
pub fn hostGrant(l: *Thread, specs: []const []const u8) Error!void {
    if (specs.len == 0) return;
    for (specs) |spec| _ = try apply(l, spec, true);
    const s = setOf(l).?;
    const r = registry(l.g);
    r.ceiling = s.clone(l.g.gpa) catch return l.raiseMem();
}

test "host" {
    try std.testing.expect(hostMatch("example.com", "https://example.com/a"));
    try std.testing.expect(hostMatch("example.com", "example.com:443"));
    try std.testing.expect(!hostMatch("example.com", "example.com.attacker.test:80"));
    try std.testing.expect(!hostMatch("example.com", "http://example.com.attacker.test/"));
    try std.testing.expect(hostMatch("*.example.com", "http://api.example.com/x"));
    try std.testing.expect(!hostMatch("*.example.com", "http://example.com/x"));
    try std.testing.expect(hostMatch("127.0.0.1:8080", "127.0.0.1:8080"));
    try std.testing.expect(!hostMatch("127.0.0.1:8080", "127.0.0.1:9090"));
    try std.testing.expect(hostMatch("example.com/api/*", "https://example.com/api/v1"));
    try std.testing.expect(!hostMatch("example.com/api/*", "https://example.com/other"));
    try std.testing.expect(hostMatch("example.com/", "https://example.com"));
    try std.testing.expect(hostMatch("https://example.com/*", "https://example.com/x"));
    try std.testing.expect(!hostMatch("https://example.com/*", "http://example.com/x"));
}

test "glob" {
    try std.testing.expect(globMatch("/tmp/*", "/tmp/a/b.txt"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("/tmp/*.lus", "/tmp/a.txt"));
    try std.testing.expect(globMatch("*", ""));
}
