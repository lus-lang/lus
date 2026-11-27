//! Calendar, time zone and formatting core shared by the `os` and `time`
//! libraries. Everything here is pure Zig and independent of the host C
//! library: proleptic Gregorian calendar arithmetic, checked scalar time
//! arithmetic, TZif parsing into a flat zone layout, POSIX TZ footer
//! rules, the embedded IANA tzdata container, and a `strftime` style
//! formatter for the "C" locale.

const std = @import("std");

// ---------------------------------------------------------------------
// Checked scalar arithmetic

pub const nanos_per_sec: i64 = 1_000_000_000;

pub fn addChecked(a: i64, b: i64) ?i64 {
    const r = @addWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

pub fn subChecked(a: i64, b: i64) ?i64 {
    const r = @subWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

pub fn mulChecked(a: i64, b: i64) ?i64 {
    const r = @mulWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

/// A seconds and nanoseconds pair with `nsec` in [0, nanos_per_sec).
/// Instants and durations both use this layout, with the sign kept in
/// `sec`.
pub const Span = struct {
    sec: i64,
    nsec: i32,
};

/// Folds nanosecond overflow into the seconds while keeping them
/// representable.
pub fn normalize(sec: i64, nsec: i64) ?Span {
    var s = addChecked(sec, @divTrunc(nsec, nanos_per_sec)) orelse return null;
    var rem = @rem(nsec, nanos_per_sec);
    if (rem < 0) {
        rem += nanos_per_sec;
        s = subChecked(s, 1) orelse return null;
    }
    return .{ .sec = s, .nsec = @intCast(rem) };
}

/// The duration of `n` units of `unit_sec` seconds plus `unit_ns`
/// nanoseconds. Splitting the count into quotient and remainder avoids an
/// overflowing intermediate for large millisecond counts whose normalized
/// duration still fits.
pub fn unitDuration(n: i64, unit_sec: i64, unit_ns: i64) ?Span {
    var sec = mulChecked(n, unit_sec) orelse return null;
    const whole = mulChecked(@divTrunc(n, nanos_per_sec), unit_ns) orelse return null;
    const rem = mulChecked(@rem(n, nanos_per_sec), unit_ns) orelse return null;
    sec = addChecked(sec, whole) orelse return null;
    sec = addChecked(sec, @divTrunc(rem, nanos_per_sec)) orelse return null;
    return normalize(sec, @rem(rem, nanos_per_sec));
}

fn fromWide(sec: i128, nsec: i64) ?Span {
    if (sec > std.math.maxInt(i64) or sec < std.math.minInt(i64)) return null;
    return .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
}

/// Sum of two normalized spans.
pub fn spanAdd(a: Span, b: Span) ?Span {
    const total = @as(i64, a.nsec) + b.nsec;
    const carry: i128 = @intFromBool(total >= nanos_per_sec);
    return fromWide(@as(i128, a.sec) + b.sec + carry, @mod(total, nanos_per_sec));
}

/// Difference of two normalized spans.
pub fn spanSub(a: Span, b: Span) ?Span {
    const diff = @as(i64, a.nsec) - b.nsec;
    const borrow: i128 = @intFromBool(diff < 0);
    return fromWide(@as(i128, a.sec) - b.sec - borrow, @mod(diff, nanos_per_sec));
}

/// A span multiplied by an integer factor, computed on magnitudes so the
/// result is exact whenever it is representable.
pub fn spanMul(d: Span, factor: i64) ?Span {
    const negative = (d.sec < 0) != (factor < 0);
    var mag_sec: u64 = undefined;
    var mag_nsec: u64 = undefined;
    if (d.sec >= 0) {
        mag_sec = @intCast(d.sec);
        mag_nsec = @intCast(d.nsec);
    } else if (d.nsec == 0) {
        mag_sec = @abs(d.sec);
        mag_nsec = 0;
    } else {
        mag_sec = @abs(d.sec) - 1;
        mag_nsec = @intCast(nanos_per_sec - d.nsec);
    }
    const mult: u64 = @abs(factor);
    const limit: u64 = @as(u64, std.math.maxInt(i64)) + @intFromBool(negative);
    if (mult != 0 and mag_sec > limit / mult) return null;
    var product_sec = mag_sec * mult;
    const nps: u64 = @intCast(nanos_per_sec);
    const nsec_product = mag_nsec * (mult % nps);
    const carry = mag_nsec * (mult / nps) + nsec_product / nps;
    const product_nsec = nsec_product % nps;
    if (carry > limit - product_sec) return null;
    product_sec += carry;
    if (!negative) return .{ .sec = @intCast(product_sec), .nsec = @intCast(product_nsec) };
    if (product_nsec == 0) return .{ .sec = @bitCast(0 -% product_sec), .nsec = 0 };
    if (product_sec >= @as(u64, std.math.maxInt(i64)) + 1) return null;
    const neg: i64 = -@as(i64, @intCast(product_sec));
    return .{ .sec = subChecked(neg, 1) orelse return null, .nsec = @intCast(nps - product_nsec) };
}

pub fn spanOrder(a: Span, b: Span) std.math.Order {
    if (a.sec != b.sec) return std.math.order(a.sec, b.sec);
    return std.math.order(a.nsec, b.nsec);
}

// ---------------------------------------------------------------------
// Calendar arithmetic (proleptic Gregorian, days since 1970-01-01)

pub fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysInMonth(y: i64, m: i64) i64 {
    const dm = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2) return if (isLeap(y)) 29 else 28;
    return dm[@intCast(m - 1)];
}

/// Days from 1970-01-01 to a civil date, or null when the count does not
/// fit in an integer. `m` is 1..12 and `d` is 1..31.
pub fn daysFromCivilChecked(y_in: i64, m: i64, d: i64) ?i64 {
    const y = if (m <= 2) subChecked(y_in, 1) orelse return null else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const era_days = mulChecked(era, 146097) orelse return null;
    return subChecked(addChecked(era_days, doe) orelse return null, 719468);
}

/// Days from 1970-01-01 to a civil date whose day count is known to fit.
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    return daysFromCivilChecked(y, m, d).?;
}

pub const Civil = struct { year: i64, month: i64, day: i64 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = @as(i128, z_in) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(if (m <= 2) y + 1 else y), .month = @intCast(m), .day = @intCast(d) };
}

/// ISO weekday of a day count: 1 is Monday and 7 is Sunday.
pub fn isoWeekday(days: i64) i64 {
    return @mod(days + 3, 7) + 1;
}

/// Splits seconds since the epoch into whole days and the second of the
/// day.
pub fn splitDays(seconds: i64) struct { days: i64, secs: i64 } {
    const days = @divFloor(seconds, 86400);
    // The second of the day comes from the remainder, since the product
    // of the days has no place in 64 bits near the lowest time.
    return .{ .days = days, .secs = @mod(seconds, 86400) };
}

/// Seconds since the epoch of a civil wall clock time, or null on
/// overflow.
pub fn civilSeconds(y: i64, m: i64, d: i64, hour: i64, min: i64, sec: i64) ?i64 {
    const days = daysFromCivilChecked(y, m, d) orelse return null;
    var r = mulChecked(days, 86400) orelse return null;
    r = addChecked(r, mulChecked(hour, 3600) orelse return null) orelse return null;
    r = addChecked(r, mulChecked(min, 60) orelse return null) orelse return null;
    return addChecked(r, sec);
}

// ---------------------------------------------------------------------
// Broken-down time

pub const Tm = struct {
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

    pub fn zone(t: *const Tm) []const u8 {
        return t.abbr[0..t.abbr_len];
    }
};

/// Breaks down a wall clock time (seconds since the epoch, already
/// shifted by the zone offset).
pub fn breakDownWall(local: i64, info: ZoneInfo) Tm {
    const sd = splitDays(local);
    const c = civilFromDays(sd.days);
    var tm: Tm = .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @divTrunc(sd.secs, 3600),
        .min = @divTrunc(@mod(sd.secs, 3600), 60),
        .sec = @mod(sd.secs, 60),
        .wday = @mod(sd.days + 4, 7), // 1970-01-01 was a Thursday
        .yday = sd.days - daysFromCivil(c.year, 1, 1),
        .isdst = info.isdst,
        .utoff = info.utoff,
    };
    const n = @min(info.abbr.len, tm.abbr.len);
    @memcpy(tm.abbr[0..n], info.abbr[0..n]);
    tm.abbr_len = n;
    return tm;
}

/// Breaks down the instant `t` as observed with zone information `info`.
pub fn breakDown(t: i64, info: ZoneInfo) Tm {
    return breakDownWall(t +% info.utoff, info);
}

// ---------------------------------------------------------------------
// Time zones

pub const ZoneInfo = struct {
    utoff: i64,
    isdst: bool,
    abbr: []const u8,
};

pub const utc_info: ZoneInfo = .{ .utoff = 0, .isdst = false, .abbr = "UTC" };

/// A POSIX TZ rule such as "CET-1CEST,M3.5.0,M10.5.0/3".
pub const PosixRule = struct {
    std_abbr: [16]u8 = @splat(0),
    std_len: usize = 0,
    std_off: i64 = 0, // seconds east of UTC
    has_dst: bool = false,
    dst_abbr: [16]u8 = @splat(0),
    dst_len: usize = 0,
    dst_off: i64 = 0,
    start: DateRule = .{ .kind = .month, .month = 3, .week = 2, .wday = 0, .time = 7200 },
    end: DateRule = .{ .kind = .month, .month = 11, .week = 1, .wday = 0, .time = 7200 },

    pub const DateRule = struct {
        kind: enum { julian1, julian0, month },
        day: i64 = 0,
        month: i64 = 0,
        week: i64 = 0,
        wday: i64 = 0,
        time: i64 = 7200,
    };

    pub fn parse(s: []const u8) ?PosixRule {
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
            while (i.* < s.len and std.ascii.isDigit(s[i.*]) and i.* - start < 3) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
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
        while (i.* < s.len and std.ascii.isDigit(s[i.*]) and i.* - start < 6) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        return if (i.* == start) null else v;
    }

    fn parseDate(s: []const u8, i: *usize) ?DateRule {
        var d: DateRule = undefined;
        if (i.* < s.len and s[i.*] == 'J') {
            i.* += 1;
            d = .{ .kind = .julian1, .day = parseNum(s, i) orelse return null };
            if (d.day < 1 or d.day > 365) return null;
        } else if (i.* < s.len and s[i.*] == 'M') {
            i.* += 1;
            const m = parseNum(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const w = parseNum(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const wd = parseNum(s, i) orelse return null;
            if (m < 1 or m > 12 or w < 1 or w > 5 or wd > 6) return null;
            d = .{ .kind = .month, .month = m, .week = w, .wday = wd };
        } else {
            d = .{ .kind = .julian0, .day = parseNum(s, i) orelse return null };
            if (d.day > 365) return null;
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
                const mdays = daysInMonth(year, d.month);
                while (dd - first >= mdays) dd -= 7;
                break :blk dd;
            },
        };
        return day * 86400 + d.time;
    }

    pub fn info(r: *const PosixRule, t: i64) ZoneInfo {
        const std_info: ZoneInfo = .{ .utoff = r.std_off, .isdst = false, .abbr = r.std_abbr[0..r.std_len] };
        if (!r.has_dst) return std_info;
        const dst_info: ZoneInfo = .{ .utoff = r.dst_off, .isdst = true, .abbr = r.dst_abbr[0..r.dst_len] };
        // Years far outside the calendar range use standard time.
        if (t > (1 << 55) or t < -(1 << 55)) return std_info;
        const year = civilFromDays(@divFloor(t + r.std_off, 86400)).year;
        const start = ruleLocal(r.start, year) - r.std_off;
        const end = ruleLocal(r.end, year) - r.dst_off;
        const in_dst = if (start < end) (t >= start and t < end) else !(t >= end and t < start);
        return if (in_dst) dst_info else std_info;
    }
};

/// A time zone in a flat layout: a header followed in the same memory
/// block by its transition arrays. Both the `os` library (heap memory)
/// and the `time` library (userdata payloads) store zones this way, so a
/// zone needs no separate allocations.
///
/// Trailing layout, in order: `times: [timecnt]i64`, `offs: [typecnt]i32`,
/// `idx: [timecnt]u8`, `isdst: [typecnt]u8`, `abbrind: [typecnt]u8`,
/// `chars: [charcnt]u8`.
pub const FlatZone = struct {
    timecnt: u32 = 0,
    typecnt: u32 = 0,
    charcnt: u32 = 0,
    has_rule: bool = false,
    rule: PosixRule = .{},

    pub fn sizeFor(timecnt: usize, typecnt: usize, charcnt: usize) usize {
        return @sizeOf(FlatZone) + timecnt * 8 + typecnt * 4 + timecnt + typecnt * 2 + charcnt;
    }

    fn tail(z: anytype) [*]align(8) u8 {
        const base: [*]align(8) u8 = @ptrCast(@constCast(z));
        return base + @sizeOf(FlatZone);
    }

    pub fn times(z: *const FlatZone) []i64 {
        const p: [*]i64 = @ptrCast(tail(z));
        return p[0..z.timecnt];
    }
    pub fn offs(z: *const FlatZone) []i32 {
        const p: [*]i32 = @ptrCast(@alignCast(tail(z) + z.timecnt * 8));
        return p[0..z.typecnt];
    }
    fn bytesAt(z: *const FlatZone, off: usize, n: usize) []u8 {
        return (tail(z) + z.timecnt * 8 + z.typecnt * 4 + off)[0..n];
    }
    pub fn idx(z: *const FlatZone) []u8 {
        return z.bytesAt(0, z.timecnt);
    }
    pub fn isdst(z: *const FlatZone) []u8 {
        return z.bytesAt(z.timecnt, z.typecnt);
    }
    pub fn abbrind(z: *const FlatZone) []u8 {
        return z.bytesAt(z.timecnt + z.typecnt, z.typecnt);
    }
    pub fn chars(z: *const FlatZone) []u8 {
        return z.bytesAt(z.timecnt + z.typecnt * 2, z.charcnt);
    }

    /// Initializes a fixed offset zone in `mem`, which holds at least
    /// `sizeFor(0, 1, 0)` bytes.
    pub fn initFixed(mem: []align(8) u8, offset: i32) *FlatZone {
        const z: *FlatZone = @ptrCast(mem.ptr);
        z.* = .{ .typecnt = 1 };
        z.offs()[0] = offset;
        z.isdst()[0] = 0;
        z.abbrind()[0] = 0;
        return z;
    }

    /// Initializes a zone governed only by a POSIX rule.
    pub fn initRule(mem: []align(8) u8, rule: PosixRule) *FlatZone {
        const z: *FlatZone = @ptrCast(mem.ptr);
        z.* = .{ .has_rule = true, .rule = rule };
        return z;
    }

    fn typeInfo(z: *const FlatZone, i: usize) ZoneInfo {
        const c = z.chars();
        const start = @min(z.abbrind()[i], c.len);
        const end = std.mem.indexOfScalarPos(u8, c, start, 0) orelse c.len;
        return .{ .utoff = z.offs()[i], .isdst = z.isdst()[i] != 0, .abbr = c[start..end] };
    }

    /// Zone information in effect at the instant `t`.
    pub fn info(z: *const FlatZone, t: i64) ZoneInfo {
        const ts = z.times();
        if (ts.len == 0) {
            if (z.has_rule) return z.rule.info(t);
            if (z.typecnt == 0) return utc_info;
            return z.typeInfo(0);
        }
        if (t < ts[0]) {
            // Before the first transition: the earliest standard time type.
            for (z.isdst(), 0..) |d, i| if (d == 0) return z.typeInfo(i);
            return z.typeInfo(0);
        }
        var lo: usize = 0;
        var hi: usize = ts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (ts[mid] <= t) lo = mid else hi = mid;
        }
        // Past the last explicit transition the footer rule governs.
        if (lo == ts.len - 1 and z.has_rule) return z.rule.info(t);
        return z.typeInfo(z.idx()[lo]);
    }

    pub fn offsetAt(z: *const FlatZone, t: i64) i64 {
        return z.info(t).utoff;
    }
};

/// The location of the data blocks inside a TZif record.
pub const Tzif = struct {
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
    time_size: usize,
    data: []const u8,
    footer: ?[]const u8,

    pub const ParseError = error{
        Malformed,
        Truncated,
        BadV2Magic,
        NoTypes,
        TypeOutOfRange,
    };

    fn be32(p: []const u8) u32 {
        return std.mem.readInt(u32, p[0..4], .big);
    }

    /// Validates a TZif record and locates its data, preferring the 64-bit
    /// block of version 2 and later.
    pub fn scan(p: []const u8) ParseError!Tzif {
        if (p.len < 44 or !std.mem.eql(u8, p[0..4], "TZif")) return error.Malformed;
        const version = p[4];
        var h = p;
        var isutcnt = be32(h[20..]);
        var isstdcnt = be32(h[24..]);
        var leapcnt = be32(h[28..]);
        var timecnt = be32(h[32..]);
        var typecnt = be32(h[36..]);
        var charcnt = be32(h[40..]);
        var time_size: usize = 4;
        var footer: ?[]const u8 = null;
        if (version >= '2') {
            const v1 = @as(usize, timecnt) * 5 + @as(usize, typecnt) * 6 + charcnt + @as(usize, leapcnt) * 8 + isstdcnt + isutcnt;
            if (44 + v1 + 44 > p.len) return error.Truncated;
            h = p[44 + v1 ..];
            if (!std.mem.eql(u8, h[0..4], "TZif")) return error.BadV2Magic;
            isutcnt = be32(h[20..]);
            isstdcnt = be32(h[24..]);
            leapcnt = be32(h[28..]);
            timecnt = be32(h[32..]);
            typecnt = be32(h[36..]);
            charcnt = be32(h[40..]);
            time_size = 8;
        }
        if (typecnt == 0) return error.NoTypes;
        const body = h[44..];
        const need = @as(usize, timecnt) * (time_size + 1) + @as(usize, typecnt) * 6 + charcnt;
        if (need > body.len) return error.Truncated;
        if (version >= '2') {
            const full = need + @as(usize, leapcnt) * 12 + isstdcnt + isutcnt;
            if (full < body.len and body[full] == '\n') {
                const rest = body[full + 1 ..];
                const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                if (end > 0) footer = rest[0..end];
            }
        }
        return .{ .timecnt = timecnt, .typecnt = typecnt, .charcnt = charcnt, .time_size = time_size, .data = body, .footer = footer };
    }

    pub fn flatSize(t: Tzif) usize {
        return FlatZone.sizeFor(t.timecnt, t.typecnt, t.charcnt);
    }

    /// Writes the zone into `mem`, which holds at least `flatSize()` bytes.
    pub fn fill(t: Tzif, mem: []align(8) u8) ParseError!*FlatZone {
        const z: *FlatZone = @ptrCast(mem.ptr);
        z.* = .{ .timecnt = t.timecnt, .typecnt = t.typecnt, .charcnt = t.charcnt };
        const d = t.data;
        const types_at = @as(usize, t.timecnt) * t.time_size;
        const ttinfo_at = types_at + t.timecnt;
        const chars_at = ttinfo_at + @as(usize, t.typecnt) * 6;
        for (z.times(), 0..) |*x, i| {
            x.* = if (t.time_size == 8)
                std.mem.readInt(i64, d[i * 8 ..][0..8], .big)
            else
                std.mem.readInt(i32, d[i * 4 ..][0..4], .big);
        }
        for (z.idx(), 0..) |*x, i| {
            x.* = d[types_at + i];
            if (x.* >= t.typecnt) return error.TypeOutOfRange;
        }
        for (0..t.typecnt) |i| {
            const rec = d[ttinfo_at + i * 6 ..][0..6];
            z.offs()[i] = std.mem.readInt(i32, rec[0..4], .big);
            z.isdst()[i] = @intFromBool(rec[4] != 0);
            z.abbrind()[i] = rec[5];
        }
        @memcpy(z.chars(), d[chars_at..][0..t.charcnt]);
        if (t.footer) |f| {
            if (PosixRule.parse(f)) |r| {
                z.rule = r;
                z.has_rule = true;
            }
        }
        return z;
    }
};

// ---------------------------------------------------------------------
// Embedded IANA tzdata

/// The IANA tzdata release embedded in this build.
pub const tzdata_version = @embedFile("data/tzdata.version");

/// The zstd compressed container generated by `tools/gen-tzdata.js`
/// (run `mise run gen:tzdata`). Its layout (integers little endian) is
/// the magic "LTZ1", a length prefixed version string, a u32 zone count,
/// then for each zone sorted by name a u16 length prefixed name and a u32
/// length prefixed TZif record.
const tzdata_z = @embedFile("data/tzdata.zst");

/// Decompresses the embedded container into a buffer owned by the caller.
pub fn decompressTzdata(gpa: std.mem.Allocator) error{ OutOfMemory, Corrupt }![]u8 {
    var in: std.Io.Reader = .fixed(tzdata_z);
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(gpa, 384 * 1024) catch return error.OutOfMemory;
    errdefer out.deinit();
    var d: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
    _ = d.reader.streamRemaining(&out.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    const bytes = out.toOwnedSlice() catch return error.OutOfMemory;
    if (bytes.len < 9 or !std.mem.eql(u8, bytes[0..4], "LTZ1")) {
        gpa.free(bytes);
        return error.Corrupt;
    }
    return bytes;
}

/// Finds the TZif record of the zone `name` in a decompressed container.
pub fn findZone(container: []const u8, name: []const u8) ?[]const u8 {
    if (container.len < 9) return null;
    var pos: usize = 5 + @as(usize, container[4]);
    if (pos + 4 > container.len) return null;
    const count = std.mem.readInt(u32, container[pos..][0..4], .little);
    pos += 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 2 > container.len) return null;
        const nlen = std.mem.readInt(u16, container[pos..][0..2], .little);
        pos += 2;
        if (pos + nlen + 4 > container.len) return null;
        const entry = container[pos .. pos + nlen];
        pos += nlen;
        const dlen = std.mem.readInt(u32, container[pos..][0..4], .little);
        pos += 4;
        if (pos + dlen > container.len) return null;
        if (std.mem.eql(u8, entry, name)) return container[pos .. pos + dlen];
        pos += dlen;
    }
    return null;
}

/// The IANA zone name selected by the `TZ` value or the zoneinfo path
/// `s`, taking the part after a "/zoneinfo/" directory.
pub fn zoneNameFromPath(s: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, "/zoneinfo/") orelse return null;
    return s[i + 10 ..];
}

// ---------------------------------------------------------------------
// Formatting ("C" locale strftime)

pub const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
pub const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Conversion specifiers accepted after '%', grouped by length as in Lua.
pub const single_options = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%";
pub const double_options = [_][]const u8{ "Ec", "EC", "Ex", "EX", "Ey", "EY", "Od", "Oe", "OH", "OI", "Om", "OM", "OS", "Ou", "OU", "OV", "Ow", "OW", "Oy" };

/// Matches the conversion at the start of `rest` (the text after '%').
/// Returns the conversion character and the number of bytes it spans.
pub fn matchConversion(rest: []const u8) ?struct { conv: u8, len: usize } {
    if (rest.len >= 1 and std.mem.indexOfScalar(u8, single_options, rest[0]) != null) return .{ .conv = rest[0], .len = 1 };
    if (rest.len >= 2) {
        for (double_options) |o| {
            if (rest[0] == o[0] and rest[1] == o[1]) return .{ .conv = o[1], .len = 2 };
        }
    }
    return null;
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
            return @mod(x + @divFloor(x, 4) - @divFloor(x, 100) + @divFloor(x, 400), 7);
        }
    }.f;
    return if (p(y) == 4 or p(y - 1) == 3) 53 else 52;
}

/// Appends one conversion (as returned by `matchConversion`).
pub fn formatConv(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), conv: u8, tm: *const Tm) !void {
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
        'C' => try pad2(gpa, buf, @divFloor(tm.year, 100)),
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
        'z' => try formatOffset(gpa, buf, tm.utoff, false),
        'Z' => try buf.appendSlice(gpa, tm.zone()),
        '%' => try buf.append(gpa, '%'),
        else => unreachable,
    }
}

/// Appends a UTC offset as +HHMM, or +HH:MM when `colon` is set.
pub fn formatOffset(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), off: i64, colon: bool) !void {
    const a: u64 = @abs(off);
    const sign: u8 = if (off < 0) '-' else '+';
    if (colon) {
        try buf.print(gpa, "{c}{d:0>2}:{d:0>2}", .{ sign, a / 3600, (a % 3600) / 60 });
    } else {
        try buf.print(gpa, "{c}{d:0>2}{d:0>2}", .{ sign, a / 3600, (a % 3600) / 60 });
    }
}

/// Two digit zero padded number. Negative values keep their sign.
pub fn pad2(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), n: i64) !void {
    if (n < 0) {
        try buf.print(gpa, "-{d:0>2}", .{@abs(n)});
    } else {
        try buf.print(gpa, "{d:0>2}", .{@as(u64, @intCast(n))});
    }
}

// ---------------------------------------------------------------------
// Tests

test "civil calendar round trip" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    var d: i64 = -800000;
    while (d < 800000) : (d += 997) {
        const c = civilFromDays(d);
        try testing.expectEqual(d, daysFromCivil(c.year, c.month, c.day));
    }
    try testing.expectEqual(@as(i64, 4), isoWeekday(0)); // Thursday
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

test "span arithmetic" {
    const testing = std.testing;
    const a: Span = .{ .sec = 1, .nsec = 600_000_000 };
    const b: Span = .{ .sec = 2, .nsec = 700_000_000 };
    try testing.expectEqual(Span{ .sec = 4, .nsec = 300_000_000 }, spanAdd(a, b).?);
    try testing.expectEqual(Span{ .sec = -2, .nsec = 900_000_000 }, spanSub(a, b).?);
    try testing.expectEqual(Span{ .sec = -5, .nsec = 200_000_000 }, spanMul(a, -3).?);
    try testing.expectEqual(@as(?Span, null), spanAdd(.{ .sec = std.math.maxInt(i64), .nsec = 0 }, .{ .sec = 1, .nsec = 0 }));
    try testing.expectEqual(Span{ .sec = 1, .nsec = 500_000_000 }, unitDuration(1500, 0, 1_000_000).?);
}

test "embedded tzdata" {
    const testing = std.testing;
    const blob = try decompressTzdata(testing.allocator);
    defer testing.allocator.free(blob);
    const rec = findZone(blob, "Europe/Paris").?;
    const t = try Tzif.scan(rec);
    const mem = try testing.allocator.alignedAlloc(u8, .@"8", t.flatSize());
    defer testing.allocator.free(mem);
    const z = try t.fill(mem);
    try testing.expectEqual(@as(i64, 7200), z.offsetAt(1719835200));
    try testing.expectEqual(@as(i64, 3600), z.offsetAt(1705320000));
    try testing.expectEqualStrings("CEST", z.info(1719835200).abbr);
    try testing.expect(findZone(blob, "Nowhere/Land") == null);
}
