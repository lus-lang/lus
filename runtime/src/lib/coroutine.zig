//! Coroutines. Each coroutine is a thread with its own value stack and
//! frame list. Resuming runs the interpreter on that thread. Yielding
//! unwinds the interpreter back to `resume` while every frame stays in
//! place, so a later resume continues exactly where the yield happened.
//!
//! A coroutine that `detach` handed to the scheduler runs whenever what
//! it waits for is ready (`vm/sched.zig`, `spec/design/coroutines.md`). A
//! coroutine that suspends inside a blocking native unwinds like a yield.
//! `resume` passes such a wait on to its own resumer and runs the native
//! again when the wait is over.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const interp = @import("../vm/interp.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const sched = @import("../vm/sched.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;

pub const funcs = [_]aux.Reg{
    .{ .name = "create", .func = create },
    .{ .name = "resume", .func = @"resume" },
    .{ .name = "yield", .func = yield },
    .{ .name = "status", .func = status },
    .{ .name = "running", .func = running },
    .{ .name = "isyieldable", .func = isyieldable },
    .{ .name = "wrap", .func = wrap },
    .{ .name = "close", .func = close },
    .{ .name = "detach", .func = detach },
    .{ .name = "sleep", .func = @import("events.zig").sleep },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, .fields, "coroutine", &funcs);
    try aux.setGlobal(l, "coroutine", Value.obj(.table, t));
}

fn checkCo(l: *Thread, i: u32) Error!*Thread {
    const v = l.arg(i);
    if (v.tag != .thread) return aux.typeError(l, i, "thread");
    return v.as(Thread);
}

pub fn newCoroutine(l: *Thread, f: Value) Error!*Thread {
    const co = state.newThread(l.g) catch return l.raiseMem();
    co.status = .suspended;
    @import("../vm/pledge.zig").inherit(co, l);
    @import("../vm/context.zig").inherit(co, l);
    co.stack[0] = f;
    co.top = 1;
    return co;
}

pub fn create(l: *Thread) Error!u32 {
    const f = try aux.checkFunction(l, 1);
    const co = try newCoroutine(l, f);
    return aux.ret(l, Value.obj(.thread, co));
}

/// Resumes `co` with `nargs` values taken from the top of `l`'s stack.
/// On success the yielded or returned values are moved to `l` and their
/// count is returned. On error, returns error.LusError with the error
/// value in `l.err` and `co` marked dead. When `co` suspends to wait, or
/// when `l` waits for a detached `co`, the error it returns suspends `l`
/// in turn with `l.yielding` set, and the caller passes it on untouched.
pub fn resumeCo(l: *Thread, co: *Thread, nargs: u32) Error!u32 {
    // Only a coroutine that waited or was detached has a scheduler
    // record, so a plain resume pays one test for all of this.
    if (sched.taskOf(co)) |t| {
        @branchHint(.unlikely);
        return resumeScheduled(l, co, nargs, t);
    }
    if (co.port) |p| return resumePort(l, co, p, nargs);
    if (co.status != .suspended) return notSuspended(l, co, nargs);
    return resumeWith(l, co, nargs, if (co.frames.items.len == 0) .fresh else .results);
}

/// Creates a port over `ctx` and pushes it.
pub fn newPort(l: *Thread, port: *const state.Port, ctx: Value) Error!*Thread {
    gc.maybeCollect(l.g);
    const co = state.newPortThread(l.g, port, ctx) catch return l.raiseMem();
    try l.push(Value.obj(.thread, co));
    return co;
}

/// Resumes a port: its native runs on `l` with the arguments of the
/// `resume` call in the frame. A wait inside the native suspends `l`, and
/// the scheduler calls `resume` again, which calls the native again.
inline fn resumePort(l: *Thread, co: *Thread, p: *const state.Port, nargs: u32) Error!u32 {
    if (co.status != .suspended) return notSuspended(l, co, nargs);
    if (co.resumer) |r| {
        if (r != l and portBusy(co, r)) {
            l.top -= nargs;
            return l.raise(try l.newStringValue("cannot resume non-suspended coroutine"));
        }
    }
    // The resumer stays recorded while the native waits, so a second
    // thread cannot read or write through the port meanwhile.
    co.resumer = l;
    const first = l.top - nargs;
    const n = p.step(l, co, l.stack[first..l.top]) catch |e| {
        if (!l.yielding) co.resumer = null;
        return e;
    };
    co.resumer = null;
    // The results replace the values of the resume, as they do for any
    // coroutine.
    const from = l.top - n;
    if (from != first) {
        var i: u32 = 0;
        while (i < n) : (i += 1) l.stack[first + i] = l.stack[from + i];
        l.top = first + n;
    }
    return n;
}

/// True while the thread `r` waits inside a resume of the port `co`. A
/// thread that was cancelled or closed while it waited has left the port.
fn portBusy(co: *Thread, r: *Thread) bool {
    const t = sched.taskOf(r) orelse return false;
    if (t.kind == .none or r.frames.items.len == 0) return false;
    const fr = r.frame();
    if (fr.native == null) return false;
    const v = r.stack[fr.base];
    return v.tag == .thread and v.as(Thread) == co;
}

fn notSuspended(l: *Thread, co: *Thread, nargs: u32) Error {
    @branchHint(.cold);
    const what = switch (co.status) {
        // An event coroutine of the runtime that was closed, such as a sleep
        // that another coroutine ended to wake its waiter.
        .dead, .err => if (co.event_closed) "closed" else "cannot resume dead coroutine",
        else => "cannot resume non-suspended coroutine",
    };
    l.top -= nargs;
    return l.raise(try l.newStringValue(what));
}

/// `resumeCo` for a coroutine with a scheduler record: one that is
/// detached, or one that suspended inside a native at some point.
noinline fn resumeScheduled(l: *Thread, co: *Thread, nargs: u32, t: *sched.Task) Error!u32 {
    if (t.detached) {
        // A detached coroutine takes no values. The caller waits for its
        // end.
        l.top -= nargs;
        return joinDetached(l, co, t);
    }
    if (co.status != .suspended) return notSuspended(l, co, nargs);
    if (t.kind != .none) {
        // The coroutine suspended inside a native. The thread that
        // resumed it runs that native again.
        if (co.resumer) |r| {
            if (r != l and sched.awaits(r, co)) {
                l.top -= nargs;
                return l.raise(try l.newStringValue("cannot resume non-suspended coroutine"));
            }
        }
        l.top -= nargs;
        return resumeWith(l, co, 0, .restart);
    }
    return resumeWith(l, co, nargs, if (co.frames.items.len == 0) .fresh else .results);
}

/// Runs the suspended coroutine `co` from `l` with `n` values from the
/// top of the stack of `l`.
inline fn resumeWith(l: *Thread, co: *Thread, n: u32, mode: sched.Entry) Error!u32 {
    if (l.ncalls >= Thread.max_ncalls or l.g.native_depth >= Thread.max_ncalls) {
        l.top -= n;
        return l.raiseFmt("C stack overflow", .{});
    }
    // Move the arguments to the coroutine.
    co.ensure(n + 1) catch {
        l.top -= n;
        return l.raise(co.err);
    };
    const src = l.top - n;
    var i: u32 = 0;
    while (i < n) : (i += 1) co.stack[co.top + i] = l.stack[src + i];
    co.top += n;
    l.top = src;
    co.status = .running;
    co.resumer = l;
    co.resumer_passes = true;
    l.status = .normal;
    l.ncalls += 1;
    l.g.native_depth += 1;
    const outcome = runCo(co, mode, n);
    l.ncalls -= 1;
    l.g.native_depth -= 1;
    l.status = .running;
    switch (outcome) {
        .yielded => {
            if (sched.taskOf(co)) |t| {
                @branchHint(.unlikely);
                if (t.kind != .none) return passWait(l, co);
            }
            co.resumer = null;
            return takeResults(l, co, .suspended);
        },
        .returned => {
            co.resumer = null;
            return takeResults(l, co, .dead);
        },
        .failed => {
            co.resumer = null;
            // The error stays on the coroutine until close() reports it.
            co.status = .err;
            return l.raise(co.err);
        },
    }
}

/// The coroutine `co` that `l` resumed waits, so `l` waits for it. The
/// scheduler finds what to wait for through `l`.
noinline fn passWait(l: *Thread, co: *Thread) Error {
    co.status = .suspended;
    const me = try sched.ensureTask(l);
    me.kind = .inner;
    me.target = co;
    return sched.suspendThread(l, me);
}

/// True when `co` suspended inside a native to wait.
inline fn waiting(co: *Thread) bool {
    const t = sched.taskOf(co) orelse return false;
    return t.kind != .none;
}

/// Moves the values at the top of the stack of `co` to `l`.
inline fn takeResults(l: *Thread, co: *Thread, status_after: state.Status) Error!u32 {
    const n = co.transfer;
    const from = co.top - n;
    try l.ensure(n + 1);
    var i: u32 = 0;
    while (i < n) : (i += 1) l.stack[l.top + i] = co.stack[from + i];
    l.top += n;
    co.top = from;
    co.status = status_after;
    return n;
}

/// `resume` on the detached coroutine `co`: waits until it ends and
/// returns what a plain resume returns for a coroutine that ends. The
/// first resume after the end collects the results or the error, and so
/// does every thread that was already waiting. A later resume finds a
/// dead coroutine.
fn joinDetached(l: *Thread, co: *Thread, t: *sched.Task) Error!u32 {
    if (co == l) return l.raise(try l.newStringValue("cannot resume non-suspended coroutine"));
    var waiter = sched.joined(l, co);
    if (t.place != .done) {
        const can = sched.canSuspend(l);
        // A coroutine below `l` on the native stack cannot end while `l`
        // keeps the stack.
        if (!can and t.place == .running) return l.raise(try l.newStringValue("cannot resume non-suspended coroutine"));
        try sched.waitJoin(l, co);
        waiter = true;
    }
    const me = sched.taskOf(l);
    if (waiter) {
        if (t.fin_waiters > 0) t.fin_waiters -= 1;
        // The native that waited without suspending forgets its wait
        // here. A native that ran again forgets it when it returns.
        if (me) |m| {
            if (!m.restarted) sched.clearWait(l.g, m);
        }
    } else if (t.collected) {
        return l.raise(try l.newStringValue("cannot resume dead coroutine"));
    }
    t.collected = true;
    switch (t.outcome) {
        .returned => {
            const n = t.nres;
            const from = co.top - n;
            try l.ensure(n + 1);
            var i: u32 = 0;
            while (i < n) : (i += 1) l.stack[l.top + i] = co.stack[from + i];
            l.top += n;
            if (t.fin_waiters == 0) {
                co.top = from;
                t.nres = 0;
            }
            return n;
        },
        .failed => return l.raise(co.err),
        .cancelled, .pending => return l.raise(try l.newStringValue("cannot resume dead coroutine")),
    }
}

/// Runs the detached coroutine `co` from the thread `l` that runs the
/// scheduler. `nargs` values for it are at the top of its stack.
pub fn runDetached(l: *Thread, co: *Thread, mode: sched.Entry, nargs: u32) Outcome {
    const saved = l.status;
    co.status = .running;
    co.resumer = l;
    co.resumer_passes = false;
    l.status = .normal;
    l.ncalls += 1;
    l.g.native_depth += 1;
    const outcome = runCo(co, mode, nargs);
    l.ncalls -= 1;
    l.g.native_depth -= 1;
    l.status = saved;
    co.resumer = null;
    return outcome;
}

pub const Outcome = enum { yielded, returned, failed };

inline fn runCo(co: *Thread, mode: sched.Entry, nargs: u32) Outcome {
    switch (mode) {
        .fresh => {
            const kind = interp.precall(co, 0, nargs, -1) catch |e| return handleStop(co, e);
            if (kind == .done) {
                co.transfer = co.top;
                return .returned;
            }
            if (co.hook_mask & Thread.hook_call != 0) interp.callHook(co, "call", null) catch |e| return handleStop(co, e);
        },
        .results => {
            // Finish the pending `yield` call: its results are the resume
            // arguments now at the top of the stack.
            const fr = co.frame();
            const want = fr.want;
            interp.poscall(co, nargs) catch return .failed;
            if (co.frames.items.len > 0) {
                const top_fr = co.frame();
                if (top_fr.closure) |cl| {
                    if (want >= 0) co.top = top_fr.base + cl.proto.max_stack;
                }
            } else {
                co.transfer = co.top;
                return .returned;
            }
        },
        .restart => {
            // The coroutine suspended inside a native to wait. The native
            // runs again and continues the call.
            interp.restartNative(co) catch |e| return handleStop(co, e);
            if (co.frames.items.len == 0) {
                co.transfer = co.top;
                return .returned;
            }
        },
    }
    if (co.frames.items.len > 0) {
        interp.execute(co, 0) catch |e| return handleStop(co, e);
    }
    co.transfer = co.top;
    return .returned;
}

fn handleStop(co: *Thread, e: anyerror) Outcome {
    if (e == error.Yield) {
        co.yielding = false;
        return .yielded;
    }
    if (co.self_closed) {
        // The coroutine closed itself: it ends with no results.
        co.self_closed = false;
        co.frames.items.len = 0;
        co.top = 0;
        co.transfer = 0;
        return .returned;
    }
    // Error: the frames and pending to-be-closed variables stay in place
    // until coroutine.close, so a traceback can still inspect them. The
    // top covers every live register so the collector keeps them.
    var top = co.top;
    for (co.frames.items) |f| {
        if (f.closure) |cl| top = @max(top, f.base + cl.proto.max_stack);
    }
    if (co.tbc.items.len > 0) top = @max(top, co.tbc.items[co.tbc.items.len - 1] + 1);
    co.top = @min(top, @as(u32, @intCast(co.stack.len)));
    return .failed;
}

/// Closes a suspended or errored coroutine: runs pending to-be-closed
/// variables with the pending error (if any) and marks it dead. Returns
/// the final error, or null when everything closed cleanly.
fn closeThread(co: *Thread) ?Value {
    // A coroutine that waits for an event coroutine of the runtime, such as
    // a sleep or a watch, cancels that wait with it.
    const event: ?*Thread = if (co.task) |t| (if (t.kind == .inner and t.target != null and t.target.?.event) t.target else null) else null;
    defer if (event) |e| {
        if (e.status == .suspended) _ = closeThread(e);
    };
    if (co.event and co.status == .suspended) co.event_closed = true;
    sched.abandonWait(co);
    // The results or the error that waiters still read. The end of a
    // detached coroutine woke them, and they run after this close.
    var owed: u32 = 0;
    var owed_err: ?Value = null;
    if (sched.taskOf(co)) |t| {
        // Closing a detached coroutine collects its error and drops the
        // results that no waiter reads anymore.
        if (t.detached) {
            t.collected = true;
            if (t.fin_waiters > 0) {
                owed = t.nres;
                if (t.outcome == .failed) owed_err = co.err;
            } else {
                t.nres = 0;
            }
        }
    }
    var err: ?Value = if (co.status == .err) co.err else null;
    co.err = .nil;
    if (co.frames.items.len > 0) {
        interp.closeUpvals(co, 0);
        const saved = co.status;
        co.status = .running;
        interp.closeTbc(co, 0, err) catch {
            err = co.err;
        };
        co.status = saved;
    }
    co.frames.items.len = 0;
    co.tbc.items.len = 0;
    // A coroutine that returned has no frames, so its results are still
    // at the top of its stack. They move to the bottom.
    const from = co.top - owed;
    var i: u32 = 0;
    while (i < owed) : (i += 1) co.stack[i] = co.stack[from + i];
    co.top = owed;
    co.status = .dead;
    co.err = owed_err orelse .nil;
    return err;
}

/// Closes a detached coroutine that the scheduler gave up, as the end of
/// a state does.
pub fn closeCancelled(co: *Thread) void {
    _ = closeThread(co);
}

/// True when an error of `l` leaves through every handler: the thread
/// suspends to wait, the state stops, or an error nothing collected
/// stops the program.
inline fn passes(l: *Thread) bool {
    return l.yielding or l.g.halting or l.g.sched.fatal;
}

fn @"resume"(l: *Thread) Error!u32 {
    const co = try checkCo(l, 1);
    const nargs = l.argCount() - 1;
    const n = resumeCo(l, co, nargs) catch {
        // A wait suspends this thread as well, and a stopping worker
        // unwinds through coroutines.
        if (passes(l)) return error.LusError;
        const err = l.err;
        try l.push(.false);
        try l.push(err);
        return 2;
    };
    // Insert `true` below the n transferred values.
    try l.ensure(1);
    var i: u32 = 0;
    while (i < n) : (i += 1) l.stack[l.top - i] = l.stack[l.top - i - 1];
    l.stack[l.top - n] = .true;
    l.top += 1;
    return n + 1;
}

pub fn resumeNative(l: *Thread) Error!u32 {
    return @"resume"(l);
}

pub fn closeNative(l: *Thread) Error!u32 {
    return close(l);
}

pub fn statusNative(l: *Thread) Error!u32 {
    return status(l);
}

pub fn yield(l: *Thread) Error!u32 {
    if (l == l.g.main_thread or l.resumer == null) {
        return l.raiseFmt("attempt to yield from outside a coroutine", .{});
    }
    l.transfer = l.argCount();
    l.yielding = true;
    l.status = .suspended;
    return error.LusError;
}

fn status(l: *Thread) Error!u32 {
    const co = try checkCo(l, 1);
    return aux.retStr(l, statusName(l, co));
}

fn statusName(l: *Thread, co: *Thread) []const u8 {
    if (co == l) return "running";
    return switch (co.status) {
        .suspended => "suspended",
        .running => "running",
        .normal => "normal",
        .dead, .err => "dead",
        .ok => if (co == l.g.main_thread) "normal" else "dead",
    };
}

fn running(l: *Thread) Error!u32 {
    try l.push(Value.obj(.thread, l));
    try l.push(Value.boolean(l == l.g.main_thread));
    return 2;
}

fn isyieldable(l: *Thread) Error!u32 {
    const co = if (l.hasArg(1)) try checkCo(l, 1) else l;
    // Every coroutine can yield. The main thread and coroutines
    // running under a native call boundary cannot.
    return aux.retBool(l, co != l.g.main_thread and (co != l or co.ncalls == 0));
}

fn wrapAux(l: *Thread) Error!u32 {
    const nat = l.frame().native.?;
    if (nat.upvalues()[0].tag != .thread) return l.raiseFmt("the wrapped coroutine is gone", .{});
    const co = nat.upvalues()[0].as(Thread);
    const nargs = l.argCount();
    return resumeCo(l, co, nargs) catch {
        if (passes(l)) return error.LusError;
        var err = l.err;
        if (co.status == .err) {
            // Close the failed coroutine, then propagate its error with
            // the position of the call to the wrapper.
            err = closeThread(co) orelse err;
        }
        if (err.tag == .string) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(l.g.gpa);
            l.where(&buf, 1) catch return l.raiseMem();
            buf.appendSlice(l.g.gpa, err.as(object.String).bytes()) catch return l.raiseMem();
            err = try l.newStringValue(buf.items);
        }
        return l.raise(err);
    };
}

fn wrap(l: *Thread) Error!u32 {
    const f = try aux.checkFunction(l, 1);
    const co = try newCoroutine(l, f);
    // Creating the native can collect, so the coroutine stays on the
    // stack until the native holds it.
    try l.push(Value.obj(.thread, co));
    const n = state.newNative(l.g, wrapAux, "wrap", 1) catch return l.raiseMem();
    n.upvalues()[0] = Value.obj(.thread, co);
    return aux.ret(l, Value.obj(.native, n));
}

fn close(l: *Thread) Error!u32 {
    const co = if (l.hasArg(1)) try checkCo(l, 1) else l;
    if (co == l) {
        if (co == l.g.main_thread) return l.raiseFmt("cannot close main thread", .{});
        // Closing the running coroutine runs its pending to-be-closed
        // variables and ends it, as if its body had returned nothing.
        interp.closeUpvals(co, 0);
        try interp.closeTbc(co, 0, null);
        co.self_closed = true;
        return error.LusError;
    }
    if (co.status != .suspended and co.status != .dead and co.status != .err and !co.event) {
        return l.raiseFmt("cannot close a {s} coroutine", .{statusName(l, co)});
    }
    if (closeCo(l, co)) |err| {
        try l.push(.false);
        try l.push(err);
        return 2;
    }
    return aux.retBool(l, true);
}

/// Closes the coroutine `co`, which is not the running one, and returns
/// the error it ended with, if any. A coroutine that runs or that resumed
/// another one stays as it is. `coroutine.close`, a to-be-closed variable
/// that holds a coroutine, and a loop over a coroutine all close this way.
pub fn closeCo(l: *Thread, co: *Thread) ?Value {
    if (co.port) |p| {
        if (co.status == .suspended) {
            co.status = .dead;
            if (p.close) |c| c(l, co);
        }
        return null;
    }
    // An event coroutine of the runtime that waits inside its native while
    // its resumer blocks (the main chunk, or a plain coroutine) ends its
    // wait at once, and the resume returns false and "closed".
    if (co.event and co.status != .suspended and co.status != .dead and co.status != .err) {
        co.event_closed = true;
        if (sched.taskOf(co)) |t| sched.interruptWait(l.g, t);
        return null;
    }
    switch (co.status) {
        .suspended, .dead, .err => {},
        else => return null,
    }
    // A detached coroutine that has not ended leaves the scheduler first.
    if (sched.taskOf(co)) |t| {
        if (t.detached) sched.cancel(l.g, t);
    }
    return closeThread(co);
}

// ---------------------------------------------------------------------
// for x in co

const iter_key = "coroutine.iterate";

/// Sets up the generic for at `r` whose iterator is the coroutine in
/// `R[r]`: the iterator becomes the native that resumes it, the state is
/// the coroutine, and so is the closing value, so the loop closes the
/// coroutine when it ends early.
pub fn forPrep(l: *Thread, r: u32) Error!void {
    const g = l.g;
    const it: Value = if (g.ext.get(iter_key)) |p| Value.obj(.native, @as(*state.Native, @ptrCast(@alignCast(p)))) else blk: {
        const v = try aux.native(l, iterate, "iterate");
        try l.push(v);
        defer l.top -= 1;
        try aux.setField(l, g.registry.as(object.Table), iter_key, v);
        g.ext.put(g.gpa, iter_key, v.as(state.Native)) catch return l.raiseMem();
        break :blk v;
    };
    const co = l.stack[r];
    l.stack[r] = it;
    l.stack[r + 1] = co;
    l.stack[r + 2] = .nil;
    if (l.stack[r + 3].isNil()) l.stack[r + 3] = co;
}

/// The iterator of a loop over a coroutine: resumes it with no values.
/// The values it yields are the values of the loop variables. When it
/// ends, the loop ends, and the values it returned are dropped. An error
/// in the coroutine closes it and leaves the loop with that error.
fn iterate(l: *Thread) Error!u32 {
    if (l.arg(1).tag != .thread) return aux.typeError(l, 1, "coroutine");
    const co = l.arg(1).as(Thread);
    // The control value stays out of the resume, so a port sees no
    // arguments and reads with its defaults.
    l.top = l.base() + 1;
    const n = resumeCo(l, co, 0) catch {
        if (passes(l)) return error.LusError;
        var err = l.err;
        if (co.status == .err) err = closeThread(co) orelse err;
        return l.raise(err);
    };
    if (co.status == .dead) {
        l.top -= n;
        return 0;
    }
    return n;
}

/// coroutine.detach(co, ...): hands the suspended coroutine `co` to the
/// scheduler, which resumes it with the extra arguments and then
/// whenever what it waits for is ready. Returns `co`.
fn detach(l: *Thread) Error!u32 {
    const co = try checkCo(l, 1);
    if (co == l.g.main_thread) return l.raiseFmt("cannot detach the main thread", .{});
    if (sched.taskOf(co)) |t| {
        if (t.detached) return l.raiseFmt("cannot detach a detached coroutine", .{});
    }
    if (co == l or co.status != .suspended) return l.raiseFmt("cannot detach a {s} coroutine", .{statusName(l, co)});
    const nargs = l.argCount() - 1;
    var entry: sched.Entry = if (co.frames.items.len == 0) .fresh else .results;
    var n = nargs;
    if (waiting(co)) {
        if (co.resumer) |r| {
            if (sched.awaits(r, co)) return l.raiseFmt("cannot detach a normal coroutine", .{});
        }
        entry = .restart;
        n = 0;
    }
    // Both calls raise on the coroutine, so their errors move to `l`.
    const t = sched.ensureTask(co) catch return l.raise(co.err);
    co.ensure(n + 1) catch return l.raise(co.err);
    const src = l.base() + 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) co.stack[co.top + i] = l.stack[src + i];
    co.top += n;
    co.resumer = null;
    sched.attach(l.g, t, entry, n);
    l.top = l.base() + 1;
    return 1;
}
