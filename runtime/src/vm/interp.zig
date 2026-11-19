//! The bytecode interpreter. Calls between Lus functions never recurse on
//! the native stack: they push a frame and continue the dispatch loop.
//! Natives run inline. A native that calls back into Lus re-enters the
//! loop through `call`, which marks a boundary frame.
//!
//! Errors are Zig errors. When one reaches the loop, the unwinder searches
//! the exception tables of the active Lus frames above the current
//! boundary, closes upvalues and to-be-closed variables, and resumes at the
//! handler. Entering a protected region costs nothing.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const state = @import("state.zig");
const table = @import("table.zig");
const ops = @import("ops.zig");
const gc = @import("gc.zig");
const jit = @import("../jit/jit.zig");
const numeric = @import("numeric.zig");
const opc = @import("../compile/opcodes.zig");
const Value = value.Value;
const Thread = state.Thread;
const Frame = state.Frame;
const Table = object.Table;
const String = object.String;
const Proto = object.Proto;
const Closure = object.Closure;
const Upvalue = object.Upvalue;
const Error = state.Error;
const Op = opc.Op;

/// Error variant used internally to unwind a coroutine back to `resume`.
pub const YieldError = error{Yield};
/// Internal: the running frame continues in another loop. `SwitchLoop`
/// means that hooks were set or cleared, or that native code handed a
/// frame back to the interpreter. `EnterJit` means that the running
/// function has native code.
pub const LoopError = error{ SwitchLoop, EnterJit };

/// How the dispatch loop is instantiated. `fast` and `hooked` are the two
/// interpreter loops. `step` runs the body of one opcode and returns, which
/// gives the JIT an out-of-line routine for every opcode that is the
/// interpreter's own definition of it.
pub const Mode = union(enum) { fast, hooked, step: Op };

/// What a step returns to native code.
pub const Step = struct {
    /// Continue with the next instruction.
    pub const next: u32 = 0;
    /// Continue after the next instruction. The frame's pc is saved.
    pub const skip: u32 = 1;
    /// Continue at the saved pc of the top frame, which may be another
    /// frame than the one that ran the step.
    pub const dispatch: u32 = 2;
    /// The frame count dropped to `stop`, or a boundary frame returned.
    pub const done: u32 = 3;
    pub const failed: u32 = 4;
    pub const yielded: u32 = 5;
    /// The interpreter loop continues the top frame.
    pub const interpret: u32 = 6;
};

fn RunResult(comptime mode: Mode) type {
    return if (mode == .step) u32 else void;
}

inline fn finished(comptime mode: Mode) RunResult(mode) {
    return if (mode == .step) Step.done else {};
}

// ---------------------------------------------------------------------
// Upvalues

pub fn findUpval(l: *Thread, level: u32) Error!*Upvalue {
    var prev: ?*Upvalue = null;
    var it = l.open_upvals;
    while (it) |u| {
        if (u.level < level) break;
        if (u.level == level) return u;
        prev = u;
        it = u.next_open;
    }
    const u = gc.allocUninit(l.g, Upvalue, .upvalue, @sizeOf(Upvalue)) catch return l.raiseMem();
    u.* = .{ .hdr = u.hdr, .loc = &l.stack[level], .level = level, .next_open = it };
    if (prev) |p| p.next_open = u else l.open_upvals = u;
    return u;
}

pub fn closeUpvals(l: *Thread, level: u32) void {
    while (l.open_upvals) |u| {
        if (u.level < level) break;
        u.closed = u.loc.*;
        u.loc = &u.closed;
        u.open = false;
        l.open_upvals = u.next_open;
        u.next_open = null;
        gc.barrierBack(l.g, &u.hdr);
    }
}

fn newClosedUpval(l: *Thread, v: Value) Error!*Upvalue {
    const u = gc.allocUninit(l.g, Upvalue, .upvalue, @sizeOf(Upvalue)) catch return l.raiseMem();
    u.* = .{ .hdr = u.hdr, .loc = undefined, .closed = v, .open = false };
    u.loc = &u.closed;
    return u;
}

/// Closes to-be-closed variables at or above `level`, calling `__close`
/// with the error value (nil on normal exit). An error raised by a
/// `__close` replaces the current one.
pub fn closeTbc(l: *Thread, level: u32, err: ?Value) Error!void {
    var cur_err = err;
    var failed = false;
    while (l.tbc.items.len > 0) {
        const lv = l.tbc.items[l.tbc.items.len - 1];
        if (lv < level) break;
        _ = l.tbc.pop();
        const obj = l.stack[lv];
        if (obj.isNil() or obj.tag == .false) continue;
        const tm = l.metamethod(obj, .close);
        const saved_top = l.top;
        if (l.top < lv + 1) l.top = lv + 1;
        if (tm.isNil()) {
            l.top = saved_top;
            continue;
        }
        if (err == null and l.meta_finish != null and tm.tag == .closure) {
            // A normal block exit inside the interpreter: the handler runs
            // as a frame (so it may yield) and the instruction runs again
            // for the remaining variables.
            _ = try ops.callMeta(l, tm, &.{ obj, .nil });
            unreachable;
        }
        _ = ops.callN(l, tm, &.{ obj, cur_err orelse .nil }, 0) catch {
            cur_err = l.err;
            failed = true;
        };
        l.top = saved_top;
    }
    if (failed) return l.raise(cur_err.?);
}

// ---------------------------------------------------------------------
// Calls

pub const CallKind = enum { lus, done };

/// Prepares a call to the value at `func` with `nargs` arguments above it.
/// For Lus functions it pushes a frame and returns `.lus`. Natives run to
/// completion and leave their results at `func` adjusted to `want`.
pub fn precall(l: *Thread, func: u32, nargs: u32, want: i32) (Error || YieldError)!CallKind {
    const f = func;
    var n = nargs;
    var callee = l.stack[f];
    var tries: u32 = 0;
    while (true) {
        switch (callee.tag) {
            .closure => {
                const cl = callee.as(Closure);
                const p = cl.proto;
                const np: u32 = p.num_params;
                try l.ensure(@as(usize, p.max_stack) + n + 8);
                // Missing fixed parameters become nil.
                var top = f + 1 + n;
                while (n < np) : (n += 1) {
                    l.stack[top] = .nil;
                    top += 1;
                }
                var base = f + 1;
                var nvar: u32 = 0;
                var fnslot = f;
                if (p.is_vararg) {
                    // Move the function and fixed parameters above the
                    // extra arguments, which stay in place below.
                    nvar = n - np;
                    fnslot = f + n + 1;
                    l.stack[fnslot] = l.stack[f];
                    var i: u32 = 0;
                    while (i < np) : (i += 1) {
                        l.stack[fnslot + 1 + i] = l.stack[f + 1 + i];
                        l.stack[f + 1 + i] = .nil;
                    }
                    base = fnslot + 1;
                }
                l.frames.append(l.g.gpa, .{
                    .func = fnslot,
                    .base = base,
                    .closure = cl,
                    .want = want,
                    .nvarargs = nvar,
                    .ret = f,
                }) catch return l.raiseMem();
                l.top = base + p.max_stack;
                // Registers above the parameters start nil.
                var r = base + np;
                while (r < l.top) : (r += 1) l.stack[r] = .nil;
                return .lus;
            },
            .native => {
                try callNative(l, callee.as(state.Native), f, n, want);
                return .done;
            },
            else => {
                // __call: insert the metamethod below the arguments.
                const tm = l.metamethod(callee, .call);
                if (tm.isNil()) return callError(l, callee);
                if (tries >= 15) return l.raiseFmt("'__call' chain too long", .{});
                try l.ensure(1);
                var i = f + 1 + n;
                while (i > f) : (i -= 1) l.stack[i] = l.stack[i - 1];
                l.stack[f] = tm;
                n += 1;
                l.top = f + 1 + n;
                callee = tm;
                tries += 1;
            },
        }
    }
}

fn callError(l: *Thread, callee: Value) Error {
    return l.typeError(callee, "call");
}

/// Finishes the topmost frame: moves its `nres` results (at the top of the
/// stack) to the frame's return slot, adjusted to the wanted count.
pub fn poscall(l: *Thread, nres: u32) Error!void {
    const fr = l.frames.pop().?;
    const src = l.top - nres;
    const dst = fr.ret;
    const want = fr.want;
    if (want < 0) {
        var i: u32 = 0;
        while (i < nres) : (i += 1) l.stack[dst + i] = l.stack[src + i];
        l.top = dst + nres;
    } else {
        const w: u32 = @intCast(want);
        var i: u32 = 0;
        while (i < w) : (i += 1) l.stack[dst + i] = if (i < nres) l.stack[src + i] else .nil;
        l.top = dst + w;
    }
}

/// Calls the value at `func` from native code. Returns the number of
/// results now at `func` (equal to `want` unless want is -1).
pub fn call(l: *Thread, func: u32, nargs: u32, want: i32) Error!u32 {
    if (l.ncalls >= Thread.max_ncalls or l.g.native_depth >= Thread.max_ncalls) return l.raiseFmt("stack overflow (too many nested native calls)", .{});
    l.ncalls += 1;
    l.g.native_depth += 1;
    defer {
        l.ncalls -= 1;
        l.g.native_depth -= 1;
    }
    l.meta_finish = null;
    const depth = l.frames.items.len;
    const as_hook = l.hook_calling;
    l.hook_calling = false;
    const kind = precall(l, func, nargs, want) catch |e| return yieldAcrossBoundary(l, e);
    if (kind == .lus) {
        if (as_hook) l.frame().hook = true;
        l.frame().boundary = true;
        execute(l, depth) catch |e| {
            const r = yieldAcrossBoundary(l, e);
            if (l.want_traceback and l.err_traceback == null) captureTraceback(l);
            unwindTo(l, depth);
            return r;
        };
    }
    return if (want < 0) l.top - func else @intCast(want);
}

fn yieldAcrossBoundary(l: *Thread, e: (Error || YieldError)) Error {
    return switch (e) {
        error.LusError => error.LusError,
        // The interpreter handles metamethod frames before they get here.
        error.MetaCall => unreachable,
        error.Yield => {
            l.yielding = false;
            l.status = .running;
            return l.raiseFmt("attempt to yield across a C-call boundary", .{});
        },
    };
}

/// Drops frames above `depth` after an error, closing their upvalues.
pub fn unwindTo(l: *Thread, depth: usize) void {
    if (l.frames.items.len <= depth) return;
    const level = l.frames.items[depth].ret;
    closeUpvals(l, level);
    // Pending to-be-closed variables of the abandoned frames are closed
    // with the error value.
    closeTbc(l, level, l.err) catch {};
    l.frames.items.len = depth;
}

// ---------------------------------------------------------------------
// The dispatch loop

/// The interpreter's view of the running frame, kept in locals. Frames live
/// in a growable list that a re-entrant call can reallocate, and the stack
/// grows by reallocation too, so `fr` and `bp` are refreshed after every
/// operation that may run other code.
const Ctx = struct {
    fi: usize,
    fr: *Frame,
    cl: *Closure,
    code: [*]const u32,
    k: [*]const Value,
    ic: [*]object.IcEntry,
    base: u32,
    /// Pointer to register 0 of the running frame.
    bp: [*]Value,

    inline fn refresh(c: *Ctx, l: *Thread) void {
        c.fr = &l.frames.items[c.fi];
        c.bp = l.stack.ptr + c.base;
    }
};

inline fn load(l: *Thread) Ctx {
    const fi = l.frames.items.len - 1;
    const fr = &l.frames.items[fi];
    const cl = fr.closure.?;
    return .{
        .fi = fi,
        .fr = fr,
        .cl = cl,
        .code = cl.proto.code.ptr,
        .k = cl.proto.constants.ptr,
        .ic = cl.proto.ic.ptr,
        .base = fr.base,
        .bp = l.stack.ptr + fr.base,
    };
}

/// Runs Lus frames until the frame count drops to `stop`.
pub fn execute(l: *Thread, stop: usize) (Error || YieldError)!void {
    // Native code runs a frame whenever its function has some and no hook
    // is set. Every frame lives on the Lus stack whatever runs it, so the
    // tiers hand frames to each other at any instruction boundary.
    var native = jit.enabled and jit.entryCheck(l);
    while (true) {
        // The hooked loop is a second instantiation of the same code, so
        // threads without hooks pay nothing for them.
        const r = if (l.hook_mask != 0)
            run(l, stop, .hooked)
        else if (jit.enabled and native)
            jit.run(l, stop)
        else
            run(l, stop, .fast);
        native = false;
        r catch |e| {
            l.meta_finish = null;
            switch (e) {
                // A metamethod frame was pushed, or the hooks changed.
                error.MetaCall, error.SwitchLoop => continue,
                error.EnterJit => {
                    native = true;
                    continue;
                },
                error.Yield => return error.Yield,
                error.LusError => {
                    if (l.g.debugger) |d| d.raised(d.ctx, l);
                    if (!handleError(l, stop)) return error.LusError;
                    native = jit.enabled and jit.hasCode(l);
                    continue;
                },
            }
        };
        return;
    }
}

/// Finds an exception handler in the Lus frames above `stop` for the
/// current error. On success the matching frame resumes at its handler.
fn handleError(l: *Thread, stop: usize) bool {
    // A coroutine closing itself unwinds past every handler.
    if (l.self_closed) return false;
    if (l.g.halting) return false;
    var i = l.frames.items.len;
    while (i > stop) {
        i -= 1;
        const fr = &l.frames.items[i];
        const cl = fr.closure orelse {
            if (fr.boundary) return false;
            continue;
        };
        const pc = if (fr.pc == 0) 0 else fr.pc - 1;
        for (cl.proto.handlers) |h| {
            if (pc >= h.start_pc and pc < h.end_pc) {
                // A nil payload becomes the standard message.
                if (l.err.isNil()) l.err = Value.obj(.string, state.newStringKnown(l.g, "<no error object>", true, 17) catch l.g.memerr);
                const err = l.err;
                const level = fr.base + h.level;
                // Drop inner frames.
                l.frames.items.len = i + 1;
                closeUpvals(l, level);
                l.top = fr.base + cl.proto.max_stack;
                closeTbc(l, level, err) catch {
                    // An error in __close replaces the caught error.
                };
                l.stack[fr.base + h.dest] = l.err;
                l.err = .nil;
                fr.pc = h.handler_pc;
                return true;
            }
        }
        if (fr.boundary) return false;
    }
    return false;
}

/// The parts of the dispatch loop that differ between its instantiations.
fn Loop(comptime mode: Mode) type {
    return struct {
        /// Fetches the next instruction. The frame's saved pc is written
        /// only before operations that can raise, call, or allocate,
        /// because errors, tracebacks, and returns read it from the frame.
        /// A step ends here: it dispatches to the `extraarg` case, which
        /// reports where execution continues.
        inline fn fetch(l: *Thread, c: *Ctx, pc: *u32, ins: *u32, comptime hooked: bool) Error!Op {
            if (mode == .step) return .extraarg;
            if (hooked) {
                try hookStep(l, c.fi, c.cl, pc.*);
                c.refresh(l);
            }
            ins.* = c.code[pc.*];
            pc.* += 1;
            return opc.op(ins.*);
        }

        /// Finishes a test instruction. The compiler always follows a test
        /// with a jump. When the test fails the jump is skipped. Otherwise
        /// the jump runs here without another dispatch, except under
        /// hooks, which see it as its own instruction.
        inline fn condJump(l: *Thread, c: *Ctx, pc: *u32, skip: bool, comptime hooked: bool) (Error || LoopError)!void {
            if (skip) {
                pc.* += 1;
                return;
            }
            if (hooked) return;
            const j = c.code[pc.*];
            const off = opc.sj(j);
            pc.* = @intCast(@as(i64, pc.*) + 1 + off);
            if (off < 0) {
                // Loops are safe points for pending finalizers.
                if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) {
                    c.fr.pc = pc.*;
                    try runPendingFinalizers(l);
                    c.refresh(l);
                }
                try tier(l, c, pc.*);
            }
        }

        /// Counts one event of the running function, whose next
        /// instruction is `pc`, on the function's own counter. A function
        /// that is hot enough gets native code, and the loop then hands
        /// the frame over. Only the rarer loop forms count this way,
        /// because the counter is a store on every event.
        inline fn tier(l: *Thread, c: *Ctx, pc: u32) LoopError!void {
            if (comptime !(jit.enabled and mode == .fast)) return;
            const p = c.cl.proto;
            p.hot -%= 1;
            if (p.hot == 0) {
                @branchHint(.unlikely);
                c.fr.pc = pc;
                if (jit.expire(l, p)) return error.EnterJit;
            }
        }

        /// Counts a loop iteration on the sampling budget, which lives in
        /// a machine register. When the budget runs out, the running
        /// function is charged for the whole period.
        inline fn tierLoop(l: *Thread, c: *Ctx, pc: *u32, budget: *u32) LoopError!void {
            if (comptime !(jit.enabled and mode == .fast)) return;
            budget.* -= 1;
            if (budget.* == 0) {
                @branchHint(.unlikely);
                c.fr.pc = pc.*;
                const r = jit.sample(l);
                budget.* = r.budget;
                if (r.enter) return error.EnterJit;
                // The frame state is read again, so that nothing has to
                // stay in a register across the rare call above.
                c.* = load(l);
                pc.* = c.fr.pc;
            }
        }

        /// A function was entered at `pc`. One with native code is handed
        /// over at once. Any other counts on the sampling budget.
        inline fn tierCall(l: *Thread, c: *Ctx, pc: *u32, budget: *u32) LoopError!void {
            if (comptime !(jit.enabled and mode == .fast)) return;
            if (c.cl.proto.jit_code != null) {
                @branchHint(.unlikely);
                c.fr.pc = pc.*;
                return error.EnterJit;
            }
            return tierLoop(l, c, pc, budget);
        }

        /// A callee returned into the running function, which continues
        /// at `pc`. Native code takes the frame when the function has some.
        inline fn tierReturn(l: *Thread, c: *Ctx, pc: u32) LoopError!void {
            _ = l;
            if (comptime !(jit.enabled and mode == .fast)) return;
            if (c.cl.proto.jit_code != null) {
                @branchHint(.unlikely);
                c.fr.pc = pc;
                return error.EnterJit;
            }
        }

        /// A numeric loop at `pc` is about to run `count` times. The
        /// function is charged for all of them here, so that the loop
        /// instruction itself counts nothing.
        inline fn tierFor(l: *Thread, c: *Ctx, pc: u32, count: u64) LoopError!void {
            if (comptime !(jit.enabled and mode == .fast)) return;
            if (count >= jit.loop_weight_min) {
                c.fr.pc = pc;
                if (jit.charge(l, c.cl.proto, count)) return error.EnterJit;
            }
        }
    };
}

pub fn run(l: *Thread, stop: usize, comptime mode: Mode) (Error || YieldError || LoopError)!RunResult(mode) {
    // The dispatch loop inlines many fast paths, which needs more
    // semantic analysis than the default quota allows.
    @setEvalBranchQuota(10_000);
    const hooked = mode == .hooked;
    const fetch = Loop(mode).fetch;
    const condJump = Loop(mode).condJump;
    const tier = Loop(mode).tier;
    const tierLoop = Loop(mode).tierLoop;
    const tierCall = Loop(mode).tierCall;
    const tierReturn = Loop(mode).tierReturn;
    const tierFor = Loop(mode).tierFor;
    // The sampling budget of the tier-up policy. It is a local so that
    // counting an event is a register decrement.
    const sampling = comptime (jit.enabled and mode == .fast);
    var budget: u32 = if (sampling) l.jit_budget else 0;
    defer if (sampling) {
        l.jit_budget = budget;
    };
    var c = load(l);
    var pc: u32 = c.fr.pc;
    var ins: u32 = undefined;
    // A step runs the instruction before the saved pc, which its caller
    // set as the instruction itself would.
    const fi0 = c.fi;
    const pc0 = pc;
    if (mode == .step) {
        ins = c.code[pc - 1];
    }
    // Every case ends by dispatching the next instruction directly, which
    // gives each opcode its own indirect branch.
    sw: switch (if (mode == .step) mode.step else try fetch(l, &c, &pc, &ins, hooked)) {
        .move => {
            c.bp[opc.a(ins)] = c.bp[opc.b(ins)];
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadk => {
            c.bp[opc.a(ins)] = c.k[opc.bx(ins)];
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadi => {
            c.bp[opc.a(ins)] = Value.int(opc.sbx(ins));
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadf => {
            c.bp[opc.a(ins)] = Value.float(@floatFromInt(opc.sbx(ins)));
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadnil => {
            const a: u32 = opc.a(ins);
            var i: u32 = 0;
            while (i <= opc.b(ins)) : (i += 1) c.bp[a + i] = .nil;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadfalse => {
            c.bp[opc.a(ins)] = .false;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .loadtrue => {
            c.bp[opc.a(ins)] = .true;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .getupval => {
            c.bp[opc.a(ins)] = c.cl.upvals()[opc.b(ins)].loc.*;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .setupval => {
            const u = c.cl.upvals()[opc.b(ins)];
            u.loc.* = c.bp[opc.a(ins)];
            gc.barrierBack(l.g, &u.hdr);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .gettabup => {
            const t = c.cl.upvals()[opc.b(ins)].loc;
            try getStrOp(l, &c, pc, &c.ic[pc - 1], opc.a(ins), t, &c.k[opc.c(ins)]);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .settabup => {
            const t = c.cl.upvals()[opc.a(ins)].loc;
            try setStrOp(l, &c, pc, &c.ic[pc - 1], t, &c.k[opc.b(ins)], &c.bp[opc.c(ins)]);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .gettable => {
            const a = opc.a(ins);
            // Operands are read through pointers so the fast paths load
            // only the words they test.
            const t = &c.bp[opc.b(ins)];
            const key = &c.bp[opc.c(ins)];
            if (t.tag == .table and key.tag == .integer) {
                const tab = t.as(Table);
                const i = key.asInt();
                if (i >= 1 and i <= tab.array.len) {
                    const v = tab.array[@intCast(i - 1)];
                    if (!v.isNil() or noIndexMeta(tab)) {
                        c.bp[a] = v;
                        continue :sw try fetch(l, &c, &pc, &ins, hooked);
                    }
                }
            } else if (key.tag == .string) {
                try getStrOp(l, &c, pc, &c.ic[pc - 1], a, t, key);
                continue :sw try fetch(l, &c, &pc, &ins, hooked);
            }
            c.fr.pc = pc;
            const v = try getSlow(l, t.*, key.*, a);
            c.refresh(l);
            c.bp[a] = v;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .getfield => {
            try getStrOp(l, &c, pc, &c.ic[pc - 1], opc.a(ins), &c.bp[opc.b(ins)], &c.k[opc.c(ins)]);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .getindex => {
            const a = opc.a(ins);
            const t = c.bp[opc.b(ins)];
            const i: i64 = opc.c(ins);
            if (t.tag == .table) {
                const tab = t.as(Table);
                const v = table.getInt(tab, i);
                if (!v.isNil() or noIndexMeta(tab)) {
                    c.bp[a] = v;
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            }
            c.fr.pc = pc;
            const v = try metaIndex(l, t, Value.int(i), a);
            c.refresh(l);
            c.bp[a] = v;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .settable => {
            const t = &c.bp[opc.a(ins)];
            const key = &c.bp[opc.b(ins)];
            const v = &c.bp[opc.c(ins)];
            if (t.tag == .table and key.tag == .integer) {
                const tab = t.as(Table);
                const i = key.asInt();
                if (i >= 1 and i <= tab.array.len and !tab.readonly and noNewindexMeta(tab)) {
                    // An integer key never names a metamethod, so the
                    // absence cache stays valid.
                    tab.array[@intCast(i - 1)] = v.*;
                    if (v.tag.isCollectable()) gc.barrierTable(l.g, tab, .nil, v.*);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            } else if (key.tag == .string) {
                try setStrOp(l, &c, pc, &c.ic[pc - 1], t, key, v);
                continue :sw try fetch(l, &c, &pc, &ins, hooked);
            }
            c.fr.pc = pc;
            try setSlow(l, t.*, key.*, v.*);
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .setfield => {
            try setStrOp(l, &c, pc, &c.ic[pc - 1], &c.bp[opc.a(ins)], &c.k[opc.b(ins)], &c.bp[opc.c(ins)]);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .setindex => {
            c.fr.pc = pc;
            try setSlow(l, c.bp[opc.a(ins)], Value.int(opc.b(ins)), c.bp[opc.c(ins)]);
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .newtable => {
            const a = opc.a(ins);
            c.fr.pc = pc;
            if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) {
                try runPendingFinalizers(l);
                c.refresh(l);
            }
            const nb: usize = opc.b(ins);
            const nc: usize = opc.c(ins);
            // Registers above the target are dead here, so a collection
            // triggered by this allocation must not keep their values.
            l.top = c.base + a + 1;
            const t = l.newTable(nb, nc);
            l.top = c.base + c.cl.proto.max_stack;
            c.bp[a] = Value.obj(.table, try t);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .self => {
            const a = opc.a(ins);
            c.bp[a + 1] = c.bp[opc.b(ins)];
            try getStrOp(l, &c, pc, &c.ic[pc - 1], a, &c.bp[a + 1], &c.k[opc.c(ins)]);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        inline .add, .sub, .mul, .div, .mod, .pow, .idiv, .band, .bor, .bxor, .shl, .shr => |o| {
            const op = comptime arithOf(o);
            const a = opc.a(ins);
            // Operands are read through pointers so the fast paths load
            // only the tag and payload words.
            const x = &c.bp[opc.b(ins)];
            const y = &c.bp[opc.c(ins)];
            if (x.tag == .integer and y.tag == .integer) {
                if (op == .div) {
                    c.bp[a] = Value.float(@as(f64, @floatFromInt(x.asInt())) / @as(f64, @floatFromInt(y.asInt())));
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
                if (intArith(op, x.asInt(), y.asInt())) |r| {
                    c.bp[a] = Value.int(r);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            } else if (x.tag == .float and y.tag == .float) {
                if (floatArith(op, x.asFloat(), y.asFloat())) |r| {
                    c.bp[a] = Value.float(r);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            }
            c.fr.pc = pc;
            const r = try metaArith(l, op, x.*, y.*, a);
            c.refresh(l);
            c.bp[a] = r;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        inline .addk, .subk, .mulk, .divk, .modk, .powk, .idivk => |o| {
            const op = comptime arithOf(o);
            const a = opc.a(ins);
            const x = &c.bp[opc.b(ins)];
            const y = &c.k[opc.c(ins)];
            if (x.tag == .integer and y.tag == .integer) {
                if (op == .div) {
                    c.bp[a] = Value.float(@as(f64, @floatFromInt(x.asInt())) / @as(f64, @floatFromInt(y.asInt())));
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
                if (intArith(op, x.asInt(), y.asInt())) |r| {
                    c.bp[a] = Value.int(r);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            } else if (x.tag == .float and y.tag == .float) {
                if (floatArith(op, x.asFloat(), y.asFloat())) |r| {
                    c.bp[a] = Value.float(r);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
            }
            c.fr.pc = pc;
            const r = try metaArith(l, op, x.*, y.*, a);
            c.refresh(l);
            c.bp[a] = r;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .addi => {
            const a = opc.a(ins);
            const x = c.bp[opc.b(ins)];
            const imm = opc.sc(ins);
            if (x.tag == .integer) {
                c.bp[a] = Value.int(x.asInt() +% imm);
            } else if (x.tag == .float) {
                c.bp[a] = Value.float(x.asFloat() + @as(f64, @floatFromInt(imm)));
            } else {
                @branchHint(.cold);
                c.fr.pc = pc;
                const r = try metaArith(l, .add, x, Value.int(imm), a);
                c.refresh(l);
                c.bp[a] = r;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .unm => {
            const a = opc.a(ins);
            const x = c.bp[opc.b(ins)];
            switch (x.tag) {
                .integer => c.bp[a] = Value.int(0 -% x.asInt()),
                .float => c.bp[a] = Value.float(-x.asFloat()),
                else => {
                    c.fr.pc = pc;
                    const r = try metaArith(l, .unm, x, x, a);
                    c.refresh(l);
                    c.bp[a] = r;
                },
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .bnot => {
            const a = opc.a(ins);
            const x = c.bp[opc.b(ins)];
            if (x.tag == .integer) {
                c.bp[a] = Value.int(~x.asInt());
            } else {
                c.fr.pc = pc;
                const r = try metaArith(l, .bnot, x, x, a);
                c.refresh(l);
                c.bp[a] = r;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .not => {
            c.bp[opc.a(ins)] = Value.boolean(!c.bp[opc.b(ins)].truthy());
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .len => {
            const a = opc.a(ins);
            const x = c.bp[opc.b(ins)];
            if (x.tag == .table and x.as(Table).metatable == null) {
                c.bp[a] = Value.int(table.length(x.as(Table)));
            } else if (x.tag == .string) {
                c.bp[a] = Value.int(x.as(String).chars);
            } else {
                c.fr.pc = pc;
                const r = try metaLength(l, x, a);
                c.refresh(l);
                c.bp[a] = r;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .concat => {
            const a = opc.a(ins);
            c.fr.pc = pc;
            const r = try ops.concat(l, c.base + a, opc.b(ins));
            c.refresh(l);
            c.bp[a] = r;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .interp => {
            const a = opc.a(ins);
            c.fr.pc = pc;
            const r = try interpolate(l, c.base + a, opc.b(ins));
            c.refresh(l);
            c.bp[a] = r;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .jmp => {
            const off = opc.sj(ins);
            pc = @intCast(@as(i64, pc) + off);
            // Loops are safe points for pending finalizers.
            if (off < 0) {
                if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) {
                    c.fr.pc = pc;
                    try runPendingFinalizers(l);
                    c.refresh(l);
                }
                try tierLoop(l, &c, &pc, &budget);
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .eq => {
            const x = &c.bp[opc.a(ins)];
            const y = &c.bp[opc.b(ins)];
            const k = opc.c(ins) != 0;
            // Nil, booleans, and integers compare by tag and payload.
            const r = if (x.tag == y.tag and @backingInt(x.tag) <= @backingInt(value.Tag.integer))
                (x.tag != .integer or x.payload == y.payload)
            else if (x.tag == .float and y.tag == .float)
                x.asFloat() == y.asFloat()
            else blk: {
                c.fr.pc = pc;
                const r = try metaCompare(l, .eq, x.*, y.*, k);
                c.refresh(l);
                break :blk r;
            };
            try condJump(l, &c, &pc, r != k, hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        inline .lt, .le => |o| {
            const x = &c.bp[opc.a(ins)];
            const y = &c.bp[opc.b(ins)];
            const k = opc.c(ins) != 0;
            const r = if (x.tag == .integer and y.tag == .integer)
                (if (o == .lt) x.asInt() < y.asInt() else x.asInt() <= y.asInt())
            else if (x.tag == .float and y.tag == .float)
                (if (o == .lt) x.asFloat() < y.asFloat() else x.asFloat() <= y.asFloat())
            else blk: {
                c.fr.pc = pc;
                const r = try metaCompare(l, if (o == .lt) .lt else .le, x.*, y.*, k);
                c.refresh(l);
                break :blk r;
            };
            try condJump(l, &c, &pc, r != k, hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        inline .lti, .lei, .gti, .gei => |o| {
            const x = &c.bp[opc.a(ins)];
            const imm = opc.sb(ins);
            const k = opc.c(ins) != 0;
            const r = if (x.tag == .integer) switch (o) {
                .lti => x.asInt() < imm,
                .lei => x.asInt() <= imm,
                .gti => x.asInt() > imm,
                .gei => x.asInt() >= imm,
                else => unreachable,
            } else if (x.tag == .float) switch (o) {
                .lti => x.asFloat() < @as(f64, @floatFromInt(imm)),
                .lei => x.asFloat() <= @as(f64, @floatFromInt(imm)),
                .gti => x.asFloat() > @as(f64, @floatFromInt(imm)),
                .gei => x.asFloat() >= @as(f64, @floatFromInt(imm)),
                else => unreachable,
            } else blk: {
                c.fr.pc = pc;
                const iv = Value.int(imm);
                const r = try switch (o) {
                    .lti => metaCompare(l, .lt, x.*, iv, k),
                    .lei => metaCompare(l, .le, x.*, iv, k),
                    .gti => metaCompare(l, .lt, iv, x.*, k),
                    .gei => metaCompare(l, .le, iv, x.*, k),
                    else => unreachable,
                };
                c.refresh(l);
                break :blk r;
            };
            try condJump(l, &c, &pc, r != k, hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .eqk => {
            const x = &c.bp[opc.a(ins)];
            const y = &c.k[opc.b(ins)];
            const r = if (x.tag == .integer and y.tag == .integer)
                x.payload == y.payload
            else if (x.tag == .string and y.tag == .string and x.payload == y.payload)
                true
            else
                ops.rawEqual(l, x.*, y.*);
            try condJump(l, &c, &pc, r != (opc.c(ins) != 0), hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .test_ => {
            try condJump(l, &c, &pc, c.bp[opc.a(ins)].truthy() != (opc.c(ins) != 0), hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .testset => {
            const v = c.bp[opc.b(ins)];
            if (v.truthy() != (opc.c(ins) != 0)) {
                pc += 1;
            } else {
                c.bp[opc.a(ins)] = v;
                try condJump(l, &c, &pc, false, hooked);
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .testnil => {
            try condJump(l, &c, &pc, c.bp[opc.a(ins)].isNil() != (opc.c(ins) != 0), hooked);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .call => {
            const nb = opc.b(ins);
            const want: i32 = @as(i32, opc.c(ins)) - 1;
            const func = c.base + opc.a(ins);
            c.fr.pc = pc;
            if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) {
                try runPendingFinalizers(l);
                c.refresh(l);
            }
            const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
            if (nb != 0) l.top = func + nb;
            const callee = &l.stack[func];
            if (callee.tag == .closure and callee.as(Closure).proto.plain_call) {
                try enterLus(l, callee.as(Closure), func, nargs, want);
                c = load(l);
                pc = 0;
                if (hooked and l.hook_mask & Thread.hook_call != 0) {
                    try callHook(l, "call", null);
                    c.refresh(l);
                }
                try tierLoop(l, &c, &pc, &budget);
                continue :sw try fetch(l, &c, &pc, &ins, hooked);
            }
            const kind: CallKind = if (callee.tag == .native) blk: {
                try callNative(l, callee.as(state.Native), func, nargs, want);
                break :blk .done;
            } else try precall(l, func, nargs, want);
            if (kind == .lus) {
                c = load(l);
                pc = 0;
                if (hooked and l.hook_mask & Thread.hook_call != 0) {
                    try callHook(l, "call", null);
                    c.refresh(l);
                }
                try tierCall(l, &c, &pc, &budget);
            } else {
                c.refresh(l);
                if (want >= 0) l.top = c.base + c.cl.proto.max_stack;
                // A native may have set or cleared the hooks.
                if ((l.hook_mask != 0) != hooked) return error.SwitchLoop;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .tailcall => {
            const nb = opc.b(ins);
            const func = c.base + opc.a(ins);
            const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
            const callee = l.stack[func];
            c.fr.pc = pc;
            if (callee.tag != .closure) {
                // Natives and __call targets run as a plain call
                // followed by a return of all results.
                if (nb != 0) l.top = func + nb;
                const kind: CallKind = if (callee.tag == .native) blk: {
                    try callNative(l, callee.as(state.Native), func, nargs, -1);
                    break :blk .done;
                } else try precall(l, func, nargs, -1);
                if (kind == .lus) {
                    c = load(l);
                    pc = 0;
                    try tierCall(l, &c, &pc, &budget);
                    continue :sw try fetch(l, &c, &pc, &ins, hooked);
                }
                c.refresh(l);
                if (try doReturn(l, &c, &pc, func, l.top - func, stop)) return finished(mode);
                try tierReturn(l, &c, pc);
                continue :sw try fetch(l, &c, &pc, &ins, hooked);
            }
            // Reuse the current frame: close upvalues, move the callee
            // and arguments down to the frame's return slot.
            closeUpvals(l, c.base);
            const fr = l.frames.pop().?;
            const dst = fr.ret;
            var i: u32 = 0;
            while (i <= nargs) : (i += 1) l.stack[dst + i] = l.stack[func + i];
            l.top = dst + 1 + nargs;
            const tcl = callee.as(Closure);
            if (!tcl.proto.is_vararg) {
                try enterLus(l, tcl, dst, nargs, fr.want);
            } else {
                _ = try precall(l, dst, nargs, fr.want);
            }
            const nf = l.frame();
            nf.boundary = fr.boundary;
            nf.tail = true;
            c = load(l);
            pc = 0;
            if (hooked and l.hook_mask & Thread.hook_call != 0) {
                try callHook(l, "tail call", null);
                c.refresh(l);
            }
            try tierCall(l, &c, &pc, &budget);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .ret => {
            const nb = opc.b(ins);
            const first = c.base + opc.a(ins);
            const n: u32 = if (nb != 0) nb - 1 else l.top - first;
            c.fr.pc = pc;
            if (try doReturn(l, &c, &pc, first, n, stop)) return finished(mode);
            try tierReturn(l, &c, pc);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        inline .ret0, .ret1 => |o| {
            const n: u32 = if (o == .ret1) 1 else 0;
            const first = c.base + opc.a(ins);
            if (!hooked and leanReturn(l, c, stop)) {
                // Return to a Lus caller with nothing to close.
                const fr = c.fr;
                const dst = fr.ret;
                const want = fr.want;
                if (n == 1) l.stack[dst] = l.stack[first];
                if (want < 0) {
                    l.top = dst + n;
                } else {
                    var i: u32 = n;
                    while (i < @as(u32, @intCast(want))) : (i += 1) l.stack[dst + i] = .nil;
                }
                l.frames.items.len -= 1;
                c = load(l);
                pc = c.fr.pc;
                if (want >= 0) l.top = c.base + c.cl.proto.max_stack;
                continue :sw try fetch(l, &c, &pc, &ins, hooked);
            }
            c.fr.pc = pc;
            if (try doReturn(l, &c, &pc, first, n, stop)) return finished(mode);
            try tierReturn(l, &c, pc);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .forprep => {
            c.fr.pc = pc;
            if (try forPrep(l, c.base + opc.a(ins))) {
                pc += opc.bx(ins) + 1;
            } else {
                const r = c.bp + opc.a(ins);
                if (r[0].tag == .integer) try tierFor(l, &c, pc, @bitCast(r[1].asInt()));
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .forloop => {
            const r = c.bp + opc.a(ins);
            if (r[0].tag == .integer) {
                // R[r+1] holds the remaining iteration count.
                const count: u64 = @bitCast(r[1].asInt());
                if (count > 0) {
                    const idx = r[0].asInt() +% r[2].asInt();
                    r[1] = Value.int(@bitCast(count - 1));
                    r[0] = Value.int(idx);
                    r[3] = Value.int(idx);
                    pc -= opc.bx(ins);
                }
            } else if (r[0].tag == .float) {
                const step = r[2].asFloat();
                const limit = r[1].asFloat();
                const ni = r[0].asFloat() + step;
                if (if (step > 0) ni <= limit else limit <= ni) {
                    r[0] = Value.float(ni);
                    r[3] = Value.float(ni);
                    pc -= opc.bx(ins);
                    try tier(l, &c, pc);
                }
            } else {
                c.fr.pc = pc;
                const more = try exactForStep(l, r);
                c.refresh(l);
                if (more) {
                    pc -= opc.bx(ins);
                    try tier(l, &c, pc);
                }
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .tforprep => {
            const r = c.base + opc.a(ins);
            if (!l.stack[r + 3].isNil()) {
                c.fr.pc = pc;
                try markTbc(l, r + 3);
                c.refresh(l);
            }
            pc += opc.bx(ins);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .tforcall => {
            const r = c.base + opc.a(ins);
            c.fr.pc = pc;
            // R[r+4..] = R[r](R[r+1], R[r+2])
            l.stack[r + 4] = l.stack[r];
            l.stack[r + 5] = l.stack[r + 1];
            l.stack[r + 6] = l.stack[r + 2];
            l.top = r + 4 + 3;
            const want: i32 = opc.c(ins);
            const iter = l.stack[r + 4];
            const kind: CallKind = if (iter.tag == .native) blk: {
                try callNative(l, iter.as(state.Native), r + 4, 2, want);
                break :blk .done;
            } else try precall(l, r + 4, 2, want);
            if (kind == .lus) {
                c = load(l);
                pc = 0;
                try tierCall(l, &c, &pc, &budget);
            } else {
                c.refresh(l);
                l.top = c.base + c.cl.proto.max_stack;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .tforloop => {
            const r = c.bp + opc.a(ins);
            if (!r[4].isNil()) {
                r[2] = r[4];
                pc -= opc.bx(ins);
                try tierLoop(l, &c, &pc, &budget);
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .rangeprep => {
            // R[A] holds the iterator expression results. When R[A] is
            // the builtin range, convert to an integer numeric loop:
            // R[A..A+2] = start, count, step and skip to the numeric
            // loop body following this instruction. Otherwise continue
            // with the generic protocol at the offset in C.
            const r = c.base + opc.a(ins);
            if (isBuiltinRange(l, l.stack[r])) {
                c.fr.pc = pc;
                if (try rangePrep(l, r)) {
                    pc += opc.bx(ins) + 1;
                } else {
                    const lr = c.bp + opc.a(ins);
                    if (lr[0].tag == .integer) try tierFor(l, &c, pc, @bitCast(lr[1].asInt()));
                }
            } else {
                pc += opc.c(ins);
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .setlist => {
            const a = opc.a(ins);
            const t = c.bp[a].as(Table);
            var n: u32 = opc.b(ins);
            const first = c.base + a + 1;
            if (n == 0) n = l.top - first;
            const start = opc.ax(c.code[pc]);
            pc += 1;
            c.fr.pc = pc;
            const last = start + n;
            if (last > t.array.len) table.resize(l.g.gpa, t, last, t.hash_used) catch return l.raiseMem();
            var i: u32 = 0;
            while (i < n) : (i += 1) t.array[start + i] = l.stack[first + i];
            gc.barrierBack(l.g, &t.hdr);
            l.top = c.base + c.cl.proto.max_stack;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .closure => {
            const a = opc.a(ins);
            const p = c.cl.proto.protos[opc.bx(ins)];
            c.fr.pc = pc;
            // Collect only once the closure is rooted in its register,
            // with the registers above it treated as dead.
            const ncl = try makeClosure(l, p, c.cl, c.base);
            c.refresh(l);
            c.bp[a] = Value.obj(.closure, ncl);
            l.top = c.base + a + 1;
            gc.maybeCollect(l.g);
            l.top = c.base + c.cl.proto.max_stack;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .vararg => {
            const want: i32 = @as(i32, opc.c(ins)) - 1;
            const nv = c.fr.nvarargs;
            const src = c.fr.func - nv;
            const dst = c.base + opc.a(ins);
            if (want < 0) {
                c.fr.pc = pc;
                try l.ensure(nv + 8);
                c.refresh(l);
                var i: u32 = 0;
                while (i < nv) : (i += 1) l.stack[dst + i] = l.stack[src + i];
                l.top = dst + nv;
            } else {
                var i: u32 = 0;
                while (i < @as(u32, @intCast(want))) : (i += 1) l.stack[dst + i] = if (i < nv) l.stack[src + i] else .nil;
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .varargprep => continue :sw try fetch(l, &c, &pc, &ins, hooked),
        .varargtab => {
            const nv = c.fr.nvarargs;
            const src = c.fr.func - nv;
            c.fr.pc = pc;
            const t = try l.newTable(nv, 1);
            var i: u32 = 0;
            while (i < nv) : (i += 1) t.array[i] = l.stack[src + i];
            c.refresh(l);
            c.bp[opc.a(ins)] = Value.obj(.table, t);
            try ops.rawSet(l, t, try l.newStringValue("n"), Value.int(nv));
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .close => {
            const level = c.base + opc.a(ins);
            closeUpvals(l, level);
            if (l.tbc.items.len > 0 and l.tbc.items[l.tbc.items.len - 1] >= level) {
                c.fr.pc = pc;
                l.meta_finish = .{ .redo = false };
                defer l.meta_finish = null;
                try closeTbc(l, level, null);
                c.refresh(l);
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .tbc => {
            c.fr.pc = pc;
            try markTbc(l, c.base + opc.a(ins));
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },

        .slice => {
            const r = c.base + opc.b(ins);
            c.fr.pc = pc;
            const v = try @import("ext.zig").slice(l, l.stack[r], l.stack[r + 1], l.stack[r + 2]);
            c.refresh(l);
            c.bp[opc.a(ins)] = v;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .newenum => {
            c.fr.pc = pc;
            const v = try @import("ext.zig").newEnum(l, c.k[opc.bx(ins)]);
            c.refresh(l);
            c.bp[opc.a(ins)] = v;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .query => {
            const a = opc.a(ins);
            c.fr.pc = pc;
            const v = try @import("ext.zig").newQuery(l, c.k[opc.bx(ins)], c.base + a + 1);
            c.refresh(l);
            c.bp[a] = v;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .globaldef => {
            const env = c.cl.upvals()[opc.a(ins)].loc.*;
            c.fr.pc = pc;
            try globalDefine(l, env, c.k[opc.b(ins)], c.bp[opc.c(ins)]);
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .globaldefr => {
            c.fr.pc = pc;
            try globalDefine(l, c.bp[opc.a(ins)], c.k[opc.b(ins)], c.bp[opc.c(ins)]);
            c.refresh(l);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .catchcheck => {
            const h = c.bp[opc.a(ins)];
            if (h.tag != .closure and h.tag != .native) {
                c.fr.pc = pc;
                return l.raiseFmt("attempt to use a {s} value as a catch handler", .{l.typeNameOf(h)});
            }
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .settop => {
            l.top = c.base + opc.a(ins);
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .moverange => {
            const src = c.base + opc.b(ins);
            const dst = c.base + opc.a(ins);
            const n = l.top - src;
            var i: u32 = 0;
            while (i < n) : (i += 1) l.stack[dst + i] = l.stack[src + i];
            l.top = dst + n;
            continue :sw try fetch(l, &c, &pc, &ins, hooked);
        },
        .extraarg => {
            // A step ends here and reports where execution continues.
            if (mode == .step) {
                if (c.fi == fi0 and pc == pc0) return Step.next;
                c.fr.pc = pc;
                return if (c.fi == fi0 and pc == pc0 + 1) Step.skip else Step.dispatch;
            } else unreachable;
        },
    }
}

/// Appends a frame, growing the list only when it is full.
inline fn pushFrame(l: *Thread, f: Frame) Error!void {
    if (l.frames.items.len == l.frames.capacity) try growFrames(l);
    l.frames.appendAssumeCapacity(f);
}

noinline fn growFrames(l: *Thread) Error!void {
    @branchHint(.cold);
    l.frames.ensureUnusedCapacity(l.g.gpa, 1) catch return l.raiseMem();
}

/// Runs a native function called from the interpreter with its `nargs`
/// arguments above `func`, leaving its results at `func` adjusted to
/// `want`.
inline fn callNative(l: *Thread, nat: *state.Native, func: u32, nargs: u32, want: i32) (Error || YieldError)!void {
    if (@as(usize, func) + 1 + nargs + 32 > l.stack.len) try l.ensure(32);
    try pushFrame(l, .{ .func = func, .base = func + 1, .native = nat, .want = want, .ret = func });
    l.top = func + 1 + nargs;
    const nres = nat.func(l) catch |e| {
        // Yields keep the native frame so resume can finish it.
        if (e == error.LusError) {
            if (l.status == .suspended and l.yielding) return error.Yield;
        }
        return e;
    };
    try poscall(l, nres);
}

/// Pushes a frame for a call to a Lus function with fixed parameters. The
/// callee and its `nargs` arguments are at `func`.
inline fn enterLus(l: *Thread, cl: *Closure, func: u32, nargs: u32, want: i32) Error!void {
    const p = cl.proto;
    const base = func + 1;
    const top = base + p.max_stack;
    if (@as(usize, top) + nargs + 8 > l.stack.len) try l.ensure(@as(usize, p.max_stack) + nargs + 8);
    // Missing parameters and the registers above the parameters start nil.
    var r = base + @min(nargs, @as(u32, p.num_params));
    while (r < top) : (r += 1) l.stack[r] = .nil;
    try pushFrame(l, .{ .func = func, .base = base, .closure = cl, .want = want, .ret = func });
    l.top = top;
}

/// True when the running frame can return without hooks, closing, a
/// finish action, or leaving the loop: its caller is a Lus frame above
/// `stop` and no open upvalue or to-be-closed variable lives in it.
inline fn leanReturn(l: *Thread, c: Ctx, stop: usize) bool {
    const fr = c.fr;
    if (fr.finish != .none or fr.boundary or l.hook_mask != 0) return false;
    if (c.fi <= stop or l.frames.items[c.fi - 1].closure == null) return false;
    if (l.open_upvals) |u| if (u.level >= c.base) return false;
    if (l.tbc.items.len > 0 and l.tbc.items[l.tbc.items.len - 1] >= c.base) return false;
    return true;
}

/// Returns `n` values starting at `first` from the current frame. Returns
/// true when the interpreter loop must exit. The caller has saved the pc.
inline fn doReturn(l: *Thread, c: *Ctx, pc: *u32, first: u32, n: u32, stop: usize) Error!bool {
    if (l.hook_mask & Thread.hook_ret != 0) {
        if (l.top < first + n) l.top = first + n;
        try callHook(l, "return", null);
    }
    const base = c.base;
    if (l.open_upvals) |u| {
        if (u.level >= base) closeUpvals(l, base);
    }
    if (l.tbc.items.len > 0 and l.tbc.items[l.tbc.items.len - 1] >= base) {
        // Protect the results while __close runs.
        l.top = first + n;
        l.meta_finish = .{ .redo = true };
        defer l.meta_finish = null;
        try closeTbc(l, base, null);
    }
    // Finish the frame: move the results to its return slot, adjusted to
    // the wanted count. __close handlers may have reallocated the frames.
    const fr = l.frames.pop().?;
    const dst = fr.ret;
    if (fr.want < 0) {
        var i: u32 = 0;
        while (i < n) : (i += 1) l.stack[dst + i] = l.stack[first + i];
        l.top = dst + n;
    } else {
        const w: u32 = @intCast(fr.want);
        var i: u32 = 0;
        while (i < w) : (i += 1) l.stack[dst + i] = if (i < n) l.stack[first + i] else .nil;
        l.top = dst + w;
    }
    if (fr.boundary or l.frames.items.len <= stop) return true;
    if (l.frame().closure == null) return true;
    c.* = load(l);
    pc.* = c.fr.pc;
    if (l.hook_mask != 0) {
        // Returning into the caller is not a new line.
        l.hook_oldfi = c.fi;
        l.hook_oldpc = if (pc.* > 0) pc.* - 1 else 0;
    }
    switch (fr.finish) {
        .none, .discard => {},
        .store => |r| c.bp[r] = l.stack[dst],
        .cond => |k| if (l.stack[dst].truthy() != k) {
            pc.* += 1;
            c.fr.pc = pc.*;
        },
        .redo => |keep_top| {
            pc.* -= 1;
            c.fr.pc = pc.*;
            if (keep_top) l.top = dst;
        },
    }
    // Fixed result counts restore the caller's register window top.
    if (fr.want >= 0) l.top = c.base + c.cl.proto.max_stack;
    return false;
}

fn markTbc(l: *Thread, level: u32) Error!void {
    const v = l.stack[level];
    if (v.isNil() or v.tag == .false) return;
    if (l.metamethod(v, .close).isNil()) {
        if (l.frames.items.len > 0) if (l.frame().closure) |cl| {
            const pc = if (l.frame().pc == 0) 0 else l.frame().pc - 1;
            if (@import("debug.zig").localName(cl.proto, level - l.frame().base, pc + 1)) |name| {
                return l.raiseFmt("variable '{s}' got a non-closable value", .{name});
            }
        };
        return l.raiseFmt("variable got a non-closable value", .{});
    }
    l.tbc.append(l.g.gpa, level) catch return l.raiseMem();
}

pub fn makeClosure(l: *Thread, p: *Proto, parent: *Closure, base: u32) Error!*Closure {
    const n = p.upvals.len;
    const cl = gc.allocUninit(l.g, Closure, .closure, Closure.allocSize(n)) catch return l.raiseMem();
    cl.proto = p;
    cl.nupvals = @intCast(n);
    const ups = cl.upvals();
    for (p.upvals, 0..) |d, i| {
        if (d.in_stack) {
            ups[i] = if (d.by_value) try newClosedUpval(l, l.stack[base + d.index]) else try findUpval(l, base + d.index);
        } else {
            ups[i] = parent.upvals()[d.index];
        }
    }
    return cl;
}

// ---------------------------------------------------------------------
// Instruction helpers

fn arithOf(comptime o: Op) ops.ArithOp {
    return switch (o) {
        .add, .addk => .add,
        .sub, .subk => .sub,
        .mul, .mulk => .mul,
        .div, .divk => .div,
        .mod, .modk => .mod,
        .pow, .powk => .pow,
        .idiv, .idivk => .idiv,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        else => unreachable,
    };
}

/// Integer arithmetic with the exact results of `ops.arithRaw`. Returns
/// null for division by zero and for the operators that need the slow
/// path, so that it raises the error.
inline fn intArith(comptime op: ops.ArithOp, a: i64, b: i64) ?i64 {
    return switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .band => a & b,
        .bor => a | b,
        .bxor => a ^ b,
        .shl => ops.shiftLeft(a, b),
        .shr => ops.shiftLeft(a, 0 -% b),
        .mod => if (b == 0) null else ops.imod(a, b),
        .idiv => if (b == 0) null else ops.idiv(a, b),
        else => null,
    };
}

/// Float arithmetic with the exact results of `ops.arithRaw`.
inline fn floatArith(comptime op: ops.ArithOp, a: f64, b: f64) ?f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .mod => numeric.fmod(a, b),
        .idiv => @floor(a / b),
        else => null,
    };
}

/// True when indexing a missing key of `t` yields nil without a
/// metamethod: no metatable, or one known to lack `__index`.
inline fn noIndexMeta(t: *Table) bool {
    const mt = t.metatable orelse return true;
    return mt.tm_absent & (@as(u16, 1) << @backingInt(state.TM.index)) != 0;
}

/// True when a store into `t` is a raw store: no metatable, or one known
/// to lack `__newindex`.
inline fn noNewindexMeta(t: *Table) bool {
    const mt = t.metatable orelse return true;
    return mt.tm_absent & (@as(u16, 1) << @backingInt(state.TM.newindex)) != 0;
}

/// Looks up the string key `s` in `tab`, trying the node that `slot`
/// predicts before probing, and records where the key was found.
inline fn lookupIc(tab: *Table, s: *String, slot: *u16) Value {
    const i: usize = slot.*;
    if (i < tab.hash.len) {
        const n = &tab.hash[i];
        if (n.key.payload == @intFromPtr(s) and n.key.tag == .string) return n.val;
    }
    const idx = table.findStr(tab, s) orelse return .nil;
    if (idx < object.IcEntry.none) slot.* = @intCast(idx);
    return tab.hash[idx].val;
}

/// R[a] = t[key] for a string key.
/// The operands are pointers into registers, constants, or upvalues, read
/// only before anything that may reallocate the stack.
inline fn getStrOp(l: *Thread, c: *Ctx, pc: u32, ic: *object.IcEntry, a: u8, t: *const Value, key: *const Value) Error!void {
    if (t.tag == .table) {
        const tab = t.as(Table);
        const v = lookupIc(tab, key.as(String), &ic.own);
        if (!v.isNil() or noIndexMeta(tab)) {
            c.bp[a] = v;
            return;
        }
        if (indexChain(l, tab, key.as(String), ic, &c.bp[a])) return;
    }
    c.fr.pc = pc;
    const v = try metaIndex(l, t.*, key.*, a);
    c.refresh(l);
    c.bp[a] = v;
}

/// t[key] = v for a string key. Stores into an existing key of a plain
/// table, and new keys that fit without a rehash, happen inline.
/// Everything else goes through `setSlow`.
inline fn setStrOp(l: *Thread, c: *Ctx, pc: u32, ic: *object.IcEntry, t: *const Value, key: *const Value, v: *const Value) Error!void {
    if (t.tag == .table) {
        const tab = t.as(Table);
        if (!tab.readonly and noNewindexMeta(tab)) {
            const i: usize = ic.own;
            if (i < tab.hash.len and tab.hash[i].key.payload == key.payload and tab.hash[i].key.tag == .string) {
                tab.hash[i].val = v.*;
                if (v.tag.isCollectable()) gc.barrierTable(l.g, tab, .nil, v.*);
            } else if (table.storeStr(tab, key.*, v.*)) |idx| {
                if (idx < object.IcEntry.none) ic.own = @intCast(idx);
                // The store may have added the key itself.
                gc.barrierTable(l.g, tab, key.*, v.*);
            } else {
                c.fr.pc = pc;
                try setSlow(l, t.*, key.*, v.*);
                c.refresh(l);
                return;
            }
            tab.tm_absent = 0;
            return;
        }
    }
    c.fr.pc = pc;
    try setSlow(l, t.*, key.*, v.*);
    c.refresh(l);
}

/// Follows `__index` tables from `tab`, whose own lookup missed and whose
/// metatable may have `__index`. Stores the result and returns true when
/// the chain ends in a table lookup. Returns false when a function
/// metamethod or a non-table must run through the generic path. The first
/// step of the chain uses the slot predictions in `ic`.
fn indexChain(l: *Thread, start: *Table, key: *String, ic: *object.IcEntry, out: *Value) bool {
    var tab = start;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        const mt = tab.metatable orelse {
            out.* = .nil;
            return true;
        };
        const h = if (depth == 0) indexMetaIc(l, mt, &ic.index) else state.tmLookup(l.g, mt, .index);
        if (h.tag != .table) {
            if (!h.isNil()) return false;
            out.* = .nil;
            return true;
        }
        tab = h.as(Table);
        const v = if (depth == 0) lookupIc(tab, key, &ic.holder) else table.getStr(tab, key);
        if (!v.isNil() or noIndexMeta(tab)) {
            out.* = v;
            return true;
        }
    }
    return false;
}

/// `state.tmLookup` for `__index`, with a slot prediction.
inline fn indexMetaIc(l: *Thread, mt: *Table, slot: *u16) Value {
    const bit: u16 = @as(u16, 1) << @backingInt(state.TM.index);
    if (mt.tm_absent & bit != 0) return .nil;
    const v = lookupIc(mt, l.g.tm_names[@backingInt(state.TM.index)].?, slot);
    if (v.isNil()) mt.tm_absent |= bit;
    return v;
}

fn getSlow(l: *Thread, t: Value, key: Value, dest: u8) Error!Value {
    if (t.tag == .table) {
        const tab = t.as(Table);
        const v = table.get(tab, try ops.normKey(l, key));
        if (!v.isNil() or tab.metatable == null) return v;
    }
    return metaIndex(l, t, key, dest);
}

fn setSlow(l: *Thread, t: Value, key: Value, v: Value) Error!void {
    if (t.tag == .table) {
        const tab = t.as(Table);
        if (tab.metatable == null) return ops.rawSet(l, tab, key, v);
    }
    return metaSet(l, t, key, v);
}

/// Slow-path operations that may run a metamethod as an interpreter
/// frame. `fin` says what to do with the metamethod's result.
fn metaIndex(l: *Thread, t: Value, key: Value, dest: u8) Error!Value {
    l.meta_finish = .{ .store = dest };
    defer l.meta_finish = null;
    return ops.index(l, t, key);
}

fn metaSet(l: *Thread, t: Value, key: Value, v: Value) Error!void {
    l.meta_finish = .discard;
    defer l.meta_finish = null;
    return ops.setIndex(l, t, key, v);
}

fn metaArith(l: *Thread, op: ops.ArithOp, x: Value, y: Value, dest: u8) Error!Value {
    @branchHint(.cold);
    l.meta_finish = .{ .store = dest };
    defer l.meta_finish = null;
    return ops.arith(l, op, x, y);
}

fn metaLength(l: *Thread, v: Value, dest: u8) Error!Value {
    l.meta_finish = .{ .store = dest };
    defer l.meta_finish = null;
    return ops.length(l, v);
}

fn metaCompare(l: *Thread, comptime which: enum { eq, lt, le }, x: Value, y: Value, k: bool) Error!bool {
    l.meta_finish = .{ .cond = k };
    defer l.meta_finish = null;
    return switch (which) {
        .eq => ops.equal(l, x, y),
        .lt => ops.lessThan(l, x, y),
        .le => ops.lessEqual(l, x, y),
    };
}

fn interpolate(l: *Thread, first: u32, n: u32) Error!Value {
    // Short results are built on the stack, and the parts that are
    // already strings or numbers size the buffer up front.
    var stack: [ops.concat_stack]u8 = undefined;
    var fb = std.heap.BufferFirstAllocator.init(&stack, l.g.gpa);
    const gpa = fb.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var room: usize = 0;
    for (l.stack[first..][0..n]) |v| room += ops.concatRoom(v);
    buf.ensureTotalCapacityPrecise(gpa, room) catch return l.raiseMem();
    var ascii = true;
    var chars: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var v = l.stack[first + i];
        if (v.tag == .vector) return l.raiseFmt("cannot interpolate a vector (decode it with vector.tostring)", .{});
        if (v.tag != .string and !v.isNumber()) v = Value.obj(.string, try ops.toString(l, v));
        try ops.appendForConcat(l, gpa, &buf, v, &ascii, &chars);
    }
    const s = state.newStringKnown(l.g, buf.items, ascii, chars) catch return l.raiseMem();
    return Value.obj(.string, s);
}

/// Prepares a numeric for loop at registers r..r+3 (init, limit, step,
/// control). Returns true when the loop runs zero times.
fn isExact(v: Value) bool {
    return v.tag == .bigint or v.tag == .decimal;
}

/// Whether `v` has passed `limit` in the direction of the step.
fn exactPast(l: *Thread, v: Value, limit: Value, ascending: bool) Error!bool {
    const o = @import("numeric.zig").compare(l.g.gpa, v, limit) orelse return l.raiseFmt("'for' limit is not comparable", .{});
    return if (ascending) o == .gt else o == .lt;
}

/// One step of an exact numeric loop. Returns true when the loop goes on.
noinline fn exactForStep(l: *Thread, r: [*]Value) Error!bool {
    const next = try ops.arith(l, .add, r[0], r[2]);
    const ascending = (@import("numeric.zig").compare(l.g.gpa, r[2], Value.int(0)) orelse .gt) == .gt;
    if (try exactPast(l, next, r[1], ascending)) return false;
    r[0] = next;
    r[3] = next;
    return true;
}

fn forPrep(l: *Thread, r: u32) Error!bool {
    const init_v = try forValue(l, l.stack[r], "initial");
    const limit_v = try forValue(l, l.stack[r + 1], "limit");
    const step_v = try forValue(l, l.stack[r + 2], "step");
    if (isExact(init_v) or isExact(limit_v) or isExact(step_v)) {
        // Bigint and decimal loops step with exact arithmetic.
        const zero = Value.int(0);
        const step_order = @import("numeric.zig").compare(l.g.gpa, step_v, zero) orelse return l.raiseFmt("'for' step is not a number", .{});
        if (step_order == .eq) return l.raiseFmt("'for' step is zero", .{});
        // The control value takes the exact type, so every step stays exact
        // and the loop instruction recognizes the exact mode by its tag.
        var start = init_v;
        if (!isExact(start)) {
            const dec = init_v.tag == .decimal or limit_v.tag == .decimal or step_v.tag == .decimal;
            const zero_exact = if (dec)
                Value.obj(.decimal, numeric.parseDecimalLiteral(l.g, "0") catch return l.raiseMem())
            else
                Value.obj(.bigint, numeric.parseBigLiteral(l.g, "0") catch return l.raiseMem());
            start = try ops.arith(l, .add, init_v, zero_exact);
        }
        if (try exactPast(l, start, limit_v, step_order == .gt)) return true;
        l.stack[r] = start;
        l.stack[r + 1] = limit_v;
        l.stack[r + 2] = step_v;
        l.stack[r + 3] = start;
        return false;
    }
    if (init_v.tag == .integer and step_v.tag == .integer) {
        const init = init_v.asInt();
        const step = step_v.asInt();
        if (step == 0) return l.raiseFmt("'for' step is zero", .{});
        // Clip a float limit to the integer range.
        const limit: i64 = blk: {
            if (limit_v.tag == .integer) break :blk limit_v.asInt();
            const f = limit_v.asFloat();
            if (std.math.isNan(f)) return true;
            if (step > 0) {
                const fl = @floor(f);
                if (fl >= 9.223372036854775807e18) break :blk std.math.maxInt(i64);
                if (fl < -9.223372036854775808e18) return true;
                break :blk @intFromFloat(fl);
            } else {
                const fl = @ceil(f);
                if (fl < -9.223372036854775808e18) break :blk std.math.minInt(i64);
                if (fl >= 9.223372036854775807e18) return true;
                break :blk @intFromFloat(fl);
            }
        };
        if (if (step > 0) init > limit else init < limit) return true;
        // Iteration count, computed in unsigned arithmetic to avoid
        // overflow.
        const ui: u64 = @bitCast(init);
        const ul: u64 = @bitCast(limit);
        const count: u64 = if (step > 0)
            (ul -% ui) / @as(u64, @intCast(step))
        else
            (ui -% ul) / (@as(u64, @bitCast(-(step + 1))) + 1);
        l.stack[r] = Value.int(init);
        l.stack[r + 1] = Value.int(@bitCast(count));
        l.stack[r + 2] = Value.int(step);
        l.stack[r + 3] = Value.int(init);
        return false;
    }
    const init = ops.toFloat(init_v);
    const limit = ops.toFloat(limit_v);
    const step = ops.toFloat(step_v);
    if (step == 0) return l.raiseFmt("'for' step is zero", .{});
    if (if (step > 0) limit < init else init < limit) return true;
    l.stack[r] = Value.float(init);
    l.stack[r + 1] = Value.float(limit);
    l.stack[r + 2] = Value.float(step);
    l.stack[r + 3] = Value.float(init);
    return false;
}

fn forValue(l: *Thread, v: Value, what: []const u8) Error!Value {
    return switch (v.tag) {
        .integer, .float => v,
        .string => ops.toNumberCoerce(v) orelse l.raiseFmt("'for' {s} value must be a number", .{what}),
        .bigint, .decimal => v,
        else => l.raiseFmt("'for' {s} value must be a number", .{what}),
    };
}

fn isBuiltinRange(l: *Thread, v: Value) bool {
    if (v.tag != .native) return false;
    const p = l.g.ext.get("range") orelse return false;
    return @intFromPtr(p) == v.payload;
}

/// Converts `range(a, b [, step])` arguments at r+1..r+3 into the numeric
/// loop layout at r..r+3. Returns true when the loop is empty.
fn rangePrep(l: *Thread, r: u32) Error!bool {
    l.stack[r] = l.stack[r + 1];
    l.stack[r + 1] = l.stack[r + 2];
    l.stack[r + 2] = if (l.stack[r + 3].isNil()) Value.int(1) else l.stack[r + 3];
    return forPrep(l, r);
}

fn globalDefine(l: *Thread, env: Value, name: Value, v: Value) Error!void {
    const cur = try ops.index(l, env, name);
    if (!cur.isNil()) return l.raiseFmt("global '{s}' already defined", .{name.as(String).bytes()});
    try ops.setIndex(l, env, name, v);
}

/// Runs queued `__gc` finalizers at a safe point (a call instruction).
fn runPendingFinalizers(l: *Thread) Error!void {
    try @import("../lib/base.zig").runFinalizers(l);
}

// ---------------------------------------------------------------------
// Debug hooks

/// Count and line events, before the instruction at `pc` runs.
fn hookStep(l: *Thread, fi: usize, cl: *Closure, pc: u32) Error!void {
    const mask = l.hook_mask;
    if (mask == 0 or !l.allow_hook) return;
    l.frames.items[fi].pc = pc + 1;
    if (mask & Thread.hook_countm != 0) {
        if (l.hook_left <= 1) {
            l.hook_left = l.hook_count;
            try callHook(l, "count", null);
        } else l.hook_left -= 1;
    }
    if (mask & Thread.hook_line != 0) {
        const lines = cl.proto.lines;
        if (lines.len > pc) {
            const line = lines[pc];
            const old = l.hook_oldpc;
            // A new function, a jump backwards, or a new line.
            const fire = if (l.hook_oldfi != fi)
                pc == 0 or lines[pc - 1] != line
            else
                pc == 0 or pc <= old or old >= lines.len or lines[old] != line;
            l.hook_oldpc = pc;
            l.hook_oldfi = fi;
            if (fire) try callHook(l, "line", line);
        }
    }
}

/// Calls the thread's hook function with `event` (and the line for line
/// events). Hooks do not fire while a hook runs.
pub fn callHook(l: *Thread, event: []const u8, line: ?u32) Error!void {
    if (!l.allow_hook) return;
    // An attached debugger takes every event in place of the hook function.
    const dbg = l.g.debugger;
    const f = if (dbg == null) @import("../lib/debuglib.zig").hookFunction(l) orelse return else Value.nil;
    l.allow_hook = false;
    defer l.allow_hook = true;
    const saved_top = l.top;
    defer l.top = saved_top;
    if (l.frames.items.len > 0) if (l.frame().closure) |cl| {
        l.top = @max(l.top, l.frame().base + cl.proto.max_stack);
    };
    if (dbg) |d| return d.event(d.ctx, l, event, line);
    const ev = try l.newStringValue(event);
    l.hook_calling = true;
    _ = try ops.callN(l, f, &.{ ev, if (line) |n| Value.int(n) else .nil }, 0);
}

fn captureTraceback(l: *Thread) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    @import("debug.zig").traceback(l, &buf, 0) catch return;
    l.err_traceback = state.newStringIn(l.g, buf.items) catch null;
}
