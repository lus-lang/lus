//! The os library. Dates are computed in pure Zig: civil calendar
//! arithmetic for UTC, and local time from the TZif database (the `TZ`
//! variable, then /etc/localtime) with POSIX TZ rules for times past the
//! last recorded transition. `os.date` formats like C `strftime` in the
//! "C" locale.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("aux.zig");
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
    .{ .name = "platform", .func = platform },
    .{ .name = "remove", .func = remove },
    .{ .name = "rename", .func = rename },
    .{ .name = "setlocale", .func = setlocale },
    .{ .name = "time", .func = time },
    .{ .name = "tmpname", .func = tmpname },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try aux.setGlobal(l, "os", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Environment

/// Looks up an environment variable in the host provided map, or in the
/// process environment when the C library is linked.
fn envGet(l: *Thread, name: []const u8) ?[]const u8 {
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

fn getenv(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    if (!@import("../vm/pledge.zig").allowed(l, "env", name)) return l.raiseFmt("permission \"env\" denied for '{s}'", .{name});
    const v = envGet(l, name) orelse return aux.retNil(l);
    return aux.ret(l, try lossyString(l, v));
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
    if (@import("worker.zig").isWorker(l.g)) return l.raiseFmt("os.exit is unavailable in a worker", .{});
    out.flushAll(l.g);
    std.process.exit(@truncate(@as(u64, @bitCast(status))));
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
        else => .{ .msg = @errorName(e), .errno = 0 },
    };
}

fn remove(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    try @import("../vm/pledge.zig").require(l, "fs:write", name);
    const io = l.g.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, name) catch |e| switch (e) {
        error.IsDir => cwd.deleteDir(io, name) catch |e2| return fileError(l, name, e2),
        else => return fileError(l, name, e),
    };
    return aux.retBool(l, true);
}

fn rename(l: *Thread) Error!u32 {
    const from = try aux.checkBytes(l, 1);
    const to = try aux.checkBytes(l, 2);
    try @import("../vm/pledge.zig").require(l, "fs:write", from);
    try @import("../vm/pledge.zig").require(l, "fs:write", to);
    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.rename(cwd, from, cwd, to, l.g.io) catch |e| return fileError(l, from, e);
    return aux.retBool(l, true);
}

fn tmpname(l: *Thread) Error!u32 {
    if (!@import("../vm/pledge.zig").allowed(l, "fs:write", null)) return l.raiseFmt("permission \"fs:write\" denied for os.tmpname", .{});
    const io = l.g.io;
    const dir: []const u8 = if (builtin.os.tag == .windows) (envGet(l, "TEMP") orelse ".") else "/tmp";
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
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
    const cmd = try aux.optString(l, 1, null);
    const c = cmd orelse return aux.retBool(l, true); // a shell is available
    if (!@import("../vm/pledge.zig").allowed(l, "exec", null)) return l.raiseFmt("permission \"exec\" denied for os.execute", .{});
    const io = l.g.io;
    out.flushAll(l.g);
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", c }
    else
        &.{ "/bin/sh", "-c", c };
    var child = std.process.spawn(io, .{ .argv = argv }) catch |e| return fileError(l, null, e);
    const term = child.wait(io) catch |e| return fileError(l, null, e);
    switch (term) {
        .exited => |code| {
            try l.push(if (code == 0) .true else .nil);
            try l.push(try l.newStringValue("exit"));
            try l.push(Value.int(code));
        },
        .signal, .stopped => |sig| {
            try l.push(.nil);
            try l.push(try l.newStringValue("signal"));
            try l.push(Value.int(@intFromEnum(sig)));
        },
        .unknown => |code| {
            try l.push(.nil);
            try l.push(try l.newStringValue("exit"));
            try l.push(Value.int(code));
        },
    }
    return 3;
}

// ---------------------------------------------------------------------
// Calendar arithmetic (proleptic Gregorian, days since 1970-01-01)

fn floorDiv(a: i64, b: i64) i64 {
    return @divFloor(a, b);
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = floorDiv(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: i64, month: i64, day: i64 };

fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = floorDiv(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// Broken-down time.
const Tm = struct {
    year: i64,
    month: i64, // 1..12
    day: i64,
    hour: i64,
    min: i64,
    sec: i64,
    wday: i64, // 0..6, Sunday is 0
    yday: i64, // 0..365
    isdst: bool,
    utoff: i64,
    abbr: [16]u8 = @splat(0),
    abbr_len: usize = 0,

    fn zone(t: *const Tm) []const u8 {
        return t.abbr[0..t.abbr_len];
    }
};

fn breakDown(t: i64, info: ZoneInfo) Tm {
    const local = t +% info.utoff;
    const days = floorDiv(local, 86400);
    const secs = local - days * 86400;
    const c = civilFromDays(days);
    var tm: Tm = .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @divTrunc(secs, 3600),
        .min = @divTrunc(@mod(secs, 3600), 60),
        .sec = @mod(secs, 60),
        .wday = @mod(days + 4, 7), // 1970-01-01 was a Thursday
        .yday = days - daysFromCivil(c.year, 1, 1),
        .isdst = info.isdst,
        .utoff = info.utoff,
    };
    const n = @min(info.abbr.len, tm.abbr.len);
    @memcpy(tm.abbr[0..n], info.abbr[0..n]);
    tm.abbr_len = n;
    return tm;
}

// ---------------------------------------------------------------------
// Time zones

const ZoneInfo = struct {
    utoff: i64,
    isdst: bool,
    abbr: []const u8,
};

const utc_info: ZoneInfo = .{ .utoff = 0, .isdst = false, .abbr = "UTC" };

/// A POSIX TZ rule such as "CET-1CEST,M3.5.0,M10.5.0/3".
const PosixRule = struct {
    std_abbr: [16]u8 = @splat(0),
    std_len: usize = 0,
    std_off: i64 = 0, // seconds east of UTC
    has_dst: bool = false,
    dst_abbr: [16]u8 = @splat(0),
    dst_len: usize = 0,
    dst_off: i64 = 0,
    start: DateRule = .{ .kind = .month, .month = 3, .week = 2, .wday = 0, .time = 7200 },
    end: DateRule = .{ .kind = .month, .month = 11, .week = 1, .wday = 0, .time = 7200 },

    const DateRule = struct {
        kind: enum { julian1, julian0, month },
        day: i64 = 0,
        month: i64 = 0,
        week: i64 = 0,
        wday: i64 = 0,
        time: i64 = 7200,
    };

    fn parse(s: []const u8) ?PosixRule {
        var r: PosixRule = .{};
        var i: usize = 0;
        r.std_len = parseName(s, &i, &r.std_abbr) orelse return null;
        r.std_off = -(parseOffset(s, &i) orelse return null);
        if (i == s.len) return r;
        r.dst_len = parseName(s, &i, &r.dst_abbr) orelse return null;
        r.has_dst = true;
        r.dst_off = r.std_off + 3600;
        if (i < s.len and s[i] != ',') r.dst_off = -(parseOffset(s, &i) orelse return null);
        if (i == s.len) return r;
        if (s[i] != ',') return null;
        i += 1;
        r.start = parseDate(s, &i) orelse return null;
        if (i >= s.len or s[i] != ',') return null;
        i += 1;
        r.end = parseDate(s, &i) orelse return null;
        return r;
    }

    fn parseName(s: []const u8, i: *usize, buf: *[16]u8) ?usize {
        var n: usize = 0;
        if (i.* < s.len and s[i.*] == '<') {
            i.* += 1;
            while (i.* < s.len and s[i.*] != '>') : (i.* += 1) {
                if (n < buf.len) buf[n] = s[i.*];
                n += 1;
            }
            if (i.* >= s.len) return null;
            i.* += 1;
        } else {
            while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) : (i.* += 1) {
                if (n < buf.len) buf[n] = s[i.*];
                n += 1;
            }
            if (n < 3) return null;
        }
        return @min(n, buf.len);
    }

    /// Parses [+-]hh[:mm[:ss]] into seconds (positive west, as written).
    fn parseOffset(s: []const u8, i: *usize) ?i64 {
        var sign: i64 = 1;
        if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
            if (s[i.*] == '-') sign = -1;
            i.* += 1;
        }
        var total: i64 = 0;
        var part: u32 = 0;
        while (part < 3) : (part += 1) {
            const start = i.*;
            var v: i64 = 0;
            while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
            if (i.* == start) return if (part == 0) null else total * sign;
            total += v * @as(i64, switch (part) {
                0 => 3600,
                1 => 60,
                else => 1,
            });
            if (i.* < s.len and s[i.*] == ':') i.* += 1 else break;
        }
        return total * sign;
    }

    fn parseNum(s: []const u8, i: *usize) ?i64 {
        const start = i.*;
        var v: i64 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        return if (i.* == start) null else v;
    }

    fn parseDate(s: []const u8, i: *usize) ?DateRule {
        var d: DateRule = undefined;
        if (i.* < s.len and s[i.*] == 'J') {
            i.* += 1;
            d = .{ .kind = .julian1, .day = parseNum(s, i) orelse return null };
        } else if (i.* < s.len and s[i.*] == 'M') {
            i.* += 1;
            const m = parseNum(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const w = parseNum(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const wd = parseNum(s, i) orelse return null;
            d = .{ .kind = .month, .month = m, .week = w, .wday = wd };
        } else {
            d = .{ .kind = .julian0, .day = parseNum(s, i) orelse return null };
        }
        d.time = 7200;
        if (i.* < s.len and s[i.*] == '/') {
            i.* += 1;
            d.time = parseOffset(s, i) orelse return null;
        }
        return d;
    }

    /// Local time (seconds since the epoch, in local wall clock) at which
    /// the rule fires in `year`.
    fn ruleLocal(d: DateRule, year: i64) i64 {
        const jan1 = daysFromCivil(year, 1, 1);
        const day: i64 = switch (d.kind) {
            .julian1 => blk: {
                // Day 1..365, February 29 never counted.
                var n = d.day - 1;
                if (isLeap(year) and d.day >= 60) n += 1;
                break :blk jan1 + n;
            },
            .julian0 => jan1 + d.day,
            .month => blk: {
                const first = daysFromCivil(year, d.month, 1);
                const first_wday = @mod(first + 4, 7);
                var dd = first + @mod(d.wday - first_wday, 7) + (d.week - 1) * 7;
                if (d.week == 5) {
                    const mdays = daysFromCivil(if (d.month == 12) year + 1 else year, if (d.month == 12) 1 else d.month + 1, 1) - first;
                    while (dd - first >= mdays) dd -= 7;
                }
                break :blk dd;
            },
        };
        return day * 86400 + d.time;
    }

    fn info(r: *const PosixRule, t: i64) ZoneInfo {
        const std_info: ZoneInfo = .{ .utoff = r.std_off, .isdst = false, .abbr = r.std_abbr[0..r.std_len] };
        if (!r.has_dst) return std_info;
        const dst_info: ZoneInfo = .{ .utoff = r.dst_off, .isdst = true, .abbr = r.dst_abbr[0..r.dst_len] };
        const year = civilFromDays(floorDiv(t + r.std_off, 86400)).year;
        const start = ruleLocal(r.start, year) - r.std_off;
        const end = ruleLocal(r.end, year) - r.dst_off;
        const in_dst = if (start < end) (t >= start and t < end) else !(t >= end and t < start);
        return if (in_dst) dst_info else std_info;
    }
};

const Zone = struct {
    tz: ?std.tz.Tz = null,
    rule: ?PosixRule = null,

    fn deinit(z: *Zone) void {
        if (z.tz) |*t| t.deinit();
    }

    fn info(z: *const Zone, t: i64) ZoneInfo {
        if (z.tz) |*tz| {
            const trans = tz.transitions;
            if (trans.len == 0 or t < trans[0].ts) {
                if (trans.len == 0) {
                    if (z.rule) |*r| return r.info(t);
                }
                if (tz.timetypes.len == 0) return utc_info;
                return typeInfo(&tz.timetypes[0]);
            }
            if (t >= trans[trans.len - 1].ts) {
                if (z.rule) |*r| return r.info(t);
                return typeInfo(trans[trans.len - 1].timetype);
            }
            // Binary search for the last transition at or before t.
            var lo: usize = 0;
            var hi: usize = trans.len - 1;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (trans[mid].ts <= t) lo = mid else hi = mid;
            }
            return typeInfo(trans[lo].timetype);
        }
        if (z.rule) |*r| return r.info(t);
        return utc_info;
    }

    fn typeInfo(tt: *const std.tz.Timetype) ZoneInfo {
        return .{ .utoff = tt.offset, .isdst = tt.isDst(), .abbr = tt.name() };
    }
};

fn loadTzFile(l: *Thread, path: []const u8) ?std.tz.Tz {
    const gpa = l.g.gpa;
    const bytes = std.Io.Dir.cwd().readFileAlloc(l.g.io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(bytes);
    // Version 4 files only add leap second semantics, which this reader
    // does not use. Present them as version 3.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "TZif4")) |p| : (i = p + 5) bytes[p + 4] = '3';
    var r: std.Io.Reader = .fixed(bytes);
    return std.tz.Tz.parse(gpa, &r) catch null;
}

/// Loads the local time zone. The caller deinitializes the result.
fn localZone(l: *Thread) Zone {
    if (builtin.os.tag == .windows) return .{};
    var z: Zone = .{};
    if (envGet(l, "TZ")) |tz_raw| {
        var tzs = tz_raw;
        if (tzs.len == 0) return .{ .rule = PosixRule.parse("UTC0") };
        if (tzs[0] == ':') tzs = tzs[1..];
        if (tzs.len > 0 and tzs[0] == '/') {
            z.tz = loadTzFile(l, tzs);
        } else if (tzs.len > 0 and std.mem.indexOf(u8, tzs, "..") == null) {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "/usr/share/zoneinfo/{s}", .{tzs})) |p| z.tz = loadTzFile(l, p) else |_| {}
        }
        if (z.tz == null) {
            z.rule = PosixRule.parse(tzs);
            return z;
        }
    } else {
        z.tz = loadTzFile(l, "/etc/localtime");
    }
    if (z.tz) |tz| {
        if (tz.footer) |f| z.rule = PosixRule.parse(f);
    }
    return z;
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
    const y = year + 1900 + floorDiv(month, 12);
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

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Conversion specifiers accepted after '%', grouped by length as in Lua.
const single_options = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%";
const double_options = [_][]const u8{ "Ec", "EC", "Ex", "EX", "Ey", "EY", "Od", "Oe", "OH", "OI", "Om", "OM", "OS", "Ou", "OU", "OV", "Ow", "OW", "Oy" };

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
        var conv: u8 = 0;
        if (rest.len >= 1 and std.mem.indexOfScalar(u8, single_options, rest[0]) != null) {
            conv = rest[0];
            i += 1;
        } else if (rest.len >= 2) {
            for (double_options) |o| {
                if (rest[0] == o[0] and rest[1] == o[1]) {
                    conv = o[1];
                    i += 2;
                    break;
                }
            }
        }
        if (conv == 0) return aux.argError(l, 1, "invalid conversion specifier '%{s}'", .{rest});
        formatConv(gpa, &buf, conv, &tm) catch return l.raiseMem();
    }
    return aux.ret(l, try lossyString(l, buf.items));
}

fn isoWeek(tm: *const Tm) struct { year: i64, week: i64 } {
    const iso_wday = @mod(tm.wday + 6, 7); // Monday is 0
    var week = @divFloor(tm.yday - iso_wday + 10, 7);
    var year = tm.year;
    if (week < 1) {
        year -= 1;
        week = weeksInYear(year);
    } else if (week > weeksInYear(year)) {
        year += 1;
        week = 1;
    }
    return .{ .year = year, .week = week };
}

fn weeksInYear(y: i64) i64 {
    const p = struct {
        fn f(x: i64) i64 {
            return @mod(x + floorDiv(x, 4) - floorDiv(x, 100) + floorDiv(x, 400), 7);
        }
    }.f;
    return if (p(y) == 4 or p(y - 1) == 3) 53 else 52;
}

fn formatConv(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), conv: u8, tm: *const Tm) !void {
    switch (conv) {
        'a' => try buf.appendSlice(gpa, day_names[@intCast(tm.wday)][0..3]),
        'A' => try buf.appendSlice(gpa, day_names[@intCast(tm.wday)]),
        'b', 'h' => try buf.appendSlice(gpa, month_names[@intCast(tm.month - 1)][0..3]),
        'B' => try buf.appendSlice(gpa, month_names[@intCast(tm.month - 1)]),
        'c' => {
            try formatConv(gpa, buf, 'a', tm);
            try buf.append(gpa, ' ');
            try formatConv(gpa, buf, 'b', tm);
            try buf.append(gpa, ' ');
            try formatConv(gpa, buf, 'e', tm);
            try buf.append(gpa, ' ');
            try formatConv(gpa, buf, 'T', tm);
            try buf.append(gpa, ' ');
            try formatConv(gpa, buf, 'Y', tm);
        },
        'C' => try pad2(gpa, buf, floorDiv(tm.year, 100)),
        'd' => try pad2(gpa, buf, tm.day),
        'D', 'x' => {
            try pad2(gpa, buf, tm.month);
            try buf.append(gpa, '/');
            try pad2(gpa, buf, tm.day);
            try buf.append(gpa, '/');
            try pad2(gpa, buf, @mod(tm.year, 100));
        },
        'e' => try buf.print(gpa, "{d: >2}", .{@as(u64, @intCast(tm.day))}),
        'F' => {
            try formatConv(gpa, buf, 'Y', tm);
            try buf.append(gpa, '-');
            try pad2(gpa, buf, tm.month);
            try buf.append(gpa, '-');
            try pad2(gpa, buf, tm.day);
        },
        'g' => try pad2(gpa, buf, @mod(isoWeek(tm).year, 100)),
        'G' => try buf.print(gpa, "{d}", .{isoWeek(tm).year}),
        'H' => try pad2(gpa, buf, tm.hour),
        'I' => try pad2(gpa, buf, if (@mod(tm.hour, 12) == 0) 12 else @mod(tm.hour, 12)),
        'j' => try buf.print(gpa, "{d:0>3}", .{@as(u64, @intCast(tm.yday + 1))}),
        'm' => try pad2(gpa, buf, tm.month),
        'M' => try pad2(gpa, buf, tm.min),
        'n' => try buf.append(gpa, '\n'),
        'p' => try buf.appendSlice(gpa, if (tm.hour < 12) "AM" else "PM"),
        'r' => {
            try formatConv(gpa, buf, 'I', tm);
            try buf.append(gpa, ':');
            try pad2(gpa, buf, tm.min);
            try buf.append(gpa, ':');
            try pad2(gpa, buf, tm.sec);
            try buf.append(gpa, ' ');
            try formatConv(gpa, buf, 'p', tm);
        },
        'R' => {
            try pad2(gpa, buf, tm.hour);
            try buf.append(gpa, ':');
            try pad2(gpa, buf, tm.min);
        },
        'S' => try pad2(gpa, buf, tm.sec),
        't' => try buf.append(gpa, '\t'),
        'T', 'X' => {
            try pad2(gpa, buf, tm.hour);
            try buf.append(gpa, ':');
            try pad2(gpa, buf, tm.min);
            try buf.append(gpa, ':');
            try pad2(gpa, buf, tm.sec);
        },
        'u' => try buf.print(gpa, "{d}", .{if (tm.wday == 0) 7 else tm.wday}),
        'U' => try pad2(gpa, buf, @divFloor(tm.yday + 7 - tm.wday, 7)),
        'V' => try pad2(gpa, buf, isoWeek(tm).week),
        'w' => try buf.print(gpa, "{d}", .{tm.wday}),
        'W' => try pad2(gpa, buf, @divFloor(tm.yday + 7 - @mod(tm.wday + 6, 7), 7)),
        'y' => try pad2(gpa, buf, @mod(tm.year, 100)),
        'Y' => try buf.print(gpa, "{d}", .{tm.year}),
        'z' => {
            const off = tm.utoff;
            const a: u64 = @abs(off);
            try buf.print(gpa, "{c}{d:0>2}{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), a / 3600, (a % 3600) / 60 });
        },
        'Z' => try buf.appendSlice(gpa, tm.zone()),
        '%' => try buf.append(gpa, '%'),
        else => unreachable,
    }
}

/// Two digit zero padded number. Negative values keep their sign.
fn pad2(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), n: i64) !void {
    if (n < 0) {
        try buf.print(gpa, "-{d:0>2}", .{@as(u64, @intCast(-n))});
    } else {
        try buf.print(gpa, "{d:0>2}", .{@as(u64, @intCast(n))});
    }
}

test "civil calendar round trip" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    var d: i64 = -800000;
    while (d < 800000) : (d += 997) {
        const c = civilFromDays(d);
        try testing.expectEqual(d, daysFromCivil(c.year, c.month, c.day));
    }
}

test "posix tz rule" {
    const testing = std.testing;
    const r = PosixRule.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    try testing.expectEqual(@as(i64, 3600), r.std_off);
    try testing.expectEqual(@as(i64, 7200), r.dst_off);
    // 2024-07-01 12:00 UTC is summer time, 2024-01-15 is winter time.
    try testing.expect(r.info(1719835200).isdst);
    try testing.expect(!r.info(1705320000).isdst);
    // DST starts 2024-03-31 01:00 UTC.
    try testing.expect(!r.info(1711846799).isdst);
    try testing.expect(r.info(1711846800).isdst);
}
