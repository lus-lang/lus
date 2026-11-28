//! The `crypto` library: SHA-2, SHA-1, and MD5 digests, HMAC, PBKDF2 and
//! HKDF, AES-256-GCM, Ed25519, ECDSA, and RSA signatures, secure random
//! bytes, constant-time comparison, Argon2id password hashing, and UUID
//! and ULID generation (spec/design/crypto.md).
//!
//! Every primitive comes from `std.crypto`. This file checks arguments,
//! converts between Lus values and bytes, and writes the text forms of
//! UUIDs and ULIDs. `cryptokey.zig` holds the key formats and RSA signing.
//! Digests, keys, and signatures are vectors, because they are raw bytes
//! (spec/design/strings.md).

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const tables = @import("../vm/table.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const ckey = @import("cryptokey.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha1 = std.crypto.hash.Sha1;
const Md5 = std.crypto.hash.Md5;
const Hmac = std.crypto.auth.hmac.Hmac;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
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
    .{ .name = "pbkdf2", .func = pbkdf2 },
    .{ .name = "hkdf", .func = hkdf },
    .{ .name = "encrypt", .func = encrypt },
    .{ .name = "decrypt", .func = decrypt },
    .{ .name = "importkey", .func = importkey },
};

const hasher_key = "crypto.hasher";

const hasher_methods = [_]aux.Reg{
    .{ .name = "update", .func = hasherUpdate },
    .{ .name = "digest", .func = hasherDigest },
};

const key_key = "crypto.key";
const key_methods_key = "crypto.key.methods";

const key_methods = [_]aux.Reg{
    .{ .name = "public", .func = keyPublic },
    .{ .name = "export", .func = keyExport },
};

pub fn open(l: *Thread) Error!void {
    try openKey(l);
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

const Algorithm = enum { sha256, sha384, sha512, sha1, md5 };
const algorithm_names = [_][]const u8{ "sha256", "sha384", "sha512", "sha1", "md5" };

fn HashOf(comptime a: Algorithm) type {
    return switch (a) {
        .sha256 => Sha256,
        .sha384 => Sha384,
        .sha512 => Sha512,
        .sha1 => Sha1,
        .md5 => Md5,
    };
}

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
    switch (alg) {
        inline else => |a| {
            const H = HashOf(a);
            var out: [H.digest_length]u8 = undefined;
            H.hash(data, &out, .{});
            return retBytes(l, &out);
        },
    }
}

/// The state of a streaming digest, the payload of a `crypto.hasher`
/// userdata. It holds no heap memory, so the userdata needs no finalizer.
const Hasher = union(Algorithm) {
    sha256: Sha256,
    sha384: Sha384,
    sha512: Sha512,
    sha1: Sha1,
    md5: Md5,
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
        inline else => |a| @unionInit(Hasher, @tagName(a), HashOf(a).init(.{})),
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
            const H = Hmac(HashOf(a));
            H.create(out[0..H.mac_length], data, key);
            break :blk H.mac_length;
        },
    };
    return retBytes(l, out[0..n]);
}

// ---------------------------------------------------------------------
// Random bytes and comparison

/// The bytes one read of the random source fills. Some sources cap a
/// single request, so a large vector fills in pieces of this size.
const random_chunk = 1 << 20;

fn random(l: *Thread) Error!u32 {
    const n = try aux.checkInt(l, 1);
    if (n < 0) return aux.argError(l, 1, "size must be non-negative", .{});
    const len = std.math.cast(usize, n) orelse return l.raiseMem();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(l.g.gpa);
    list.resize(l.g.gpa, len) catch return l.raiseMem();
    var i: usize = 0;
    while (i < len) : (i += random_chunk) {
        try secureRandom(l, list.items[i..@min(i + random_chunk, len)]);
    }
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
    const v = l.arg(1);
    if (v.tag == .string) {
        const kind: ckey.Kind = switch (try aux.checkOption(l, 1, null, &.{ "P-256", "P-384" })) {
            0 => .p256,
            else => .p384,
        };
        var rnd: [64]u8 = undefined;
        try secureRandom(l, &rnd);
        defer std.crypto.secureZero(u8, &rnd);
        const k = ckey.ecGenerate(kind, &rnd) catch |e| return keyError(l, e);
        try l.push(try newKey(l, k));
        try l.push(try newKey(l, k.toPublic()));
        return 2;
    }
    if (v.isNil()) {
        try secureRandom(l, &seed);
    } else {
        seed = (try checkSized(l, 1, 32)).*;
    }
    const kp = try keyPairOf(l, seed);
    try l.push(Value.obj(.vector, try vector.newVector(l, &seed)));
    try l.push(Value.obj(.vector, try vector.newVector(l, &kp.public_key.toBytes())));
    return 2;
}

/// The algorithm argument `i` of `sign` or `verify` for the key `k`.
fn keyAlgorithm(l: *Thread, i: u32, k: *const ckey.Key) Error!ckey.Algorithm {
    if (l.arg(i).isNil()) {
        return ckey.impliedAlgorithm(k.kind) orelse aux.argError(l, i, "RSA key requires an algorithm", .{});
    }
    const alg: ckey.Algorithm = @fromBackingInt(@intCast(try aux.checkOption(l, i, null, &ckey.algorithm_names)));
    if (!ckey.fits(k.kind, alg)) return aux.argError(l, i, "algorithm '{s}' does not fit {s} key", .{ @tagName(alg), kindPhrase(k.kind) });
    return alg;
}

fn kindPhrase(kind: ckey.Kind) []const u8 {
    return switch (kind) {
        .rsa => "an RSA",
        .p256 => "a P-256",
        .p384 => "a P-384",
        .ed25519 => "an Ed25519",
    };
}

/// For a 32-byte vector key, checks that an algorithm argument, if any,
/// names Ed25519.
fn checkEdAlgorithm(l: *Thread, i: u32) Error!void {
    if (l.arg(i).isNil()) return;
    const alg: ckey.Algorithm = @fromBackingInt(@intCast(try aux.checkOption(l, i, null, &ckey.algorithm_names)));
    if (alg != .EdDSA) return aux.argError(l, i, "algorithm '{s}' does not fit an Ed25519 key", .{@tagName(alg)});
}

fn sign(l: *Thread) Error!u32 {
    if (l.arg(1).tag == .vector) {
        const seed = try checkSized(l, 1, 32);
        const msg = try vector.checkData(l, 2);
        try checkEdAlgorithm(l, 3);
        const kp = try keyPairOf(l, seed.*);
        const sig = kp.sign(msg, null) catch return l.raiseFmt("invalid Ed25519 key", .{});
        return retBytes(l, &sig.toBytes());
    }
    const k = try checkKey(l, 1);
    if (!k.private) return aux.argError(l, 1, "private key expected", .{});
    const msg = try vector.checkData(l, 2);
    const alg = try keyAlgorithm(l, 3, k);
    var noise: [64]u8 = undefined;
    try secureRandom(l, &noise);
    defer std.crypto.secureZero(u8, &noise);
    var out: [ckey.max_signature]u8 = undefined;
    const sig = ckey.sign(k, alg, msg, &noise, &out) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.SignatureCheckFailed => return l.raiseFmt("RSA signature failed its verification check", .{}),
        error.InvalidKey => return l.raiseFmt("invalid key", .{}),
    };
    return retBytes(l, sig);
}

fn verify(l: *Thread) Error!u32 {
    if (l.arg(1).tag == .vector) {
        const public = try checkSized(l, 1, 32);
        const msg = try vector.checkData(l, 2);
        const sig_bytes = try checkSized(l, 3, 64);
        try checkEdAlgorithm(l, 4);
        return aux.retBool(l, ed25519Verify(public.*, msg, sig_bytes.*));
    }
    const k = try checkKey(l, 1);
    const msg = try vector.checkData(l, 2);
    const sig = try vector.checkData(l, 3);
    const alg = try keyAlgorithm(l, 4, k);
    return aux.retBool(l, ckey.verify(k, alg, msg, sig));
}

// ---------------------------------------------------------------------
// Key objects

fn openKey(l: *Thread) Error!void {
    const mt = try l.newTable(0, 4);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setField(l, l.g.registry.as(Table), key_key, Value.obj(.table, mt));
    const m = try aux.newLib(l, .methods, "crypto:key", &key_methods);
    try aux.setField(l, l.g.registry.as(Table), key_methods_key, Value.obj(.table, m));
    try aux.setField(l, mt, "__index", try aux.native(l, keyIndex, "index"));
    try aux.setField(l, mt, "__tostring", try aux.native(l, keyToString, "tostring"));
    try aux.setField(l, mt, "__gc", try aux.native(l, keyGc, "gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue(key_key));
    try aux.setField(l, mt, "__metatable", .false);
    l.g.ext.put(l.g.gpa, key_key, mt) catch return l.raiseMem();
    l.g.ext.put(l.g.gpa, key_methods_key, m) catch return l.raiseMem();
}

fn extTable(l: *Thread, name: []const u8) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(name).?));
}

/// Clears the bytes of a key that the collector frees, so a private key
/// stays in memory no longer than its object.
fn keyGc(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.tag != .userdata) return 0;
    const u = v.as(Userdata);
    if (u.metatable != extTable(l, key_key) or u.size != @sizeOf(ckey.Key)) return 0;
    std.crypto.secureZero(u8, u.data()[0..u.size]);
    return 0;
}

/// A new `crypto.key` userdata holding `k`. A private key registers a
/// finalizer that clears its bytes.
fn newKey(l: *Thread, k: ckey.Key) Error!Value {
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(ckey.Key), 0)) catch return l.raiseMem();
    u.size = @sizeOf(ckey.Key);
    u.nuser = 0;
    u.metatable = extTable(l, key_key);
    const p: *ckey.Key = @ptrCast(@alignCast(u.data()));
    p.* = k;
    if (k.private) {
        try l.push(Value.obj(.userdata, u));
        defer l.top -= 1;
        try @import("base.zig").registerFinalizer(l, &u.hdr, u.metatable.?);
    }
    return Value.obj(.userdata, u);
}

fn toKey(l: *Thread, v: Value) ?*ckey.Key {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != extTable(l, key_key)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn checkKey(l: *Thread, i: u32) Error!*ckey.Key {
    return toKey(l, l.arg(i)) orelse aux.typeError(l, i, "crypto.key or vector");
}

fn checkSelfKey(l: *Thread) Error!*ckey.Key {
    return toKey(l, l.arg(1)) orelse aux.typeError(l, 1, key_key);
}

fn keyError(l: *Thread, e: ckey.KeyError) Error {
    return switch (e) {
        error.OutOfMemory => l.raiseMem(),
        error.InvalidKey => l.raiseFmt("invalid key", .{}),
        error.EncryptedKey => l.raiseFmt("encrypted keys are not supported", .{}),
        error.UnsupportedKey => l.raiseFmt("unsupported key type", .{}),
        error.UnsupportedSize => l.raiseFmt("RSA keys must have 2048, 3072, or 4096 bits", .{}),
        error.InconsistentKey => l.raiseFmt("public and private parts of the key do not match", .{}),
    };
}

fn importkey(l: *Thread) Error!u32 {
    const gpa = l.g.gpa;
    const v = l.arg(1);
    const k: ckey.Key = switch (v.tag) {
        .vector => ckey.fromDer((try vector.checkVector(l, 1)).bytes.items),
        .table => blk: {
            const t = v.as(Table);
            var j: ckey.Jwk = .{};
            inline for (ckey.jwk_fields) |f| {
                const fv = try aux.getField(l, t, f);
                if (fv.tag == .string) {
                    @field(j, f) = fv.as(object.String).bytes();
                } else if (!fv.isNil()) {
                    return aux.argError(l, 1, "JWK member '" ++ f ++ "' must be a string", .{});
                }
            }
            break :blk ckey.fromJwk(gpa, j);
        },
        .string => blk: {
            const text = v.as(object.String).bytes();
            const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "-----BEGIN ")) break :blk ckey.fromPem(gpa, trimmed);
            if (std.mem.startsWith(u8, trimmed, "{")) break :blk ckey.jwkFromJson(gpa, trimmed);
            return aux.argError(l, 1, "PEM text or JWK expected", .{});
        },
        else => return aux.typeError(l, 1, "string, vector, or table"),
    } catch |e| return keyError(l, e);
    return aux.ret(l, try newKey(l, k));
}

fn keyIndex(l: *Thread) Error!u32 {
    const k = try checkSelfKey(l);
    const name = l.arg(2);
    if (name.tag == .string) {
        const s = name.as(object.String).bytes();
        if (std.mem.eql(u8, s, "type")) return aux.retStr(l, switch (k.kind) {
            .rsa => "rsa",
            .p256, .p384 => "ec",
            .ed25519 => "ed25519",
        });
        if (std.mem.eql(u8, s, "private")) return aux.retBool(l, k.private);
        if (std.mem.eql(u8, s, "bits")) {
            if (k.kind != .rsa) return aux.ret(l, .nil);
            return aux.ret(l, Value.int(@intCast(k.bits())));
        }
        if (std.mem.eql(u8, s, "curve")) {
            if (k.kind == .rsa) return aux.ret(l, .nil);
            return aux.retStr(l, ckey.curveName(k.kind));
        }
    }
    return aux.ret(l, tables.get(extTable(l, key_methods_key), name));
}

fn keyToString(l: *Thread) Error!u32 {
    const k = try checkSelfKey(l);
    var buf: [64]u8 = undefined;
    const vis = if (k.private) "private" else "public";
    const s = switch (k.kind) {
        .rsa => std.fmt.bufPrint(&buf, "crypto.key: rsa {d} {s}", .{ k.bits(), vis }),
        else => std.fmt.bufPrint(&buf, "crypto.key: {s} {s}", .{ ckey.curveName(k.kind), vis }),
    } catch unreachable;
    return aux.retStr(l, s);
}

/// `key:public()` returns the public half of the key.
fn keyPublic(l: *Thread) Error!u32 {
    const k = try checkSelfKey(l);
    return aux.ret(l, try newKey(l, k.toPublic()));
}

/// `key:export([format])` writes the key as PEM text, DER bytes, or a JWK
/// table.
fn keyExport(l: *Thread) Error!u32 {
    const k = try checkSelfKey(l);
    const format = try aux.checkOption(l, 2, "pem", &.{ "pem", "der", "jwk" });
    const gpa = l.g.gpa;
    switch (format) {
        0, 1 => {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            defer std.crypto.secureZero(u8, out.items);
            if (format == 0) {
                ckey.toPem(k, gpa, &out) catch return l.raiseMem();
                return aux.retStr(l, out.items);
            }
            ckey.toDer(k, gpa, &out) catch return l.raiseMem();
            return retBytes(l, out.items);
        },
        else => {
            var o: ckey.JwkOut = .{};
            ckey.toJwk(k, &o);
            defer std.crypto.secureZero(u8, &o.buf);
            const t = try l.newTable(0, @intCast(o.len));
            try l.push(Value.obj(.table, t));
            for (o.names[0..o.len], o.values[0..o.len]) |name, text| {
                try aux.setField(l, t, name, try l.newStringValue(text));
            }
            return 1;
        },
    }
}

// ---------------------------------------------------------------------
// Key derivation

fn checkRange(l: *Thread, i: u32, lo: i64, hi: i64, comptime what: []const u8) Error!u32 {
    const n = try aux.checkInt(l, i);
    if (n < lo or n > hi) return aux.argError(l, i, what ++ " out of range", .{});
    return @intCast(n);
}

const max_derived = 1024;

fn pbkdf2(l: *Thread) Error!u32 {
    const alg = try checkAlgorithm(l, 1);
    const password = try vector.checkData(l, 2);
    const salt = try vector.checkData(l, 3);
    const rounds = try checkRange(l, 4, 1, std.math.maxInt(u32), "iterations");
    const len = try checkRange(l, 5, 1, max_derived, "length");
    var out: [max_derived]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    switch (alg) {
        inline else => |a| std.crypto.pwhash.pbkdf2(out[0..len], password, salt, rounds, Hmac(HashOf(a))) catch
            return l.raiseFmt("invalid PBKDF2 parameters", .{}),
    }
    return retBytes(l, out[0..len]);
}

fn hkdf(l: *Thread) Error!u32 {
    const alg = try checkAlgorithm(l, 1);
    const key = try vector.checkData(l, 2);
    const salt = if (l.arg(3).isNil()) "" else try vector.checkData(l, 3);
    const info = if (l.arg(4).isNil()) "" else try vector.checkData(l, 4);
    switch (alg) {
        inline else => |a| {
            const H = HashOf(a);
            const K = std.crypto.kdf.hkdf.Hkdf(Hmac(H));
            const len = try checkRange(l, 5, 1, 255 * H.digest_length, "length");
            var out: [255 * H.digest_length]u8 = undefined;
            defer std.crypto.secureZero(u8, &out);
            var prk = K.extract(salt, key);
            defer std.crypto.secureZero(u8, &prk);
            K.expand(out[0..len], info, prk);
            return retBytes(l, out[0..len]);
        },
    }
}

// ---------------------------------------------------------------------
// Authenticated encryption

const cipher_names = [_][]const u8{"aes-256-gcm"};

fn optData(l: *Thread, i: u32) Error![]const u8 {
    return if (l.arg(i).isNil()) "" else vector.checkData(l, i);
}

fn encrypt(l: *Thread) Error!u32 {
    _ = try aux.checkOption(l, 1, null, &cipher_names);
    const key = try checkSized(l, 2, Aes256Gcm.key_length);
    const nonce = try checkSized(l, 3, Aes256Gcm.nonce_length);
    const plain = try vector.checkData(l, 4);
    const aad = try optData(l, 5);
    const gpa = l.g.gpa;
    var ct: std.ArrayList(u8) = .empty;
    defer ct.deinit(gpa);
    ct.resize(gpa, plain.len) catch return l.raiseMem();
    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(ct.items, &tag, plain, aad, nonce.*, key.*);
    try l.push(Value.obj(.vector, try vector.newVectorFrom(l, &ct)));
    try l.push(Value.obj(.vector, try vector.newVector(l, &tag)));
    return 2;
}

fn decrypt(l: *Thread) Error!u32 {
    _ = try aux.checkOption(l, 1, null, &cipher_names);
    const key = try checkSized(l, 2, Aes256Gcm.key_length);
    const nonce = try checkSized(l, 3, Aes256Gcm.nonce_length);
    const ct = try vector.checkData(l, 4);
    const tag = try checkSized(l, 5, Aes256Gcm.tag_length);
    const aad = try optData(l, 6);
    const gpa = l.g.gpa;
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    plain.resize(gpa, ct.len) catch return l.raiseMem();
    Aes256Gcm.decrypt(plain.items, ct, tag.*, aad, nonce.*, key.*) catch {
        std.crypto.secureZero(u8, plain.items);
        return aux.ret(l, .nil);
    };
    return aux.ret(l, Value.obj(.vector, try vector.newVectorFrom(l, &plain)));
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
/// The most lanes a password hash may ask for.
const max_lanes = 64;

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
    // The hash names its own cost, so each part of it has a bound.
    if (h.m > max_memory or h.t > max_time or h.p > max_lanes) return aux.argError(l, 2, "invalid password hash", .{});
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
