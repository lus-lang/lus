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

pub const StepFn = *const fn (l: *Thread, pc: u32, stop: usize) callconv(.c) usize;

fn StepOf(comptime o: Op) type {
    return struct {
        /// Runs the instruction before `pc` in the top frame and returns
        /// an `interp.Step` code.
        fn step(l: *Thread, pc: u32, stop: usize) callconv(.c) usize {
            l.frames.items[l.frames.items.len - 1].pc = pc;
            return interp.run(l, stop, .{ .step = o }) catch |e| {
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

/// A call with a fixed argument count to a function that has native
/// code. Pushes the callee's frame and returns where it starts. A zero
/// address means the step routine must make the call.
pub fn call(l: *Thread, bp: [*]Value, ins: u32, pc: u32) callconv(.c) jit.Target {
    const none: jit.Target = .{ .addr = 0, .base = 0 };
    const a = opc.a(ins);
    const callee = &bp[a];
    if (callee.tag != .closure) return none;
    const cl = callee.as(Closure);
    const p = cl.proto;
    const code: *jit.Code = @ptrCast(@alignCast(p.jit_code orelse return none));
    if (p.is_vararg) return none;
    if (l.g.tobefnz.items.len > 0) return none;
    const fr = l.frame();
    const func = fr.base + a;
    const nb = opc.b(ins);
    const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
    fr.pc = pc;
    // A failure here leaves the frame as the instruction found it, and
    // the step routine raises the error.
    interp.enterLus(l, cl, func, nargs, @as(i32, opc.c(ins)) - 1) catch return none;
    return .{ .addr = @intFromPtr(code.block.ptr) + code.offs[0], .base = func + 1 };
}

/// A return of zero or one value to a Lus caller with nothing to close.
/// Returns where the caller continues. A zero address means the step
/// routine must make the return, and an address of one means that the
/// return happened and the caller has no native code.
pub fn ret(l: *Thread, n: u32, a: u32, stop: usize) callconv(.c) jit.Target {
    const c = interp.load(l);
    if (!interp.leanReturn(l, c, stop)) return .{ .addr = 0, .base = 0 };
    const caller = interp.fast.finishLean(l, c, c.base + a, n);
    const code: *jit.Code = @ptrCast(@alignCast(caller.cl.proto.jit_code orelse return .{ .addr = 1, .base = 0 }));
    return .{ .addr = @intFromPtr(code.block.ptr) + code.offs[caller.fr.pc], .base = caller.base };
}
