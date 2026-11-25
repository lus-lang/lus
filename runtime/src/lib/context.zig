//! The library side of context variables (`spec/design/context.md`): the
//! slot objects that the hidden local of a declaration holds, the builtin
//! that a declaration calls, and `debug.getcontext` and `debug.setcontext`.

const std = @import("std");
const state = @import("../vm/state.zig");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const gc = @import("../vm/gc.zig");
const ctx = @import("../vm/context.zig");
const aux = @import("auxlib.zig");
const base_lib = @import("base.zig");
const Thread = state.Thread;
const Value = value.Value;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const String = object.String;

const Slot = struct { slot: u32 };

fn slotMt(l: *Thread) Error!*Table {
    if (l.g.ctx.slot_mt) |mt| return mt;
    const mt = try l.newTable(0, 3);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setField(l, mt, "__gc", try aux.native(l, slotGc, "__gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue("context variable"));
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), "context.slot", Value.obj(.table, mt));
    l.g.ctx.slot_mt = mt;
    return mt;
}

/// The slot that the value `v`, read from the hidden local of a
/// declaration, stands for.
pub inline fn slotOf(l: *Thread, v: Value) Error!u32 {
    if (v.tag == .userdata) {
        const u = v.as(Userdata);
        if (l.g.ctx.slot_mt != null and u.metatable == l.g.ctx.slot_mt) return @as(*Slot, @ptrCast(@alignCast(u.data()))).slot;
    }
    return l.raiseFmt("the slot of a context variable was replaced", .{});
}

fn slotGc(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.tag != .userdata) return 0;
    const u = v.as(Userdata);
    if (u.metatable != l.g.ctx.slot_mt) return 0;
    ctx.reclaim(l.g, @as(*Slot, @ptrCast(@alignCast(u.data()))).slot);
    return 0;
}

/// `ctxnew(default, name, source, line)`: the builtin a declaration calls.
/// Returns the slot object of a new variable.
pub fn ctxNew(l: *Thread) Error!u32 {
    const default = l.arg(1);
    const name = try aux.checkBytes(l, 2);
    const source = try aux.checkBytes(l, 3);
    const line = try aux.checkInt(l, 4);
    const mt = try slotMt(l);
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Slot), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Slot);
    u.nuser = 0;
    u.metatable = mt;
    const sp: *Slot = @ptrCast(@alignCast(u.data()));
    // Until the slot exists, the collector frees nothing for it.
    sp.slot = std.math.maxInt(u32);
    try l.push(Value.obj(.userdata, u));
    try base_lib.registerFinalizer(l, &u.hdr, mt);
    sp.slot = ctx.newSlot(l.g, default, name, source, @intCast(@max(line, 0))) catch return l.raiseMem();
    return 1;
}

/// The coroutine argument of a debug function, and the index of the next
/// argument.
fn threadArg(l: *Thread) struct { *Thread, u32 } {
    if (l.arg(1).tag == .thread) return .{ l.arg(1).as(Thread), 2 };
    return .{ l, 1 };
}

/// `debug.getcontext([co,] n)` returns the name, the value as `co` sees
/// it, and "source:line" of context variable number `n`.
pub fn getcontext(l: *Thread) Error!u32 {
    if (!@import("../vm/pledge.zig").allowedUntouched(l, "debug")) return l.raiseFmt("permission \"debug\" denied for debug.getcontext", .{});
    const ta = threadArg(l);
    const n = try aux.checkInt(l, ta[1]);
    const slot = ctx.nth(l.g, n) orelse return aux.retNil(l);
    const info = l.g.ctx.info.items[slot];
    try l.push(try l.newStringValue(info.name));
    try l.push(ctx.get(ta[0], slot));
    var buf: [600]u8 = undefined;
    const where = std.fmt.bufPrint(&buf, "{s}:{d}", .{ state.chunkId(info.source), info.line }) catch info.source;
    try l.push(try l.newStringValue(where));
    return 3;
}

/// `debug.setcontext([co,] n, value)` assigns the value for `co` and
/// returns the name, or nil past the last variable.
pub fn setcontext(l: *Thread) Error!u32 {
    if (!@import("../vm/pledge.zig").allowedUntouched(l, "debug")) return l.raiseFmt("permission \"debug\" denied for debug.setcontext", .{});
    const ta = threadArg(l);
    const n = try aux.checkInt(l, ta[1]);
    _ = try aux.checkAny(l, ta[1] + 1);
    const slot = ctx.nth(l.g, n) orelse return aux.retNil(l);
    ctx.set(ta[0], slot, l.arg(ta[1] + 1)) catch return l.raiseMem();
    return aux.retStr(l, l.g.ctx.info.items[slot].name);
}
