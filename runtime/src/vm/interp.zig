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
/// Internal: hooks were set or cleared, so the interpreter changes loops.
const LoopError = error{SwitchLoop};

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
    const u = gc.alloc(l.g, Upvalue, .upvalue, @sizeOf(Upvalue)) catch return l.raiseMem();
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
    const u = gc.alloc(l.g, Upvalue, .upvalue, @sizeOf(Upvalue)) catch return l.raiseMem();
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
                const nat = callee.as(state.Native);
                try l.ensure(32);
                l.frames.append(l.g.gpa, .{ .func = f, .base = f + 1, .native = nat, .want = want, .ret = f }) catch return l.raiseMem();
                l.top = f + 1 + n;
                const nres = nat.func(l) catch |e| {
                    // Yields keep the native frame so resume can finish it.
                    if (e == error.LusError) {
                        if (l.status == .suspended and l.yielding) return error.Yield;
                    }
                    return e;
                };
                try poscall(l, nres);
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

const Ctx = struct {
    /// Index of the running frame. Frames live in a growable list that a
    /// re-entrant call can reallocate, so the interpreter never keeps a
    /// pointer to a frame across an operation.
    fi: usize,
    cl: *Closure,
    code: []u32,
    k: []Value,
    base: u32,
};

inline fn load(l: *Thread) Ctx {
    const fr = l.frame();
    const cl = fr.closure.?;
    return .{ .fi = l.frames.items.len - 1, .cl = cl, .code = cl.proto.code, .k = cl.proto.constants, .base = fr.base };
}

/// Runs Lus frames until the frame count drops to `stop`.
pub fn execute(l: *Thread, stop: usize) (Error || YieldError)!void {
    while (true) {
        // The hooked loop is a second instantiation of the same code, so
        // threads without hooks pay nothing for them.
        const r = if (l.hook_mask != 0) run(l, stop, true) else run(l, stop, false);
        r catch |e| {
            l.meta_finish = null;
            switch (e) {
                // A metamethod frame was pushed, or the hooks changed.
                error.MetaCall, error.SwitchLoop => continue,
                error.Yield => return error.Yield,
                error.LusError => {
                    if (!handleError(l, stop)) return error.LusError;
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

fn run(l: *Thread, stop: usize, comptime hooked: bool) (Error || YieldError || LoopError)!void {
    var c = load(l);
    var pc = l.frames.items[c.fi].pc;
    const R = struct {
        inline fn reg(lp: *Thread, base: u32, i: u8) *Value {
            return &lp.stack[base + i];
        }
    };
    while (true) {
        if (hooked) try hookStep(l, &c, pc);
        const ins = c.code[pc];
        pc += 1;
        l.frames.items[c.fi].pc = pc; // keep the frame pc current for errors and hooks
        const ra = opc.a(ins);
        switch (opc.op(ins)) {
            .move => R.reg(l, c.base, ra).* = R.reg(l, c.base, opc.b(ins)).*,
            .loadk => R.reg(l, c.base, ra).* = c.k[opc.bx(ins)],
            .loadi => R.reg(l, c.base, ra).* = Value.int(opc.sbx(ins)),
            .loadf => R.reg(l, c.base, ra).* = Value.float(@floatFromInt(opc.sbx(ins))),
            .loadnil => {
                var i: u32 = 0;
                while (i <= opc.b(ins)) : (i += 1) R.reg(l, c.base, ra + @as(u8, @intCast(i))).* = .nil;
            },
            .loadfalse => R.reg(l, c.base, ra).* = .false,
            .loadtrue => R.reg(l, c.base, ra).* = .true,

            .getupval => R.reg(l, c.base, ra).* = c.cl.upvals()[opc.b(ins)].loc.*,
            .setupval => {
                const u = c.cl.upvals()[opc.b(ins)];
                u.loc.* = R.reg(l, c.base, ra).*;
                gc.barrierBack(l.g, &u.hdr);
            },
            .gettabup => {
                const t = c.cl.upvals()[opc.b(ins)].loc.*;
                const key = c.k[opc.c(ins)];
                {
                    const v_ = try getStrFast(l, t, key, ra);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .settabup => {
                const t = c.cl.upvals()[ra].loc.*;
                try setFast(l, t, c.k[opc.b(ins)], R.reg(l, c.base, opc.c(ins)).*);
            },
            .gettable => {
                const t = R.reg(l, c.base, opc.b(ins)).*;
                const key = R.reg(l, c.base, opc.c(ins)).*;
                {
                    const v_ = try getFast(l, t, key, ra);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .getfield => {
                const t = R.reg(l, c.base, opc.b(ins)).*;
                {
                    const v_ = try getStrFast(l, t, c.k[opc.c(ins)], ra);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .getindex => {
                const t = R.reg(l, c.base, opc.b(ins)).*;
                const i: i64 = opc.c(ins);
                if (t.tag == .table) {
                    const v = table.getInt(t.as(Table), i);
                    if (!v.isNil() or t.as(Table).metatable == null) {
                        R.reg(l, c.base, ra).* = v;
                        continue;
                    }
                }
                {
                    const v_ = try metaIndex(l, t, Value.int(i), ra);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .settable => {
                const t = R.reg(l, c.base, ra).*;
                try setFast(l, t, R.reg(l, c.base, opc.b(ins)).*, R.reg(l, c.base, opc.c(ins)).*);
            },
            .setfield => {
                const t = R.reg(l, c.base, ra).*;
                try setFast(l, t, c.k[opc.b(ins)], R.reg(l, c.base, opc.c(ins)).*);
            },
            .setindex => {
                const t = R.reg(l, c.base, ra).*;
                try setFast(l, t, Value.int(opc.b(ins)), R.reg(l, c.base, opc.c(ins)).*);
            },
            .newtable => {
                if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) try runPendingFinalizers(l);
                const nb: usize = opc.b(ins);
                const nc: usize = opc.c(ins);
                // Registers above the target are dead here, so a collection
                // triggered by this allocation must not keep their values.
                l.top = c.base + ra + 1;
                const t = l.newTable(nb, if (nc == 0) 0 else nc);
                l.top = c.base + c.cl.proto.max_stack;
                R.reg(l, c.base, ra).* = Value.obj(.table, try t);
            },
            .self => {
                const obj = R.reg(l, c.base, opc.b(ins)).*;
                R.reg(l, c.base, ra + 1).* = obj;
                {
                    const v_ = try getStrFast(l, obj, c.k[opc.c(ins)], ra);
                    R.reg(l, c.base, ra).* = v_;
                }
            },

            .add => try arith2(l, c.base, ins, .add),
            .sub => try arith2(l, c.base, ins, .sub),
            .mul => try arith2(l, c.base, ins, .mul),
            .div => try arith2(l, c.base, ins, .div),
            .mod => try arith2(l, c.base, ins, .mod),
            .pow => try arith2(l, c.base, ins, .pow),
            .idiv => try arith2(l, c.base, ins, .idiv),
            .band => try arith2(l, c.base, ins, .band),
            .bor => try arith2(l, c.base, ins, .bor),
            .bxor => try arith2(l, c.base, ins, .bxor),
            .shl => try arith2(l, c.base, ins, .shl),
            .shr => try arith2(l, c.base, ins, .shr),
            .addk => try arithK(l, c, ins, .add),
            .subk => try arithK(l, c, ins, .sub),
            .mulk => try arithK(l, c, ins, .mul),
            .divk => try arithK(l, c, ins, .div),
            .modk => try arithK(l, c, ins, .mod),
            .powk => try arithK(l, c, ins, .pow),
            .idivk => try arithK(l, c, ins, .idiv),
            .addi => {
                const x = R.reg(l, c.base, opc.b(ins)).*;
                const imm = opc.sc(ins);
                if (x.tag == .integer) {
                    R.reg(l, c.base, ra).* = Value.int(x.asInt() +% imm);
                } else if (x.tag == .float) {
                    R.reg(l, c.base, ra).* = Value.float(x.asFloat() + @as(f64, @floatFromInt(imm)));
                } else {
                    {
                        const v_ = try metaArith(l, .add, x, Value.int(imm), ra);
                        R.reg(l, c.base, ra).* = v_;
                    }
                }
            },

            .unm => {
                const x = R.reg(l, c.base, opc.b(ins)).*;
                const r = switch (x.tag) {
                    .integer => Value.int(0 -% x.asInt()),
                    .float => Value.float(-x.asFloat()),
                    else => try metaArith(l, .unm, x, x, ra),
                };
                R.reg(l, c.base, ra).* = r;
            },
            .bnot => {
                const x = R.reg(l, c.base, opc.b(ins)).*;
                const r = if (x.tag == .integer) Value.int(~x.asInt()) else try metaArith(l, .bnot, x, x, ra);
                R.reg(l, c.base, ra).* = r;
            },
            .not => R.reg(l, c.base, ra).* = Value.boolean(!R.reg(l, c.base, opc.b(ins)).truthy()),
            .len => {
                const r = try metaLength(l, R.reg(l, c.base, opc.b(ins)).*, ra);
                R.reg(l, c.base, ra).* = r;
            },
            .concat => {
                const n = opc.b(ins);
                const r = try ops.concat(l, c.base + ra, n);
                R.reg(l, c.base, ra).* = r;
            },
            .interp => {
                const n = opc.b(ins);
                {
                    const v_ = try interpolate(l, c.base + ra, n);
                    R.reg(l, c.base, ra).* = v_;
                }
            },

            .jmp => {
                const off = opc.sj(ins);
                pc = @intCast(@as(i64, pc) + off);
                // Loops are safe points for pending finalizers.
                if (off < 0 and l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) {
                    l.frames.items[c.fi].pc = pc;
                    try runPendingFinalizers(l);
                }
            },
            .eq => {
                const x = R.reg(l, c.base, ra).*;
                const y = R.reg(l, c.base, opc.b(ins)).*;
                const r = try metaCompare(l, .eq, x, y, opc.c(ins) != 0);
                if (r != (opc.c(ins) != 0)) pc += 1;
            },
            .lt => {
                const x = R.reg(l, c.base, ra).*;
                const y = R.reg(l, c.base, opc.b(ins)).*;
                const r = if (x.tag == .integer and y.tag == .integer) x.asInt() < y.asInt() else try metaCompare(l, .lt, x, y, opc.c(ins) != 0);
                if (r != (opc.c(ins) != 0)) pc += 1;
            },
            .le => {
                const x = R.reg(l, c.base, ra).*;
                const y = R.reg(l, c.base, opc.b(ins)).*;
                const r = if (x.tag == .integer and y.tag == .integer) x.asInt() <= y.asInt() else try metaCompare(l, .le, x, y, opc.c(ins) != 0);
                if (r != (opc.c(ins) != 0)) pc += 1;
            },
            .eqk => {
                const x = R.reg(l, c.base, ra).*;
                const r = ops.rawEqual(l, x, c.k[opc.b(ins)]);
                if (r != (opc.c(ins) != 0)) pc += 1;
            },
            .test_ => {
                if (R.reg(l, c.base, ra).truthy() != (opc.c(ins) != 0)) pc += 1;
            },
            .testset => {
                const v = R.reg(l, c.base, opc.b(ins)).*;
                if (v.truthy() != (opc.c(ins) != 0)) pc += 1 else R.reg(l, c.base, ra).* = v;
            },
            .testnil => {
                if (R.reg(l, c.base, ra).isNil() != (opc.c(ins) != 0)) pc += 1;
            },

            .call => {
                if (l.g.tobefnz.items.len > 0 and !l.g.running_finalizers) try runPendingFinalizers(l);
                const nb = opc.b(ins);
                const want: i32 = @as(i32, opc.c(ins)) - 1;
                const func = c.base + ra;
                const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
                if (nb != 0) l.top = func + nb;
                const kind = try precall(l, func, nargs, want);
                if (kind == .lus) {
                    c = load(l);
                    pc = 0;
                    if (hooked and l.hook_mask & Thread.hook_call != 0) try callHook(l, "call", null);
                } else {
                    if (want >= 0) l.top = c.base + c.cl.proto.max_stack;
                    // A native may have set or cleared the hooks.
                    if ((l.hook_mask != 0) != hooked) return error.SwitchLoop;
                }
            },
            .tailcall => {
                const nb = opc.b(ins);
                const func = c.base + ra;
                const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
                const callee = l.stack[func];
                if (callee.tag != .closure) {
                    // Natives and __call targets run as a plain call
                    // followed by a return of all results.
                    if (nb != 0) l.top = func + nb;
                    const kind = try precall(l, func, nargs, -1);
                    if (kind == .lus) {
                        c = load(l);
                        pc = 0;
                        continue;
                    }
                    if (try doReturn(l, &c, &pc, func, l.top - func, stop)) return;
                    continue;
                }
                // Reuse the current frame: close upvalues, move the callee
                // and arguments down to the frame's return slot.
                closeUpvals(l, c.base);
                const fr = l.frames.pop().?;
                const dst = fr.ret;
                var i: u32 = 0;
                while (i <= nargs) : (i += 1) l.stack[dst + i] = l.stack[func + i];
                l.top = dst + 1 + nargs;
                _ = try precall(l, dst, nargs, fr.want);
                const nf = l.frame();
                nf.boundary = fr.boundary;
                nf.tail = true;
                c = load(l);
                pc = 0;
                if (hooked and l.hook_mask & Thread.hook_call != 0) try callHook(l, "tail call", null);
            },
            .ret => {
                const nb = opc.b(ins);
                const first = c.base + ra;
                const n: u32 = if (nb != 0) nb - 1 else l.top - first;
                if (try doReturn(l, &c, &pc, first, n, stop)) return;
            },
            .ret0 => {
                if (try doReturn(l, &c, &pc, c.base, 0, stop)) return;
            },
            .ret1 => {
                if (try doReturn(l, &c, &pc, c.base + ra, 1, stop)) return;
            },

            .forprep => {
                if (try forPrep(l, c.base + ra)) pc += opc.bx(ins) + 1;
            },
            .forloop => {
                const r = c.base + ra;
                const idx = &l.stack[r];
                if (idx.tag == .integer) {
                    // R[r+1] holds the remaining iteration count.
                    const count: u64 = @bitCast(l.stack[r + 1].asInt());
                    if (count > 0) {
                        const step = l.stack[r + 2].asInt();
                        l.stack[r + 1] = Value.int(@bitCast(count - 1));
                        idx.* = Value.int(idx.asInt() +% step);
                        l.stack[r + 3] = idx.*;
                        pc -= opc.bx(ins);
                    }
                } else {
                    const step = l.stack[r + 2].asFloat();
                    const limit = l.stack[r + 1].asFloat();
                    const ni = idx.asFloat() + step;
                    if (if (step > 0) ni <= limit else limit <= ni) {
                        idx.* = Value.float(ni);
                        l.stack[r + 3] = idx.*;
                        pc -= opc.bx(ins);
                    }
                }
            },
            .tforprep => {
                const r = c.base + ra;
                if (!l.stack[r + 3].isNil()) try markTbc(l, r + 3);
                pc += opc.bx(ins);
            },
            .tforcall => {
                const r = c.base + ra;
                // R[r+4..] = R[r](R[r+1], R[r+2])
                l.stack[r + 4] = l.stack[r];
                l.stack[r + 5] = l.stack[r + 1];
                l.stack[r + 6] = l.stack[r + 2];
                l.top = r + 4 + 3;
                const want: i32 = opc.c(ins);
                const kind = try precall(l, r + 4, 2, want);
                if (kind == .lus) {
                    c = load(l);
                    pc = 0;
                } else {
                    l.top = c.base + c.cl.proto.max_stack;
                }
            },
            .tforloop => {
                const r = c.base + ra;
                if (!l.stack[r + 4].isNil()) {
                    l.stack[r + 2] = l.stack[r + 4];
                    pc -= opc.bx(ins);
                }
            },
            .rangeprep => {
                // R[A] holds the iterator expression results. When R[A] is
                // the builtin range, convert to an integer numeric loop:
                // R[A..A+2] = start, count, step and skip to the numeric
                // loop body following this instruction.
                const r = c.base + ra;
                if (isBuiltinRange(l, l.stack[r])) {
                    if (try rangePrep(l, r)) pc += opc.bx(ins) + 1;
                } else {
                    // Generic protocol: fall through to the tforprep that
                    // the compiler placed at pc + Bx + 1... encoded as the
                    // next instruction offset in C.
                    pc += opc.c(ins);
                }
            },

            .setlist => {
                const t = R.reg(l, c.base, ra).as(Table);
                var n: u32 = opc.b(ins);
                const first = c.base + ra + 1;
                if (n == 0) n = l.top - first;
                const start = opc.ax(c.code[pc]);
                pc += 1;
                const last = start + n;
                if (last > t.array.len) table.resize(l.g.gpa, t, last, t.hash_used) catch return l.raiseMem();
                var i: u32 = 0;
                while (i < n) : (i += 1) t.array[start + i] = l.stack[first + i];
                gc.barrierBack(l.g, &t.hdr);
                l.top = c.base + c.cl.proto.max_stack;
            },
            .closure => {
                const p = c.cl.proto.protos[opc.bx(ins)];
                l.top = c.base + ra + 1;
                const nc = makeClosure(l, p, c.cl, c.base);
                l.top = c.base + c.cl.proto.max_stack;
                R.reg(l, c.base, ra).* = Value.obj(.closure, try nc);
            },
            .vararg => {
                const want: i32 = @as(i32, opc.c(ins)) - 1;
                const vfr = l.frames.items[c.fi];
                const nv = vfr.nvarargs;
                const src = vfr.func - nv;
                const dst = c.base + ra;
                if (want < 0) {
                    try l.ensure(nv + 8);
                    var i: u32 = 0;
                    while (i < nv) : (i += 1) l.stack[dst + i] = l.stack[src + i];
                    l.top = dst + nv;
                } else {
                    var i: u32 = 0;
                    while (i < @as(u32, @intCast(want))) : (i += 1) l.stack[dst + i] = if (i < nv) l.stack[src + i] else .nil;
                }
            },
            .varargprep => {},
            .varargtab => {
                const vfr = l.frames.items[c.fi];
                const nv = vfr.nvarargs;
                const src = vfr.func - nv;
                const t = try l.newTable(nv, 1);
                var i: u32 = 0;
                while (i < nv) : (i += 1) t.array[i] = l.stack[src + i];
                R.reg(l, c.base, ra).* = Value.obj(.table, t);
                try ops.rawSet(l, t, try l.newStringValue("n"), Value.int(nv));
            },
            .close => {
                const level = c.base + ra;
                closeUpvals(l, level);
                if (l.tbc.items.len > 0 and l.tbc.items[l.tbc.items.len - 1] >= level) {
                    l.meta_finish = .{ .redo = false };
                    defer l.meta_finish = null;
                    try closeTbc(l, level, null);
                }
            },
            .tbc => try markTbc(l, c.base + ra),

            .slice => {
                const r = c.base + opc.b(ins);
                {
                    const v_ = try @import("ext.zig").slice(l, l.stack[r], l.stack[r + 1], l.stack[r + 2]);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .newenum => {
                {
                    const v_ = try @import("ext.zig").newEnum(l, c.k[opc.bx(ins)]);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .query => {
                {
                    const v_ = try @import("ext.zig").newQuery(l, c.k[opc.bx(ins)], c.base + ra + 1);
                    R.reg(l, c.base, ra).* = v_;
                }
            },
            .globaldef => {
                const env = c.cl.upvals()[ra].loc.*;
                try globalDefine(l, env, c.k[opc.b(ins)], R.reg(l, c.base, opc.c(ins)).*);
            },
            .globaldefr => {
                try globalDefine(l, R.reg(l, c.base, ra).*, c.k[opc.b(ins)], R.reg(l, c.base, opc.c(ins)).*);
            },
            .catchcheck => {
                const h = R.reg(l, c.base, ra).*;
                if (h.tag != .closure and h.tag != .native) {
                    return l.raiseFmt("attempt to use a {s} value as a catch handler", .{l.typeNameOf(h)});
                }
            },
            .settop => l.top = c.base + ra,
            .moverange => {
                const src = c.base + opc.b(ins);
                const dst = c.base + ra;
                const n = l.top - src;
                var i: u32 = 0;
                while (i < n) : (i += 1) l.stack[dst + i] = l.stack[src + i];
                l.top = dst + n;
            },
            .extraarg => unreachable,
        }
    }
}

/// Returns `n` values starting at `first` from the current frame. Returns
/// true when the interpreter loop must exit.
inline fn doReturn(l: *Thread, c: *Ctx, pc: *u32, first: u32, n: u32, stop: usize) Error!bool {
    if (l.hook_mask & Thread.hook_ret != 0) {
        if (l.top < first + n) l.top = first + n;
        try callHook(l, "return", null);
    }
    // Copy what is needed: __close handlers may reallocate the frames.
    const fr = l.frames.items[c.fi];
    if (l.open_upvals) |u| {
        if (u.level >= fr.base) closeUpvals(l, fr.base);
    }
    if (l.tbc.items.len > 0 and l.tbc.items[l.tbc.items.len - 1] >= fr.base) {
        // Protect the results while __close runs.
        l.top = first + n;
        l.meta_finish = .{ .redo = true };
        defer l.meta_finish = null;
        try closeTbc(l, fr.base, null);
    }
    l.top = first + n;
    const boundary = fr.boundary;
    try poscall(l, n);
    if (boundary or l.frames.items.len <= stop) return true;
    const want = l.frames.items.len; // caller frame now on top
    _ = want;
    if (l.frame().closure == null) return true;
    c.* = load(l);
    pc.* = l.frames.items[c.fi].pc;
    if (l.hook_mask != 0) {
        // Returning into the caller is not a new line.
        l.hook_oldfi = c.fi;
        l.hook_oldpc = if (pc.* > 0) pc.* - 1 else 0;
    }
    switch (fr.finish) {
        .none, .discard => {},
        .store => |r| l.stack[c.base + r] = l.stack[fr.ret],
        .cond => |k| if (l.stack[fr.ret].truthy() != k) {
            pc.* += 1;
            l.frames.items[c.fi].pc = pc.*;
        },
        .redo => |keep_top| {
            pc.* -= 1;
            l.frames.items[c.fi].pc = pc.*;
            if (keep_top) l.top = fr.ret;
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
    const cl = gc.alloc(l.g, Closure, .closure, Closure.allocSize(n)) catch return l.raiseMem();
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
    gc.maybeCollect(l.g);
    return cl;
}

// ---------------------------------------------------------------------
// Instruction helpers

inline fn arith2(l: *Thread, base: u32, ins: u32, comptime op: ops.ArithOp) Error!void {
    const x = l.stack[base + opc.b(ins)];
    const y = l.stack[base + opc.c(ins)];
    const r = try arithFast(l, op, x, y, opc.a(ins));
    l.stack[base + opc.a(ins)] = r;
}

inline fn arithK(l: *Thread, c: Ctx, ins: u32, comptime op: ops.ArithOp) Error!void {
    const x = l.stack[c.base + opc.b(ins)];
    const y = c.k[opc.c(ins)];
    const r = try arithFast(l, op, x, y, opc.a(ins));
    l.stack[c.base + opc.a(ins)] = r;
}

inline fn arithFast(l: *Thread, comptime op: ops.ArithOp, x: Value, y: Value, dest: u8) Error!Value {
    if (x.tag == .integer and y.tag == .integer) {
        const a = x.asInt();
        const b = y.asInt();
        switch (op) {
            .add => return Value.int(a +% b),
            .sub => return Value.int(a -% b),
            .mul => return Value.int(a *% b),
            .band => return Value.int(a & b),
            .bor => return Value.int(a | b),
            .bxor => return Value.int(a ^ b),
            else => {},
        }
    } else if (x.tag == .float and y.tag == .float) {
        const a = x.asFloat();
        const b = y.asFloat();
        switch (op) {
            .add => return Value.float(a + b),
            .sub => return Value.float(a - b),
            .mul => return Value.float(a * b),
            .div => return Value.float(a / b),
            else => {},
        }
    }
    return metaArith(l, op, x, y, dest);
}

inline fn getStrFast(l: *Thread, t: Value, key: Value, dest: u8) Error!Value {
    if (t.tag == .table) {
        const tab = t.as(Table);
        const v = table.getStr(tab, key.as(String));
        if (!v.isNil() or tab.metatable == null) return v;
    }
    return metaIndex(l, t, key, dest);
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

inline fn getFast(l: *Thread, t: Value, key: Value, dest: u8) Error!Value {
    if (t.tag == .table) {
        const tab = t.as(Table);
        const v = if (key.tag == .integer) table.getInt(tab, key.asInt()) else if (key.tag == .string) table.getStr(tab, key.as(String)) else table.get(tab, try ops.normKey(l, key));
        if (!v.isNil() or tab.metatable == null) return v;
    }
    return metaIndex(l, t, key, dest);
}

inline fn setFast(l: *Thread, t: Value, key: Value, v: Value) Error!void {
    if (t.tag == .table) {
        const tab = t.as(Table);
        if (tab.metatable == null) return ops.rawSet(l, tab, key, v);
    }
    return metaSet(l, t, key, v);
}

fn interpolate(l: *Thread, first: u32, n: u32) Error!Value {
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var ascii = true;
    var chars: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var v = l.stack[first + i];
        if (v.tag == .vector) return l.raiseFmt("cannot interpolate a vector (decode it with vector.tostring)", .{});
        if (v.tag != .string and !v.isNumber()) v = Value.obj(.string, try ops.toString(l, v));
        try ops.appendForConcat(l, &buf, v, &ascii, &chars);
    }
    const s = state.newStringKnown(l.g, buf.items, ascii, chars) catch return l.raiseMem();
    return Value.obj(.string, s);
}

/// Prepares a numeric for loop at registers r..r+3 (init, limit, step,
/// control). Returns true when the loop runs zero times.
fn forPrep(l: *Thread, r: u32) Error!bool {
    const init_v = try forValue(l, l.stack[r], "initial");
    const limit_v = try forValue(l, l.stack[r + 1], "limit");
    const step_v = try forValue(l, l.stack[r + 2], "step");
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
        .bigint, .decimal => Value.float(@import("numeric.zig").toFloat(l.g.gpa, v)),
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
fn hookStep(l: *Thread, c: *Ctx, pc: u32) Error!void {
    const mask = l.hook_mask;
    if (mask == 0 or !l.allow_hook) return;
    l.frames.items[c.fi].pc = pc + 1;
    if (mask & Thread.hook_countm != 0) {
        if (l.hook_left <= 1) {
            l.hook_left = l.hook_count;
            try callHook(l, "count", null);
        } else l.hook_left -= 1;
    }
    if (mask & Thread.hook_line != 0) {
        const lines = c.cl.proto.lines;
        if (lines.len > pc) {
            const line = lines[pc];
            const old = l.hook_oldpc;
            // A new function, a jump backwards, or a new line.
            const fire = if (l.hook_oldfi != c.fi)
                pc == 0 or lines[pc - 1] != line
            else
                pc == 0 or pc <= old or old >= lines.len or lines[old] != line;
            l.hook_oldpc = pc;
            l.hook_oldfi = c.fi;
            if (fire) try callHook(l, "line", line);
        }
    }
}

/// Calls the thread's hook function with `event` (and the line for line
/// events). Hooks do not fire while a hook runs.
pub fn callHook(l: *Thread, event: []const u8, line: ?u32) Error!void {
    if (!l.allow_hook) return;
    const f = @import("../lib/debuglib.zig").hookFunction(l) orelse return;
    l.allow_hook = false;
    defer l.allow_hook = true;
    const saved_top = l.top;
    defer l.top = saved_top;
    if (l.frames.items.len > 0) if (l.frame().closure) |cl| {
        l.top = @max(l.top, l.frame().base + cl.proto.max_stack);
    };
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
