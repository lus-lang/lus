//! The C embedding interface declared in `include/lus.h`. Every function
//! here is exported with the C calling convention. The functions work on
//! the stack of a thread, report failures through status codes, and leave
//! error values on the stack, so no error ever unwinds through C frames.

const std = @import("std");
const api = @import("api.zig");
const value = @import("vm/value.zig");
const object = @import("vm/object.zig");
const state = @import("vm/state.zig");
const table = @import("vm/table.zig");
const ops = @import("vm/ops.zig");
const gc = @import("vm/gc.zig");
const interp = @import("vm/interp.zig");
const pledge = @import("vm/pledge.zig");
const base_lib = @import("lib/base.zig");
const vector_lib = @import("lib/vector.zig");
const out = @import("lib/out.zig");
const Value = value.Value;
const Tag = value.Tag;
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

pub const lus_State = Thread;
pub const lus_Integer = i64;
pub const lus_Number = f64;
pub const lus_CFunction = *const fn (l: *Thread) callconv(.c) c_int;

pub const LUS_OK: c_int = 0;
pub const LUS_ERRRUN: c_int = 1;
pub const LUS_ERRSYNTAX: c_int = 2;
pub const LUS_ERRMEM: c_int = 3;
pub const LUS_ERRFILE: c_int = 4;
pub const LUS_ERROR: c_int = -1;
pub const LUS_MULTRET: c_int = -1;
pub const LUS_NOREF: c_int = 0;

const T_NONE: c_int = -1;

/// Host resources owned by a state created through `lus_newstate`.
const Host = struct {
    threaded: std.Io.Threaded,
    request: ?struct { func: *const fn (?*anyopaque, *Thread, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int, ud: ?*anyopaque } = null,
    /// Free reference numbers, reused before new ones.
    free_refs: std.ArrayList(c_int) = .empty,
    next_ref: c_int = 1,
    /// Contexts of the custom capabilities declared from C.
    matchers: std.ArrayList(*CMatch) = .empty,
};

const host_key = "capi.host";
const refs_key = "capi.refs";

fn host(g: *Global) *Host {
    return @ptrCast(@alignCast(g.ext.get(host_key).?));
}

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------------
// State

export fn lus_newstate() ?*Thread {
    const h = gpa.create(Host) catch return null;
    h.* = .{ .threaded = std.Io.Threaded.init(gpa, .{}) };
    const l = api.newState(gpa, h.threaded.io()) catch {
        h.threaded.deinit();
        gpa.destroy(h);
        return null;
    };
    l.g.ext.put(gpa, host_key, h) catch {
        api.close(l);
        h.threaded.deinit();
        gpa.destroy(h);
        return null;
    };
    return l;
}

export fn lus_close(l: *Thread) void {
    const g = l.g;
    const main = g.main_thread;
    // api.close runs every pending finalizer, so C resources held by
    // userdata are released, then flushes output and frees the state.
    const h = host(g);
    api.close(main);
    h.free_refs.deinit(gpa);
    for (h.matchers.items) |m| gpa.destroy(m);
    h.matchers.deinit(gpa);
    h.threaded.deinit();
    gpa.destroy(h);
}

export fn lus_openlibs(l: *Thread) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread) Error!void {
            try api.openLibs(t);
        }
    }.f, .{l});
}

export fn lus_collect(l: *Thread) void {
    gc.fullCollect(l.g);
    const top = l.top;
    _ = protect(l, top, base_lib.runFinalizers, .{l});
    l.top = top;
}

// ---------------------------------------------------------------------
// Errors and protection

/// The status that matches the pending error value.
fn errStatus(l: *Thread) c_int {
    if (l.err.tag == .string and l.err.as(String) == l.g.memerr) return LUS_ERRMEM;
    return LUS_ERRRUN;
}

/// Runs `f` and, when it fails, unwinds the frames it left, resets the
/// stack top to `reset`, and pushes the error value.
fn protect(l: *Thread, reset: u32, comptime f: anytype, args: anytype) c_int {
    const depth = l.frames.items.len;
    const tbc_len = l.tbc.items.len;
    const ncalls = l.ncalls;
    @call(.auto, f, args) catch {
        interp.unwindTo(l, depth);
        l.tbc.items.len = @min(l.tbc.items.len, tbc_len);
        l.ncalls = ncalls;
        // An error that stops the program ends at the outermost call.
        if (l.g.native_depth == 0) l.g.sched.fatal = false;
        l.top = reset;
        pushErr(l);
        return errStatus(l);
    };
    return LUS_OK;
}

/// Pushes the pending error value. The stack always has room for it,
/// because the failed operation consumed at least the slot it reuses or
/// `ensure` grew the stack earlier. If it cannot grow, the top slot is
/// overwritten.
fn pushErr(l: *Thread) void {
    l.push(l.err) catch {
        if (l.top > 0) l.stack[l.top - 1] = l.err;
    };
}

export fn lus_error(l: *Thread) c_int {
    l.err = if (l.top > frameBase(l)) l.pop() else .nil;
    return LUS_ERROR;
}

export fn lus_errorstr(l: *Thread, msg: [*:0]const u8) c_int {
    _ = l.raiseFmt("{s}", .{std.mem.span(msg)}) catch {};
    return LUS_ERROR;
}

// ---------------------------------------------------------------------
// Stack indices

/// The first slot of the running C function, or the bottom of the stack
/// at host level.
fn frameBase(l: *Thread) u32 {
    if (l.frames.items.len == 0) return 0;
    return l.frame().base;
}

/// The absolute stack slot of `idx`, or null when it names no value.
fn slot(l: *Thread, idx: c_int) ?u32 {
    if (idx > 0) {
        const s = frameBase(l) + @as(u32, @intCast(idx)) - 1;
        return if (s < l.top) s else null;
    }
    if (idx < 0) {
        const back: u32 = @intCast(-idx);
        if (back > l.top - frameBase(l)) return null;
        return l.top - back;
    }
    return null;
}

fn at(l: *Thread, idx: c_int) Value {
    const s = slot(l, idx) orelse return .nil;
    return l.stack[s];
}

export fn lus_gettop(l: *Thread) c_int {
    return @intCast(l.top - frameBase(l));
}

export fn lus_settop(l: *Thread, idx: c_int) void {
    const b = frameBase(l);
    if (idx >= 0) {
        const want = b + @as(u32, @intCast(idx));
        if (want > l.top) {
            l.ensure(want - l.top) catch return;
            while (l.top < want) : (l.top += 1) l.stack[l.top] = .nil;
        }
        l.top = want;
    } else {
        const drop: u32 = @intCast(-idx - 1);
        l.top = if (drop > l.top - b) b else l.top - drop;
    }
}

export fn lus_absindex(l: *Thread, idx: c_int) c_int {
    if (idx > 0) return idx;
    return lus_gettop(l) + idx + 1;
}

export fn lus_pushvalue(l: *Thread, idx: c_int) void {
    l.push(at(l, idx)) catch {};
}

export fn lus_remove(l: *Thread, idx: c_int) void {
    const s = slot(l, idx) orelse return;
    var i = s;
    while (i + 1 < l.top) : (i += 1) l.stack[i] = l.stack[i + 1];
    l.top -= 1;
}

export fn lus_insert(l: *Thread, idx: c_int) void {
    const s = slot(l, idx) orelse return;
    const v = l.stack[l.top - 1];
    var i = l.top - 1;
    while (i > s) : (i -= 1) l.stack[i] = l.stack[i - 1];
    l.stack[s] = v;
}

export fn lus_replace(l: *Thread, idx: c_int) void {
    const s = slot(l, idx) orelse return;
    l.stack[s] = l.stack[l.top - 1];
    l.top -= 1;
}

export fn lus_checkstack(l: *Thread, n: c_int) c_int {
    if (n <= 0) return 1;
    l.ensure(@intCast(n)) catch return 0;
    return 1;
}

// ---------------------------------------------------------------------
// Reading values

fn typeCode(tag: Tag) c_int {
    return switch (tag) {
        .nil => 0,
        .false, .true => 1,
        .light => 2,
        .integer, .float, .bigint, .decimal => 3,
        .string => 4,
        .table => 5,
        .closure, .native => 6,
        .userdata => 7,
        .thread => 8,
        .vector => 9,
        .enum_value, .enum_root => 10,
        .query => 11,
        .proto, .upvalue => T_NONE,
    };
}

export fn lus_type(l: *Thread, idx: c_int) c_int {
    const s = slot(l, idx) orelse return T_NONE;
    return typeCode(l.stack[s].tag);
}

export fn lus_typename(t: c_int) [*:0]const u8 {
    return switch (t) {
        0 => "nil",
        1 => "boolean",
        2, 7 => "userdata",
        3 => "number",
        4 => "string",
        5 => "table",
        6 => "function",
        8 => "thread",
        9 => "vector",
        10 => "enum",
        11 => "query",
        else => "no value",
    };
}

export fn lus_isnil(l: *Thread, idx: c_int) c_int {
    return @intFromBool(at(l, idx).isNil());
}

export fn lus_isinteger(l: *Thread, idx: c_int) c_int {
    return @intFromBool(at(l, idx).tag == .integer);
}

export fn lus_isfunction(l: *Thread, idx: c_int) c_int {
    const t = at(l, idx).tag;
    return @intFromBool(t == .closure or t == .native);
}

export fn lus_toboolean(l: *Thread, idx: c_int) c_int {
    return @intFromBool(at(l, idx).truthy());
}

export fn lus_tointeger(l: *Thread, idx: c_int, isnum: ?*c_int) i64 {
    const n = ops.toNumberCoerce(at(l, idx));
    const r: ?i64 = if (n) |v| ops.toIntegerStrict(v) else null;
    if (isnum) |p| p.* = @intFromBool(r != null);
    return r orelse 0;
}

export fn lus_tonumber(l: *Thread, idx: c_int, isnum: ?*c_int) f64 {
    const v = at(l, idx);
    // Bigints and decimals convert to the nearest float, as `tonumber` does.
    if (v.tag == .bigint or v.tag == .decimal) {
        if (isnum) |p| p.* = 1;
        return @import("vm/numeric.zig").toFloat(l.g.gpa, v);
    }
    const n = ops.toNumberCoerce(v);
    const ok = n != null and (n.?.tag == .integer or n.?.tag == .float);
    if (isnum) |p| p.* = @intFromBool(ok);
    return if (ok) ops.toFloat(n.?) else 0;
}

export fn lus_tostring(l: *Thread, idx: c_int, len: ?*usize) ?[*:0]const u8 {
    const v = at(l, idx);
    if (v.tag != .string) return null;
    const s = v.as(String);
    if (len) |p| p.* = s.len;
    return @ptrCast(s.bytes().ptr);
}

var empty_bytes: [1]u8 = .{0};

export fn lus_tobytes(l: *Thread, idx: c_int, len: ?*usize) ?[*]u8 {
    const v = at(l, idx);
    if (v.tag != .vector) return null;
    const vec = v.as(object.Vector);
    if (len) |p| p.* = vec.bytes.items.len;
    // An empty vector still yields a usable non-null pointer.
    if (vec.bytes.items.len == 0) return &empty_bytes;
    return vec.bytes.items.ptr;
}

export fn lus_touserdata(l: *Thread, idx: c_int) ?*anyopaque {
    const v = at(l, idx);
    return switch (v.tag) {
        .light => @ptrFromInt(v.address()),
        .userdata => @ptrCast(v.as(object.Userdata).data()),
        else => null,
    };
}

export fn lus_tolight(l: *Thread, idx: c_int) ?*anyopaque {
    const v = at(l, idx);
    return if (v.tag == .light) @ptrFromInt(v.address()) else null;
}

export fn lus_rawequal(l: *Thread, a: c_int, b: c_int) c_int {
    if (slot(l, a) == null or slot(l, b) == null) return 0;
    return @intFromBool(ops.rawEqual(l, at(l, a), at(l, b)));
}

export fn lus_rawlen(l: *Thread, idx: c_int) usize {
    const v = at(l, idx);
    return switch (v.tag) {
        .string => v.as(String).len,
        .vector => v.as(object.Vector).bytes.items.len,
        .table => @intCast(@max(table.length(v.as(Table)), 0)),
        else => 0,
    };
}

// ---------------------------------------------------------------------
// Pushing values

export fn lus_pushnil(l: *Thread) void {
    l.push(.nil) catch {};
}

export fn lus_pushboolean(l: *Thread, b: c_int) void {
    l.push(Value.boolean(b != 0)) catch {};
}

export fn lus_pushinteger(l: *Thread, n: i64) void {
    l.push(Value.int(n)) catch {};
}

export fn lus_pushnumber(l: *Thread, n: f64) void {
    l.push(Value.float(n)) catch {};
}

export fn lus_pushlight(l: *Thread, p: ?*anyopaque) void {
    l.push(Value.light(p)) catch {};
}

fn pushBytesAsString(l: *Thread, bytes: []const u8) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, b: []const u8) Error!void {
            const v = try t.newStringValue(b);
            try t.push(v);
        }
    }.f, .{ l, bytes });
}

export fn lus_pushstring(l: *Thread, s: ?[*:0]const u8) c_int {
    const p = s orelse {
        lus_pushnil(l);
        return LUS_OK;
    };
    return pushBytesAsString(l, std.mem.span(p));
}

export fn lus_pushlstring(l: *Thread, s: ?[*]const u8, len: usize) c_int {
    if (len == 0) return pushBytesAsString(l, "");
    return pushBytesAsString(l, s.?[0..len]);
}

export fn lus_pushbytes(l: *Thread, p: ?[*]const u8, len: usize) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, src: ?[*]const u8, n: usize) Error!void {
            const v = try vector_lib.newVector(t, &.{});
            try t.push(Value.obj(.vector, v));
            if (src) |s| {
                v.bytes.appendSlice(t.g.gpa, s[0..n]) catch return t.raiseMem();
            } else {
                v.bytes.appendNTimes(t.g.gpa, 0, n) catch return t.raiseMem();
            }
        }
    }.f, .{ l, p, len });
}

export fn lus_newtable(l: *Thread, narr: c_int, nrec: c_int) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, a: usize, r: usize) Error!void {
            const tab = try t.newTable(a, r);
            try t.push(Value.obj(.table, tab));
        }
    }.f, .{ l, @as(usize, @intCast(@max(narr, 0))), @as(usize, @intCast(@max(nrec, 0))) });
}

/// The native behind every C function. Upvalue 0 holds the C function
/// pointer and the remaining upvalues belong to the C closure.
fn trampoline(l: *Thread) Error!u32 {
    const nat = l.frame().native.?;
    const f: lus_CFunction = @ptrFromInt(nat.upvalues()[0].address());
    const n = f(l);
    if (n < 0) return error.LusError;
    const nres: u32 = @intCast(n);
    if (nres > l.top - l.frame().base) return l.raiseFmt("C function returned more results than it pushed", .{});
    return nres;
}

export fn lus_pushcfunction(l: *Thread, f: lus_CFunction) c_int {
    return lus_pushcclosure(l, f, 0);
}

export fn lus_pushcclosure(l: *Thread, f: lus_CFunction, n: c_int) c_int {
    const nup: u32 = @intCast(@max(n, 0));
    const first = l.top - nup;
    return protect(l, first, struct {
        fn make(t: *Thread, func: lus_CFunction, count: u32, from: u32) Error!void {
            const nat = state.newNative(t.g, trampoline, null, count + 1) catch return t.raiseMem();
            const ups = nat.upvalues();
            ups[0] = Value.light(@ptrFromInt(@intFromPtr(func)));
            for (0..count) |i| ups[i + 1] = t.stack[from + i];
            t.top = from;
            try t.push(Value.obj(.native, nat));
        }
    }.make, .{ l, f, nup, first });
}

export fn lus_getupvalue(l: *Thread, i: c_int) void {
    if (l.frames.items.len > 0 and i >= 1) {
        if (l.frame().native) |nat| {
            if (nat.func == trampoline and @as(u32, @intCast(i)) < nat.nupvals) {
                l.push(nat.upvalues()[@intCast(i)]) catch {};
                return;
            }
        }
    }
    l.push(.nil) catch {};
}

export fn lus_stringify(l: *Thread, idx: c_int) c_int {
    const v = at(l, idx);
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, x: Value) Error!void {
            try t.push(x);
            const s = try ops.toString(t, x);
            t.stack[t.top - 1] = Value.obj(.string, s);
        }
    }.f, .{ l, v });
}

// ---------------------------------------------------------------------
// Tables and globals

fn getIn(t: *Thread, obj: Value, key: Value) Error!void {
    // The key stays on the stack while metamethods run.
    try t.push(key);
    const v = try ops.index(t, obj, key);
    t.stack[t.top - 1] = v;
}

fn setIn(t: *Thread, obj: Value, key: Value, val: Value) Error!void {
    try ops.setIndex(t, obj, key, val);
}

fn keyString(t: *Thread, k: [*:0]const u8) Error!Value {
    return t.newStringValue(std.mem.span(k));
}

export fn lus_getfield(l: *Thread, idx: c_int, k: [*:0]const u8) c_int {
    const obj = at(l, idx);
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value, key: [*:0]const u8) Error!void {
            try getIn(t, o, try keyString(t, key));
        }
    }.f, .{ l, obj, k });
}

export fn lus_setfield(l: *Thread, idx: c_int, k: [*:0]const u8) c_int {
    const obj = at(l, idx);
    const top = l.top - 1;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value, key: [*:0]const u8) Error!void {
            const ks = try keyString(t, key);
            try t.push(ks);
            try setIn(t, o, ks, t.stack[t.top - 2]);
            t.top -= 2;
        }
    }.f, .{ l, obj, k });
}

export fn lus_gettable(l: *Thread, idx: c_int) c_int {
    const obj = at(l, idx);
    const top = l.top - 1;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value) Error!void {
            const key = t.stack[t.top - 1];
            const v = try ops.index(t, o, key);
            t.stack[t.top - 1] = v;
        }
    }.f, .{ l, obj });
}

export fn lus_settable(l: *Thread, idx: c_int) c_int {
    const obj = at(l, idx);
    const top = l.top - 2;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value) Error!void {
            try setIn(t, o, t.stack[t.top - 2], t.stack[t.top - 1]);
            t.top -= 2;
        }
    }.f, .{ l, obj });
}

export fn lus_getglobal(l: *Thread, name: [*:0]const u8) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, key: [*:0]const u8) Error!void {
            try getIn(t, t.g.globals, try keyString(t, key));
        }
    }.f, .{ l, name });
}

export fn lus_setglobal(l: *Thread, name: [*:0]const u8) c_int {
    const top = l.top - 1;
    return protect(l, top, struct {
        fn f(t: *Thread, key: [*:0]const u8) Error!void {
            const ks = try keyString(t, key);
            try t.push(ks);
            try setIn(t, t.g.globals, ks, t.stack[t.top - 2]);
            t.top -= 2;
        }
    }.f, .{ l, name });
}

fn tableAt(l: *Thread, idx: c_int) ?*Table {
    const v = at(l, idx);
    return if (v.tag == .table) v.as(Table) else null;
}

export fn lus_rawget(l: *Thread, idx: c_int) c_int {
    const key = l.stack[l.top - 1];
    const v = if (tableAt(l, idx)) |t| table.get(t, key) else Value.nil;
    l.stack[l.top - 1] = v;
    return typeCode(v.tag);
}

export fn lus_rawgeti(l: *Thread, idx: c_int, n: i64) c_int {
    const v = if (tableAt(l, idx)) |t| table.getInt(t, n) else Value.nil;
    l.push(v) catch {};
    return typeCode(v.tag);
}

export fn lus_rawset(l: *Thread, idx: c_int) c_int {
    const tv = at(l, idx);
    const top = l.top - 2;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value) Error!void {
            if (o.tag != .table) return t.raiseRun("attempt to index a {s} value", .{value.typeName(o.tag)});
            try ops.rawSet(t, o.as(Table), t.stack[t.top - 2], t.stack[t.top - 1]);
            t.top -= 2;
        }
    }.f, .{ l, tv });
}

export fn lus_rawseti(l: *Thread, idx: c_int, n: i64) c_int {
    const tv = at(l, idx);
    const top = l.top - 1;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value, i: i64) Error!void {
            if (o.tag != .table) return t.raiseRun("attempt to index a {s} value", .{value.typeName(o.tag)});
            try ops.rawSet(t, o.as(Table), Value.int(i), t.stack[t.top - 1]);
            t.top -= 1;
        }
    }.f, .{ l, tv, n });
}

export fn lus_next(l: *Thread, idx: c_int) c_int {
    const t = tableAt(l, idx);
    const key = l.pop();
    const tab = t orelse {
        _ = l.raiseRun("table expected", .{}) catch {};
        pushErr(l);
        return LUS_ERROR;
    };
    const r = table.next(tab, key) catch {
        _ = l.raiseRun("invalid key to 'next'", .{}) catch {};
        pushErr(l);
        return LUS_ERROR;
    };
    const pair = r orelse return 0;
    l.ensure(2) catch {
        pushErr(l);
        return errStatus(l);
    };
    l.push(pair.key) catch unreachable;
    l.push(pair.val) catch unreachable;
    return 1;
}

export fn lus_len(l: *Thread, idx: c_int) c_int {
    const v = at(l, idx);
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, x: Value) Error!void {
            try t.push(x);
            const len_value = try ops.length(t, x);
            t.stack[t.top - 1] = len_value;
        }
    }.f, .{ l, v });
}

// ---------------------------------------------------------------------
// Metatables and userdata

export fn lus_newuserdata(l: *Thread, size: usize) ?*anyopaque {
    const g = l.g;
    gc.maybeCollect(g);
    const u = gc.alloc(g, object.Userdata, .userdata, object.Userdata.allocSize(size, 0)) catch {
        _ = l.raiseMem() catch {};
        pushErr(l);
        return null;
    };
    u.size = size;
    u.nuser = 0;
    l.push(Value.obj(.userdata, u)) catch return null;
    return @ptrCast(u.data());
}

fn registryTable(l: *Thread) *Table {
    return l.g.registry.as(Table);
}

export fn lus_newmetatable(l: *Thread, tname: [*:0]const u8) c_int {
    const top = l.top;
    var created = false;
    const st = protect(l, top, struct {
        fn f(t: *Thread, name: [*:0]const u8, made: *bool) Error!void {
            const key = try keyString(t, name);
            try t.push(key);
            const existing = table.get(registryTable(t), key);
            if (existing.tag == .table) {
                t.stack[t.top - 1] = existing;
                return;
            }
            const mt = try t.newTable(0, 4);
            try t.push(Value.obj(.table, mt));
            try ops.rawSet(t, mt, try t.newStringValue("__name"), key);
            try ops.rawSet(t, registryTable(t), key, Value.obj(.table, mt));
            t.stack[t.top - 2] = Value.obj(.table, mt);
            t.top -= 1;
            made.* = true;
        }
    }.f, .{ l, tname, &created });
    if (st != LUS_OK) return LUS_ERROR;
    return @intFromBool(created);
}

export fn lus_getmetatable(l: *Thread, tname: [*:0]const u8) void {
    const s = state.newStringIn(l.g, std.mem.span(tname)) catch {
        l.push(.nil) catch {};
        return;
    };
    const v = table.getStr(registryTable(l), s);
    l.push(if (v.tag == .table) v else .nil) catch {};
}

export fn lus_setmetatable(l: *Thread, idx: c_int) c_int {
    const obj = at(l, idx);
    const top = l.top - 1;
    return protect(l, top, struct {
        fn f(t: *Thread, o: Value) Error!void {
            const mtv = t.stack[t.top - 1];
            if (mtv.tag != .nil and mtv.tag != .table) return t.raiseRun("metatable must be a table or nil", .{});
            const mt: ?*Table = if (mtv.tag == .table) mtv.as(Table) else null;
            switch (o.tag) {
                .table => {
                    const tab = o.as(Table);
                    tab.metatable = mt;
                    if (mt) |m| {
                        gc.barrierBack(t.g, &tab.hdr);
                        try base_lib.registerFinalizer(t, &tab.hdr, m);
                    }
                },
                .userdata => {
                    const u = o.as(object.Userdata);
                    u.metatable = mt;
                    if (mt) |m| {
                        gc.barrierBack(t.g, &u.hdr);
                        try base_lib.registerFinalizer(t, &u.hdr, m);
                    }
                },
                else => return t.raiseRun("cannot set the metatable of a {s} value", .{value.typeName(o.tag)}),
            }
            t.top -= 1;
        }
    }.f, .{ l, obj });
}

export fn lus_getmetatableof(l: *Thread, idx: c_int) c_int {
    const mt = l.metatable(at(l, idx)) orelse return 0;
    l.push(Value.obj(.table, mt)) catch return 0;
    return 1;
}

export fn lus_toudata(l: *Thread, idx: c_int, tname: [*:0]const u8) ?*anyopaque {
    const v = at(l, idx);
    if (v.tag != .userdata) return null;
    const u = v.as(object.Userdata);
    const mt = u.metatable orelse return null;
    const s = state.newStringIn(l.g, std.mem.span(tname)) catch return null;
    const want = table.getStr(registryTable(l), s);
    if (want.tag != .table or want.as(Table) != mt) return null;
    return @ptrCast(u.data());
}

// ---------------------------------------------------------------------
// References

/// The registry table that holds referenced values by number.
fn refTable(l: *Thread) Error!*Table {
    const reg = registryTable(l);
    const key = try keyString(l, refs_key);
    const v = table.get(reg, key);
    if (v.tag == .table) return v.as(Table);
    try l.push(key);
    const t = try l.newTable(0, 8);
    try l.push(Value.obj(.table, t));
    try ops.rawSet(l, reg, key, Value.obj(.table, t));
    l.top -= 2;
    return t;
}

export fn lus_ref(l: *Thread) c_int {
    const v = l.stack[l.top - 1];
    if (v.isNil()) {
        l.top -= 1;
        return LUS_NOREF;
    }
    const h = host(l.g);
    var ref: c_int = 0;
    const st = protect(l, l.top - 1, struct {
        fn f(t: *Thread, hh: *Host, out_ref: *c_int) Error!void {
            const refs = try refTable(t);
            const r = hh.free_refs.pop() orelse blk: {
                const n = hh.next_ref;
                hh.next_ref += 1;
                break :blk n;
            };
            ops.rawSet(t, refs, Value.int(r), t.stack[t.top - 1]) catch |e| {
                hh.free_refs.append(gpa, r) catch {};
                return e;
            };
            out_ref.* = r;
            t.top -= 1;
        }
    }.f, .{ l, h, &ref });
    if (st != LUS_OK) return LUS_ERROR;
    return ref;
}

export fn lus_getref(l: *Thread, ref: c_int) void {
    if (ref <= 0) {
        l.push(.nil) catch {};
        return;
    }
    const s = state.newStringIn(l.g, refs_key) catch {
        l.push(.nil) catch {};
        return;
    };
    const refs = table.getStr(registryTable(l), s);
    const v = if (refs.tag == .table) table.getInt(refs.as(Table), ref) else Value.nil;
    l.push(v) catch {};
}

export fn lus_unref(l: *Thread, ref: c_int) void {
    if (ref <= 0) return;
    const s = state.newStringIn(l.g, refs_key) catch return;
    const refs = table.getStr(registryTable(l), s);
    if (refs.tag != .table) return;
    if (table.getInt(refs.as(Table), ref).isNil()) return;
    table.setInt(l.g.gpa, refs.as(Table), ref, .nil) catch return;
    host(l.g).free_refs.append(gpa, ref) catch {};
}

// ---------------------------------------------------------------------
// Loading and calling

export fn lus_load(l: *Thread, buf: ?[*]const u8, len: usize, chunkname: ?[*:0]const u8) c_int {
    const src: []const u8 = if (len == 0) "" else buf.?[0..len];
    const name = if (chunkname) |c| std.mem.span(c) else "=(load)";
    const top = l.top;
    api.load(l, src, name) catch {
        const syntax = !(l.err.tag == .string and l.err.as(String) == l.g.memerr);
        l.top = top;
        pushErr(l);
        if (!syntax) return errStatus(l);
        return LUS_ERRSYNTAX;
    };
    return LUS_OK;
}

export fn lus_loadfile(l: *Thread, path: [*:0]const u8) c_int {
    const p = std.mem.span(path);
    const src = std.Io.Dir.cwd().readFileAlloc(l.g.io, p, l.g.gpa, .unlimited) catch |e| {
        const msg = std.fmt.allocPrint(l.g.gpa, "cannot open {s}: {s}", .{ p, @import("lib/os.zig").errnoOf(e).msg }) catch {
            l.push(Value.obj(.string, l.g.memerr)) catch {};
            return LUS_ERRMEM;
        };
        defer l.g.gpa.free(msg);
        _ = pushBytesAsString(l, msg);
        return LUS_ERRFILE;
    };
    defer l.g.gpa.free(src);
    const name = std.fmt.allocPrintSentinel(l.g.gpa, "@{s}", .{p}, 0) catch {
        l.push(Value.obj(.string, l.g.memerr)) catch {};
        return LUS_ERRMEM;
    };
    defer l.g.gpa.free(name);
    return lus_load(l, src.ptr, src.len, name.ptr);
}

export fn lus_pcall(l: *Thread, nargs: c_int, nresults: c_int) c_int {
    const na: u32 = @intCast(@max(nargs, 0));
    const want: i32 = if (nresults < 0) -1 else nresults;
    const saved_tb = l.want_traceback;
    l.want_traceback = true;
    l.err_traceback = null;
    defer l.want_traceback = saved_tb;
    if (api.pcall(l, na, want)) return LUS_OK;
    return errStatus(l);
}

/// Runs the detached coroutines of the state. With `wait` nonzero it runs
/// them until none is left and then reports the error of a coroutine
/// that failed with nothing left to collect it. With `wait` zero it runs
/// the coroutines that are ready and returns.
export fn lus_runpending(l: *Thread, wait: c_int) c_int {
    l.err_traceback = null;
    if (api.runPending(l, wait != 0)) return LUS_OK;
    pushErr(l);
    return errStatus(l);
}

/// The number of detached coroutines that have not ended.
export fn lus_pending(l: *Thread) c_int {
    return @intCast(@min(api.pendingCoroutines(l), std.math.maxInt(c_int)));
}

export fn lus_traceback(l: *Thread) ?[*:0]const u8 {
    const s = l.err_traceback orelse return null;
    return @ptrCast(s.bytes().ptr);
}

export fn lus_dostring(l: *Thread, src: [*:0]const u8) c_int {
    const s = std.mem.span(src);
    const st = lus_load(l, s.ptr, s.len, "=(dostring)");
    if (st != LUS_OK) return st;
    return lus_pcall(l, 0, LUS_MULTRET);
}

export fn lus_dofile(l: *Thread, path: [*:0]const u8) c_int {
    const st = lus_loadfile(l, path);
    if (st != LUS_OK) return st;
    return lus_pcall(l, 0, LUS_MULTRET);
}

// ---------------------------------------------------------------------
// Permissions

fn applySpec(l: *Thread, spec: []const u8) c_int {
    const top = l.top;
    var refused = false;
    const st = protect(l, top, struct {
        fn f(t: *Thread, s: []const u8, r: *bool) Error!void {
            if (try pledge.hostApply(t, s) == .refused) r.* = true;
        }
    }.f, .{ l, spec, &refused });
    if (st != LUS_OK) return st;
    if (refused) {
        _ = l.raiseRun("permission set is sealed", .{}) catch {};
        pushErr(l);
        return LUS_ERRRUN;
    }
    return LUS_OK;
}

export fn lus_grant(l: *Thread, spec: [*:0]const u8) c_int {
    return applySpec(l, std.mem.span(spec));
}

export fn lus_reject(l: *Thread, name: [*:0]const u8) c_int {
    const n = std.mem.span(name);
    const spec = std.fmt.allocPrint(gpa, "~{s}", .{n}) catch {
        l.push(Value.obj(.string, l.g.memerr)) catch {};
        return LUS_ERRMEM;
    };
    defer gpa.free(spec);
    return applySpec(l, spec);
}

export fn lus_seal(l: *Thread) c_int {
    return applySpec(l, "seal");
}

fn optSpan(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}

export fn lus_require(l: *Thread, cap: [*:0]const u8, val: ?[*:0]const u8) c_int {
    const top = l.top;
    return protect(l, top, struct {
        fn f(t: *Thread, c: []const u8, v: ?[]const u8) Error!void {
            try pledge.require(t, c, v);
        }
    }.f, .{ l, std.mem.span(cap), optSpan(val) });
}

export fn lus_allowed(l: *Thread, cap: [*:0]const u8, val: ?[*:0]const u8) c_int {
    return @intFromBool(pledge.allowed(l, std.mem.span(cap), optSpan(val)));
}

pub const lus_CapMatch = *const fn (ud: ?*anyopaque, granted: [*:0]const u8, requested: [*:0]const u8) callconv(.c) c_int;

pub const lus_Capability = extern struct {
    name: ?[*:0]const u8,
    subcapabilities: ?[*:null]const ?[*:0]const u8,
    kind: c_int,
    match: ?lus_CapMatch,
    ud: ?*anyopaque,
};

/// The context of a capability declared from C: its C matcher and the
/// host's pointer. Lives as long as the state.
const CMatch = struct {
    match: lus_CapMatch,
    ud: ?*anyopaque,
};

fn callCMatch(ctx: ?*anyopaque, granted: []const u8, requested: []const u8) bool {
    const m: *CMatch = @ptrCast(@alignCast(ctx.?));
    const g = gpa.dupeSentinel(u8, granted, 0) catch return false;
    defer gpa.free(g);
    const r = gpa.dupeSentinel(u8, requested, 0) catch return false;
    defer gpa.free(r);
    return m.match(m.ud, g.ptr, r.ptr) != 0;
}

fn failMsg(l: *Thread, msg: []const u8) c_int {
    _ = l.raiseRun("{s}", .{msg}) catch {};
    pushErr(l);
    return LUS_ERRRUN;
}

export fn lus_defcapability(l: *Thread, cap: *const lus_Capability) c_int {
    const g = l.g;
    const name = std.mem.span(cap.name orelse return failMsg(l, "capability has no name"));
    if (name.len == 0 or name.len >= 64 or std.mem.indexOfAny(u8, name, ":=~ ") != null)
        return failMsg(l, "invalid capability name");
    if (std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "seal") or pledge.isDefined(g, name)) {
        return failMsg(l, "capability is already defined");
    }
    const kind: pledge.Kind = switch (cap.kind) {
        0 => .none,
        1 => .path,
        2 => .host,
        3 => .pattern,
        4 => .custom,
        else => return failMsg(l, "invalid capability kind"),
    };
    if (kind == .custom and cap.match == null) return failMsg(l, "custom capability needs a match function");
    var subs: std.ArrayList([]const u8) = .empty;
    errdefer subs.deinit(g.gpa);
    if (cap.subcapabilities) |list| {
        var i: usize = 0;
        while (list[i]) |s| : (i += 1) {
            const owned = g.gpa.dupe(u8, std.mem.span(s)) catch return oom(l);
            subs.append(g.gpa, owned) catch return oom(l);
        }
    }
    var c: pledge.Capability = .{
        .name = g.gpa.dupe(u8, name) catch return oom(l),
        .subs = subs.toOwnedSlice(g.gpa) catch return oom(l),
        .kind = kind,
        .owned = true,
    };
    if (kind == .custom) {
        const m = makeCMatch(l, .{ .match = cap.match.?, .ud = cap.ud }) orelse return oom(l);
        c.match = callCMatch;
        c.ctx = m;
    }
    pledge.define(g, c) catch return oom(l);
    return LUS_OK;
}

/// Allocates a matcher context owned by the state. Contexts are kept in
/// the host record and freed with it.
fn makeCMatch(l: *Thread, m: CMatch) ?*CMatch {
    const h = host(l.g);
    const p = gpa.create(CMatch) catch return null;
    p.* = m;
    h.matchers.append(gpa, p) catch {
        gpa.destroy(p);
        return null;
    };
    return p;
}

fn oom(l: *Thread) c_int {
    l.push(Value.obj(.string, l.g.memerr)) catch {};
    return LUS_ERRMEM;
}

pub const lus_RequestHook = *const fn (ud: ?*anyopaque, l: *Thread, cap: [*:0]const u8, val: ?[*:0]const u8) callconv(.c) c_int;

fn callRequestHook(ctx: ?*anyopaque, l: *Thread, name: []const u8, val: ?[]const u8) bool {
    _ = ctx;
    const h = host(l.g);
    const req = h.request orelse return false;
    const n = gpa.dupeSentinel(u8, name, 0) catch return false;
    defer gpa.free(n);
    const v: ?[:0]u8 = if (val) |x| (gpa.dupeSentinel(u8, x, 0) catch return false) else null;
    defer if (v) |x| gpa.free(x);
    const top = l.top;
    defer l.top = top;
    return req.func(req.ud, l, n.ptr, if (v) |x| x.ptr else null) != 0;
}

export fn lus_onrequest(l: *Thread, hook: ?lus_RequestHook, ud: ?*anyopaque) void {
    const h = host(l.g);
    if (hook) |f| {
        h.request = .{ .func = f, .ud = ud };
        pledge.setRequestHook(l.g, .{ .func = callRequestHook });
    } else {
        h.request = null;
        pledge.setRequestHook(l.g, null);
    }
}
