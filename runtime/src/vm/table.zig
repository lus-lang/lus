//! Table implementation: an array part for keys 1..n plus a hash part with
//! open addressing and linear probing. Dead entries keep their key with a
//! nil value until the next rehash, so `next` stays valid while a program
//! clears fields during traversal, as Lua requires.
//!
//! The array part specializes by element kind (`Table.ArrayKind`). An
//! array of integers or of floats stores bare 64-bit words, and every
//! other array stores full values. `spec/design/tables.md` describes the
//! layout and the transitions.

const std = @import("std");
const numeric = @import("numeric.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const gc = @import("gc.zig");
const Value = value.Value;
const Table = object.Table;
const Node = object.Node;
const ArrayKind = Table.ArrayKind;
const Allocator = std.mem.Allocator;
const hole = Table.hole;

pub const Error = error{ OutOfMemory, InvalidKey, NanKey };

pub fn hashValue(v: Value) u64 {
    return switch (v.tag) {
        .string => v.as(object.String).hash,
        .integer => mixInt(@bitCast(v.asInt())),
        .float => mixInt(@bitCast(v.asFloat())),
        .true => 1,
        .false => 2,
        // Large bigints hash by their digits so equal values share a slot.
        .bigint => blk: {
            const b = v.as(numeric.BigInt);
            var h = std.hash.Wyhash.init(@intFromBool(b.positive));
            h.update(std.mem.sliceAsBytes(b.limbs()));
            break :blk h.final();
        },
        // Fractional decimals compare by value across scales (1.5 and
        // 1.50), so they share one hash class. They are rare as keys.
        .decimal => 0x9E3779B97F4A7C15,
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
        .string => a.payload == b.payload or longStringEqual(a.as(object.String), b.as(object.String)),
        .bigint => a.payload == b.payload or bigEqual(a.as(numeric.BigInt), b.as(numeric.BigInt)),
        .decimal => a.payload == b.payload or (numeric.compare(std.heap.page_allocator, a, b) orelse .lt) == .eq,
        else => a.payload == b.payload,
    };
}

fn bigEqual(x: *const numeric.BigInt, y: *const numeric.BigInt) bool {
    return x.positive == y.positive and std.mem.eql(numeric.Limb, x.limbs(), y.limbs());
}

/// Short strings are interned, so equal short strings are the same object.
/// Long strings are not, so they compare by content.
fn longStringEqual(x: *object.String, y: *object.String) bool {
    if (x.flags.interned or y.flags.interned) return false;
    return x.len == y.len and x.hash == y.hash and std.mem.eql(u8, x.bytes(), y.bytes());
}

// ---------------------------------------------------------------------
// Array part

/// The value in the zero-based array slot `idx`, which is below `asize`.
pub inline fn arrayGet(t: *const Table, idx: usize) Value {
    if (t.kind == .boxed) return t.values()[idx];
    return unboxWord(t.kind, t.array_ptr[idx]);
}

/// The value an unboxed slot of kind `kind` holding `w` stands for.
inline fn unboxWord(kind: ArrayKind, w: u64) Value {
    if (w == hole) return .nil;
    return Value.make(w, @fromBackingInt(@intCast(@backingInt(kind))));
}

/// True when the zero-based array slot `idx` holds nil.
pub inline fn arrayIsNil(t: *const Table, idx: usize) bool {
    if (t.kind == .boxed) return t.values()[idx].isNil();
    return t.array_ptr[idx] == hole;
}

/// The kind an array part of kind `k` needs to also hold `v`.
pub inline fn joinKind(k: ArrayKind, v: Value) ArrayKind {
    if (k == .boxed or v.tag == .nil) return k;
    if ((v.tag == .integer or v.tag == .float) and v.payload != hole) {
        const vk: ArrayKind = @fromBackingInt(@intCast(@backingInt(v.tag)));
        if (k == .none or k == vk) return vk;
    }
    return .boxed;
}

/// Stores `v` into the zero-based array slot `idx` when it fits the kind
/// of the array part, fixing the kind of a `none` part on its first
/// number. Returns false, leaving the table unchanged, when the part must
/// become boxed first. The caller runs the write barrier.
pub inline fn arrayStoreFast(t: *Table, idx: usize, v: Value) bool {
    if (t.kind == .boxed) {
        t.values()[idx] = v;
        return true;
    }
    if (v.tag == .nil) {
        t.array_ptr[idx] = hole;
        return true;
    }
    const k = joinKind(t.kind, v);
    if (k == .boxed) return false;
    t.kind = k;
    t.array_ptr[idx] = v.payload;
    return true;
}

/// Stores `v` into the zero-based array slot `idx`, boxing the array
/// part when `v` does not fit its kind.
pub fn arrayStore(gpa: Allocator, t: *Table, idx: usize, v: Value) Error!void {
    if (arrayStoreFast(t, idx, v)) return;
    try box(gpa, t);
    t.values()[idx] = v;
}

/// Makes the array part boxed. Every slot keeps its value.
pub fn box(gpa: Allocator, t: *Table) Error!void {
    if (t.kind == .boxed) return;
    if (t.asize > 0 and t.ownsInline(t.array_ptr)) {
        // An array part in the cell reserves a full value per slot, so it
        // boxes in place. Slot i moves from word i to words 2i and 2i+1,
        // and walking down never overwrites a word before it is read.
        const vals: [*]Value = @ptrCast(t.array_ptr);
        var i = t.asize;
        while (i > 0) {
            i -= 1;
            vals[i] = unboxWord(t.kind, t.array_ptr[i]);
        }
    } else if (t.asize > 0) {
        const vals = try gpa.alloc(Value, t.asize);
        for (vals, t.words()) |*d, w| d.* = unboxWord(t.kind, w);
        gpa.free(t.words());
        t.array_ptr = @ptrCast(vals.ptr);
    }
    t.kind = .boxed;
}

/// Releases the array and hash parts of a dead table.
pub fn freeParts(gpa: Allocator, t: *Table) void {
    freeArray(gpa, t, t.kind, t.array_ptr, t.asize);
    freeHash(gpa, t, t.hash);
}

fn freeHash(gpa: Allocator, t: *Table, h: []Node) void {
    if (h.len > 0 and !t.ownsInline(h.ptr)) gpa.free(h);
}

fn freeArray(gpa: Allocator, t: *Table, kind: ArrayKind, ptr: [*]u64, n: usize) void {
    if (n == 0 or t.ownsInline(ptr)) return;
    if (kind == .boxed) {
        const p: [*]Value = @ptrCast(ptr);
        gpa.free(p[0..n]);
    } else gpa.free(ptr[0..n]);
}

/// Stores `vals` into the array slots `start + 1` through
/// `start + vals.len`, growing the array part to hold them. Constructors
/// and vararg tables fill their array parts this way.
pub fn storeList(gpa: Allocator, t: *Table, start: usize, vals: []const Value) Error!void {
    const last = start + vals.len;
    if (last > t.asize) try resize(gpa, t, last, t.hash_used);
    var kind = t.kind;
    for (vals) |v| kind = joinKind(kind, v);
    if (kind == .boxed) {
        try box(gpa, t);
        @memcpy(t.values()[start..last], vals);
    } else {
        t.kind = kind;
        for (t.words()[start..last], vals) |*w, v| w.* = if (v.isNil()) hole else v.payload;
    }
}

// ---------------------------------------------------------------------
// Lookup

pub fn getInt(t: *Table, k: i64) Value {
    if (k >= 1 and k <= t.asize) return arrayGet(t, @intCast(k - 1));
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
    // A small hash part may be full, and a probe for an absent key would
    // then find no empty node to stop at.
    if (t.hash_used >= t.hash.len) return findStrFull(t, s);
    const mask = t.hash.len - 1;
    var i: usize = s.hash & mask;
    while (true) : (i = (i + 1) & mask) {
        const n = &t.hash[i];
        if (n.key.tag == .string) {
            if (n.key.payload == @intFromPtr(s)) return i;
            if (!s.flags.interned and longStrEqual(n.key, s)) return i;
        }
        if (n.key.tag == .nil) return null;
    }
}

/// `findStr` in a hash part with a key in every node, which visits every
/// node at most once.
noinline fn findStrFull(t: *Table, s: *object.String) ?usize {
    const mask = t.hash.len - 1;
    var i: usize = s.hash & mask;
    for (0..t.hash.len) |_| {
        const n = &t.hash[i];
        if (n.key.tag == .string) {
            if (n.key.payload == @intFromPtr(s)) return i;
            if (!s.flags.interned and longStrEqual(n.key, s)) return i;
        }
        i = (i + 1) & mask;
    }
    return null;
}

/// Long strings are not interned: equal contents, distinct objects.
inline fn longStrEqual(k: Value, s: *object.String) bool {
    const o = k.as(object.String);
    return !o.flags.interned and o.len == s.len and o.hash == s.hash and std.mem.eql(u8, o.bytes(), s.bytes());
}

/// True when a hash part of `len` nodes, `used` of which hold a key, has
/// room for one more key. A part of up to `full_max` nodes may fill
/// completely. A larger part stays at most three quarters full, so that
/// probes stay short.
pub inline fn hashRoom(used: usize, len: usize) bool {
    if (len <= full_max) return used < len;
    return (used + 1) * 4 <= len * 3;
}

/// The largest hash part that may hold a key in every node.
pub const full_max = 4;

/// Stores `val` under the string key `key` when that needs no rehash:
/// the key is present, or it is absent, `val` is not nil, and the hash
/// part has room. Returns the node index, or null when the store needs
/// the general path, leaving the table unchanged. The caller resets the
/// metamethod cache and runs the write barrier.
pub inline fn storeStr(t: *Table, key: Value, val: Value) ?usize {
    if (t.hash.len == 0) return null;
    const s = key.as(object.String);
    // A full part has no empty node to end the probe, and the general
    // path takes the store.
    if (t.hash_used >= t.hash.len) return null;
    const mask = t.hash.len - 1;
    var i: usize = s.hash & mask;
    while (true) : (i = (i + 1) & mask) {
        const n = &t.hash[i];
        if (n.key.tag == .string) {
            if (n.key.payload == @intFromPtr(s)) break;
            if (!s.flags.interned) return null;
        } else if (n.key.tag == .nil) {
            // Absent. Linear probing inserts a new key at the first free
            // slot of its probe sequence, which is this one.
            if (val.isNil() or !hashRoom(t.hash_used, t.hash.len)) return null;
            n.key = key;
            t.hash_used += 1;
            break;
        }
    }
    t.hash[i].val = val;
    return i;
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
    if (t.hash_used >= t.hash.len) return findSlotFull(t, k);
    const mask = t.hash.len - 1;
    var i: usize = @intCast(hashValue(k) & mask);
    while (true) : (i = (i + 1) & mask) {
        const n = &t.hash[i];
        if (n.key.tag == .nil) return null;
        if (keyEqual(n.key, k)) return i;
    }
}

/// `findSlot` in a hash part with a key in every node, which visits every
/// node at most once.
noinline fn findSlotFull(t: *Table, k: Value) ?usize {
    const mask = t.hash.len - 1;
    var i: usize = @intCast(hashValue(k) & mask);
    for (0..t.hash.len) |_| {
        if (keyEqual(t.hash[i].key, k)) return i;
        i = (i + 1) & mask;
    }
    return null;
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
        if (i >= 1 and i <= t.asize) return arrayStore(gpa, t, @intCast(i - 1), val);
    }
    if (findSlot(t, k)) |idx| {
        t.hash[idx].val = val;
        return;
    }
    if (val.isNil()) return; // storing nil under an absent key is a no-op
    // New key. Grow when the hash part has no room for it.
    if (t.hash.len == 0 or !hashRoom(t.hash_used, t.hash.len)) {
        try rehash(gpa, t, k);
        // The key may now belong in the array part.
        if (k.tag == .integer) {
            const i = k.asInt();
            if (i >= 1 and i <= t.asize) return arrayStore(gpa, t, @intCast(i - 1), val);
        }
    }
    insertNew(t, k, val);
}

pub fn setInt(gpa: Allocator, t: *Table, i: i64, val: Value) Error!void {
    if (i >= 1 and i <= t.asize) {
        t.tm_absent = 0;
        return arrayStore(gpa, t, @intCast(i - 1), val);
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
    for (0..t.asize) |idx| {
        if (!arrayIsNil(t, idx)) {
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
    if (t.kind == .boxed) {
        for (t.values()) |v| n += @intFromBool(!v.isNil());
    } else {
        for (t.words()) |w| n += @intFromBool(w != hole);
    }
    return n;
}

fn ceilLog2(x: usize) usize {
    if (x <= 1) return 0;
    return @as(usize, 64) - @clz(@as(u64, x - 1));
}

/// The number of hash slots that holds `hcount` entries at the target
/// load factor.
fn hashSizeFor(hcount: usize) usize {
    if (hcount == 0) return 0;
    var hsize: usize = 4;
    while (hsize * 3 < hcount * 4) hsize *= 2;
    return hsize;
}

/// The number of hash slots of a new table that is created for exactly
/// `hcount` keys, as a constructor creates its table. A small part is
/// sized to fill completely, which keeps records such as `{x = 1, y = 2}`
/// compact. Parts that grow later use `hashSizeFor`.
fn hashSizeExact(hcount: usize) usize {
    if (hcount == 0) return 0;
    if (hcount <= full_max) return std.math.ceilPowerOfTwoAssert(usize, hcount);
    return hashSizeFor(hcount);
}

/// Largest storage, in bytes, that a new table keeps in its own cell.
const max_inline = 512;

/// The size in 16-byte units of the storage that a new table with
/// `narr` array slots and room for `nhash` hash entries keeps in its own
/// cell, or zero when the parts are too big for it. The array part
/// reserves a full value per slot so that it can box in place.
pub fn inlineUnits(narr: usize, nhash: usize) usize {
    if (narr == 0 and nhash == 0) return 0;
    if (narr > max_inline or nhash > max_inline) return 0;
    const bytes = hashSizeExact(nhash) * @sizeOf(Node) + narr * @sizeOf(Value);
    if (bytes > max_inline) return 0;
    return std.math.divCeil(usize, bytes, 16) catch unreachable;
}

/// Lays out the parts of a fresh table in the storage of its cell, as
/// `inlineUnits` sized it: the hash part first, then the array part.
pub fn initInline(t: *Table, narr: usize, nhash: usize) void {
    const hsize = hashSizeExact(nhash);
    const mem = t.inlineBytes();
    const nodes: [*]Node = @ptrCast(@alignCast(mem.ptr));
    t.hash = nodes[0..hsize];
    // The parts of small records clear with a few stores instead of a
    // call to memset.
    const empty: Node = .{ .key = .nil, .val = .nil };
    switch (hsize) {
        0 => {},
        1 => nodes[0..1].* = @splat(empty),
        2 => nodes[0..2].* = @splat(empty),
        4 => nodes[0..4].* = @splat(empty),
        else => @memset(t.hash, empty),
    }
    t.log2_hash = if (hsize == 0) 0 else @intCast(std.math.log2_int(usize, hsize));
    if (narr == 0) return;
    t.array_ptr = @ptrCast(@alignCast(mem.ptr + hsize * @sizeOf(Node)));
    t.asize = narr;
    @memset(t.words(), hole);
}

/// Resizes the table to `asize` array slots and a hash part big enough for
/// `hcount` entries at the target load factor. The array part keeps its
/// kind unless an entry that moves into it from the hash part does not
/// fit, in which case it becomes boxed.
pub fn resize(gpa: Allocator, t: *Table, asize: usize, hcount: usize) Error!void {
    const hsize = hashSizeFor(hcount);
    const old_kind = t.kind;
    const old_ptr = t.array_ptr;
    const old_n = t.asize;
    const old_hash = t.hash;
    var kind = old_kind;
    for (old_hash) |n| {
        if (n.key.tag != .integer or n.val.isNil()) continue;
        const i = n.key.asInt();
        if (i >= 1 and i <= asize) kind = joinKind(kind, n.val);
    }
    // Allocate both parts before changing the table, so that running out
    // of memory leaves it intact.
    const reuse = asize == old_n and kind == old_kind;
    var new_ptr = if (reuse) old_ptr else Table.empty_words;
    if (!reuse and asize > 0) {
        new_ptr = if (kind == .boxed) @ptrCast((try gpa.alloc(Value, asize)).ptr) else (try gpa.alloc(u64, asize)).ptr;
    }
    errdefer if (!reuse) freeArray(gpa, t, kind, new_ptr, asize);
    const new_hash = try gpa.alloc(Node, hsize);
    for (new_hash) |*n| n.* = .{ .key = .nil, .val = .nil };
    const old: Table = .{ .hdr = t.hdr, .kind = old_kind, .array_ptr = old_ptr, .asize = old_n };
    t.kind = kind;
    t.array_ptr = new_ptr;
    t.asize = asize;
    if (!reuse) {
        const keep = @min(asize, old_n);
        if (kind == .boxed) {
            const dst = t.values();
            if (old_kind == .boxed) {
                @memcpy(dst[0..keep], old.values()[0..keep]);
            } else {
                for (dst[0..keep], 0..) |*d, idx| d.* = arrayGet(&old, idx);
            }
            @memset(dst[keep..], .nil);
        } else {
            const dst = t.words();
            @memcpy(dst[0..keep], old.words()[0..keep]);
            @memset(dst[keep..], hole);
        }
    }
    t.hash = new_hash;
    t.hash_used = 0;
    t.log2_hash = if (hsize == 0) 0 else @intCast(std.math.log2_int(usize, hsize));
    // Move array entries that no longer fit into the hash part.
    if (old_n > asize) {
        for (asize..old_n) |idx| {
            const v = arrayGet(&old, idx);
            if (!v.isNil()) reinsert(t, Value.int(@intCast(idx + 1)), v);
        }
    }
    for (old_hash) |n| {
        if (n.key.tag == .nil or n.val.isNil()) continue;
        reinsert(t, n.key, n.val);
    }
    if (!reuse) freeArray(gpa, t, old_kind, old_ptr, old_n);
    freeHash(gpa, t, old_hash);
}

/// Inserts a live entry while rebuilding. The kind of the array part
/// already admits every value that lands in it.
fn reinsert(t: *Table, k: Value, v: Value) void {
    if (k.tag == .integer) {
        const i = k.asInt();
        if (i >= 1 and i <= t.asize) {
            const ok = arrayStoreFast(t, @intCast(i - 1), v);
            std.debug.assert(ok);
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
    const n = t.asize;
    if (n > 0 and arrayIsNil(t, n - 1)) {
        // The previous border, or the one just after it when a value was
        // appended, is usually still a border.
        const h: usize = t.len_hint;
        if (h < n and arrayIsNil(t, h)) {
            if (h == 0 or !arrayIsNil(t, h - 1)) return @intCast(h);
        } else if (h + 1 < n and arrayIsNil(t, h + 1)) {
            t.len_hint = @intCast(h + 1);
            return @intCast(h + 1);
        }
        // Binary search for a border inside the array part.
        var lo: usize = 0;
        var hi: usize = n;
        while (hi - lo > 1) {
            const m = (lo + hi) / 2;
            if (arrayIsNil(t, m - 1)) hi = m else lo = m;
        }
        t.len_hint = @intCast(lo);
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
        if (k.tag == .integer and k.asInt() >= 1 and k.asInt() <= t.asize) {
            start = @intCast(k.asInt());
        } else {
            const idx = findSlot(t, k) orelse return error.InvalidKey;
            start = t.asize + idx + 1;
        }
    }
    var i = start;
    while (i < t.asize) : (i += 1) {
        const v = arrayGet(t, i);
        if (!v.isNil()) return .{ .key = Value.int(@intCast(i + 1)), .val = v };
    }
    var h = i - t.asize;
    while (h < t.hash.len) : (h += 1) {
        const n = t.hash[h];
        if (n.key.tag != .nil and !n.val.isNil()) return .{ .key = n.key, .val = n.val };
    }
    return null;
}

// ---------------------------------------------------------------------
// Layout

/// The facts about the storage of a table that native code relies on
/// (`jit/emit.zig`). Each one is computed from the declarations above, so
/// native code follows a change of layout, and a change that breaks an
/// assumption of the templates fails to compile.
pub const layout = struct {
    /// Byte offsets in a table.
    pub const flags: i32 = @offsetOf(Table, "hdr") + @offsetOf(gc.Header, "flags");
    pub const tm_absent: i32 = @offsetOf(Table, "tm_absent");
    pub const kind: i32 = @offsetOf(Table, "kind");
    pub const metatable: i32 = @offsetOf(Table, "metatable");
    pub const array_ptr: i32 = @offsetOf(Table, "array_ptr");
    pub const asize: i32 = @offsetOf(Table, "asize");
    pub const hash_used: i32 = @offsetOf(Table, "hash_used");
    pub const readonly: i32 = @offsetOf(Table, "readonly");
    /// Bit of the flag byte that the write barrier tests.
    pub const barrier_bit: u3 = @bitOffsetOf(gc.Header.Flags, "barrier");

    /// A hash node is `1 << node_shift` bytes, and its key and value are
    /// values at these offsets.
    pub const node_shift: u6 = std.math.log2_int(usize, @sizeOf(Node));
    pub const node_key: i32 = @offsetOf(Node, "key");
    pub const node_val: i32 = @offsetOf(Node, "val");

    /// A value is its payload word followed by a word whose first byte is
    /// the tag. A boxed array slot is a value, and an unboxed slot is one
    /// word.
    pub const value_shift: u6 = 4;
    pub const word_shift: u6 = 3;
    pub const value_tag: i32 = @offsetOf(Value, "tag");

    /// The element kinds as bytes. `kind_none` holds only holes, and the
    /// other unboxed kinds equal the tag of the values they hold.
    pub const kind_none: u8 = @backingInt(ArrayKind.none);
    pub const kind_boxed: u8 = @backingInt(ArrayKind.boxed);
    /// The word an unboxed slot holds for nil.
    pub const nil_word: u64 = hole;

    /// Offsets of the pointer and of the length of the hash part. The
    /// language leaves the layout of a slice open, so they are measured.
    pub fn hashPtr() i32 {
        var t: Table = undefined;
        return @intCast(@intFromPtr(&t.hash.ptr) - @intFromPtr(&t));
    }
    pub fn hashLen() i32 {
        var t: Table = undefined;
        return @intCast(@intFromPtr(&t.hash.len) - @intFromPtr(&t));
    }

    comptime {
        const assert = std.debug.assert;
        assert(@sizeOf(Node) == @as(usize, 1) << node_shift);
        assert(@sizeOf(Value) == @as(usize, 1) << value_shift);
        assert(@offsetOf(Value, "payload") == 0 and value_tag == 8);
        assert(@backingInt(ArrayKind.none) == @backingInt(value.Tag.nil));
        assert(@backingInt(ArrayKind.int) == @backingInt(value.Tag.integer));
        assert(@backingInt(ArrayKind.float) == @backingInt(value.Tag.float));
        assert(@FieldType(Table, "tm_absent") == u16);
        assert(@FieldType(Table, "hash_used") == u32);
        assert(@FieldType(Table, "asize") == usize and @sizeOf(usize) == 8);
        assert(@FieldType(Table, "readonly") == bool);
        assert(@sizeOf(ArrayKind) == 1);
        assert(@sizeOf(gc.Header.Flags) == 1);
    }
};

const testing = std.testing;

test "array and hash parts" {
    var t: Table = .{ .hdr = .{ .tag = .table } };
    defer freeParts(testing.allocator, &t);
    var i: i64 = 1;
    while (i <= 100) : (i += 1) try setInt(testing.allocator, &t, i, Value.int(i * 2));
    try testing.expectEqual(@as(i64, 100), length(&t));
    try testing.expectEqual(@as(i64, 84), getInt(&t, 42).asInt());
    try testing.expect(t.asize >= 64);
    try testing.expectEqual(ArrayKind.int, t.kind);
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
