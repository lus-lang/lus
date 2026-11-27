//! Asymmetric keys for the `crypto` library: RSA, ECDSA over P-256 and
//! P-384, and Ed25519 (spec/design/crypto.md, "Keys").
//!
//! The arithmetic comes from `std.crypto`: the curve operations of
//! `std.crypto.sign.ecdsa` and `std.crypto.sign.Ed25519`, the RSA
//! verification of `std.crypto.Certificate.rsa`, and the constant-time
//! modular exponentiation of `std.crypto.ff`, on which RSA signing is
//! built. This file holds what std leaves out: the key formats (PEM, the
//! DER structures of PKCS#8, SPKI, PKCS#1, and SEC1, and JWK) and the
//! EMSA-PKCS1-v1_5 and EMSA-PSS encodings of RFC 8017 that signing needs.
//!
//! Nothing here touches the Lus heap. A `Key` is plain data, the payload
//! of a `crypto.key` userdata.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Ed25519 = std.crypto.sign.Ed25519;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const rsa = std.crypto.Certificate.rsa;
const Modulus = std.crypto.ff.Modulus(4096);
const Fe = Modulus.Fe;
const base64 = std.base64;

pub const KeyError = error{
    /// The bytes do not form a key in any supported layout.
    InvalidKey,
    /// A PEM block or PKCS#8 structure is encrypted.
    EncryptedKey,
    /// The key uses an algorithm or curve outside the supported set.
    UnsupportedKey,
    /// The RSA modulus is not 2048, 3072, or 4096 bits.
    UnsupportedSize,
    /// The public and private halves do not match.
    InconsistentKey,
    OutOfMemory,
};

// ---------------------------------------------------------------------
// The key

/// A big-endian unsigned integer of up to 4096 bits, without leading zero
/// bytes.
pub const Big = struct {
    len: u16 = 0,
    b: [512]u8 = undefined,

    pub fn slice(x: *const Big) []const u8 {
        return x.b[0..x.len];
    }

    fn set(x: *Big, bytes: []const u8) KeyError!void {
        var s = bytes;
        while (s.len > 0 and s[0] == 0) s = s[1..];
        if (s.len > x.b.len) return error.UnsupportedSize;
        @memcpy(x.b[0..s.len], s);
        x.len = @intCast(s.len);
    }
};

pub const Kind = enum { rsa, p256, p384, ed25519 };

pub const Key = struct {
    kind: Kind,
    private: bool,
    // RSA components. Only `n` and `e` are set for a public key.
    n: Big = .{},
    e: Big = .{},
    d: Big = .{},
    p: Big = .{},
    q: Big = .{},
    dp: Big = .{},
    dq: Big = .{},
    qi: Big = .{},
    /// The public key of an EC or Ed25519 key: the uncompressed SEC1
    /// point, or the 32 bytes of an Ed25519 key.
    public: [97]u8 = undefined,
    public_len: u8 = 0,
    /// The secret scalar of an EC key, or the seed of an Ed25519 key.
    secret: [48]u8 = undefined,

    pub fn publicBytes(k: *const Key) []const u8 {
        return k.public[0..k.public_len];
    }

    pub fn secretBytes(k: *const Key) []const u8 {
        return k.secret[0..scalarLen(k.kind)];
    }

    /// The bit length of an RSA modulus.
    pub fn bits(k: *const Key) usize {
        const n = k.n.slice();
        if (n.len == 0) return 0;
        return n.len * 8 - @clz(n[0]);
    }

    /// The public half of the key.
    pub fn toPublic(k: *const Key) Key {
        var out: Key = .{ .kind = k.kind, .private = false };
        out.n = k.n;
        out.e = k.e;
        out.public = k.public;
        out.public_len = k.public_len;
        return out;
    }
};

fn scalarLen(kind: Kind) usize {
    return switch (kind) {
        .p256 => 32,
        .p384 => 48,
        .ed25519 => 32,
        .rsa => 0,
    };
}

pub fn curveName(kind: Kind) []const u8 {
    return switch (kind) {
        .p256 => "P-256",
        .p384 => "P-384",
        .ed25519 => "Ed25519",
        .rsa => "",
    };
}

// ---------------------------------------------------------------------
// Building and checking keys

fn rsaPublic(n: []const u8, e: []const u8) KeyError!Key {
    var k: Key = .{ .kind = .rsa, .private = false };
    try k.n.set(n);
    try k.e.set(e);
    const len = k.n.len;
    if (len != 256 and len != 384 and len != 512) return error.UnsupportedSize;
    if (k.n.b[len - 1] & 1 == 0) return error.InvalidKey;
    // std's verifier takes an odd public exponent of at most four bytes.
    if (k.e.len == 0 or k.e.len > 4 or k.e.b[k.e.len - 1] & 1 == 0) return error.InvalidKey;
    if (k.e.len == 1 and k.e.b[0] < 3) return error.InvalidKey;
    _ = rsa.PublicKey.fromBytes(k.e.slice(), k.n.slice()) catch return error.InvalidKey;
    return k;
}

const RsaPrivateParts = struct { n: []const u8, e: []const u8, d: []const u8, p: []const u8, q: []const u8, dp: []const u8, dq: []const u8, qi: []const u8 };

fn rsaPrivate(parts: RsaPrivateParts) KeyError!Key {
    var k = try rsaPublic(parts.n, parts.e);
    k.private = true;
    try k.d.set(parts.d);
    try k.p.set(parts.p);
    try k.q.set(parts.q);
    try k.dp.set(parts.dp);
    try k.dq.set(parts.dq);
    try k.qi.set(parts.qi);
    const n_len = k.n.len;
    for ([_]*const Big{ &k.d, &k.p, &k.q, &k.dp, &k.dq, &k.qi }) |x| {
        if (x.len == 0 or x.len > n_len) return error.InvalidKey;
    }
    if (k.p.b[k.p.len - 1] & 1 == 0 or k.q.b[k.q.len - 1] & 1 == 0) return error.InvalidKey;
    // The primes belong to the modulus: their product is a multiple of
    // it and has no more bytes than it can have.
    if (k.p.len + k.q.len > n_len + 1) return error.InvalidKey;
    const n_mod = Modulus.fromBytes(k.n.slice(), .big) catch return error.InvalidKey;
    const p_n = Fe.fromBytes(n_mod, k.p.slice(), .big) catch return error.InvalidKey;
    const q_n = Fe.fromBytes(n_mod, k.q.slice(), .big) catch return error.InvalidKey;
    if (!n_mod.mul(p_n, q_n).isZero()) return error.InvalidKey;
    // The CRT values must reduce under their primes, which the modular
    // arithmetic checks when it reads them.
    const p_mod = Modulus.fromBytes(k.p.slice(), .big) catch return error.InvalidKey;
    const q_mod = Modulus.fromBytes(k.q.slice(), .big) catch return error.InvalidKey;
    _ = Fe.fromBytes(p_mod, k.qi.slice(), .big) catch return error.InvalidKey;
    _ = Fe.fromBytes(p_mod, k.dp.slice(), .big) catch return error.InvalidKey;
    _ = Fe.fromBytes(q_mod, k.dq.slice(), .big) catch return error.InvalidKey;
    return k;
}

fn ecPublic(kind: Kind, sec1: []const u8) KeyError!Key {
    var k: Key = .{ .kind = kind, .private = false };
    switch (kind) {
        inline .p256, .p384 => |c| {
            const S = if (c == .p256) P256 else P384;
            const pk = S.PublicKey.fromSec1(sec1) catch return error.InvalidKey;
            const raw = pk.toUncompressedSec1();
            @memcpy(k.public[0..raw.len], &raw);
            k.public_len = raw.len;
        },
        else => unreachable,
    }
    return k;
}

/// An EC key from its secret scalar. When `sec1` is given, it must be the
/// public key of that scalar.
fn ecPrivate(kind: Kind, scalar: []const u8, sec1: ?[]const u8) KeyError!Key {
    var k: Key = .{ .kind = kind, .private = true };
    switch (kind) {
        inline .p256, .p384 => |c| {
            const S = if (c == .p256) P256 else P384;
            const len = S.SecretKey.encoded_length;
            if (scalar.len != len) return error.InvalidKey;
            const sk = S.SecretKey.fromBytes(scalar[0..len].*) catch return error.InvalidKey;
            const kp = S.KeyPair.fromSecretKey(sk) catch return error.InvalidKey;
            const raw = kp.public_key.toUncompressedSec1();
            @memcpy(k.public[0..raw.len], &raw);
            k.public_len = raw.len;
            @memcpy(k.secret[0..len], scalar);
            if (sec1) |given| {
                const pk = S.PublicKey.fromSec1(given) catch return error.InvalidKey;
                if (!std.mem.eql(u8, &pk.toUncompressedSec1(), &raw)) return error.InconsistentKey;
            }
        },
        else => unreachable,
    }
    return k;
}

fn edPublic(public: []const u8) KeyError!Key {
    if (public.len != 32) return error.InvalidKey;
    _ = Ed25519.PublicKey.fromBytes(public[0..32].*) catch return error.InvalidKey;
    var k: Key = .{ .kind = .ed25519, .private = false };
    @memcpy(k.public[0..32], public);
    k.public_len = 32;
    return k;
}

pub fn edPrivate(seed: []const u8, public: ?[]const u8) KeyError!Key {
    if (seed.len != 32) return error.InvalidKey;
    const kp = Ed25519.KeyPair.generateDeterministic(seed[0..32].*) catch return error.InvalidKey;
    var k: Key = .{ .kind = .ed25519, .private = true };
    const pk = kp.public_key.toBytes();
    @memcpy(k.public[0..32], &pk);
    k.public_len = 32;
    @memcpy(k.secret[0..32], seed);
    if (public) |given| if (!std.mem.eql(u8, given, &pk)) return error.InconsistentKey;
    return k;
}

/// A new EC key from a 32-byte or 48-byte random seed.
pub fn ecGenerate(kind: Kind, seed: []const u8) KeyError!Key {
    switch (kind) {
        inline .p256, .p384 => |c| {
            const S = if (c == .p256) P256 else P384;
            const kp = S.KeyPair.generateDeterministic(seed[0..S.KeyPair.seed_length].*) catch return error.InvalidKey;
            return ecPrivate(kind, &kp.secret_key.toBytes(), null);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------
// DER

const tag_int = 0x02;
const tag_bits = 0x03;
const tag_octets = 0x04;
const tag_null = 0x05;
const tag_oid = 0x06;
const tag_seq = 0x30;
const tag_ctx0 = 0xa0;
const tag_ctx1 = 0xa1;

const oid_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
const oid_ec = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const oid_p384 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
const oid_ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
const oid_pbes2 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };

/// A reader over the contents of one DER element. Every read checks its
/// bounds, so any input either parses or fails.
const Der = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn done(r: *const Der) bool {
        return r.pos == r.bytes.len;
    }

    fn peek(r: *const Der) ?u8 {
        return if (r.pos < r.bytes.len) r.bytes[r.pos] else null;
    }

    /// The contents of the next element, which must have tag `tag`.
    fn next(r: *Der, tag: u8) KeyError![]const u8 {
        if (r.peek() != tag) return error.InvalidKey;
        return r.any();
    }

    fn any(r: *Der) KeyError![]const u8 {
        const b = r.bytes;
        var i = r.pos + 1;
        if (i >= b.len) return error.InvalidKey;
        var len: usize = b[i];
        i += 1;
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            if (n == 0 or n > 4 or b.len - i < n) return error.InvalidKey;
            len = 0;
            for (b[i..][0..n]) |c| len = (len << 8) | c;
            i += n;
        }
        if (b.len - i < len) return error.InvalidKey;
        r.pos = i + len;
        return b[i..][0..len];
    }

    fn seq(r: *Der) KeyError!Der {
        return .{ .bytes = try r.next(tag_seq) };
    }

    /// A non-negative INTEGER, without its leading zero bytes.
    fn uint(r: *Der) KeyError![]const u8 {
        const c = try r.next(tag_int);
        if (c.len == 0 or c[0] & 0x80 != 0) return error.InvalidKey;
        var s = c;
        while (s.len > 0 and s[0] == 0) s = s[1..];
        return s;
    }

    fn small(r: *Der) KeyError!u8 {
        const s = try r.uint();
        if (s.len > 1) return error.InvalidKey;
        return if (s.len == 0) 0 else s[0];
    }

    /// A BIT STRING with no unused bits.
    fn bitString(r: *Der) KeyError![]const u8 {
        const c = try r.next(tag_bits);
        if (c.len == 0 or c[0] != 0) return error.InvalidKey;
        return c[1..];
    }
};

/// An AlgorithmIdentifier: the algorithm and, for EC keys, the curve.
fn algorithm(r: *Der) KeyError!Kind {
    var a = try r.seq();
    const oid = try a.next(tag_oid);
    if (std.mem.eql(u8, oid, &oid_rsa)) return .rsa;
    if (std.mem.eql(u8, oid, &oid_ed25519)) return .ed25519;
    if (std.mem.eql(u8, oid, &oid_ec)) return curveOf(try a.next(tag_oid));
    if (std.mem.eql(u8, oid, &oid_pbes2)) return error.EncryptedKey;
    return error.UnsupportedKey;
}

fn curveOf(oid: []const u8) KeyError!Kind {
    if (std.mem.eql(u8, oid, &oid_p256)) return .p256;
    if (std.mem.eql(u8, oid, &oid_p384)) return .p384;
    return error.UnsupportedKey;
}

/// RSAPublicKey of PKCS#1, whose contents `r` reads.
fn pkcs1Public(r: *Der) KeyError!Key {
    const n = try r.uint();
    const e = try r.uint();
    if (!r.done()) return error.InvalidKey;
    return rsaPublic(n, e);
}

/// RSAPrivateKey of PKCS#1, after its version.
fn pkcs1Private(r: *Der, version: u8) KeyError!Key {
    // Version 1 adds more primes, which the CRT here does not cover.
    if (version != 0) return error.UnsupportedKey;
    var parts: RsaPrivateParts = undefined;
    inline for (.{ "n", "e", "d", "p", "q", "dp", "dq", "qi" }) |f| @field(parts, f) = try r.uint();
    return rsaPrivate(parts);
}

/// ECPrivateKey of SEC1, after its version. `curve` comes from the
/// enclosing PKCS#8 structure, or else from the key itself.
fn sec1Private(r: *Der, version: u8, curve: ?Kind) KeyError!Key {
    if (version != 1) return error.InvalidKey;
    const scalar = try r.next(tag_octets);
    var kind = curve;
    var public: ?[]const u8 = null;
    if (r.peek() == tag_ctx0) {
        var p: Der = .{ .bytes = try r.any() };
        const named = try curveOf(try p.next(tag_oid));
        if (kind != null and kind.? != named) return error.InconsistentKey;
        kind = named;
    }
    if (r.peek() == tag_ctx1) {
        var p: Der = .{ .bytes = try r.any() };
        public = try p.bitString();
    }
    return ecPrivate(kind orelse return error.InvalidKey, scalar, public);
}

/// PrivateKeyInfo of PKCS#8 (versions 1 and 2), after its version.
fn pkcs8(r: *Der) KeyError!Key {
    const kind = try algorithm(r);
    var inner: Der = .{ .bytes = try r.next(tag_octets) };
    switch (kind) {
        .rsa => {
            var s = try inner.seq();
            return pkcs1Private(&s, try s.small());
        },
        .p256, .p384 => {
            var s = try inner.seq();
            return sec1Private(&s, try s.small(), kind);
        },
        .ed25519 => return edPrivate(try inner.next(tag_octets), null),
    }
}

/// SubjectPublicKeyInfo, after its outer SEQUENCE.
fn spki(r: *Der) KeyError!Key {
    const kind = try algorithm(r);
    const bits = try r.bitString();
    switch (kind) {
        .rsa => {
            var k: Der = .{ .bytes = bits };
            var s = try k.seq();
            return pkcs1Public(&s);
        },
        .p256, .p384 => return ecPublic(kind, bits),
        .ed25519 => return edPublic(bits),
    }
}

/// A key in any of the DER layouts, told apart by their first fields.
pub fn fromDer(bytes: []const u8) KeyError!Key {
    var top: Der = .{ .bytes = bytes };
    var r = try top.seq();
    if (!top.done()) return error.InvalidKey;
    switch (r.peek() orelse return error.InvalidKey) {
        tag_seq => {
            // EncryptedPrivateKeyInfo starts with an AlgorithmIdentifier
            // of PBES2, which `algorithm` reports.
            return spki(&r);
        },
        tag_int => {
            const first = try r.uint();
            switch (r.peek() orelse return error.InvalidKey) {
                tag_seq => return pkcs8(&r),
                tag_octets => return sec1Private(&r, if (first.len == 1) first[0] else 0, null),
                tag_int => {
                    // Two integers make an RSAPublicKey, more make an
                    // RSAPrivateKey that starts with its version.
                    var probe = r;
                    _ = try probe.uint();
                    if (probe.done()) {
                        var again: Der = .{ .bytes = r.bytes };
                        return pkcs1Public(&again);
                    }
                    if (first.len > 1) return error.InvalidKey;
                    return pkcs1Private(&r, if (first.len == 1) first[0] else 0);
                },
                else => return error.InvalidKey,
            }
        },
        else => return error.InvalidKey,
    }
}

/// Appends one DER element with the given tag and contents.
fn put(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: u8, contents: []const u8) !void {
    try out.append(gpa, tag);
    const n = contents.len;
    if (n < 0x80) {
        try out.append(gpa, @intCast(n));
    } else if (n < 0x100) {
        try out.appendSlice(gpa, &.{ 0x81, @intCast(n) });
    } else {
        try out.appendSlice(gpa, &.{ 0x82, @intCast(n >> 8), @truncate(n) });
    }
    try out.appendSlice(gpa, contents);
}

fn putUint(out: *std.ArrayList(u8), gpa: std.mem.Allocator, x: []const u8) !void {
    var buf: [513]u8 = undefined;
    var len: usize = 0;
    if (x.len == 0 or x[0] & 0x80 != 0) {
        buf[0] = 0;
        len = 1;
    }
    @memcpy(buf[len..][0..x.len], x);
    try put(out, gpa, tag_int, buf[0 .. len + x.len]);
}

fn putBits(out: *std.ArrayList(u8), gpa: std.mem.Allocator, x: []const u8) !void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    try tmp.append(gpa, 0);
    try tmp.appendSlice(gpa, x);
    try put(out, gpa, tag_bits, tmp.items);
}

/// Wraps what `out` holds from `start` on in an element with tag `tag`.
fn wrap(out: *std.ArrayList(u8), gpa: std.mem.Allocator, start: usize, tag: u8) !void {
    const inner = try gpa.dupe(u8, out.items[start..]);
    defer gpa.free(inner);
    out.shrinkRetainingCapacity(start);
    try put(out, gpa, tag, inner);
}

fn putAlgorithm(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: Kind) !void {
    const start = out.items.len;
    switch (kind) {
        .rsa => {
            try put(out, gpa, tag_oid, &oid_rsa);
            try put(out, gpa, tag_null, "");
        },
        .p256, .p384 => {
            try put(out, gpa, tag_oid, &oid_ec);
            try put(out, gpa, tag_oid, if (kind == .p256) &oid_p256 else &oid_p384);
        },
        .ed25519 => try put(out, gpa, tag_oid, &oid_ed25519),
    }
    try wrap(out, gpa, start, tag_seq);
}

/// The key as PKCS#8 when it is private and as SubjectPublicKeyInfo when
/// it is public, the layouts that `openssl pkey` writes.
pub fn toDer(k: *const Key, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    const start = out.items.len;
    if (k.private) {
        try putUint(out, gpa, "");
        try putAlgorithm(out, gpa, k.kind);
        const inner = out.items.len;
        switch (k.kind) {
            .rsa => {
                try putUint(out, gpa, "");
                inline for (.{ "n", "e", "d", "p", "q", "dp", "dq", "qi" }) |f| try putUint(out, gpa, @field(k, f).slice());
                try wrap(out, gpa, inner, tag_seq);
            },
            .p256, .p384 => {
                try putUint(out, gpa, "\x01");
                try put(out, gpa, tag_octets, k.secretBytes());
                const pub_start = out.items.len;
                try putBits(out, gpa, k.publicBytes());
                try wrap(out, gpa, pub_start, tag_ctx1);
                try wrap(out, gpa, inner, tag_seq);
            },
            .ed25519 => try put(out, gpa, tag_octets, k.secretBytes()),
        }
        try wrap(out, gpa, inner, tag_octets);
    } else {
        try putAlgorithm(out, gpa, k.kind);
        switch (k.kind) {
            .rsa => {
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(gpa);
                try putUint(&tmp, gpa, k.n.slice());
                try putUint(&tmp, gpa, k.e.slice());
                try wrap(&tmp, gpa, 0, tag_seq);
                try putBits(out, gpa, tmp.items);
            },
            else => try putBits(out, gpa, k.publicBytes()),
        }
    }
    try wrap(out, gpa, start, tag_seq);
}

// ---------------------------------------------------------------------
// PEM

/// The first key in PEM text. Blocks of EC parameters, which `openssl
/// ecparam -genkey` writes before the key, are skipped.
pub fn fromPem(gpa: std.mem.Allocator, text: []const u8) KeyError!Key {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "-----BEGIN ")) |b| {
        const after = rest[b + 11 ..];
        const label_end = std.mem.indexOf(u8, after, "-----") orelse return error.InvalidKey;
        const label = after[0..label_end];
        const body_start = after[label_end + 5 ..];
        var end_buf: [80]u8 = undefined;
        const end_marker = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label}) catch return error.InvalidKey;
        const e = std.mem.indexOf(u8, body_start, end_marker) orelse return error.InvalidKey;
        const body = body_start[0..e];
        rest = body_start[e + end_marker.len ..];
        if (std.mem.eql(u8, label, "EC PARAMETERS")) continue;
        if (std.mem.eql(u8, label, "ENCRYPTED PRIVATE KEY")) return error.EncryptedKey;
        // Legacy encrypted PEM carries headers such as Proc-Type.
        if (std.mem.indexOfScalar(u8, body, ':') != null) return error.EncryptedKey;
        const known = [_][]const u8{ "PRIVATE KEY", "PUBLIC KEY", "RSA PRIVATE KEY", "RSA PUBLIC KEY", "EC PRIVATE KEY" };
        for (known) |k| {
            if (std.mem.eql(u8, label, k)) break;
        } else return error.UnsupportedKey;
        const der = try decodeBase64(gpa, body, base64.standard_no_pad.Decoder);
        defer gpa.free(der);
        return fromDer(der);
    }
    return error.InvalidKey;
}

/// Decodes base64, skipping white space and trailing padding.
fn decodeBase64(gpa: std.mem.Allocator, text: []const u8, dec: base64.Base64Decoder) KeyError![]u8 {
    var clean = std.ArrayList(u8).initCapacity(gpa, text.len) catch return error.OutOfMemory;
    defer clean.deinit(gpa);
    for (text) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => clean.appendAssumeCapacity(c),
    };
    var s = clean.items;
    while (s.len > 0 and s[s.len - 1] == '=') s = s[0 .. s.len - 1];
    const n = dec.calcSizeForSlice(s) catch return error.InvalidKey;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    dec.decode(out, s) catch return error.InvalidKey;
    return out;
}

pub fn toPem(k: *const Key, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    var der: std.ArrayList(u8) = .empty;
    defer der.deinit(gpa);
    try toDer(k, gpa, &der);
    const label = if (k.private) "PRIVATE KEY" else "PUBLIC KEY";
    try out.print(gpa, "-----BEGIN {s}-----\n", .{label});
    const enc = base64.standard.Encoder;
    var i: usize = 0;
    while (i < der.items.len) : (i += 48) {
        const chunk = der.items[i..@min(i + 48, der.items.len)];
        var buf: [64]u8 = undefined;
        try out.appendSlice(gpa, enc.encode(&buf, chunk));
        try out.append(gpa, '\n');
    }
    try out.print(gpa, "-----END {s}-----\n", .{label});
}

// ---------------------------------------------------------------------
// JWK (RFC 7517 and RFC 7518)

/// The members of a JWK that name or hold key material, as base64url text.
pub const Jwk = struct {
    kty: ?[]const u8 = null,
    crv: ?[]const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
    d: ?[]const u8 = null,
    p: ?[]const u8 = null,
    q: ?[]const u8 = null,
    dp: ?[]const u8 = null,
    dq: ?[]const u8 = null,
    qi: ?[]const u8 = null,
    x: ?[]const u8 = null,
    y: ?[]const u8 = null,
};

pub const jwk_fields = [_][]const u8{ "kty", "crv", "n", "e", "d", "p", "q", "dp", "dq", "qi", "x", "y" };

/// A JWK given as JSON text.
pub fn jwkFromJson(gpa: std.mem.Allocator, text: []const u8) KeyError!Key {
    const parsed = std.json.parseFromSlice(Jwk, gpa, text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidKey,
    };
    defer parsed.deinit();
    return fromJwk(gpa, parsed.value);
}

pub fn fromJwk(gpa: std.mem.Allocator, j: Jwk) KeyError!Key {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const D = struct {
        fn get(a: std.mem.Allocator, field: ?[]const u8) KeyError![]const u8 {
            return decodeBase64(a, field orelse return error.InvalidKey, base64.url_safe_no_pad.Decoder);
        }
        fn opt(a: std.mem.Allocator, field: ?[]const u8) KeyError!?[]const u8 {
            if (field == null) return null;
            return try get(a, field);
        }
    };
    const kty = j.kty orelse return error.InvalidKey;
    if (std.mem.eql(u8, kty, "RSA")) {
        const n = try D.get(arena, j.n);
        const e = try D.get(arena, j.e);
        if (j.d == null) return rsaPublic(n, e);
        return rsaPrivate(.{
            .n = n,
            .e = e,
            .d = try D.get(arena, j.d),
            .p = try D.get(arena, j.p),
            .q = try D.get(arena, j.q),
            .dp = try D.get(arena, j.dp),
            .dq = try D.get(arena, j.dq),
            .qi = try D.get(arena, j.qi),
        });
    }
    if (!std.mem.eql(u8, kty, "EC") and !std.mem.eql(u8, kty, "OKP")) return error.UnsupportedKey;
    const crv = j.crv orelse return error.InvalidKey;
    if (std.mem.eql(u8, kty, "EC")) {
        const kind: Kind = if (std.mem.eql(u8, crv, "P-256")) .p256 else if (std.mem.eql(u8, crv, "P-384")) .p384 else return error.UnsupportedKey;
        const len = scalarLen(kind);
        const x = try D.get(arena, j.x);
        const y = try D.get(arena, j.y);
        if (x.len != len or y.len != len) return error.InvalidKey;
        var sec1: [97]u8 = undefined;
        sec1[0] = 4;
        @memcpy(sec1[1..][0..len], x);
        @memcpy(sec1[1 + len ..][0..len], y);
        const point = sec1[0 .. 1 + 2 * len];
        if (try D.opt(arena, j.d)) |d| return ecPrivate(kind, d, point);
        return ecPublic(kind, point);
    }
    if (std.mem.eql(u8, kty, "OKP")) {
        if (!std.mem.eql(u8, crv, "Ed25519")) return error.UnsupportedKey;
        const x = try D.get(arena, j.x);
        if (try D.opt(arena, j.d)) |d| return edPrivate(d, x);
        return edPublic(x);
    }
    unreachable;
}

/// The members of the JWK of a key, as names and base64url text. The text
/// lives in `buf`, so the value stays where `toJwk` filled it.
pub const JwkOut = struct {
    names: [12][]const u8 = undefined,
    values: [12][]const u8 = undefined,
    len: usize = 0,
    /// Room for the eight members of an RSA-4096 private key, each of
    /// which takes at most 683 characters.
    buf: [6144]u8 = undefined,
    used: usize = 0,

    fn add(o: *JwkOut, name: []const u8, text: []const u8) void {
        o.names[o.len] = name;
        o.values[o.len] = text;
        o.len += 1;
    }

    fn addBytes(o: *JwkOut, name: []const u8, bytes: []const u8) void {
        const s = base64.url_safe_no_pad.Encoder.encode(o.buf[o.used..], bytes);
        o.used += s.len;
        o.add(name, s);
    }
};

pub fn toJwk(k: *const Key, o: *JwkOut) void {
    o.* = .{};
    switch (k.kind) {
        .rsa => {
            o.add("kty", "RSA");
            o.addBytes("n", k.n.slice());
            o.addBytes("e", k.e.slice());
            if (k.private) {
                inline for (.{ "d", "p", "q", "dp", "dq", "qi" }) |f| o.addBytes(f, @field(k, f).slice());
            }
        },
        .p256, .p384 => {
            const len = scalarLen(k.kind);
            o.add("kty", "EC");
            o.add("crv", curveName(k.kind));
            o.addBytes("x", k.public[1..][0..len]);
            o.addBytes("y", k.public[1 + len ..][0..len]);
            if (k.private) o.addBytes("d", k.secretBytes());
        },
        .ed25519 => {
            o.add("kty", "OKP");
            o.add("crv", "Ed25519");
            o.addBytes("x", k.publicBytes());
            if (k.private) o.addBytes("d", k.secretBytes());
        },
    }
}

// ---------------------------------------------------------------------
// Signatures

/// The JOSE algorithm names (RFC 7518 and RFC 8037).
pub const Algorithm = enum { EdDSA, ES256, ES384, RS256, RS384, RS512, PS256, PS384, PS512 };
pub const algorithm_names = [_][]const u8{ "EdDSA", "ES256", "ES384", "RS256", "RS384", "RS512", "PS256", "PS384", "PS512" };

/// The algorithm a key implies, or null for RSA, which signs with both
/// families.
pub fn impliedAlgorithm(kind: Kind) ?Algorithm {
    return switch (kind) {
        .ed25519 => .EdDSA,
        .p256 => .ES256,
        .p384 => .ES384,
        .rsa => null,
    };
}

pub fn fits(kind: Kind, alg: Algorithm) bool {
    return switch (alg) {
        .EdDSA => kind == .ed25519,
        .ES256 => kind == .p256,
        .ES384 => kind == .p384,
        else => kind == .rsa,
    };
}

pub const SignError = error{ InvalidKey, SignatureCheckFailed, OutOfMemory };

/// The largest signature: an RSA signature of a 4096-bit key.
pub const max_signature = 512;

/// Signs `msg` with the private key `k` under `alg`, which fits the key.
/// `noise` is random input: ECDSA mixes it into its nonce, and RSA-PSS
/// takes its salt from it.
pub fn sign(k: *const Key, alg: Algorithm, msg: []const u8, noise: *const [64]u8, out: *[max_signature]u8) SignError![]const u8 {
    switch (alg) {
        .EdDSA => {
            const kp = Ed25519.KeyPair.generateDeterministic(k.secret[0..32].*) catch return error.InvalidKey;
            const sig = kp.sign(msg, null) catch return error.InvalidKey;
            out[0..64].* = sig.toBytes();
            return out[0..64];
        },
        inline .ES256, .ES384 => |a| {
            const S = if (a == .ES256) P256 else P384;
            const len = S.SecretKey.encoded_length;
            const sk = S.SecretKey.fromBytes(k.secret[0..len].*) catch return error.InvalidKey;
            const kp = S.KeyPair.fromSecretKey(sk) catch return error.InvalidKey;
            const sig = kp.sign(msg, noise[0..S.noise_length].*) catch return error.InvalidKey;
            const raw = sig.toBytes();
            @memcpy(out[0..raw.len], &raw);
            return out[0..raw.len];
        },
        inline else => |a| {
            const H = rsaHash(a);
            const pss = comptime std.mem.startsWith(u8, @tagName(a), "PS");
            return switch (k.n.len) {
                inline 256, 384, 512 => |len| rsaSign(len, k, H, pss, msg, noise[0..H.digest_length], out),
                else => error.InvalidKey,
            };
        },
    }
}

/// True when `sig` is a valid signature of `msg` by the key `k`.
pub fn verify(k: *const Key, alg: Algorithm, msg: []const u8, sig: []const u8) bool {
    switch (alg) {
        .EdDSA => {
            if (sig.len != 64) return false;
            const pk = Ed25519.PublicKey.fromBytes(k.public[0..32].*) catch return false;
            Ed25519.Signature.fromBytes(sig[0..64].*).verifyStrict(msg, pk) catch return false;
            return true;
        },
        inline .ES256, .ES384 => |a| {
            const S = if (a == .ES256) P256 else P384;
            if (sig.len != S.Signature.encoded_length) return false;
            const pk = S.PublicKey.fromSec1(k.publicBytes()) catch return false;
            S.Signature.fromBytes(sig[0..S.Signature.encoded_length].*).verify(msg, pk) catch return false;
            return true;
        },
        inline else => |a| {
            const H = rsaHash(a);
            const pss = comptime std.mem.startsWith(u8, @tagName(a), "PS");
            return switch (k.n.len) {
                inline 256, 384, 512 => |len| rsaVerify(len, k, H, pss, msg, sig),
                else => false,
            };
        },
    }
}

fn rsaHash(comptime a: Algorithm) type {
    return switch (a) {
        .RS256, .PS256 => Sha256,
        .RS384, .PS384 => Sha384,
        .RS512, .PS512 => Sha512,
        else => unreachable,
    };
}

fn rsaVerify(comptime len: usize, k: *const Key, comptime H: type, comptime pss: bool, msg: []const u8, sig: []const u8) bool {
    if (sig.len != len) return false;
    const pk = rsa.PublicKey.fromBytes(k.e.slice(), k.n.slice()) catch return false;
    if (pss) {
        rsa.PSSSignature.verify(len, sig[0..len], msg, pk, H) catch return false;
    } else {
        rsa.PKCS1v1_5Signature.verify(len, sig[0..len], msg, pk, H) catch return false;
    }
    return true;
}

/// The DER prefix of the DigestInfo of EMSA-PKCS1-v1_5 (RFC 8017, section
/// 9.2, note 1).
fn digestInfo(comptime H: type) []const u8 {
    return switch (H) {
        Sha256 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        Sha384 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
        Sha512 => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        else => unreachable,
    };
}

/// EMSA-PKCS1-v1_5-ENCODE (RFC 8017, section 9.2) into `em`, which is as
/// long as the modulus.
fn encodePkcs1(comptime H: type, msg: []const u8, em: []u8) void {
    const t = digestInfo(H);
    const h_start = em.len - H.digest_length;
    H.hash(msg, em[h_start..][0..H.digest_length], .{});
    const t_start = h_start - t.len;
    @memcpy(em[t_start..h_start], t);
    em[0] = 0;
    em[1] = 1;
    @memset(em[2 .. t_start - 1], 0xff);
    em[t_start - 1] = 0;
}

/// MGF1 (RFC 8017, appendix B.2.1): XORs the mask of `seed` into `out`.
fn mgf1Xor(comptime H: type, seed: []const u8, out: []u8) void {
    var counter: u32 = 0;
    var i: usize = 0;
    while (i < out.len) : (counter += 1) {
        var h = H.init(.{});
        h.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        h.update(&c);
        var block: [H.digest_length]u8 = undefined;
        h.final(&block);
        const n = @min(block.len, out.len - i);
        for (out[i..][0..n], block[0..n]) |*o, b| o.* ^= b;
        i += n;
    }
}

/// EMSA-PSS-ENCODE (RFC 8017, section 9.1.1) with a salt as long as the
/// digest, the length JOSE fixes. `em` is as long as the modulus, and its
/// first byte is zero when `em_bits` leaves no room for it.
fn encodePss(comptime H: type, msg: []const u8, salt: []const u8, em_bits: usize, em_full: []u8) void {
    const h_len = H.digest_length;
    const em_len = (em_bits + 7) / 8;
    @memset(em_full[0 .. em_full.len - em_len], 0);
    const em = em_full[em_full.len - em_len ..];
    var m_hash: [h_len]u8 = undefined;
    H.hash(msg, &m_hash, .{});
    var h = H.init(.{});
    const zeros: [8]u8 = @splat(0);
    h.update(&zeros);
    h.update(&m_hash);
    h.update(salt);
    const db_len = em_len - h_len - 1;
    const db = em[0..db_len];
    h.final(em[db_len..][0..h_len]);
    @memset(db[0 .. db_len - salt.len - 1], 0);
    db[db_len - salt.len - 1] = 1;
    @memcpy(db[db_len - salt.len ..], salt);
    mgf1Xor(H, em[db_len..][0..h_len], db);
    const unused: u3 = @intCast(8 * em_len - em_bits);
    db[0] &= @as(u8, 0xff) >> unused;
    em[em_len - 1] = 0xbc;
}

/// The RSA signature of `msg`: the encoded message raised to the private
/// exponent through the Chinese remainder theorem (RFC 8017, section
/// 5.1.2), then checked with std's verifier, so that a fault or a key whose
/// parts do not match never releases a signature.
fn rsaSign(comptime len: usize, k: *const Key, comptime H: type, comptime pss: bool, msg: []const u8, salt: []const u8, out: *[max_signature]u8) SignError![]const u8 {
    var em: [len]u8 = undefined;
    if (pss) {
        if (len < H.digest_length * 2 + 2) return error.InvalidKey;
        encodePss(H, msg, salt, k.bits() - 1, &em);
    } else {
        encodePkcs1(H, msg, &em);
    }
    defer std.crypto.secureZero(u8, &em);

    const n = Modulus.fromBytes(k.n.slice(), .big) catch return error.InvalidKey;
    const p = Modulus.fromBytes(k.p.slice(), .big) catch return error.InvalidKey;
    const q = Modulus.fromBytes(k.q.slice(), .big) catch return error.InvalidKey;
    const m = Fe.fromBytes(n, &em, .big) catch return error.InvalidKey;

    // s1 = m^dp mod p and s2 = m^dq mod q.
    const s1 = p.powWithEncodedExponent(p.reduce(m.v), k.dp.slice(), .big) catch return error.InvalidKey;
    const s2 = q.powWithEncodedExponent(q.reduce(m.v), k.dq.slice(), .big) catch return error.InvalidKey;
    // h = qi * (s1 - s2) mod p, and s = s2 + q * h, which is below n.
    const qi = Fe.fromBytes(p, k.qi.slice(), .big) catch return error.InvalidKey;
    const h = p.mul(qi, p.sub(s1, p.reduce(s2.v)));
    var buf: [512]u8 = undefined;
    const s = n.add(try lift(n, q, s2, &buf), n.mul(try lift(n, q, q.toUint(), &buf), try lift(n, p, h, &buf)));

    const sig = out[0..len];
    s.toBytes(sig, .big) catch return error.InvalidKey;
    if (!rsaVerify(len, k, H, pss, msg, sig)) return error.SignatureCheckFailed;
    return sig;
}

/// A value below the modulus `from`, as an element of `n`.
fn lift(n: Modulus, from: Modulus, x: anytype, buf: *[512]u8) SignError!Fe {
    const bytes = buf[0..from.encodedLen()];
    x.toBytes(bytes, .big) catch return error.InvalidKey;
    return Fe.fromBytes(n, bytes, .big) catch error.InvalidKey;
}

test "PKCS#1 v1.5 encoding matches the verifier" {
    var em: [256]u8 = undefined;
    encodePkcs1(Sha256, "abc", &em);
    try std.testing.expectEqual(@as(u8, 0), em[0]);
    try std.testing.expectEqual(@as(u8, 1), em[1]);
    try std.testing.expectEqual(@as(u8, 0xff), em[2]);
    try std.testing.expectEqual(@as(u8, 0), em[256 - 32 - 19 - 1]);
}

test "DER reader rejects truncated input" {
    try std.testing.expectError(error.InvalidKey, fromDer(&.{0x30}));
    try std.testing.expectError(error.InvalidKey, fromDer(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff }));
    try std.testing.expectError(error.InvalidKey, fromDer(&.{ 0x30, 0x02, 0x02 }));
    try std.testing.expectError(error.InvalidKey, fromDer(""));
}

test "Ed25519 keys round trip through DER" {
    const seed: [32]u8 = @splat(7);
    const k = try edPrivate(&seed, null);
    var der: std.ArrayList(u8) = .empty;
    defer der.deinit(std.testing.allocator);
    try toDer(&k, std.testing.allocator, &der);
    const back = try fromDer(der.items);
    try std.testing.expect(back.private);
    try std.testing.expectEqualSlices(u8, k.secretBytes(), back.secretBytes());
    const pub_k = k.toPublic();
    der.clearRetainingCapacity();
    try toDer(&pub_k, std.testing.allocator, &der);
    const back2 = try fromDer(der.items);
    try std.testing.expect(!back2.private);
    try std.testing.expectEqualSlices(u8, k.publicBytes(), back2.publicBytes());
}
