//! Remote modules: `require` of an `https` URL (`spec/design/modules.md`,
//! sections 3 to 5, and `spec/tools/atmosphere.md`).
//!
//! A module URL names either a package on an atmosphere server, which
//! answers with a signed release document and a compressed bundle, or a
//! file on any other server. `Store` resolves a URL to a `Package`: it
//! reads the module cache in the Lus home, checks freshness, contacts the
//! server when it must, verifies every signature and digest, and unpacks
//! bundles. The store is process-wide, so every state and every worker
//! loads a package from one copy, and each chunk compiles once.
//!
//! Permissions are not checked here. `require` checks `load` and
//! `network:http` for the module URL before it asks the store.

const std = @import("std");
const builtin = @import("builtin");
const httpc = @import("httpc.zig");
const signed = @import("signed.zig");
const semver = @import("semver.zig");
const home_mod = @import("home.zig");
const release_keys = @import("release_keys.zig");
const crypto = @import("lib/crypto.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const release_type = "application/vnd.atmos.release+json";
const official_host = "atmosp.here";
const default_ttl: i64 = 86400;
const max_ttl: i64 = 7 * 86400;
const max_entries = 10000;
const max_unpacked = 64 << 20;

/// A failure, with the message `require` raises.
pub const Failure = error{ Remote, OutOfMemory };

pub fn isUrl(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "https://") or std.ascii.startsWithIgnoreCase(name, "http://");
}

/// Normalizes a module URL: the scheme and the host become lowercase, a
/// default port goes, and `.` and `..` segments of the path are resolved.
/// Writes the reason to `why` and returns error.Remote for a URL that is
/// not a valid module URL.
pub fn normalize(gpa: Allocator, text: []const u8, why: *std.ArrayList(u8)) Failure![]u8 {
    const uri = std.Uri.parse(text) catch return fail(gpa, why, "invalid module URL '{s}'", .{text});
    if (!httpc.acceptable(uri)) return fail(gpa, why, "module URL '{s}' must use https, or http for a loopback host", .{text});
    if (uri.query != null or uri.fragment != null) return fail(gpa, why, "module URL '{s}' must have no query or fragment", .{text});
    var hbuf: [256]u8 = undefined;
    const host = httpc.hostOf(uri, &hbuf) orelse return fail(gpa, why, "module URL '{s}' has no host", .{text});
    var pbuf: [4096]u8 = undefined;
    const raw_path = uri.path.toRaw(&pbuf) catch return fail(gpa, why, "module URL '{s}' is too long", .{text});
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = segs.pop();
            continue;
        }
        try segs.append(gpa, seg);
    }
    if (segs.items.len == 0 or !std.mem.endsWith(u8, segs.items[segs.items.len - 1], ".lus"))
        return fail(gpa, why, "module URL '{s}' must end in .lus", .{text});
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (https) "https://" else "http://");
    for (host) |c| try out.append(gpa, std.ascii.toLower(c));
    if (uri.port) |p| if (p != (if (https) @as(u16, 443) else 80)) try out.print(gpa, ":{d}", .{p});
    for (segs.items) |seg| {
        try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    return out.toOwnedSlice(gpa);
}

fn fail(gpa: Allocator, why: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Failure {
    why.clearRetainingCapacity();
    why.print(gpa, fmt, args) catch return error.OutOfMemory;
    return error.Remote;
}

/// The host of a normalized URL, with its port when it has one.
pub fn hostOf(url: []const u8) []const u8 {
    const rest = url[std.mem.indexOf(u8, url, "://").? + 3 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// The URL of the directory that holds `url`, ending in a slash.
pub fn dirOf(url: []const u8) []const u8 {
    return url[0 .. std.mem.lastIndexOfScalar(u8, url, '/').? + 1];
}

pub const Kind = enum { atmosphere, generic };

/// A resolved module URL.
pub const Package = struct {
    url: []u8,
    kind: Kind,
    /// The package name of an atmosphere release, or empty.
    name: []u8 = &.{},
    version: []u8 = &.{},
    /// The directory of the unpacked bundle, for an atmosphere release.
    bundle_dir: []u8 = &.{},
    /// The path of the main module inside the bundle.
    main: []u8 = &.{},
    /// The source of a module from a generic server.
    source: []u8 = &.{},
    /// The atmosphere URLs that the release lists in `requires`.
    requires: [][]u8 = &.{},
    /// Declared flags with their defaults, as `name=value` specs.
    flag_defaults: [][]u8 = &.{},
    /// The copied dependencies that `@includes` lists in the main module.
    includes: [][]u8 = &.{},
    /// Whether the store contacted the network for this package.
    fetched: bool = false,

    fn deinit(p: *Package, gpa: Allocator) void {
        gpa.free(p.url);
        gpa.free(p.name);
        gpa.free(p.version);
        gpa.free(p.bundle_dir);
        gpa.free(p.main);
        gpa.free(p.source);
        for (p.requires) |r| gpa.free(r);
        gpa.free(p.requires);
        for (p.flag_defaults) |r| gpa.free(r);
        gpa.free(p.flag_defaults);
        for (p.includes) |r| gpa.free(r);
        gpa.free(p.includes);
    }

    /// The package whose flags a module of this bundle reads: a copied
    /// dependency that `@includes` lists for the files of its name, the
    /// package itself for every other file.
    pub fn flagPrefix(p: *const Package, sub: ?[]const u8) []const u8 {
        if (sub) |n| {
            const top = n[0 .. std.mem.indexOfScalar(u8, n, '.') orelse n.len];
            for (p.includes) |inc| if (std.mem.eql(u8, inc, top)) return inc;
        }
        return p.name;
    }

    /// The source of the module `name` of an atmosphere bundle, or of the
    /// main module when `name` is null. Returns null when the bundle has
    /// no such file. The caller frees the result.
    pub fn read(p: *const Package, gpa: Allocator, io: Io, name: ?[]const u8) !?[]u8 {
        if (p.kind == .generic) return try gpa.dupe(u8, p.source);
        if (name == null) {
            const f = try std.fs.path.join(gpa, &.{ p.bundle_dir, p.main });
            defer gpa.free(f);
            return try Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(max_unpacked));
        }
        const rel = try std.mem.replaceOwned(u8, gpa, name.?, ".", "/");
        defer gpa.free(rel);
        for ([_][]const u8{ ".lus", "/init.lus" }) |suffix| {
            const f = try std.mem.concat(gpa, u8, &.{ p.bundle_dir, "/", rel, suffix });
            defer gpa.free(f);
            if (Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(max_unpacked))) |src| return src else |_| {}
        }
        return null;
    }
};

pub const Options = struct {
    /// The Lus home, or null when it is unknown. Without it nothing is
    /// cached on disk.
    home: ?[]const u8,
    offline: bool = false,
    reload: bool = false,
    /// Overrides the root key of atmosp.here, for tests. Applies only to
    /// loopback hosts, which never are atmosp.here, so it names the root
    /// key that a loopback atmosphere server must use.
    env: ?*const std.process.Environ.Map = null,
};

/// The process-wide store of resolved packages.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    mutex: Io.Mutex = .init,
    http: httpc.Client,
    packages: std.StringHashMapUnmanaged(*Package) = .empty,
    /// Compiled chunks by chunk name, shared by every state.
    compiled: std.StringHashMapUnmanaged([]u8) = .empty,
    /// URLs whose warnings were printed.
    warned: std.StringHashMapUnmanaged(void) = .empty,
    /// Set when the main chunk starts. A fetch after it prints a warning.
    running: bool = false,

    pub fn init(gpa: Allocator, io: Io, opts: Options) Store {
        return .{ .gpa = gpa, .io = io, .opts = opts, .http = .init(gpa, io) };
    }

    pub fn deinit(s: *Store) void {
        var it = s.packages.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit(s.gpa);
            s.gpa.destroy(e.value_ptr.*);
        }
        s.packages.deinit(s.gpa);
        var ci = s.compiled.iterator();
        while (ci.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.compiled.deinit(s.gpa);
        var wi = s.warned.keyIterator();
        while (wi.next()) |k| s.gpa.free(k.*);
        s.warned.deinit(s.gpa);
        s.http.deinit();
    }

    pub fn lock(s: *Store) void {
        s.mutex.lockUncancelable(s.io);
    }

    pub fn unlock(s: *Store) void {
        s.mutex.unlock(s.io);
    }

    /// The package already resolved for `url`, or null. The caller holds
    /// the lock.
    pub fn peek(s: *Store, url: []const u8) ?*Package {
        return s.packages.get(url);
    }

    /// Records a warning for `key` once per process. Returns whether it is
    /// new. The caller holds the lock.
    pub fn firstWarning(s: *Store, key: []const u8) bool {
        if (s.warned.contains(key)) return false;
        const k = s.gpa.dupe(u8, key) catch return false;
        s.warned.put(s.gpa, k, {}) catch {
            s.gpa.free(k);
            return false;
        };
        return true;
    }

    /// Resolves a normalized module URL. The caller holds the lock.
    pub fn get(s: *Store, url: []const u8, why: *std.ArrayList(u8)) Failure!*Package {
        if (s.packages.get(url)) |p| return p;
        const p = try s.gpa.create(Package);
        errdefer s.gpa.destroy(p);
        p.* = .{ .url = try s.gpa.dupe(u8, url), .kind = .generic };
        errdefer p.deinit(s.gpa);
        try s.resolve(p, why);
        try s.packages.put(s.gpa, p.url, p);
        return p;
    }

    // The cache.

    fn cachePath(s: *Store, parts: []const []const u8) !?[]u8 {
        const h = s.opts.home orelse return null;
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(s.gpa);
        try all.appendSlice(s.gpa, &.{ h, "cache" });
        try all.appendSlice(s.gpa, parts);
        return try std.fs.path.join(s.gpa, all.items);
    }

    fn urlHash(url: []const u8) [32]u8 {
        const d = crypto.sha256(url);
        const hex = std.fmt.bytesToHex(d, .lower);
        return hex[0..32].*;
    }

    fn readCache(s: *Store, parts: []const []const u8, max: usize) ?[]u8 {
        const p = (s.cachePath(parts) catch return null) orelse return null;
        defer s.gpa.free(p);
        return Io.Dir.cwd().readFileAlloc(s.io, p, s.gpa, .limited(max)) catch null;
    }

    fn writeCache(s: *Store, parts: []const []const u8, data: []const u8) void {
        const p = (s.cachePath(parts) catch return) orelse return;
        defer s.gpa.free(p);
        const dir = std.fs.path.dirname(p) orelse return;
        Io.Dir.cwd().createDirPath(s.io, dir) catch return;
        var d = Io.Dir.cwd().openDir(s.io, dir, .{}) catch return;
        defer d.close(s.io);
        home_mod.writeAtomic(s.io, d, std.fs.path.basename(p), data) catch {};
    }

    fn now(s: *Store) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_s));
    }

    const Record = struct {
        kind: []const u8,
        release: []const u8 = "",
        version: []const u8 = "",
        signed: []const u8 = "",
        source: []const u8 = "",
        etag: []const u8 = "",
        fetched: i64 = 0,
        expires: i64 = 0,
    };

    fn loadRecord(s: *Store, url: []const u8) ?std.json.Parsed(Record) {
        const h = urlHash(url);
        const bytes = s.readCache(&.{ "modules", &h, "record.json" }, 1 << 16) orelse return null;
        defer s.gpa.free(bytes);
        return std.json.parseFromSlice(Record, s.gpa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }

    fn saveRecord(s: *Store, url: []const u8, r: Record) void {
        const h = urlHash(url);
        const text = std.json.Stringify.valueAlloc(s.gpa, r, .{}) catch return;
        defer s.gpa.free(text);
        s.writeCache(&.{ "modules", &h, "url" }, url);
        s.writeCache(&.{ "modules", &h, "record.json" }, text);
    }

    fn expiresFrom(s: *Store, cache_control: ?[]const u8) i64 {
        var ttl: i64 = default_ttl;
        if (httpc.maxAge(cache_control)) |a| ttl = @intCast(@min(a, @as(u64, @intCast(max_ttl))));
        return s.now() + ttl;
    }

    // Resolution.

    fn resolve(s: *Store, p: *Package, why: *std.ArrayList(u8)) Failure!void {
        const url = p.url;
        var rec = s.loadRecord(url);
        defer if (rec) |*r| r.deinit();
        const fresh = if (rec) |r| r.value.expires > s.now() else false;
        if (rec != null and (s.opts.offline or (fresh and !s.opts.reload))) {
            if (s.fromRecord(p, rec.?.value, why)) return else |e| if (s.opts.offline) return e;
        }
        if (s.opts.offline) return fail(s.gpa, why, "{s} is not in the module cache, and --offline forbids fetching it", .{url});

        var headers: [2]std.http.Header = undefined;
        var nh: usize = 0;
        headers[nh] = .{ .name = "accept", .value = release_type ++ ";v=1, text/plain;q=0.1" };
        nh += 1;
        if (rec) |r| if (r.value.etag.len > 0) {
            headers[nh] = .{ .name = "if-none-match", .value = r.value.etag };
            nh += 1;
        };
        var resp = s.http.get(url, .{ .headers = headers[0..nh], .redirect = httpc.sameHost, .max_body = 16 << 20 }) catch |e| {
            // A server out of reach leaves the stale copy in use.
            if (rec) |r| if (s.fromRecord(p, r.value, why)) {
                if (s.firstWarning(url)) warn(s, "cannot reach the server of {s} ({s}), so lus uses the cached copy", .{ url, @errorName(e) });
                return;
            } else |_| {};
            return fail(s.gpa, why, "cannot fetch {s}: {s}", .{ url, @errorName(e) });
        };
        defer resp.deinit(s.gpa);
        p.fetched = true;

        if (resp.status == 304) {
            if (rec) |r| {
                var nr = r.value;
                nr.expires = s.expiresFrom(resp.cache_control);
                nr.fetched = s.now();
                s.saveRecord(url, nr);
                return s.fromRecord(p, nr, why);
            }
            return fail(s.gpa, why, "cannot fetch {s}: unexpected status 304", .{url});
        }
        const is_release = if (resp.content_type) |ct| std.ascii.startsWithIgnoreCase(ct, release_type) else false;
        if (resp.status != 200) {
            return fail(s.gpa, why, "cannot fetch {s}: {s}", .{ url, errorText(s.gpa, resp) });
        }
        if (is_release) return s.atmosphere(p, resp.body, resp.etag, resp.cache_control, if (rec) |r| r.value else null, why);
        return s.generic(p, resp.body, resp.etag, resp.cache_control, why);
    }

    /// Restores a package from its cache record.
    fn fromRecord(s: *Store, p: *Package, r: Record, why: *std.ArrayList(u8)) Failure!void {
        if (std.mem.eql(u8, r.kind, "generic")) {
            const h = urlHash(p.url);
            const src = s.readCache(&.{ "modules", &h, "source.lus" }, 64 << 20) orelse
                return fail(s.gpa, why, "the cached copy of {s} is incomplete", .{p.url});
            p.kind = .generic;
            p.source = src;
            return;
        }
        const name = try std.mem.concat(s.gpa, u8, &.{ r.release, ".json" });
        defer s.gpa.free(name);
        const doc_bytes = s.readCache(&.{ "releases", name }, 16 << 20) orelse
            return fail(s.gpa, why, "the cached copy of {s} is incomplete", .{p.url});
        defer s.gpa.free(doc_bytes);
        // The cached document was verified when it arrived. Parsing it
        // again restores the fields.
        var parsed = std.json.parseFromSlice(std.json.Value, s.gpa, doc_bytes, .{}) catch
            return fail(s.gpa, why, "the cached copy of {s} is corrupt", .{p.url});
        defer parsed.deinit();
        try s.fill(p, parsed.value.object, why);
        const sha = parsed.value.object.get("sha256").?.string;
        const dir = (try s.cachePath(&.{ "bundles", sha })) orelse return fail(s.gpa, why, "no Lus home to cache {s}", .{p.url});
        p.bundle_dir = dir;
        _ = Io.Dir.cwd().statFile(s.io, dir, .{}) catch return fail(s.gpa, why, "the cached bundle of {s} is missing", .{p.url});
        s.loadIncludes(p);
    }

    fn generic(s: *Store, p: *Package, body: []const u8, etag: ?[]const u8, cc: ?[]const u8, why: *std.ArrayList(u8)) Failure!void {
        if (s.hostKind(hostOf(p.url)) == .atmosphere)
            return fail(s.gpa, why, "{s} answered with a plain file, but its host is an atmosphere server. The response may have been tampered with", .{p.url});
        // A binary chunk from the network would bypass the compiler's
        // checks, so only source text loads.
        if (@import("compile/dump.zig").isBinary(body)) return fail(s.gpa, why, "{s} is a binary chunk, and remote modules must be source", .{p.url});
        p.kind = .generic;
        p.source = try s.gpa.dupe(u8, body);
        const h = urlHash(p.url);
        s.writeCache(&.{ "modules", &h, "source.lus" }, body);
        s.saveRecord(p.url, .{ .kind = "generic", .etag = etag orelse "", .fetched = s.now(), .expires = s.expiresFrom(cc) });
        if (s.opts.home != null and s.hostKind(hostOf(p.url)) == null) s.setHostKind(hostOf(p.url), "generic", null);
    }

    fn hostKind(s: *Store, host: []const u8) ?Kind {
        if (std.mem.eql(u8, host, official_host)) return .atmosphere;
        const bytes = s.readCache(&.{ "hosts", hostFile(host) }, 1 << 16) orelse return null;
        defer s.gpa.free(bytes);
        const parsed = std.json.parseFromSlice(struct { kind: []const u8 }, s.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        return std.meta.stringToEnum(Kind, parsed.value.kind);
    }

    fn setHostKind(s: *Store, host: []const u8, kind: []const u8, root: ?[]const u8) void {
        const text = std.json.Stringify.valueAlloc(s.gpa, .{ .kind = kind, .root = root }, .{}) catch return;
        defer s.gpa.free(text);
        s.writeCache(&.{ "hosts", hostFile(host) }, text);
    }

    /// The file name of a host in the cache, `HOST.json`. A host holds no
    /// slash. Its port separator becomes `_`, since Windows forbids `:`.
    fn hostFile(host: []const u8) []const u8 {
        const S = struct {
            threadlocal var buf: [300]u8 = undefined;
        };
        const n = @min(host.len, S.buf.len - 5);
        for (host[0..n], 0..) |c, i| S.buf[i] = if (c == ':') '_' else c;
        @memcpy(S.buf[n .. n + 5], ".json");
        return S.buf[0 .. n + 5];
    }

    /// The root key of an atmosphere host: embedded for atmosp.here,
    /// pinned on first contact for any other host.
    fn rootKey(s: *Store, host: []const u8, why: *std.ArrayList(u8)) Failure![32]u8 {
        if (std.mem.eql(u8, host, official_host)) {
            const k = release_keys.atmosphere orelse return fail(s.gpa, why, "this build of lus trusts no root key of {s}", .{host});
            return signed.decodePublic(k) orelse return fail(s.gpa, why, "the embedded root key of {s} is malformed", .{host});
        }
        if (s.readCache(&.{ "hosts", hostFile(host) }, 1 << 16)) |bytes| {
            defer s.gpa.free(bytes);
            if (std.json.parseFromSlice(struct { kind: []const u8, root: ?[]const u8 = null }, s.gpa, bytes, .{ .ignore_unknown_fields = true })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.root) |r| if (signed.decodePublic(r)) |k| return k;
            } else |_| {}
        }
        return error.Remote;
    }

    /// Fetches and verifies the key list of a host. A host other than
    /// atmosp.here names its root key in the list, which the store pins.
    fn keyList(s: *Store, host: []const u8, scheme: []const u8, why: *std.ArrayList(u8)) Failure!signed.Document {
        const url = try std.mem.concat(s.gpa, u8, &.{ scheme, host, "/.well-known/atmos-keys.json" });
        defer s.gpa.free(url);
        var resp = s.http.get(url, .{ .redirect = httpc.sameHost, .max_body = 1 << 20 }) catch |e|
            return fail(s.gpa, why, "cannot fetch the keys of {s}: {s}", .{ host, @errorName(e) });
        defer resp.deinit(s.gpa);
        if (resp.status != 200) return fail(s.gpa, why, "cannot fetch the keys of {s}: status {d}", .{ host, resp.status });
        const pinned = s.rootKey(host, why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Remote => if (std.mem.eql(u8, host, official_host)) return error.Remote else null,
        };
        var root: [32]u8 = undefined;
        if (pinned) |k| {
            root = k;
        } else {
            // First contact: the list names its own root.
            var parsed = std.json.parseFromSlice(struct { root: ?[]const u8 = null }, s.gpa, resp.body, .{ .ignore_unknown_fields = true }) catch
                return fail(s.gpa, why, "the key list of {s} is malformed", .{host});
            defer parsed.deinit();
            const r = parsed.value.root orelse return fail(s.gpa, why, "the key list of {s} names no root key", .{host});
            root = signed.decodePublic(r) orelse return fail(s.gpa, why, "the key list of {s} names a malformed root key", .{host});
        }
        var doc = signed.openKeyList(s.gpa, resp.body, root) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (pinned != null) {
                    const file = (try s.cachePath(&.{ "hosts", hostFile(host) })) orelse "";
                    defer if (file.len > 0) s.gpa.free(file);
                    return fail(s.gpa, why, "the key list of {s} is not signed by its pinned root key. Delete {s} to accept a new root key", .{ host, file });
                }
                return fail(s.gpa, why, "the key list of {s} does not verify", .{host});
            },
        };
        errdefer doc.deinit();
        // A list older than the cached one is a replay.
        if (s.readCache(&.{ "keys", hostFile(host) }, 1 << 20)) |old| {
            defer s.gpa.free(old);
            if (signed.openKeyList(s.gpa, old, root)) |od| {
                var o = od;
                defer o.deinit();
                if (doc.signed < o.signed) return fail(s.gpa, why, "the key list of {s} is older than one accepted before", .{host});
            } else |_| {}
        }
        s.writeCache(&.{ "keys", hostFile(host) }, resp.body);
        if (pinned == null) {
            var enc: [44]u8 = undefined;
            const r64 = std.base64.standard.Encoder.encode(&enc, &root);
            s.setHostKind(host, "atmosphere", r64);
        }
        return doc;
    }

    fn keysIn(s: *Store, doc: *const signed.Document, host: []const u8, why: *std.ArrayList(u8)) Failure![]signed.Key {
        return signed.keysOf(s.gpa, doc) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => fail(s.gpa, why, "the key list of {s} is malformed", .{host}),
        };
    }

    /// The signing keys of a host, from the cache when they verify.
    fn cachedKeys(s: *Store, host: []const u8, why: *std.ArrayList(u8)) Failure!?signed.Document {
        const root = s.rootKey(host, why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Remote => return null,
        };
        const bytes = s.readCache(&.{ "keys", hostFile(host) }, 1 << 20) orelse return null;
        defer s.gpa.free(bytes);
        return signed.openKeyList(s.gpa, bytes, root) catch null;
    }

    fn atmosphere(s: *Store, p: *Package, body: []const u8, etag: ?[]const u8, cc: ?[]const u8, prev: ?Record, why: *std.ArrayList(u8)) Failure!void {
        const host = hostOf(p.url);
        const scheme = p.url[0 .. std.mem.indexOf(u8, p.url, "://").? + 3];
        // Verify under the cached keys, and fetch the list again when the
        // document names a key the cache lacks.
        var doc: signed.Document = undefined;
        var have = false;
        if (try s.cachedKeys(host, why)) |kd| {
            var k = kd;
            defer k.deinit();
            const keys = try s.keysIn(&k, host, why);
            defer s.gpa.free(keys);
            if (signed.openDocument(s.gpa, body, keys)) |d| {
                doc = d;
                have = true;
            } else |e| switch (e) {
                error.UnknownKey => {},
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(s.gpa, why, "the release document of {s} does not verify: {s}", .{ p.url, @errorName(e) }),
            }
        }
        if (!have) {
            var kd = try s.keyList(host, scheme, why);
            defer kd.deinit();
            const keys = try s.keysIn(&kd, host, why);
            defer s.gpa.free(keys);
            doc = signed.openDocument(s.gpa, body, keys) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(s.gpa, why, "the release document of {s} does not verify: {s}", .{ p.url, @errorName(e) }),
            };
        }
        defer doc.deinit();
        const o = doc.root();

        try s.fill(p, o, why);
        // The URL names the package, and a pinned URL names its version.
        const last = p.url[std.mem.lastIndexOfScalar(u8, p.url, '/').? + 1 .. p.url.len - 4];
        const at = std.mem.indexOfScalar(u8, last, '@');
        const url_name = if (at) |a| last[0..a] else last;
        if (!std.mem.eql(u8, url_name, p.name)) return fail(s.gpa, why, "{s} answered with the release document of another package, {s}", .{ p.url, p.name });
        if (at) |a| if (!std.mem.eql(u8, last[a + 1 ..], p.version))
            return fail(s.gpa, why, "{s} answered with version {s}", .{ p.url, p.version });

        // The Lus version check decides from the document alone.
        const lus_s = strField(o, "lus") orelse return fail(s.gpa, why, "the release document of {s} has no lus field", .{p.url});
        const line = semver.parseLine(lus_s) orelse return fail(s.gpa, why, "the release document of {s} names a malformed line {s}", .{ p.url, lus_s });
        const min = if (strField(o, "lus_min")) |m| semver.parse(m) else null;
        const running_text = @import("tools/version.zig").runningVersion();
        const running = semver.parse(running_text) orelse semver.Version{ .major = 2, .minor = 0, .patch = 0 };
        if (!semver.runsOn(line, null, running))
            return fail(s.gpa, why, "{s} needs Lus {s}, this is Lus {s}", .{ p.url, lus_s, running_text });
        if (!semver.runsOn(line, min, running))
            return fail(s.gpa, why, "{s} needs Lus {s}, this is Lus {s}", .{ p.url, strField(o, "lus_min").?, running_text });

        // The patch rule of a line URL, which also refuses a replayed
        // older document.
        const is_unstable = std.mem.indexOf(u8, p.url[std.mem.indexOf(u8, p.url, "://").? + 3 ..], "/unstable/") != null;
        if (at == null and !is_unstable) if (prev) |r| if (std.mem.eql(u8, r.kind, "atmosphere")) {
            const old = semver.parse(r.version);
            const new = semver.parse(p.version);
            if (old != null and new != null and (old.?.major != new.?.major or old.?.minor != new.?.minor))
                return fail(s.gpa, why, "{s} moved from {s} to {s}, and a line URL accepts only patch releases", .{ p.url, r.version, p.version });
            if (signed.parseTime(r.signed)) |t| if (doc.signed < t)
                return fail(s.gpa, why, "{s} answered with a release document older than one accepted before", .{p.url});
        };

        // The bundle.
        const sha = strField(o, "sha256") orelse return fail(s.gpa, why, "the release document of {s} has no sha256", .{p.url});
        const size_v = o.get("size") orelse return fail(s.gpa, why, "the release document of {s} has no size", .{p.url});
        if (size_v != .integer) return fail(s.gpa, why, "the release document of {s} has a malformed size", .{p.url});
        const bundle_url = strField(o, "bundle") orelse return fail(s.gpa, why, "the release document of {s} has no bundle", .{p.url});
        const files = o.get("files") orelse return fail(s.gpa, why, "the release document of {s} has no files", .{p.url});
        if (files != .object) return fail(s.gpa, why, "the release document of {s} has malformed files", .{p.url});
        const dir = (try s.cachePath(&.{ "bundles", sha })) orelse return fail(s.gpa, why, "lus needs a Lus home to cache {s}. Set LUS_HOME", .{p.url});
        p.bundle_dir = dir;
        if (Io.Dir.cwd().statFile(s.io, dir, .{})) |_| {} else |_| {
            const abs = try resolveUrl(s.gpa, p.url, bundle_url);
            defer s.gpa.free(abs);
            var b = s.http.get(abs, .{ .max_body = 64 << 20 }) catch |e|
                return fail(s.gpa, why, "cannot fetch the bundle of {s}: {s}", .{ p.url, @errorName(e) });
            defer b.deinit(s.gpa);
            if (b.status != 200) return fail(s.gpa, why, "cannot fetch the bundle of {s}: status {d}", .{ p.url, b.status });
            if (b.body.len != size_v.integer) return fail(s.gpa, why, "the bundle of {s} has {d} bytes, the release document says {d}", .{ p.url, b.body.len, size_v.integer });
            const hex = std.fmt.bytesToHex(crypto.sha256(b.body), .lower);
            if (!std.mem.eql(u8, &hex, sha)) return fail(s.gpa, why, "the bundle of {s} does not match its SHA-256 digest", .{p.url});
            try s.unpack(p.url, b.body, dir, files.object, why);
        }
        s.loadIncludes(p);

        if (o.get("yanked")) |y| if (y == .bool and y.bool) if (s.firstWarning(p.url))
            warn(s, "{s} is version {s}, which its author withdrew", .{ p.url, p.version });
        if (strField(o, "deprecated")) |m| {
            const key = try std.mem.concat(s.gpa, u8, &.{ p.url, "#deprecated" });
            defer s.gpa.free(key);
            if (s.firstWarning(key)) warn(s, "{s} is deprecated: {s}", .{ p.url, m });
        }

        const doc_hex = std.fmt.bytesToHex(crypto.sha256(body), .lower);
        const doc_name = try std.mem.concat(s.gpa, u8, &.{ &doc_hex, ".json" });
        defer s.gpa.free(doc_name);
        s.writeCache(&.{ "releases", doc_name }, body);
        var tb: [20]u8 = undefined;
        s.saveRecord(p.url, .{
            .kind = "atmosphere",
            .release = &doc_hex,
            .version = p.version,
            .signed = signed.formatTime(&tb, doc.signed),
            .etag = etag orelse "",
            .fetched = s.now(),
            .expires = if (at != null) s.now() + max_ttl else s.expiresFrom(cc),
        });
        if (s.hostKind(host) == null) {
            const root = s.rootKey(host, why) catch null;
            var enc: [44]u8 = undefined;
            s.setHostKind(host, "atmosphere", if (root) |r| std.base64.standard.Encoder.encode(&enc, &r) else null);
        }
    }

    /// Reads the `@includes` annotations of the main module's header, which
    /// name the dependencies copied into the bundle.
    fn loadIncludes(s: *Store, p: *Package) void {
        const src = (p.read(s.gpa, s.io, null) catch return) orelse return;
        defer s.gpa.free(src);
        var list: std.ArrayList([]u8) = .empty;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "---")) break;
            const body = std.mem.trim(u8, line[3..], " \t");
            if (!std.mem.startsWith(u8, body, "@includes ")) continue;
            var words = std.mem.tokenizeAny(u8, body["@includes ".len..], " \t");
            const name = words.next() orelse continue;
            const owned = s.gpa.dupe(u8, name) catch break;
            list.append(s.gpa, owned) catch {
                s.gpa.free(owned);
                break;
            };
        }
        p.includes = list.toOwnedSlice(s.gpa) catch &.{};
    }

    /// Copies the fields of a verified release document into `p`.
    fn fill(s: *Store, p: *Package, o: std.json.ObjectMap, why: *std.ArrayList(u8)) Failure!void {
        p.kind = .atmosphere;
        const name = strField(o, "name") orelse return fail(s.gpa, why, "the release document of {s} has no name", .{p.url});
        const version = strField(o, "version") orelse return fail(s.gpa, why, "the release document of {s} has no version", .{p.url});
        const main = strField(o, "main") orelse return fail(s.gpa, why, "the release document of {s} has no main", .{p.url});
        if (!safePath(main)) return fail(s.gpa, why, "the release document of {s} names a malformed main module", .{p.url});
        p.name = try s.gpa.dupe(u8, name);
        p.version = try s.gpa.dupe(u8, version);
        p.main = try s.gpa.dupe(u8, main);
        var reqs: std.ArrayList([]u8) = .empty;
        errdefer {
            for (reqs.items) |r| s.gpa.free(r);
            reqs.deinit(s.gpa);
        }
        if (o.get("requires")) |r| if (r == .array) for (r.array.items) |it| if (it == .string) try reqs.append(s.gpa, try s.gpa.dupe(u8, it.string));
        p.requires = try reqs.toOwnedSlice(s.gpa);
        var defs: std.ArrayList([]u8) = .empty;
        errdefer {
            for (defs.items) |d| s.gpa.free(d);
            defs.deinit(s.gpa);
        }
        if (o.get("flags")) |f| if (f == .array) for (f.array.items) |it| {
            if (it != .object) continue;
            const fname = strField(it.object, "name") orelse continue;
            const dv = it.object.get("default") orelse continue;
            switch (dv) {
                .null => {},
                .bool => |b| if (b) try defs.append(s.gpa, try s.gpa.dupe(u8, fname)),
                .integer => |i| try defs.append(s.gpa, try std.fmt.allocPrint(s.gpa, "{s}={d}", .{ fname, i })),
                .float => |x| try defs.append(s.gpa, try std.fmt.allocPrint(s.gpa, "{s}={d}", .{ fname, x })),
                .string => |t| try defs.append(s.gpa, try std.fmt.allocPrint(s.gpa, "{s}={s}", .{ fname, t })),
                else => {},
            }
        };
        p.flag_defaults = try defs.toOwnedSlice(s.gpa);
    }

    /// Unpacks a verified bundle into `dir` through a temporary directory.
    fn unpack(s: *Store, url: []const u8, compressed: []const u8, dir: []const u8, files: std.json.ObjectMap, why: *std.ArrayList(u8)) Failure!void {
        var in: Io.Reader = .fixed(compressed);
        const window = s.gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max) catch return error.OutOfMemory;
        defer s.gpa.free(window);
        var dec: std.compress.zstd.Decompress = .init(&in, window, .{});
        var tar: std.Io.Writer.Allocating = .init(s.gpa);
        defer tar.deinit();
        _ = dec.reader.streamRemaining(&tar.writer) catch return fail(s.gpa, why, "the bundle of {s} is not valid Zstandard data", .{url});
        if (tar.written().len > max_unpacked + max_entries * 1024) return fail(s.gpa, why, "the bundle of {s} unpacks to more than 64 MiB", .{url});
        const entries = try parseTar(s.gpa, tar.written(), why, url);
        defer freeEntries(s.gpa, entries);

        // The bundle must hold exactly the files of the document.
        var count: usize = 0;
        for (entries) |e| if (!e.dir) {
            count += 1;
            const want = files.get(e.name) orelse return fail(s.gpa, why, "the bundle of {s} holds {s}, which the release document does not list", .{ url, e.name });
            if (want != .string) return fail(s.gpa, why, "the release document of {s} has a malformed digest", .{url});
            const hex = std.fmt.bytesToHex(crypto.sha256(e.data), .lower);
            if (!std.mem.eql(u8, &hex, want.string)) return fail(s.gpa, why, "{s} in the bundle of {s} does not match its digest", .{ e.name, url });
        };
        if (count != files.count()) return fail(s.gpa, why, "the bundle of {s} lacks files that the release document lists", .{url});

        const parent = std.fs.path.dirname(dir).?;
        Io.Dir.cwd().createDirPath(s.io, parent) catch |e| return fail(s.gpa, why, "cannot create {s}: {s}", .{ parent, @errorName(e) });
        var rnd: [6]u8 = undefined;
        s.io.random(&rnd);
        const tmp = try std.fmt.allocPrint(s.gpa, "{s}.tmp-{x}", .{ dir, rnd });
        defer s.gpa.free(tmp);
        Io.Dir.cwd().createDirPath(s.io, tmp) catch |e| return fail(s.gpa, why, "cannot create {s}: {s}", .{ tmp, @errorName(e) });
        errdefer Io.Dir.cwd().deleteTree(s.io, tmp) catch {};
        var d = Io.Dir.cwd().openDir(s.io, tmp, .{}) catch |e| return fail(s.gpa, why, "cannot open {s}: {s}", .{ tmp, @errorName(e) });
        defer d.close(s.io);
        for (entries) |e| {
            if (e.dir) {
                d.createDirPath(s.io, e.name) catch |er| return fail(s.gpa, why, "cannot unpack {s}: {s}", .{ e.name, @errorName(er) });
                continue;
            }
            if (std.fs.path.dirname(e.name)) |pd| d.createDirPath(s.io, pd) catch |er| return fail(s.gpa, why, "cannot unpack {s}: {s}", .{ e.name, @errorName(er) });
            d.writeFile(s.io, .{ .sub_path = e.name, .data = e.data }) catch |er| return fail(s.gpa, why, "cannot unpack {s}: {s}", .{ e.name, @errorName(er) });
        }
        Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dir, s.io) catch |e| {
            // Another process unpacked the same bundle first.
            if (Io.Dir.cwd().statFile(s.io, dir, .{})) |_| {
                Io.Dir.cwd().deleteTree(s.io, tmp) catch {};
                return;
            } else |_| {}
            return fail(s.gpa, why, "cannot install the bundle of {s}: {s}", .{ url, @errorName(e) });
        };
    }
};

fn strField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn errorText(gpa: Allocator, r: httpc.Response) []const u8 {
    _ = gpa;
    // An atmosphere error carries a message. Any other status is reported
    // by number.
    if (std.mem.indexOf(u8, r.body, "\"message\":\"")) |i| {
        const rest = r.body[i + 11 ..];
        if (std.mem.indexOfScalar(u8, rest, '"')) |e| return rest[0..e];
    }
    return switch (r.status) {
        404 => "not found (status 404)",
        410 => "removed (status 410)",
        451 => "withheld for a legal reason (status 451)",
        else => "unexpected status",
    };
}

/// Whether a bundle path is a plain relative path: no absolute path, no
/// empty, `.`, or `..` segment, and only `A-Z a-z 0-9 . _ - /`.
pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    for (path) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/')) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    return true;
}

const TarEntry = struct { name: []const u8, data: []const u8, dir: bool, owned: bool = false };

fn freeEntries(gpa: Allocator, entries: []TarEntry) void {
    for (entries) |e| if (e.owned) gpa.free(e.name);
    gpa.free(entries);
}

/// Parses a ustar archive under the limits of a bundle. The entries point
/// into `bytes`.
fn parseTar(gpa: Allocator, bytes: []const u8, why: *std.ArrayList(u8), url: []const u8) Failure![]TarEntry {
    var out: std.ArrayList(TarEntry) = .empty;
    errdefer {
        for (out.items) |e| if (e.owned) gpa.free(e.name);
        out.deinit(gpa);
    }
    var pos: usize = 0;
    var total: usize = 0;
    while (pos + 512 <= bytes.len) {
        const h = bytes[pos .. pos + 512];
        if (std.mem.allEqual(u8, h, 0)) break;
        var sum: u32 = 0;
        for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
        const want = std.fmt.parseInt(u32, std.mem.trim(u8, h[148..156], " \x00"), 8) catch return fail(gpa, why, "the bundle of {s} is not a ustar archive", .{url});
        if (sum != want) return fail(gpa, why, "the bundle of {s} has a corrupt tar header", .{url});
        if (!std.mem.eql(u8, h[257..262], "ustar")) return fail(gpa, why, "the bundle of {s} is not a ustar archive", .{url});
        const name_part = std.mem.sliceTo(h[0..100], 0);
        const prefix = std.mem.sliceTo(h[345..500], 0);
        var name_buf: [256]u8 = undefined;
        const name = if (prefix.len > 0) std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ prefix, name_part }) catch unreachable else name_part;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, h[124..136], " \x00"), 8) catch return fail(gpa, why, "the bundle of {s} has a corrupt tar header", .{url});
        const typ = h[156];
        pos += 512;
        if (pos + size > bytes.len) return fail(gpa, why, "the bundle of {s} is truncated", .{url});
        const data = bytes[pos .. pos + size];
        pos += (size + 511) / 512 * 512;
        const is_dir = typ == '5';
        if (!is_dir and typ != '0' and typ != 0) return fail(gpa, why, "the bundle of {s} holds {s}, which is not a regular file or a directory", .{ url, name });
        const trimmed = std.mem.trimEnd(u8, name, "/");
        if (!safePath(trimmed)) return fail(gpa, why, "the bundle of {s} holds the unsafe path {s}", .{ url, name });
        if (out.items.len >= max_entries) return fail(gpa, why, "the bundle of {s} holds more than {d} entries", .{ url, max_entries });
        total += size;
        if (total > max_unpacked) return fail(gpa, why, "the bundle of {s} unpacks to more than 64 MiB", .{url});
        // A plain name points into the header block. A name with a prefix
        // was rebuilt in a buffer, so it needs a copy.
        if (prefix.len > 0) {
            try out.append(gpa, .{ .name = try gpa.dupe(u8, trimmed), .data = data, .dir = is_dir, .owned = true });
        } else {
            try out.append(gpa, .{ .name = trimmed, .data = data, .dir = is_dir });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Resolves `ref`, absolute or relative, against `base`.
pub fn resolveUrl(gpa: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    if (isUrl(ref)) return gpa.dupe(u8, ref);
    if (ref.len > 0 and ref[0] == '/') {
        const scheme_end = std.mem.indexOf(u8, base, "://").? + 3;
        const host_end = scheme_end + (std.mem.indexOfScalar(u8, base[scheme_end..], '/') orelse base.len - scheme_end);
        return std.mem.concat(gpa, u8, &.{ base[0..host_end], ref });
    }
    return std.mem.concat(gpa, u8, &.{ dirOf(base), ref });
}

fn warn(s: *Store, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(s.gpa, "lus: warning: " ++ fmt ++ "\n", args) catch return;
    defer s.gpa.free(msg);
    Io.File.stderr().writeStreamingAll(s.io, msg) catch {};
}

/// The store of the running program, or null when remote modules are
/// unavailable. Every entry point of the CLI that runs Lus code installs
/// one with `Process` before it creates a state.
pub var store: ?*Store = null;

/// The store of one process: the Lus home and the store, installed as
/// `store` from `begin` to `end`. It must outlive every state of the
/// process, because workers read it until their state stops them.
pub const Process = struct {
    gpa: Allocator,
    home: ?[]u8,
    store: Store,

    pub fn begin(p: *Process, gpa: Allocator, io: Io, env: ?*const std.process.Environ.Map, opts: struct {
        ignore_env: bool = false,
        offline: bool = false,
        reload: bool = false,
    }) void {
        const h = if (opts.ignore_env) null else (home_mod.path(gpa, env) catch null);
        p.* = .{
            .gpa = gpa,
            .home = h,
            .store = .init(gpa, io, .{ .home = h, .offline = opts.offline, .reload = opts.reload, .env = env }),
        };
        store = &p.store;
    }

    pub fn end(p: *Process) void {
        store = null;
        p.store.deinit();
        if (p.home) |h| p.gpa.free(h);
    }
};

/// The reason `require` gives when `store` is null.
pub const unavailable = if (builtin.cpu.arch.isWasm())
    "remote modules are unavailable in the WebAssembly build, which has no network library"
else
    "remote modules are unavailable here, because the host that embeds Lus set up no module store";

test "normalize" {
    const gpa = std.testing.allocator;
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    const cases = [_][2][]const u8{
        .{ "https://Atmosp.HERE/2.0/dates.lus", "https://atmosp.here/2.0/dates.lus" },
        .{ "https://atmosp.here:443/2.0/./x/../dates.lus", "https://atmosp.here/2.0/dates.lus" },
        .{ "http://127.0.0.1:8080/a/b.lus", "http://127.0.0.1:8080/a/b.lus" },
    };
    for (cases) |c| {
        const n = try normalize(gpa, c[0], &why);
        defer gpa.free(n);
        try std.testing.expectEqualStrings(c[1], n);
    }
    for ([_][]const u8{ "http://example.com/a.lus", "https://example.com/a.lua", "https://example.com/a.lus?x=1", "https://example.com/a.lus#f" }) |bad| {
        try std.testing.expectError(error.Remote, normalize(gpa, bad, &why));
    }
    try std.testing.expectEqualStrings("atmosp.here", hostOf("https://atmosp.here/2.0/dates.lus"));
    try std.testing.expectEqualStrings("https://atmosp.here/2.0/", dirOf("https://atmosp.here/2.0/dates.lus"));
    try std.testing.expect(safePath("dates/zones.lus"));
    try std.testing.expect(!safePath("../x.lus"));
    try std.testing.expect(!safePath("/abs.lus"));
    try std.testing.expect(!safePath("a b.lus"));
}
