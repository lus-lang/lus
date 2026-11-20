//! The routines native code calls. Every opcode has a step routine, which
//! is the interpreter's own body for that opcode, instantiated to run one
//! instruction. Native code falls back to it whenever an inline fast path
//! does not apply, so the tiers share one definition of every opcode.

const std = @import("std");
const state = @import("../vm/state.zig");
const interp = @import("../vm/interp.zig");
const opc = @import("../compile/opcodes.zig");
const Thread = state.Thread;
const Op = opc.Op;

pub const StepFn = *const fn (l: *Thread, pc: u32, stop: usize, ins: u32) callconv(.c) usize;

fn StepOf(comptime o: Op) type {
    return struct {
        /// Runs the instruction `ins`, which is the one before `pc` in
        /// the top frame, and returns an `interp.Step` code.
        fn step(l: *Thread, pc: u32, stop: usize, ins: u32) callconv(.c) usize {
            l.frames.items[l.frames.items.len - 1].pc = pc;
            return interp.run(l, stop, .{ .step = o }, ins) catch |e| {
                l.meta_finish = null;
                return switch (e) {
                    // A metamethod frame was pushed. It runs like a call.
                    error.MetaCall => interp.Step.dispatch,
                    error.LusError => interp.Step.failed,
                    error.Yield => interp.Step.yielded,
                    error.SwitchLoop, error.EnterJit => interp.Step.interpret,
                };
            };
        }
    };
}

const op_values = @typeInfo(Op).@"enum".field_values;
const op_count = op_values.len;

/// The step routine of every opcode, indexed by opcode.
pub const steps: [op_count]StepFn = blk: {
    var t: [op_count]StepFn = undefined;
    for (op_values) |v| t[v] = &StepOf(@fromBackingInt(v)).step;
    break :blk t;
};

// ---------------------------------------------------------------------
// Fast paths. Each returns zero when it completed the instruction and a
// nonzero value when native code must run the step routine instead. None
// of them moves the stack, raises, or leaves a frame half changed.

const object = @import("../vm/object.zig");
const value = @import("../vm/value.zig");
const gc = @import("../vm/gc.zig");
const jit = @import("jit.zig");
const Value = value.Value;
const IcEntry = object.IcEntry;
const Closure = object.Closure;

/// A step of a generic `for` over `next` or `ipairs` (`interp.stepIterator`).
/// Returns 1 when it ran and 0 when the step routine must make the call.
pub fn tforStep(l: *Thread, rp: [*]Value, want: usize) callconv(.c) usize {
    return @intFromBool(interp.stepIterator(l, rp, @intCast(want)));
}

pub fn getStr(l: *Thread, t: *const Value, key: *const Value, ic: *IcEntry, out: *Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.getStr(l, ic, t, key, out));
}

pub fn setStr(l: *Thread, t: *const Value, key: *const Value, ic: *IcEntry, v: *const Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.setStr(l, ic, t, key, v));
}

/// out = tab[i] for an integer key.
pub fn getArray(tab: *object.Table, i: i64, out: *Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.getArray(tab, i, out));
}

/// tab[i] = v for an integer key.
pub fn setArray(l: *Thread, tab: *object.Table, i: i64, v: *const Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.setArray(l, tab, i, v));
}

pub fn getIndex(t: *const Value, i: usize, out: *Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.getIndex(t, @intCast(i), out));
}

pub fn length(x: *const Value, out: *Value) callconv(.c) usize {
    return @intFromBool(!interp.fast.length(x, out));
}

/// The slow part of the write barrier, for a store native code made.
pub fn barrier(l: *Thread, h: *gc.Header) callconv(.c) void {
    gc.barrierBack(l.g, h);
}

/// The slow part of the table write barrier, for a store native code
/// made into `tab`. `key` is null when the key was already present.
pub fn barrierTable(l: *Thread, tab: *object.Table, key: ?*const Value, v: *const Value) callconv(.c) void {
    gc.barrierTable(l.g, tab, if (key) |k| k.* else .nil, v.*);
}

/// A tail call to a Lus function with fixed parameters and native code:
/// the closure branch of the interpreter's `tailcall`, with the checks
/// that could fail made before anything changes. Returns where the
/// callee starts. A zero address means the step routine must make the
/// call.
pub fn tailcall(l: *Thread, bp: [*]Value, ins: u32, pc: u32) callconv(.c) jit.Target {
    const none: jit.Target = .{ .addr = 0, .base = 0 };
    const a = opc.a(ins);
    const callee = bp[a];
    if (callee.tag != .closure) return none;
    const tcl = callee.as(Closure);
    const p = tcl.proto;
    const code: *jit.Code = @ptrCast(@alignCast(p.jit_code orelse return none));
    if (p.is_vararg) return none;
    const fr = l.frame();
    const func = fr.base + a;
    const nb = opc.b(ins);
    const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
    const dst = fr.ret;
    // The callee's registers must fit, so that entering it cannot fail
    // once this frame is gone.
    if (@as(usize, dst) + 1 + p.max_stack + nargs + 8 > l.stack.len) return none;
    fr.pc = pc;
    interp.closeUpvals(l, fr.base);
    const old = l.frames.pop().?;
    var i: u32 = 0;
    while (i <= nargs) : (i += 1) l.stack[dst + i] = l.stack[func + i];
    l.top = dst + 1 + nargs;
    interp.enterLus(l, tcl, dst, nargs, old.want) catch unreachable;
    const nf = l.frame();
    nf.boundary = old.boundary;
    nf.finish = old.finish;
    nf.tail = true;
    // The new frame returns to the same caller, so it inherits the
    // native return of the frame it replaces.
    nf.lean = old.lean;
    nf.plain = old.plain;
    nf.closes = old.plain;
    nf.resume_at = old.resume_at;
    return .{ .addr = code.base + code.offs[0], .base = dst + 1 };
}

/// Returned by a helper that changed nothing and needs the step routine.
/// The value lies outside the `interp.Step` codes.
pub const retry: usize = 7;

/// A call to a native function: the native branch of the interpreter's
/// `call`. Returns `interp.Step.next` when the call completed, another
/// `interp.Step` code when it raised, yielded, or set a hook, and `retry`
/// when the callee is something else or finalizers are pending.
pub fn callNative(l: *Thread, ins: u32, pc: u32) callconv(.c) usize {
    const fr = l.frame();
    fr.pc = pc;
    if (l.g.tobefnz.items.len > 0) return retry;
    const func = fr.base + opc.a(ins);
    const callee = l.stack[func];
    if (callee.tag != .native) return retry;
    const nb = opc.b(ins);
    const want: i32 = @as(i32, opc.c(ins)) - 1;
    const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
    if (nb != 0) l.top = func + nb;
    interp.callNative(l, callee.as(state.Native), func, nargs, want) catch |e| {
        l.meta_finish = null;
        return switch (e) {
            error.MetaCall => interp.Step.dispatch,
            error.LusError => interp.Step.failed,
            error.Yield => interp.Step.yielded,
        };
    };
    // A fixed result count restores the register window of the caller.
    const caller = l.frame();
    if (want >= 0) l.top = caller.base + caller.closure.?.proto.max_stack;
    // The native may have set a hook.
    if (l.hook_mask != 0) return interp.Step.interpret;
    return interp.Step.next;
}

/// A call to a native function in tail position: the native branch of
/// the interpreter's `tailcall` up to the return. The results are at the
/// register of the callee and run up to the stack top when this returns
/// `interp.Step.next`. It returns `retry`, with nothing changed, when the
/// callee is something else.
pub fn tailNative(l: *Thread, ins: u32, pc: u32) callconv(.c) usize {
    const fr = l.frame();
    const func = fr.base + opc.a(ins);
    const callee = l.stack[func];
    if (callee.tag != .native) return retry;
    fr.pc = pc;
    const nb = opc.b(ins);
    const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
    if (nb != 0) l.top = func + nb;
    interp.callNative(l, callee.as(state.Native), func, nargs, -1) catch |e| {
        l.meta_finish = null;
        return switch (e) {
            error.MetaCall => interp.Step.dispatch,
            error.LusError => interp.Step.failed,
            error.Yield => interp.Step.yielded,
        };
    };
    return interp.Step.next;
}

/// Returns every value from the register of the callee of the tail call
/// `ins` up to the stack top, as the interpreter does after a native
/// that was called in tail position.
pub fn returnAll(l: *Thread, stop: usize, ins: u32) callconv(.c) usize {
    const func = l.frame().base + opc.a(ins);
    return interp.returnStep(l, func, l.top - func, stop) catch |e| {
        l.meta_finish = null;
        return switch (e) {
            error.MetaCall => interp.Step.dispatch,
            error.LusError => interp.Step.failed,
        };
    };
}
