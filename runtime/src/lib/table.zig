//! The table library: sequence manipulation (insert, remove, move,
//! concat, pack, unpack, sort), copies and constructors (clone, create,
//! compact), and the data processing functions.
//!
//! Values that must survive an allocation or a call into Lus code are kept
//! in stack slots, never only in Zig locals, so the collector always sees
//! them.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const numeric = @import("../vm/numeric.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;

pub const funcs = [_]aux.Reg{
    .{ .name = "clone", .func = clone },
    .{ .name = "compact", .func = compact },
    .{ .name = "concat", .func = concat },
    .{ .name = "create", .func = create },
    .{ .name = "filter", .func = filter },
    .{ .name = "groupby", .func = groupby },
    .{ .name = "insert", .func = insert },
    .{ .name = "map", .func = map },
    .{ .name = "mean", .func = mean },
    .{ .name = "median", .func = median },
    .{ .name = "move", .func = move },
    .{ .name = "pack", .func = pack },
    .{ .name = "reduce", .func = reduce },
    .{ .name = "remove", .func = remove },
    .{ .name = "reshape", .func = reshape },
    .{ .name = "sort", .func = sort },
    .{ .name = "sortby", .func = sortby },
    .{ .name = "stdev", .func = stdev },
    .{ .name = "sum", .func = sum },
    .{ .name = "transpose", .func = transpose },
    .{ .name = "unpack", .func = unpack },
    .{ .name = "unzip", .func = unzip },
    .{ .name = "zip", .func = zip },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, .fields, "table", &funcs);
    try aux.setGlobal(l, "table", Value.obj(.table, t));
}

// ---------------------------------------------------------------------
// Element access honoring metamethods, as lua_geti and lua_seti do.

fn geti(l: *Thread, t: Value, i: i64) Error!Value {
    if (t.tag == .table) {
        const tab = t.as(Table);
        if (tab.metatable == null) return table.getInt(tab, i);
    }
    return ops.index(l, t, Value.int(i));
}

fn seti(l: *Thread, t: Value, i: i64, v: Value) Error!void {
    if (t.tag == .table) {
        const tab = t.as(Table);
        if (tab.metatable == null) return ops.rawSet(l, tab, Value.int(i), v);
    }
    return ops.setIndex(l, t, Value.int(i), v);
}

/// Pushes `t[i]` onto the stack.
fn pushi(l: *Thread, t: Value, i: i64) Error!void {
    try l.push(try geti(l, t, i));
}

/// Stores the value on top of the stack into `t[i]` and pops it.
fn popseti(l: *Thread, t: Value, i: i64) Error!void {
    try seti(l, t, i, l.stack[l.top - 1]);
    l.top -= 1;
}

/// The length of a value as `luaL_len` computes it.
fn lenOf(l: *Thread, v: Value) Error!i64 {
    const n = try ops.length(l, v);
    if (n.tag == .integer) return n.asInt();
    if (ops.toIntegerStrict(n)) |i| return i;
    return l.raiseFmt("object length is not an integer", .{});
}

const tab_r = 1;
const tab_w = 2;
const tab_l = 4;
const tab_rw = tab_r | tab_w;

/// Checks that argument `i` is a table or behaves like one through the
/// metamethods selected by `what`.
fn checkTab(l: *Thread, i: u32, what: u8) Error!void {
    const v = l.arg(i);
    if (v.tag == .table) return;
    if (l.metatable(v)) |mt| {
        const names = l.g.tm_names;
        const ok = (what & tab_r == 0 or !table.getStr(mt, names[@backingInt(state.TM.index)].?).isNil()) and
            (what & tab_w == 0 or !table.getStr(mt, names[@backingInt(state.TM.newindex)].?).isNil()) and
            (what & tab_l == 0 or v.tag == .string or !table.getStr(mt, names[@backingInt(state.TM.len)].?).isNil());
        if (ok) return;
    }
    return aux.typeError(l, i, "table");
}

fn getn(l: *Thread, i: u32, what: u8) Error!i64 {
    try checkTab(l, i, what | tab_l);
    return lenOf(l, l.arg(i));
}

/// Pushes a fresh table and returns it.
fn pushNewTable(l: *Thread, narr: usize, nhash: usize) Error!*Table {
    const t = try l.newTable(narr, nhash);
    try l.push(Value.obj(.table, t));
    return t;
}

fn sizeHint(n: i64) usize {
    if (n <= 0) return 0;
    return @intCast(@min(n, 1 << 24));
}

// ---------------------------------------------------------------------
// Lua 5.4 functions

fn create(l: *Thread) Error!u32 {
    const seq = try aux.checkInt(l, 1);
    const rest = try aux.optInt(l, 2, 0);
    const int_max = std.math.maxInt(i32);
    if (@as(u64, @bitCast(seq)) > int_max) return aux.argError(l, 1, "out of range", .{});
    if (@as(u64, @bitCast(rest)) > int_max) return aux.argError(l, 2, "out of range", .{});
    _ = try pushNewTable(l, @intCast(seq), @intCast(rest));
    return 1;
}

fn insert(l: *Thread) Error!u32 {
    const t = l.arg(1);
    const e = (try getn(l, 1, tab_rw)) +% 1; // first empty element
    var pos: i64 = undefined;
    switch (l.argCount()) {
        2 => pos = e,
        3 => {
            pos = try aux.checkInt(l, 2);
            // Check whether 'pos' is in [1, e].
            if (@as(u64, @bitCast(pos)) -% 1 >= @as(u64, @bitCast(e))) {
                return aux.argError(l, 2, "position out of bounds", .{});
            }
            var i = e;
            while (i > pos) : (i -= 1) {
                try pushi(l, t, i - 1);
                try popseti(l, t, i);
            }
        },
        else => return l.raiseFmt("wrong number of arguments to 'insert'", .{}),
    }
    try seti(l, t, pos, l.arg(l.argCount()));
    return 0;
}

fn remove(l: *Thread) Error!u32 {
    const t = l.arg(1);
    const size = try getn(l, 1, tab_rw);
    var pos = try aux.optInt(l, 2, size);
    if (pos != size) {
        // Check whether 'pos' is in [1, size + 1].
        if (@as(u64, @bitCast(pos)) -% 1 > @as(u64, @bitCast(size))) {
            return aux.argError(l, 2, "position out of bounds", .{});
        }
    }
    try pushi(l, t, pos); // the result
    while (pos < size) : (pos += 1) {
        try pushi(l, t, pos + 1);
        try popseti(l, t, pos);
    }
    try seti(l, t, pos, .nil);
    return 1;
}

fn move(l: *Thread) Error!u32 {
    const f = try aux.checkInt(l, 2);
    const e = try aux.checkInt(l, 3);
    const t = try aux.checkInt(l, 4);
    const tt: u32 = if (!l.arg(5).isNil()) 5 else 1;
    try checkTab(l, 1, tab_r);
    try checkTab(l, tt, tab_w);
    const src = l.arg(1);
    const dst = l.arg(tt);
    if (e >= f) {
        const max = std.math.maxInt(i64);
        if (!(f > 0 or e < max +% f)) return aux.argError(l, 3, "too many elements to move", .{});
        const n = e - f + 1;
        if (t > max - n + 1) return aux.argError(l, 4, "destination wrap around", .{});
        if (t > e or t <= f or (tt != 1 and !try ops.equal(l, src, dst))) {
            var i: i64 = 0;
            while (i < n) : (i += 1) {
                try pushi(l, src, f + i);
                try popseti(l, dst, t + i);
            }
        } else {
            var i: i64 = n - 1;
            while (i >= 0) : (i -= 1) {
                try pushi(l, src, f + i);
                try popseti(l, dst, t + i);
            }
        }
    }
    try l.push(dst);
    return 1;
}

/// Whether `s` joins any piece before it without changing either: it does
/// not start with a trail surrogate, which would pair with a lead
/// surrogate at the end of that piece.
fn joinsPlainly(s: *String) bool {
    return s.flags().ascii or @import("../vm/wtf8.zig").leadingTrailSurrogate(s.bytes()) == null;
}

fn concat(l: *Thread) Error!u32 {
    const t = l.arg(1);
    var last = try getn(l, 1, tab_r);
    const sep_given = !l.arg(2).isNil();
    if (sep_given) _ = try aux.checkString(l, 2);
    const sep = l.arg(2);
    var i = try aux.optInt(l, 3, 1);
    last = try aux.optInt(l, 4, last);
    var stack: [ops.concat_stack]u8 = undefined;
    var first = std.heap.BufferFirstAllocator.init(&stack, l.g.gpa);
    var strbuf: state.StringBuffer = .{ .g = l.g };
    var gpa = first.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // A table without a metatable is read twice: once to size the result,
    // so the bytes are copied once into one buffer, and once to append.
    if (t.tag == .table and t.as(Table).metatable == null and i <= last) {
        const tab = t.as(Table);
        const sep_room = if (sep_given) ops.concatRoom(sep) else 0;
        var room: usize = 0;
        // When every piece is a string, the room is the exact length, and
        // a long result is written straight into its string. A piece
        // that starts with a trail surrogate may join the piece before
        // it, and it takes the general path.
        var exact = !sep_given or joinsPlainly(sep.as(String));
        var ascii_all = !sep_given or sep.as(String).flags().ascii;
        var chars_all: usize = 0;
        var j = i;
        while (true) : (j += 1) {
            const v = table.getInt(tab, j);
            // A value that cannot be joined raises an error below.
            if (v.tag != .string and !v.isNumber()) {
                exact = false;
                break;
            }
            room += ops.concatRoom(v);
            if (v.tag == .string) {
                const str = v.as(String);
                exact = exact and joinsPlainly(str);
                ascii_all = ascii_all and str.flags().ascii;
                chars_all += str.chars();
            } else exact = false;
            if (j == last) break;
            room += sep_room;
            if (sep_given) chars_all += sep.as(String).chars();
        }
        if (exact and room > String.short_max) {
            const r = state.newLongUninit(l.g, room) catch return l.raiseMem();
            const dst = r.bytesMut();
            var at: usize = 0;
            j = i;
            while (true) : (j += 1) {
                const b = table.getInt(tab, j).as(String).bytes();
                @memcpy(dst[at..][0..b.len], b);
                at += b.len;
                if (j == last) break;
                if (sep_given) {
                    const sb = sep.as(String).bytes();
                    @memcpy(dst[at..][0..sb.len], sb);
                    at += sb.len;
                }
            }
            state.finishLong(l.g, r, ascii_all, chars_all);
            return aux.ret(l, Value.obj(.string, r));
        }
        // A short result of strings alone is copied once on the stack.
        if (exact and room <= stack.len) {
            var at: usize = 0;
            j = i;
            while (true) : (j += 1) {
                const b = table.getInt(tab, j).as(String).bytes();
                @memcpy(stack[at..][0..b.len], b);
                at += b.len;
                if (j == last) break;
                if (sep_given) {
                    const sb = sep.as(String).bytes();
                    @memcpy(stack[at..][0..sb.len], sb);
                    at += sb.len;
                }
            }
            const r = state.newStringFresh(l.g, stack[0..at], ascii_all, chars_all) catch return l.raiseMem();
            return aux.ret(l, Value.obj(.string, r));
        }
        // A long result is built where its string will live.
        if (ops.longResult(room)) gpa = strbuf.allocator();
        buf.ensureTotalCapacityPrecise(gpa, room) catch return l.raiseMem();
    }
    var ascii = true;
    var chars: usize = 0;
    while (i <= last) : (i += 1) {
        const v = try geti(l, t, i);
        if (v.tag != .string and !v.isNumber()) {
            return l.raiseFmt("invalid value ({s}) at index {d} in table for 'concat'", .{ value.typeName(v.tag), i });
        }
        try ops.appendForConcat(l, gpa, &buf, v, &ascii, &chars);
        if (i == last) break; // also avoids overflow when last is maxinteger
        if (sep_given) try ops.appendForConcat(l, gpa, &buf, sep, &ascii, &chars);
    }
    const s = ops.finishConcat(l.g, &strbuf, gpa, &buf, ascii, chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, s));
}

fn pack(l: *Thread) Error!u32 {
    const n = l.argCount();
    const t = try pushNewTable(l, n, 1);
    var i: u32 = 1;
    while (i <= n) : (i += 1) try ops.rawSet(l, t, Value.int(i), l.arg(i));
    try aux.setField(l, t, "n", Value.int(n));
    return 1;
}

fn unpack(l: *Thread) Error!u32 {
    const t = l.arg(1);
    const len = try getn(l, 1, tab_r);
    var i = try aux.optInt(l, 2, 1);
    const e = try aux.optInt(l, 3, len);
    if (i > e) return 0;
    const n = @as(u64, @bitCast(e)) -% @as(u64, @bitCast(i)); // count minus one
    if (n >= std.math.maxInt(i32) or n + 1 + l.top > Thread.max_stack) {
        return l.raiseFmt("too many results to unpack", .{});
    }
    try l.ensure(@intCast(n + 1));
    while (i < e) : (i += 1) try pushi(l, t, i);
    try pushi(l, t, e);
    return @intCast(n + 1);
}

// ---------------------------------------------------------------------
// Quicksort, following Lua 5.4 (Sedgewick's algorithm). The values being
// compared live on the stack exactly as in the C implementation, so the
// comparator may do anything without exposing them to the collector.

const ranlimit = 100;

const Sorter = struct {
    l: *Thread,
    t: Value,
    comp: Value,

    fn at(s: *Sorter, idx: i32) Value {
        return s.l.stack[@intCast(@as(i64, s.l.top) + idx)];
    }

    fn push(s: *Sorter, i: u64) Error!void {
        try pushi(s.l, s.t, @intCast(i));
    }

    fn pop(s: *Sorter, n: u32) void {
        s.l.top -= n;
    }

    /// True when the value at stack index `a` sorts before the one at `b`.
    fn lt(s: *Sorter, a: i32, b: i32) Error!bool {
        const va = s.at(a);
        const vb = s.at(b);
        if (s.comp.isNil()) return ops.lessThan(s.l, va, vb);
        return (try ops.call1(s.l, s.comp, &.{ va, vb })).truthy();
    }

    /// Pops the top value into t[i] and the next one into t[j].
    fn set2(s: *Sorter, i: u64, j: u64) Error!void {
        try popseti(s.l, s.t, @intCast(i));
        try popseti(s.l, s.t, @intCast(j));
    }

    /// Pivot P is on top of the stack. Precondition:
    /// a[lo] <= P == a[up-1] <= a[up]. Returns the final position of P.
    fn partition(s: *Sorter, lo: u64, up: u64) Error!u64 {
        var i = lo;
        var j = up - 1;
        while (true) {
            // Repeat ++i while a[i] < P.
            while (true) {
                i += 1;
                try s.push(i);
                if (!try s.lt(-1, -2)) break;
                if (i == up - 1) return s.l.raiseFmt("invalid order function for sorting", .{});
                s.pop(1);
            }
            // Repeat --j while P < a[j].
            while (true) {
                j -%= 1;
                try s.push(j);
                if (!try s.lt(-3, -1)) break;
                if (j < i) return s.l.raiseFmt("invalid order function for sorting", .{});
                s.pop(1);
            }
            if (j < i) {
                s.pop(1); // a[j]
                try s.set2(up - 1, i);
                return i;
            }
            try s.set2(i, j);
        }
    }

    fn choosePivot(lo: u64, up: u64, rnd: u32) u64 {
        const r4 = (up - lo) / 4;
        return (@as(u64, rnd ^ @as(u32, @truncate(lo)) ^ @as(u32, @truncate(up)))) % (r4 * 2) + (lo + r4);
    }

    fn auxsort(s: *Sorter, lo_in: u64, up_in: u64, rnd_in: u32) Error!void {
        var lo = lo_in;
        var up = up_in;
        var rnd = rnd_in;
        while (lo < up) {
            // Sort a[lo], a[p], a[up].
            try s.push(lo);
            try s.push(up);
            if (try s.lt(-1, -2)) try s.set2(lo, up) else s.pop(2);
            if (up - lo == 1) return;
            var p: u64 = if (up - lo < ranlimit or rnd == 0) (lo + up) / 2 else choosePivot(lo, up, rnd);
            try s.push(p);
            try s.push(lo);
            if (try s.lt(-2, -1)) {
                try s.set2(p, lo);
            } else {
                s.pop(1);
                try s.push(up);
                if (try s.lt(-1, -2)) try s.set2(p, up) else s.pop(2);
            }
            if (up - lo == 2) return;
            try s.push(p); // the pivot
            try s.l.push(s.at(-1));
            try s.push(up - 1);
            try s.set2(p, up - 1);
            p = try s.partition(lo, up);
            var n: u64 = undefined;
            if (p - lo < up - p) {
                try s.auxsort(lo, p - 1, rnd);
                n = p - lo;
                lo = p + 1;
            } else {
                try s.auxsort(p + 1, up, rnd);
                n = up - p;
                up = p - 1;
            }
            if ((up -% lo) / 128 > n and up > lo) rnd = randomPivotSeed(s.l);
        }
    }
};

fn randomPivotSeed(l: *Thread) u32 {
    const ns = std.Io.Clock.awake.now(l.g.io).nanoseconds;
    const x: u64 = @truncate(@as(u96, @bitCast(ns)));
    return @truncate((x ^ (x >> 29) ^ l.g.seed) *% 0x9E3779B97F4A7C15 >> 32);
}

fn sort(l: *Thread) Error!u32 {
    const n = try getn(l, 1, tab_rw);
    if (n > 1) {
        if (n >= std.math.maxInt(i32)) return aux.argError(l, 1, "array too big", .{});
        if (!l.arg(2).isNil()) _ = try aux.checkFunction(l, 2);
        // Make sure there are exactly two arguments.
        while (l.argCount() < 2) try l.push(.nil);
        l.top = l.base() + 2;
        var s: Sorter = .{ .l = l, .t = l.arg(1), .comp = l.arg(2) };
        try s.auxsort(1, @intCast(n), 0);
    }
    return 0;
}

// ---------------------------------------------------------------------
// Clone

const clone_max_depth = 200;

fn clone(l: *Thread) Error!u32 {
    const src = try aux.checkTable(l, 1);
    if (aux.optBool(l, 2, false)) {
        const map_t = try pushNewTable(l, 0, 0); // source table -> clone
        const map_slot = l.top - 1;
        _ = try cloneDeep(l, src, map_t, 0);
        // Drop the map, keep the clone.
        l.stack[map_slot] = l.stack[l.top - 1];
        l.top = map_slot + 1;
        return 1;
    }
    const dst = try pushNewTable(l, src.asize, table.hashCount(src));
    var k: Value = .nil;
    while (table.next(src, k) catch null) |kv| : (k = kv.key) {
        try ops.rawSet(l, dst, kv.key, kv.val);
    }
    if (src.metatable) |mt| setMetatable(l, dst, mt);
    return 1;
}

fn setMetatable(l: *Thread, t: *Table, mt: *Table) void {
    t.metatable = mt;
    gc.barrierBack(l.g, &t.hdr);
}

/// Leaves the clone of `src` on top of the stack.
fn cloneDeep(l: *Thread, src: *Table, map_t: *Table, depth: u32) Error!*Table {
    if (depth > clone_max_depth) return l.raiseFmt("table.clone: nesting too deep (max {d})", .{clone_max_depth});
    const key = Value.obj(.table, src);
    const existing = table.get(map_t, key);
    if (!existing.isNil()) {
        try l.push(existing);
        return existing.as(Table);
    }
    const dst = try pushNewTable(l, src.asize, table.hashCount(src));
    const dst_slot = l.top - 1;
    try ops.rawSet(l, map_t, key, Value.obj(.table, dst));
    var k: Value = .nil;
    while (table.next(src, k) catch null) |kv| : (k = kv.key) {
        var nk = kv.key;
        var nv = kv.val;
        if (nk.tag == .table) nk = Value.obj(.table, try cloneDeep(l, nk.as(Table), map_t, depth + 1));
        if (nv.tag == .table) nv = Value.obj(.table, try cloneDeep(l, nv.as(Table), map_t, depth + 1));
        try ops.rawSet(l, dst, nk, nv);
        l.top = dst_slot + 1;
    }
    if (src.metatable) |mt| setMetatable(l, dst, mt);
    return dst;
}

/// Shrinks the storage of a table to fit its live contents.
fn compact(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    var asize = t.asize;
    while (asize > 0 and table.arrayIsNil(t, asize - 1)) asize -= 1;
    var live: usize = table.hashCount(t);
    if (!t.isShaped()) {
        live = 0;
        for (0..t.hash_len) |h| {
            if (t.keyTag(h) != .nil and t.valTag(h) != .nil) live += 1;
        }
    }
    table.resize(l.g.gpa, t, asize, live) catch return l.raiseMem();
    l.top = l.base() + 1;
    return 1;
}

// ---------------------------------------------------------------------
// Aggregation. Numbers and numeric strings count, other values are
// skipped. Results are floats.

fn numericValue(l: *Thread, v: Value) ?f64 {
    if (v.isNumber()) return numeric.toFloat(l.g.gpa, v);
    if (v.tag == .string) {
        if (ops.toNumberCoerce(v)) |n| return numeric.toFloat(l.g.gpa, n);
    }
    return null;
}

/// Floating-point sums in a fixed order that SIMD loops can follow. The
/// element at index i adds into accumulator (i - 1) % 8, and the eight
/// accumulators combine pairwise: accumulator j with j + 4, then j with
/// j + 2, then the last two. Every path, unboxed or not, adds in this
/// order, so the results never depend on how a table is stored.
const lanes = 8;
const F64s = @Vector(lanes, f64);
const U64s = @Vector(lanes, u64);
const I64s = @Vector(lanes, i64);

const Term = enum { value, square };

const Lanes = struct {
    acc: [lanes]f64 = @splat(0),
    count: i64 = 0,

    /// Adds the term for `x` at the one-based index `i`.
    inline fn add(a: *Lanes, comptime term: Term, i: i64, x: f64, m: f64) void {
        const lane: usize = @intCast(@mod(i - 1, lanes));
        a.acc[lane] += termOf(term, x, m);
        a.count += 1;
    }

    fn total(a: *const Lanes) f64 {
        const v = a.acc;
        const s0 = v[0] + v[4];
        const s1 = v[1] + v[5];
        const s2 = v[2] + v[6];
        const s3 = v[3] + v[7];
        return (s0 + s2) + (s1 + s3);
    }
};

inline fn termOf(comptime term: Term, x: anytype, m: anytype) @TypeOf(x) {
    return switch (term) {
        .value => x,
        .square => (x - m) * (x - m),
    };
}

/// Accumulates the terms of the numeric values `t[1]` through `t[len]`
/// for the table argument 1. A plain table reads its array part directly,
/// eight unboxed slots at a time when it holds integers or floats.
fn accumulate(l: *Thread, len: i64, comptime term: Term, m: f64) Error!Lanes {
    var a: Lanes = .{};
    var i: i64 = 1;
    const tv = l.arg(1);
    if (tv.tag == .table and tv.as(Table).metatable == null and len > 0) {
        const t = tv.as(Table);
        const n: usize = @intCast(@min(len, @as(i64, @intCast(@min(t.asize, std.math.maxInt(i64))))));
        switch (t.kind) {
            .float => accumulateWords(.float, t.words()[0..n], &a, term, m),
            .int => accumulateWords(.int, t.words()[0..n], &a, term, m),
            .none => {},
            // Converting a value never runs Lus code, so the array part
            // stays in place during the loop.
            .boxed => for (t.values()[0..n], 1..) |v, k| {
                if (numericValue(l, v)) |x| a.add(term, @intCast(k), x, m);
            },
            .string, .table => for (0..n) |k| {
                if (numericValue(l, table.arrayGet(t, k))) |x| a.add(term, @intCast(k + 1), x, m);
            },
        }
        i = @as(i64, @intCast(n)) + 1;
    }
    while (i <= len) : (i += 1) {
        if (numericValue(l, try geti(l, l.arg(1), i))) |x| a.add(term, i, x, m);
    }
    return a;
}

/// Converts 64-bit integers to floats. The float unit of 32-bit ARM
/// converts 32-bit integers only, and the routine of the compiler
/// runtime for a 64-bit integer takes about seventy instructions. There
/// the result is the signed high word times 2^32 plus the unsigned low
/// word. Both terms are exact, so the one addition rounds as the direct
/// conversion does.
inline fn intsToFloats(x: anytype) @Vector(@typeInfo(@TypeOf(x)).vector.len, f64) {
    const n = @typeInfo(@TypeOf(x)).vector.len;
    if (comptime @import("builtin").cpu.arch != .arm) return @floatFromInt(x);
    const low: @Vector(n, u32) = @truncate(@as(@Vector(n, u64), @bitCast(x)));
    const high: @Vector(n, i32) = @truncate(x >> @splat(32));
    const scale: @Vector(n, f64) = @splat(4294967296.0);
    return @as(@Vector(n, f64), @floatFromInt(high)) * scale + @as(@Vector(n, f64), @floatFromInt(low));
}

fn accumulateWords(comptime kind: Table.ArrayKind, w: []const u64, a: *Lanes, comptime term: Term, m: f64) void {
    var acc: F64s = a.acc;
    var count: i64 = 0;
    const mv: F64s = @splat(m);
    var k: usize = 0;
    while (k + lanes <= w.len) : (k += lanes) {
        const x: U64s = w[k..][0..lanes].*;
        const live = x != @as(U64s, @splat(Table.hole));
        const xf: F64s = if (kind == .float) @bitCast(x) else intsToFloats(@as(I64s, @bitCast(x)));
        acc = @select(f64, live, acc + termOf(term, xf, mv), acc);
        count += @popCount(@as(u8, @bitCast(live)));
    }
    a.acc = acc;
    a.count += count;
    while (k < w.len) : (k += 1) {
        if (w[k] == Table.hole) continue;
        const x: f64 = if (kind == .float) @bitCast(w[k]) else intsToFloats(@as(@Vector(1, i64), @splat(@as(i64, @bitCast(w[k])))))[0];
        a.add(term, @intCast(k + 1), x, m);
    }
}

fn sum(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const len = try lenOf(l, l.arg(1));
    const a = try accumulate(l, len, .value, 0);
    return aux.ret(l, Value.float(a.total()));
}

fn mean(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const len = try lenOf(l, l.arg(1));
    const a = try accumulate(l, len, .value, 0);
    if (a.count == 0) return aux.ret(l, Value.float(std.math.nan(f64)));
    return aux.ret(l, Value.float(a.total() / @as(f64, @floatFromInt(a.count))));
}

fn floatLess(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn median(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const len = try lenOf(l, l.arg(1));
    const gpa = l.g.gpa;
    var vals: std.ArrayList(f64) = .empty;
    defer vals.deinit(gpa);
    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        if (numericValue(l, try geti(l, l.arg(1), i))) |x| vals.append(gpa, x) catch return l.raiseMem();
    }
    const n = vals.items.len;
    if (n == 0) return aux.ret(l, Value.float(std.math.nan(f64)));
    std.mem.sort(f64, vals.items, {}, floatLess);
    const r = if (n % 2 == 1) vals.items[n / 2] else (vals.items[n / 2 - 1] + vals.items[n / 2]) / 2.0;
    return aux.ret(l, Value.float(r));
}

fn stdev(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const sample = l.arg(2).truthy();
    const len = try lenOf(l, l.arg(1));
    const a = try accumulate(l, len, .value, 0);
    const count = a.count;
    if (count == 0 or (sample and count < 2)) return aux.ret(l, Value.float(std.math.nan(f64)));
    const m = a.total() / @as(f64, @floatFromInt(count));
    const q = try accumulate(l, len, .square, m);
    const div: f64 = @floatFromInt(if (sample) count - 1 else count);
    return aux.ret(l, Value.float(@sqrt(q.total() / div)));
}

// ---------------------------------------------------------------------
// Transformation

fn map(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const f = try aux.checkFunction(l, 2);
    const t = l.arg(1);
    const len = try lenOf(l, t);
    const res = try pushNewTable(l, sizeHint(len), 0);
    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        const elem = try geti(l, t, i);
        const r = try ops.call1(l, f, &.{ elem, Value.int(i) });
        try ops.rawSet(l, res, Value.int(i), r);
    }
    return 1;
}

fn filter(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const f = try aux.checkFunction(l, 2);
    const t = l.arg(1);
    const len = try lenOf(l, t);
    const res = try pushNewTable(l, 0, 0);
    var j: i64 = 1;
    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        const elem = try geti(l, t, i);
        if ((try ops.call1(l, f, &.{elem})).truthy()) {
            try ops.rawSet(l, res, Value.int(j), try geti(l, t, i));
            j += 1;
        }
    }
    return 1;
}

fn reduce(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const f = try aux.checkFunction(l, 2);
    const t = l.arg(1);
    const len = try lenOf(l, t);
    var start: i64 = undefined;
    if (!l.arg(3).isNil()) {
        try l.push(l.arg(3));
        start = 1;
    } else {
        if (len == 0) return l.raiseFmt("'reduce' on empty table with no initial value", .{});
        try pushi(l, t, 1);
        start = 2;
    }
    const acc = l.top - 1; // the accumulator slot
    var i = start;
    while (i <= len) : (i += 1) {
        const elem = try geti(l, t, i);
        l.stack[acc] = try ops.call1(l, f, &.{ l.stack[acc], elem, Value.int(i) });
    }
    return 1;
}

fn groupby(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const f = try aux.checkFunction(l, 2);
    const t = l.arg(1);
    const len = try lenOf(l, t);
    const res = try pushNewTable(l, 0, 0);
    const mark = l.top;
    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        const elem = try geti(l, t, i);
        try l.push(try ops.call1(l, f, &.{elem})); // key, kept on the stack
        const key = try ops.normKey(l, l.stack[l.top - 1]);
        l.stack[l.top - 1] = key;
        const group = table.get(res, key);
        if (group.isNil()) {
            const g = try pushNewTable(l, 1, 0);
            try ops.rawSet(l, g, Value.int(1), try geti(l, t, i));
            try ops.rawSet(l, res, key, Value.obj(.table, g));
        } else {
            // The groups are tables of this call, which no metamethod or
            // other code can reach before it returns.
            const g = group.as(Table);
            try ops.rawSet(l, g, Value.int(table.length(g) + 1), try geti(l, t, i));
        }
        l.top = mark;
    }
    return 1;
}

// ---------------------------------------------------------------------
// Sorting by key. The keys are computed once and kept in a table on the
// stack. The sort is a stable merge sort over positions.

fn sortby(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const f = try aux.checkFunction(l, 2);
    const asc = if (l.arg(3).isNil()) true else l.arg(3).truthy();
    const t = l.arg(1);
    const len = try lenOf(l, t);
    if (len <= 1) return 0;
    if (len >= std.math.maxInt(i32)) return aux.argError(l, 1, "array too big", .{});
    const n: usize = @intCast(len);
    const keys = try pushNewTable(l, n, 0);
    const vals = try pushNewTable(l, n, 0);
    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        const elem = try geti(l, t, i);
        try ops.rawSet(l, vals, Value.int(i), elem);
        try ops.rawSet(l, keys, Value.int(i), try ops.call1(l, f, &.{elem}));
    }
    const gpa = l.g.gpa;
    const idx = gpa.alloc(u32, n) catch return l.raiseMem();
    defer gpa.free(idx);
    const tmp = gpa.alloc(u32, n) catch return l.raiseMem();
    defer gpa.free(tmp);
    for (idx, 0..) |*p, k| p.* = @intCast(k + 1);
    var ctx: KeyOrder = .{ .l = l, .keys = keys, .asc = asc };
    try mergeSort(&ctx, idx, tmp);
    for (idx, 1..) |p, k| try seti(l, t, @intCast(k), table.getInt(vals, p));
    return 0;
}

const KeyOrder = struct {
    l: *Thread,
    keys: *Table,
    asc: bool,

    fn before(c: *KeyOrder, a: u32, b: u32) Error!bool {
        const ka = table.getInt(c.keys, a);
        const kb = table.getInt(c.keys, b);
        return if (c.asc) ops.lessThan(c.l, ka, kb) else ops.lessThan(c.l, kb, ka);
    }
};

fn mergeSort(c: *KeyOrder, a: []u32, tmp: []u32) Error!void {
    if (a.len <= 1) return;
    if (a.len <= 8) {
        // Insertion sort for short runs.
        var i: usize = 1;
        while (i < a.len) : (i += 1) {
            const x = a[i];
            var j = i;
            while (j > 0 and try c.before(x, a[j - 1])) : (j -= 1) a[j] = a[j - 1];
            a[j] = x;
        }
        return;
    }
    const mid = a.len / 2;
    try mergeSort(c, a[0..mid], tmp[0..mid]);
    try mergeSort(c, a[mid..], tmp[mid..]);
    @memcpy(tmp[0..a.len], a);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < a.len) : (k += 1) {
        if (try c.before(tmp[j], tmp[i])) {
            a[k] = tmp[j];
            j += 1;
        } else {
            a[k] = tmp[i];
            i += 1;
        }
    }
    while (i < mid) : (k += 1) {
        a[k] = tmp[i];
        i += 1;
    }
    while (j < a.len) : (k += 1) {
        a[k] = tmp[j];
        j += 1;
    }
}

// ---------------------------------------------------------------------
// Combining and matrices

fn zip(l: *Thread) Error!u32 {
    const nargs = l.argCount();
    if (nargs == 0) {
        _ = try pushNewTable(l, 0, 0);
        return 1;
    }
    var minlen: i64 = std.math.maxInt(i64);
    var k: u32 = 1;
    while (k <= nargs) : (k += 1) {
        _ = try aux.checkTable(l, k);
        const n = try lenOf(l, l.arg(k));
        if (n < minlen) minlen = n;
    }
    const res = try pushNewTable(l, sizeHint(minlen), 0);
    var i: i64 = 1;
    while (i <= minlen) : (i += 1) {
        const tuple = try pushNewTable(l, nargs, 0);
        k = 1;
        while (k <= nargs) : (k += 1) try ops.rawSet(l, tuple, Value.int(k), try geti(l, l.arg(k), i));
        try ops.rawSet(l, res, Value.int(i), Value.obj(.table, tuple));
        l.top -= 1;
    }
    return 1;
}

/// The error luaL_checktype raises for a value at a negative stack index.
fn checkTableAt(l: *Thread, v: Value) Error!void {
    if (v.tag != .table) {
        return l.raiseFmt("bad argument #-1 to '{s}' (table expected, got {s})", .{ aux.fnName(l), l.typeNameOf(v) });
    }
}

fn unzip(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const t = l.arg(1);
    const n = try lenOf(l, t);
    if (n == 0) return 0;
    const first = try geti(l, t, 1);
    try checkTableAt(l, first);
    const w = try lenOf(l, first);
    if (w <= 0) return 0;
    if (w + 2 + l.top >= Thread.max_stack) return l.raiseFmt("too many columns to unzip", .{});
    const base = l.top;
    var j: i64 = 1;
    while (j <= w) : (j += 1) _ = try pushNewTable(l, sizeHint(n), 0);
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        try pushi(l, t, i);
        const tuple = l.stack[l.top - 1];
        j = 1;
        while (j <= w) : (j += 1) {
            const v = try geti(l, tuple, j);
            try ops.rawSet(l, l.stack[base + @as(u32, @intCast(j - 1))].as(Table), Value.int(i), v);
        }
        l.top -= 1;
    }
    return @intCast(w);
}

fn transpose(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const m = l.arg(1);
    const rows = try lenOf(l, m);
    if (rows == 0) {
        _ = try pushNewTable(l, 0, 0);
        return 1;
    }
    const first = try geti(l, m, 1);
    try checkTableAt(l, first);
    const cols = try lenOf(l, first);
    var i: i64 = 2;
    while (i <= rows) : (i += 1) {
        const row = try geti(l, m, i);
        try checkTableAt(l, row);
        if (try lenOf(l, row) != cols) return l.raiseFmt("non-rectangular matrix in 'transpose'", .{});
    }
    const res = try pushNewTable(l, sizeHint(cols), 0);
    var j: i64 = 1;
    while (j <= cols) : (j += 1) {
        const nrow = try pushNewTable(l, sizeHint(rows), 0);
        i = 1;
        while (i <= rows) : (i += 1) {
            try pushi(l, m, i);
            const v = try geti(l, l.stack[l.top - 1], j);
            l.top -= 1;
            try ops.rawSet(l, nrow, Value.int(i), v);
        }
        try ops.rawSet(l, res, Value.int(j), Value.obj(.table, nrow));
        l.top -= 1;
    }
    return 1;
}

fn reshape(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const nrows = try aux.checkInt(l, 2);
    const ncols = try aux.checkInt(l, 3);
    const t = l.arg(1);
    const len = try lenOf(l, t);
    if (nrows <= 0) return aux.argError(l, 2, "rows must be positive", .{});
    if (ncols <= 0) return aux.argError(l, 3, "cols must be positive", .{});
    if (nrows > @divTrunc(std.math.maxInt(i64), ncols) or len != nrows * ncols) {
        return l.raiseFmt("array length {d} does not match {d} x {d}", .{ len, nrows, ncols });
    }
    const res = try pushNewTable(l, sizeHint(nrows), 0);
    var r: i64 = 1;
    while (r <= nrows) : (r += 1) {
        const row = try pushNewTable(l, sizeHint(ncols), 0);
        var c: i64 = 1;
        while (c <= ncols) : (c += 1) try ops.rawSet(l, row, Value.int(c), try geti(l, t, (r - 1) * ncols + c));
        try ops.rawSet(l, res, Value.int(r), Value.obj(.table, row));
        l.top -= 1;
    }
    return 1;
}
