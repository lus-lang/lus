//! Conversion of big integers to decimal text in subquadratic time.
//!
//! The conversion of `std.math.big` divides by one limb at a time, which
//! takes time quadratic in the length of the number: half a second for the
//! 147,455 digits of the largest decimal. This file splits the number in
//! halves at powers of ten instead, 10^(456 * 2^i), and converts each half
//! the same way. Each split divides by a power of ten through a Barrett
//! reciprocal, which Newton iteration builds from multiplications, and
//! `std.math.big` multiplies large numbers with Karatsuba, so the whole
//! conversion takes about the time of a few multiplications of numbers of
//! its length. Numbers of at most `small_limbs` limbs convert with
//! `std.math.big`, which is faster at that size.

const std = @import("std");
const big = std.math.big;
const M = big.int.Managed;
const Allocator = std.mem.Allocator;

/// Below this many limbs the conversion of std is faster.
const small_limbs = 48;

/// The digits of the first power of ten, 10^456, about 24 limbs. Each
/// later power squares the one before.
const base_digits = 456;

/// Below this many bits a reciprocal divides directly.
const direct_bits = 4096;

/// The decimal digits of `c`, with a leading '-' when it is negative.
pub fn toDecimal(gpa: Allocator, c: big.int.Const) ![]u8 {
    if (c.limbs.len <= small_limbs) {
        var m = try c.toManaged(gpa);
        defer m.deinit();
        return m.toString(gpa, 10, .lower);
    }
    var x = try c.toManaged(gpa);
    defer x.deinit();
    x.abs();

    // The powers 10^(456 * 2^i) up to the first whose square exceeds x,
    // each with its bit length and reciprocal.
    var levels: std.ArrayList(Level) = .empty;
    defer {
        for (levels.items) |*lv| lv.deinit();
        levels.deinit(gpa);
    }
    const xbits = x.toConst().bitCountAbs();
    var digits: usize = base_digits;
    while (true) {
        // Each power is the square of the one before, and the level owns it.
        var p = try M.init(gpa);
        errdefer p.deinit();
        if (levels.items.len == 0) {
            try p.set(10);
            try p.pow(&p, base_digits);
        } else {
            const prev = &levels.items[levels.items.len - 1].power;
            try p.mul(prev, prev);
        }
        const lv = try Level.init(gpa, p, digits);
        levels.append(gpa, lv) catch |e| {
            // The errdefer above frees the power.
            var recip = lv.recip;
            recip.deinit();
            return e;
        };
        // A power of b bits is at least 2^(b-1), so its square exceeds x
        // once 2b - 2 reaches the bits of x.
        if (2 * lv.bits > xbits + 1) break;
        digits *= 2;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (!c.positive) try out.append(gpa, '-');
    try convert(gpa, &out, x.toConst(), levels.items, levels.items.len - 1, 0);
    return out.toOwnedSlice(gpa);
}

const Level = struct {
    power: M,
    digits: usize,
    bits: usize,
    recip: M,

    /// Takes `power` and computes its reciprocal. On failure the caller
    /// still owns `power`.
    fn init(gpa: Allocator, power: M, digits: usize) !Level {
        const bits = power.toConst().bitCountAbs();
        const recip = try reciprocal(gpa, &power, bits);
        return .{ .power = power, .digits = digits, .bits = bits, .recip = recip };
    }

    fn deinit(lv: *Level) void {
        lv.power.deinit();
        lv.recip.deinit();
    }
};

/// Appends the digits of x, which is below the square of the power of
/// `level`, left padded with zeros to `pad` digits.
fn convert(gpa: Allocator, out: *std.ArrayList(u8), x: big.int.Const, levels: []const Level, level: usize, pad: usize) !void {
    if (x.limbs.len <= small_limbs or x.order(levels[0].power.toConst()) == .lt) {
        var m = try x.toManaged(gpa);
        defer m.deinit();
        const s = try m.toString(gpa, 10, .lower);
        defer gpa.free(s);
        const text = if (s.len == 1 and s[0] == '0' and pad > 0) s[0..0] else s;
        if (pad > text.len) try out.appendNTimes(gpa, '0', pad - text.len);
        try out.appendSlice(gpa, text);
        return;
    }
    const lv = &levels[level];
    if (x.order(lv.power.toConst()) == .lt) {
        return convert(gpa, out, x, levels, level - 1, pad);
    }
    var q = try M.init(gpa);
    defer q.deinit();
    var r = try M.init(gpa);
    defer r.deinit();
    var xm = try x.toManaged(gpa);
    defer xm.deinit();
    try divmod(gpa, &q, &r, &xm, lv);
    try convert(gpa, out, q.toConst(), levels, if (level == 0) 0 else level - 1, if (pad > lv.digits) pad - lv.digits else 0);
    if (level == 0) {
        // Below the first power the remainder converts directly.
        var rs = try r.toString(gpa, 10, .lower);
        defer gpa.free(rs);
        if (rs.len == 1 and rs[0] == '0') rs = rs[0..0];
        try out.appendNTimes(gpa, '0', lv.digits - rs.len);
        try out.appendSlice(gpa, rs);
        return;
    }
    try convert(gpa, out, r.toConst(), levels, level - 1, lv.digits);
}

/// q, r = x divided by the power of `lv`, for 0 <= x < power^2, by the
/// Barrett method: the estimate ((x >> (s - 1)) * recip) >> (s + 1), for
/// a power of s bits, is at most a few units below the quotient, and the
/// remainder corrects it. Only the top half of x enters the product.
fn divmod(gpa: Allocator, q: *M, r: *M, x: *const M, lv: *const Level) !void {
    try q.shiftRight(x, lv.bits - 1);
    try q.mul(q, &lv.recip);
    try q.shiftRight(q, lv.bits + 1);
    var t = try M.init(gpa);
    defer t.deinit();
    try t.mul(q, &lv.power);
    try r.sub(x, &t);
    var one = try M.initSet(gpa, 1);
    defer one.deinit();
    var fixes: usize = 0;
    while (r.toConst().order(lv.power.toConst()) != .lt) : (fixes += 1) {
        if (fixes > 8) return M.divTrunc(q, r, x, &lv.power);
        try r.sub(r, &lv.power);
        try q.add(q, &one);
    }
    while (!r.isPositive() and !r.eqlZero()) : (fixes += 1) {
        if (fixes > 8) return M.divTrunc(q, r, x, &lv.power);
        try r.add(r, &lv.power);
        try q.sub(q, &one);
    }
}

/// floor(2^(2s) / d) for d of bit length s. A divisor past `direct_bits`
/// takes the reciprocal of its top half, scales it, and refines it with
/// one Newton step, which doubles its precision, so the cost is a few
/// multiplications of numbers of its length.
fn reciprocal(gpa: Allocator, d: *const M, s: usize) !M {
    var p2s = try M.initSet(gpa, 1);
    defer p2s.deinit();
    try p2s.shiftLeft(&p2s, 2 * s);
    if (s <= direct_bits) {
        var q = try M.init(gpa);
        errdefer q.deinit();
        var r = try M.init(gpa);
        defer r.deinit();
        try M.divTrunc(&q, &r, &p2s, d);
        return q;
    }
    const h = (s + 1) / 2;
    var dh = try M.init(gpa);
    defer dh.deinit();
    try dh.shiftRight(d, s - h);
    var rh = try reciprocal(gpa, &dh, h);
    defer rh.deinit();
    var x = try M.init(gpa);
    errdefer x.deinit();
    try x.shiftLeft(&rh, s - h);
    // x += x * (2^(2s) - d * x) / 2^(2s)
    var e = try M.init(gpa);
    defer e.deinit();
    try e.mul(d, &x);
    try e.sub(&p2s, &e);
    var t = try M.init(gpa);
    defer t.deinit();
    try t.mul(&x, &e);
    const neg = !t.isPositive();
    t.abs();
    try t.shiftRight(&t, 2 * s);
    if (neg) try x.sub(&x, &t) else try x.add(&x, &t);
    // Settle the last units: 0 <= 2^(2s) - d * x < d.
    try e.mul(d, &x);
    try e.sub(&p2s, &e);
    var one = try M.initSet(gpa, 1);
    defer one.deinit();
    var fixes: usize = 0;
    while (!e.isPositive() and !e.eqlZero()) : (fixes += 1) {
        if (fixes > 64) return direct(gpa, &x, &p2s, d);
        try x.sub(&x, &one);
        try e.add(&e, d);
    }
    while (e.toConst().order(d.toConst()) != .lt) : (fixes += 1) {
        if (fixes > 64) return direct(gpa, &x, &p2s, d);
        try x.add(&x, &one);
        try e.sub(&e, d);
    }
    return x;
}

/// The exact reciprocal by long division, for the rare case where the
/// Newton step lands too far away to settle by units.
fn direct(gpa: Allocator, x: *M, p2s: *const M, d: *const M) !M {
    var r = try M.init(gpa);
    defer r.deinit();
    try M.divTrunc(x, &r, p2s, d);
    return x.*;
}

test "radix conversion agrees with std on numbers of many sizes" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const sizes = [_]usize{ 1, 47, 48, 49, 60, 100, 300, 1000, 3000 };
    for (sizes) |limbs| {
        for (0..3) |round| {
            var m = try M.init(gpa);
            defer m.deinit();
            try m.ensureCapacity(limbs);
            for (0..limbs) |i| m.limbs[i] = rand.int(big.Limb);
            m.setMetadata(round != 1, limbs);
            m.normalize(limbs);
            const want = try m.toString(gpa, 10, .lower);
            defer gpa.free(want);
            const got = try toDecimal(gpa, m.toConst());
            defer gpa.free(got);
            try std.testing.expectEqualStrings(want, got);
        }
    }
    // Powers of ten and their neighbors exercise the zero padding.
    for ([_]u32{ 455, 456, 457, 912, 5000, 20000 }) |k| {
        var p = try M.initSet(gpa, 10);
        defer p.deinit();
        try p.pow(&p, k);
        var one = try M.initSet(gpa, 1);
        defer one.deinit();
        for (0..3) |j| {
            if (j == 1) try p.sub(&p, &one);
            if (j == 2) try p.add(&p, &one);
            const want = try p.toString(gpa, 10, .lower);
            defer gpa.free(want);
            const got = try toDecimal(gpa, p.toConst());
            defer gpa.free(got);
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

fn convertOnce(gpa: Allocator, c: big.int.Const) !void {
    const s = try toDecimal(gpa, c);
    gpa.free(s);
}

test "radix conversion frees everything when an allocation fails" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    // Large enough for three levels and a Newton reciprocal.
    const limbs = 400;
    var m = try M.init(gpa);
    defer m.deinit();
    try m.ensureCapacity(limbs);
    for (0..limbs) |i| m.limbs[i] = rand.int(big.Limb);
    m.setMetadata(true, limbs);
    m.normalize(limbs);
    try std.testing.checkAllAllocationFailures(gpa, convertOnce, .{m.toConst()});
}
