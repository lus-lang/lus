//! Coroutines. Each coroutine is a thread with its own value stack and
//! frame list. Resuming runs the interpreter on that thread. Yielding
//! unwinds the interpreter back to `resume` while every frame stays in
//! place, so a later resume continues exactly where the yield happened.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const interp = @import("../vm/interp.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const aux = @import("aux.zig");
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
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
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
    co.stack[0] = f;
    co.top = 1;
    return co;
}

fn create(l: *Thread) Error!u32 {
    const f = try aux.checkFunction(l, 1);
    const co = try newCoroutine(l, f);
    return aux.ret(l, Value.obj(.thread, co));
}

/// Resumes `co` with `nargs` values taken from the top of `l`'s stack.
/// On success the yielded or returned values are moved to `l` and their
/// count is returned. On error, returns error.LusError with the error
/// value in `l.err` and `co` marked dead.
pub fn resumeCo(l: *Thread, co: *Thread, nargs: u32) Error!u32 {
    if (co.status != .suspended) {
        const what = switch (co.status) {
            .dead, .err => "cannot resume dead coroutine",
            .running => "cannot resume non-suspended coroutine",
            else => "cannot resume non-suspended coroutine",
        };
        l.top -= nargs;
        return l.raise(try l.newStringValue(what));
    }
    if (l.ncalls >= Thread.max_ncalls or l.g.native_depth >= Thread.max_ncalls) {
        l.top -= nargs;
        return l.raiseFmt("C stack overflow", .{});
    }
    // Move the arguments to the coroutine.
    co.ensure(nargs + 1) catch {
        l.top -= nargs;
        return l.raise(co.err);
    };
    const src = l.top - nargs;
    var i: u32 = 0;
    while (i < nargs) : (i += 1) co.stack[co.top + i] = l.stack[src + i];
    co.top += nargs;
    l.top = src;
    const fresh = co.frames.items.len == 0;
    co.status = .running;
    co.resumer = l;
    l.status = .normal;
    l.ncalls += 1;
    l.g.native_depth += 1;
    defer {
        l.ncalls -= 1;
        l.g.native_depth -= 1;
        l.status = .running;
    }
    const outcome = runCo(co, fresh, nargs);
    co.resumer = null;
    switch (outcome) {
        .yielded, .returned => {
            // Values at the top of the coroutine stack go back to `l`.
            const n = co.transfer;
            const from = co.top - n;
            try l.ensure(n + 1);
            i = 0;
            while (i < n) : (i += 1) l.stack[l.top + i] = co.stack[from + i];
            l.top += n;
            co.top = from;
            if (outcome == .returned) co.status = .dead else co.status = .suspended;
            return n;
        },
        .failed => {
            // The error stays on the coroutine until close() reports it.
            co.status = .err;
            return l.raise(co.err);
        },
    }
}

const Outcome = enum { yielded, returned, failed };

fn runCo(co: *Thread, fresh: bool, nargs: u32) Outcome {
    if (fresh) {
        const kind = interp.precall(co, 0, nargs, -1) catch |e| return handleStop(co, e);
        if (kind == .done) {
            co.transfer = co.top;
            return .returned;
        }
    } else {
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
    co.top = 0;
    co.status = .dead;
    co.err = .nil;
    return err;
}

fn @"resume"(l: *Thread) Error!u32 {
    const co = try checkCo(l, 1);
    const nargs = l.argCount() - 1;
    const n = resumeCo(l, co, nargs) catch {
        // A stopping worker unwinds through coroutines as well.
        if (l.g.halting) return error.LusError;
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

fn yield(l: *Thread) Error!u32 {
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
    const co = nat.upvalues()[0].as(Thread);
    const nargs = l.argCount();
    return resumeCo(l, co, nargs) catch {
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
    switch (co.status) {
        .suspended, .dead, .err => {},
        else => return l.raiseFmt("cannot close a {s} coroutine", .{statusName(l, co)}),
    }
    if (closeThread(co)) |err| {
        try l.push(.false);
        try l.push(err);
        return 2;
    }
    return aux.retBool(l, true);
}
