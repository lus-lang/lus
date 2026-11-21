//! Exact decimal expansion of doubles. This is the single source of float
//! digits for printf-style formatting: `string.format`, `tostring`, and
//! JSON all round from these digits, half to even, as C printf does.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The exact decimal expansion of a finite non-negative double, rounded on
/// request. `digits` has no leading zero and `exp` is the decimal
/// exponent of its first digit. Zero has no digits.
pub const Decimal = struct {
    digits: std.ArrayList(u8) = .empty,
    exp: i32 = 0,

    pub fn init(gpa: Allocator, f: f64) !Decimal {
        var d: Decimal = .{};
        const bits: u64 = @bitCast(f);
        const exp_bits: i32 = @intCast((bits >> 52) & 0x7FF);
        var mant: u64 = bits & ((@as(u64, 1) << 52) - 1);
        var e2: i32 = -1074;
        if (exp_bits != 0) {
            mant |= @as(u64, 1) << 52;
            e2 = exp_bits - 1075;
        }
        if (mant == 0) return d;
        const tz: u6 = @intCast(@ctz(mant));
        mant >>= tz;
        e2 += tz;
        // f = mant * 2^e2. With e2 < 0 this is mant * 5^-e2 / 10^-e2,
        // an integer scaled by a power of ten.
        var big = try std.math.big.int.Managed.initSet(gpa, mant);
        defer big.deinit();
        var k: i32 = 0;
        if (e2 >= 0) {
            try big.shiftLeft(&big, @intCast(e2));
        } else {
            var p5 = try std.math.big.int.Managed.initSet(gpa, 5);
            defer p5.deinit();
            try p5.pow(&p5, @intCast(-e2));
            try big.mul(&big, &p5);
            k = -e2;
        }
        const str = try big.toString(gpa, 10, .lower);
        d.digits = .fromOwnedSlice(str);
        d.exp = @as(i32, @intCast(str.len)) - 1 - k;
        return d;
    }

    /// The exact digits of the coefficient `coef` times ten to `e10`, as
    /// a decimal number stores them. Takes ownership of `coef`, a string of
    /// decimal digits.
    pub fn fromCoefficient(gpa: Allocator, coef: []u8, e10: i32) Decimal {
        var n = coef.len;
        while (n > 0 and coef[n - 1] == '0') n -= 1;
        var lead: usize = 0;
        while (lead < n and coef[lead] == '0') lead += 1;
        if (lead == n) {
            gpa.free(coef);
            return .{};
        }
        std.mem.copyForwards(u8, coef[0 .. n - lead], coef[lead..n]);
        const exp: i32 = @as(i32, @intCast(coef.len - lead)) - 1 + e10;
        var list: std.ArrayList(u8) = .fromOwnedSlice(coef);
        list.items.len = n - lead;
        return .{ .digits = list, .exp = exp };
    }

    pub fn deinit(d: *Decimal, gpa: Allocator) void {
        d.digits.deinit(gpa);
    }

    pub fn isZero(d: *const Decimal) bool {
        return d.digits.items.len == 0;
    }

    /// Digit at index `i`, where index 0 has exponent `exp`.
    pub fn digit(d: *const Decimal, i: isize) u8 {
        if (i < 0 or i >= d.digits.items.len) return '0';
        return d.digits.items[@intCast(i)];
    }

    /// Rounds to `nsig` significant digits, half to even, as C printf
    /// does in the default rounding mode.
    pub fn round(d: *Decimal, nsig: isize) void {
        const ds = d.digits.items;
        if (ds.len == 0 or nsig >= ds.len) return;
        if (nsig < 0) {
            d.digits.items.len = 0;
            return;
        }
        const ns: usize = @intCast(nsig);
        const next = ds[ns];
        var rest_nonzero = false;
        for (ds[ns + 1 ..]) |c| if (c != '0') {
            rest_nonzero = true;
            break;
        };
        const prev_odd = ns > 0 and (ds[ns - 1] - '0') % 2 == 1;
        const up = next > '5' or (next == '5' and (rest_nonzero or prev_odd));
        d.digits.items.len = ns;
        if (!up) return;
        var i = ns;
        while (i > 0) {
            i -= 1;
            if (ds[i] == '9') {
                ds[i] = '0';
            } else {
                ds[i] += 1;
                return;
            }
        }
        // Every kept digit was 9 (or none was kept): the value becomes
        // the next power of ten.
        ds[0] = '1';
        if (ns == 0) d.digits.items.len = 1;
        d.exp += 1;
    }

    /// Appends the "%.<prec>f" body.
    pub fn writeFixed(d: *Decimal, gpa: Allocator, out: *std.ArrayList(u8), prec: usize, hash: bool) !void {
        d.round(@as(isize, d.exp) + 1 + @as(isize, @intCast(prec)));
        const e: isize = if (d.isZero()) 0 else d.exp;
        if (d.isZero() or e < 0) {
            try out.append(gpa, '0');
        } else {
            var i: isize = 0;
            while (i <= e) : (i += 1) try out.append(gpa, d.digit(i));
        }
        if (prec > 0 or hash) try out.append(gpa, '.');
        var k: isize = 1;
        while (k <= prec) : (k += 1) try out.append(gpa, if (d.isZero()) '0' else d.digit(e + k));
    }

    /// Appends the "%.<prec>e" body.
    pub fn writeExp(d: *Decimal, gpa: Allocator, out: *std.ArrayList(u8), prec: usize, hash: bool, upper_case: bool) !void {
        d.round(@as(isize, @intCast(prec)) + 1);
        const e: i32 = if (d.isZero()) 0 else d.exp;
        try out.append(gpa, d.digit(0));
        if (prec > 0 or hash) try out.append(gpa, '.');
        var i: isize = 1;
        while (i <= prec) : (i += 1) try out.append(gpa, d.digit(i));
        try out.append(gpa, if (upper_case) 'E' else 'e');
        try out.append(gpa, if (e < 0) '-' else '+');
        const ae = @abs(e);
        if (ae < 10) try out.append(gpa, '0');
        try out.print(gpa, "{d}", .{ae});
    }
};
