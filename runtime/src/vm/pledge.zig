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

pub const Kind = enum { none, path, host, pattern, custom, program };

/// A requested value of a `program` capability: the name of the program as
/// the caller wrote it, empty when it holds a separator, then a zero byte,
/// then the absolute path it resolved to. A granted value without a
/// separator is a glob over the written name, and one with a separator is
/// a path glob over the resolved path.
pub fn programRequest(gpa: Allocator, written: ?[]const u8, resolved: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ written orelse "", "\x00", resolved });
}

fn hasSeparator(v: []const u8) bool {
    return std.mem.indexOfScalar(u8, v, '/') != null or (host_rules.windows and std.mem.indexOfScalar(u8, v, '\\') != null);
}

/// Decides whether a granted value covers a requested value for a
/// `custom` capability. `ctx` is the context given at registration.
pub const Matcher = *const fn (ctx: ?*anyopaque, granted: []const u8, requested: []const u8) bool;

pub const Capability = struct {
    name: []const u8,
    subs: []const []const u8 = &.{},
    kind: Kind,
    match: ?Matcher = null,
    ctx: ?*anyopaque = null,
    /// Set when the registry owns `name` and `subs` and frees them with
    /// the state.
    owned: bool = false,
};

/// A host hook that decides script pledges the host has neither granted
/// nor rejected. It receives the capability name (such as "fs:read") and
/// the requested value, and returns whether to allow the grant.
pub const RequestHook = struct {
    func: *const fn (ctx: ?*anyopaque, l: *Thread, name: []const u8, val: ?[]const u8) bool,
    ctx: ?*anyopaque = null,
};

/// Capabilities the runtime declares. Extensions add theirs with
/// `define`.
const builtin_caps = [_]Capability{
    .{ .name = "fs", .subs = &.{ "read", "write", "exec" }, .kind = .path },
    .{ .name = "network", .subs = &.{ "tcp", "udp", "http", "tls", "server" }, .kind = .host },
    .{ .name = "exec", .kind = .program },
    .{ .name = "env", .subs = &.{ "read", "write" }, .kind = .pattern },
    .{ .name = "load", .kind = .none },
    .{ .name = "ffi", .kind = .none },
    .{ .name = "worker", .kind = .none },
    .{ .name = "debug", .kind = .none },
    .{ .name = bytecode, .kind = .none },
};

/// The permission to load a binary chunk. The loader trusts a binary
/// chunk as it trusts the compiler, so only the host grants it, on the
/// command line or through the embedding interface. `pledge` refuses it.
/// The grant sets no ceiling and leaves a fresh state fresh, so it changes
/// nothing else about what a script may pledge.
pub const bytecode = "bytecode";

fn isBytecode(name: []const u8) bool {
    return std.mem.eql(u8, name, bytecode);
}

pub const Entry = struct {
    name: []u8,
    rejected: bool = false,
    /// Granted without a value restriction.
    unrestricted: bool = false,
    /// Granted value patterns, canonicalized for path capabilities. A path
    /// grant resolves through symbolic links when it is made, so it stays
    /// bound to what it named at that moment.
    values: std.ArrayList([]u8) = .empty,
    /// For path capabilities, each grant with only its directory resolved.
    /// Operations on a link itself (removing or inspecting it) match these.
    link_values: std.ArrayList([]u8) = .empty,
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
        // A copy that runs out of memory frees what it built so far.
        errdefer n.destroy(gpa);
        try n.entries.ensureTotalCapacity(gpa, s.entries.items.len);
        for (s.entries.items) |e| {
            n.entries.appendAssumeCapacity(.{ .name = &.{}, .rejected = e.rejected, .unrestricted = e.unrestricted });
            const ne = &n.entries.items[n.entries.items.len - 1];
            ne.name = try gpa.dupe(u8, e.name);
            try ne.values.ensureTotalCapacity(gpa, e.values.items.len);
            for (e.values.items) |v| ne.values.appendAssumeCapacity(try gpa.dupe(u8, v));
            try ne.link_values.ensureTotalCapacity(gpa, e.link_values.items.len);
            for (e.link_values.items) |v| ne.link_values.appendAssumeCapacity(try gpa.dupe(u8, v));
        }
        return n;
    }

    fn destroy(s: *Set, gpa: Allocator) void {
        for (s.entries.items) |*e| {
            gpa.free(e.name);
            for (e.values.items) |v| gpa.free(v);
            e.values.deinit(gpa);
            for (e.link_values.items) |v| gpa.free(v);
            e.link_values.deinit(gpa);
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
    on_request: ?RequestHook = null,
    /// The permission set a finalizer runs with, for each object whose
    /// `__gc` was registered by a thread that held another set than the
    /// main thread. Each entry holds a reference to its set.
    finalizer_sets: std.AutoHashMapUnmanaged(*anyopaque, ?*Set) = .empty,
};

/// The capability registry of a state. `openAll` creates it with
/// `prepare`, so a state with its libraries open never allocates here.
fn registry(g: *Global) *Registry {
    return prepare(g) catch @panic("out of memory");
}

/// Creates the capability registry of a state, or returns the one it has.
pub fn prepare(g: *Global) error{OutOfMemory}!*Registry {
    if (g.ext.get("pledge.registry")) |p| return @ptrCast(@alignCast(p));
    try g.ext.ensureUnusedCapacity(g.gpa, 1);
    const r = try g.gpa.create(Registry);
    r.* = .{};
    r.caps.appendSlice(g.gpa, &builtin_caps) catch |e| {
        g.gpa.destroy(r);
        return e;
    };
    g.ext.putAssumeCapacity("pledge.registry", r);
    return r;
}

pub fn deinit(g: *Global) void {
    const p = g.ext.get("pledge.registry") orelse return;
    const r: *Registry = @ptrCast(@alignCast(p));
    if (r.ceiling) |c| c.destroy(g.gpa);
    var fin = r.finalizer_sets.valueIterator();
    while (fin.next()) |v| dropSet(g, v.*);
    r.finalizer_sets.deinit(g.gpa);
    for (r.caps.items) |c| if (c.owned) {
        for (c.subs) |sub| g.gpa.free(sub);
        g.gpa.free(c.subs);
        g.gpa.free(c.name);
    };
    r.caps.deinit(g.gpa);
    g.gpa.destroy(r);
}

/// Declares a capability. Extension modules call this once per state.
pub fn define(g: *Global, cap: Capability) !void {
    try (try prepare(g)).caps.append(g.gpa, cap);
}

/// Whether a capability named `base` is declared.
pub fn isDefined(g: *Global, base: []const u8) bool {
    return findCap(g, base) != null;
}

/// Installs the host request hook, or removes it when null.
pub fn setRequestHook(g: *Global, hook: ?RequestHook) void {
    registry(g).on_request = hook;
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

fn dropSet(g: *Global, set: ?*Set) void {
    const s = set orelse return;
    s.refs -= 1;
    if (s.refs == 0) s.destroy(g.gpa);
}

/// Records the permission set of `l` for the finalizer of `obj`, so the
/// finalizer runs with the permissions of the code that registered it,
/// whichever thread collects. Every registration records its set, since
/// the thread that collects may hold another set by then, and a
/// finalizer that runs on the main thread registers under the set it was
/// given for that run.
pub fn noteFinalizer(l: *Thread, obj: *anyopaque) Error!void {
    const g = l.g;
    const r = registry(g);
    const gop = r.finalizer_sets.getOrPut(g.gpa, obj) catch return l.raiseMem();
    if (gop.found_existing) dropSet(g, gop.value_ptr.*);
    gop.value_ptr.* = setOf(l);
    if (setOf(l)) |s| s.refs += 1;
}

/// What `beginFinalizer` hands to `endFinalizer`.
pub const FinalizerScope = struct { swapped: bool = false, saved: ?*anyopaque = null };

/// Gives `l` the permission set recorded for the finalizer of `obj`, if
/// there is one, and forgets the record.
pub fn beginFinalizer(l: *Thread, obj: *anyopaque) FinalizerScope {
    const p = l.g.ext.get("pledge.registry") orelse return .{};
    const r: *Registry = @ptrCast(@alignCast(p));
    if (r.finalizer_sets.count() == 0) return .{};
    const kv = r.finalizer_sets.fetchRemove(obj) orelse return .{};
    const saved = l.pledges;
    // The reference of the record becomes the reference of the thread.
    l.pledges = if (kv.value) |s| s else null;
    return .{ .swapped = true, .saved = saved };
}

/// Gives `l` its own permission set back.
pub fn endFinalizer(l: *Thread, scope: FinalizerScope) void {
    if (!scope.swapped) return;
    release(l);
    l.pledges = scope.saved;
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

/// Saves the permission set of `l`. Sets are copy on write, so later
/// changes on `l` leave the saved set as it was.
pub fn save(l: *Thread) ?*anyopaque {
    const s = setOf(l) orelse return null;
    s.refs += 1;
    return s;
}

/// Puts back a set taken by `save`, dropping the one `l` holds now.
pub fn restore(l: *Thread, saved: ?*anyopaque) void {
    release(l);
    l.pledges = saved;
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
/// own. The copy belongs to no state yet, so it is made with the parent
/// allocator, which `discard` frees it with.
pub fn snapshot(l: *Thread) Allocator.Error!*anyopaque {
    const gpa = l.g.parent_gpa;
    const n = if (setOf(l)) |s| try s.clone(gpa) else blk: {
        const n = try gpa.create(Set);
        n.* = .{};
        break :blk n;
    };
    n.sealed = true;
    return n;
}

/// Installs a copy of a set made by `snapshot` as the permissions of `l`,
/// made with the allocator of `l` so that its bytes count toward that
/// state, and frees the snapshot with `parent`. On failure the snapshot is
/// left as it was.
pub fn adopt(l: *Thread, p: *anyopaque, parent: Allocator) Allocator.Error!void {
    const s: *Set = @ptrCast(@alignCast(p));
    const own = try s.clone(l.g.gpa);
    s.destroy(parent);
    release(l);
    l.pledges = own;
}

/// Limits a fresh state to the permissions that `src` holds now, or to
/// none: `l` starts with a copy of the set of `src`, and its scripts may
/// pledge only what that set covers. The meta state of a compilation is
/// limited this way (`spec/design/meta.md`). Sets are copied, since each
/// state frees its own.
pub fn limitTo(l: *Thread, src: ?*Thread) error{OutOfMemory}!void {
    const gpa = l.g.gpa;
    const r = try prepare(l.g);
    const from: ?*Set = if (src) |s| setOf(s) else null;
    const ceil = if (from) |f| try f.clone(gpa) else blk: {
        const n = try gpa.create(Set);
        n.* = .{};
        break :blk n;
    };
    if (r.ceiling) |old| old.destroy(gpa);
    r.ceiling = ceil;
    if (from) |f| {
        const own = try f.clone(gpa);
        release(l);
        l.pledges = own;
    }
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
    return globMatchCase(pattern, s, false);
}

/// `globMatch`, comparing ASCII letters without regard to case when `fold`
/// is set.
pub fn globMatchCase(pattern: []const u8, s: []const u8, fold: bool) bool {
    return globCore(pattern, s, .{ .fold = fold });
}

/// `globMatchCase` for a path. `*` and `?` match inside one component, so
/// neither matches `/`, and `**` matches any run of characters, `/`
/// included. `/data/*` covers the files of `/data`, and `/data/**` covers
/// everything below it.
pub fn pathGlobMatch(pattern: []const u8, s: []const u8, fold: bool) bool {
    return globCore(pattern, s, .{ .fold = fold, .components = true });
}

const GlobOptions = struct {
    /// ASCII letters compare without regard to case.
    fold: bool = false,
    /// The path rules: `*` and `?` stay inside a component, `**` spans.
    components: bool = false,
    /// The subject is a pattern too, and the question is whether the
    /// pattern matches every string that the subject matches.
    covers: bool = false,
};

const GlobToken = struct {
    kind: enum { literal, one, run, span },
    char: u8 = 0,
    len: usize = 1,
};

/// The token at `i` of `text`. Outside the path rules `*` is a span.
fn globToken(text: []const u8, i: usize, is_pattern: bool, components: bool) GlobToken {
    const c = text[i];
    if (is_pattern and c == '*') {
        if (!components) return .{ .kind = .span };
        if (i + 1 < text.len and text[i + 1] == '*') return .{ .kind = .span, .len = 2 };
        return .{ .kind = .run };
    }
    if (is_pattern and c == '?') return .{ .kind = .one };
    return .{ .kind = .literal, .char = c };
}

/// Whether a `*` of the path rules takes the subject token `t`.
fn runTakes(t: GlobToken) bool {
    return switch (t.kind) {
        .literal => t.char != '/',
        .one, .run => true,
        .span => false,
    };
}

/// The matcher behind every glob of a permission value. It walks the
/// pattern and the subject once and returns to the last `*`, or to the
/// last `**`, when a later part fails.
fn globCore(pattern: []const u8, subject: []const u8, o: GlobOptions) bool {
    var p: usize = 0;
    var i: usize = 0;
    var run_p: ?usize = null;
    var run_i: usize = 0;
    var span_p: ?usize = null;
    var span_i: usize = 0;
    while (i < subject.len) {
        const st = globToken(subject, i, o.covers, o.components);
        if (p < pattern.len) {
            const pt = globToken(pattern, p, true, o.components);
            switch (pt.kind) {
                .span => {
                    span_p = p + pt.len;
                    span_i = i;
                    run_p = null;
                    p += pt.len;
                    continue;
                },
                .run => {
                    run_p = p + 1;
                    run_i = i;
                    p += 1;
                    continue;
                },
                .one => if (st.kind == .one or (st.kind == .literal and !(o.components and st.char == '/'))) {
                    p += 1;
                    i += st.len;
                    continue;
                },
                .literal => if (st.kind == .literal and (pt.char == st.char or
                    (o.fold and std.ascii.toLower(pt.char) == std.ascii.toLower(st.char))))
                {
                    p += 1;
                    i += st.len;
                    continue;
                },
            }
        }
        if (run_p) |rp| {
            const t = globToken(subject, run_i, o.covers, o.components);
            if (runTakes(t)) {
                run_i += t.len;
                i = run_i;
                p = rp;
                continue;
            }
            run_p = null;
        }
        if (span_p) |sp| {
            span_i += globToken(subject, span_i, o.covers, o.components).len;
            i = span_i;
            p = sp;
            continue;
        }
        return false;
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
/// matched against the requested path under the rules of `pathGlobMatch`.
/// A granted value with a scheme is matched the same way against a
/// request of that scheme. Anchoring the match on the
/// host keeps a grant such as `example.com` from matching a different
/// host like `example.com.attacker.test`.
pub fn hostMatch(granted: []const u8, requested: []const u8) bool {
    // A granted value with a scheme covers requests of that scheme only.
    if (schemeLen(granted)) |n| {
        if (!std.mem.startsWith(u8, requested, granted[0..n])) return false;
        return hostPartsMatch(granted[n..], requested[n..]);
    }
    return hostPartsMatch(granted, skipScheme(requested));
}

fn schemeLen(v: []const u8) ?usize {
    if (std.mem.startsWith(u8, v, "http://")) return 7;
    if (std.mem.startsWith(u8, v, "https://")) return 8;
    return null;
}

fn hostPartsMatch(granted: []const u8, rest: []const u8) bool {
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
        // A server may resolve `.` and `..` before it routes a request,
        // so a path with such a segment names no path that a grant can
        // be compared with.
        if (hasDotSegment(path)) return false;
        return pathGlobMatch(granted[sl..], path, false);
    }
    return true;
}

/// Whether the path of a request target has a `.` or `..` segment, written
/// plainly or with `%2e`.
fn hasDotSegment(target: []const u8) bool {
    const path = target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
    // An encoded separator and a backslash are separators to some servers,
    // so a path under a grant with a path holds neither.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    for ([_][]const u8{ "%2f", "%2F", "%5c", "%5C" }) |enc| {
        if (std.mem.indexOf(u8, path, enc) != null) return true;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        var dots: usize = 0;
        var i: usize = 0;
        var only_dots = seg.len > 0;
        while (i < seg.len) {
            if (seg[i] == '.') {
                i += 1;
            } else if (i + 2 < seg.len and seg[i] == '%' and seg[i + 1] == '2' and (seg[i + 2] == 'e' or seg[i + 2] == 'E')) {
                i += 3;
            } else {
                only_dots = false;
                break;
            }
            dots += 1;
        }
        if (only_dots and dots <= 2) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// Paths

/// The path rules of a file system. Canonical paths use `/` as their only
/// separator under both rules. Windows paths also accept `\` on input,
/// start with a drive (`C:/`) or a UNC share (`//server/share/`), and
/// match without regard to ASCII case, as NTFS does by default. The rules
/// are a parameter so the unit tests cover both on every host.
pub const PathRules = struct {
    windows: bool,

    pub const posix: PathRules = .{ .windows = false };
    pub const win: PathRules = .{ .windows = true };
};

/// The rules of the file system the runtime runs on.
pub const host_rules: PathRules = .{ .windows = @import("builtin").os.tag == .windows };

/// Whether `v` is a valid value for a path capability: an absolute path,
/// or a path that starts with `.` and resolves against the working
/// directory.
pub fn isPathValue(v: []const u8, rules: PathRules) bool {
    if (v.len == 0) return false;
    if (v[0] == '/' or v[0] == '.') return true;
    if (!rules.windows) return false;
    if (v[0] == '\\') return true;
    return v.len >= 3 and std.ascii.isAlphabetic(v[0]) and v[1] == ':' and (v[2] == '/' or v[2] == '\\');
}

/// A copy of `path` with every separator written as `/`.
pub fn normalizeSeparators(gpa: Allocator, path: []const u8, rules: PathRules) Allocator.Error![]u8 {
    const r = try gpa.dupe(u8, path);
    if (rules.windows) std.mem.replaceScalar(u8, r, '\\', '/');
    return r;
}

/// The length of the root of a path whose separators are `/`: the leading
/// slash, a drive with its slash (`C:/`), or a UNC share with its slash
/// (`//server/share/`). Zero for a relative path.
pub fn rootLen(p: []const u8, rules: PathRules) usize {
    if (rules.windows) {
        if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':')
            return if (p.len >= 3 and p[2] == '/') 3 else 2;
        if (p.len >= 2 and p[0] == '/' and p[1] == '/') {
            var i: usize = 2;
            // The server name, then the share name, each with its slash.
            for (0..2) |_| {
                while (i < p.len and p[i] != '/') i += 1;
                if (i < p.len) i += 1;
            }
            return i;
        }
    }
    return if (p.len > 0 and p[0] == '/') 1 else 0;
}

/// Splits a path whose separators are `/` into its parent directory and
/// its final component. A path with one component has the parent `.`,
/// and a component right under the root has the root as its parent.
pub fn splitParent(p: []const u8, rules: PathRules) struct { []const u8, []const u8 } {
    const root = rootLen(p, rules);
    if (std.mem.lastIndexOfScalar(u8, p[root..], '/')) |sl| return .{ p[0 .. root + sl], p[root + sl + 1 ..] };
    return .{ if (root > 0) p[0..root] else ".", p[root..] };
}

/// The final component as Win32 opens it: without its trailing dots and
/// spaces. The components `.` and `..` stay as they are.
pub fn win32Component(base: []const u8, rules: PathRules) []const u8 {
    if (!rules.windows or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return base;
    return std.mem.trimEnd(u8, base, ". ");
}

/// The names Win32 opens as devices in any directory, whatever extension
/// follows them. The digits include the superscripts one to three.
const dos_devices = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
const dos_ports = [_][]const u8{ "COM", "LPT" };
const dos_digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\xc2\xb9", "\xc2\xb2", "\xc2\xb3" };

/// Whether Win32 opens the final component `base` as a device: the part
/// before its first dot, without trailing spaces, is a device name in any
/// case once the trailing dots and spaces of the component are gone.
pub fn isDosDevice(base: []const u8) bool {
    const name = win32Component(base, .win);
    const stem = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for (dos_devices) |d| if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    for (dos_ports) |port| {
        if (stem.len <= port.len or !std.ascii.eqlIgnoreCase(stem[0..port.len], port)) continue;
        for (dos_digits) |d| if (std.mem.eql(u8, stem[port.len..], d)) return true;
    }
    return false;
}

/// Whether a path whose separators are `/` names an ordinary file under
/// the given rules. Under the Windows rules a colon after the drive or the
/// share names an alternate data stream, and a final component that is a
/// device name opens a device in any directory, so neither ever matches a
/// grant. Every path is ordinary under the POSIX rules.
pub fn isOrdinaryPath(p: []const u8, rules: PathRules) bool {
    if (!rules.windows) return true;
    // `//./` and `//?/` name devices and paths that skip the rules of
    // ordinary paths, so no permission value and no request takes them.
    if (p.len >= 4 and (p[2] == '.' or p[2] == '?')) {
        var seps = true;
        for ([_]u8{ p[0], p[1], p[3] }) |c| {
            if (c != '/' and c != '\\') seps = false;
        }
        if (seps) return false;
    }
    const root = rootLen(p, rules);
    if (std.mem.indexOfScalar(u8, p[root..], ':') != null) return false;
    const trimmed = std.mem.trimEnd(u8, p, "/");
    if (trimmed.len <= root) return true;
    return !isDosDevice(splitParent(trimmed, rules)[1]);
}

/// Joins a resolved directory and a final component with one `/`.
fn joinPath(gpa: Allocator, dir: []const u8, base: []const u8) ?[]u8 {
    if (base.len == 0) return gpa.dupe(u8, dir) catch null;
    const sep: []const u8 = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
    return std.mem.concat(gpa, u8, &.{ dir, sep, base }) catch null;
}

/// The absolute path of an existing file, with `/` separators. WASI has
/// no realpath, and its file system has no symbolic links to resolve, so
/// there the path resolves lexically against the root.
fn realPath(g: *Global, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    if (@import("builtin").os.tag == .wasi) {
        _ = try cwd.statFile(g.io, path, .{});
        return std.fs.path.resolve(g.gpa, &.{ "/", path });
    }
    // The result is sentinel terminated. Copy it so callers free a plain
    // slice of the right length.
    const r = try cwd.realPathFileAlloc(g.io, path, g.gpa);
    defer g.gpa.free(r);
    return normalizeSeparators(g.gpa, r, host_rules);
}

/// Resolves paths on the host file system. The path functions below take
/// any value with a `resolve` method that returns the absolute path of an
/// existing file with `/` separators, and an `isLink` method that says
/// whether a path names a symbolic link, so tests can supply a file system
/// of their own.
const HostResolver = struct {
    g: *Global,

    fn resolve(r: HostResolver, path: []const u8) ![]u8 {
        return realPath(r.g, path);
    }

    /// Whether `path` names a symbolic link, whatever it points to.
    fn isLink(r: HostResolver, path: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(r.g.io, path, .{ .follow_symlinks = false }) catch return false;
        return st.kind == .sym_link;
    }
};

/// Canonical absolute path: the realpath of the longest prefix of `path`
/// that exists, followed by the components that do not exist yet. Returns
/// null when the path cannot be resolved, which callers treat as denied.
pub fn canonicalize(g: *Global, path: []const u8) ?[]u8 {
    return canonicalizeWith(g.gpa, path, host_rules, HostResolver{ .g = g });
}

fn canonicalizeWith(gpa: Allocator, path: []const u8, rules: PathRules, resolver: anytype) ?[]u8 {
    const norm = normalizeSeparators(gpa, path, rules) catch return null;
    defer gpa.free(norm);
    if (!isOrdinaryPath(norm, rules)) return null;
    return ordinaryOrNull(gpa, resolveExisting(gpa, norm, rules, resolver) orelse return null, rules);
}

/// The realpath of the longest existing prefix of `p`, a path whose
/// separators are `/`, followed by the components of `p` that do not
/// exist. Grants and requests both resolve this way, so a grant made
/// before its directory exists and a later request inside that directory
/// reach the same form. Null when no prefix resolves, or when a missing
/// component is `..`, whose meaning depends on what is created later.
fn resolveExisting(gpa: Allocator, p: []const u8, rules: PathRules, resolver: anytype) ?[]u8 {
    const root = rootLen(p, rules);
    var end = p.len;
    while (true) {
        const at_top = end <= root;
        const dir = if (!at_top) p[0..end] else if (root > 0) p[0..root] else ".";
        if (resolver.resolve(dir)) |rp| {
            defer gpa.free(rp);
            return appendMissing(gpa, rp, p[if (at_top) root else end..], rules);
        } else |_| {}
        // A link that does not resolve is no missing component: opening
        // the path would follow it to wherever it points.
        if (resolver.isLink(dir)) return null;
        if (at_top) return null;
        end = if (std.mem.lastIndexOfScalar(u8, p[root..end], '/')) |sl| root + sl else root;
    }
}

/// `dir` followed by each component of `rest` as Win32 opens it. Empty
/// components and `.` drop out. Null when a component is `..` or empty
/// once Win32 trims it.
fn appendMissing(gpa: Allocator, dir: []const u8, rest: []const u8, rules: PathRules) ?[]u8 {
    return appendMissingAlloc(gpa, dir, rest, rules) catch null;
}

fn appendMissingAlloc(gpa: Allocator, dir: []const u8, rest: []const u8, rules: PathRules) error{ OutOfMemory, Unresolvable }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, dir);
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |raw| {
        if (raw.len == 0 or std.mem.eql(u8, raw, ".")) continue;
        const comp = win32Component(raw, rules);
        if (std.mem.eql(u8, raw, "..") or comp.len == 0) return error.Unresolvable;
        if (!std.mem.endsWith(u8, out.items, "/")) try out.append(gpa, '/');
        try out.appendSlice(gpa, comp);
    }
    return out.toOwnedSlice(gpa);
}

/// `p` when it names an ordinary file, otherwise null after freeing it.
fn ordinaryOrNull(gpa: Allocator, p: []u8, rules: PathRules) ?[]u8 {
    if (isOrdinaryPath(p, rules)) return p;
    gpa.free(p);
    return null;
}

/// Canonical path of a link itself: its parent resolves, its final
/// component does not, so an operation on a symbolic link is checked
/// against the link's own location rather than its target.
pub fn canonicalizeLink(g: *Global, path: []const u8) ?[]u8 {
    return canonicalizeLinkWith(g.gpa, path, host_rules, HostResolver{ .g = g });
}

fn canonicalizeLinkWith(gpa: Allocator, path: []const u8, rules: PathRules, resolver: anytype) ?[]u8 {
    const norm = normalizeSeparators(gpa, path, rules) catch return null;
    defer gpa.free(norm);
    if (!isOrdinaryPath(norm, rules)) return null;
    const trimmed = std.mem.trimEnd(u8, norm, "/");
    const parent, const base = splitParent(trimmed, rules);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return canonicalizeWith(gpa, path, rules, resolver);
    const rp = resolveExisting(gpa, parent, rules, resolver) orelse return null;
    defer gpa.free(rp);
    return ordinaryOrNull(gpa, joinPath(gpa, rp, win32Component(base, rules)) orelse return null, rules);
}

/// Canonicalizes a granted path pattern. The directory part before the
/// first wildcard, or the whole path without one, resolves as a request
/// does, so a grant made before its directory exists matches the requests
/// made inside it once it does.
fn canonicalPattern(g: *Global, raw: []const u8, keep_last: bool) Allocator.Error![]u8 {
    return canonicalPatternWith(g.gpa, raw, keep_last, host_rules, HostResolver{ .g = g });
}

fn canonicalPatternWith(gpa: Allocator, raw: []const u8, keep_last: bool, rules: PathRules, resolver: anytype) Allocator.Error![]u8 {
    const pattern = try normalizeSeparators(gpa, raw, rules);
    if (!isPathValue(pattern, rules)) return pattern;
    const wild = std.mem.indexOfAny(u8, pattern, "*?") orelse pattern.len;
    // Split at the last separator before the first wildcard.
    var cut = std.mem.lastIndexOfScalar(u8, pattern[0..wild], '/') orelse return pattern;
    if (wild == pattern.len and !keep_last) cut = pattern.len; // no wildcard: resolve it all
    cut = @max(cut, rootLen(pattern, rules));
    const rp = resolveExisting(gpa, pattern[0..cut], rules, resolver) orelse return pattern;
    defer gpa.free(rp);
    defer gpa.free(pattern);
    var rest = pattern[cut..];
    // A root resolves to a path that already ends in a separator.
    if (std.mem.endsWith(u8, rp, "/") and rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len > 0 and rest[0] != '/' and !std.mem.endsWith(u8, rp, "/")) return std.mem.concat(gpa, u8, &.{ rp, "/", rest });
    return std.mem.concat(gpa, u8, &.{ rp, rest });
}

/// The extensions Windows tries when it runs a program named without one.
const program_extensions = [_][]const u8{ ".com", ".exe", ".bat", ".cmd" };

/// Whether a granted program path covers `resolved`, the canonical path of
/// the program a call runs. Under the Windows rules a grant also covers the
/// program with one of the extensions Windows adds, so a grant of
/// `C:/tools/lus` covers `C:/tools/lus.exe` as running `C:/tools/lus` does.
fn programPathMatches(granted: []const u8, resolved: []const u8, rules: PathRules) bool {
    if (pathGlobMatch(granted, resolved, rules.windows)) return true;
    if (!rules.windows) return false;
    const base = splitParent(resolved, rules)[1];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot..];
    for (program_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return pathGlobMatch(granted, resolved[0 .. resolved.len - ext.len], true);
    }
    return false;
}

fn valueMatches(cap: Capability, granted: []const u8, requested: []const u8, canon_req: ?[]const u8) bool {
    return switch (cap.kind) {
        .none => true,
        .path => if (canon_req) |c| pathGlobMatch(granted, c, host_rules.windows) else false,
        .host => hostMatch(granted, requested),
        .pattern => globMatch(granted, requested),
        .custom => if (cap.match) |m| m(cap.ctx, granted, requested) else false,
        .program => {
            const nul = std.mem.indexOfScalar(u8, requested, 0) orelse requested.len;
            if (hasSeparator(granted)) return if (canon_req) |c| programPathMatches(granted, c, host_rules) else false;
            const written = requested[0..nul];
            return written.len > 0 and globMatch(granted, written);
        },
    };
}

fn split(spec: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, spec, ':')) |c| return .{ spec[0..c], spec[c + 1 ..] };
    return .{ spec, "" };
}

/// Whether set `s` allows `perm` (e.g. "fs:read") for `requested` (or for
/// any value when null).
fn setAllows(g: *Global, s: *Set, perm: []const u8, requested: ?[]const u8) bool {
    return setAllowsMode(g, s, perm, requested, true);
}

fn setAllowsMode(g: *Global, s: *Set, perm: []const u8, requested: ?[]const u8, follow: bool) bool {
    const parts = split(perm);
    const base = parts[0];
    const cap = findCap(g, base) orelse return false;
    if (allRejected(s)) return false;
    if (s.find(perm)) |e| if (e.rejected) return false;
    if (s.find(base)) |e| if (e.rejected) return false;
    var canon: ?[]u8 = null;
    defer if (canon) |c| g.gpa.free(c);
    var canon_link: ?[]u8 = null;
    defer if (canon_link) |c| g.gpa.free(c);
    if (cap.kind == .program) {
        if (requested) |r| if (std.mem.indexOfScalar(u8, r, 0)) |nul| if (nul + 1 < r.len) {
            canon = canonicalize(g, r[nul + 1 ..]);
        };
    }
    if (cap.kind == .path) {
        if (requested) |r| {
            // Following operations match what the path resolves to now.
            // Operations on a link match the link's own location.
            if (follow) canon = canonicalize(g, r) else canon_link = canonicalizeLink(g, r);
        }
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
        if (cap.kind != .path) {
            for (e.values.items) |v| if (valueMatches(cap, v, req, canon)) return true;
        } else if (follow) {
            for (e.values.items) |v| if (valueMatches(cap, v, req, canon)) return true;
        } else {
            for (e.link_values.items) |v| if (valueMatches(cap, v, req, canon_link)) return true;
        }
        // A grant only adds access, so a part whose values do not match
        // still allows what its base permission grants.
    }
    if (s.find("all")) |e| if (e.unrestricted) return true;
    return false;
}

/// Whether `l` holds `perm` for `requested` now, or a later `pledge` of
/// the script could grant it. Work that happens before the script runs,
/// such as reading the modules that it requires, stays within this, so a
/// script that can never hold a permission causes no use of it.
pub fn couldEverAllow(l: *Thread, perm: []const u8, requested: []const u8) bool {
    const g = l.g;
    if (allowed(l, perm, requested)) return true;
    if (setOf(l)) |s| {
        if (s.sealed or allRejected(s)) return false;
        if (s.find(perm)) |e| if (e.rejected) return false;
        if (s.find(split(perm)[0])) |e| if (e.rejected) return false;
    }
    const r = registry(g);
    // A hook of the host decides each pledge when it is made.
    if (r.on_request != null) return false;
    const ceil = r.ceiling orelse return true;
    return ceilingCoversValue(g, ceil, perm, requested);
}

/// Whether the set rejected every permission at once, with `~all`.
fn allRejected(s: *const Set) bool {
    for (s.entries.items) |e| {
        if (e.rejected and std.mem.eql(u8, e.name, "all")) return true;
    }
    return false;
}

/// Whether `perm` is granted without a value restriction, as running a
/// shell command needs, since a shell runs any program.
pub fn allowedUnrestricted(l: *Thread, perm: []const u8) bool {
    const s = setOf(l) orelse return false;
    if (allRejected(s)) return false;
    if (s.find(perm)) |e| {
        if (e.rejected) return false;
        if (e.unrestricted) return true;
    }
    if (s.find("all")) |e| if (e.unrestricted) return true;
    return false;
}

/// Whether the ceiling `ceil` covers a script pledge of `name` with `val`.
/// A pledge without a value asks for every value, which a ceiling that
/// grants some values only does not cover: a check that names no value
/// passes such a ceiling, so `setAllows` alone would widen the grant.
fn ceilingCovers(g: *Global, ceil: *Set, name: []const u8, val: ?[]const u8) bool {
    if (val) |v| return ceilingCoversValue(g, ceil, name, v);
    if (allRejected(ceil)) return false;
    const parts = split(name);
    const cap = findCap(g, parts[0]) orelse return false;
    if (cap.kind == .none) return setAllows(g, ceil, name, null);
    if (ceil.find(name)) |e| if (e.rejected) return false;
    if (ceil.find(parts[0])) |e| if (e.rejected) return false;
    if (ceil.find(name)) |e| if (e.unrestricted) return true;
    // A part such as fs:read is covered by its base granted without a
    // value, unless the part itself is limited to values.
    if (!std.mem.eql(u8, name, parts[0])) {
        if (ceil.find(name)) |e| if (e.values.items.len > 0) return false;
        if (ceil.find(parts[0])) |e| if (e.unrestricted) return true;
    }
    if (ceil.find("all")) |e| if (e.unrestricted) return true;
    return false;
}

/// Whether every string that the glob `pledged` matches is also matched by
/// the glob `ceiling`. A `*` of the ceiling covers any run of the pledged
/// pattern, a `?` covers one literal byte or one `?`, and a literal byte
/// covers the same literal byte. A `*` of the pledged pattern is covered
/// by a `*` only, since it stands for strings of every length.
pub fn patternCovers(ceiling: []const u8, pledged: []const u8, fold: bool) bool {
    return globCore(ceiling, pledged, .{ .fold = fold, .covers = true });
}

/// `patternCovers` for two path patterns, under the rules of
/// `pathGlobMatch`. A `*` of the ceiling covers neither a `/` nor a `**`.
pub fn pathPatternCovers(ceiling: []const u8, pledged: []const u8, fold: bool) bool {
    return globCore(ceiling, pledged, .{ .fold = fold, .components = true, .covers = true });
}

/// `patternCovers` for two values of the `host` kind, part by part as
/// `hostMatch` reads them.
fn hostCovers(ceiling: []const u8, pledged: []const u8) bool {
    // A ceiling with a scheme covers pledges of that scheme only. A
    // pledge with a scheme asks for less than the same value without one.
    var c = ceiling;
    var p = pledged;
    if (schemeLen(ceiling)) |n| {
        if (!std.mem.startsWith(u8, pledged, ceiling[0..n])) return false;
        c = ceiling[n..];
        p = pledged[n..];
    } else if (schemeLen(pledged)) |n| p = pledged[n..];
    const c_slash = std.mem.indexOfScalar(u8, c, '/');
    const p_slash = std.mem.indexOfScalar(u8, p, '/');
    const c_auth = c[0 .. c_slash orelse c.len];
    const p_auth = p[0 .. p_slash orelse p.len];
    const c_port = std.mem.indexOfScalar(u8, c_auth, ':') != null;
    const p_colon = std.mem.indexOfScalar(u8, p_auth, ':');
    if (c_port) {
        // The ceiling names a port, so the pledge must name one too.
        if (p_colon == null or !patternCovers(c_auth, p_auth, false)) return false;
    } else {
        // The ceiling matches the host alone, whatever the port.
        if (!patternCovers(c_auth, p_auth[0 .. p_colon orelse p_auth.len], false)) return false;
    }
    if (c_slash) |cs| {
        const ps = p_slash orelse return false;
        return pathPatternCovers(c[cs..], p[ps..], false);
    }
    return true;
}

/// Whether the ceiling covers a script pledge of `name` with the value
/// `val`. The value is a pattern, so it is compared with the patterns of
/// the ceiling in the form a grant stores them.
fn ceilingCoversValue(g: *Global, ceil: *Set, name: []const u8, val: []const u8) bool {
    if (allRejected(ceil)) return false;
    const parts = split(name);
    const base = parts[0];
    const cap = findCap(g, base) orelse return false;
    // A matcher of an extension reads values in its own way.
    if (cap.kind == .custom or cap.kind == .none) return setAllows(g, ceil, name, val);
    if (ceil.find(name)) |e| if (e.rejected) return false;
    if (ceil.find(base)) |e| if (e.rejected) return false;
    const is_path = cap.kind == .path or (cap.kind == .program and hasSeparator(val));
    var stored: ?[]u8 = null;
    defer if (stored) |s| g.gpa.free(s);
    var link: ?[]u8 = null;
    defer if (link) |s| g.gpa.free(s);
    if (is_path) {
        stored = canonicalPattern(g, val, false) catch return false;
        link = canonicalPattern(g, val, true) catch return false;
    }
    const candidates = [_][]const u8{ name, base };
    var plain = false;
    var as_link = !is_path;
    for (candidates, 0..) |cand, ci| {
        if (ci == 1 and std.mem.eql(u8, name, base)) break;
        const e = ceil.find(cand) orelse continue;
        if (e.unrestricted) return true;
        for (e.values.items) |cv| {
            const covers = switch (cap.kind) {
                .path => pathPatternCovers(cv, stored.?, host_rules.windows),
                .program => if (is_path) hasSeparator(cv) and pathPatternCovers(cv, stored.?, host_rules.windows) else !hasSeparator(cv) and patternCovers(cv, val, false),
                .host => hostCovers(cv, val),
                .pattern => patternCovers(cv, val, false),
                .custom, .none => unreachable,
            };
            if (covers) plain = true;
        }
        if (is_path) for (e.link_values.items) |cv| {
            if (pathPatternCovers(cv, link.?, host_rules.windows)) as_link = true;
        };
    }
    if (plain and as_link) return true;
    if (ceil.find("all")) |e| if (e.unrestricted) return true;
    return false;
}

/// Whether `perm`, a capability that a fresh state holds, is granted. A
/// thread holds it while its permission set is unchanged, with no pledge,
/// no rejection, no seal, and no grant of the host. Once the set
/// has changed, `perm` must be granted like any other capability.
pub fn allowedUntouched(l: *Thread, perm: []const u8) bool {
    const s = setOf(l) orelse return true;
    var changes = s.entries.items.len;
    if (s.find(bytecode)) |e| {
        if (!e.rejected) changes -= 1;
    }
    if (changes == 0 and !s.sealed) return true;
    return allowed(l, perm, null);
}

/// Non-raising check.
pub fn allowed(l: *Thread, perm: []const u8, requested: ?[]const u8) bool {
    const s = setOf(l) orelse return false;
    return setAllows(l.g, s, perm, requested);
}

/// Raising check for operations that act on a path itself and never
/// follow a final symbolic link (removing, renaming, reading a link).
pub fn requireNoFollow(l: *Thread, perm: []const u8, requested: []const u8) Error!void {
    if (setOf(l)) |s| if (setAllowsMode(l.g, s, perm, requested, false)) return;
    return l.raiseFmt("permission \"{s}\" denied for '{s}'", .{ perm, requested });
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
        // A value that came out empty, as from an unset shell variable,
        // would otherwise read as a grant of every value.
        if (val.?.len == 0) return l.raiseFmt("permission '{s}' has an empty value", .{spec});
    }
    if (name.len >= 64) return l.raiseFmt("permission name too long: '{s}'", .{spec});
    var rel_buf: ?[]u8 = null;
    defer if (rel_buf) |b| gpa.free(b);
    if (std.mem.eql(u8, name, "seal")) {
        // A seal takes no value and has no rejection.
        if (reject or val != null) return l.raiseFmt("'seal' takes no '~' and no value (got '{s}')", .{spec});
        const set = try writable(l);
        set.sealed = true;
        return .granted;
    }
    if (std.mem.eql(u8, name, "all")) {
        if (!from_host) return l.raiseFmt("permission \"all\" cannot be requested from scripts", .{});
        if (val != null) return l.raiseFmt("'all' takes no value (got '{s}')", .{spec});
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
        // A relative path without a leading `./`, such as `data/*` or
        // `tool.lus`, names the same place as `./data/*`. A value that starts
        // with a wildcard stays refused, since `*` spans separators.
        if (cap.kind == .path) if (val) |v| {
            if (!isPathValue(v, host_rules)) {
                if (v[0] == '*' or v[0] == '?' or v[0] == '[') return l.raiseFmt("filesystem permission values must be an absolute path or a relative path that starts with a name (got '{s}')", .{v});
                rel_buf = std.mem.concat(gpa, u8, &.{ "./", v }) catch return l.raiseMem();
                val = rel_buf;
            }
        };
        if (cap.kind == .program) if (val) |v| {
            if (hasSeparator(v) and !isPathValue(v, host_rules)) return l.raiseFmt("a program path in a permission value must be absolute or start with '.' (got '{s}')", .{v});
        };
    }
    if (setOf(l)) |s| if (s.sealed) return .refused;
    if (!reject and !from_host and isBytecode(name)) return .refused;
    if (!reject) {
        if (setOf(l)) |s| if (s.find(name)) |e| if (e.rejected) return l.raiseFmt("permission \"{s}\" was rejected", .{name});
        if (setOf(l)) |s| if (allRejected(s)) return l.raiseFmt("permission \"{s}\" was rejected", .{name});
        // A rejected base permission rejects each of its parts.
        if (setOf(l)) |s| if (s.find(split(name)[0])) |e| if (e.rejected) return l.raiseFmt("permission \"{s}\" was rejected", .{name});
        // The host ceiling bounds what scripts may grant. With a request
        // hook installed, the hook decides every script pledge the ceiling
        // does not already cover.
        if (!from_host) {
            const r = registry(g);
            const covered = if (r.ceiling) |ceil| ceilingCovers(g, ceil, name, val) else false;
            if (!covered) {
                if (r.on_request) |hook| {
                    if (!hook.func(hook.ctx, l, name, val)) return .refused;
                    // The hook ran code of the host, which may have
                    // sealed or rejected in the meantime.
                    if (setOf(l)) |s| {
                        if (s.sealed) return .refused;
                        if (s.find(name)) |e| if (e.rejected) return .refused;
                    }
                } else if (r.ceiling != null) return .refused;
            }
        }
    }
    try record(l, try writable(l), name, val, reject);
    if (from_host) {
        // The ceiling holds host decisions only, so script pledges made
        // earlier never widen what later script pledges may reach.
        const r = registry(g);
        if (isBytecode(name) and !reject) return .granted;
        // A rejection of every permission is a host decision that later
        // script pledges must meet, so it makes a ceiling as a grant does.
        if (r.ceiling == null and (!reject or std.mem.eql(u8, name, "all"))) {
            const n = gpa.create(Set) catch return l.raiseMem();
            n.* = .{};
            r.ceiling = n;
        }
        if (r.ceiling) |ceil| try record(l, ceil, name, val, reject);
    }
    return .granted;
}

/// Adds one grant or rejection to `set`.
fn record(l: *Thread, set: *Set, name: []const u8, val: ?[]const u8, reject: bool) Error!void {
    const g = l.g;
    const gpa = g.gpa;
    const e = set.find(name) orelse blk: {
        set.entries.ensureUnusedCapacity(gpa, 1) catch return l.raiseMem();
        set.entries.appendAssumeCapacity(.{ .name = gpa.dupe(u8, name) catch return l.raiseMem() });
        break :blk &set.entries.items[set.entries.items.len - 1];
    };
    if (reject) {
        e.rejected = true;
        return;
    }
    // A grant only adds access. A grant without a value covers every
    // value, whatever values the permission already holds, and a value
    // added after it changes nothing.
    if (e.unrestricted) return;
    if (val) |v| {
        const cap = findCap(g, split(name)[0]);
        const is_path = cap != null and (cap.?.kind == .path or (cap.?.kind == .program and hasSeparator(v)));
        const stored = (if (is_path) canonicalPattern(g, v, false) else gpa.dupe(u8, v)) catch return l.raiseMem();
        const link: ?[]u8 = if (is_path) canonicalPattern(g, v, true) catch {
            gpa.free(stored);
            return l.raiseMem();
        } else null;
        // Both lists grow before either changes, so a failure leaves the
        // grant as it was.
        e.values.ensureUnusedCapacity(gpa, 1) catch {
            gpa.free(stored);
            if (link) |k| gpa.free(k);
            return l.raiseMem();
        };
        if (link != null) e.link_values.ensureUnusedCapacity(gpa, 1) catch {
            gpa.free(stored);
            gpa.free(link.?);
            return l.raiseMem();
        };
        e.values.appendAssumeCapacity(stored);
        if (link) |k| e.link_values.appendAssumeCapacity(k);
    } else e.unrestricted = true;
}

/// One host policy change from the embedding interface: a grant, a
/// rejection, or "seal". Grants and rejections also update the ceiling for
/// script pledges, as command line grants do. A rejection made before any
/// grant sets no ceiling, so it never limits what scripts may pledge
/// otherwise.
pub fn hostApply(l: *Thread, spec: []const u8) Error!GrantResult {
    return apply(l, spec, true);
}

/// Host grants from the command line: applied to the main thread and
/// recorded as the ceiling for script pledges.
pub fn hostGrant(l: *Thread, specs: []const []const u8) Error!void {
    for (specs) |spec| {
        if (try apply(l, spec, true) == .refused) return l.raiseFmt("permission '{s}' was refused: the permissions are sealed", .{spec});
    }
}

test "a ceiling covers a pledged pattern" {
    try std.testing.expect(patternCovers("/data/*", "/data/a.txt", false));
    try std.testing.expect(patternCovers("/data/*", "/data/*.txt", false));
    try std.testing.expect(patternCovers("/data/a?c", "/data/a?c", false));
    try std.testing.expect(patternCovers("*", "a*b?c", false));
    try std.testing.expect(!patternCovers("/data/file?.txt", "/data/file*.txt", false));
    try std.testing.expect(!patternCovers("APP_?", "APP_*", false));
    try std.testing.expect(!patternCovers("/data/a", "/data/?", false));
    try std.testing.expect(!patternCovers("/data/*", "/dat*", false));
    try std.testing.expect(hostCovers("127.0.0.1", "127.0.0.1"));
    try std.testing.expect(hostCovers("127.0.0.1", "127.0.0.1:80"));
    try std.testing.expect(hostCovers("*.example.com", "api.example.com/v1/*"));
    try std.testing.expect(!hostCovers("127.0.0.1", "127.0.0.1?*"));
    try std.testing.expect(!hostCovers("api.example.com", "api.example.com*"));
    try std.testing.expect(!hostCovers("example.com:443", "example.com"));
    try std.testing.expect(!hostCovers("example.com/api/*", "example.com"));
    try std.testing.expect(hostCovers("example.com", "https://example.com/*"));
    try std.testing.expect(!hostCovers("https://example.com", "example.com"));
    try std.testing.expect(!hostCovers("https://example.com", "http://example.com"));
}

test "path globs keep a star inside one component" {
    try std.testing.expect(pathGlobMatch("/data/*", "/data/a.txt", false));
    try std.testing.expect(!pathGlobMatch("/data/*", "/data/a/b.txt", false));
    try std.testing.expect(pathGlobMatch("/data/**", "/data/a/b.txt", false));
    try std.testing.expect(pathGlobMatch("/data/**/x.lus", "/data/a/b/x.lus", false));
    try std.testing.expect(pathGlobMatch("/data/*/x.lus", "/data/a/x.lus", false));
    try std.testing.expect(!pathGlobMatch("/data/*/x.lus", "/data/a/b/x.lus", false));
    try std.testing.expect(!pathGlobMatch("/data*", "/database/x", false));
    try std.testing.expect(pathGlobMatch("/data*", "/database", false));
    try std.testing.expect(!pathGlobMatch("/a?c", "/a/c", false));
    try std.testing.expect(pathGlobMatch("/a/**", "/a/", false));
    try std.testing.expect(pathPatternCovers("/data/**", "/data/*/x", false));
    try std.testing.expect(pathPatternCovers("/data/**", "/data/**", false));
    try std.testing.expect(!pathPatternCovers("/data/*", "/data/**", false));
    try std.testing.expect(!pathPatternCovers("/data/*", "/data/a/b", false));
    try std.testing.expect(pathPatternCovers("/data/*", "/data/a?.txt", false));
}

test "a scheme grant matches part by part" {
    try std.testing.expect(hostMatch("https://*.example.com/**", "https://api.example.com/v1/x"));
    try std.testing.expect(!hostMatch("https://*.example.com/**", "https://evil.net/.example.com/"));
    try std.testing.expect(!hostMatch("https://*.example.com/**", "http://api.example.com/"));
    try std.testing.expect(!hostMatch("example.com/api/*", "http://example.com/api/../admin"));
    try std.testing.expect(!hostMatch("example.com/api/*", "http://example.com/api/%2e%2E/admin"));
    try std.testing.expect(hostMatch("example.com/api/*", "http://example.com/api/users?x=1"));
    try std.testing.expect(!hostMatch("example.com/api/*", "http://example.com/api/a/b"));
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

/// A file system for the path tests: the paths that exist, each with its
/// resolved form.
const FakeFs = struct {
    gpa: Allocator,
    rules: PathRules,
    files: []const [2][]const u8,

    fn resolve(f: FakeFs, path: []const u8) ![]u8 {
        const p = if (path.len > (rootLen(path, f.rules))) std.mem.trimEnd(u8, path, "/") else path;
        for (f.files) |e| {
            const same = if (f.rules.windows) std.ascii.eqlIgnoreCase(e[0], p) else std.mem.eql(u8, e[0], p);
            if (same) return f.gpa.dupe(u8, e[1]);
        }
        return error.FileNotFound;
    }

    fn isLink(_: FakeFs, _: []const u8) bool {
        return false;
    }
};

fn expectPattern(f: FakeFs, raw: []const u8, keep_last: bool, want: []const u8) !void {
    const got = try canonicalPatternWith(f.gpa, raw, keep_last, f.rules, f);
    defer f.gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn expectCanonical(f: FakeFs, raw: []const u8, want: ?[]const u8) !void {
    const got = canonicalizeWith(f.gpa, raw, f.rules, f);
    defer if (got) |g| f.gpa.free(g);
    if (want) |w| try std.testing.expectEqualStrings(w, got orelse return error.TestUnexpectedResult) else try std.testing.expect(got == null);
}

test "path values" {
    const W = PathRules.win;
    const P = PathRules.posix;
    try std.testing.expect(isPathValue("/tmp", P));
    try std.testing.expect(isPathValue("./x", P));
    try std.testing.expect(!isPathValue("C:/x", P));
    try std.testing.expect(!isPathValue("x", P));
    try std.testing.expect(isPathValue("C:\\x", W));
    try std.testing.expect(isPathValue("d:/x", W));
    try std.testing.expect(isPathValue("\\\\server\\share", W));
    try std.testing.expect(isPathValue(".\\x", W));
    try std.testing.expect(!isPathValue("C:x", W));
    try std.testing.expect(!isPathValue("x", W));
    try std.testing.expectEqual(@as(usize, 1), rootLen("/a/b", P));
    try std.testing.expectEqual(@as(usize, 0), rootLen("C:/a", P));
    try std.testing.expectEqual(@as(usize, 3), rootLen("C:/a", W));
    try std.testing.expectEqual(@as(usize, 2), rootLen("C:a", W));
    try std.testing.expectEqual(@as(usize, 12), rootLen("//srv/share/a", W));
    try std.testing.expectEqual(@as(usize, 11), rootLen("//srv/share", W));
    const a = splitParent("C:/x", W);
    try std.testing.expectEqualStrings("C:/", a[0]);
    try std.testing.expectEqualStrings("x", a[1]);
    const b = splitParent("/x", P);
    try std.testing.expectEqualStrings("/", b[0]);
    const c = splitParent("x", W);
    try std.testing.expectEqualStrings(".", c[0]);
    try std.testing.expect(globMatchCase("C:/Work/*", "c:/work/A.txt", true));
    try std.testing.expect(!globMatchCase("/Work/*", "/work/a", false));
}

test "canonical paths under the POSIX rules" {
    const gpa = std.testing.allocator;
    const f: FakeFs = .{ .gpa = gpa, .rules = .posix, .files = &.{
        .{ "/", "/" },
        .{ ".", "/work" },
        .{ "/tmp", "/private/tmp" },
        .{ "./sub", "/work/sub" },
    } };
    try expectPattern(f, "/tmp/*", false, "/private/tmp/*");
    try expectPattern(f, "./*", false, "/work/*");
    try expectPattern(f, "./sub/a.txt", false, "/work/sub/a.txt");
    try expectPattern(f, "./sub/a.txt", true, "/work/sub/a.txt");
    try expectPattern(f, "/none/deeper/*", false, "/none/deeper/*");
    try expectPattern(f, "./missing/x*", false, "/work/missing/x*");
    try expectCanonical(f, "new.txt", "/work/new.txt");
    try expectCanonical(f, "/tmp", "/private/tmp");
    try expectCanonical(f, "/tmp/new", "/private/tmp/new");
    // A path whose directory does not exist yet resolves through its
    // longest existing prefix, as its grant does.
    try expectCanonical(f, "/nope/new", "/nope/new");
    try expectCanonical(f, "/tmp/new/x", "/private/tmp/new/x");
    try expectPattern(f, "/tmp/new/*", false, "/private/tmp/new/*");
    try expectCanonical(f, "missing/deeper/x", "/work/missing/deeper/x");
    try expectCanonical(f, "/tmp/./new//x", "/private/tmp/new/x");
    // A missing `..` names a place that depends on what is created later.
    try expectCanonical(f, "/tmp/new/../../etc/passwd", null);
    try expectPattern(f, "/tmp/new/../*", false, "/tmp/new/../*");
}

test "canonical paths under the Windows rules" {
    const gpa = std.testing.allocator;
    const f: FakeFs = .{ .gpa = gpa, .rules = .win, .files = &.{
        .{ "D:/", "D:/" },
        .{ ".", "C:/Temp/lus-test-1" },
        .{ "D:/a/lus/tests/conformance", "D:/a/lus/tests/conformance" },
        .{ "D:/a/lus/tests/conformance/fixtures/flags", "D:/a/lus/tests/conformance/fixtures/flags" },
        .{ "//srv/share/", "//srv/share/" },
        .{ "./h3c3", "C:/Temp/lus-test-1/h3c3" },
        .{ "h3c3", "C:/Temp/lus-test-1/h3c3" },
    } };
    // Mixed separators, as a test directory joined with "/" produces.
    try expectPattern(f, "D:\\a\\lus\\tests\\conformance/fixtures/flags", false, "D:/a/lus/tests/conformance/fixtures/flags");
    try expectPattern(f, "D:\\a\\lus\\tests\\conformance/*", false, "D:/a/lus/tests/conformance/*");
    try expectPattern(f, "d:/A/LUS/tests/conformance/*", false, "D:/a/lus/tests/conformance/*");
    try expectPattern(f, "./baselib_*", false, "C:/Temp/lus-test-1/baselib_*");
    try expectPattern(f, ".\\h3c3\\allowed-link", true, "C:/Temp/lus-test-1/h3c3/allowed-link");
    // A walk up to the drive or the share resolves the root itself.
    try expectPattern(f, "D:/missing/deeper/*", false, "D:/missing/deeper/*");
    try expectPattern(f, "D:\\x\\*", false, "D:/x/*");
    try expectPattern(f, "\\\\srv\\share\\dir\\*", false, "//srv/share/dir/*");
    try expectCanonical(f, "fs2_x1795137734", "C:/Temp/lus-test-1/fs2_x1795137734");
    try expectCanonical(f, "h3c3\\allowed-link", "C:/Temp/lus-test-1/h3c3/allowed-link");
    try expectCanonical(f, "D:\\new.txt", "D:/new.txt");
    try expectCanonical(f, "D:\\a\\lus\\tests\\conformance\\fixtures\\flags", "D:/a/lus/tests/conformance/fixtures/flags");
    const link = canonicalizeLinkWith(gpa, "h3c3\\blocked-link\\", .win, f).?;
    defer gpa.free(link);
    try std.testing.expectEqualStrings("C:/Temp/lus-test-1/h3c3/blocked-link", link);
    // Grants and requests compare without regard to case.
    try std.testing.expect(globMatchCase("C:/Temp/lus-test-1/baselib_*", "c:/temp/LUS-TEST-1/baselib_1/a", true));
}

test "program paths under the Windows rules" {
    const W = PathRules.win;
    try std.testing.expect(programPathMatches("D:/a/bin/lus", "D:/a/bin/lus.exe", W));
    try std.testing.expect(programPathMatches("d:/A/bin/lus", "D:/a/bin/LUS.EXE", W));
    try std.testing.expect(programPathMatches("D:/a/bin/lus.exe", "D:/a/bin/lus.exe", W));
    try std.testing.expect(programPathMatches("D:/a/bin/*", "D:/a/bin/lus.exe", W));
    try std.testing.expect(programPathMatches("D:/a/bin/tool", "D:/a/bin/tool.cmd", W));
    try std.testing.expect(!programPathMatches("D:/a/bin/lus", "D:/a/bin/lus.dll", W));
    try std.testing.expect(!programPathMatches("D:/a/bin/lus", "D:/a/bin/lusx.exe", W));
    try std.testing.expect(!programPathMatches("D:/a/bin/lus", "D:/a/lib/lus.exe", W));
    try std.testing.expect(!programPathMatches("/a/bin/lus", "/a/bin/lus.exe", PathRules.posix));
    try std.testing.expect(!programPathMatches("/a/bin/lus", "/a/bin/LUS", PathRules.posix));
}

test "device names and streams under the Windows rules" {
    const gpa = std.testing.allocator;
    const f: FakeFs = .{ .gpa = gpa, .rules = .win, .files = &.{
        .{ "C:/", "C:/" },
        .{ "C:/Work", "C:/Work" },
        .{ "C:/Work/a.lus", "C:/Work/a.lus" },
        .{ ".", "C:/Work" },
    } };
    // A device name as the final component, in any case and with any
    // extension, trailing dots, or trailing spaces, never canonicalizes.
    for ([_][]const u8{
        "C:/Work/CON",    "C:/Work/con",      "C:\\Work\\NUL",   "C:/Work/PRN",         "C:/Work/aux",
        "C:/Work/COM1",   "C:/Work/com9",     "C:/Work/LPT1",    "C:/Work/lpt9",        "C:/Work/COM0",
        "C:/Work/CONIN$", "C:/Work/conout$",  "C:/Work/con.txt", "C:/Work/NUL.tar.gz",  "C:/Work/CON.",
        "C:/Work/CON ",   "C:/Work/con .txt", "C:/Work/AUX. . ", "C:/Work/COM\xc2\xb9", "C:/Work/lpt\xc2\xb3.log",
        "con",            "./nul.txt",        "C:/Work/con/",
    }) |p| {
        try expectCanonical(f, p, null);
        try std.testing.expect(canonicalizeLinkWith(gpa, p, .win, f) == null);
    }
    // Names that only start like a device are ordinary files.
    try expectCanonical(f, "C:/Work/CONSOLE", "C:/Work/CONSOLE");
    try expectCanonical(f, "C:/Work/COM10", "C:/Work/COM10");
    try expectCanonical(f, "C:/Work/xcon.txt", "C:/Work/xcon.txt");
    try expectCanonical(f, "C:/Work/COM", "C:/Work/COM");
    // A colon after the drive names an alternate data stream.
    try expectCanonical(f, "C:/Work/a.lus:x.txt", null);
    try expectCanonical(f, "C:/Work/b.txt:$DATA", null);
    try expectCanonical(f, "a.lus:x.txt", null);
    try std.testing.expect(canonicalizeLinkWith(gpa, "C:/Work/a.lus:x.txt", .win, f) == null);
    // The fallback opens what Win32 opens, without trailing dots and spaces.
    try expectCanonical(f, "C:/Work/new.txt. .", "C:/Work/new.txt");
    try expectCanonical(f, "C:/Work/new ", "C:/Work/new");
    // The POSIX rules treat these names as ordinary files.
    const pf: FakeFs = .{ .gpa = gpa, .rules = .posix, .files = &.{.{ "/work", "/work" }} };
    try expectCanonical(pf, "/work/CON", "/work/CON");
    try expectCanonical(pf, "/work/a:b.txt", "/work/a:b.txt");
    try expectCanonical(pf, "/work/x. ", "/work/x. ");
}
