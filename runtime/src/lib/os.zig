//! The os library. Dates are computed in pure Zig by `timecore.zig`,
//! which the `time` library shares: civil calendar arithmetic for UTC,
//! and local time from the TZif database (the `TZ` variable, then
//! /etc/localtime, with the tzdata embedded in the runtime as a fallback
//! for zone names) with POSIX TZ rules for times past the last recorded
//! transition. `os.date` formats like C `strftime` in the "C" locale.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("auxlib.zig");
const out = @import("out.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

pub const funcs = [_]aux.Reg{
    .{ .name = "clock", .func = clock },
    .{ .name = "date", .func = date },
    .{ .name = "difftime", .func = difftime },
    .{ .name = "execute", .func = execute },
    .{ .name = "exit", .func = exit },
    .{ .name = "getenv", .func = getenv },
    .{ .name = "pid", .func = pid },
    .{ .name = "platform", .func = platform },
    .{ .name = "setenv", .func = setenv },
    .{ .name = "setlocale", .func = setlocale },
    .{ .name = "time", .func = time },
    .{ .name = "tmpname", .func = tmpname },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, .fields, "os", &funcs);
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    try @import("process.zig").open(l, t);
    try @import("signal.zig").open(l, t);
    try aux.setGlobal(l, "os", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Environment

/// Looks up an environment variable in the host provided map, or in the
/// process environment when the C library is linked.
pub fn envGet(l: *Thread, name: []const u8) ?[]const u8 {
    if (l.g.environ) |m| return m.get(name);
    if (builtin.link_libc and builtin.os.tag != .windows) {
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len or std.mem.indexOfScalar(u8, name, 0) != null) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const p = std.c.getenv(@ptrCast(&buf)) orelse return null;
        return std.mem.span(p);
    }
    return null;
}

/// The directory for temporary files, looked up as the system looks it
/// up: `TMP`, then `TEMP`, then `USERPROFILE` on Windows, and `TMPDIR`
/// elsewhere. `env` is any value with a `get` method that returns the value
/// of a variable. Trailing separators are removed, so the root comes back
/// empty.
pub fn tempDirFrom(env: anytype) []const u8 {
    if (builtin.os.tag == .windows) {
        for ([_][]const u8{ "TMP", "TEMP", "USERPROFILE" }) |name| {
            if (env.get(name)) |v| if (v.len > 0) return std.mem.trimEnd(u8, v, "/\\");
        }
        return ".";
    }
    return std.mem.trimEnd(u8, env.get("TMPDIR") orelse "/tmp", "/");
}

/// The directory for temporary files of the environment of `l`.
pub fn tempDir(l: *Thread) []const u8 {
    return tempDirFrom(ThreadEnv{ .l = l });
}

const ThreadEnv = struct {
    l: *Thread,

    fn get(e: ThreadEnv, name: []const u8) ?[]const u8 {
        return envGet(e.l, name);
    }
};

/// The separator the host puts between the components of a path.
pub const path_separator: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

fn getenv(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    try @import("../vm/pledge.zig").require(l, "env:read", name);
    const v = envGet(l, name) orelse return aux.retNil(l);
    return aux.ret(l, try lossyString(l, v));
}

const Environ = std.process.Environ.Map;
const environ_key = "os.environ";
/// The allocator of the environment maps a state owns. It is safe to use
/// from any thread, so a map made for a worker can be freed by it.
const environ_gpa = if (builtin.single_threaded) std.heap.wasm_allocator else std.heap.smp_allocator;

/// The environment map that state `g` owns, or null while it reads the
/// environment the host gave it.
pub fn ownedEnviron(g: *state.Global) ?*Environ {
    const p = g.ext.get(environ_key) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Makes `m` the environment that state `g` owns and reads.
pub fn adoptEnviron(g: *state.Global, m: *Environ) error{OutOfMemory}!void {
    g.ext.put(g.gpa, environ_key, m) catch return error.OutOfMemory;
    g.environ = m;
}

const startup_key = "os.startup_env";

/// The environment the state started with, kept from before its first
/// change. It decides the program that a permission to run a program by
/// name covers, and the variables such a program must receive unchanged.
/// A change made with `os.setenv` and the `env` option of `os.spawn`
/// leave it as it was.
fn startupEnviron(g: *state.Global) ?*Environ {
    const p = g.ext.get(startup_key) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The value that variable `name` had when the state started.
pub fn startupGet(l: *Thread, name: []const u8) ?[]const u8 {
    if (startupEnviron(l.g)) |m| return m.get(name);
    return envGet(l, name);
}

/// The `PATH` the state started with.
pub fn startupPath(l: *Thread) ?[]const u8 {
    return startupGet(l, "PATH") orelse (if (builtin.os.tag == .windows) startupGet(l, "Path") else null);
}

/// Whether the environment of the state has changed since it started.
pub fn environChanged(l: *Thread) bool {
    return startupEnviron(l.g) != null;
}

/// Keeps the environment of the state before its first change.
fn keepStartup(l: *Thread) error{OutOfMemory}!void {
    const g = l.g;
    if (g.ext.get(startup_key) != null) return;
    const m = try copyEnviron(g);
    errdefer freeEnviron(m);
    try g.ext.put(g.gpa, startup_key, m);
}

/// A copy of the kept environment of the state of `l` for a worker, or
/// null when the state has kept none because its environment never
/// changed.
pub fn copyStartupPath(l: *Thread) error{OutOfMemory}!?*anyopaque {
    const from = startupEnviron(l.g) orelse return null;
    const m = try environ_gpa.create(Environ);
    errdefer environ_gpa.destroy(m);
    m.* = try from.clone(environ_gpa);
    return m;
}

/// Makes `p`, which `copyStartupPath` returned, the kept environment of
/// state `g`.
pub fn adoptStartupPath(g: *state.Global, p: *anyopaque) error{OutOfMemory}!void {
    g.ext.put(g.gpa, startup_key, p) catch return error.OutOfMemory;
}

/// Frees a copy that no state adopted.
pub fn freeStartupPath(p: *anyopaque) void {
    freeEnviron(@ptrCast(@alignCast(p)));
}

/// Whether `name` is a variable that makes a dynamic loader, a shell, or
/// a language runtime load code or change how it finds programs. A
/// program that runs under a permission for that program alone receives
/// each of them as the state started with it.
pub fn loadsCode(name: []const u8) bool {
    const prefixes = [_][]const u8{ "LD_", "DYLD_", "BASH_FUNC_", "__BASH_FUNC" };
    for (prefixes) |pre| if (std.mem.startsWith(u8, name, pre)) return true;
    const names = [_][]const u8{
        "PATH",              "PATHEXT",        "COMSPEC",          "IFS",             "ENV",
        "BASH_ENV",          "SHELLOPTS",      "BASHOPTS",         "PS4",             "CDPATH",
        "GLOBIGNORE",        "PROMPT_COMMAND", "ZDOTDIR",          "LIBPATH",         "SHLIB_PATH",
        "GCONV_PATH",        "LOCPATH",        "NLSPATH",          "HOSTALIASES",     "PYTHONPATH",
        "PYTHONSTARTUP",     "PYTHONHOME",     "PYTHONINSPECT",    "PERL5LIB",        "PERLLIB",
        "PERL5OPT",          "RUBYLIB",        "RUBYOPT",          "NODE_OPTIONS",    "NODE_PATH",
        "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS",  "JDK_JAVA_OPTIONS", "LUA_PATH",        "LUA_CPATH",
        "LUA_INIT",          "LUS_PATH",       "GIT_SSH",          "GIT_SSH_COMMAND", "GIT_EXEC_PATH",
        "EDITOR",            "VISUAL",         "PAGER",            "GIT_PAGER",       "GIT_EDITOR",
    };
    for (names) |n| {
        const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(name, n) else std.mem.eql(u8, name, n);
        if (same) return true;
    }
    return false;
}

/// Frees the environment map that state `g` owns.
pub fn deinitEnviron(g: *state.Global) void {
    if (startupEnviron(g)) |m| {
        _ = g.ext.remove(startup_key);
        freeEnviron(m);
    }
    const m = ownedEnviron(g) orelse return;
    _ = g.ext.remove(environ_key);
    if (g.environ == m) g.environ = null;
    freeEnviron(m);
}

pub fn freeEnviron(m: *Environ) void {
    m.deinit();
    environ_gpa.destroy(m);
}

/// A copy of the environment that state `g` reads, as a map of its own.
/// Without a map from the host it copies the process environment.
pub fn copyEnviron(g: *state.Global) error{OutOfMemory}!*Environ {
    const m = try environ_gpa.create(Environ);
    errdefer environ_gpa.destroy(m);
    if (g.environ) |e| {
        m.* = try e.clone(environ_gpa);
        return m;
    }
    m.* = Environ.init(environ_gpa);
    errdefer m.deinit();
    if (builtin.link_libc and builtin.os.tag != .windows) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const line = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (eq == 0) continue;
            try m.put(line[0..eq], line[eq + 1 ..]);
        }
    }
    return m;
}

/// The map that `os.setenv` writes. A state copies the environment of
/// its host into a map of its own before its first change, so a map that
/// other states share is never written.
fn writableEnviron(l: *Thread) Error!*Environ {
    const g = l.g;
    keepStartup(l) catch return l.raiseMem();
    if (ownedEnviron(g)) |m| return m;
    const m = copyEnviron(g) catch return l.raiseMem();
    adoptEnviron(g, m) catch {
        freeEnviron(m);
        return l.raiseMem();
    };
    return m;
}

/// os.setenv(name, value): sets the environment variable `name`, or
/// removes it when `value` is nil.
fn setenv(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const val: ?[]const u8 = if (l.arg(2).isNil()) null else try aux.checkBytes(l, 2);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "=\x00") != null)
        return aux.argError(l, 1, "invalid environment variable name", .{});
    if (val) |v| if (std.mem.indexOfScalar(u8, v, 0) != null)
        return aux.argError(l, 2, "environment variable value contains a zero byte", .{});
    try @import("../vm/pledge.zig").require(l, "env:write", name);
    // `TZ` may name a file, which `os.date` then reads.
    if (std.mem.eql(u8, name, "TZ")) if (val) |v| {
        const file = if (v.len > 0 and v[0] == ':') v[1..] else v;
        if (file.len > 0 and file[0] == '/') try @import("../vm/pledge.zig").require(l, "fs:read", file);
    };
    const m = try writableEnviron(l);
    if (val) |v| {
        m.put(name, v) catch return l.raiseMem();
    } else {
        _ = m.orderedRemove(name);
    }
    return 0;
}

/// Makes a string from bytes that may not be valid UTF-8, replacing each
/// invalid sequence with U+FFFD.
pub fn lossyString(l: *Thread, bytes: []const u8) Error!Value {
    if (wtf8.analyze(bytes).valid) return l.newStringValue(bytes);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    wtf8.appendLossy(l.g.gpa, &buf, bytes) catch return l.raiseMem();
    return l.newStringValue(buf.items);
}

// ---------------------------------------------------------------------
// Process

fn clock(l: *Thread) Error!u32 {
    const ns = std.Io.Clock.cpu_process.now(l.g.io).nanoseconds;
    return aux.ret(l, Value.float(@as(f64, @floatFromInt(ns)) / 1e9));
}

fn exit(l: *Thread) Error!u32 {
    const a = l.arg(1);
    var status: i64 = 0;
    if (a.tag == .true) {
        status = 0;
    } else if (a.tag == .false) {
        status = 1;
    } else {
        status = try aux.optInt(l, 1, 0);
    }
    // A worker cannot end the whole process. The optional `close`
    // argument would close the state first, and exiting directly releases
    // everything anyway.
    if (@import("build_options").workers and @import("worker.zig").isWorker(l.g)) return l.raiseFmt("os.exit is unavailable in a worker", .{});
    out.flushAll(l.g);
    @import("term.zig").restore();
    std.process.exit(@truncate(@as(u64, @bitCast(status))));
}

/// os.pid(): the id of the process, an integer. The WebAssembly build
/// has no processes, so it raises.
fn pid(l: *Thread) Error!u32 {
    const id: i64 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi, .freestanding => return l.raiseFmt("os.pid is unavailable in the WebAssembly build", .{}),
        .linux => if (builtin.link_libc) std.c.getpid() else std.os.linux.getpid(),
        else => std.c.getpid(),
    };
    return aux.retInt(l, id);
}

fn platform(l: *Thread) Error!u32 {
    const name = switch (builtin.os.tag) {
        .linux => "linux",
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .illumos => "sunos",
        .windows => "windows",
        .dragonfly, .haiku => "posix",
        .wasi => "wasi",
        else => "unknown",
    };
    return aux.retStr(l, name);
}

fn setlocale(l: *Thread) Error!u32 {
    const loc = try aux.optString(l, 1, null);
    const cats = [_][]const u8{ "all", "collate", "ctype", "monetary", "numeric", "time" };
    _ = try aux.checkOption(l, 2, "all", &cats);
    // Only the "C" locale exists: every conversion in the runtime is
    // locale independent.
    if (loc) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX")) return aux.retStr(l, "C");
        return aux.retNil(l);
    }
    return aux.retStr(l, "C");
}

/// Result of a failed file operation, as luaL_fileresult reports it.
fn fileError(l: *Thread, name: ?[]const u8, e: anyerror) Error!u32 {
    const info = errnoOf(e);
    var buf: [1024]u8 = undefined;
    const msg = if (name) |n|
        std.fmt.bufPrint(&buf, "{s}: {s}", .{ n, info.msg }) catch info.msg
    else
        info.msg;
    try l.push(.nil);
    try l.push(try lossyString(l, msg));
    try l.push(Value.int(info.errno));
    return 3;
}

const ErrInfo = struct { msg: []const u8, errno: i64 };

pub fn errnoOf(e: anyerror) ErrInfo {
    return switch (e) {
        error.FileNotFound => .{ .msg = "No such file or directory", .errno = 2 },
        error.AccessDenied, error.PermissionDenied => .{ .msg = "Permission denied", .errno = 13 },
        error.PathAlreadyExists => .{ .msg = "File exists", .errno = 17 },
        error.NotDir => .{ .msg = "Not a directory", .errno = 20 },
        error.IsDir => .{ .msg = "Is a directory", .errno = 21 },
        error.DirNotEmpty => .{ .msg = "Directory not empty", .errno = 66 },
        error.FileBusy => .{ .msg = "Device or resource busy", .errno = 16 },
        error.NameTooLong => .{ .msg = "File name too long", .errno = 63 },
        error.ReadOnlyFileSystem => .{ .msg = "Read-only file system", .errno = 30 },
        error.RenameAcrossMountPoints => .{ .msg = "Cross-device link", .errno = 18 },
        error.SymLinkLoop => .{ .msg = "Too many levels of symbolic links", .errno = 62 },
        error.NoSpaceLeft => .{ .msg = "No space left on device", .errno = 28 },
        error.FileNotFoundOrNoAccess => .{ .msg = "No such file or directory", .errno = 2 },
        error.InputOutput => .{ .msg = "Input/output error", .errno = 5 },
        error.SystemResources => .{ .msg = "Cannot allocate memory", .errno = 12 },
        error.SystemFdQuotaExceeded => .{ .msg = "Too many open files in system", .errno = 23 },
        error.ProcessFdQuotaExceeded => .{ .msg = "Too many open files", .errno = 24 },
        error.FileTooBig => .{ .msg = "File too large", .errno = 27 },
        error.BrokenPipe => .{ .msg = "Broken pipe", .errno = 32 },
        error.ConnectionResetByPeer => .{ .msg = "Connection reset by peer", .errno = if (builtin.os.tag == .linux) 104 else 54 },
        else => .{ .msg = @errorName(e), .errno = 0 },
    };
}

fn tmpname(l: *Thread) Error!u32 {
    const pledge = @import("../vm/pledge.zig");
    // Without any grant of fs:write the call fails before it reads the
    // environment. A grant limited to some paths must cover the file.
    if (!pledge.allowed(l, "fs:write", null)) return l.raiseFmt("permission \"fs:write\" denied for os.tmpname", .{});
    const io = l.g.io;
    const dir = tempDir(l);
    const sep = path_separator;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)));
    seed ^= @intFromPtr(l) ^ l.g.seed;
    var attempt: u32 = 0;
    var buf: [512]u8 = undefined;
    while (attempt < 100) : (attempt += 1) {
        var suffix: [6]u8 = undefined;
        for (&suffix) |*c| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            c.* = alphabet[@intCast((seed >> 33) % alphabet.len)];
        }
        const path = std.fmt.bufPrint(&buf, "{s}{s}lua_{s}", .{ dir, sep, suffix }) catch break;
        // The message leaves the directory out, which comes from the
        // environment.
        if (!pledge.allowed(l, "fs:write", path)) return l.raiseFmt("permission \"fs:write\" denied for the directory of temporary files", .{});
        const f = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => break,
        };
        f.close(io);
        return aux.retStr(l, path);
    }
    return l.raiseFmt("unable to generate a unique filename", .{});
}

fn execute(l: *Thread) Error!u32 {
    if (comptime !aux.can_spawn) {
        // Without a command, os.execute reports that no shell exists.
        if ((try aux.optString(l, 1, null)) == null) return aux.retBool(l, false);
        return aux.unavailable(l, "os.execute");
    }
    return spawnShell(l);
}

fn spawnShell(l: *Thread) Error!u32 {
    const cmd = try aux.optString(l, 1, null);
    const c = cmd orelse return aux.retBool(l, true); // a shell is available
    if (!@import("../vm/pledge.zig").allowedUnrestricted(l, "exec")) return l.raiseFmt("permission \"exec\" denied for os.execute", .{});
    const io = l.g.io;
    out.flushAll(l.g);
    const shell = @import("shell.zig");
    var child = shell.spawn(io, l.g.gpa, c, .none, ownedEnviron(l.g)) catch |e| return fileError(l, null, e);
    const status = shell.wait(io, &child) catch |e| return fileError(l, null, e);
    return @import("io.zig").pushStatus(l, status);
}

// ---------------------------------------------------------------------
// Time zones

const timecore = @import("timecore.zig");
const Tm = timecore.Tm;
const ZoneInfo = timecore.ZoneInfo;
const utc_info = timecore.utc_info;
const breakDown = timecore.breakDown;
const daysFromCivil = timecore.daysFromCivil;

/// The local time zone, held in the flat layout of `timecore`. A zone
/// without memory is UTC.
const Zone = struct {
    gpa: std.mem.Allocator,
    mem: ?[]align(8) u8 = null,

    fn deinit(z: *Zone) void {
        if (z.mem) |m| z.gpa.free(m);
    }

    fn info(z: *const Zone, t: i64) ZoneInfo {
        const m = z.mem orelse return utc_info;
        const flat: *const timecore.FlatZone = @ptrCast(m.ptr);
        return flat.info(t);
    }
};

/// Copies a TZif record into a freshly allocated flat zone.
fn flatFromTzif(gpa: std.mem.Allocator, bytes: []const u8) ?[]align(8) u8 {
    const t = timecore.Tzif.scan(bytes) catch return null;
    const mem = gpa.alignedAlloc(u8, .@"8", t.flatSize()) catch return null;
    _ = t.fill(mem) catch {
        gpa.free(mem);
        return null;
    };
    return mem;
}

fn loadTzFile(l: *Thread, path: []const u8) ?[]align(8) u8 {
    const gpa = l.g.gpa;
    const bytes = std.Io.Dir.cwd().readFileAlloc(l.g.io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(bytes);
    return flatFromTzif(gpa, bytes);
}

/// Loads a named zone from the system database, then from the tzdata
/// embedded in the runtime.
fn loadNamedZone(l: *Thread, name: []const u8) ?[]align(8) u8 {
    if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return null;
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "/usr/share/zoneinfo/{s}", .{name})) |p| {
        if (loadTzFile(l, p)) |m| return m;
    } else |_| {}
    const gpa = l.g.gpa;
    const blob = timecore.decompressTzdata(gpa) catch return null;
    defer gpa.free(blob);
    const rec = timecore.findZone(blob, name) orelse return null;
    return flatFromTzif(gpa, rec);
}

fn ruleZone(l: *Thread, spec: []const u8) Zone {
    const gpa = l.g.gpa;
    const r = timecore.PosixRule.parse(spec) orelse return .{ .gpa = gpa };
    const mem = gpa.alignedAlloc(u8, .@"8", timecore.FlatZone.sizeFor(0, 0, 0)) catch return .{ .gpa = gpa };
    _ = timecore.FlatZone.initRule(mem, r);
    return .{ .gpa = gpa, .mem = mem };
}

/// Loads the local time zone. The caller deinitializes the result.
fn localZone(l: *Thread) Zone {
    const gpa = l.g.gpa;
    if (builtin.os.tag == .windows) return .{ .gpa = gpa };
    if (envGet(l, "TZ")) |tz_raw| {
        var tzs = tz_raw;
        if (tzs.len == 0) return ruleZone(l, "UTC0");
        if (tzs[0] == ':') tzs = tzs[1..];
        // A path that the host set at start is the host's choice. One
        // that changed since is read only where the program may read it,
        // whichever state or coroutine made the change.
        const from_host = if (startupGet(l, "TZ")) |at_start| std.mem.eql(u8, at_start, tz_raw) else false;
        const readable = from_host or @import("../vm/pledge.zig").allowed(l, "fs:read", tzs);
        const mem = if (tzs.len > 0 and tzs[0] == '/') (if (readable) loadTzFile(l, tzs) else null) else loadNamedZone(l, tzs);
        if (mem) |m| return .{ .gpa = gpa, .mem = m };
        return ruleZone(l, tzs);
    }
    return .{ .gpa = gpa, .mem = loadTzFile(l, "/etc/localtime") };
}

// ---------------------------------------------------------------------
// os.time, os.date, os.difftime

fn now(l: *Thread) i64 {
    return std.Io.Clock.real.now(l.g.io).toSeconds();
}

/// Reads an integer field of a date table, as Lua's getfield does.
fn getField(l: *Thread, t: Value, key: []const u8, d: ?i64, delta: i64) Error!i64 {
    const k = try l.newStringValue(key);
    const v = try ops.index(l, t, k);
    var n: ?i64 = null;
    if (v.tag == .integer) {
        n = v.asInt();
    } else if (v.isNumber()) {
        n = ops.toIntegerStrict(v);
    } else if (v.tag == .string) {
        if (ops.toNumberCoerce(v)) |x| n = ops.toIntegerStrict(x);
    }
    if (n) |res| {
        const int_max = std.math.maxInt(i32);
        const int_min = std.math.minInt(i32);
        const ok = if (res >= 0) res - delta <= int_max else int_min + delta <= res;
        if (!ok) return l.raiseFmt("field '{s}' is out-of-bound", .{key});
        return res - delta;
    }
    if (!v.isNil()) return l.raiseFmt("field '{s}' is not an integer", .{key});
    return d orelse l.raiseFmt("field '{s}' missing in date table", .{key});
}

fn setField(l: *Thread, t: Value, key: []const u8, v: Value) Error!void {
    try ops.setIndex(l, t, try l.newStringValue(key), v);
}

fn setAllFields(l: *Thread, t: Value, tm: *const Tm) Error!void {
    try setField(l, t, "year", Value.int(tm.year));
    try setField(l, t, "month", Value.int(tm.month));
    try setField(l, t, "day", Value.int(tm.day));
    try setField(l, t, "hour", Value.int(tm.hour));
    try setField(l, t, "min", Value.int(tm.min));
    try setField(l, t, "sec", Value.int(tm.sec));
    try setField(l, t, "yday", Value.int(tm.yday + 1));
    try setField(l, t, "wday", Value.int(tm.wday + 1));
    try setField(l, t, "isdst", Value.boolean(tm.isdst));
}

/// Converts a local wall clock time to a timestamp, choosing among the
/// offsets in effect around it. `isdst` disambiguates repeated hours.
fn localToUtc(z: *const Zone, local: i64, isdst: ?bool) i64 {
    const probes = [_]i64{ local, local - 86400, local + 86400 };
    var found: [3]i64 = undefined;
    var found_dst: [3]bool = undefined;
    var n: usize = 0;
    for (probes) |p| {
        const o = z.info(p).utoff;
        const t = local - o;
        const at = z.info(t);
        if (at.utoff != o) continue;
        var dup = false;
        for (found[0..n]) |f| {
            if (f == t) dup = true;
        }
        if (dup) continue;
        found[n] = t;
        found_dst[n] = at.isdst;
        n += 1;
    }
    if (n == 0) {
        // The time falls in a gap: use the offset in effect before it,
        // which moves the time forward past the gap.
        return local - z.info(local - 86400).utoff;
    }
    if (isdst) |want| {
        for (found[0..n], found_dst[0..n]) |t, d| {
            if (d == want) return t;
        }
    }
    return std.mem.min(i64, found[0..n]);
}

fn time(l: *Thread) Error!u32 {
    if (l.arg(1).isNil()) return aux.retInt(l, now(l));
    _ = try aux.checkTable(l, 1);
    l.top = l.base() + 1;
    const t = l.arg(1);
    const year = try getField(l, t, "year", null, 1900);
    const month = try getField(l, t, "month", null, 1);
    const day = try getField(l, t, "day", null, 0);
    const hour = try getField(l, t, "hour", 12, 0);
    const min = try getField(l, t, "min", 0, 0);
    const sec = try getField(l, t, "sec", 0, 0);
    const dst_v = try ops.index(l, t, try l.newStringValue("isdst"));
    const isdst: ?bool = if (dst_v.isNil()) null else dst_v.truthy();
    // Normalize the month first, then let day arithmetic carry the rest.
    const y = year + 1900 + @divFloor(month, 12);
    const m = @mod(month, 12) + 1;
    const days = daysFromCivil(y, m, 1) + day - 1;
    const local = days * 86400 + hour * 3600 + min * 60 + sec;
    var z = localZone(l);
    defer z.deinit();
    const ts = localToUtc(&z, local, isdst);
    const tm = breakDown(ts, z.info(ts));
    if (tm.year - 1900 > std.math.maxInt(i32) or tm.year - 1900 < std.math.minInt(i32)) {
        return l.raiseFmt("time result cannot be represented in this installation", .{});
    }
    try setAllFields(l, t, &tm);
    return aux.retInt(l, ts);
}

fn difftime(l: *Thread) Error!u32 {
    const t1 = try aux.checkInt(l, 1);
    const t2 = try aux.checkInt(l, 2);
    return aux.ret(l, Value.float(@as(f64, @floatFromInt(t1)) - @as(f64, @floatFromInt(t2))));
}

fn date(l: *Thread) Error!u32 {
    var fmt = (try aux.optString(l, 1, "%c")).?;
    const t = if (l.arg(2).isNil()) now(l) else try aux.checkInt(l, 2);
    var tm: Tm = undefined;
    if (fmt.len > 0 and fmt[0] == '!') {
        tm = breakDown(t, utc_info);
        fmt = fmt[1..];
    } else {
        var z = localZone(l);
        defer z.deinit();
        tm = breakDown(t, z.info(t));
    }
    if (tm.year - 1900 > std.math.maxInt(i32) or tm.year - 1900 < std.math.minInt(i32)) {
        return l.raiseFmt("date result cannot be represented in this installation", .{});
    }
    if (std.mem.eql(u8, fmt, "*t")) {
        const res = try l.newTable(0, 9);
        try l.push(Value.obj(.table, res));
        try setAllFields(l, Value.obj(.table, res), &tm);
        return 1;
    }
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            buf.append(gpa, fmt[i]) catch return l.raiseMem();
            i += 1;
            continue;
        }
        i += 1;
        const rest = fmt[i..];
        const m = timecore.matchConversion(rest) orelse return aux.argError(l, 1, "invalid conversion specifier '%{s}'", .{rest});
        i += m.len;
        timecore.formatConv(gpa, &buf, m.conv, &tm) catch return l.raiseMem();
    }
    return aux.ret(l, try lossyString(l, buf.items));
}
