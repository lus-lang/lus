//! The `time` library: instants, durations, zoned civil times and time
//! zones. Instants and durations are exact second and nanosecond pairs,
//! and calendar arithmetic is a separate, zone aware operation on zoned
//! values. All four types are immutable userdata.
//!
//! Calendar arithmetic, zone rules and formatting come from
//! `timecore.zig`, which the `os` library shares. Named zones resolve from
//! the IANA tzdata embedded in the runtime, so they behave identically on
//! every platform whatever the host provides.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const ext = @import("../vm/ext.zig");
const aux = @import("aux.zig");
const vector = @import("vector.zig");
const tc = @import("timecore.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;
const Userdata = object.Userdata;
const Span = tc.Span;
const FlatZone = tc.FlatZone;

// ---------------------------------------------------------------------
// Value layouts

/// An absolute point on the timeline. A monotonic instant counts from an
/// arbitrary origin and is only meaningful relative to another reading of
/// the same clock.
const Instant = struct {
    span: Span,
    mono: bool,
};

/// A civil time: the UTC instant `span` observed at `offset` seconds east
/// of UTC. User value 1 holds the originating zone, or nil for a bare
/// fixed offset, so calendar operations can re-resolve the offset.
const Zoned = struct {
    span: Span,
    offset: i32,
};

const Kind = enum {
    instant,
    duration,
    zoned,
    zone,

    fn key(k: Kind) []const u8 {
        return switch (k) {
            .instant => "time.instant",
            .duration => "time.duration",
            .zoned => "time.zoned",
            .zone => "time.zone",
        };
    }
};

const weekday_key = "time.weekday";
const tzdata_key = "time.tzdata";

fn metatableOf(l: *Thread, k: Kind) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(k.key()).?));
}

/// Allocates a userdata of kind `k` and pushes it, so it stays rooted.
fn newUserdata(l: *Thread, k: Kind, size: usize, nuser: u16) Error!*Userdata {
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(size, nuser)) catch return l.raiseMem();
    u.size = size;
    u.nuser = nuser;
    u.metatable = metatableOf(l, k);
    try l.push(Value.obj(.userdata, u));
    return u;
}

fn payload(comptime T: type, u: *Userdata) *T {
    return @ptrCast(@alignCast(u.data()));
}

fn toUserdata(l: *Thread, v: Value, k: Kind) ?*Userdata {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != metatableOf(l, k)) return null;
    return u;
}

fn checkUserdata(l: *Thread, i: u32, k: Kind) Error!*Userdata {
    return toUserdata(l, l.arg(i), k) orelse aux.typeError(l, i, k.key());
}

fn checkInstant(l: *Thread, i: u32) Error!*Instant {
    return payload(Instant, try checkUserdata(l, i, .instant));
}

fn checkDuration(l: *Thread, i: u32) Error!*Span {
    return payload(Span, try checkUserdata(l, i, .duration));
}

fn checkZoned(l: *Thread, i: u32) Error!*Zoned {
    return payload(Zoned, try checkUserdata(l, i, .zoned));
}

fn checkZone(l: *Thread, i: u32) Error!*FlatZone {
    return payload(FlatZone, try checkUserdata(l, i, .zone));
}

fn zoneOf(v: Value) *FlatZone {
    return payload(FlatZone, v.as(Userdata));
}

fn rangeError(l: *Thread) Error {
    return l.raiseFmt("time value out of range", .{});
}

/// Unwraps the result of a checked operation, raising the range error on
/// overflow.
fn ok(l: *Thread, comptime T: type, x: ?T) Error!T {
    return x orelse rangeError(l);
}

fn normalize(l: *Thread, sec: i64, nsec: i64) Error!Span {
    return ok(l, Span, tc.normalize(sec, nsec));
}

fn pushInstant(l: *Thread, span: Span, mono: bool) Error!u32 {
    const u = try newUserdata(l, .instant, @sizeOf(Instant), 0);
    payload(Instant, u).* = .{ .span = span, .mono = mono };
    return 1;
}

fn pushDuration(l: *Thread, span: Span) Error!u32 {
    const u = try newUserdata(l, .duration, @sizeOf(Span), 0);
    payload(Span, u).* = span;
    return 1;
}

/// Pushes a zoned value with no zone attached and returns its userdata.
fn pushZoned(l: *Thread, span: Span, offset: i64) Error!*Userdata {
    const u = try newUserdata(l, .zoned, @sizeOf(Zoned), 1);
    payload(Zoned, u).* = .{ .span = span, .offset = @intCast(offset) };
    return u;
}

/// Resolves the wall clock time `naive` (seconds since the epoch as if
/// UTC) through `zone`, pushes the zoned result and attaches the zone. One
/// correction pass handles the usual daylight saving step. Gaps and
/// overlaps resolve to a single deterministic side.
fn pushZonedInZone(l: *Thread, naive: i64, frac: i32, zone: Value) Error!void {
    const z = zoneOf(zone);
    var g = z.offsetAt(naive);
    var utc = try ok(l, i64, tc.subChecked(naive, g));
    const g2 = z.offsetAt(utc);
    if (g2 != g) {
        utc = try ok(l, i64, tc.subChecked(naive, g2));
        g = g2;
    }
    const u = try pushZoned(l, .{ .sec = utc, .nsec = frac }, g);
    u.userValues()[0] = zone;
}

/// Rebuilds a zoned value from a wall clock time, re-resolving through
/// the zone of `src` when it has one and keeping its fixed offset
/// otherwise.
fn rebuildZoned(l: *Thread, src: *Userdata, naive: i64, frac: i32) Error!u32 {
    const zone = src.userValues()[0];
    if (zone.isNil()) {
        const off = payload(Zoned, src).offset;
        _ = try pushZoned(l, .{ .sec = try ok(l, i64, tc.subChecked(naive, off)), .nsec = frac }, off);
    } else {
        try pushZonedInZone(l, naive, frac, zone);
    }
    return 1;
}

/// Pushes a zone with a fixed offset east of UTC.
fn pushFixedZone(l: *Thread, offset: i32, name: []const u8) Error!u32 {
    const size = FlatZone.sizeFor(0, 1, 0);
    const u = try newUserdata(l, .zone, size, 1);
    const mem: [*]align(8) u8 = @ptrCast(@alignCast(u.data()));
    _ = FlatZone.initFixed(mem[0..size], offset);
    u.userValues()[0] = try l.newStringValue(name);
    return 1;
}

// ---------------------------------------------------------------------
// The embedded zone database

/// The decompressed tzdata container, cached per state in the registry as
/// a vector.
fn tzdata(l: *Thread) Error![]const u8 {
    const reg = l.g.registry.as(Table);
    const cached = try aux.getField(l, reg, tzdata_key);
    if (cached.tag == .vector) return cached.as(object.Vector).bytes.items;
    const bytes = tc.decompressTzdata(l.g.gpa) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.Corrupt => return l.raiseFmt("corrupt embedded tzdata", .{}),
    };
    var list: std.ArrayList(u8) = .fromOwnedSlice(bytes);
    defer list.deinit(l.g.gpa);
    const v = try vector.newVectorFrom(l, &list);
    try l.push(Value.obj(.vector, v));
    defer l.top -= 1;
    try aux.setField(l, reg, tzdata_key, Value.obj(.vector, v));
    return v.bytes.items;
}

fn tzifError(l: *Thread, e: tc.Tzif.ParseError) Error {
    return switch (e) {
        error.Malformed => l.raiseFmt("malformed TZif record", .{}),
        error.Truncated => l.raiseFmt("truncated TZif data", .{}),
        error.BadV2Magic => l.raiseFmt("bad TZif v2 magic", .{}),
        error.NoTypes => l.raiseFmt("TZif record has no local-time types", .{}),
        error.TypeOutOfRange => l.raiseFmt("TZif transition type out of range", .{}),
    };
}

/// Looks up a named zone and pushes it. Returns false, with nothing
/// pushed, when the database has no such zone.
fn lookupZone(l: *Thread, name: []const u8) Error!bool {
    const blob = try tzdata(l);
    const rec = tc.findZone(blob, name) orelse return false;
    const t = tc.Tzif.scan(rec) catch |e| return tzifError(l, e);
    const size = t.flatSize();
    const u = try newUserdata(l, .zone, size, 1);
    const mem: [*]align(8) u8 = @ptrCast(@alignCast(u.data()));
    _ = t.fill(mem[0..size]) catch |e| return tzifError(l, e);
    u.userValues()[0] = try l.newStringValue(name);
    return true;
}

// ---------------------------------------------------------------------
// Argument helpers

fn valueToInt(v: Value) ?i64 {
    return switch (v.tag) {
        .integer => v.asInt(),
        .float, .bigint, .decimal => ops.toIntegerStrict(v),
        .string => if (ops.toNumberCoerce(v)) |n| ops.toIntegerStrict(n) else null,
        else => null,
    };
}

/// Reads an optional integer field of the table argument `arg`. An enum
/// member (such as `time.month.july`) counts as its 1-based index, so the
/// month and weekday enums work interchangeably with integers.
fn field(l: *Thread, arg: u32, key: []const u8, default: i64) Error!i64 {
    const v = try ops.index(l, l.arg(arg), try l.newStringValue(key));
    if (v.isNil()) return default;
    if (v.tag == .enum_value) return @as(i64, v.as(object.EnumValue).index) + 1;
    if (valueToInt(v)) |n| return n;
    if (v.isNumber() or (v.tag == .string and ops.toNumberCoerce(v) != null))
        return aux.argError(l, arg, "field '{s}' has no integer representation", .{key});
    return aux.argError(l, arg, "field '{s}' must be an integer, got {s}", .{ key, l.typeNameOf(v) });
}

fn fixedOffsetValid(seconds: i64) bool {
    return seconds >= -24 * 3600 and seconds <= 24 * 3600;
}

fn fixedOffsetArg(l: *Thread, seconds: i64, arg: u32) Error!i32 {
    if (!fixedOffsetValid(seconds)) return aux.argError(l, arg, "offset out of range", .{});
    return @intCast(seconds);
}

fn fixedOffsetParts(sign: i64, hours: i64, minutes: i64) ?i32 {
    if (minutes < 0 or minutes > 59 or hours < 0 or hours > 24 or (hours == 24 and minutes != 0)) return null;
    const seconds = sign * (hours * 3600 + minutes * 60);
    if (!fixedOffsetValid(seconds)) return null;
    return @intCast(seconds);
}

fn rejectMono(l: *Thread, i: *const Instant) Error!void {
    if (i.mono) return l.raiseFmt("monotonic instants have no calendar representation", .{});
}

// ---------------------------------------------------------------------
// Clocks and constructors

fn readClock(l: *Thread, clock: std.Io.Clock) Span {
    const ns: i96 = clock.now(l.g.io).nanoseconds;
    return .{
        .sec = @intCast(@divFloor(ns, tc.nanos_per_sec)),
        .nsec = @intCast(@mod(ns, tc.nanos_per_sec)),
    };
}

fn timeNow(l: *Thread) Error!u32 {
    return pushInstant(l, readClock(l, .real), false);
}

fn timeMonotonic(l: *Thread) Error!u32 {
    return pushInstant(l, readClock(l, .awake), true);
}

fn timeInstant(l: *Thread) Error!u32 {
    const sec = try aux.checkInt(l, 1);
    const nsec = try aux.optInt(l, 2, 0);
    return pushInstant(l, try normalize(l, sec, nsec), false);
}

fn timeDuration(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    l.top = l.base() + 1;
    const units = [_]struct { []const u8, i64, i64 }{
        .{ "days", 86400, 0 },
        .{ "hours", 3600, 0 },
        .{ "minutes", 60, 0 },
        .{ "seconds", 1, 0 },
        .{ "millis", 0, 1_000_000 },
        .{ "micros", 0, 1_000 },
        .{ "nanos", 0, 1 },
    };
    var total: Span = .{ .sec = 0, .nsec = 0 };
    for (units) |unit| {
        const n = try field(l, 1, unit[0], 0);
        const part = try ok(l, Span, tc.unitDuration(n, unit[1], unit[2]));
        total = try ok(l, Span, tc.spanAdd(total, part));
    }
    return pushDuration(l, total);
}

fn unitHelper(l: *Thread, unit_sec: i64, unit_ns: i64) Error!u32 {
    const n = try aux.checkInt(l, 1);
    return pushDuration(l, try ok(l, Span, tc.unitDuration(n, unit_sec, unit_ns)));
}

fn timeDays(l: *Thread) Error!u32 {
    return unitHelper(l, 86400, 0);
}
fn timeHours(l: *Thread) Error!u32 {
    return unitHelper(l, 3600, 0);
}
fn timeMinutes(l: *Thread) Error!u32 {
    return unitHelper(l, 60, 0);
}
fn timeSeconds(l: *Thread) Error!u32 {
    return unitHelper(l, 1, 0);
}
fn timeMillis(l: *Thread) Error!u32 {
    return unitHelper(l, 0, 1_000_000);
}

/// The wall clock fields of a zoned value.
const Fields = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64 };

fn zonedFields(l: *Thread, z: *const Zoned) Error!Fields {
    const wall = try ok(l, i64, tc.addChecked(z.span.sec, z.offset));
    const sd = tc.splitDays(wall);
    const c = tc.civilFromDays(sd.days);
    return .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @divTrunc(sd.secs, 3600),
        .minute = @divTrunc(@mod(sd.secs, 3600), 60),
        .second = @mod(sd.secs, 60),
    };
}

/// Reads civil fields from the table argument `arg` over `def` and returns
/// the normalized wall clock time.
fn civilFromTable(l: *Thread, arg: u32, def: Fields, def_nsec: i64) Error!Span {
    const year = try field(l, arg, "year", def.year);
    const month = try field(l, arg, "month", def.month);
    const day = try field(l, arg, "day", def.day);
    const hour = try field(l, arg, "hour", def.hour);
    const minute = try field(l, arg, "minute", def.minute);
    const second = try field(l, arg, "second", def.second);
    const nsec = try field(l, arg, "nanosecond", def_nsec);
    if (month < 1 or month > 12) return aux.argError(l, arg, "month out of range", .{});
    if (day < 1 or day > 31) return aux.argError(l, arg, "day out of range", .{});
    const naive = try ok(l, i64, tc.civilSeconds(year, month, day, hour, minute, second));
    return normalize(l, naive, nsec);
}

fn timeZoned(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    l.top = l.base() + @min(l.argCount(), 2);
    const epoch: Fields = .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    const wall = try civilFromTable(l, 1, epoch, 0);
    const zone = l.arg(2);
    if (toUserdata(l, zone, .zone) != null) {
        try pushZonedInZone(l, wall.sec, wall.nsec, zone);
    } else {
        const off = try fixedOffsetArg(l, try aux.optInt(l, 2, 0), 2);
        _ = try pushZoned(l, .{ .sec = try ok(l, i64, tc.subChecked(wall.sec, off)), .nsec = wall.nsec }, off);
    }
    return 1;
}

// ---------------------------------------------------------------------
// Parsing

/// A cursor over the input that reads 0 past the end, like a C string.
const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(c: *const Cursor) u8 {
        return if (c.i < c.s.len) c.s[c.i] else 0;
    }

    fn next(c: *Cursor) u8 {
        const ch = c.peek();
        if (c.i < c.s.len) c.i += 1;
        return ch;
    }

    /// Reads exactly `n` decimal digits.
    fn digits(c: *Cursor, n: usize) ?i64 {
        var v: i64 = 0;
        for (0..n) |_| {
            const ch = c.peek();
            if (!std.ascii.isDigit(ch)) return null;
            v = v * 10 + (ch - '0');
            c.i += 1;
        }
        return v;
    }

    /// Reads one to `max` decimal digits.
    fn number(c: *Cursor, max: usize) ?i64 {
        var v: i64 = 0;
        var n: usize = 0;
        while (n < max and std.ascii.isDigit(c.peek())) : (n += 1) {
            v = v * 10 + (c.peek() - '0');
            c.i += 1;
        }
        return if (n == 0) null else v;
    }
};

fn pushParsed(l: *Thread, naive: i64, frac: i32, offset: ?i32) Error!u32 {
    if (offset) |off| {
        _ = try pushZoned(l, .{ .sec = try ok(l, i64, tc.subChecked(naive, off)), .nsec = frac }, off);
        return 1;
    }
    return pushInstant(l, .{ .sec = naive, .nsec = frac }, false);
}

fn mismatch(l: *Thread, s: []const u8, fmt: []const u8) Error {
    return l.raiseFmt("'{s}' does not match time format '{s}'", .{ s, fmt });
}

/// Parses `s` against an explicit pattern. Supports the numeric fields
/// %Y %y %m %d %e %H %M %S, the zone %z (Z or +/-HH[:]MM), and %% for a
/// literal percent. A space in the pattern matches a run of whitespace,
/// and any other character must match exactly.
fn parseFormat(l: *Thread, s: []const u8, fmt: []const u8) Error!u32 {
    var y: i64 = 1970;
    var mo: i64 = 1;
    var d: i64 = 1;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var offset: ?i32 = null;
    var c: Cursor = .{ .s = s };
    var f: usize = 0;
    while (f < fmt.len) : (f += 1) {
        const fc = fmt[f];
        if (fc == '%') {
            f += 1;
            const spec: u8 = if (f < fmt.len) fmt[f] else 0;
            switch (spec) {
                'Y' => y = c.number(4) orelse return mismatch(l, s, fmt),
                'y' => y = 2000 + (c.number(2) orelse return mismatch(l, s, fmt)),
                'm' => mo = c.number(2) orelse return mismatch(l, s, fmt),
                'd', 'e' => {
                    while (c.peek() == ' ') c.i += 1;
                    d = c.number(2) orelse return mismatch(l, s, fmt);
                },
                'H' => h = c.number(2) orelse return mismatch(l, s, fmt),
                'M' => mi = c.number(2) orelse return mismatch(l, s, fmt),
                'S' => sec = c.number(2) orelse return mismatch(l, s, fmt),
                'z' => {
                    const ch = c.peek();
                    if (ch == 'Z') {
                        c.i += 1;
                    } else if (ch == '+' or ch == '-') {
                        c.i += 1;
                        const sign: i64 = if (ch == '-') -1 else 1;
                        const oh = c.number(2) orelse return mismatch(l, s, fmt);
                        if (c.peek() == ':') c.i += 1;
                        var om: i64 = 0;
                        if (std.ascii.isDigit(c.peek())) om = c.number(2) orelse return mismatch(l, s, fmt);
                        offset = fixedOffsetParts(sign, oh, om) orelse return mismatch(l, s, fmt);
                    } else return mismatch(l, s, fmt);
                },
                '%' => if (c.next() != '%') return mismatch(l, s, fmt),
                else => {
                    const n = if (f < fmt.len) std.unicode.utf8ByteSequenceLength(spec) catch 1 else 0;
                    return l.raiseFmt("unsupported time format specifier '%{s}'", .{fmt[f..@min(f + n, fmt.len)]});
                },
            }
        } else if (fc == ' ') {
            while (c.peek() == ' ' or c.peek() == '\t') c.i += 1;
        } else {
            if (c.i >= s.len or s[c.i] != fc) return mismatch(l, s, fmt);
            c.i += 1;
        }
    }
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return mismatch(l, s, fmt);
    const naive = try ok(l, i64, tc.civilSeconds(y, mo, d, h, mi, sec));
    return pushParsed(l, naive, 0, offset);
}

/// Parses an ISO 8601 date and time, or a custom pattern when a format is
/// given. The result is an instant for UTC ("Z") or offset-free input, and
/// a zoned value when the input carries an explicit numeric offset.
fn timeParse(l: *Thread) Error!u32 {
    const s = try aux.checkBytes(l, 1);
    if (!l.arg(2).isNil()) return parseFormat(l, s, try aux.checkBytes(l, 2));
    var c: Cursor = .{ .s = s };
    var hh: i64 = 0;
    var mi: i64 = 0;
    var ss: i64 = 0;
    var frac: i64 = 0;
    var offset: ?i32 = null;
    const y = c.digits(4);
    const mo = if (y != null and c.next() == '-') c.digits(2) else null;
    const d = if (mo != null and c.next() == '-') c.digits(2) else null;
    if (y == null or mo == null or d == null) return l.raiseFmt("invalid ISO 8601 date in '{s}'", .{s});
    if (mo.? < 1 or mo.? > 12 or d.? < 1 or d.? > 31) return l.raiseFmt("ISO 8601 date out of range in '{s}'", .{s});
    if (c.peek() == 'T' or c.peek() == ' ') {
        c.i += 1;
        hh = c.digits(2) orelse return l.raiseFmt("invalid ISO 8601 time in '{s}'", .{s});
        if (c.next() != ':') return l.raiseFmt("invalid ISO 8601 time in '{s}'", .{s});
        mi = c.digits(2) orelse return l.raiseFmt("invalid ISO 8601 time in '{s}'", .{s});
        if (c.peek() == ':') {
            c.i += 1;
            ss = c.digits(2) orelse return l.raiseFmt("invalid ISO 8601 seconds in '{s}'", .{s});
        }
        if (c.peek() == '.' or c.peek() == ',') {
            // Fractional seconds keep up to nine digits.
            c.i += 1;
            if (!std.ascii.isDigit(c.peek())) return l.raiseFmt("invalid fractional seconds in '{s}'", .{s});
            var scale: i64 = tc.nanos_per_sec / 10;
            while (std.ascii.isDigit(c.peek())) : (c.i += 1) {
                if (scale >= 1) {
                    frac += (c.peek() - '0') * scale;
                    scale = @divTrunc(scale, 10);
                }
            }
        }
        const ch = c.peek();
        if (ch == 'Z') {
            c.i += 1;
        } else if (ch == '+' or ch == '-') {
            c.i += 1;
            const sign: i64 = if (ch == '-') -1 else 1;
            const oh = c.digits(2) orelse return l.raiseFmt("invalid zone offset in '{s}'", .{s});
            if (c.peek() == ':') c.i += 1;
            var om: i64 = 0;
            if (std.ascii.isDigit(c.peek())) om = c.digits(2) orelse return l.raiseFmt("invalid zone offset in '{s}'", .{s});
            offset = fixedOffsetParts(sign, oh, om) orelse return l.raiseFmt("invalid zone offset in '{s}'", .{s});
        }
    }
    while (c.peek() == ' ') c.i += 1;
    if (c.i < s.len) return l.raiseFmt("trailing characters in '{s}'", .{s});
    const naive = try ok(l, i64, tc.civilSeconds(y.?, mo.?, d.?, hh, mi, ss));
    return pushParsed(l, naive, @intCast(frac), offset);
}

// ---------------------------------------------------------------------
// Zones

fn timeZone(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    if (!try lookupZone(l, name)) return l.raiseFmt("unknown time zone '{s}'", .{name});
    return 1;
}

fn timeOffset(l: *Thread) Error!u32 {
    const secs = try aux.checkInt(l, 1);
    const fixed = try fixedOffsetArg(l, secs, 1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    tc.formatOffset(l.g.gpa, &buf, fixed, true) catch return l.raiseMem();
    return pushFixedZone(l, fixed, buf.items);
}

/// Copies the zone name found after a "/zoneinfo/" path component.
fn nameFromPath(buf: []u8, path: []const u8) ?[]const u8 {
    const name = tc.zoneNameFromPath(path) orelse return null;
    if (name.len == 0 or name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

/// Detects the IANA name of the host's local zone.
fn detectLocalZone(l: *Thread, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return windowsLocalZone();
    const io = l.g.io;
    if (@import("os.zig").envGet(l, "TZ")) |tz_raw| {
        var tz = tz_raw;
        if (tz.len > 0 and tz[0] == ':') tz = tz[1..];
        if (tz.len > 0 and tz[0] == '/') {
            if (nameFromPath(buf, tz)) |n| return n;
        } else if (tz.len > 0 and tz.len <= buf.len) {
            // A bare zone name. POSIX TZ rules are not resolved here.
            @memcpy(buf[0..tz.len], tz);
            return buf[0..tz.len];
        }
    }
    // /etc/localtime is normally a symbolic link into the zoneinfo tree.
    var link: [512]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &link)) |n| {
        if (nameFromPath(buf, link[0..n])) |name| return name;
    } else |_| {}
    // Debian and its derivatives record the name in /etc/timezone.
    if (std.Io.Dir.cwd().readFile(io, "/etc/timezone", buf)) |content| {
        const line = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
        const name = std.mem.trimEnd(u8, line, "\r ");
        if (name.len > 0) return name;
    } else |_| {}
    return null;
}

fn windowsLocalZone() ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const winzones = @import("winzones.zig");
    return winzones.localZoneName();
}

fn timeLocalzone(l: *Thread) Error!u32 {
    var buf: [256]u8 = undefined;
    if (detectLocalZone(l, &buf)) |name| {
        if (try lookupZone(l, name)) return 1;
    }
    // Fall back to UTC when detection fails.
    return pushFixedZone(l, 0, "UTC");
}

fn tzdataVersion(l: *Thread) Error!u32 {
    return aux.retStr(l, tc.tzdata_version);
}

// ---------------------------------------------------------------------
// Formatting

const iso_utc = "%Y-%m-%dT%H:%M:%SZ";
const iso_local = "%Y-%m-%dT%H:%M:%S";

/// Formats a wall clock time (already shifted by `utoff`) like C
/// `strftime` in the "C" locale. The year is zero padded to four digits
/// and %z renders the stored offset, so the output is identical on every
/// platform.
fn formatWall(l: *Thread, buf: *std.ArrayList(u8), wall: i64, fmt: []const u8, info: tc.ZoneInfo) Error!void {
    const gpa = l.g.gpa;
    const tm = tc.breakDownWall(wall, info);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            buf.append(gpa, fmt[i]) catch return l.raiseMem();
            i += 1;
            continue;
        }
        const rest = fmt[i + 1 ..];
        if (rest[0] == 'Y') {
            const y = tm.year;
            if (y < 0) {
                buf.print(gpa, "-{d:0>4}", .{@abs(y)}) catch return l.raiseMem();
            } else {
                buf.print(gpa, "{d:0>4}", .{@as(u64, @intCast(y))}) catch return l.raiseMem();
            }
            i += 2;
        } else if (tc.matchConversion(rest)) |m| {
            tc.formatConv(gpa, buf, m.conv, &tm) catch return l.raiseMem();
            i += 1 + m.len;
        } else {
            // An unknown conversion is copied through unchanged.
            buf.appendSlice(gpa, fmt[i .. i + 2]) catch return l.raiseMem();
            i += 2;
        }
    }
}

fn retFormatted(l: *Thread, wall: i64, fmt: []const u8, info: tc.ZoneInfo, suffix: []const u8) Error!u32 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    try formatWall(l, &buf, wall, fmt, info);
    buf.appendSlice(l.g.gpa, suffix) catch return l.raiseMem();
    return aux.retStr(l, buf.items);
}

fn utcInfo() tc.ZoneInfo {
    return tc.utc_info;
}

/// Zone information for a zoned value: its own offset, with the
/// abbreviation of its zone when it has one.
fn zonedInfo(u: *Userdata) tc.ZoneInfo {
    const z = payload(Zoned, u);
    const zv = u.userValues()[0];
    if (!zv.isNil()) {
        const inf = zoneOf(zv).info(z.span.sec);
        if (inf.utoff == z.offset) return inf;
    }
    return .{ .utoff = z.offset, .isdst = false, .abbr = if (z.offset == 0) "UTC" else "" };
}

// ---------------------------------------------------------------------
// Instant methods and metamethods

fn instEpoch(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    try rejectMono(l, i);
    return aux.retInt(l, i.span.sec);
}

fn instNanos(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    return aux.retInt(l, i.span.nsec);
}

fn instFormat(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    const fmt = (try aux.optString(l, 2, iso_utc)).?;
    try rejectMono(l, i);
    return retFormatted(l, i.span.sec, fmt, utcInfo(), "");
}

fn instIso(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    try rejectMono(l, i);
    return retFormatted(l, i.span.sec, iso_utc, utcInfo(), "");
}

fn instAt(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    try rejectMono(l, i);
    l.top = l.base() + @min(l.argCount(), 2);
    const zv = l.arg(2);
    if (toUserdata(l, zv, .zone) != null) {
        const u = try pushZoned(l, i.span, zoneOf(zv).offsetAt(i.span.sec));
        u.userValues()[0] = zv;
    } else {
        const off = try fixedOffsetArg(l, try aux.checkInt(l, 2), 2);
        _ = try pushZoned(l, i.span, off);
    }
    return 1;
}

fn instAdd(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    const d = try checkDuration(l, 2);
    return pushInstant(l, try ok(l, Span, tc.spanAdd(i.span, d.*)), i.mono);
}

fn instSub(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    if (toUserdata(l, l.arg(2), .instant)) |u| {
        const j = payload(Instant, u);
        if (i.mono != j.mono) return l.raiseFmt("cannot subtract instants from different clocks", .{});
        return pushDuration(l, try ok(l, Span, tc.spanSub(i.span, j.span)));
    }
    const d = try checkDuration(l, 2);
    return pushInstant(l, try ok(l, Span, tc.spanSub(i.span, d.*)), i.mono);
}

fn instEq(l: *Thread) Error!u32 {
    const a = try checkInstant(l, 1);
    const b = try checkInstant(l, 2);
    return aux.retBool(l, std.meta.eql(a.span, b.span) and a.mono == b.mono);
}

fn instLt(l: *Thread) Error!u32 {
    const a = try checkInstant(l, 1);
    const b = try checkInstant(l, 2);
    return aux.retBool(l, tc.spanOrder(a.span, b.span) == .lt);
}

fn instLe(l: *Thread) Error!u32 {
    const a = try checkInstant(l, 1);
    const b = try checkInstant(l, 2);
    return aux.retBool(l, tc.spanOrder(a.span, b.span) != .gt);
}

fn instToString(l: *Thread) Error!u32 {
    const i = try checkInstant(l, 1);
    if (i.mono) {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "time.instant(monotonic {d} s + {d} ns)", .{ i.span.sec, i.span.nsec }) catch unreachable;
        return aux.retStr(l, s);
    }
    return retFormatted(l, i.span.sec, iso_utc, utcInfo(), "");
}

// ---------------------------------------------------------------------
// Duration methods and metamethods

fn durSeconds(l: *Thread) Error!u32 {
    const d = try checkDuration(l, 1);
    const f = @as(f64, @floatFromInt(d.sec)) + @as(f64, @floatFromInt(d.nsec)) / 1e9;
    return aux.ret(l, Value.float(f));
}

fn durMillis(l: *Thread) Error!u32 {
    const d = try checkDuration(l, 1);
    const f = @as(f64, @floatFromInt(d.sec)) * 1000.0 + @as(f64, @floatFromInt(d.nsec)) / 1e6;
    return aux.ret(l, Value.float(f));
}

fn durParts(l: *Thread) Error!u32 {
    const d = try checkDuration(l, 1);
    // The magnitude is broken into components and the sign reported apart.
    const neg = d.sec < 0;
    var s: u64 = @abs(d.sec);
    var nanos: u64 = @intCast(d.nsec);
    if (neg and nanos != 0) {
        s -= 1;
        nanos = @as(u64, @intCast(tc.nanos_per_sec)) - nanos;
    }
    const t = try l.newTable(0, 6);
    try l.push(Value.obj(.table, t));
    try aux.setField(l, t, "negative", Value.boolean(neg));
    try aux.setField(l, t, "days", Value.int(@intCast(s / 86400)));
    try aux.setField(l, t, "hours", Value.int(@intCast((s % 86400) / 3600)));
    try aux.setField(l, t, "minutes", Value.int(@intCast((s % 3600) / 60)));
    try aux.setField(l, t, "seconds", Value.int(@intCast(s % 60)));
    try aux.setField(l, t, "nanos", Value.int(@intCast(nanos)));
    return 1;
}

fn durAdd(l: *Thread) Error!u32 {
    const a = try checkDuration(l, 1);
    const b = try checkDuration(l, 2);
    return pushDuration(l, try ok(l, Span, tc.spanAdd(a.*, b.*)));
}

fn durSub(l: *Thread) Error!u32 {
    const a = try checkDuration(l, 1);
    const b = try checkDuration(l, 2);
    return pushDuration(l, try ok(l, Span, tc.spanSub(a.*, b.*)));
}

/// duration * integer, in either operand order.
fn durMul(l: *Thread) Error!u32 {
    var d: *Span = undefined;
    var k: i64 = undefined;
    if (toUserdata(l, l.arg(1), .duration) != null) {
        d = try checkDuration(l, 1);
        k = try aux.checkInt(l, 2);
    } else {
        k = try aux.checkInt(l, 1);
        d = try checkDuration(l, 2);
    }
    return pushDuration(l, try ok(l, Span, tc.spanMul(d.*, k)));
}

fn durUnm(l: *Thread) Error!u32 {
    const d = try checkDuration(l, 1);
    return pushDuration(l, try ok(l, Span, tc.spanMul(d.*, -1)));
}

fn durEq(l: *Thread) Error!u32 {
    return aux.retBool(l, tc.spanOrder((try checkDuration(l, 1)).*, (try checkDuration(l, 2)).*) == .eq);
}

fn durLt(l: *Thread) Error!u32 {
    return aux.retBool(l, tc.spanOrder((try checkDuration(l, 1)).*, (try checkDuration(l, 2)).*) == .lt);
}

fn durLe(l: *Thread) Error!u32 {
    return aux.retBool(l, tc.spanOrder((try checkDuration(l, 1)).*, (try checkDuration(l, 2)).*) != .gt);
}

fn durToString(l: *Thread) Error!u32 {
    const d = try checkDuration(l, 1);
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "time.duration({d} s + {d} ns)", .{ d.sec, d.nsec }) catch unreachable;
    return aux.retStr(l, s);
}

// ---------------------------------------------------------------------
// Zoned methods

fn zonedInstant(l: *Thread) Error!u32 {
    const z = try checkZoned(l, 1);
    return pushInstant(l, z.span, false);
}

fn zonedFormat(l: *Thread) Error!u32 {
    const u = try checkUserdata(l, 1, .zoned);
    const z = payload(Zoned, u);
    const fmt = (try aux.optString(l, 2, iso_local)).?;
    const wall = try ok(l, i64, tc.addChecked(z.span.sec, z.offset));
    return retFormatted(l, wall, fmt, zonedInfo(u), "");
}

fn zonedIso(l: *Thread) Error!u32 {
    const u = try checkUserdata(l, 1, .zoned);
    const z = payload(Zoned, u);
    const wall = try ok(l, i64, tc.addChecked(z.span.sec, z.offset));
    var suffix_buf: std.ArrayList(u8) = .empty;
    defer suffix_buf.deinit(l.g.gpa);
    if (z.offset == 0) {
        suffix_buf.append(l.g.gpa, 'Z') catch return l.raiseMem();
    } else {
        tc.formatOffset(l.g.gpa, &suffix_buf, z.offset, true) catch return l.raiseMem();
    }
    return retFormatted(l, wall, iso_local, zonedInfo(u), suffix_buf.items);
}

/// Replaces the named wall clock fields and re-resolves the result
/// through the zone, so replacing the hour across a daylight saving
/// boundary yields the right offset.
fn zonedWith(l: *Thread) Error!u32 {
    const u = try checkUserdata(l, 1, .zoned);
    const z = payload(Zoned, u);
    _ = try aux.checkTable(l, 2);
    l.top = l.base() + 2;
    const cur = try zonedFields(l, z);
    const wall = try civilFromTable(l, 2, cur, z.span.nsec);
    return rebuildZoned(l, u, wall.sec, wall.nsec);
}

/// Calendar arithmetic. Every component moves the wall clock, then the
/// result is re-resolved through the zone, so `:add{days = 1}` keeps the
/// wall time across a daylight saving change. Years and months apply
/// first, clamping the day to the length of the target month.
fn zonedAdd(l: *Thread) Error!u32 {
    const u = try checkUserdata(l, 1, .zoned);
    const z = payload(Zoned, u);
    _ = try aux.checkTable(l, 2);
    l.top = l.base() + 2;
    const f = try zonedFields(l, z);
    var y = try ok(l, i64, tc.addChecked(f.year, try field(l, 2, "years", 0)));
    const m0 = try ok(l, i64, tc.addChecked(f.month - 1, try field(l, 2, "months", 0)));
    y = try ok(l, i64, tc.addChecked(y, @divFloor(m0, 12)));
    const mo = @mod(m0, 12) + 1;
    const d = @min(f.day, tc.daysInMonth(y, mo));
    var day_count = try ok(l, i64, tc.daysFromCivilChecked(y, mo, d));
    const weeks = try ok(l, i64, tc.mulChecked(try field(l, 2, "weeks", 0), 7));
    day_count = try ok(l, i64, tc.addChecked(day_count, weeks));
    day_count = try ok(l, i64, tc.addChecked(day_count, try field(l, 2, "days", 0)));
    var sod: i64 = f.hour * 3600 + f.minute * 60 + f.second;
    sod = try ok(l, i64, tc.addChecked(sod, try ok(l, i64, tc.mulChecked(try field(l, 2, "hours", 0), 3600))));
    sod = try ok(l, i64, tc.addChecked(sod, try ok(l, i64, tc.mulChecked(try field(l, 2, "minutes", 0), 60))));
    sod = try ok(l, i64, tc.addChecked(sod, try field(l, 2, "seconds", 0)));
    const naive = try ok(l, i64, tc.addChecked(try ok(l, i64, tc.mulChecked(day_count, 86400)), sod));
    const nanos = try ok(l, Span, tc.unitDuration(try field(l, 2, "nanos", 0), 0, 1));
    const wall = try ok(l, Span, tc.spanAdd(.{ .sec = naive, .nsec = z.span.nsec }, nanos));
    return rebuildZoned(l, u, wall.sec, wall.nsec);
}

const zoned_fields = [_][]const u8{ "year", "month", "day", "hour", "minute", "second", "nanosecond", "weekday", "yearday", "offset" };

/// `__index` of zoned values: methods first, then the computed civil
/// fields.
fn zonedIndex(l: *Thread) Error!u32 {
    const z = try checkZoned(l, 1);
    const k = l.arg(2);
    if (k.tag != .string) return aux.retNil(l);
    const mt = metatableOf(l, .zoned);
    const methods = try aux.getField(l, mt, "__methods");
    if (methods.tag == .table) {
        const m = table.getStr(methods.as(Table), k.as(String));
        if (!m.isNil()) return aux.ret(l, m);
    }
    const name = k.as(String).bytes();
    const which = for (zoned_fields, 0..) |f, i| {
        if (std.mem.eql(u8, f, name)) break i;
    } else return aux.retNil(l);
    const wall = try ok(l, i64, tc.addChecked(z.span.sec, z.offset));
    const sd = tc.splitDays(wall);
    const c = tc.civilFromDays(sd.days);
    return switch (which) {
        0 => aux.retInt(l, c.year),
        1 => aux.retInt(l, c.month),
        2 => aux.retInt(l, c.day),
        3 => aux.retInt(l, @divTrunc(sd.secs, 3600)),
        4 => aux.retInt(l, @divTrunc(@mod(sd.secs, 3600), 60)),
        5 => aux.retInt(l, @mod(sd.secs, 60)),
        6 => aux.retInt(l, z.span.nsec),
        7 => blk: {
            const first = try aux.getField(l, l.g.registry.as(Table), weekday_key);
            const root = first.as(object.EnumValue).root;
            const member = try ext.enumMember(l, root, @intCast(tc.isoWeekday(sd.days) - 1));
            break :blk aux.ret(l, Value.obj(.enum_value, member));
        },
        8 => aux.retInt(l, sd.days - tc.daysFromCivil(c.year, 1, 1) + 1),
        9 => aux.retInt(l, z.offset),
        else => unreachable,
    };
}

fn zonedToString(l: *Thread) Error!u32 {
    return zonedIso(l);
}

// ---------------------------------------------------------------------
// Zone methods

fn zoneName(l: *Thread) Error!u32 {
    const u = try checkUserdata(l, 1, .zone);
    return aux.ret(l, u.userValues()[0]);
}

fn zoneOffset(l: *Thread) Error!u32 {
    const z = try checkZone(l, 1);
    const i = try checkInstant(l, 2);
    try rejectMono(l, i);
    return aux.retInt(l, z.offsetAt(i.span.sec));
}

// ---------------------------------------------------------------------
// Registration

const module_funcs = [_]aux.Reg{
    .{ .name = "now", .func = timeNow },
    .{ .name = "monotonic", .func = timeMonotonic },
    .{ .name = "instant", .func = timeInstant },
    .{ .name = "zoned", .func = timeZoned },
    .{ .name = "duration", .func = timeDuration },
    .{ .name = "parse", .func = timeParse },
    .{ .name = "zone", .func = timeZone },
    .{ .name = "offset", .func = timeOffset },
    .{ .name = "localzone", .func = timeLocalzone },
    .{ .name = "days", .func = timeDays },
    .{ .name = "hours", .func = timeHours },
    .{ .name = "minutes", .func = timeMinutes },
    .{ .name = "seconds", .func = timeSeconds },
    .{ .name = "millis", .func = timeMillis },
    .{ .name = "tzdata_version", .func = tzdataVersion },
};

const instant_methods = [_]aux.Reg{
    .{ .name = "epoch", .func = instEpoch },
    .{ .name = "nanos", .func = instNanos },
    .{ .name = "format", .func = instFormat },
    .{ .name = "iso", .func = instIso },
    .{ .name = "at", .func = instAt },
    .{ .name = "add", .func = instAdd },
};

const instant_meta = [_]aux.Reg{
    .{ .name = "__add", .func = instAdd },
    .{ .name = "__sub", .func = instSub },
    .{ .name = "__eq", .func = instEq },
    .{ .name = "__lt", .func = instLt },
    .{ .name = "__le", .func = instLe },
    .{ .name = "__tostring", .func = instToString },
};

const duration_methods = [_]aux.Reg{
    .{ .name = "seconds", .func = durSeconds },
    .{ .name = "millis", .func = durMillis },
    .{ .name = "parts", .func = durParts },
};

const duration_meta = [_]aux.Reg{
    .{ .name = "__add", .func = durAdd },
    .{ .name = "__sub", .func = durSub },
    .{ .name = "__mul", .func = durMul },
    .{ .name = "__unm", .func = durUnm },
    .{ .name = "__eq", .func = durEq },
    .{ .name = "__lt", .func = durLt },
    .{ .name = "__le", .func = durLe },
    .{ .name = "__tostring", .func = durToString },
};

const zoned_methods = [_]aux.Reg{
    .{ .name = "instant", .func = zonedInstant },
    .{ .name = "format", .func = zonedFormat },
    .{ .name = "iso", .func = zonedIso },
    .{ .name = "with", .func = zonedWith },
    .{ .name = "add", .func = zonedAdd },
};

const zoned_meta = [_]aux.Reg{
    .{ .name = "__index", .func = zonedIndex },
    .{ .name = "__tostring", .func = zonedToString },
};

const zone_methods = [_]aux.Reg{
    .{ .name = "name", .func = zoneName },
    .{ .name = "offset", .func = zoneOffset },
};

const zone_meta = [_]aux.Reg{
    .{ .name = "__tostring", .func = zoneName },
};

/// Creates the metatable of kind `k`, anchors it in the registry and
/// records it for type checks. Methods go in an `__index` table, or in
/// `__methods` when `__index` is a function.
fn makeMetatable(l: *Thread, k: Kind, methods: []const aux.Reg, meta: []const aux.Reg) Error!void {
    const mt = try l.newTable(0, meta.len + 4);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setFuncs(l, mt, meta);
    const m = try aux.newLib(l, methods);
    try l.push(Value.obj(.table, m));
    try aux.setField(l, mt, if (k == .zoned) "__methods" else "__index", Value.obj(.table, m));
    l.top -= 1;
    try aux.setField(l, mt, "__name", try l.newStringValue(k.key()));
    // Hide the metatable from getmetatable and setmetatable.
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), k.key(), Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, k.key(), mt) catch return l.raiseMem();
}

/// Builds a first-class enum from `names` and returns its first member.
fn makeEnum(l: *Thread, names: []const []const u8) Error!Value {
    const gpa = l.g.gpa;
    const top = l.top;
    defer l.top = top;
    for (names) |n| try l.push(try l.newStringValue(n));
    const strs = gpa.alloc(*String, names.len) catch return l.raiseMem();
    const vals = gpa.alloc(?*object.EnumValue, names.len) catch {
        gpa.free(strs);
        return l.raiseMem();
    };
    for (strs, 0..) |*s, i| s.* = l.stack[top + i].as(String);
    @memset(vals, null);
    const root = gc.alloc(l.g, object.EnumRoot, .enum_root, @sizeOf(object.EnumRoot)) catch {
        gpa.free(strs);
        gpa.free(vals);
        return l.raiseMem();
    };
    root.names = strs;
    root.values = vals;
    return Value.obj(.enum_value, try ext.enumMember(l, root, 0));
}

pub fn open(l: *Thread) Error!void {
    try makeMetatable(l, .instant, &instant_methods, &instant_meta);
    try makeMetatable(l, .duration, &duration_methods, &duration_meta);
    try makeMetatable(l, .zoned, &zoned_methods, &zoned_meta);
    try makeMetatable(l, .zone, &zone_methods, &zone_meta);
    const lib = try aux.newLib(l, &module_funcs);
    try l.push(Value.obj(.table, lib));
    defer l.top -= 1;
    // First-class weekday (ISO, Monday first) and month enums.
    const weekday = try makeEnum(l, &.{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" });
    try l.push(weekday);
    try aux.setField(l, l.g.registry.as(Table), weekday_key, weekday);
    try aux.setField(l, lib, "weekday", weekday);
    l.top -= 1;
    const month = try makeEnum(l, &.{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" });
    try l.push(month);
    try aux.setField(l, lib, "month", month);
    l.top -= 1;
    try aux.setGlobal(l, "time", Value.obj(.table, lib));
}
