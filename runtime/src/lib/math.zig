//! The math library. Integer and float results follow Lua 5.4. Bigints and
//! decimals (spec/design/numbers.md) keep their exactness where the result
//! is exact (abs, floor, ceil, modf, fmod, tointeger, min, max) and convert
//! to floats for the transcendental functions.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const numeric = @import("../vm/numeric.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const BigInt = numeric.BigInt;
const Decimal = numeric.Decimal;
const M = std.math.big.int.Managed;

pub const funcs = [_]aux.Reg{
    .{ .name = "abs", .func = abs },
    .{ .name = "acos", .func = acos },
    .{ .name = "asin", .func = asin },
    .{ .name = "atan", .func = atan },
    .{ .name = "ceil", .func = ceil },
    .{ .name = "cos", .func = cos },
    .{ .name = "deg", .func = deg },
    .{ .name = "exp", .func = exp },
    .{ .name = "tointeger", .func = tointeger },
    .{ .name = "floor", .func = floor },
    .{ .name = "fmod", .func = fmod },
    .{ .name = "frexp", .func = frexp },
    .{ .name = "ult", .func = ult },
    .{ .name = "ldexp", .func = ldexp },
    .{ .name = "log", .func = log },
    .{ .name = "max", .func = max },
    .{ .name = "min", .func = min },
    .{ .name = "modf", .func = modf },
    .{ .name = "rad", .func = rad },
    .{ .name = "sin", .func = sin },
    .{ .name = "sqrt", .func = sqrt },
    .{ .name = "tan", .func = tan },
    .{ .name = "type", .func = @"type" },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try l.push(Value.obj(.table, t));
    try aux.setField(l, t, "pi", Value.float(std.math.pi));
    try aux.setField(l, t, "huge", Value.float(std.math.inf(f64)));
    try aux.setField(l, t, "maxinteger", Value.int(std.math.maxInt(i64)));
    try aux.setField(l, t, "mininteger", Value.int(std.math.minInt(i64)));
    // The generator state is a table of four integers shared by `random`
    // and `randomseed` through an upvalue.
    const st = try l.newTable(4, 0);
    try l.push(Value.obj(.table, st));
    var s: [4]u64 = undefined;
    setSeed(&s, makeSeed(l), 0);
    try storeState(l, st, &s);
    inline for (.{ .{ "random", random }, .{ "randomseed", randomseed } }) |r| {
        const n = state.newNative(l.g, r[1], r[0], 1) catch return l.raiseMem();
        n.upvalues()[0] = Value.obj(.table, st);
        try aux.setField(l, t, r[0], Value.obj(.native, n));
    }
    l.top -= 2;
    try aux.setGlobal(l, "math", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Helpers

fn pushFloat(l: *Thread, f: f64) Error!u32 {
    return aux.ret(l, Value.float(f));
}

/// Pushes `d` as an integer when it fits, otherwise as a float.
fn pushNumInt(l: *Thread, d: f64) Error!u32 {
    if (ops.floatToInt(d)) |n| return aux.retInt(l, n);
    return pushFloat(l, d);
}

fn newBig(l: *Thread, c: std.math.big.int.Const) Error!Value {
    return Value.obj(.bigint, numeric.newBigFromConst(l.g, c) catch return l.raiseMem());
}

/// An integer value when `c` fits in 64 bits, otherwise a bigint.
fn intOrBig(l: *Thread, c: std.math.big.int.Const) Error!Value {
    if (c.toInt(i64)) |n| return Value.int(n) else |_| {}
    return newBig(l, c);
}

const Round = enum { floor, ceil, trunc };

/// Rounds a decimal to an integral value, returned as an integer when it
/// fits and as a bigint otherwise.
fn decRound(l: *Thread, d: *Decimal, mode: Round) Error!Value {
    const gpa = l.g.gpa;
    var c = d.coef().toManaged(gpa) catch return l.raiseMem();
    defer c.deinit();
    if (d.exponent >= 0) {
        var p = pow10(gpa, @intCast(d.exponent)) catch return l.raiseMem();
        defer p.deinit();
        c.mul(&c, &p) catch return l.raiseMem();
        return intOrBig(l, c.toConst());
    }
    var p = pow10(gpa, @intCast(-@as(i64, d.exponent))) catch return l.raiseMem();
    defer p.deinit();
    var q = M.init(gpa) catch return l.raiseMem();
    defer q.deinit();
    var r = M.init(gpa) catch return l.raiseMem();
    defer r.deinit();
    switch (mode) {
        .floor => M.divFloor(&q, &r, &c, &p) catch return l.raiseMem(),
        .trunc => M.divTrunc(&q, &r, &c, &p) catch return l.raiseMem(),
        .ceil => {
            c.negate();
            M.divFloor(&q, &r, &c, &p) catch return l.raiseMem();
            q.negate();
        },
    }
    return intOrBig(l, q.toConst());
}

fn pow10(gpa: std.mem.Allocator, n: u32) !M {
    var m = try M.initSet(gpa, 10);
    errdefer m.deinit();
    try m.pow(&m, n);
    return m;
}

/// Converts an integral value (integer or bigint) to a decimal with
/// exponent zero.
fn toDecimal(l: *Thread, v: Value) Error!Value {
    var buf: [2]std.math.big.Limb = undefined;
    const c = switch (v.tag) {
        .integer => std.math.big.int.Mutable.init(&buf, v.asInt()).toConst(),
        .bigint => v.as(BigInt).toConst(),
        else => unreachable,
    };
    return Value.obj(.decimal, numeric.newDecFromConst(l.g, c, 0) catch return l.raiseMem());
}

// ---------------------------------------------------------------------
// Rounding and absolute value

fn abs(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .integer => {
            const n = v.asInt();
            return aux.retInt(l, if (n < 0) 0 -% n else n);
        },
        .bigint => {
            const b = v.as(BigInt);
            if (b.positive) return aux.ret(l, v);
            var c = b.toConst();
            c.positive = true;
            return aux.ret(l, try newBig(l, c));
        },
        .decimal => {
            const d = v.as(Decimal);
            if (d.positive) return aux.ret(l, v);
            var c = d.coef();
            c.positive = true;
            return aux.ret(l, Value.obj(.decimal, numeric.newDecFromConst(l.g, c, d.exponent) catch return l.raiseMem()));
        },
        else => return pushFloat(l, @abs(try aux.checkFloat(l, 1))),
    }
}

fn floor(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .integer, .bigint => return aux.ret(l, v),
        .decimal => return aux.ret(l, try decRound(l, v.as(Decimal), .floor)),
        else => return pushNumInt(l, @floor(try aux.checkFloat(l, 1))),
    }
}

fn ceil(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .integer, .bigint => return aux.ret(l, v),
        .decimal => return aux.ret(l, try decRound(l, v.as(Decimal), .ceil)),
        else => return pushNumInt(l, @ceil(try aux.checkFloat(l, 1))),
    }
}

fn modf(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .integer, .bigint => {
            try l.push(v);
            try l.push(Value.float(0));
            return 2;
        },
        .decimal => {
            const ip = try decRound(l, v.as(Decimal), .trunc);
            try l.push(ip);
            const ipd = try toDecimal(l, ip);
            l.stack[l.top - 1] = ipd;
            try l.push(try ops.arith(l, .sub, v, ipd));
            return 2;
        },
        else => {
            const n = try aux.checkFloat(l, 1);
            const ip = if (n < 0) @ceil(n) else @floor(n);
            _ = try pushNumInt(l, ip);
            try l.push(Value.float(if (n == ip) 0.0 else n - ip));
            return 2;
        },
    }
}

fn fmod(l: *Thread) Error!u32 {
    const a = l.arg(1);
    const b = l.arg(2);
    if (a.tag == .integer and b.tag == .integer) {
        const d = b.asInt();
        if (@as(u64, @bitCast(d)) +% 1 <= 1) { // special cases: -1 or 0
            if (d == 0) return aux.argError(l, 2, "zero", .{});
            return aux.retInt(l, 0); // avoids overflow with minint / -1
        }
        return aux.retInt(l, @rem(a.asInt(), d));
    }
    const exact = struct {
        fn is(v: Value) bool {
            return v.tag == .integer or v.tag == .bigint or v.tag == .decimal;
        }
    }.is;
    if (exact(a) and exact(b) and (a.tag != .integer or b.tag != .integer)) {
        // Truncated remainder from the floored one: r = a % b, then move
        // r toward zero when its sign differs from the dividend.
        if (numeric.compare(l.g.gpa, b, Value.int(0)) == .eq) return aux.argError(l, 2, "zero", .{});
        var r = try ops.arith(l, .mod, a, b);
        try l.push(r);
        const zero = Value.int(0);
        const r_sign = numeric.compare(l.g.gpa, r, zero) orelse .eq;
        const a_sign = numeric.compare(l.g.gpa, a, zero) orelse .eq;
        if (r_sign != .eq and r_sign != a_sign) r = try ops.arith(l, .sub, r, b);
        l.top -= 1;
        return aux.ret(l, r);
    }
    const x = try aux.checkFloat(l, 1);
    const y = try aux.checkFloat(l, 2);
    return pushFloat(l, @rem(x, y));
}

// ---------------------------------------------------------------------
// Floating point functions

fn sqrt(l: *Thread) Error!u32 {
    return pushFloat(l, @sqrt(try aux.checkFloat(l, 1)));
}

fn sin(l: *Thread) Error!u32 {
    return pushFloat(l, @sin(try aux.checkFloat(l, 1)));
}

fn cos(l: *Thread) Error!u32 {
    return pushFloat(l, @cos(try aux.checkFloat(l, 1)));
}

fn tan(l: *Thread) Error!u32 {
    return pushFloat(l, @tan(try aux.checkFloat(l, 1)));
}

fn asin(l: *Thread) Error!u32 {
    return pushFloat(l, std.math.asin(try aux.checkFloat(l, 1)));
}

fn acos(l: *Thread) Error!u32 {
    return pushFloat(l, std.math.acos(try aux.checkFloat(l, 1)));
}

fn atan(l: *Thread) Error!u32 {
    const y = try aux.checkFloat(l, 1);
    const x = if (l.arg(2).isNil()) 1.0 else try aux.checkFloat(l, 2);
    return pushFloat(l, std.math.atan2(y, x));
}

fn exp(l: *Thread) Error!u32 {
    return pushFloat(l, @exp(try aux.checkFloat(l, 1)));
}

fn log(l: *Thread) Error!u32 {
    const x = try aux.checkFloat(l, 1);
    if (l.arg(2).isNil()) return pushFloat(l, @log(x));
    const base = try aux.checkFloat(l, 2);
    if (base == 2.0) return pushFloat(l, @log2(x));
    if (base == 10.0) return pushFloat(l, @log10(x));
    return pushFloat(l, @log(x) / @log(base));
}

fn deg(l: *Thread) Error!u32 {
    return pushFloat(l, (try aux.checkFloat(l, 1)) * (180.0 / std.math.pi));
}

fn rad(l: *Thread) Error!u32 {
    return pushFloat(l, (try aux.checkFloat(l, 1)) * (std.math.pi / 180.0));
}

fn frexp(l: *Thread) Error!u32 {
    const x = try aux.checkFloat(l, 1);
    const r = std.math.frexp(x);
    try l.push(Value.float(r.significand));
    try l.push(Value.int(r.exponent));
    return 2;
}

fn ldexp(l: *Thread) Error!u32 {
    const x = try aux.checkFloat(l, 1);
    const e: i32 = @truncate(try aux.checkInt(l, 2));
    return pushFloat(l, std.math.ldexp(x, e));
}

// ---------------------------------------------------------------------
// Integers and types

fn tointeger(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .integer => return aux.ret(l, v),
        .float, .bigint => if (ops.toIntegerStrict(v)) |n| return aux.retInt(l, n),
        .decimal => {
            if (numeric.decIntegral(l.g.gpa, v.as(Decimal)) catch return l.raiseMem()) |m| {
                var mm = m;
                defer mm.deinit();
                if (mm.toConst().toInt(i64)) |n| return aux.retInt(l, n) else |_| {}
            }
        },
        .string => if (ops.toNumberCoerce(v)) |n| {
            if (ops.toIntegerStrict(n)) |i| return aux.retInt(l, i);
        },
        else => _ = try aux.checkAny(l, 1),
    }
    return aux.retNil(l);
}

fn @"type"(l: *Thread) Error!u32 {
    const v = l.arg(1);
    return switch (v.tag) {
        .integer => aux.retStr(l, "integer"),
        .float => aux.retStr(l, "float"),
        .bigint => aux.retStr(l, "bigint"),
        .decimal => aux.retStr(l, "decimal"),
        else => {
            _ = try aux.checkAny(l, 1);
            return aux.retNil(l);
        },
    };
}

fn ult(l: *Thread) Error!u32 {
    const a = try aux.checkInt(l, 1);
    const b = try aux.checkInt(l, 2);
    return aux.retBool(l, @as(u64, @bitCast(a)) < @as(u64, @bitCast(b)));
}

fn min(l: *Thread) Error!u32 {
    const n = l.argCount();
    if (n < 1) return aux.argError(l, 1, "value expected", .{});
    var imin: u32 = 1;
    var i: u32 = 2;
    while (i <= n) : (i += 1) {
        if (try ops.lessThan(l, l.arg(i), l.arg(imin))) imin = i;
    }
    return aux.ret(l, l.arg(imin));
}

fn max(l: *Thread) Error!u32 {
    const n = l.argCount();
    if (n < 1) return aux.argError(l, 1, "value expected", .{});
    var imax: u32 = 1;
    var i: u32 = 2;
    while (i <= n) : (i += 1) {
        if (try ops.lessThan(l, l.arg(imax), l.arg(i))) imax = i;
    }
    return aux.ret(l, l.arg(imax));
}

// ---------------------------------------------------------------------
// Pseudo-random numbers: xoshiro256**, as in Lua 5.4.

fn rotl(x: u64, n: u6) u64 {
    return std.math.rotl(u64, x, n);
}

fn nextRand(s: *[4]u64) u64 {
    const s0 = s[0];
    const s1 = s[1];
    const s2 = s[2] ^ s0;
    const s3 = s[3] ^ s1;
    const res = rotl(s1 *% 5, 7) *% 9;
    s[0] = s0 ^ s3;
    s[1] = s1 ^ s2;
    s[2] = s2 ^ (s1 << 17);
    s[3] = rotl(s3, 45);
    return res;
}

/// The top 53 bits of `x` as a float in [0, 1).
fn toUnitFloat(x: u64) f64 {
    return @as(f64, @floatFromInt(x >> 11)) * 0x1.0p-53;
}

/// Projects `ran` into [0, n] uniformly, drawing again when the masked
/// value falls outside the interval.
fn project(ran_in: u64, n: u64, s: *[4]u64) u64 {
    var lim = n;
    var sh: u7 = 1;
    while (lim & (lim +% 1) != 0) : (sh *= 2) lim |= lim >> @intCast(sh);
    var ran = ran_in;
    while (true) {
        ran &= lim;
        if (ran <= n) return ran;
        ran = nextRand(s);
    }
}

fn setSeed(s: *[4]u64, n1: u64, n2: u64) void {
    s.* = .{ n1, 0xff, n2, 0 };
    var i: u32 = 0;
    while (i < 16) : (i += 1) _ = nextRand(s);
}

fn makeSeed(l: *Thread) u64 {
    const ns = std.Io.Clock.real.now(l.g.io).nanoseconds;
    const t: u64 = @truncate(@as(u96, @bitCast(ns)));
    return t ^ (@as(u64, @intFromPtr(l)) *% 0x9E3779B97F4A7C15) ^ l.g.seed;
}

fn stateTable(l: *Thread) *Table {
    return l.frame().native.?.upvalues()[0].as(Table);
}

fn loadState(t: *Table) [4]u64 {
    var s: [4]u64 = undefined;
    for (&s, 1..) |*x, i| x.* = @bitCast(table.getInt(t, @intCast(i)).asInt());
    return s;
}

fn storeState(l: *Thread, t: *Table, s: *const [4]u64) Error!void {
    for (s, 1..) |x, i| try ops.rawSet(l, t, Value.int(@intCast(i)), Value.int(@bitCast(x)));
}

fn random(l: *Thread) Error!u32 {
    const st = stateTable(l);
    var s = loadState(st);
    const rv = nextRand(&s);
    var low: i64 = undefined;
    var up: i64 = undefined;
    switch (l.argCount()) {
        0 => {
            try storeState(l, st, &s);
            return pushFloat(l, toUnitFloat(rv));
        },
        1 => {
            low = 1;
            up = try aux.checkInt(l, 1);
            if (up == 0) {
                try storeState(l, st, &s);
                return aux.retInt(l, @bitCast(rv));
            }
        },
        2 => {
            low = try aux.checkInt(l, 1);
            up = try aux.checkInt(l, 2);
        },
        else => return l.raiseFmt("wrong number of arguments", .{}),
    }
    if (low > up) return aux.argError(l, 1, "interval is empty", .{});
    const p = project(rv, @as(u64, @bitCast(up)) -% @as(u64, @bitCast(low)), &s);
    try storeState(l, st, &s);
    return aux.retInt(l, @bitCast(p +% @as(u64, @bitCast(low))));
}

fn randomseed(l: *Thread) Error!u32 {
    const st = stateTable(l);
    var s = loadState(st);
    var n1: u64 = undefined;
    var n2: u64 = undefined;
    if (!l.hasArg(1)) {
        n1 = makeSeed(l);
        n2 = nextRand(&s);
    } else {
        n1 = @bitCast(try aux.checkInt(l, 1));
        n2 = @bitCast(try aux.optInt(l, 2, 0));
    }
    setSeed(&s, n1, n2);
    try storeState(l, st, &s);
    try l.push(Value.int(@bitCast(n1)));
    try l.push(Value.int(@bitCast(n2)));
    return 2;
}
