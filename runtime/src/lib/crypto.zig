//! The `crypto` library: SHA-256, SHA-384, SHA-512, and SHA-1 digests, HMAC, Ed25519
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
const gc = @import("../vm/gc.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha1 = std.crypto.hash.Sha1;
const Ed25519 = std.crypto.sign.Ed25519;
const argon2 = std.crypto.pwhash.argon2;
const phc = std.crypto.pwhash.phc_format;

const funcs = [_]aux.Reg{
    .{ .name = "hash", .func = hash },
    .{ .name = "hasher", .func = hasher },
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

const hasher_key = "crypto.hasher";

const hasher_methods = [_]aux.Reg{
    .{ .name = "update", .func = hasherUpdate },
    .{ .name = "digest", .func = hasherDigest },
};

pub fn open(l: *Thread) Error!void {
    const mt = try l.newTable(0, 3);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    const m = try aux.newLib(l, .methods, "crypto:hasher", &hasher_methods);
    try aux.setField(l, mt, "__index", Value.obj(.table, m));
    try aux.setField(l, mt, "__name", try l.newStringValue(hasher_key));
    // Hide the metatable from getmetatable and setmetatable.
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), hasher_key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, hasher_key, mt) catch return l.raiseMem();
    const t = try aux.newLib(l, .fields, "crypto", &funcs);
    try aux.setGlobal(l, "crypto", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Zig interface
//
// The runtime verifies release archives and remote module bundles with
// these functions, which are the same primitives the Lus functions use.

/// The SHA-256 digest of `data`.
pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(data, &out, .{});
    return out;
}

/// True when `sig` is a valid Ed25519 signature of `msg` by `public`,
/// under the same strict verification as `crypto.verify`.
pub fn ed25519Verify(public: [32]u8, msg: []const u8, sig: [64]u8) bool {
    const pk = Ed25519.PublicKey.fromBytes(public) catch return false;
    Ed25519.Signature.fromBytes(sig).verifyStrict(msg, pk) catch return false;
    return true;
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

const Algorithm = enum { sha256, sha384, sha512, sha1 };
const algorithm_names = [_][]const u8{ "sha256", "sha384", "sha512", "sha1" };

fn checkAlgorithm(l: *Thread, i: u32) Error!Algorithm {
    return @fromBackingInt(@intCast(try aux.checkOption(l, i, null, &algorithm_names)));
}

fn retBytes(l: *Thread, bytes: []const u8) Error!u32 {
    return aux.ret(l, Value.obj(.vector, try vector.newVector(l, bytes)));
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
        .sha384 => blk: {
            Sha384.hash(data, out[0..Sha384.digest_length], .{});
            break :blk Sha384.digest_length;
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
    return retBytes(l, out[0..n]);
}

/// The state of a streaming digest, the payload of a `crypto.hasher`
/// userdata. It holds no heap memory, so the userdata needs no finalizer.
const Hasher = union(Algorithm) {
    sha256: Sha256,
    sha384: Sha384,
    sha512: Sha512,
    sha1: Sha1,
};

fn hasher(l: *Thread) Error!u32 {
    const alg = try checkAlgorithm(l, 1);
    const mt: *Table = @ptrCast(@alignCast(l.g.ext.get(hasher_key).?));
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Hasher), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Hasher);
    u.nuser = 0;
    u.metatable = mt;
    const h: *Hasher = @ptrCast(@alignCast(u.data()));
    h.* = switch (alg) {
        .sha256 => .{ .sha256 = Sha256.init(.{}) },
        .sha384 => .{ .sha384 = Sha384.init(.{}) },
        .sha512 => .{ .sha512 = Sha512.init(.{}) },
        .sha1 => .{ .sha1 = Sha1.init(.{}) },
    };
    return aux.ret(l, Value.obj(.userdata, u));
}

fn checkHasher(l: *Thread) Error!*Hasher {
    const v = l.arg(1);
    if (v.tag == .userdata) {
        const u = v.as(Userdata);
        if (u.metatable == @as(*Table, @ptrCast(@alignCast(l.g.ext.get(hasher_key).?)))) return @ptrCast(@alignCast(u.data()));
    }
    return aux.typeError(l, 1, hasher_key);
}

/// `hasher:update(data)` adds bytes and returns the hasher.
fn hasherUpdate(l: *Thread) Error!u32 {
    const h = try checkHasher(l);
    const data = try vector.checkData(l, 2);
    switch (h.*) {
        inline else => |*st| st.update(data),
    }
    return aux.ret(l, l.arg(1));
}

/// `hasher:digest()` returns the digest of every byte added so far. It
/// finishes a copy of the state, so the hasher accepts more data after.
fn hasherDigest(l: *Thread) Error!u32 {
    const h = try checkHasher(l);
    var out: [Sha512.digest_length]u8 = undefined;
    const n: usize = switch (h.*) {
        inline else => |st| blk: {
            var copy = st;
            const T = @TypeOf(st);
            copy.final(out[0..T.digest_length]);
            break :blk T.digest_length;
        },
    };
    return retBytes(l, out[0..n]);
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
                .sha384 => Sha384,
                .sha512 => Sha512,
                .sha1 => Sha1,
            });
            H.create(out[0..H.mac_length], data, key);
            break :blk H.mac_length;
        },
    };
    return retBytes(l, out[0..n]);
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
    return aux.retBool(l, ed25519Verify(public.*, msg, sig_bytes.*));
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

test "zig interface" {
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectEqual(want, sha256("abc"));
    var pk: [32]u8 = undefined;
    var sig: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pk, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    _ = try std.fmt.hexToBytes(&sig, "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
    try std.testing.expect(ed25519Verify(pk, "", sig));
    try std.testing.expect(!ed25519Verify(pk, "x", sig));
}

test "constant-time comparison" {
    try std.testing.expect(constantTimeEqual("abc", "abc"));
    try std.testing.expect(!constantTimeEqual("abc", "abd"));
    try std.testing.expect(!constantTimeEqual("abc", "ab"));
    try std.testing.expect(constantTimeEqual("", ""));
}
