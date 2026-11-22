//! Query objects and query execution.
//!
//! The `query` instruction builds a query object from a plan string
//! constant and a run of registers: the source values, then the clause
//! functions and captured parameters that `compile/query_gen.zig` laid out.
//! Building only copies those values, so a query is cheap to create and
//! runs again from scratch on every `query(q)` call.
//!
//! Execution follows a fixed logical pipeline: fetch each source, join,
//! where, group, having, select and distinct, order, then limit and
//! offset. The clause logic itself is compiled bytecode. This file drives
//! one fused loop over the cross product of the sources that calls the
//! step function once per tuple and streams records straight into the
//! result, with no intermediate tuple or record arrays. Only grouping and
//! ordering keep extra state.
//!
//! Semantics are SQL flavored so a query returns the same rows from a
//! plain table and from SQLite: a comparison with a nil operand is false,
//! nil orders first ascending, aggregates over zero rows yield an absent
//! field except count, and a nil value never becomes a record field.
//!
//! A source is a plain table of records, a value whose metatable has
//! `__query` (called as `__query(source, q, index)`, returning a row
//! iterator), or a SQLite table reference. Where conjuncts that read only
//! a SQLite source and translate to SQL with identical semantics push down
//! into the SELECT, and the step function skips them.

const std = @import("std");
const gc = @import("gc.zig");
const state = @import("state.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const table = @import("table.zig");
const ops = @import("ops.zig");
const qgen = @import("../compile/query_gen.zig");
const aux = @import("../lib/auxlib.zig");
// A build without SQLite (`-Dsqlite=false`) has no table references, so
// every source is classified as memory or metamethod.
const sqlite = if (@import("build_options").sqlite) @import("../lib/sqlite.zig") else struct {
    const TableRefInfo = struct { name: *object.String };
    fn toTableRef(_: *Thread, _: Value) ?TableRefInfo {
        return null;
    }
    fn appendIdent(_: std.mem.Allocator, _: *std.ArrayList(u8), _: []const u8) !void {
        unreachable;
    }
    fn openSelect(_: *Thread, _: TableRefInfo, _: []const u8, _: []const Value) Error!Value {
        unreachable;
    }
};

const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

pub const Query = struct {
    hdr: gc.Header,
    nsrc: u32,
    nvals: u32,
    plan_str: Value,
    /// The decoded plan, built on first execution and owned by the query.
    plan: ?*Plan,

    pub fn allocSize(n: usize) usize {
        return @sizeOf(Query) + n * @sizeOf(Value);
    }
    pub fn allocSizeOf(h: *gc.Header) usize {
        return allocSize(h.as(Query).nvals);
    }
    pub fn vals(q: *Query) []Value {
        const base: [*]u8 = @ptrCast(q);
        const p: [*]Value = @ptrCast(@alignCast(base + @sizeOf(Query)));
        return p[0..q.nvals];
    }
    fn operand(q: *Query, i: u32) Value {
        return q.vals()[q.nsrc + i];
    }
    pub fn freeExtra(g: *state.Global, h: *gc.Header) void {
        const q = h.as(Query);
        if (q.plan) |p| {
            p.arena.deinit();
            g.gpa.destroy(p);
            q.plan = null;
        }
    }
    pub fn traverse(m: anytype, h: *gc.Header) void {
        const q = h.as(Query);
        m.mark(q.plan_str);
        for (q.vals()) |v| m.mark(v);
    }
};

// ---------------------------------------------------------------------
// Plans

const Sql = struct {
    tag: u8,
    a: ?*Sql = null,
    b: ?*Sql = null,
    int: i64 = 0,
    str: []const u8 = "",
};

/// A column of a source, which a join conjunct names.
const Column = struct { src: u32, name: []const u8 };

const Conj = struct {
    mask: u32,
    opaque_: bool,
    sql: ?*Sql,
    /// The two columns of a conjunct that compares a column of one source
    /// with a column of another for equality.
    join: ?[2]Column = null,
};

const AggCode = qgen.agg_codes;

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    nsrc: u32,
    nops: u32,
    flags: u32,
    op_step: u32,
    op_final: ?u32,
    op_lo: ?u32,
    err: []const u8,
    nkeys: u32,
    aggs: []u8,
    desc: []bool,
    sel: []?[]const u8,
    conj: []Conj,
    aliases: [][]const u8,

    fn has(p: *const Plan, f: u32) bool {
        return p.flags & f != 0;
    }
};

const Reader = struct {
    s: []const u8,
    i: usize = 0,

    fn int(r: *Reader) ?i64 {
        var neg = false;
        if (r.i < r.s.len and r.s[r.i] == '-') {
            neg = true;
            r.i += 1;
        }
        const start = r.i;
        var v: i64 = 0;
        while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') : (r.i += 1) {
            const d: i64 = r.s[r.i] - '0';
            v = std.math.mul(i64, v, 10) catch return null;
            v = (if (neg) std.math.sub(i64, v, d) else std.math.add(i64, v, d)) catch return null;
        }
        if (r.i == start or r.i >= r.s.len or r.s[r.i] != ' ') return null;
        r.i += 1;
        return v;
    }
    fn count(r: *Reader, max: i64) ?u32 {
        const v = r.int() orelse return null;
        if (v < 0 or v > max) return null;
        return @intCast(v);
    }
    fn str(r: *Reader) ?[]const u8 {
        const start = r.i;
        var n: usize = 0;
        while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') : (r.i += 1) {
            n = std.math.mul(usize, n, 10) catch return null;
            n = std.math.add(usize, n, r.s[r.i] - '0') catch return null;
        }
        if (r.i == start or r.i >= r.s.len or r.s[r.i] != ':') return null;
        r.i += 1;
        if (n > r.s.len - r.i) return null;
        const out = r.s[r.i .. r.i + n];
        r.i += n;
        if (r.i >= r.s.len or r.s[r.i] != ' ') return null;
        r.i += 1;
        return out;
    }
    fn tag(r: *Reader) ?u8 {
        if (r.i + 1 >= r.s.len or r.s[r.i + 1] != ' ') return null;
        const t = r.s[r.i];
        r.i += 2;
        return t;
    }
};

const Header = struct { nsrc: u32, nops: u32 };

fn readHeader(r: *Reader) ?Header {
    if (r.s.len < 3 or !std.mem.eql(u8, r.s[0..3], "Q1 ")) return null;
    r.i = 3;
    const nsrc = r.count(qgen.max_sources) orelse return null;
    if (nsrc == 0) return null;
    const nops = r.count(255) orelse return null;
    return .{ .nsrc = nsrc, .nops = nops };
}

fn readSql(r: *Reader, a: std.mem.Allocator, nops: u32, depth: u32) ?*Sql {
    if (depth > 200) return null;
    const t = r.tag() orelse return null;
    const n = a.create(Sql) catch return null;
    n.* = .{ .tag = t };
    switch (t) {
        'C', 'S' => n.str = r.str() orelse return null,
        'I', 'F' => n.int = r.int() orelse return null,
        'P' => {
            const i = r.int() orelse return null;
            if (i < 0 or i >= nops) return null;
            n.int = i;
        },
        'N' => {},
        'E', 'D', 'L', 'M', 'G', 'H', 'A', 'O', 'a', 's', 'm', 'c' => {
            n.a = readSql(r, a, nops, depth + 1) orelse return null;
            n.b = readSql(r, a, nops, depth + 1) orelse return null;
        },
        'u' => n.a = readSql(r, a, nops, depth + 1) orelse return null,
        else => return null,
    }
    return n;
}

fn optOp(r: *Reader, nops: u32) ??u32 {
    const v = r.int() orelse return null;
    if (v == -1) return @as(?u32, null);
    if (v < 0 or v >= nops) return null;
    return @as(?u32, @intCast(v));
}

/// Decodes and validates a plan string. Dumped chunks are untrusted, so
/// every count and index is checked. Returns null on a malformed plan.
fn decode(gpa: std.mem.Allocator, s: []const u8) ?*Plan {
    const p = gpa.create(Plan) catch return null;
    p.arena = .init(gpa);
    if (decodeInto(p, s)) return p;
    p.arena.deinit();
    gpa.destroy(p);
    return null;
}

fn decodeInto(p: *Plan, s: []const u8) bool {
    const a = p.arena.allocator();
    var r: Reader = .{ .s = s };
    const h = readHeader(&r) orelse return false;
    p.nsrc = h.nsrc;
    p.nops = h.nops;
    p.flags = r.count(63) orelse return false;
    p.op_step = (optOp(&r, h.nops) orelse return false) orelse return false;
    p.op_final = optOp(&r, h.nops) orelse return false;
    p.op_lo = optOp(&r, h.nops) orelse return false;
    if (p.has(qgen.flag_grouped) and p.op_final == null) return false;
    if ((p.has(qgen.flag_limit) or p.has(qgen.flag_offset)) and p.op_lo == null) return false;
    p.err = r.str() orelse return false;
    p.nkeys = r.count(64) orelse return false;
    const naggs = r.count(255) orelse return false;
    p.aggs = a.alloc(u8, naggs) catch return false;
    for (p.aggs) |*g| g.* = @intCast(r.count(5) orelse return false);
    const norder = r.count(64) orelse return false;
    p.desc = a.alloc(bool, norder) catch return false;
    for (p.desc) |*d| d.* = (r.count(1) orelse return false) == 1;
    const nsel = r.count(64) orelse return false;
    p.sel = a.alloc(?[]const u8, nsel) catch return false;
    for (p.sel) |*it| {
        it.* = if ((r.count(1) orelse return false) == 1) (r.str() orelse return false) else null;
    }
    const nconj = r.count(qgen.max_conjuncts) orelse return false;
    p.conj = a.alloc(Conj, nconj) catch return false;
    for (p.conj) |*cj| {
        cj.mask = r.count(0xff) orelse return false;
        cj.opaque_ = (r.count(1) orelse return false) == 1;
        cj.join = null;
        if (r.i < s.len and s[r.i] == 'X') {
            _ = r.tag() orelse return false;
            cj.sql = null;
        } else if (r.i < s.len and s[r.i] == 'J') {
            _ = r.tag() orelse return false;
            cj.sql = null;
            var cols: [2]Column = undefined;
            for (&cols) |*col| {
                col.src = r.count(h.nsrc - 1) orelse return false;
                col.name = r.str() orelse return false;
            }
            if (cols[0].src == cols[1].src) return false;
            cj.join = cols;
        } else {
            cj.sql = readSql(&r, a, h.nops, 0) orelse return false;
        }
    }
    p.aliases = a.alloc([]const u8, h.nsrc) catch return false;
    for (p.aliases) |*al| al.* = r.str() orelse return false;
    return r.i == s.len;
}

fn corrupt(l: *Thread) Error {
    return l.raiseFmt("corrupt query plan in bytecode", .{});
}

/// Builds a query object from plan `plan_v` and the values starting at
/// stack slot `first`.
pub fn build(l: *Thread, plan_v: Value, first: u32) Error!Value {
    if (plan_v.tag != .string) return corrupt(l);
    var r: Reader = .{ .s = plan_v.as(String).bytes() };
    const h = readHeader(&r) orelse return corrupt(l);
    const n = h.nsrc + h.nops;
    if (@as(usize, first) + n > l.stack.len) return corrupt(l);
    gc.maybeCollect(l.g);
    const q = gc.alloc(l.g, Query, .query, Query.allocSize(n)) catch return l.raiseMem();
    q.nsrc = h.nsrc;
    q.nvals = n;
    q.plan_str = plan_v;
    q.plan = null;
    @memcpy(q.vals(), l.stack[first .. first + n]);
    return Value.obj(.query, q);
}

fn planOf(l: *Thread, q: *Query) Error!*Plan {
    if (q.plan) |p| return p;
    const p = decode(l.g.gpa, q.plan_str.as(String).bytes()) orelse return corrupt(l);
    if (p.nsrc != q.nsrc or p.nsrc + p.nops != q.nvals) {
        p.arena.deinit();
        l.g.gpa.destroy(p);
        return corrupt(l);
    }
    q.plan = p;
    return p;
}

// ---------------------------------------------------------------------
// Source classification and SQL push-down

const SourceKind = enum { memory, metamethod, native };

fn queryMetamethod(l: *Thread, v: Value) Error!Value {
    const mt = l.metatable(v) orelse return .nil;
    const key = try l.newString("__query");
    return table.getStr(mt, key);
}

fn classify(l: *Thread, v: Value) Error!SourceKind {
    if (sqlite.toTableRef(l, v) != null) return .native;
    if (!(try queryMetamethod(l, v)).isNil()) return .metamethod;
    return .memory;
}

/// Would SQLite evaluate this tree exactly as the in-memory engine does,
/// given the current parameter values?
fn sqlAccepts(q: *Query, n: *const Sql) bool {
    switch (n.tag) {
        'P' => {
            const v = q.operand(@intCast(n.int));
            return switch (v.tag) {
                .nil, .integer, .float, .string => true,
                else => false,
            };
        },
        'C', 'N', 'I', 'F', 'S' => return true,
        'u' => return sqlAccepts(q, n.a.?),
        else => return sqlAccepts(q, n.a.?) and sqlAccepts(q, n.b.?),
    }
}

const SqlGen = struct {
    l: *Thread,
    q: *Query,
    out: std.ArrayList(u8) = .empty,
    /// Bound values. Strings created here stay rooted on the stack.
    binds: std.ArrayList(Value) = .empty,

    fn deinit(g: *SqlGen) void {
        g.out.deinit(g.l.g.gpa);
        g.binds.deinit(g.l.g.gpa);
    }
    fn add(g: *SqlGen, s: []const u8) Error!void {
        g.out.appendSlice(g.l.g.gpa, s) catch return g.l.raiseMem();
    }
    fn bind(g: *SqlGen, v: Value) Error!void {
        if (g.binds.items.len >= 200) return g.l.raiseFmt("query too complex", .{});
        g.binds.append(g.l.g.gpa, v) catch return g.l.raiseMem();
        try g.add("?");
    }
    fn expr(g: *SqlGen, n: *const Sql) Error!void {
        const l = g.l;
        switch (n.tag) {
            'C' => sqlite.appendIdent(l.g.gpa, &g.out, n.str) catch return l.raiseMem(),
            'P' => try g.bind(g.q.operand(@intCast(n.int))),
            'N' => try g.bind(.nil),
            'I' => try g.bind(Value.int(n.int)),
            'F' => try g.bind(Value.float(@bitCast(n.int))),
            'S' => {
                const sv = try l.newStringValue(n.str);
                try l.push(sv);
                try g.bind(sv);
            },
            'u' => {
                try g.add("(-");
                try g.expr(n.a.?);
                try g.add(")");
            },
            else => {
                const op: []const u8 = switch (n.tag) {
                    'E' => " = ",
                    'D' => " <> ",
                    'L' => " < ",
                    'M' => " <= ",
                    'G' => " > ",
                    'H' => " >= ",
                    'A' => " AND ",
                    'O' => " OR ",
                    'a' => " + ",
                    's' => " - ",
                    'm' => " * ",
                    'c' => " || ",
                    else => return corrupt(l),
                };
                try g.add("(");
                try g.expr(n.a.?);
                try g.add(op);
                try g.expr(n.b.?);
                try g.add(")");
            },
        }
    }
};

/// Marks in `pushed` the conjuncts that a native provider accepts for
/// source `i`, and returns how many.
fn pushable(q: *Query, p: *const Plan, i: u32, pushed: []bool) u32 {
    var n: u32 = 0;
    for (p.conj, 0..) |cj, ci| {
        if (cj.opaque_ or cj.mask != (@as(u32, 1) << @intCast(i))) continue;
        const tree = cj.sql orelse continue;
        if (!sqlAccepts(q, tree)) continue;
        pushed[ci] = true;
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------
// Fetching sources

/// Drains the row iterator `iter` into a new table and returns it with its
/// row count. The table is pushed on the stack.
fn drain(l: *Thread, iter: Value) Error!struct { t: *Table, n: i64 } {
    const t = try l.newTable(0, 0);
    try l.push(Value.obj(.table, t));
    var k: i64 = 0;
    while (true) {
        const row = try ops.call1(l, iter, &.{});
        if (row.isNil()) break;
        k += 1;
        try ops.rawSet(l, t, Value.int(k), row);
    }
    return .{ .t = t, .n = k };
}

/// Fetches source `i` into stack slot `slot` and returns its row count.
fn fetch(l: *Thread, q: *Query, qv: Value, p: *const Plan, i: u32, slot: u32, pushed: []bool, window: ?Window) Error!i64 {
    const src = q.vals()[i];
    const top = l.top;
    if (sqlite.toTableRef(l, src)) |ref| {
        _ = pushable(q, p, i, pushed);
        var g: SqlGen = .{ .l = l, .q = q };
        defer g.deinit();
        try g.add("SELECT * FROM ");
        sqlite.appendIdent(l.g.gpa, &g.out, ref.name.bytes()) catch return l.raiseMem();
        var first = true;
        for (p.conj, 0..) |cj, ci| {
            if (!pushed[ci] or cj.mask != (@as(u32, 1) << @intCast(i))) continue;
            try g.add(if (first) " WHERE " else " AND ");
            first = false;
            try g.expr(cj.sql.?);
        }
        if (window) |w| {
            try g.add(" LIMIT ");
            try g.bind(Value.int(w.limit));
            try g.add(" OFFSET ");
            try g.bind(Value.int(w.offset));
        }
        // A table reference exists only where the program reaches SQLite.
        const open_select = aux.guarded(.fields, "io", "sqlite", "query", sqlite.openSelect) orelse unreachable;
        const iter = try open_select(l, ref, g.out.items, g.binds.items);
        try l.push(iter);
        const d = try drain(l, iter);
        l.stack[slot] = Value.obj(.table, d.t);
        l.top = top;
        return d.n;
    }
    const mm = try queryMetamethod(l, src);
    if (!mm.isNil()) {
        const iter = try ops.call1(l, mm, &.{ src, qv, Value.int(i + 1) });
        if (iter.tag != .closure and iter.tag != .native) return l.raiseFmt("'__query' must return a function", .{});
        try l.push(iter);
        const d = try drain(l, iter);
        l.stack[slot] = Value.obj(.table, d.t);
        l.top = top;
        return d.n;
    }
    if (src.tag != .table) return l.raiseFmt("value of type '{s}' is not queryable", .{l.typeNameOf(src)});
    const t = src.as(Table);
    if (t.metatable == null) {
        // A plain array of records is read in place.
        var k: i64 = 1;
        while (true) : (k += 1) {
            const row = table.getInt(t, k);
            if (row.isNil()) break;
            if (row.tag != .table) return l.raiseFmt("query source row {d} is not a record", .{k});
        }
        l.stack[slot] = src;
        return k - 1;
    }
    const copy = try l.newTable(0, 0);
    try l.push(Value.obj(.table, copy));
    var k: i64 = 1;
    while (true) : (k += 1) {
        const row = try ops.index(l, src, Value.int(k));
        if (row.isNil()) break;
        if (row.tag != .table) return l.raiseFmt("query source row {d} is not a record", .{k});
        try ops.rawSet(l, copy, Value.int(k), row);
    }
    l.stack[slot] = Value.obj(.table, copy);
    l.top = top;
    return k - 1;
}

// ---------------------------------------------------------------------
// Keys

var nil_sentinel: u8 = 0;

/// Normalizes a group or distinct key: nil and NaN share one stand-in key.
fn normKey(l: *Thread, v: Value, strict: bool) Error!Value {
    switch (v.tag) {
        .nil => return Value.light(&nil_sentinel),
        .float => if (std.math.isNan(v.asFloat())) return Value.light(&nil_sentinel),
        .true, .false, .integer, .bigint, .decimal, .string, .enum_value => {},
        else => if (strict) return l.raiseFmt("query group key must be a primitive value, got {s}", .{value.typeName(v.tag)}),
    }
    return v;
}

/// Walks (and extends) a nested key map rooted at `map` through `keys`,
/// returning the leaf table.
fn keyLeaf(l: *Thread, map: *Table, keys: []const Value) Error!*Table {
    var level = map;
    for (keys) |k| {
        const sub = table.get(level, try ops.normKey(l, k));
        if (sub.tag == .table) {
            level = sub.as(Table);
        } else {
            const t = try l.newTable(0, 0);
            try ops.rawSet(l, level, k, Value.obj(.table, t));
            level = t;
        }
    }
    return level;
}

// ---------------------------------------------------------------------
// Ordering

const OrderClass = enum { number, string, boolean, other };

fn orderClass(v: Value) OrderClass {
    return switch (v.tag) {
        .integer, .float, .bigint, .decimal => .number,
        .string => .string,
        .true, .false => .boolean,
        else => .other,
    };
}

/// Compares two order keys. The keys never allocate while comparing, so
/// they can sit in a plain slice during the sort (they stay rooted in the
/// keys table).
fn keyCompare(l: *Thread, a: Value, b: Value) Error!i32 {
    if (a.tag == .integer and b.tag == .integer) return orderInt(a.asInt(), b.asInt());
    if (a.isNil() or b.isNil()) return if (a.isNil() and b.isNil()) 0 else if (a.isNil()) -1 else 1;
    const ca = orderClass(a);
    const cb = orderClass(b);
    if (ca != cb) return l.raiseFmt("cannot order rows on a {s} value", .{value.typeName(b.tag)});
    switch (ca) {
        .number, .string => {
            if (a.tag == .float and b.tag == .float) return orderFloat(a.asFloat(), b.asFloat());
            return if (try ops.lessThan(l, a, b)) -1 else if (try ops.lessThan(l, b, a)) 1 else 0;
        },
        .boolean => {
            const ba = a.truthy();
            const bb = b.truthy();
            return if (ba == bb) 0 else if (ba) 1 else -1;
        },
        .other => return l.raiseFmt("cannot order rows on a {s} value", .{value.typeName(a.tag)}),
    }
}

fn orderInt(a: i64, b: i64) i32 {
    return @as(i32, @intFromBool(a > b)) - @as(i32, @intFromBool(a < b));
}

fn orderFloat(a: f64, b: f64) i32 {
    return @as(i32, @intFromBool(a > b)) - @as(i32, @intFromBool(a < b));
}

const Sorter = struct {
    l: *Thread,
    desc: []const bool,
    keys: []const Value,

    fn compare(s: *const Sorter, ia: u32, ib: u32) Error!i32 {
        const nk = s.desc.len;
        const ka = s.keys[ia * nk ..][0..nk];
        const kb = s.keys[ib * nk ..][0..nk];
        for (ka, kb, s.desc) |a, b, desc| {
            var res = try keyCompare(s.l, a, b);
            if (desc) res = -res;
            if (res != 0) return res;
        }
        return 0;
    }

    /// Orders by key and then by arrival.
    fn before(s: *const Sorter, a: u32, b: u32) Error!bool {
        const c = try s.compare(a, b);
        return c < 0 or (c == 0 and a < b);
    }

    /// Moves the `m` ids of `ids` that come first by key and then by
    /// arrival to its front, in no order, and returns them. A heap keeps
    /// the `m` best so far with the last of them on top.
    fn smallest(s: *const Sorter, ids: []u32, m: usize) Error![]u32 {
        const h = ids[0..m];
        var i = m / 2;
        while (i > 0) {
            i -= 1;
            try s.siftDown(h, i);
        }
        for (ids[m..]) |id| {
            if (try s.before(id, h[0])) {
                h[0] = id;
                try s.siftDown(h, 0);
            }
        }
        return h;
    }

    fn siftDown(s: *const Sorter, h: []u32, start: usize) Error!void {
        var i = start;
        while (true) {
            var big = i;
            const a = 2 * i + 1;
            const b = a + 1;
            if (a < h.len and try s.before(h[big], h[a])) big = a;
            if (b < h.len and try s.before(h[big], h[b])) big = b;
            if (big == i) return;
            std.mem.swap(u32, &h[i], &h[big]);
            i = big;
        }
    }

    /// Stable merge sort of record ids.
    fn sort(s: *const Sorter, perm: []u32, tmp: []u32) Error!void {
        if (perm.len < 2) return;
        const mid = perm.len / 2;
        try s.sort(perm[0..mid], tmp[0..mid]);
        try s.sort(perm[mid..], tmp[mid..]);
        // Already ordered halves need no merge.
        if (try s.compare(perm[mid - 1], perm[mid]) <= 0) return;
        var a: usize = 0;
        var b: usize = mid;
        var i: usize = 0;
        while (i < perm.len) : (i += 1) {
            if (a < mid and (b >= perm.len or try s.compare(perm[a], perm[b]) <= 0)) {
                tmp[i] = perm[a];
                a += 1;
            } else {
                tmp[i] = perm[b];
                b += 1;
            }
        }
        @memcpy(perm, tmp[0..perm.len]);
    }
};

// ---------------------------------------------------------------------
// Limit and offset

fn countValue(l: *Thread, v: Value, comptime what: []const u8) Error!i64 {
    const n = switch (v.tag) {
        .integer => v.asInt(),
        .float => ops.floatToInt(v.asFloat()),
        .string => if (ops.toNumberCoerce(v)) |num| ops.toIntegerStrict(num) else null,
        else => null,
    } orelse return l.raiseFmt("query " ++ what ++ " must be a number", .{});
    if (n < 0) return l.raiseFmt("query " ++ what ++ " must be a nonnegative number", .{});
    return n;
}

// ---------------------------------------------------------------------
// Aggregates

const Acc = struct {
    n: i64 = 0,
    isum: i64 = 0,
    fsum: f64 = 0,
    mode: enum { int, float, generic } = .int,
    seen: bool = false,
};

fn aggError(l: *Thread, v: Value) Error {
    return l.raiseFmt("cannot aggregate a {s} value", .{l.typeNameOf(v)});
}

/// Folds `v` into aggregate `j` of a group. Best values and generic sums
/// live in the group's state table at slot `slot`.
fn accumulate(l: *Thread, code: u8, acc: *Acc, gstate: *Table, slot: i64, v: Value) Error!void {
    if (v.isNil()) return;
    switch (code) {
        AggCode.count => acc.n += 1,
        AggCode.sum, AggCode.avg => {
            if (!v.isNumber()) return aggError(l, v);
            acc.n += 1;
            if (acc.mode == .int and v.tag == .integer) {
                const r = @addWithOverflow(acc.isum, v.asInt());
                if (r[1] != 0) return l.raiseFmt("integer overflow in sum", .{});
                acc.isum = r[0];
                return;
            }
            if (acc.mode == .int) {
                if (v.tag == .float) {
                    acc.fsum = @floatFromInt(acc.isum);
                    acc.mode = .float;
                } else {
                    try ops.rawSet(l, gstate, Value.int(slot), Value.int(acc.isum));
                    acc.mode = .generic;
                }
            } else if (acc.mode == .float and v.tag != .float and v.tag != .integer) {
                try ops.rawSet(l, gstate, Value.int(slot), Value.float(acc.fsum));
                acc.mode = .generic;
            }
            switch (acc.mode) {
                .float => acc.fsum += ops.toFloat(v),
                .generic => {
                    const cur = table.getInt(gstate, slot);
                    try ops.rawSet(l, gstate, Value.int(slot), try ops.arith(l, .add, cur, v));
                },
                .int => unreachable,
            }
        },
        AggCode.min, AggCode.max => {
            if (!v.isNumber() and v.tag != .string) return aggError(l, v);
            var take = true;
            if (acc.seen) {
                const best = table.getInt(gstate, slot);
                if (best.isNumber() != v.isNumber()) return aggError(l, v);
                take = if (code == AggCode.min) try ops.lessThan(l, v, best) else try ops.lessThan(l, best, v);
            }
            if (take) try ops.rawSet(l, gstate, Value.int(slot), v);
            acc.seen = true;
        },
        else => {},
    }
}

fn aggResult(l: *Thread, code: u8, acc: *const Acc, ntuples: i64, gstate: *Table, slot: i64) Error!Value {
    switch (code) {
        AggCode.count_star => return Value.int(ntuples),
        AggCode.count => return Value.int(acc.n),
        AggCode.sum, AggCode.avg => {
            if (acc.n == 0) return .nil;
            const total: Value = switch (acc.mode) {
                .int => Value.int(acc.isum),
                .float => Value.float(acc.fsum),
                .generic => table.getInt(gstate, slot),
            };
            if (code == AggCode.sum) return total;
            if (total.tag == .bigint or total.tag == .decimal) return ops.arith(l, .div, total, Value.int(acc.n));
            return Value.float(ops.toFloat(total) / @as(f64, @floatFromInt(acc.n)));
        },
        AggCode.min, AggCode.max => return table.getInt(gstate, slot),
        else => return .nil,
    }
}

// ---------------------------------------------------------------------
// Indexed joins

/// A join conjunct lets the odometer visit only the rows of its inner
/// source whose column equals the column of the current row of the outer
/// source, when skipping the other rows changes nothing that the step
/// function would do. The step evaluates the conjuncts in order and stops
/// at the first false one, so the conjunct must come after joins only,
/// and every row that these joins read must be a table without a
/// metatable whose columns hold nil or primitive values. Then no field
/// read runs `__index`, no comparison runs `__eq`, and a skipped tuple is
/// one the step would have rejected without a trace. The step still
/// evaluates every conjunct of the tuples the index finds, and the rows
/// come in the order of their positions, as the full product gives them.
const Index = struct {
    /// The outer source and the name of its column.
    outer: u32,
    outer_name: Value,
    /// The normalized key of each value of the inner column to its number.
    map: *Table,
    /// The positions of the rows with key number `k` are
    /// `pos[offs[k]..offs[k + 1]]`, in ascending order.
    offs: []u32,
    pos: []u32,

    fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        gpa.free(ix.offs);
        gpa.free(ix.pos);
    }
};

/// Whether `v` compares equal only to values of the same normalized key,
/// without a metamethod.
fn plainKey(v: Value) bool {
    return switch (v.tag) {
        .nil, .integer, .float, .string, .true, .false => true,
        else => false,
    };
}

/// Whether every row of the source table `t` is a table without a
/// metatable whose field `name` holds nil or a plain key.
fn plainColumn(t: *Table, n: i64, name: Value) bool {
    var k: i64 = 1;
    while (k <= n) : (k += 1) {
        const row = table.getInt(t, k);
        if (row.tag != .table) return false;
        const rt = row.as(Table);
        if (rt.metatable != null) return false;
        if (!plainKey(table.get(rt, name))) return false;
    }
    return true;
}

/// A key that matches nothing: nil, or NaN.
fn matchesNothing(v: Value) bool {
    return v.isNil() or (v.tag == .float and std.math.isNan(v.asFloat()));
}

/// Indexes the rows of source table `t` by their field `name`, whose
/// values `plainColumn` checked. `map` is a new table rooted on the stack.
fn buildIndex(l: *Thread, t: *Table, n: i64, name: Value, map: *Table, outer: u32, outer_name: Value) Error!Index {
    const gpa = l.g.gpa;
    const count: usize = @intCast(n);
    const ids = gpa.alloc(i32, count) catch return l.raiseMem();
    defer gpa.free(ids);
    var counts: std.ArrayList(u32) = .empty;
    defer counts.deinit(gpa);
    for (ids, 0..) |*id, i| {
        const v = table.get(table.getInt(t, @intCast(i + 1)).as(Table), name);
        if (matchesNothing(v)) {
            id.* = -1;
            continue;
        }
        const found = table.get(map, try ops.normKey(l, v));
        if (found.tag == .integer) {
            id.* = @intCast(found.asInt());
        } else {
            id.* = @intCast(counts.items.len);
            try ops.rawSet(l, map, v, Value.int(id.*));
            counts.append(gpa, 0) catch return l.raiseMem();
        }
        counts.items[@intCast(id.*)] += 1;
    }
    const offs = gpa.alloc(u32, counts.items.len + 1) catch return l.raiseMem();
    errdefer gpa.free(offs);
    var total: u32 = 0;
    for (counts.items, 0..) |c, k| {
        offs[k] = total;
        total += c;
    }
    offs[counts.items.len] = total;
    const pos = gpa.alloc(u32, total) catch return l.raiseMem();
    // Fill each run in ascending order, counting the runs down again.
    for (counts.items, 0..) |*c, k| c.* = offs[k];
    for (ids, 0..) |id, i| {
        if (id < 0) continue;
        const k: usize = @intCast(id);
        pos[counts.items[k]] = @intCast(i + 1);
        counts.items[k] += 1;
    }
    return .{ .outer = outer, .outer_name = outer_name, .map = map, .offs = offs, .pos = pos };
}

/// Builds the indexes of the sources that a join lets the odometer
/// narrow, storing each one at the index of its inner source. `slot` is
/// the first of `nsrc` stack slots that root the names and key maps.
fn buildIndexes(l: *Thread, p: *const Plan, src: u32, slot: u32, sizes: []const i64, out: []?Index) Error!void {
    var nnames: i64 = 0;
    for (p.conj) |cj| {
        const cols = cj.join orelse break;
        if (l.stack[slot].isNil()) l.stack[slot] = Value.obj(.table, try l.newTable(0, 0));
        const names = l.stack[slot].as(Table);
        var vals: [2]Value = undefined;
        for (cols, &vals) |col, *nv| {
            nv.* = try l.newStringValue(col.name);
            nnames += 1;
            try ops.rawSet(l, names, Value.int(nnames), nv.*);
            const t = l.stack[src + col.src].as(Table);
            if (!plainColumn(t, sizes[col.src], nv.*)) return;
        }
        const inner: usize = if (cols[0].src > cols[1].src) 0 else 1;
        const s = cols[inner].src;
        if (out[s] != null or sizes[s] < 2) continue;
        const map = try l.newTable(0, 0);
        l.stack[slot + 1 + s] = Value.obj(.table, map);
        out[s] = try buildIndex(l, l.stack[src + s].as(Table), sizes[s], vals[inner], map, cols[1 - inner].src, vals[1 - inner]);
    }
}

// ---------------------------------------------------------------------
// Execution

/// Stack slots relative to the execution base.
const slot_records = 0;
const slot_keys = 1;
const slot_dmap = 2;
const slot_gmap = 3;
const slot_groups = 4;
const slot_names = 5;
const slot_sources = 6;

const Sink = struct {
    l: *Thread,
    p: *const Plan,
    base: u32,
    nrec: i64 = 0,
    /// Window applied while streaming, when no ordering intervenes.
    stream: bool,
    skip: i64 = 0,
    limit: i64 = -1,
    /// Projection field names as strings, rooted in the names slot.
    names: []const Value = &.{},
    /// With one order key and a window known before the rows arrive, the
    /// records kept are the `top` best so far, by key and then by
    /// arrival. Every key is kept, rooted in the keys table and listed in
    /// `keys`, and `classes` and `others` track whether ordering them all
    /// raises, which the full sort then does.
    top: usize = 0,
    heap: std.ArrayList(u32) = .empty,
    keys: std.ArrayList(Value) = .empty,
    class: ?OrderClass = null,
    others: u32 = 0,
    raises: bool = false,

    fn deinit(s: *Sink) void {
        s.heap.deinit(s.l.g.gpa);
        s.keys.deinit(s.l.g.gpa);
    }

    fn sorter(s: *const Sink) Sorter {
        return .{ .l = s.l, .desc = s.p.desc, .keys = s.keys.items };
    }

    /// Notes key `v` and whether ordering every key seen raises.
    fn noteClass(s: *Sink, v: Value) void {
        if (v.isNil()) return;
        const c = orderClass(v);
        if (c == .other) s.others += 1;
        if (s.class) |seen| {
            if (seen != c) s.raises = true;
        } else s.class = c;
        if (s.others >= 2) s.raises = true;
    }

    /// Offers the record with id `id` to the kept ones.
    fn offer(s: *Sink, id: u32, rec: Value) Error!void {
        const l = s.l;
        const so = s.sorter();
        if (s.heap.items.len < s.top) {
            try ops.rawSet(l, s.tbl(slot_records), Value.int(@as(i64, id) + 1), rec);
            s.heap.append(l.g.gpa, id) catch return l.raiseMem();
            // Sift the new id up.
            const h = s.heap.items;
            var i = h.len - 1;
            while (i > 0) {
                const up = (i - 1) / 2;
                if (!try so.before(h[up], h[i])) break;
                std.mem.swap(u32, &h[up], &h[i]);
                i = up;
            }
            return;
        }
        const h = s.heap.items;
        if (!try so.before(id, h[0])) return;
        try ops.rawSet(l, s.tbl(slot_records), Value.int(@as(i64, h[0]) + 1), .nil);
        try ops.rawSet(l, s.tbl(slot_records), Value.int(@as(i64, id) + 1), rec);
        h[0] = id;
        try so.siftDown(h, 0);
    }

    fn tbl(s: *Sink, slot: u32) *Table {
        return s.l.stack[s.base + slot].as(Table);
    }

    /// True once a streamed window is full.
    fn full(s: *Sink) bool {
        return s.stream and s.limit >= 0 and s.nrec >= s.limit;
    }

    /// Accepts one record with its order keys (results of a clause
    /// function, still on the stack at `res`).
    fn put(s: *Sink, res: u32) Error!void {
        const l = s.l;
        const p = s.p;
        if (p.has(qgen.flag_rec_err)) return l.raiseFmt("a whole-row projection needs an 'as' name", .{});
        const rec = l.stack[res + 1];
        if (p.has(qgen.flag_distinct)) {
            var kbuf: [64]Value = undefined;
            const n = if (p.sel.len > 0) p.sel.len else 1;
            for (0..n) |i| {
                var kv = rec;
                if (p.sel.len > 0 and p.sel[i] != null) {
                    kv = if (rec.tag == .table) table.get(rec.as(Table), s.names[i]) else .nil;
                }
                kbuf[i] = try normKey(l, kv, false);
            }
            const leaf = try keyLeaf(l, s.tbl(slot_dmap), kbuf[0 .. n - 1]);
            const last = try ops.normKey(l, kbuf[n - 1]);
            if (!table.get(leaf, last).isNil()) return;
            try ops.rawSet(l, leaf, last, .true);
        }
        if (s.stream and s.skip > 0) {
            s.skip -= 1;
            return;
        }
        if (s.full()) return;
        s.nrec += 1;
        if (s.top > 0) {
            var kv = l.stack[res + 2];
            if (kv.tag == .float and std.math.isNan(kv.asFloat())) kv = .nil;
            // The keys table roots the keys that the collector could free.
            if (kv.tag.isCollectable()) try ops.rawSet(l, s.tbl(slot_keys), Value.int(s.nrec), kv);
            s.keys.append(l.g.gpa, kv) catch return l.raiseMem();
            s.noteClass(kv);
            if (!s.raises) try s.offer(@intCast(s.nrec - 1), rec);
            return;
        }
        try ops.rawSet(l, s.tbl(slot_records), Value.int(s.nrec), rec);
        const nk = p.desc.len;
        if (nk > 0) {
            const keys = s.tbl(slot_keys);
            for (0..nk) |k| {
                var kv = l.stack[res + 2 + k];
                if (kv.tag == .float and std.math.isNan(kv.asFloat())) kv = .nil;
                if (!kv.isNil()) try ops.rawSet(l, keys, Value.int((s.nrec - 1) * @as(i64, @intCast(nk)) + @as(i64, @intCast(k)) + 1), kv);
            }
        }
    }
};

const Window = struct { limit: i64, offset: i64 };

fn evalWindow(l: *Thread, q: *Query, p: *const Plan) Error!Window {
    const op = p.op_lo orelse return .{ .limit = -1, .offset = 0 };
    const top = l.top;
    _ = try ops.callN(l, q.operand(op), &.{}, 2);
    const lv = l.stack[top];
    const ov = l.stack[top + 1];
    l.top = top;
    const limit = if (p.has(qgen.flag_limit)) try countValue(l, lv, "limit") else -1;
    const offset = if (p.has(qgen.flag_offset)) try countValue(l, ov, "offset") else 0;
    return .{ .limit = limit, .offset = offset };
}

/// The window of a plan whose limit and offset are literals or captured
/// values, which calling the window function reads without raising or
/// running anything. Returns null when a value is not a count, and then
/// the window is evaluated after the rows, which raises the error.
fn plainWindow(l: *Thread, q: *Query, p: *const Plan) Error!?Window {
    const op = p.op_lo orelse return null;
    const top = l.top;
    _ = try ops.callN(l, q.operand(op), &.{}, 2);
    const lv = l.stack[top];
    const ov = l.stack[top + 1];
    l.top = top;
    const limit = if (p.has(qgen.flag_limit)) countOf(lv) orelse return null else -1;
    const offset = if (p.has(qgen.flag_offset)) countOf(ov) orelse return null else 0;
    return .{ .limit = limit, .offset = offset };
}

/// What `countValue` returns for `v`, or null where it raises.
fn countOf(v: Value) ?i64 {
    const n = switch (v.tag) {
        .integer => v.asInt(),
        .float => ops.floatToInt(v.asFloat()),
        .string => if (ops.toNumberCoerce(v)) |num| ops.toIntegerStrict(num) else null,
        else => null,
    } orelse return null;
    if (n < 0) return null;
    return n;
}

/// Runs the query and returns the table of result records, which is left
/// on the stack.
fn execute(l: *Thread, q: *Query, qv: Value) Error!*Table {
    const p = try planOf(l, q);
    if (p.err.len > 0) return l.raiseFmt("{s}", .{p.err});
    const gpa = l.g.gpa;
    const nsrc = p.nsrc;
    const base = l.top;
    // After the sources come the slots that root the column names and the
    // key maps of the indexed joins.
    const slot_index = slot_sources + nsrc;
    try l.ensure(slot_index + 1 + nsrc + 8);
    for (0..slot_index + 1 + nsrc) |_| try l.push(.nil);
    l.stack[base + slot_records] = Value.obj(.table, try l.newTable(0, 0));
    if (p.desc.len > 0) l.stack[base + slot_keys] = Value.obj(.table, try l.newTable(0, 0));
    const names = gpa.alloc(Value, p.sel.len) catch return l.raiseMem();
    defer gpa.free(names);
    if (p.has(qgen.flag_distinct)) {
        l.stack[base + slot_dmap] = Value.obj(.table, try l.newTable(0, 0));
        const nt = try l.newTable(p.sel.len, 0);
        l.stack[base + slot_names] = Value.obj(.table, nt);
        for (p.sel, names, 0..) |it, *nv, i| {
            nv.* = if (it) |name| try l.newStringValue(name) else .nil;
            try ops.rawSet(l, nt, Value.int(@intCast(i + 1)), nv.*);
        }
    }
    const grouped = p.has(qgen.flag_grouped);
    if (grouped) {
        l.stack[base + slot_gmap] = Value.obj(.table, try l.newTable(0, 0));
        l.stack[base + slot_groups] = Value.obj(.table, try l.newTable(0, 0));
    }

    // Fetch every source, pushing down what the providers accept.
    const pushed = gpa.alloc(bool, p.conj.len) catch return l.raiseMem();
    defer gpa.free(pushed);
    @memset(pushed, false);
    // Without ordering the window streams. It is evaluated before the
    // sources are fetched, so a lone SQLite source whose whole where clause
    // pushes down can apply it in SQL too.
    var sink: Sink = .{ .l = l, .p = p, .base = base, .stream = p.desc.len == 0, .names = names };
    defer sink.deinit();
    // One order key and a window that reads no row: the window comes first,
    // and the sink keeps only the records that can fall in it.
    var early: ?Window = null;
    if (p.desc.len == 1 and p.has(qgen.flag_plain_window)) {
        early = try plainWindow(l, q, p);
        if (early) |w| {
            if (w.limit >= 0) sink.top = @intCast(@min(w.offset + w.limit, std.math.maxInt(u32)));
            if (sink.top == 0) early = null;
        }
    }
    var sql_window: ?Window = null;
    if (sink.stream) {
        const w = try evalWindow(l, q, p);
        sink.limit = w.limit;
        sink.skip = w.offset;
        if ((w.limit >= 0 or w.offset > 0) and nsrc == 1 and !grouped and !p.has(qgen.flag_distinct) and
            sqlite.toTableRef(l, q.vals()[0]) != null and pushable(q, p, 0, pushed) == p.conj.len)
        {
            sql_window = w;
            sink.limit = -1;
            sink.skip = 0;
            @memset(pushed, false);
        }
    }
    var sizes: [qgen.max_sources]i64 = undefined;
    var empty = false;
    for (0..nsrc) |i| {
        sizes[i] = try fetch(l, q, qv, p, @intCast(i), base + slot_sources + @as(u32, @intCast(i)), pushed, sql_window);
        if (sizes[i] == 0) empty = true;
    }
    var skip_mask: i64 = 0;
    for (pushed, 0..) |b, i| {
        if (b and i < qgen.max_skip_bits) skip_mask |= @as(i64, 1) << @intCast(i);
    }

    var accs: std.ArrayList(Acc) = .empty;
    defer accs.deinit(gpa);
    var ngroups: i64 = 0;
    const naggs = p.aggs.len;

    var indexes: [qgen.max_sources]?Index = @splat(null);
    defer for (&indexes) |*ix| if (ix.*) |*x| x.deinit(gpa);
    if (!empty and nsrc > 1) try buildIndexes(l, p, base + slot_sources, base + slot_index, sizes[0..nsrc], indexes[0..nsrc]);

    // The fused join loop: walk the cross product with an odometer and
    // call the step function once per tuple. Each source runs through a
    // sequence of row positions: all of them, or the rows that its index
    // finds for the current row of the outer source.
    const step = q.operand(p.op_step);
    var args: [qgen.max_sources + 1]Value = undefined;
    var at: [qgen.max_sources]usize = @splat(0);
    var len: [qgen.max_sources]usize = @splat(0);
    var seq: [qgen.max_sources]?[]const u32 = @splat(null);
    var done = empty or (!grouped and sink.full());
    // The first source whose sequence starts again.
    var fresh: usize = 0;
    while (!done) {
        // Start the sequences of the sources from `fresh` on. A sequence
        // that is empty advances the source before it instead.
        var si = fresh;
        while (si < nsrc) {
            at[si] = 0;
            seq[si] = null;
            len[si] = @intCast(sizes[si]);
            if (indexes[si]) |*ix| {
                const outer = args[ix.outer + 1].as(Table);
                const v = table.get(outer, ix.outer_name);
                len[si] = 0;
                if (!matchesNothing(v)) {
                    const found = table.get(ix.map, try ops.normKey(l, v));
                    if (found.tag == .integer) {
                        const k: usize = @intCast(found.asInt());
                        seq[si] = ix.pos[ix.offs[k]..ix.offs[k + 1]];
                        len[si] = seq[si].?.len;
                    }
                }
            }
            if (len[si] == 0) {
                si = advance(&at, &len, si) orelse {
                    done = true;
                    break;
                };
                args[si] = rowAt(l, base, &seq, &at, si - 1);
                continue;
            }
            args[si + 1] = rowAt(l, base, &seq, &at, si);
            si += 1;
        }
        if (done) break;
        args[0] = Value.int(skip_mask);
        const top = l.top;
        const nres = try ops.callN(l, step, args[0 .. nsrc + 1], -1);
        if (nres > 0 and l.stack[top].truthy()) {
            if (!grouped) {
                if (nres < 2 + p.desc.len) return corrupt(l);
                try sink.put(top);
                if (sink.full()) done = true;
            } else {
                if (nres < 1 + p.nkeys) return corrupt(l);
                // Locate or create the group.
                var gidx: i64 = 0;
                var kbuf: [64]Value = undefined;
                for (0..p.nkeys) |k| kbuf[k] = try normKey(l, l.stack[top + 1 + k], true);
                var is_new = false;
                if (p.nkeys == 0) {
                    is_new = ngroups == 0;
                } else {
                    const leaf = try keyLeaf(l, l.stack[base + slot_gmap].as(Table), kbuf[0 .. p.nkeys - 1]);
                    const last = kbuf[p.nkeys - 1];
                    const found = table.get(leaf, try ops.normKey(l, last));
                    if (found.tag == .integer) {
                        gidx = found.asInt();
                    } else {
                        is_new = true;
                        gidx = ngroups;
                        try ops.rawSet(l, leaf, last, Value.int(gidx));
                    }
                }
                if (is_new) {
                    const gs = try l.newTable(nsrc + naggs, 0);
                    try ops.rawSet(l, l.stack[base + slot_groups].as(Table), Value.int(ngroups + 1), Value.obj(.table, gs));
                    for (0..nsrc) |i| try ops.rawSet(l, gs, Value.int(@intCast(i + 1)), args[i + 1]);
                    // One accumulator for the tuple count, then one per
                    // aggregate.
                    accs.appendNTimes(gpa, .{}, naggs + 1) catch return l.raiseMem();
                    ngroups += 1;
                }
                const gs = table.getInt(l.stack[base + slot_groups].as(Table), gidx + 1).as(Table);
                const acc_base = @as(usize, @intCast(gidx)) * (naggs + 1);
                accs.items[acc_base].n += 1;
                var argi: u32 = top + 1 + p.nkeys;
                for (p.aggs, 0..) |code, j| {
                    if (code == AggCode.count_star) continue;
                    if (argi >= top + nres) return corrupt(l);
                    try accumulate(l, code, &accs.items[acc_base + 1 + j], gs, @intCast(nsrc + 1 + j), l.stack[argi]);
                    argi += 1;
                }
            }
        }
        l.top = top;
        // Advance the odometer.
        fresh = advance(&at, &len, nsrc) orelse break;
        args[fresh] = rowAt(l, base, &seq, &at, fresh - 1);
    }

    if (grouped) {
        if (ngroups == 0 and p.nkeys == 0) {
            const gs = try l.newTable(0, 0);
            try ops.rawSet(l, l.stack[base + slot_groups].as(Table), Value.int(1), Value.obj(.table, gs));
            accs.appendNTimes(gpa, .{}, naggs + 1) catch return l.raiseMem();
            ngroups = 1;
        }
        const final = q.operand(p.op_final.?);
        const fargs = gpa.alloc(Value, nsrc + naggs) catch return l.raiseMem();
        defer gpa.free(fargs);
        var g: i64 = 0;
        while (g < ngroups and !sink.full()) : (g += 1) {
            const gs = table.getInt(l.stack[base + slot_groups].as(Table), g + 1).as(Table);
            const acc_base = @as(usize, @intCast(g)) * (naggs + 1);
            const ntuples = accs.items[acc_base].n;
            for (0..nsrc) |i| fargs[i] = table.getInt(gs, @intCast(i + 1));
            for (p.aggs, 0..) |code, j| {
                fargs[nsrc + j] = try aggResult(l, code, &accs.items[acc_base + 1 + j], ntuples, gs, @intCast(nsrc + 1 + j));
                // Generic results may be fresh objects: keep them rooted.
                if (fargs[nsrc + j].tag.isCollectable()) try ops.rawSet(l, gs, Value.int(@intCast(nsrc + 1 + naggs + j)), fargs[nsrc + j]);
            }
            const top = l.top;
            const nres = try ops.callN(l, final, fargs, -1);
            if (nres > 0 and l.stack[top].truthy()) {
                if (nres < 2 + p.desc.len) return corrupt(l);
                try sink.put(top);
            }
            l.top = top;
        }
    }

    const records = l.stack[base + slot_records].as(Table);
    if (sink.stream) return finish(l, base, records);

    if (sink.top > 0) {
        if (sink.raises) {
            // The full sort of every key raises, as it does without the
            // window.
            const all = gpa.alloc(u32, sink.keys.items.len * 2) catch return l.raiseMem();
            defer gpa.free(all);
            const nall = sink.keys.items.len;
            for (0..nall) |i| all[i] = @intCast(i);
            try sink.sorter().sort(all[0..nall], all[nall..]);
            return corrupt(l);
        }
        const w = early.?;
        const kept = sink.heap.items;
        std.mem.sort(u32, kept, {}, std.sort.asc(u32));
        const tmp = gpa.alloc(u32, kept.len) catch return l.raiseMem();
        defer gpa.free(tmp);
        try sink.sorter().sort(kept, tmp);
        const out = try l.newTable(0, 0);
        l.stack[base + slot_dmap] = Value.obj(.table, out);
        var r: usize = @intCast(@min(w.offset, @as(i64, @intCast(kept.len))));
        var slot: i64 = 1;
        while (r < kept.len) : (r += 1) {
            try ops.rawSet(l, out, Value.int(slot), table.getInt(records, @as(i64, kept[r]) + 1));
            slot += 1;
        }
        return finish(l, base, out);
    }

    // Order, then window.
    const n: usize = @intCast(sink.nrec);
    if (n > 1) {
        const perm = gpa.alloc(u32, n * 2) catch return l.raiseMem();
        defer gpa.free(perm);
        for (0..n) |i| perm[i] = @intCast(i);
        const nk = p.desc.len;
        const keys = gpa.alloc(Value, n * nk) catch return l.raiseMem();
        defer gpa.free(keys);
        const kt = l.stack[base + slot_keys].as(Table);
        for (keys, 0..) |*k, i| k.* = table.getInt(kt, @intCast(i + 1));
        const sorter: Sorter = .{ .l = l, .desc = p.desc, .keys = keys };
        // When the keys of every position share one class, no comparison
        // raises or runs a metamethod, so the window may come first, and
        // a window much smaller than the records needs only its own rows
        // in order: the smallest ones by key and then by arrival, which
        // the stable sort puts first too.
        if (oneClassPerKey(keys, nk)) {
            const w = try evalWindow(l, q, p);
            if (w.limit >= 0 and w.offset < n) {
                const m: usize = @intCast(@min(@as(i64, @intCast(n)), w.offset + w.limit));
                if (m * 4 <= n) {
                    const out = try l.newTable(0, 0);
                    l.stack[base + slot_dmap] = Value.obj(.table, out);
                    if (m > 0) {
                        const top = try sorter.smallest(perm[0..n], m);
                        // Ascending arrival first, so the stable sort breaks
                        // ties as the full sort does.
                        std.mem.sort(u32, top, {}, std.sort.asc(u32));
                        try sorter.sort(top, perm[n..][0..m]);
                        var r: usize = @intCast(w.offset);
                        var slot: i64 = 1;
                        while (r < m) : (r += 1) {
                            try ops.rawSet(l, out, Value.int(slot), table.getInt(records, @as(i64, top[r]) + 1));
                            slot += 1;
                        }
                    }
                    return finish(l, base, out);
                }
            }
            try sorter.sort(perm[0..n], perm[n..]);
            const sorted = try l.newTable(n, 0);
            l.stack[base + slot_dmap] = Value.obj(.table, sorted);
            for (perm[0..n], 0..) |id, i| try ops.rawSet(l, sorted, Value.int(@intCast(i + 1)), table.getInt(records, @as(i64, id) + 1));
            l.stack[base + slot_records] = Value.obj(.table, sorted);
            return windowed(l, base, n, w);
        }
        try sorter.sort(perm[0..n], perm[n..]);
        const sorted = try l.newTable(n, 0);
        l.stack[base + slot_dmap] = Value.obj(.table, sorted);
        for (perm[0..n], 0..) |id, i| try ops.rawSet(l, sorted, Value.int(@intCast(i + 1)), table.getInt(records, @as(i64, id) + 1));
        l.stack[base + slot_records] = Value.obj(.table, sorted);
    }
    return windowed(l, base, n, try evalWindow(l, q, p));
}

/// Applies window `w` to the `n` ordered records and finishes.
fn windowed(l: *Thread, base: u32, n: usize, w: Window) Error!*Table {
    if (w.limit >= 0 or w.offset > 0) {
        const all = l.stack[base + slot_records].as(Table);
        const total: i64 = @intCast(n);
        const out = try l.newTable(0, 0);
        l.stack[base + slot_dmap] = Value.obj(.table, out);
        if (w.offset < total and w.limit != 0) {
            const avail = total - w.offset;
            const take = if (w.limit < 0 or w.limit > avail) avail else w.limit;
            var r: i64 = 0;
            while (r < take) : (r += 1) try ops.rawSet(l, out, Value.int(r + 1), table.getInt(all, w.offset + r + 1));
        }
        l.stack[base + slot_records] = Value.obj(.table, out);
    }
    return finish(l, base, l.stack[base + slot_records].as(Table));
}

/// Whether the non-nil keys at each of the `nk` positions share one
/// order class other than `.other`, so that comparing them never raises.
fn oneClassPerKey(keys: []const Value, nk: usize) bool {
    for (0..nk) |k| {
        var class: ?OrderClass = null;
        var i = k;
        while (i < keys.len) : (i += nk) {
            const v = keys[i];
            if (v.isNil()) continue;
            const c = orderClass(v);
            if (c == .other) return false;
            if (class) |seen| {
                if (seen != c) return false;
            } else class = c;
        }
    }
    return true;
}

/// Moves the odometer past the sources before `from`: the last of them
/// that has a next row takes it. Returns the index of the first source
/// after it, whose sequence starts again, or null when every tuple went by.
fn advance(at: []usize, len: []const usize, from: usize) ?usize {
    var j = from;
    while (j > 0) {
        j -= 1;
        at[j] += 1;
        if (at[j] < len[j]) return j + 1;
    }
    return null;
}

/// The current row of source `i`.
fn rowAt(l: *Thread, base: u32, seq: []const ?[]const u32, at: []const usize, i: usize) Value {
    const t = l.stack[base + slot_sources + i].as(Table);
    const pos: i64 = if (seq[i]) |s| s[at[i]] else @intCast(at[i] + 1);
    return table.getInt(t, pos);
}

fn finish(l: *Thread, base: u32, records: *Table) *Table {
    l.stack[base] = Value.obj(.table, records);
    l.top = base + 1;
    return records;
}

// ---------------------------------------------------------------------
// Natives

fn checkQuery(l: *Thread, i: u32) Error!*Query {
    const v = try aux.checkAny(l, i);
    if (v.tag != .query) return aux.typeError(l, i, "query");
    return v.as(Query);
}

fn queryNext(l: *Thread) Error!u32 {
    const ups = l.frame().native.?.upvalues();
    const i = ups[1].asInt() + 1;
    ups[1] = Value.int(i);
    return aux.ret(l, table.getInt(ups[0].as(Table), i));
}

/// `query(q)`: runs the query and returns an iterator over its records.
fn lusQuery(l: *Thread) Error!u32 {
    const q = try checkQuery(l, 1);
    const qv = l.arg(1);
    const records = try execute(l, q, qv);
    // Creating the native can collect, so the records stay on the stack
    // until the native holds them.
    try l.push(Value.obj(.table, records));
    const n = state.newNative(l.g, queryNext, "query_next", 2) catch return l.raiseMem();
    n.upvalues()[0] = Value.obj(.table, records);
    n.upvalues()[1] = Value.int(0);
    return aux.ret(l, Value.obj(.native, n));
}

/// `debug.queryplan(q)`: describes how each source is fetched and where
/// each where conjunct runs.
fn lusQueryPlan(l: *Thread) Error!u32 {
    const q = try checkQuery(l, 1);
    const p = try planOf(l, q);
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const pushed = gpa.alloc(bool, p.conj.len) catch return l.raiseMem();
    defer gpa.free(pushed);
    @memset(pushed, false);
    buf.print(gpa, "query: {d} source(s), {d} conjunct(s)\n", .{ p.nsrc, p.conj.len }) catch return l.raiseMem();
    for (0..p.nsrc) |i| {
        const kind = try classify(l, q.vals()[i]);
        const n = if (kind == .native) pushable(q, p, @intCast(i), pushed) else 0;
        const name = switch (kind) {
            .native => "native",
            .metamethod => "__query",
            .memory => "memory",
        };
        buf.print(gpa, "  {s}: {s}, {d} pushed conjunct(s)\n", .{ p.aliases[i], name, n }) catch return l.raiseMem();
    }
    for (p.conj, 0..) |cj, ci| {
        const where = if (pushed[ci]) "pushed down" else if (cj.opaque_) "in memory (host closure)" else "in memory (translatable)";
        buf.print(gpa, "  conjunct {d}: {s}\n", .{ ci + 1, where }) catch return l.raiseMem();
    }
    return aux.retStr(l, buf.items);
}

/// Registers the global `query` and `debug.queryplan`.
pub fn open(l: *Thread) Error!void {
    try aux.setFuncs(l, l.g.globals.as(Table), .fields, "", &.{.{ .name = "query", .func = lusQuery }});
    const dbg = try aux.getField(l, l.g.globals.as(Table), "debug");
    if (dbg.tag == .table) try aux.setFuncs(l, dbg.as(Table), .fields, "debug", &.{.{ .name = "queryplan", .func = lusQueryPlan }});
}
