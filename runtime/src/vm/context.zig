//! Context variables (`spec/design/context.md`): locals declared with
//! `<context>`, whose value belongs to the running coroutine.
//!
//! Each variable has a slot, a small number. The state keeps the default
//! of every slot and the debug information of the variable. A coroutine
//! points to a context array with one value per slot, shared copy on write
//! with the coroutine that created it, or to nothing while neither it nor
//! an ancestor assigned a context variable. A read takes the value from
//! the array when the array covers the slot, and the default otherwise.
//! Every array holds, for each slot it covers, either a value assigned in
//! some coroutine or the default, so a read never needs a third case.

const std = @import("std");
const state = @import("state.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const Thread = state.Thread;
const Global = state.Global;
const Value = value.Value;
const Error = state.Error;

pub const Array = struct {
    refs: u32 = 1,
    vals: []Value,
    prev: ?*Array = null,
    next: ?*Array = null,
};

pub const Info = struct {
    name: []u8,
    source: []u8,
    line: u32,
    live: bool,
    /// Orders the live variables for `debug.getcontext` by when their
    /// declaration ran.
    order: u64,
};

pub const Store = struct {
    defaults: std.ArrayList(Value) = .empty,
    info: std.ArrayList(Info) = .empty,
    free: std.ArrayList(u32) = .empty,
    arrays: ?*Array = null,
    next_order: u64 = 0,
    /// The metatable of slot objects, which the registry roots.
    slot_mt: ?*object.Table = null,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        var a = s.arrays;
        while (a) |arr| {
            a = arr.next;
            gpa.free(arr.vals);
            gpa.destroy(arr);
        }
        for (s.info.items) |i| {
            gpa.free(i.name);
            gpa.free(i.source);
        }
        s.defaults.deinit(gpa);
        s.info.deinit(gpa);
        s.free.deinit(gpa);
        s.* = .{};
    }
};

/// The default values are roots of the collector.
pub fn markRoots(g: *Global, m: anytype) void {
    for (g.ctx.defaults.items) |v| m.mark(v);
}

/// The values of the array of a coroutine are traced through it.
pub fn traverse(l: *Thread, m: anytype) void {
    const arr = l.ctx orelse return;
    for (arr.vals) |v| m.mark(v);
}

/// A new coroutine starts with the values of its creator.
pub fn inherit(child: *Thread, parent: *Thread) void {
    if (parent.ctx) |arr| {
        arr.refs += 1;
        child.ctx = arr;
    }
}

/// Drops the array of a coroutine that is freed.
pub fn release(l: *Thread) void {
    const arr = l.ctx orelse return;
    l.ctx = null;
    arr.refs -= 1;
    if (arr.refs > 0) return;
    const g = l.g;
    if (arr.prev) |p| p.next = arr.next else g.ctx.arrays = arr.next;
    if (arr.next) |n| n.prev = arr.prev;
    g.gpa.free(arr.vals);
    g.gpa.destroy(arr);
}

/// Allocates a slot for a variable declared now. Returns its number.
pub fn newSlot(g: *Global, default: Value, name: []const u8, source: []const u8, line: u32) error{OutOfMemory}!u32 {
    const gpa = g.gpa;
    const n = try gpa.dupe(u8, name);
    errdefer gpa.free(n);
    const src = try gpa.dupe(u8, source);
    errdefer gpa.free(src);
    const info: Info = .{ .name = n, .source = src, .line = line, .live = true, .order = g.ctx.next_order };
    g.ctx.next_order += 1;
    if (g.ctx.free.pop()) |slot| {
        g.ctx.defaults.items[slot] = default;
        g.ctx.info.items[slot] = info;
        // An array that covers a reused slot holds the default of the new
        // variable.
        var a = g.ctx.arrays;
        while (a) |arr| : (a = arr.next) if (slot < arr.vals.len) {
            arr.vals[slot] = default;
        };
        return slot;
    }
    try g.ctx.defaults.ensureUnusedCapacity(gpa, 1);
    try g.ctx.info.ensureUnusedCapacity(gpa, 1);
    g.ctx.defaults.appendAssumeCapacity(default);
    g.ctx.info.appendAssumeCapacity(info);
    return @intCast(g.ctx.defaults.items.len - 1);
}

/// Frees the slot of a variable that nothing refers to any more. The
/// arrays drop the values they held for it.
pub fn reclaim(g: *Global, slot: u32) void {
    if (slot >= g.ctx.info.items.len or !g.ctx.info.items[slot].live) return;
    const gpa = g.gpa;
    const info = &g.ctx.info.items[slot];
    info.live = false;
    gpa.free(info.name);
    gpa.free(info.source);
    info.name = &.{};
    info.source = &.{};
    g.ctx.defaults.items[slot] = .nil;
    var a = g.ctx.arrays;
    while (a) |arr| : (a = arr.next) if (slot < arr.vals.len) {
        arr.vals[slot] = .nil;
    };
    g.ctx.free.append(gpa, slot) catch {};
}

/// The value of `slot` as the coroutine `l` sees it.
pub inline fn get(l: *Thread, slot: u32) Value {
    if (l.ctx) |arr| if (slot < arr.vals.len) return arr.vals[slot];
    // A slot object forged through the debug library names no variable.
    const defaults = l.g.ctx.defaults.items;
    return if (slot < defaults.len) defaults[slot] else .nil;
}

/// Assigns `v` to `slot` for the coroutine `l` alone. The array is copied
/// first when another coroutine shares it or when it does not cover the
/// slot yet.
pub fn set(l: *Thread, slot: u32, v: Value) error{OutOfMemory}!void {
    const g = l.g;
    if (l.ctx) |arr| if (arr.refs == 1 and slot < arr.vals.len) {
        arr.vals[slot] = v;
        return;
    };
    const gpa = g.gpa;
    const len = g.ctx.defaults.items.len;
    if (slot >= len) return;
    const vals = try gpa.alloc(Value, len);
    errdefer gpa.free(vals);
    const fresh = try gpa.create(Array);
    var have: usize = 0;
    if (l.ctx) |old| {
        have = @min(old.vals.len, len);
        @memcpy(vals[0..have], old.vals[0..have]);
    }
    @memcpy(vals[have..], g.ctx.defaults.items[have..len]);
    vals[slot] = v;
    fresh.* = .{ .vals = vals, .next = g.ctx.arrays };
    if (g.ctx.arrays) |h| h.prev = fresh;
    g.ctx.arrays = fresh;
    release(l);
    l.ctx = fresh;
}

/// The slot of the live context variable numbered `n` from 1 in the order
/// in which their declarations ran, or null past the last.
pub fn nth(g: *Global, n: i64) ?u32 {
    if (n < 1) return null;
    // Counts the live variables declared before each candidate.
    var best: ?u32 = null;
    for (g.ctx.info.items, 0..) |info, i| {
        if (!info.live) continue;
        var before: i64 = 0;
        for (g.ctx.info.items) |o| {
            if (o.live and o.order < info.order) before += 1;
        }
        if (before == n - 1) {
            best = @intCast(i);
            break;
        }
    }
    return best;
}
