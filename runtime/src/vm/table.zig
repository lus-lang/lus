//! Table implementation: an array part for keys 1..n plus a hash part with
//! open addressing and linear probing. Dead entries keep their key with a
//! nil value until the next rehash, so `next` stays valid while a program
//! clears fields during traversal, as Lua requires.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const Value = value.Value;
const Table = object.Table;
const Node = object.Node;
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, InvalidKey, NanKey };

pub fn hashValue(v: Value) u64 {
    return switch (v.tag) {
        .string => v.as(object.String).hash,
        .integer => mixInt(@bitCast(v.asInt())),
        .float => mixInt(@bitCast(v.asFloat())),
        .true => 1,
        .false => 2,
        else => mixInt(v.payload),
    };
}

inline fn mixInt(x: u64) u64 {
    var h = x *% 0x9E3779B97F4A7C15;
    h ^= h >> 32;
    return h;
}

/// Converts a float key with an integral value to an integer key, so that
/// `t[1.0]` and `t[1]` name the same slot. Bigint and decimal keys are
/// normalized by the caller before reaching the table.
pub inline fn normalizeKey(k: Value) Value {
    if (k.tag == .float) {
        const f = k.asFloat();
        if (f == @floor(f) and f >= -9.223372036854775808e18 and f < 9.223372036854775808e18) {
            return Value.int(@intFromFloat(f));
        }
    }
    return k;
}

pub fn keyEqual(a: Value, b: Value) bool {
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .float => a.asFloat() == b.asFloat(),
        .nil, .true, .false => true,
        else => a.payload == b.payload,
    };
}

// ---------------------------------------------------------------------
// Lookup

pub fn getInt(t: *Table, k: i64) Value {
    if (k >= 1 and k <= t.array.len) return t.array[@intCast(k - 1)];
    return getHash(t, Value.int(k));
}

pub fn getStr(t: *Table, s: *object.String) Value {
    const idx = findStr(t, s) orelse return .nil;
    return t.hash[idx].val;
}

/// Index of the hash slot holding the string key `s` (live or dead), or
/// null.
pub inline fn findStr(t: *Table, s: *object.String) ?usize {
    if (t.hash.len == 0) return null;
    const mask = t.hash.len - 1;
    var i: usize = s.hash & mask;
    while (true) : (i = (i + 1) & mask) {
        const n = &t.hash[i];
        if (n.key.tag == .string) {
            if (n.key.payload == @intFromPtr(s)) return i;
            // Long strings are not interned: equal contents, distinct objects.
            if (!s.flags.interned) {
                const o = n.key.as(object.String);
                if (!o.flags.interned and o.len == s.len and o.hash == s.hash and std.mem.eql(u8, o.bytes(), s.bytes())) return i;
            }
        }
        if (n.key.tag == .nil) return null;
    }
}

pub fn get(t: *Table, key: Value) Value {
    const k = normalizeKey(key);
    switch (k.tag) {
        .integer => return getInt(t, k.asInt()),
        .string => return getStr(t, k.as(object.String)),
        .nil => return .nil,
        else => return getHash(t, k),
    }
}

fn getHash(t: *Table, k: Value) Value {
    const idx = findSlot(t, k) orelse return .nil;
    return t.hash[idx].val;
}

/// Index of the slot holding `k` (live or dead), or null.
pub fn findSlot(t: *Table, k: Value) ?usize {
    if (t.hash.len == 0) return null;
    const mask = t.hash.len - 1;
    var i: usize = @intCast(hashValue(k) & mask);
    while (true) : (i = (i + 1) & mask) {
        const n = &t.hash[i];
        if (n.key.tag == .nil) return null;
        if (keyEqual(n.key, k)) return i;
    }
}

// ---------------------------------------------------------------------
// Store

/// Stores `val` under `key`. The caller has already rejected nil and NaN
/// keys and run any metamethods.
pub fn set(gpa: Allocator, t: *Table, key: Value, val: Value) Error!void {
    const k = normalizeKey(key);
    t.tm_absent = 0;
    if (k.tag == .integer) {
        const i = k.asInt();
        if (i >= 1 and i <= t.array.len) {
            t.array[@intCast(i - 1)] = val;
            return;
        }
    }
    if (findSlot(t, k)) |idx| {
        t.hash[idx].val = val;
        return;
    }
    if (val.isNil()) return; // storing nil under an absent key is a no-op
    // New key. Grow when the hash part would exceed a 3/4 load factor.
    if (t.hash.len == 0 or (t.hash_used + 1) * 4 > t.hash.len * 3) {
        try rehash(gpa, t, k);
        // The key may now belong in the array part.
        if (k.tag == .integer) {
            const i = k.asInt();
            if (i >= 1 and i <= t.array.len) {
                t.array[@intCast(i - 1)] = val;
                return;
            }
        }
    }
    insertNew(t, k, val);
}

pub fn setInt(gpa: Allocator, t: *Table, i: i64, val: Value) Error!void {
    if (i >= 1 and i <= t.array.len) {
        t.array[@intCast(i - 1)] = val;
        t.tm_absent = 0;
        return;
    }
    return set(gpa, t, Value.int(i), val);
}

pub fn setStr(gpa: Allocator, t: *Table, s: *object.String, val: Value) Error!void {
    return set(gpa, t, Value.obj(.string, s), val);
}

fn insertNew(t: *Table, k: Value, val: Value) void {
    const mask = t.hash.len - 1;
    var i: usize = @intCast(hashValue(k) & mask);
    while (t.hash[i].key.tag != .nil) : (i = (i + 1) & mask) {}
    t.hash[i] = .{ .key = k, .val = val };
    t.hash_used += 1;
}

/// Recomputes the sizes of both parts so that the array part is the
/// largest power of two that is more than half full, then reinserts every
/// live entry. `extra` is the key about to be inserted.
fn rehash(gpa: Allocator, t: *Table, extra: Value) Error!void {
    // nums[b] counts integer keys k with 2^(b-1) < k <= 2^b.
    var nums: [64]u32 = @splat(0);
    var total_int: u32 = 0;
    var total: u32 = 0;
    for (t.array, 0..) |v, idx| {
        if (!v.isNil()) {
            nums[ceilLog2(idx + 1)] += 1;
            total_int += 1;
        }
    }
    for (t.hash) |n| {
        if (n.key.tag == .nil or n.val.isNil()) continue;
        total += 1;
        if (n.key.tag == .integer) {
            const k = n.key.asInt();
            if (k >= 1 and k <= 1 << 40) {
                nums[ceilLog2(@intCast(k))] += 1;
                total_int += 1;
            }
        }
    }
    if (extra.tag == .integer) {
        const k = extra.asInt();
        if (k >= 1 and k <= 1 << 40) {
            nums[ceilLog2(@intCast(k))] += 1;
            total_int += 1;
        }
    }
    total += 1; // the extra key
    // Choose the array size.
    var na: usize = 0;
    var a: u32 = 0;
    var best: usize = 0;
    var twotoi: usize = 1;
    var b: usize = 0;
    while (b < 64 and twotoi / 2 < total_int) : (b += 1) {
        a += nums[b];
        if (a > twotoi / 2) {
            best = twotoi;
            na = a;
        }
        twotoi *= 2;
    }
    const hash_count = total + countArray(t) - @as(u32, @intCast(na));
    try resize(gpa, t, best, hash_count);
}

fn countArray(t: *Table) u32 {
    var n: u32 = 0;
    for (t.array) |v| {
        if (!v.isNil()) n += 1;
    }
    return n;
}

fn ceilLog2(x: usize) usize {
    if (x <= 1) return 0;
    return @as(usize, 64) - @clz(@as(u64, x - 1));
}

/// Resizes the table to `asize` array slots and a hash part big enough for
/// `hcount` entries at the target load factor.
pub fn resize(gpa: Allocator, t: *Table, asize: usize, hcount: usize) Error!void {
    var hsize: usize = 0;
    if (hcount > 0) {
        hsize = 4;
        while (hsize * 3 < hcount * 4) hsize *= 2;
    }
    const old_array = t.array;
    const old_hash = t.hash;
    const new_array = if (asize == old_array.len) old_array else try gpa.alloc(Value, asize);
    errdefer if (asize != old_array.len) gpa.free(new_array);
    const new_hash = try gpa.alloc(Node, hsize);
    for (new_hash) |*n| n.* = .{ .key = .nil, .val = .nil };
    if (new_array.ptr != old_array.ptr) {
        const keep = @min(asize, old_array.len);
        @memcpy(new_array[0..keep], old_array[0..keep]);
        for (new_array[keep..]) |*v| v.* = .nil;
    }
    t.array = new_array;
    t.hash = new_hash;
    t.hash_used = 0;
    t.log2_hash = if (hsize == 0) 0 else @intCast(std.math.log2_int(usize, hsize));
    // Move array entries that no longer fit into the hash part.
    if (old_array.len > asize) {
        for (old_array[asize..], asize..) |v, idx| {
            if (!v.isNil()) reinsert(t, Value.int(@intCast(idx + 1)), v);
        }
    }
    for (old_hash) |n| {
        if (n.key.tag == .nil or n.val.isNil()) continue;
        reinsert(t, n.key, n.val);
    }
    if (new_array.ptr != old_array.ptr and old_array.len > 0) gpa.free(old_array);
    if (old_hash.len > 0) gpa.free(old_hash);
}

fn reinsert(t: *Table, k: Value, v: Value) void {
    if (k.tag == .integer) {
        const i = k.asInt();
        if (i >= 1 and i <= t.array.len) {
            t.array[@intCast(i - 1)] = v;
            return;
        }
    }
    insertNew(t, k, v);
}

// ---------------------------------------------------------------------
// Length and traversal

/// Border of the table, as defined by the `#` operator: an index n such
/// that t[n] is not nil and t[n+1] is nil (or 0 when t[1] is nil).
pub fn length(t: *Table) i64 {
    const n = t.array.len;
    if (n > 0 and t.array[n - 1].isNil()) {
        // Binary search for a border inside the array part.
        var lo: usize = 0;
        var hi: usize = n;
        while (hi - lo > 1) {
            const m = (lo + hi) / 2;
            if (t.array[m - 1].isNil()) hi = m else lo = m;
        }
        return @intCast(lo);
    }
    if (t.hash.len == 0) return @intCast(n);
    // Continue into the hash part with unbounded search.
    var j: i64 = @intCast(n + 1);
    if (getHash(t, Value.int(j)).isNil()) return @intCast(n);
    var i: i64 = j;
    while (!getHash(t, Value.int(j)).isNil()) {
        i = j;
        if (j > std.math.maxInt(i64) / 2) {
            // Pathological table: linear search.
            var k: i64 = 1;
            while (!get(t, Value.int(k)).isNil()) k += 1;
            return k - 1;
        }
        j *= 2;
    }
    while (j - i > 1) {
        const m = @divTrunc(i + j, 2);
        if (getHash(t, Value.int(m)).isNil()) j = m else i = m;
    }
    return i;
}

pub const NextResult = struct { key: Value, val: Value };

/// Traversal step. Returns null at the end, or error.InvalidKey when `key`
/// is not present in the table.
pub fn next(t: *Table, key: Value) Error!?NextResult {
    var start: usize = 0; // position in the combined array+hash sequence
    if (!key.isNil()) {
        const k = normalizeKey(key);
        if (k.tag == .integer and k.asInt() >= 1 and k.asInt() <= t.array.len) {
            start = @intCast(k.asInt());
        } else {
            const idx = findSlot(t, k) orelse return error.InvalidKey;
            start = t.array.len + idx + 1;
        }
    }
    var i = start;
    while (i < t.array.len) : (i += 1) {
        if (!t.array[i].isNil()) return .{ .key = Value.int(@intCast(i + 1)), .val = t.array[i] };
    }
    var h = i - t.array.len;
    while (h < t.hash.len) : (h += 1) {
        const n = t.hash[h];
        if (n.key.tag != .nil and !n.val.isNil()) return .{ .key = n.key, .val = n.val };
    }
    return null;
}

const testing = std.testing;

test "array and hash parts" {
    var t: Table = .{ .hdr = .{ .tag = .table } };
    defer {
        if (t.array.len > 0) testing.allocator.free(t.array);
        if (t.hash.len > 0) testing.allocator.free(t.hash);
    }
    var i: i64 = 1;
    while (i <= 100) : (i += 1) try setInt(testing.allocator, &t, i, Value.int(i * 2));
    try testing.expectEqual(@as(i64, 100), length(&t));
    try testing.expectEqual(@as(i64, 84), getInt(&t, 42).asInt());
    try testing.expect(t.array.len >= 64);
    try set(testing.allocator, &t, Value.float(3.0), Value.int(7));
    try testing.expectEqual(@as(i64, 7), getInt(&t, 3).asInt());
    // Traversal visits every key once.
    var count: usize = 0;
    var k: Value = .nil;
    while (try next(&t, k)) |r| : (k = r.key) count += 1;
    try testing.expectEqual(@as(usize, 100), count);
    // Clearing during traversal keeps `next` valid.
    k = .nil;
    while (try next(&t, k)) |r| : (k = r.key) try set(testing.allocator, &t, r.key, .nil);
    try testing.expectEqual(@as(i64, 0), length(&t));
}
