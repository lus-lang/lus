//! `os.signal(name, ...)`: a coroutine that hands over the signals the
//! program asked for. Each resume waits for the next of them and returns
//! its name. Signals that arrive between two resumes are counted, so each
//! one is delivered by a resume of its own. While a coroutine handles a
//! signal, the signal no longer ends the program. Closing the coroutine,
//! or the collection of it, restores the action that was in place before
//! once no other coroutine handles that signal.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const sched = @import("../vm/sched.zig");
const sigwatch = @import("../vm/sigwatch.zig");
const aux = @import("auxlib.zig");
const base_lib = @import("base.zig");
const events = @import("events.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const String = object.String;
const Sig = sigwatch.Sig;

const n_sigs = 4;

const Handle = struct {
    /// The signals this coroutine handles.
    mask: [n_sigs]bool = @splat(false),
    /// How many of each signal it delivered or saw before it started.
    seen: [n_sigs]u64 = @splat(0),
    open: bool = false,
};

const key = "os.signal";

pub fn open(l: *Thread, os_t: *Table) Error!void {
    if (!sigwatch.supported) return;
    const mt = try l.newTable(0, 4);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setField(l, mt, "__close", try aux.native(l, close, "__close"));
    try aux.setField(l, mt, "__gc", try aux.native(l, close, "__gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue("signal handler"));
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, key, mt) catch return l.raiseMem();
    try aux.setField(l, os_t, "signal", try aux.native(l, signal, "signal"));
}

fn handleMt(l: *Thread) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(key).?));
}

fn toHandle(l: *Thread, v: Value) ?*Handle {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != handleMt(l)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn close(l: *Thread) Error!u32 {
    const h = toHandle(l, l.arg(1)) orelse return 0;
    if (!h.open) return 0;
    h.open = false;
    for (h.mask, 0..) |on, i| if (on) sigwatch.release(@fromBackingInt(@intCast(i)));
    return 0;
}

fn signal(l: *Thread) Error!u32 {
    const n = l.argCount();
    if (n == 0) return aux.argError(l, 1, "signal name expected", .{});
    var mask: [n_sigs]bool = @splat(false);
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const s = try aux.checkBytes(l, i);
        const sig: Sig = if (std.mem.eql(u8, s, "interrupt")) .interrupt else if (std.mem.eql(u8, s, "terminate")) .terminate else if (std.mem.eql(u8, s, "hangup")) .hangup else return aux.argError(l, i, "unknown signal '{s}' (expected \"interrupt\", \"terminate\", or \"hangup\")", .{s});
        if (sig == .hangup and builtin.os.tag == .windows) return aux.argError(l, i, "the signal 'hangup' does not exist on Windows", .{});
        mask[@backingInt(sig)] = true;
    }
    if (!sigwatch.subscribe(l.g)) return l.raiseFmt("signals cannot be delivered on this system", .{});
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Handle), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Handle);
    u.nuser = 0;
    u.metatable = handleMt(l);
    const h: *Handle = @ptrCast(@alignCast(u.data()));
    h.* = .{};
    const uv = Value.obj(.userdata, u);
    try l.push(uv);
    try base_lib.registerFinalizer(l, &u.hdr, handleMt(l));
    for (mask, 0..) |on, j| if (on) {
        const sig: Sig = @fromBackingInt(@intCast(j));
        if (!sigwatch.hold(sig)) {
            _ = try closeValue(l, uv);
            return l.raiseFmt("the signal '{s}' cannot be handled on this system", .{sig.name()});
        }
        h.mask[j] = true;
        h.open = true;
        h.seen[j] = sigwatch.count(sig);
    };
    _ = try events.repeating(l, wait, "signal", uv);
    return 1;
}

fn closeValue(l: *Thread, v: Value) Error!u32 {
    try l.push(v);
    defer l.top -= 1;
    const h = toHandle(l, v).?;
    if (!h.open) return 0;
    h.open = false;
    for (h.mask, 0..) |on, i| if (on) sigwatch.release(@fromBackingInt(@intCast(i)));
    return 0;
}

/// Waits for the next signal of the handle and returns its name.
fn wait(l: *Thread) Error!u32 {
    const h = toHandle(l, l.arg(1)) orelse return aux.typeError(l, 1, "signal handler");
    while (true) {
        if (!h.open) return l.raiseFmt("the signal handler is closed", .{});
        for (h.mask, 0..) |on, i| {
            if (!on) continue;
            const sig: Sig = @fromBackingInt(@intCast(i));
            if (sigwatch.count(sig) > h.seen[i]) {
                h.seen[i] += 1;
                if (sig == .interrupt) sigwatch.handling_interrupt.store(true, .release);
                return aux.retStr(l, sig.name());
            }
        }
        // A wait for an interrupt starts, so the program handles the next
        // one again.
        if (h.mask[@backingInt(Sig.interrupt)]) sigwatch.handling_interrupt.store(false, .release);
        try sched.waitNotify(l);
    }
}
