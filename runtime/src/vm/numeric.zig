//! Bigint and decimal numbers (spec/design/numbers.md). Both are immutable
//! heap objects with inline limbs. A decimal is `coefficient * 10^exponent`
//! with the coefficient kept exactly as computed, so `1.50d` keeps its
//! trailing zero.

const std = @import("std");
const value = @import("value.zig");
const gc = @import("gc.zig");
const state = @import("state.zig");
const big = std.math.big.int;
const Value = value.Value;
const Limb = std.math.big.Limb;
const Global = state.Global;
const Thread = state.Thread;
const Allocator = std.mem.Allocator;

pub const BigInt = struct {
    hdr: gc.Header,
    positive: bool,
    len: u32,

    pub fn limbs(b: *const BigInt) []const Limb {
        const base: [*]const u8 = @ptrCast(b);
        const p: [*]const Limb = @ptrCast(@alignCast(base + @sizeOf(BigInt)));
        return p[0..b.len];
    }
    fn limbsMut(b: *BigInt) []Limb {
        const base: [*]u8 = @ptrCast(b);
        const p: [*]Limb = @ptrCast(@alignCast(base + @sizeOf(BigInt)));
        return p[0..b.len];
    }
    pub fn toConst(b: *const BigInt) big.Const {
        return .{ .limbs = b.limbs(), .positive = b.positive };
    }
    pub fn allocSize(n: usize) usize {
        return @sizeOf(BigInt) + n * @sizeOf(Limb);
    }
    pub fn allocSizeOf(h: *gc.Header) usize {
        return allocSize(h.as(BigInt).len);
    }
    pub fn freeExtra(g: *Global, h: *gc.Header) void {
        _ = g;
        _ = h;
    }
};

pub const Decimal = struct {
    hdr: gc.Header,
    exponent: i32,
    positive: bool,
    len: u32,

    pub fn limbs(d: *const Decimal) []const Limb {
        const base: [*]const u8 = @ptrCast(d);
        const p: [*]const Limb = @ptrCast(@alignCast(base + @sizeOf(Decimal)));
        return p[0..d.len];
    }
    fn limbsMut(d: *Decimal) []Limb {
        const base: [*]u8 = @ptrCast(d);
        const p: [*]Limb = @ptrCast(@alignCast(base + @sizeOf(Decimal)));
        return p[0..d.len];
    }
    pub fn coef(d: *const Decimal) big.Const {
        return .{ .limbs = d.limbs(), .positive = d.positive };
    }
    pub fn allocSize(n: usize) usize {
        return @sizeOf(Decimal) + n * @sizeOf(Limb);
    }
    pub fn allocSizeOf(h: *gc.Header) usize {
        return allocSize(h.as(Decimal).len);
    }
    pub fn freeExtra(g: *Global, h: *gc.Header) void {
        _ = g;
        _ = h;
    }
};

comptime {
    std.debug.assert(@sizeOf(BigInt) % @alignOf(Limb) == 0);
    std.debug.assert(@sizeOf(Decimal) % @alignOf(Limb) == 0);
}

pub const Error = state.Error;
const M = big.Managed;

// ---------------------------------------------------------------------
// Construction

pub fn newBigFromConst(g: *Global, c: big.Const) Allocator.Error!*BigInt {
    gc.maybeCollect(g);
    const n = @max(c.limbs.len, 1);
    const b = try gc.alloc(g, BigInt, .bigint, BigInt.allocSize(n));
    b.len = @intCast(n);
    b.positive = c.positive or c.eqlZero();
    if (c.limbs.len == 0) b.limbsMut()[0] = 0 else @memcpy(b.limbsMut(), c.limbs);
    return b;
}

pub fn newDecFromConst(g: *Global, c: big.Const, exponent: i32) Allocator.Error!*Decimal {
    gc.maybeCollect(g);
    const n = @max(c.limbs.len, 1);
    const d = try gc.alloc(g, Decimal, .decimal, Decimal.allocSize(n));
    d.len = @intCast(n);
    d.positive = c.positive or c.eqlZero();
    d.exponent = exponent;
    if (c.limbs.len == 0) d.limbsMut()[0] = 0 else @memcpy(d.limbsMut(), c.limbs);
    return d;
}

/// Parses the digits of a bigint literal (decimal or `0x` hexadecimal).
pub fn parseBigLiteral(g: *Global, digits: []const u8) !*BigInt {
    var m = try M.init(g.gpa);
    defer m.deinit();
    var neg = false;
    var s = digits;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        try m.setString(16, s[2..]);
    } else {
        try m.setString(10, s);
    }
    if (neg) m.negate();
    return newBigFromConst(g, m.toConst());
}

/// Parses decimal text such as "1.50", "3", "1e-2", "-0.5E+3".
pub fn parseDecimalLiteral(g: *Global, text: []const u8) !*Decimal {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(g.gpa);
    var exp: i64 = 0;
    var i: usize = 0;
    var neg = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        neg = text[i] == '-';
        i += 1;
    }
    var any = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        try digits.append(g.gpa, text[i]);
        any = true;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            try digits.append(g.gpa, text[i]);
            exp -= 1;
            any = true;
        }
    }
    if (!any) return error.InvalidCharacter;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        const e = std.fmt.parseInt(i64, text[i..], 10) catch return error.InvalidCharacter;
        exp += e;
        i = text.len;
    }
    if (i != text.len) return error.InvalidCharacter;
    if (exp > std.math.maxInt(i32) or exp < std.math.minInt(i32)) return error.Overflow;
    var m = try M.init(g.gpa);
    defer m.deinit();
    try m.setString(10, digits.items);
    if (neg) m.negate();
    return newDecFromConst(g, m.toConst(), @intCast(exp));
}

pub fn bigFromInt(g: *Global, v: i64) Allocator.Error!*BigInt {
    var buf: [2]Limb = undefined;
    const mut = big.Mutable.init(&buf, v);
    return newBigFromConst(g, mut.toConst());
}

// ---------------------------------------------------------------------
// Conversions

pub fn bigToFloat(b: *const BigInt) f64 {
    return b.toConst().toFloat(f64, .nearest_even)[0];
}

pub fn decToFloat(gpa: Allocator, d: *const Decimal) f64 {
    // Format and reparse: exact correctly-rounded conversion.
    const s = decimalToString(gpa, d) catch return std.math.nan(f64);
    defer gpa.free(s);
    return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
}

/// Returns the integer value when `b` fits in 64 bits.
pub fn bigToInt(b: *const BigInt) ?i64 {
    return b.toConst().toInt(i64) catch null;
}

/// When the decimal has an integral value, returns it as a bigint const in
/// a managed buffer owned by the caller.
pub fn decIntegral(gpa: Allocator, d: *const Decimal) !?M {
    var m = try d.coef().toManaged(gpa);
    errdefer m.deinit();
    if (d.exponent >= 0) {
        try mulPow10(&m, @intCast(d.exponent));
        return m;
    }
    var q = try M.init(gpa);
    defer q.deinit();
    var r = try M.init(gpa);
    defer r.deinit();
    var p = try pow10(gpa, @intCast(-d.exponent));
    defer p.deinit();
    try M.divTrunc(&q, &r, &m, &p);
    if (!r.eqlZero()) {
        m.deinit();
        return null;
    }
    try m.copy(q.toConst());
    return m;
}

fn pow10(gpa: Allocator, n: u32) !M {
    var m = try M.initSet(gpa, 1);
    errdefer m.deinit();
    try mulPow10(&m, n);
    return m;
}

fn mulPow10(m: *M, n: u32) !void {
    if (n == 0) return;
    var p = try M.initSet(m.allocator, 10);
    defer p.deinit();
    try p.pow(&p, n);
    try m.mul(m, &p);
}

pub fn bigToString(gpa: Allocator, b: *const BigInt) ![]u8 {
    var m = try b.toConst().toManaged(gpa);
    defer m.deinit();
    return m.toString(gpa, 10, .lower);
}

pub fn decimalToString(gpa: Allocator, d: *const Decimal) ![]u8 {
    var m = try d.coef().toManaged(gpa);
    defer m.deinit();
    m.abs();
    const digits = try m.toString(gpa, 10, .lower);
    defer gpa.free(digits);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (!d.positive and !d.coef().eqlZero()) try out.append(gpa, '-');
    const e = d.exponent;
    if (e >= 0) {
        if (e > 20) {
            try out.print(gpa, "{s}e+{d}", .{ digits, e });
        } else {
            try out.appendSlice(gpa, digits);
            try out.appendNTimes(gpa, '0', @intCast(e));
        }
    } else {
        const frac: usize = @intCast(-e);
        if (frac > 40 and frac > digits.len + 20) {
            try out.print(gpa, "{s}e{d}", .{ digits, e });
        } else if (digits.len > frac) {
            try out.appendSlice(gpa, digits[0 .. digits.len - frac]);
            try out.append(gpa, '.');
            try out.appendSlice(gpa, digits[digits.len - frac ..]);
        } else {
            try out.appendSlice(gpa, "0.");
            try out.appendNTimes(gpa, '0', frac - digits.len);
            try out.appendSlice(gpa, digits);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------
// Arithmetic dispatch

pub const ArithOp = enum { add, sub, mul, div, mod, idiv, pow, unm, band, bor, bxor, shl, shr, bnot };

const Kind = enum { int, float, big, dec };

fn kindOf(v: Value) ?Kind {
    return switch (v.tag) {
        .integer => .int,
        .float => .float,
        .bigint => .big,
        .decimal => .dec,
        else => null,
    };
}

/// Generic arithmetic for operands where at least one side is a bigint or
/// decimal. Both operands are already numbers (string coercion happened in
/// the caller). Returns null when the operation does not apply, so the
/// caller can try metamethods.
pub fn arith(l: *Thread, op: ArithOp, a: Value, b: Value) Error!?Value {
    const ka = kindOf(a) orelse return null;
    const kb = kindOf(b) orelse return null;
    const g = l.g;
    const gpa = g.gpa;
    // Bitwise operations: integers and bigints only.
    switch (op) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            if ((ka != .int and ka != .big) or (kb != .int and kb != .big)) return null;
            var ma = toManagedInt(gpa, a) catch return l.raiseMem();
            defer ma.deinit();
            var mb = toManagedInt(gpa, b) catch return l.raiseMem();
            defer mb.deinit();
            var r = M.init(gpa) catch return l.raiseMem();
            defer r.deinit();
            (switch (op) {
                .band => r.bitAnd(&ma, &mb),
                .bor => r.bitOr(&ma, &mb),
                .bxor => r.bitXor(&ma, &mb),
                .bnot => blk: {
                    // ~x == -x - 1
                    var one = M.initSet(gpa, 1) catch return l.raiseMem();
                    defer one.deinit();
                    r.copy(ma.toConst()) catch return l.raiseMem();
                    r.negate();
                    break :blk r.sub(&r, &one);
                },
                .shl, .shr => blk: {
                    const n = mb.toConst().toInt(i64) catch return l.raiseFmt("shift amount too large", .{});
                    const left = (op == .shl) == (n >= 0);
                    const amt: usize = @intCast(@min(@abs(n), 1 << 24));
                    break :blk if (left) r.shiftLeft(&ma, amt) else r.shiftRight(&ma, amt);
                },
                else => unreachable,
            }) catch return l.raiseMem();
            return Value.obj(.bigint, newBigFromConst(g, r.toConst()) catch return l.raiseMem());
        },
        else => {},
    }
    // Result kind table (spec/design/numbers.md).
    const has_dec = ka == .dec or kb == .dec;
    const has_float = ka == .float or kb == .float;
    if (has_dec and has_float) return l.raiseFmt("attempt to mix decimal and float in arithmetic", .{});
    if (has_float) {
        const fa = toFloat(gpa, a);
        const fb = toFloat(gpa, b);
        return Value.float(floatArith(op, fa, fb));
    }
    if (has_dec) return decArith(l, op, a, b);
    // Integers and bigints.
    if (op == .div) return Value.float(floatArith(.div, toFloat(gpa, a), toFloat(gpa, b)));
    return bigArith(l, op, a, b);
}

pub fn toFloat(gpa: Allocator, v: Value) f64 {
    return switch (v.tag) {
        .integer => @floatFromInt(v.asInt()),
        .float => v.asFloat(),
        .bigint => bigToFloat(v.as(BigInt)),
        .decimal => decToFloat(gpa, v.as(Decimal)),
        else => std.math.nan(f64),
    };
}

fn floatArith(op: ArithOp, a: f64, b: f64) f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .pow => std.math.pow(f64, a, b),
        .unm => -a,
        .idiv => @floor(a / b),
        .mod => fmod(a, b),
        else => std.math.nan(f64),
    };
}

pub fn fmod(a: f64, b: f64) f64 {
    if (std.math.isInf(b) and std.math.isFinite(a)) {
        if ((a >= 0) == (b > 0) or a == 0) return a;
        return b;
    }
    const m = @rem(a, b);
    if (m != 0 and (m < 0) != (b < 0)) return m + b;
    return m;
}

fn toManagedInt(gpa: Allocator, v: Value) !M {
    return switch (v.tag) {
        .integer => M.initSet(gpa, v.asInt()),
        .bigint => v.as(BigInt).toConst().toManaged(gpa),
        else => unreachable,
    };
}

fn bigArith(l: *Thread, op: ArithOp, a: Value, b: Value) Error!?Value {
    const g = l.g;
    const gpa = g.gpa;
    var ma = toManagedInt(gpa, a) catch return l.raiseMem();
    defer ma.deinit();
    var mb = toManagedInt(gpa, b) catch return l.raiseMem();
    defer mb.deinit();
    var r = M.init(gpa) catch return l.raiseMem();
    defer r.deinit();
    var rem = M.init(gpa) catch return l.raiseMem();
    defer rem.deinit();
    switch (op) {
        .add => r.add(&ma, &mb) catch return l.raiseMem(),
        .sub => r.sub(&ma, &mb) catch return l.raiseMem(),
        .mul => r.mul(&ma, &mb) catch return l.raiseMem(),
        .unm => {
            r.copy(ma.toConst()) catch return l.raiseMem();
            r.negate();
        },
        .idiv, .mod => {
            if (mb.eqlZero()) return l.raiseFmt("attempt to perform 'n{s}0'", .{if (op == .idiv) "//" else "%%"});
            M.divFloor(&r, &rem, &ma, &mb) catch return l.raiseMem();
            if (op == .mod) r.swap(&rem);
        },
        .pow => {
            if (!mb.isPositive() and !mb.eqlZero()) return Value.float(floatArith(.pow, toFloat(gpa, a), toFloat(gpa, b)));
            const e = mb.toConst().toInt(u32) catch return l.raiseFmt("exponent too large", .{});
            r.pow(&ma, e) catch return l.raiseMem();
        },
        else => return null,
    }
    return Value.obj(.bigint, newBigFromConst(g, r.toConst()) catch return l.raiseMem());
}

/// Converts an integer, bigint, or decimal to (coefficient, exponent).
fn toDecParts(gpa: Allocator, v: Value) !struct { M, i32 } {
    return switch (v.tag) {
        .integer => .{ try M.initSet(gpa, v.asInt()), 0 },
        .bigint => .{ try v.as(BigInt).toConst().toManaged(gpa), 0 },
        .decimal => .{ try v.as(Decimal).coef().toManaged(gpa), v.as(Decimal).exponent },
        else => unreachable,
    };
}

const div_precision = 34;

fn decArith(l: *Thread, op: ArithOp, a: Value, b: Value) Error!?Value {
    const g = l.g;
    const gpa = g.gpa;
    var pa = toDecParts(gpa, a) catch return l.raiseMem();
    defer pa[0].deinit();
    var pb = toDecParts(gpa, b) catch return l.raiseMem();
    defer pb[0].deinit();
    var r = M.init(gpa) catch return l.raiseMem();
    defer r.deinit();
    var exp: i32 = 0;
    switch (op) {
        .add, .sub, .mod, .idiv => {
            // Align exponents to the smaller one.
            const e = @min(pa[1], pb[1]);
            mulPow10(&pa[0], @intCast(pa[1] - e)) catch return l.raiseMem();
            mulPow10(&pb[0], @intCast(pb[1] - e)) catch return l.raiseMem();
            exp = e;
            switch (op) {
                .add => r.add(&pa[0], &pb[0]) catch return l.raiseMem(),
                .sub => r.sub(&pa[0], &pb[0]) catch return l.raiseMem(),
                .mod, .idiv => {
                    if (pb[0].eqlZero()) return l.raiseFmt("attempt to perform 'n{s}0'", .{if (op == .idiv) "//" else "%%"});
                    var rem = M.init(gpa) catch return l.raiseMem();
                    defer rem.deinit();
                    M.divFloor(&r, &rem, &pa[0], &pb[0]) catch return l.raiseMem();
                    if (op == .mod) r.swap(&rem) else exp = 0;
                },
                else => unreachable,
            }
        },
        .mul => {
            r.mul(&pa[0], &pb[0]) catch return l.raiseMem();
            exp = pa[1] + pb[1];
        },
        .unm => {
            r.copy(pa[0].toConst()) catch return l.raiseMem();
            r.negate();
            exp = pa[1];
        },
        .div => {
            if (pb[0].eqlZero()) return l.raiseFmt("attempt to divide a decimal by zero", .{});
            divDecimal(gpa, &r, &exp, &pa[0], pa[1], &pb[0], pb[1]) catch return l.raiseMem();
        },
        .pow => {
            // Exact for non-negative integral exponents, context division
            // for negative ones, float otherwise.
            if (pb[1] != 0 or b.tag == .decimal and pb[1] < 0) {
                return l.raiseFmt("decimal exponent must be an integer", .{});
            }
            const n = pb[0].toConst().toInt(i32) catch return l.raiseFmt("exponent too large", .{});
            r.pow(&pa[0], @abs(n)) catch return l.raiseMem();
            exp = pa[1] * @as(i32, @intCast(@abs(n)));
            if (n < 0) {
                var one = M.initSet(gpa, 1) catch return l.raiseMem();
                defer one.deinit();
                var q = M.init(gpa) catch return l.raiseMem();
                defer q.deinit();
                var qe: i32 = 0;
                divDecimal(gpa, &q, &qe, &one, 0, &r, exp) catch return l.raiseMem();
                r.swap(&q);
                exp = qe;
            }
        },
        else => return null,
    }
    return Value.obj(.decimal, newDecFromConst(g, r.toConst(), exp) catch return l.raiseMem());
}

fn digitCount(gpa: Allocator, m: *const M) !usize {
    if (m.eqlZero()) return 1;
    const s = try m.toString(gpa, 10, .lower);
    defer gpa.free(s);
    return if (s[0] == '-') s.len - 1 else s.len;
}

/// Decimal division rounded half to even to `div_precision` significant
/// digits, with trailing zeros removed down to the ideal exponent.
fn divDecimal(gpa: Allocator, q: *M, exp: *i32, ca: *M, ea: i32, cb: *M, eb: i32) !void {
    const da = try digitCount(gpa, ca);
    const db = try digitCount(gpa, cb);
    const shift: u32 = @intCast(@max(0, @as(i64, div_precision) + @as(i64, @intCast(db)) - @as(i64, @intCast(da)) + 1));
    var num = try ca.clone();
    defer num.deinit();
    try mulPow10(&num, shift);
    var rem = try M.init(gpa);
    defer rem.deinit();
    try M.divTrunc(q, &rem, &num, cb);
    var e: i32 = ea - eb - @as(i32, @intCast(shift));
    // Round to div_precision digits.
    var dq = try digitCount(gpa, q);
    var sticky = !rem.eqlZero();
    while (dq > div_precision) {
        var ten = try M.initSet(gpa, 10);
        defer ten.deinit();
        var r = try M.init(gpa);
        defer r.deinit();
        var nq = try M.init(gpa);
        defer nq.deinit();
        try M.divTrunc(&nq, &r, q, &ten);
        const digit = @abs(try r.toConst().toInt(i64));
        const extra = dq - 1 > div_precision;
        if (extra) {
            sticky = sticky or digit != 0;
        } else {
            const round_up = digit > 5 or (digit == 5 and (sticky or nq.isOdd()));
            if (round_up) {
                var one = try M.initSet(gpa, @as(i64, if (nq.isPositive()) 1 else -1));
                defer one.deinit();
                try nq.add(&nq, &one);
            }
        }
        q.swap(&nq);
        e += 1;
        dq -= 1;
    }
    // Strip trailing zeros down to the ideal exponent.
    const ideal = ea - eb;
    while (e < ideal and !q.eqlZero()) {
        var ten = try M.initSet(gpa, 10);
        defer ten.deinit();
        var r = try M.init(gpa);
        defer r.deinit();
        var nq = try M.init(gpa);
        defer nq.deinit();
        try M.divTrunc(&nq, &r, q, &ten);
        if (!r.eqlZero()) break;
        q.swap(&nq);
        e += 1;
    }
    exp.* = e;
}

// ---------------------------------------------------------------------
// Comparison

/// Compares two numbers of any subtype by mathematical value. Returns null
/// when either side is NaN.
pub fn compare(gpa: Allocator, a: Value, b: Value) ?std.math.Order {
    const ka = kindOf(a).?;
    const kb = kindOf(b).?;
    if (ka == .float or kb == .float) {
        const fa = if (ka == .float) a.asFloat() else 0;
        const fb = if (kb == .float) b.asFloat() else 0;
        if ((ka == .float and std.math.isNan(fa)) or (kb == .float and std.math.isNan(fb))) return null;
        if (ka == .float and std.math.isInf(fa)) return if (fa > 0) .gt else .lt;
        if (kb == .float and std.math.isInf(fb)) return if (fb > 0) .lt else .gt;
    }
    // Exact comparison through decimal parts. Floats convert exactly.
    var pa = exactParts(gpa, a) catch return null;
    defer pa[0].deinit();
    var pb = exactParts(gpa, b) catch return null;
    defer pb[0].deinit();
    const e = @min(pa[1], pb[1]);
    mulPow10(&pa[0], @intCast(pa[1] - e)) catch return null;
    mulPow10(&pb[0], @intCast(pb[1] - e)) catch return null;
    return pa[0].order(pb[0]);
}

fn exactParts(gpa: Allocator, v: Value) !struct { M, i32 } {
    if (v.tag != .float) return toDecParts(gpa, v);
    const f = v.asFloat();
    // f = mant * 2^e exactly. For e < 0, mant * 2^e = mant * 5^-e * 10^e.
    const fr = std.math.frexp(f);
    var mant = fr.significand;
    var e: i32 = fr.exponent;
    var k: i32 = 0;
    while (mant != @floor(mant) and k < 1100) : (k += 1) {
        mant *= 2;
        e -= 1;
    }
    var m = try M.init(gpa);
    errdefer m.deinit();
    _ = m.toMutable(); // ensure capacity semantics
    var tmp: [4]Limb = undefined;
    var mut = big.Mutable.init(&tmp, 0);
    _ = mut.setFloat(mant, .trunc);
    try m.copy(mut.toConst());
    if (e >= 0) {
        try m.shiftLeft(&m, @intCast(e));
        return .{ m, 0 };
    }
    var five = try M.initSet(gpa, 5);
    defer five.deinit();
    try five.pow(&five, @intCast(-e));
    try m.mul(&m, &five);
    return .{ m, e };
}

/// Normalizes a bigint or decimal key to an integer when its value is
/// integral and fits in 64 bits (or to a bigint for an integral decimal).
pub fn normalizeKey(l: *Thread, k: Value) Error!Value {
    switch (k.tag) {
        .bigint => {
            if (bigToInt(k.as(BigInt))) |i| return Value.int(i);
            return k;
        },
        .decimal => {
            var m = (decIntegral(l.g.gpa, k.as(Decimal)) catch return l.raiseMem()) orelse return k;
            defer m.deinit();
            if (m.toConst().toInt(i64)) |i| return Value.int(i) else |_| {}
            return Value.obj(.bigint, newBigFromConst(l.g, m.toConst()) catch return l.raiseMem());
        },
        else => return k,
    }
}

const testing = std.testing;

test "decimal formatting and parsing" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const g = try state.create(testing.allocator, threaded.io());
    defer state.destroy(g);
    const d = try parseDecimalLiteral(g, "1.50");
    const s = try decimalToString(testing.allocator, d);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1.50", s);
    const d2 = try parseDecimalLiteral(g, "1e-2");
    const s2 = try decimalToString(testing.allocator, d2);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("0.01", s2);
    const b = try parseBigLiteral(g, "123456789012345678901234567890");
    const s3 = try bigToString(testing.allocator, b);
    defer testing.allocator.free(s3);
    try testing.expectEqualStrings("123456789012345678901234567890", s3);
}
