//! The routines native code calls. Every opcode has a step routine, which
//! is the interpreter's own body for that opcode, instantiated to run one
//! instruction. Native code falls back to it whenever an inline fast path
//! does not apply, so the tiers share one definition of every opcode.

const std = @import("std");
const state = @import("../vm/state.zig");
const interp = @import("../vm/interp.zig");
const ops = @import("../vm/ops.zig");
const opc = @import("../compile/opcodes.zig");
const Thread = state.Thread;
const Op = opc.Op;

/// Routines that native code calls take every integer as a full word.
/// The conventions of riscv64, loong64, ppc64le, and s390x extend a
/// 32-bit argument to 64 bits in a way that depends on its type, and the
/// callee relies on it, so a 32-bit parameter would make every caller in
/// native code extend each value the way its own target requires.
pub const StepFn = *const fn (l: *Thread, pc: usize, stop: usize, ins: usize) callconv(jit.cc) usize;

fn StepOf(comptime o: Op) type {
    return struct {
        /// Runs the instruction `ins`, which is the one before `pc` in
        /// the top frame, and returns an `interp.Step` code.
        fn step(l: *Thread, pc: usize, stop: usize, ins: usize) callconv(jit.cc) usize {
            l.frames.items[l.frames.items.len - 1].pc = @truncate(pc);
            return interp.run(l, stop, .{ .step = o }, @truncate(ins)) catch |e| {
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

/// The step routine of a return. A lean frame that needs the general
/// return, because it has a variable to close or returns several
/// values, still returns to the address its caller left in it.
/// The routine leaves that address for `jit.dispatch`, and native code
/// continues there with the result count that a lean return passes. The
/// general return has moved the results, padded them with nil to the
/// wanted count, and set the stack top as the code at that address does
/// again. A call that wants a fixed count finds that count, and the code
/// after it stores no nil.
fn ReturnOf(comptime o: Op) type {
    return struct {
        fn step(l: *Thread, pc: usize, stop: usize, ins: usize) callconv(jit.cc) usize {
            const depth = l.frames.items.len;
            const fr = &l.frames.items[depth - 1];
            const back: usize = if (fr.lean and l.hook_mask == 0) fr.resume_at else 0;
            const n: usize = if (fr.want >= 0) @intCast(fr.want) else switch (o) {
                .ret0 => 0,
                .ret1 => 1,
                else => blk: {
                    const w: u32 = @truncate(ins);
                    const nb = opc.b(w);
                    break :blk if (nb != 0) nb - 1 else l.top - (fr.base + opc.a(w));
                },
            };
            const s = StepOf(o).step(l, pc, stop, ins);
            if (back != 0 and s == interp.Step.dispatch and l.frames.items.len == depth - 1) {
                l.g.jit.resume_addr = back;
                l.g.jit.resume_count = n;
            }
            return s;
        }
    };
}

const op_values = @typeInfo(Op).@"enum".field_values;
const op_count = op_values.len;

/// The step routine of every opcode, indexed by opcode.
pub const steps: [op_count]StepFn = blk: {
    var t: [op_count]StepFn = undefined;
    for (op_values) |v| t[v] = &StepOf(@fromBackingInt(v)).step;
    for ([_]Op{ .ret, .ret0, .ret1 }) |o| t[@backingInt(o)] = &ReturnOf(o).step;
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

/// R[A] = R[A] .. ... .. R[A+n-1] for a short result of strings and
/// integers (`ops.joinShort`), written to `r[0]`. Returns 1 when it ran
/// and 0 when the step routine must run the instruction, which also
/// raises any error.
pub fn concatShort(l: *Thread, r: [*]Value, n: usize) callconv(jit.cc) usize {
    if (n == 0) return 0;
    const v = (ops.joinShort(l, r[0 .. n - 1], r[n - 1]) catch return 0) orelse return 0;
    r[0] = v;
    return 1;
}

/// `getctx`: the value of the context variable whose slot object is
/// `slotv`, as the running coroutine sees it, written to `dst`. Returns 1
/// when it ran and 0 when the step routine must run the instruction.
pub fn ctxGet(l: *Thread, dst: *Value, slotv: *const Value) callconv(jit.cc) usize {
    const slot = ctxSlot(l, slotv.*) orelse return 0;
    dst.* = @import("../vm/context.zig").get(l, slot);
    return 1;
}

/// `setctx`: assigns `v` when the running coroutine owns an array that
/// covers the slot. Any copy of the array is left to the step routine.
pub fn ctxSet(l: *Thread, slotv: *const Value, v: *const Value) callconv(jit.cc) usize {
    const slot = ctxSlot(l, slotv.*) orelse return 0;
    const arr = l.ctx orelse return 0;
    if (arr.refs != 1 or slot >= arr.vals.len) return 0;
    arr.vals[slot] = v.*;
    return 1;
}

inline fn ctxSlot(l: *Thread, v: Value) ?u32 {
    if (v.tag != .userdata) return null;
    const u = v.as(object.Userdata);
    if (l.g.ctx.slot_mt == null or u.metatable != l.g.ctx.slot_mt) return null;
    return @as(*const u32, @ptrCast(@alignCast(u.data()))).*;
}

/// A step of a generic `for` over `next` or `ipairs` (`interp.stepIterator`).
/// Returns 1 when it ran and 0 when the step routine must make the call.
pub fn tforStep(l: *Thread, rp: [*]Value, want: usize) callconv(jit.cc) usize {
    return @intFromBool(interp.stepIterator(l, rp, @intCast(want)));
}

pub fn getStr(l: *Thread, t: *const Value, key: *const Value, ic: *IcEntry, out: *Value) callconv(jit.cc) usize {
    return @intFromBool(!interp.fast.getStr(l, ic, t, key, out));
}

pub fn setStr(l: *Thread, t: *const Value, key: *const Value, ic: *IcEntry, v: *const Value) callconv(jit.cc) usize {
    return @intFromBool(!interp.fast.setStr(l, ic, t, key, v));
}

/// out = tab[i] for an integer key. This routine and `setArray` take and
/// return 64-bit integers only, and native code calls them with
/// `callWide`.
pub fn getArray(tab: u64, i: i64, out: u64) callconv(jit.cc) u64 {
    return @intFromBool(!interp.fast.getArray(jit.fromWide(*object.Table, tab), i, jit.fromWide(*Value, out)));
}

/// tab[i] = v for an integer key.
pub fn setArray(l: u64, tab: u64, i: i64, v: u64) callconv(jit.cc) u64 {
    return @intFromBool(!interp.fast.setArray(jit.fromWide(*Thread, l), jit.fromWide(*object.Table, tab), i, jit.fromWide(*const Value, v)));
}

pub fn getIndex(t: *const Value, i: usize, out: *Value) callconv(jit.cc) usize {
    return @intFromBool(!interp.fast.getIndex(t, @intCast(i), out));
}

pub fn length(x: *const Value, out: *Value) callconv(jit.cc) usize {
    return @intFromBool(!interp.fast.length(x, out));
}

/// The slow part of the write barrier, for a store native code made.
/// Closes the open upvalues at or above `level`, for a lean return.
pub fn closeUpvals(l: *Thread, level: usize) callconv(jit.cc) void {
    interp.closeUpvals(l, @intCast(level));
}

pub fn barrier(l: *Thread, h: *gc.Header) callconv(jit.cc) void {
    gc.barrierBack(l.g, h);
}

/// The slow part of the table write barrier, for a store native code
/// made into `tab`. `key` is null when the key was already present.
pub fn barrierTable(l: *Thread, tab: *object.Table, key: ?*const Value, v: *const Value) callconv(jit.cc) void {
    gc.barrierTable(l.g, tab, if (key) |k| k.* else .nil, v.*);
}

/// A tail call to a Lus function with fixed parameters and native code:
/// the closure branch of the interpreter's `tailcall`, with the checks
/// that could fail made before anything changes. Returns where the
/// callee starts. A zero address means the step routine must make the
/// call.
pub fn tailcall(l: *Thread, bp: [*]Value, ins_word: usize, pc_word: usize) callconv(jit.cc) jit.Target {
    const ins: u32 = @truncate(ins_word);
    const pc: u32 = @truncate(pc_word);
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
pub fn callNative(l: *Thread, ins_word: usize, pc_word: usize) callconv(jit.cc) usize {
    const ins: u32 = @truncate(ins_word);
    const pc: u32 = @truncate(pc_word);
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
pub fn tailNative(l: *Thread, ins_word: usize, pc_word: usize) callconv(jit.cc) usize {
    const ins: u32 = @truncate(ins_word);
    const pc: u32 = @truncate(pc_word);
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
pub fn returnAll(l: *Thread, stop: usize, ins_word: usize) callconv(jit.cc) usize {
    const ins: u32 = @truncate(ins_word);
    const func = l.frame().base + opc.a(ins);
    return interp.returnStep(l, func, l.top - func, stop) catch |e| {
        l.meta_finish = null;
        return switch (e) {
            error.MetaCall => interp.Step.dispatch,
            error.LusError => interp.Step.failed,
        };
    };
}
