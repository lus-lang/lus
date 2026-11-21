//! The `crypto` library: SHA-2 and SHA-1 digests, HMAC, Ed25519
//! signatures, secure random bytes, constant-time comparison, Argon2id
//! password hashing, and UUID and ULID generation
//! (spec/design/crypto.md).
//!
//! Every primitive comes from `std.crypto`. This file checks arguments,
//! converts between Lus values and bytes, and writes the text forms of
//! UUIDs and ULIDs. Digests, keys, and signatures are vectors, because
//! they are raw bytes (spec/design/strings.md).

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const transcode = @import("transcode.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha1 = std.crypto.hash.Sha1;
const Ed25519 = std.crypto.sign.Ed25519;
const argon2 = std.crypto.pwhash.argon2;
const phc = std.crypto.pwhash.phc_format;

const funcs = [_]aux.Reg{
    .{ .name = "hash", .func = hash },
    .{ .name = "hmac", .func = hmac },
    .{ .name = "random", .func = random },
    .{ .name = "equal", .func = equal },
    .{ .name = "keypair", .func = keypair },
    .{ .name = "sign", .func = sign },
    .{ .name = "verify", .func = verify },
    .{ .name = "hashpassword", .func = hashpassword },
    .{ .name = "verifypassword", .func = verifypassword },
    .{ .name = "uuid", .func = uuid },
    .{ .name = "ulid", .func = ulid },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try aux.setGlobal(l, "crypto", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Shared helpers

/// Fills `buf` from the secure random source of the operating system.
pub fn secureRandom(l: *Thread, buf: []u8) Error!void {
    l.g.io.randomSecure(buf) catch return l.raiseFmt("secure random source unavailable", .{});
}

/// The bytes of a vector argument of exactly `n` bytes, which is how keys,
/// seeds, and signatures are passed.
fn checkSized(l: *Thread, i: u32, comptime n: usize) Error!*const [n]u8 {
    const v = l.arg(i);
    if (v.tag == .vector) {
        const b = (try vector.checkVector(l, i)).bytes.items;
        if (b.len == n) return b[0..n];
    }
    return aux.argError(l, i, std.fmt.comptimePrint("{d}-byte vector expected", .{n}), .{});
}

const Algorithm = enum { sha256, sha512, sha1 };
const algorithm_names = [_][]const u8{ "sha256", "sha512", "sha1" };

fn checkAlgorithm(l: *Thread, i: u32) Error!Algorithm {
    return @fromBackingInt(@intCast(try aux.checkOption(l, i, null, &algorithm_names)));
}

/// Returns `bytes` as a vector, or as text in the encoding argument `i`.
fn retDigest(l: *Thread, bytes: []const u8, i: u32) Error!u32 {
    if (l.arg(i).isNil()) return aux.ret(l, Value.obj(.vector, try vector.newVector(l, bytes)));
    const which = try aux.checkOption(l, i, null, &.{ "hex", "base64" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(l.g.gpa);
    (if (which == 0) transcode.encodeHex(l.g.gpa, &out, bytes) else transcode.encodeBase64(l.g.gpa, &out, bytes)) catch return l.raiseMem();
    return aux.retStr(l, out.items);
}

// ---------------------------------------------------------------------
// Digests

fn hash(l: *Thread) Error!u32 {
    const alg = try checkAlgorithm(l, 1);
    const data = try vector.checkData(l, 2);
    var out: [Sha512.digest_length]u8 = undefined;
    const n: usize = switch (alg) {
        .sha256 => blk: {
            Sha256.hash(data, out[0..Sha256.digest_length], .{});
            break :blk Sha256.digest_length;
        },
        .sha512 => blk: {
            Sha512.hash(data, out[0..Sha512.digest_length], .{});
            break :blk Sha512.digest_length;
        },
        .sha1 => blk: {
            Sha1.hash(data, out[0..Sha1.digest_length], .{});
            break :blk Sha1.digest_length;
        },
    };
    return retDigest(l, out[0..n], 3);
}

fn hmac(l: *Thread) Error!u32 {
    const alg = try checkAlgorithm(l, 1);
    const key = try vector.checkData(l, 2);
    const data = try vector.checkData(l, 3);
    var out: [Sha512.digest_length]u8 = undefined;
    const n: usize = switch (alg) {
        inline else => |a| blk: {
            const H = std.crypto.auth.hmac.Hmac(switch (a) {
                .sha256 => Sha256,
                .sha512 => Sha512,
                .sha1 => Sha1,
            });
            H.create(out[0..H.mac_length], data, key);
            break :blk H.mac_length;
        },
    };
    return retDigest(l, out[0..n], 4);
}

// ---------------------------------------------------------------------
// Random bytes and comparison

const max_random = 1 << 20;

fn random(l: *Thread) Error!u32 {
    const n = try aux.checkInt(l, 1);
    if (n < 0 or n > max_random) return aux.argError(l, 1, "size out of range", .{});
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(l.g.gpa);
    list.resize(l.g.gpa, @intCast(n)) catch return l.raiseMem();
    try secureRandom(l, list.items);
    return aux.ret(l, Value.obj(.vector, try vector.newVectorFrom(l, &list)));
}

/// Compares two byte sequences in time that depends only on their
/// length. The accumulator is volatile so the loop cannot stop early.
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    const p: *volatile u8 = &acc;
    for (a, b) |x, y| p.* |= x ^ y;
    return p.* == 0;
}

fn equal(l: *Thread) Error!u32 {
    const a = try vector.checkData(l, 1);
    const b = try vector.checkData(l, 2);
    return aux.retBool(l, constantTimeEqual(a, b));
}

// ---------------------------------------------------------------------
// Ed25519

fn keyPairOf(l: *Thread, seed: [32]u8) Error!Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed) catch l.raiseFmt("invalid Ed25519 seed", .{});
}

fn keypair(l: *Thread) Error!u32 {
    var seed: [32]u8 = undefined;
    if (l.arg(1).isNil()) {
        try secureRandom(l, &seed);
    } else {
        seed = (try checkSized(l, 1, 32)).*;
    }
    const kp = try keyPairOf(l, seed);
    try l.push(Value.obj(.vector, try vector.newVector(l, &seed)));
    try l.push(Value.obj(.vector, try vector.newVector(l, &kp.public_key.toBytes())));
    return 2;
}

fn sign(l: *Thread) Error!u32 {
    const seed = try checkSized(l, 1, 32);
    const msg = try vector.checkData(l, 2);
    const kp = try keyPairOf(l, seed.*);
    const sig = kp.sign(msg, null) catch return l.raiseFmt("invalid Ed25519 key", .{});
    return aux.ret(l, Value.obj(.vector, try vector.newVector(l, &sig.toBytes())));
}

fn verify(l: *Thread) Error!u32 {
    const public = try checkSized(l, 1, 32);
    const msg = try vector.checkData(l, 2);
    const sig_bytes = try checkSized(l, 3, 64);
    const pk = Ed25519.PublicKey.fromBytes(public.*) catch return aux.retBool(l, false);
    const sig = Ed25519.Signature.fromBytes(sig_bytes.*);
    sig.verifyStrict(msg, pk) catch return aux.retBool(l, false);
    return aux.retBool(l, true);
}

// ---------------------------------------------------------------------
// Passwords

const PhcHash = struct {
    alg_id: []const u8,
    alg_version: ?u32,
    m: u32,
    t: u32,
    p: u24,
    salt: phc.BinValue(64),
    hash: phc.BinValue(64),
};

const argon2_version = 0x13;
const salt_len = 16;
const hash_len = 32;
/// The largest memory cost accepted, in KiB, which is 4 GiB. A stored hash
/// with a higher cost is treated as malformed rather than allocated.
const max_memory = 1 << 22;
const max_time = 1 << 16;

/// Reads the optional integer field `name` of the options table, between
/// `lo` and `hi`.
fn optField(l: *Thread, t: *Table, name: []const u8, default: u32, lo: u32, hi: u32) Error!u32 {
    const v = try aux.getField(l, t, name);
    if (v.isNil()) return default;
    const n = (if (v.isNumber()) ops.toIntegerStrict(v) else null) orelse
        return aux.argError(l, 2, "option '{s}' must be an integer", .{name});
    if (n < lo or n > hi) return aux.argError(l, 2, "option '{s}' out of range", .{name});
    return @intCast(n);
}

fn kdfError(l: *Thread, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => l.raiseMem(),
        else => l.raiseFmt("invalid Argon2 parameters", .{}),
    };
}

fn hashpassword(l: *Thread) Error!u32 {
    const password = try vector.checkData(l, 1);
    var params: argon2.Params = argon2.Params.owasp_2id;
    if (!l.arg(2).isNil()) {
        const t = try aux.checkTable(l, 2);
        params.p = @intCast(try optField(l, t, "parallelism", params.p, 1, 255));
        params.t = try optField(l, t, "time", params.t, 1, max_time);
        params.m = try optField(l, t, "memory", params.m, 8 * @as(u32, params.p), max_memory);
    }
    var salt: [salt_len]u8 = undefined;
    try secureRandom(l, &salt);
    var key: [hash_len]u8 = undefined;
    argon2.kdf(l.g.gpa, &key, password, &salt, params, .argon2id, l.g.io) catch |e| return kdfError(l, e);
    var buf: [160]u8 = undefined;
    const s = phc.serialize(PhcHash{
        .alg_id = "argon2id",
        .alg_version = argon2_version,
        .m = params.m,
        .t = params.t,
        .p = params.p,
        .salt = phc.BinValue(64).fromSlice(&salt) catch unreachable,
        .hash = phc.BinValue(64).fromSlice(&key) catch unreachable,
    }, &buf) catch unreachable;
    return aux.retStr(l, s);
}

fn verifypassword(l: *Thread) Error!u32 {
    const password = try vector.checkData(l, 1);
    const str = try aux.checkBytes(l, 2);
    const h = phc.deserialize(PhcHash, str) catch return aux.argError(l, 2, "invalid password hash", .{});
    const mode = std.meta.stringToEnum(argon2.Mode, h.alg_id) orelse
        return aux.argError(l, 2, "unsupported password hash '{s}'", .{h.alg_id});
    if (h.alg_version) |v| if (v != argon2_version) return aux.argError(l, 2, "unsupported Argon2 version", .{});
    if (h.m > max_memory or h.t > max_time) return aux.argError(l, 2, "invalid password hash", .{});
    const expected = h.hash.constSlice();
    if (expected.len < 4) return aux.argError(l, 2, "invalid password hash", .{});
    var buf: [64]u8 = undefined;
    const got = buf[0..expected.len];
    const params: argon2.Params = .{ .t = h.t, .m = h.m, .p = h.p };
    argon2.kdf(l.g.gpa, got, password, h.salt.constSlice(), params, mode, l.g.io) catch |e| return kdfError(l, e);
    return aux.retBool(l, constantTimeEqual(got, expected));
}

// ---------------------------------------------------------------------
// UUIDs and ULIDs

/// The Unix time in milliseconds, clamped to the 48 bits both formats
/// hold.
fn unixMillis(l: *Thread) u128 {
    const ms = std.Io.Clock.real.now(l.g.io).toMilliseconds();
    return @intCast(std.math.clamp(ms, 0, (1 << 48) - 1));
}

/// The next value of a monotonic identifier with `bits` random bits under
/// a 48-bit millisecond timestamp. A later millisecond takes fresh random
/// bits. Otherwise the value is `last` plus one, which is the monotonic
/// method of RFC 9562 and of the ULID specification, so a clock that
/// steps back also keeps the sequence increasing.
fn nextMonotonic(l: *Thread, last: *u128, comptime bits: u7) Error!u128 {
    const ms = unixMillis(l);
    const v = if (ms > last.* >> bits) blk: {
        var rnd: [16]u8 = undefined;
        try secureRandom(l, &rnd);
        const mask: u128 = (@as(u128, 1) << bits) - 1;
        break :blk (ms << bits) | (std.mem.readInt(u128, &rnd, .big) & mask);
    } else last.* +% 1;
    last.* = v;
    return v;
}

fn formatUuid(b: [16]u8) [36]u8 {
    const digits = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var j: usize = 0;
    for (b, 0..) |c, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = digits[c >> 4];
        out[j + 1] = digits[c & 15];
        j += 2;
    }
    return out;
}

fn uuid(l: *Thread) Error!u32 {
    const version = try aux.optInt(l, 1, 4);
    var b: [16]u8 = undefined;
    switch (version) {
        4 => try secureRandom(l, &b),
        7 => {
            // 48 bits of time, then a 74-bit counter split around the
            // version and variant fields.
            const v = try nextMonotonic(l, &l.g.uuid7_last, 74);
            const ms: u48 = @truncate(v >> 74);
            const rand_a: u12 = @truncate(v >> 62);
            const rand_b: u62 = @truncate(v);
            std.mem.writeInt(u48, b[0..6], ms, .big);
            std.mem.writeInt(u16, b[6..8], rand_a, .big);
            std.mem.writeInt(u64, b[8..16], rand_b, .big);
        },
        else => return aux.argError(l, 1, "version 4 or 7 expected", .{}),
    }
    b[6] = (b[6] & 0x0f) | @as(u8, @intCast(version << 4));
    b[8] = (b[8] & 0x3f) | 0x80;
    return aux.retStr(l, &formatUuid(b));
}

fn ulid(l: *Thread) Error!u32 {
    var v = try nextMonotonic(l, &l.g.ulid_last, 80);
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    var out: [26]u8 = undefined;
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@intCast(v & 31)];
        v >>= 5;
    }
    return aux.retStr(l, &out);
}

test "uuid text form" {
    const b = [16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    try std.testing.expectEqualStrings("01234567-89ab-cdef-0123-456789abcdef", &formatUuid(b));
}

test "constant-time comparison" {
    try std.testing.expect(constantTimeEqual("abc", "abc"));
    try std.testing.expect(!constantTimeEqual("abc", "abd"));
    try std.testing.expect(!constantTimeEqual("abc", "ab"));
    try std.testing.expect(constantTimeEqual("", ""));
}
