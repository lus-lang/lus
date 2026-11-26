//! `lus version`: installs, lists, selects, and removes releases of Lus,
//! and `lus +REQUEST`, which runs a command under another installed
//! release. The commands, the JSON output, the exit statuses, and the
//! directory layout are frozen from Lus 2.0 (`spec/tools/version.md`,
//! `spec/design/modules.md` section 1).
//!
//! Usage:
//!
//!   lus version [--json]
//!   lus version list [--remote [CHANNEL]] [--json]
//!   lus version install REQUEST [--json]
//!   lus version use REQUEST [--json]
//!   lus version remove VERSION [--json]
//!   lus version which [REQUEST] [--json]
//!   lus +REQUEST [ARGS...]

const std = @import("std");
const builtin = @import("builtin");
const lus = @import("../lus.zig");
const semver = lus.semver;
const signed = lus.signed;
const httpc = lus.httpc;
const home_mod = @import("../home.zig");
const release_keys = @import("../release_keys.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Version = semver.Version;
const Channel = semver.Channel;

const usage = @import("usage.zig").of("version");

/// The exit statuses of the version manager.
pub const Status = enum(u8) {
    ok = 0,
    failed = 1,
    usage = 2,
    not_found = 3,
    verify = 4,
    in_use = 5,
};

const default_release_url = "https://lus.dev/releases/";

/// The name of the release archive target of this build.
pub const target_name: []const u8 = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-macos",
        else => "x86_64-macos",
    },
    .windows => switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-windows",
        else => "x86_64-windows",
    },
    .freebsd => switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-freebsd",
        else => "x86_64-freebsd",
    },
    else => switch (builtin.cpu.arch) {
        .aarch64 => "aarch64-linux-musl",
        .arm => "arm-linux-musleabihf",
        .riscv64 => "riscv64-linux-musl",
        .loongarch64 => "loongarch64-linux-musl",
        .powerpc64le => "powerpc64le-linux-musl",
        .s390x => "s390x-linux-musl",
        else => "x86_64-linux-musl",
    },
};

/// The version of the running binary, without the "Lus " of `lus -v`.
pub fn runningVersion() []const u8 {
    const v = lus.api.version;
    return if (std.mem.startsWith(u8, v, "Lus ")) v[4..] else v;
}

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    env: ?*const std.process.Environ.Map,
    json: bool = false,
    home: []u8 = &.{},

    fn deinit(c: *Ctx) void {
        if (c.home.len > 0) c.gpa.free(c.home);
    }

    fn out(c: *Ctx, text: []const u8) void {
        Io.File.stdout().writeStreamingAll(c.io, text) catch {};
    }

    fn outFmt(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(c.gpa, fmt, args) catch return;
        defer c.gpa.free(s);
        c.out(s);
    }

    fn warn(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(c.gpa, "lus version: warning: " ++ fmt ++ "\n", args) catch return;
        defer c.gpa.free(s);
        Io.File.stderr().writeStreamingAll(c.io, s) catch {};
    }

    /// Prints a JSON object as one line on standard output.
    fn emit(c: *Ctx, v: anytype) void {
        const s = std.json.Stringify.valueAlloc(c.gpa, v, .{}) catch return;
        defer c.gpa.free(s);
        c.out(s);
        c.out("\n");
    }

    /// Reports a failure in the format that `--json` selects and returns
    /// its status.
    fn fail(c: *Ctx, status: Status, code: []const u8, comptime fmt: []const u8, args: anytype) u8 {
        const msg = std.fmt.allocPrint(c.gpa, fmt, args) catch return @backingInt(status);
        defer c.gpa.free(msg);
        if (c.json) {
            c.emit(.{ .schema = 1, .@"error" = .{ .code = code, .message = msg } });
        } else {
            const line = std.fmt.allocPrint(c.gpa, "lus version: {s}\n", .{msg}) catch return @backingInt(status);
            defer c.gpa.free(line);
            Io.File.stderr().writeStreamingAll(c.io, line) catch {};
        }
        return @backingInt(status);
    }

    fn usageError(c: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
        const r = c.fail(.usage, "usage", fmt, args);
        if (!c.json) Io.File.stderr().writeStreamingAll(c.io, usage) catch {};
        return r;
    }

    fn openHome(c: *Ctx) !Io.Dir {
        return Io.Dir.cwd().createDirPathOpen(c.io, c.home, .{});
    }

    fn path(c: *Ctx, parts: []const []const u8) ![]u8 {
        return home_mod.join(c.gpa, c.home, parts);
    }
};

/// One installed version.
const Installed = struct {
    text: []u8,
    version: Version,
    channel: ?Channel,
};

fn freeInstalled(gpa: Allocator, list: []Installed) void {
    for (list) |i| gpa.free(i.text);
    gpa.free(list);
}

/// Lists the installed versions in ascending order.
fn listInstalled(c: *Ctx) ![]Installed {
    var out: std.ArrayList(Installed) = .empty;
    errdefer {
        for (out.items) |i| c.gpa.free(i.text);
        out.deinit(c.gpa);
    }
    const vpath = try c.path(&.{"versions"});
    defer c.gpa.free(vpath);
    var dir = Io.Dir.cwd().openDir(c.io, vpath, .{ .iterate = true }) catch return out.toOwnedSlice(c.gpa);
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |e| {
        if (e.kind != .directory or e.name.len == 0 or e.name[0] == '.') continue;
        const text = try c.gpa.dupe(u8, e.name);
        const v = semver.parse(text) orelse {
            c.gpa.free(text);
            continue;
        };
        var buf: [32]u8 = undefined;
        const ch_path = try std.fs.path.join(c.gpa, &.{ text, "channel" });
        defer c.gpa.free(ch_path);
        const ch_text = dir.readFile(c.io, ch_path, &buf) catch "";
        try out.append(c.gpa, .{ .text = text, .version = v, .channel = Channel.parse(std.mem.trim(u8, ch_text, " \r\n\t")) });
    }
    std.mem.sort(Installed, out.items, {}, struct {
        fn lt(_: void, a: Installed, b: Installed) bool {
            return a.version.order(b.version) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(c.gpa);
}

/// The exact default version, or null.
fn readDefault(c: *Ctx) ?[]u8 {
    const p = c.path(&.{"default"}) catch return null;
    defer c.gpa.free(p);
    var buf: [128]u8 = undefined;
    const t = Io.Dir.cwd().readFile(c.io, p, &buf) catch return null;
    const v = std.mem.trim(u8, t, " \r\n\t");
    if (semver.parse(v) == null) return null;
    return c.gpa.dupe(u8, v) catch null;
}

/// The highest installed version that `req` selects.
fn pickInstalled(list: []const Installed, req: semver.Request) ?Installed {
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (req.matches(list[i].version, list[i].channel)) return list[i];
    }
    return null;
}

fn exePath(c: *Ctx, version: []const u8) ![]u8 {
    return c.path(&.{ "versions", version, "bin", home_mod.exe_name });
}

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    var c: Ctx = .{ .gpa = init.gpa, .io = init.io, .env = init.environ_map };
    defer c.deinit();
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(c.gpa);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            c.json = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            c.out(usage);
            return 0;
        } else try rest.append(c.gpa, a);
    }
    const r = rest.items;
    if (r.len == 0) return cmdSelf(&c);
    c.home = (try home_mod.path(c.gpa, c.env)) orelse
        return c.fail(.failed, "io", "cannot find the Lus home: set LUS_HOME or HOME", .{});
    const cmd = r[0];
    const sub = r[1..];
    if (std.mem.eql(u8, cmd, "list")) return cmdList(&c, sub);
    if (std.mem.eql(u8, cmd, "install")) return cmdInstall(&c, sub);
    if (std.mem.eql(u8, cmd, "use")) return cmdUse(&c, sub);
    if (std.mem.eql(u8, cmd, "remove")) return cmdRemove(&c, sub);
    if (std.mem.eql(u8, cmd, "which")) return cmdWhich(&c, sub);
    return c.usageError("unknown command '{s}'", .{cmd});
}

fn cmdSelf(c: *Ctx) !u8 {
    if (c.json) {
        const self = std.process.executablePathAlloc(c.io, c.gpa) catch null;
        defer if (self) |s| c.gpa.free(s);
        c.emit(.{ .schema = 1, .version = runningVersion(), .path = if (self) |s| @as([]const u8, s) else null });
    } else {
        c.outFmt("{s}\n", .{lus.api.version});
    }
    return 0;
}

fn parseReq(c: *Ctx, text: []const u8) ?semver.Request {
    _ = c;
    return semver.parseRequest(text);
}

fn cmdList(c: *Ctx, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--remote")) {
        if (args.len > 2) return c.usageError("too many arguments", .{});
        const ch: Channel = if (args.len == 2) Channel.parse(args[1]) orelse
            return c.usageError("unknown channel '{s}'", .{args[1]}) else .stable;
        return listRemote(c, ch);
    }
    if (args.len > 0) return c.usageError("unexpected argument '{s}'", .{args[0]});
    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    const def = readDefault(c);
    defer if (def) |d| c.gpa.free(d);
    if (c.json) {
        const Item = struct { version: []const u8, channel: ?[]const u8, default: bool, path: []const u8 };
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |i| c.gpa.free(i.path);
            items.deinit(c.gpa);
        }
        for (list) |i| try items.append(c.gpa, .{
            .version = i.text,
            .channel = if (i.channel) |ch| @tagName(ch) else null,
            .default = if (def) |d| std.mem.eql(u8, d, i.text) else false,
            .path = try exePath(c, i.text),
        });
        c.emit(.{ .schema = 1, .default = def, .versions = items.items });
    } else {
        for (list) |i| {
            const is_def = if (def) |d| std.mem.eql(u8, d, i.text) else false;
            c.outFmt("{s}{s}{s}\n", .{ i.text, if (i.channel) |ch| if (ch == .unstable) "  unstable" else "" else "", if (is_def) "  default" else "" });
        }
    }
    return 0;
}

fn cmdWhich(c: *Ctx, args: []const []const u8) !u8 {
    if (args.len > 1) return c.usageError("too many arguments", .{});
    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    var chosen: []const u8 = undefined;
    var def: ?[]u8 = null;
    defer if (def) |d| c.gpa.free(d);
    if (args.len == 0) {
        def = readDefault(c);
        chosen = def orelse return c.fail(.not_found, "not-installed", "no default version is set", .{});
    } else {
        const req = parseReq(c, args[0]) orelse return c.usageError("malformed version request '{s}'", .{args[0]});
        const i = pickInstalled(list, req) orelse return c.fail(.not_found, "not-installed", "lus {s} is not installed", .{args[0]});
        chosen = i.text;
    }
    const p = try exePath(c, chosen);
    defer c.gpa.free(p);
    if (c.json) c.emit(.{ .schema = 1, .version = chosen, .path = p }) else c.outFmt("{s}\n", .{p});
    if (args.len == 0) warnShadowed(c);
    return 0;
}

fn cmdRemove(c: *Ctx, args: []const []const u8) !u8 {
    if (args.len != 1) return c.usageError("remove needs one exact version", .{});
    const v = semver.parse(args[0]) orelse return c.usageError("'{s}' is not an exact version", .{args[0]});
    _ = v;
    var hd = c.openHome() catch |e| return c.fail(.failed, "io", "cannot open {s}: {s}", .{ c.home, @errorName(e) });
    defer hd.close(c.io);
    const lock = home_mod.Lock.acquire(c.io, hd) catch |e| return c.fail(.failed, "io", "cannot lock {s}: {s}", .{ c.home, @errorName(e) });
    defer lock.release(c.io);
    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    const found = for (list) |i| {
        if (std.mem.eql(u8, i.text, args[0])) break true;
    } else false;
    if (!found) return c.fail(.not_found, "not-installed", "lus {s} is not installed", .{args[0]});
    const def = readDefault(c);
    defer if (def) |d| c.gpa.free(d);
    if (def != null and std.mem.eql(u8, def.?, args[0]))
        return c.fail(.in_use, "in-use", "lus {s} is the default version. Run `lus version use` with another version first", .{args[0]});
    const sub = try std.fs.path.join(c.gpa, &.{ "versions", args[0] });
    defer c.gpa.free(sub);
    hd.deleteTree(c.io, sub) catch |e| return c.fail(.failed, "io", "cannot remove {s}: {s}", .{ sub, @errorName(e) });
    if (c.json) c.emit(.{ .schema = 1, .version = args[0], .removed = true }) else c.outFmt("removed lus {s}\n", .{args[0]});
    return 0;
}

fn cmdUse(c: *Ctx, args: []const []const u8) !u8 {
    if (args.len != 1) return c.usageError("use needs one version request", .{});
    const req = parseReq(c, args[0]) orelse return c.usageError("malformed version request '{s}'", .{args[0]});
    var hd = c.openHome() catch |e| return c.fail(.failed, "io", "cannot open {s}: {s}", .{ c.home, @errorName(e) });
    defer hd.close(c.io);
    const lock = home_mod.Lock.acquire(c.io, hd) catch |e| return c.fail(.failed, "io", "cannot lock {s}: {s}", .{ c.home, @errorName(e) });
    defer lock.release(c.io);
    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    const i = pickInstalled(list, req) orelse return c.fail(.not_found, "not-installed", "lus {s} is not installed. Run `lus version install {s}`", .{ args[0], args[0] });
    const previous = readDefault(c);
    defer if (previous) |p| c.gpa.free(p);
    setDefault(c, hd, i.text) catch |e| return c.fail(.failed, "io", "cannot set the default version: {s}", .{@errorName(e)});
    const link = try c.path(&.{ "bin", home_mod.exe_name });
    defer c.gpa.free(link);
    if (c.json) c.emit(.{ .schema = 1, .version = i.text, .path = link, .previous = previous }) else c.outFmt("lus {s} is now the default\n", .{i.text});
    warnShadowed(c);
    return 0;
}

/// Points `bin/lus` at a version and records it in `default`.
fn setDefault(c: *Ctx, hd: Io.Dir, version: []const u8) !void {
    try hd.createDirPath(c.io, "bin");
    var rnd: [6]u8 = undefined;
    c.io.random(&rnd);
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "bin" ++ home_mod.sep ++ ".{s}.{x}", .{ home_mod.exe_name, rnd });
    const dest = "bin" ++ home_mod.sep ++ home_mod.exe_name;
    if (home_mod.is_windows) {
        // A hard link needs no privilege on NTFS. Another filesystem gets
        // a copy.
        const src = try std.fs.path.join(c.gpa, &.{ "versions", version, "bin", home_mod.exe_name });
        defer c.gpa.free(src);
        hd.hardLink(src, hd, tmp, c.io, .{}) catch {
            try hd.copyFile(src, hd, tmp, c.io, .{});
        };
    } else {
        const target = try std.fs.path.join(c.gpa, &.{ "..", "versions", version, "bin", home_mod.exe_name });
        defer c.gpa.free(target);
        try hd.symLink(c.io, target, tmp, .{});
    }
    hd.rename(tmp, hd, dest, c.io) catch |e| {
        hd.deleteFile(c.io, tmp) catch {};
        return e;
    };
    var line: [80]u8 = undefined;
    try home_mod.writeAtomic(c.io, hd, "default", try std.fmt.bufPrint(&line, "{s}\n", .{version}));
}

/// Warns when the first `lus` on `PATH` is another file than `bin/lus` of
/// the home.
fn warnShadowed(c: *Ctx) void {
    const env = c.env orelse return;
    const path_var = env.get("PATH") orelse return;
    const ours = c.path(&.{ "bin", home_mod.exe_name }) catch return;
    defer c.gpa.free(ours);
    const ours_real = Io.Dir.cwd().realPathFileAlloc(c.io, ours, c.gpa) catch return;
    defer c.gpa.free(ours_real);
    var it = std.mem.tokenizeScalar(u8, path_var, if (home_mod.is_windows) ';' else ':');
    while (it.next()) |d| {
        const cand = std.fs.path.join(c.gpa, &.{ d, home_mod.exe_name }) catch return;
        defer c.gpa.free(cand);
        const real = Io.Dir.cwd().realPathFileAlloc(c.io, cand, c.gpa) catch continue;
        defer c.gpa.free(real);
        if (!std.mem.eql(u8, real, ours_real)) c.warn("{s} comes first on PATH, so `lus` runs that file. Put {s}{s}bin first on PATH", .{ cand, c.home, home_mod.sep });
        return;
    }
}

// The release index.

const Asset = struct { url: []const u8, sha256: []const u8, size: u64 };

const Release = struct {
    version: Version,
    text: []const u8,
    channel: Channel,
    published: []const u8,
    asset: ?Asset,
};

const Index = struct {
    doc: signed.Document,
    releases: []Release,
    stable: ?[]const u8,
    unstable: ?[]const u8,

    fn deinit(ix: *Index, gpa: Allocator) void {
        gpa.free(ix.releases);
        ix.doc.deinit();
    }
};

fn releaseBase(c: *Ctx) []const u8 {
    if (c.env) |e| if (e.get("LUS_RELEASE_URL")) |u| if (u.len > 0) return u;
    return default_release_url;
}

fn baseIsLoopback(base: []const u8) bool {
    const uri = std.Uri.parse(base) catch return false;
    var buf: [256]u8 = undefined;
    const h = httpc.hostOf(uri, &buf) orelse return false;
    return httpc.isLoopback(h);
}

/// The root key: the embedded key, or `LUS_RELEASE_KEY` for a loopback
/// release URL.
fn rootKey(c: *Ctx, base: []const u8) ?[32]u8 {
    if (baseIsLoopback(base)) if (c.env) |e| if (e.get("LUS_RELEASE_KEY")) |k| return signed.decodePublic(k);
    const k = release_keys.lus_release orelse return null;
    return signed.decodePublic(k);
}

const FetchFail = struct { status: Status, code: []const u8, msg: []u8 };

fn joinUrl(gpa: Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base, "/")) return std.mem.concat(gpa, u8, &.{ base, name });
    return std.mem.concat(gpa, u8, &.{ base, "/", name });
}

fn fetchOk(c: *Ctx, client: *httpc.Client, url: []const u8, max: usize) !httpc.Response {
    var r = client.get(url, .{ .max_body = max }) catch |e| {
        _ = c.fail(.failed, "network", "cannot download {s}: {s}", .{ url, @errorName(e) });
        return error.Reported;
    };
    if (r.status != 200) {
        const s = r.status;
        r.deinit(c.gpa);
        _ = c.fail(.failed, "network", "cannot download {s}: status {d}", .{ url, s });
        return error.Reported;
    }
    return r;
}

/// Downloads and verifies the release index. Prints the failure and
/// returns error.Reported with the status in `status`.
fn loadIndex(c: *Ctx, client: *httpc.Client, status: *Status) !Index {
    const base = releaseBase(c);
    const root = rootKey(c, base) orelse {
        status.* = .verify;
        _ = c.fail(.verify, "verify", "this build of lus trusts no release key", .{});
        return error.Reported;
    };
    status.* = .failed;
    const keys_url = try joinUrl(c.gpa, base, "keys.json");
    defer c.gpa.free(keys_url);
    var kr = try fetchOk(c, client, keys_url, 1 << 20);
    defer kr.deinit(c.gpa);
    var klist = signed.openKeyList(c.gpa, kr.body, root) catch |e| {
        status.* = .verify;
        _ = c.fail(.verify, "verify", "the release key list does not verify: {s}", .{@errorName(e)});
        return error.Reported;
    };
    defer klist.deinit();
    const keys = try signed.keysOf(c.gpa, &klist);
    defer c.gpa.free(keys);

    const index_url = try joinUrl(c.gpa, base, "index.json");
    defer c.gpa.free(index_url);
    var ir = try fetchOk(c, client, index_url, 16 << 20);
    defer ir.deinit(c.gpa);
    // The document keeps slices of its bytes, so it owns a copy.
    var doc = signed.openDocument(c.gpa, ir.body, keys) catch |e| {
        status.* = .verify;
        _ = c.fail(.verify, "verify", "the release index does not verify: {s}", .{@errorName(e)});
        return error.Reported;
    };
    errdefer doc.deinit();

    // Refuse an index older than the newest one accepted so far.
    var hd = c.openHome() catch |e| {
        _ = c.fail(.failed, "io", "cannot open {s}: {s}", .{ c.home, @errorName(e) });
        return error.Reported;
    };
    defer hd.close(c.io);
    var seen_buf: [64]u8 = undefined;
    const seen_path = "index" ++ home_mod.sep ++ "seen";
    if (hd.readFile(c.io, seen_path, &seen_buf)) |t| {
        if (signed.parseTime(std.mem.trim(u8, t, " \r\n\t"))) |seen| if (doc.signed < seen) {
            status.* = .verify;
            _ = c.fail(.verify, "verify", "the release index is older than one accepted before, which suggests a replay", .{});
            return error.Reported;
        };
    } else |_| {}
    hd.createDirPath(c.io, "index") catch {};
    var tb: [20]u8 = undefined;
    home_mod.writeAtomic(c.io, hd, seen_path, signed.formatTime(&tb, doc.signed)) catch {};

    return parseIndex(c, doc) catch {
        status.* = .verify;
        _ = c.fail(.verify, "verify", "the release index is malformed", .{});
        return error.Reported;
    };
}

fn parseIndex(c: *Ctx, doc: signed.Document) !Index {
    const root = doc.root();
    var ix: Index = .{ .doc = doc, .releases = &.{}, .stable = null, .unstable = null };
    if (root.get("channels")) |ch| if (ch == .object) {
        if (ch.object.get("stable")) |v| if (v == .string) {
            ix.stable = v.string;
        };
        if (ch.object.get("unstable")) |v| if (v == .string) {
            ix.unstable = v.string;
        };
    };
    const rel = root.get("releases") orelse return error.Malformed;
    if (rel != .array) return error.Malformed;
    var list: std.ArrayList(Release) = .empty;
    errdefer list.deinit(c.gpa);
    for (rel.array.items) |r| {
        if (r != .object) return error.Malformed;
        const o = r.object;
        const vt = o.get("version") orelse return error.Malformed;
        const ct = o.get("channel") orelse return error.Malformed;
        if (vt != .string or ct != .string) return error.Malformed;
        const v = semver.parse(vt.string) orelse return error.Malformed;
        const ch = Channel.parse(ct.string) orelse return error.Malformed;
        var asset: ?Asset = null;
        if (o.get("assets")) |as| if (as == .object) if (as.object.get(target_name)) |a| if (a == .object) {
            const u = a.object.get("url") orelse return error.Malformed;
            const h = a.object.get("sha256") orelse return error.Malformed;
            const s = a.object.get("size") orelse return error.Malformed;
            if (u != .string or h != .string or s != .integer or s.integer < 0) return error.Malformed;
            asset = .{ .url = u.string, .sha256 = h.string, .size = @intCast(s.integer) };
        };
        const published = if (o.get("published")) |p| (if (p == .string) p.string else "") else "";
        try list.append(c.gpa, .{ .version = v, .text = vt.string, .channel = ch, .published = published, .asset = asset });
    }
    ix.releases = try list.toOwnedSlice(c.gpa);
    return ix;
}

/// The release of the index that `req` selects.
fn pickRelease(ix: *const Index, req: semver.Request) ?Release {
    switch (req) {
        .channel => |ch| {
            const want = (if (ch == .stable) ix.stable else ix.unstable) orelse return null;
            for (ix.releases) |r| if (std.mem.eql(u8, r.text, want)) return r;
            return null;
        },
        else => {
            var best: ?Release = null;
            for (ix.releases) |r| {
                if (!req.matches(r.version, r.channel)) continue;
                if (best == null or best.?.version.order(r.version) == .lt) best = r;
            }
            return best;
        },
    }
}

fn listRemote(c: *Ctx, ch: Channel) !u8 {
    c.home = c.home;
    var client = httpc.Client.init(c.gpa, c.io);
    defer client.deinit();
    var status: Status = .failed;
    var ix = loadIndex(c, &client, &status) catch |e| switch (e) {
        error.Reported => return @backingInt(status),
        else => return e,
    };
    defer ix.deinit(c.gpa);
    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    const Item = struct { version: []const u8, published: []const u8, installed: bool };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(c.gpa);
    for (ix.releases) |r| {
        if (r.channel != ch) continue;
        const inst = for (list) |i| {
            if (std.mem.eql(u8, i.text, r.text)) break true;
        } else false;
        try items.append(c.gpa, .{ .version = r.text, .published = r.published, .installed = inst });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return semver.parse(a.version).?.order(semver.parse(b.version).?) == .lt;
        }
    }.lt);
    if (c.json) {
        c.emit(.{ .schema = 1, .channel = @tagName(ch), .versions = items.items });
    } else {
        for (items.items) |i| c.outFmt("{s}{s}\n", .{ i.version, if (i.installed) "  installed" else "" });
    }
    return 0;
}

fn cmdInstall(c: *Ctx, args: []const []const u8) !u8 {
    if (args.len != 1) return c.usageError("install needs one version request", .{});
    const req = parseReq(c, args[0]) orelse return c.usageError("malformed version request '{s}'", .{args[0]});
    var hd = c.openHome() catch |e| return c.fail(.failed, "io", "cannot open {s}: {s}", .{ c.home, @errorName(e) });
    defer hd.close(c.io);
    const lock = home_mod.Lock.acquire(c.io, hd) catch |e| return c.fail(.failed, "io", "cannot lock {s}: {s}", .{ c.home, @errorName(e) });
    defer lock.release(c.io);

    var client = httpc.Client.init(c.gpa, c.io);
    defer client.deinit();
    var status: Status = .failed;
    var ix = loadIndex(c, &client, &status) catch |e| switch (e) {
        error.Reported => return @backingInt(status),
        else => return e,
    };
    defer ix.deinit(c.gpa);
    const rel = pickRelease(&ix, req) orelse return c.fail(.not_found, "not-found", "no release matches '{s}'", .{args[0]});
    const final_path = try exePath(c, rel.text);
    defer c.gpa.free(final_path);

    const list = try listInstalled(c);
    defer freeInstalled(c.gpa, list);
    const already = for (list) |i| {
        if (std.mem.eql(u8, i.text, rel.text)) break true;
    } else false;
    if (!already) {
        const asset = rel.asset orelse return c.fail(.not_found, "not-found", "lus {s} has no archive for {s}", .{ rel.text, target_name });
        if (!c.json) {
            const line = try std.fmt.allocPrint(c.gpa, "downloading lus {s} for {s}\n", .{ rel.text, target_name });
            defer c.gpa.free(line);
            Io.File.stderr().writeStreamingAll(c.io, line) catch {};
        }
        var ar = client.get(asset.url, .{ .max_body = 512 << 20 }) catch |e|
            return c.fail(.failed, "network", "cannot download {s}: {s}", .{ asset.url, @errorName(e) });
        defer ar.deinit(c.gpa);
        if (ar.status != 200) return c.fail(.failed, "network", "cannot download {s}: status {d}", .{ asset.url, ar.status });
        if (ar.body.len != asset.size) return c.fail(.verify, "verify", "the archive of lus {s} has {d} bytes, the index says {d}", .{ rel.text, ar.body.len, asset.size });
        const digest = lus.lib.crypto.sha256(ar.body);
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&hex, asset.sha256)) return c.fail(.verify, "verify", "the archive of lus {s} does not match its SHA-256 digest", .{rel.text});
        unpack(c, hd, rel.text, rel.channel, ar.body) catch |e| switch (e) {
            error.Reported => return 1,
            else => return c.fail(.failed, "io", "cannot install lus {s}: {s}", .{ rel.text, @errorName(e) }),
        };
        // The first version installed becomes the default.
        const def = readDefault(c);
        defer if (def) |d| c.gpa.free(d);
        if (def == null) setDefault(c, hd, rel.text) catch |e| c.warn("cannot set the default version: {s}", .{@errorName(e)});
    }
    if (c.json) {
        c.emit(.{ .schema = 1, .version = rel.text, .path = final_path, .already = already });
    } else if (already) {
        c.outFmt("lus {s} is already installed\n", .{rel.text});
    } else {
        c.outFmt("installed lus {s} in {s}\n", .{ rel.text, final_path });
    }
    return 0;
}

/// Unpacks a verified release archive into `versions/VERSION` through a
/// temporary directory, so an interrupted install leaves nothing behind.
fn unpack(c: *Ctx, hd: Io.Dir, version: []const u8, channel: Channel, archive: []const u8) !void {
    try hd.createDirPath(c.io, "versions");
    var rnd: [6]u8 = undefined;
    c.io.random(&rnd);
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "versions" ++ home_mod.sep ++ ".tmp-{x}", .{rnd});
    try hd.createDirPath(c.io, tmp);
    errdefer hd.deleteTree(c.io, tmp) catch {};
    var dest = try hd.openDir(c.io, tmp, .{});
    defer dest.close(c.io);
    if (archive.len >= 4 and std.mem.eql(u8, archive[0..4], "PK\x03\x04")) {
        // A zip archive goes through a file, which the zip reader seeks.
        try dest.writeFile(c.io, .{ .sub_path = ".archive.zip", .data = archive });
        const f = try dest.openFile(c.io, ".archive.zip", .{});
        defer f.close(c.io);
        var rbuf: [4096]u8 = undefined;
        var fr = f.reader(c.io, &rbuf);
        try std.zip.extract(dest, &fr, .{});
        dest.deleteFile(c.io, ".archive.zip") catch {};
    } else {
        var in: Io.Reader = .fixed(archive);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var dec: std.compress.flate.Decompress = .init(&in, .gzip, &window);
        try std.tar.extract(c.io, dest, &dec.reader, .{});
    }
    const bin = "bin" ++ home_mod.sep ++ home_mod.exe_name;
    _ = dest.statFile(c.io, bin, .{}) catch {
        _ = c.fail(.verify, "verify", "the archive of lus {s} has no {s}", .{ version, bin });
        return error.Reported;
    };
    var line: [16]u8 = undefined;
    try dest.writeFile(c.io, .{ .sub_path = "channel", .data = try std.fmt.bufPrint(&line, "{s}\n", .{@tagName(channel)}) });
    const final = try std.fs.path.join(c.gpa, &.{ "versions", version });
    defer c.gpa.free(final);
    try hd.rename(tmp, hd, final, c.io);
}

/// `lus +REQUEST ARGS...`: runs an installed version with ARGS. Returns
/// only on failure, or on Windows with the exit status of the child.
pub fn plus(init: std.process.Init, req_text: []const u8, args: []const []const u8) !u8 {
    var c: Ctx = .{ .gpa = init.gpa, .io = init.io, .env = init.environ_map };
    defer c.deinit();
    const req = semver.parseRequest(req_text) orelse {
        std.debug.print("lus: malformed version request '+{s}'\n", .{req_text});
        return @backingInt(Status.usage);
    };
    c.home = (try home_mod.path(c.gpa, c.env)) orelse {
        std.debug.print("lus: cannot find the Lus home: set LUS_HOME or HOME\n", .{});
        return 1;
    };
    const list = try listInstalled(&c);
    defer freeInstalled(c.gpa, list);
    const i = pickInstalled(list, req) orelse {
        std.debug.print("lus: lus {s} is not installed. Run `lus version install {s}`\n", .{ req_text, req_text });
        return @backingInt(Status.not_found);
    };
    const exe = try exePath(&c, i.text);
    defer c.gpa.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(c.gpa);
    try argv.append(c.gpa, exe);
    try argv.appendSlice(c.gpa, args);
    if (!home_mod.is_windows) {
        const err = std.process.replace(c.io, .{ .argv = argv.items, .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = exe } } });
        std.debug.print("lus: cannot run {s}: {s}\n", .{ exe, @errorName(err) });
        return 1;
    }
    var child = std.process.spawn(c.io, .{ .argv = argv.items }) catch |e| {
        std.debug.print("lus: cannot run {s}: {s}\n", .{ exe, @errorName(e) });
        return 1;
    };
    const term = child.wait(c.io) catch return 1;
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
