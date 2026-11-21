//! Signed documents: the Lus release index, the atmosphere release
//! documents, and the key lists that vouch for their signing keys
//! (`spec/design/modules.md`, section 5).
//!
//! A signed document is canonical JSON, with keys sorted by byte value and
//! no insignificant whitespace, that carries a `key` field naming the key
//! that signed it, a `signed` field with the time of signing, and a
//! `signature` field with the base64 Ed25519 signature of the canonical
//! JSON of the document without its `signature` field. The verifier
//! removes the top-level `signature` member and the comma before it from
//! the bytes it received, so it never serializes JSON. A server that emits
//! anything other than the canonical bytes it signed fails verification.
//!
//! A key list is a signed document whose `key` is `"root"` and which the
//! root key signs. Its `keys` field lists the signing keys, each with
//! `id`, `public` (base64 of 32 bytes), `not_before`, and `not_after`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const crypto = @import("lib/crypto.zig");
const base64 = std.base64.standard;

pub const Error = error{
    /// The document is not JSON of the expected shape.
    Malformed,
    /// The signature does not verify, or no trusted key made it.
    BadSignature,
    /// The signing key was not valid at the time of signing.
    Expired,
    OutOfMemory,
};

pub const Key = struct {
    id: []const u8,
    public: [32]u8,
    not_before: i64,
    not_after: i64,
};

/// Seconds since the Unix epoch of an RFC 3339 time in UTC, written
/// `YYYY-MM-DDTHH:MM:SSZ`, optionally with a fraction of a second.
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':') return null;
    if (s[s.len - 1] != 'Z' and s[s.len - 1] != 'z') return null;
    const num = struct {
        fn f(t: []const u8) ?i64 {
            for (t) |c| if (!std.ascii.isDigit(c)) return null;
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    const se = num(s[17..19]) orelse return null;
    if (s.len > 20) {
        if (s[19] != '.' or s.len < 22) return null;
        _ = num(s[20 .. s.len - 1]) orelse return null;
    }
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 60) return null;
    // Days from the civil date, after Howard Hinnant's algorithm.
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + h * 3600 + mi * 60 + se;
}

/// Formats seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn formatTime(buf: *[20]u8, t: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t, 0)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// A parsed signed document. `value` owns the parsed JSON.
pub const Document = struct {
    parsed: std.json.Parsed(std.json.Value),
    key: []const u8,
    signed: i64,

    pub fn root(d: *const Document) std.json.ObjectMap {
        return d.parsed.value.object;
    }

    pub fn deinit(d: *Document) void {
        d.parsed.deinit();
    }

    pub fn str(d: *const Document, name: []const u8) ?[]const u8 {
        const v = d.root().get(name) orelse return null;
        return if (v == .string) v.string else null;
    }
};

fn decodeFixed(comptime n: usize, text: []const u8) ?[n]u8 {
    var out: [n]u8 = undefined;
    const len = base64.Decoder.calcSizeForSlice(text) catch return null;
    if (len != n) return null;
    base64.Decoder.decode(&out, text) catch return null;
    return out;
}

pub fn decodePublic(text: []const u8) ?[32]u8 {
    return decodeFixed(32, text);
}

/// Parses `bytes` and splits off its signature. The caller verifies.
fn open(gpa: Allocator, bytes: []const u8, msg: *std.ArrayList(u8), sig: *[64]u8) Error!Document {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    const obj = parsed.value.object;
    const sig_v = obj.get("signature") orelse return error.Malformed;
    const key_v = obj.get("key") orelse return error.Malformed;
    const signed_v = obj.get("signed") orelse return error.Malformed;
    if (sig_v != .string or key_v != .string or signed_v != .string) return error.Malformed;
    const s = sig_v.string;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/' and c != '=') return error.Malformed;
    sig.* = decodeFixed(64, s) orelse return error.Malformed;
    // Base64 holds no quote or backslash, so the member appears in the
    // bytes exactly as written here. It is never the first member, since
    // every signed document has a key that sorts before "signature".
    var needle: std.ArrayList(u8) = .empty;
    defer needle.deinit(gpa);
    try needle.print(gpa, ",\"signature\":\"{s}\"", .{s});
    const at = std.mem.indexOf(u8, bytes, needle.items) orelse return error.Malformed;
    if (std.mem.indexOfPos(u8, bytes, at + 1, needle.items) != null) return error.Malformed;
    try msg.appendSlice(gpa, bytes[0..at]);
    try msg.appendSlice(gpa, bytes[at + needle.items.len ..]);
    const t = parseTime(signed_v.string) orelse return error.Malformed;
    return .{ .parsed = parsed, .key = key_v.string, .signed = t };
}

/// Strict RFC 8032 verification, shared with `crypto.verify`.
pub fn verifySig(public: [32]u8, msg: []const u8, sig: [64]u8) bool {
    return crypto.ed25519Verify(public, msg, sig);
}

/// Parses and verifies a key list signed by `root_key`.
pub fn openKeyList(gpa: Allocator, bytes: []const u8, root_key: [32]u8) Error!Document {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var sig: [64]u8 = undefined;
    var doc = try open(gpa, bytes, &msg, &sig);
    errdefer doc.deinit();
    if (!std.mem.eql(u8, doc.key, "root")) return error.BadSignature;
    if (!verifySig(root_key, msg.items, sig)) return error.BadSignature;
    gpa.free(try keysOf(gpa, &doc));
    return doc;
}

/// The signing keys of a verified key list. The strings point into the
/// document, so the result lives as long as it does.
pub fn keysOf(gpa: Allocator, doc: *const Document) Error![]Key {
    const kv = doc.root().get("keys") orelse return error.Malformed;
    if (kv != .array) return error.Malformed;
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(gpa);
    for (kv.array.items) |item| {
        if (item != .object) return error.Malformed;
        const o = item.object;
        const id = o.get("id") orelse return error.Malformed;
        const pub_v = o.get("public") orelse return error.Malformed;
        const nb = o.get("not_before") orelse return error.Malformed;
        const na = o.get("not_after") orelse return error.Malformed;
        if (id != .string or pub_v != .string or nb != .string or na != .string) return error.Malformed;
        try out.append(gpa, .{
            .id = id.string,
            .public = decodePublic(pub_v.string) orelse return error.Malformed,
            .not_before = parseTime(nb.string) orelse return error.Malformed,
            .not_after = parseTime(na.string) orelse return error.Malformed,
        });
    }
    return out.toOwnedSlice(gpa);
}

pub const Unknown = error{UnknownKey};

/// Parses and verifies a document signed by one of `keys`. Returns
/// `error.UnknownKey` when its key is not among them, so the caller can
/// fetch a newer key list and try again.
pub fn openDocument(gpa: Allocator, bytes: []const u8, keys: []const Key) (Error || Unknown)!Document {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var sig: [64]u8 = undefined;
    var doc = try open(gpa, bytes, &msg, &sig);
    errdefer doc.deinit();
    for (keys) |k| {
        if (!std.mem.eql(u8, k.id, doc.key)) continue;
        if (!verifySig(k.public, msg.items, sig)) return error.BadSignature;
        if (doc.signed < k.not_before or doc.signed > k.not_after) return error.Expired;
        return doc;
    }
    return error.UnknownKey;
}

/// Signs `doc_without_signature`, canonical JSON that lacks only the
/// `signature` member, and returns the document with the member inserted
/// in its sorted place. Used by tests and by the release tooling.
pub fn sign(gpa: Allocator, secret_seed: [32]u8, unsigned: []const u8) ![]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(secret_seed);
    const s = try kp.sign(unsigned, null);
    var enc: [base64.Encoder.calcSize(64)]u8 = undefined;
    const sig_text = base64.Encoder.encode(&enc, &s.toBytes());
    // Find the first top-level member whose key sorts after "signature".
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, unsigned, .{});
    defer parsed.deinit();
    var after: ?[]const u8 = null;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        if (std.mem.order(u8, e.key_ptr.*, "signature") == .gt) {
            if (after == null or std.mem.order(u8, e.key_ptr.*, after.?) == .lt) after = e.key_ptr.*;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (after) |k| {
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(gpa);
        try pat.print(gpa, ",\"{s}\":", .{k});
        const at = std.mem.indexOf(u8, unsigned, pat.items) orelse return error.Malformed;
        try out.appendSlice(gpa, unsigned[0..at]);
        try out.print(gpa, ",\"signature\":\"{s}\"", .{sig_text});
        try out.appendSlice(gpa, unsigned[at..]);
    } else {
        try out.appendSlice(gpa, unsigned[0 .. unsigned.len - 1]);
        try out.print(gpa, ",\"signature\":\"{s}\"}}", .{sig_text});
    }
    return out.toOwnedSlice(gpa);
}

pub fn publicOf(secret_seed: [32]u8) ![32]u8 {
    const kp = try Ed25519.KeyPair.generateDeterministic(secret_seed);
    return kp.public_key.toBytes();
}

test "time" {
    const t = std.testing;
    try t.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try t.expectEqual(@as(?i64, 1700000000), parseTime("2023-11-14T22:13:20Z"));
    try t.expectEqual(@as(?i64, 1700000000), parseTime("2023-11-14T22:13:20.5Z"));
    try t.expect(parseTime("2023-11-14 22:13:20Z") == null);
    var buf: [20]u8 = undefined;
    try t.expectEqualStrings("2023-11-14T22:13:20Z", formatTime(&buf, 1700000000));
}

test "sign and verify" {
    const gpa = std.testing.allocator;
    const root_seed = @as([32]u8, @splat(1));
    const key_seed = @as([32]u8, @splat(2));
    const root_pub = try publicOf(root_seed);
    const key_pub = try publicOf(key_seed);
    var pub_text: [44]u8 = undefined;
    _ = base64.Encoder.encode(&pub_text, &key_pub);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.print(gpa, "{{\"key\":\"root\",\"keys\":[{{\"id\":\"k1\",\"not_after\":\"2030-01-01T00:00:00Z\",\"not_before\":\"2020-01-01T00:00:00Z\",\"public\":\"{s}\"}}],\"signed\":\"2026-01-01T00:00:00Z\"}}", .{&pub_text});
    const signed_list = try sign(gpa, root_seed, list.items);
    defer gpa.free(signed_list);
    var kl = try openKeyList(gpa, signed_list, root_pub);
    defer kl.deinit();
    const keys = try keysOf(gpa, &kl);
    defer gpa.free(keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);

    const doc = try sign(gpa, key_seed, "{\"bundle\":\"b\",\"key\":\"k1\",\"signed\":\"2026-02-01T00:00:00Z\",\"size\":1}");
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"signature\":") != null);
    var d = try openDocument(gpa, doc, keys);
    d.deinit();
    // A changed byte fails.
    const bad = try gpa.dupe(u8, doc);
    defer gpa.free(bad);
    bad[std.mem.indexOf(u8, bad, "\"size\":1").? + 7] = '2';
    try std.testing.expectError(error.BadSignature, openDocument(gpa, bad, keys));
    // A signature outside the key's period fails.
    const late = try sign(gpa, key_seed, "{\"bundle\":\"b\",\"key\":\"k1\",\"signed\":\"2031-02-01T00:00:00Z\",\"size\":1}");
    defer gpa.free(late);
    try std.testing.expectError(error.Expired, openDocument(gpa, late, keys));
    // The list signed by another root fails.
    try std.testing.expectError(error.BadSignature, openKeyList(gpa, signed_list, key_pub));
}
