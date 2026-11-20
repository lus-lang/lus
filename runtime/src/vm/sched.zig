//! The scheduler of a state (`spec/design/coroutines.md`). It runs the
//! coroutines that `coroutine.detach` handed to the runtime: a run queue
//! in arrival order, a heap of deadlines on the monotonic clock, and a
//! poller that reports sockets that became readable or writable.
//!
//! A native that would block names what it waits for and suspends its
//! thread (`waitIo`, `waitJoin`). The thread unwinds to `resume` the way a
//! yield does, with the frame of the native left in place. When the event
//! arrives the interpreter calls the native again with the same arguments
//! (`interp.restartNative`). A thread whose chain of resumers does not end
//! in a detached coroutine keeps its native on the stack, and the native
//! runs the scheduler itself until its event arrives.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;
const Value = value.Value;
const posix = std.posix;

const os = builtin.os.tag;
const is_windows = os == .windows;
const is_wasi = os == .wasi;

/// What the poller watches: a socket.
pub const Handle = std.Io.net.Socket.Handle;
pub const Dir = enum(u1) { read, write };

/// What a thread waits for. `inner` is a thread whose `coroutine.resume`
/// waits for the coroutine it resumed, which waits in turn. `pass` is a
/// native that lets the other coroutines run and continues on its next
/// turn.
pub const Kind = enum(u8) { none, io, join, inner, pass };

/// Why a waiting native runs again.
pub const Wake = enum(u8) { none, ready, timeout };

/// Where a detached coroutine is.
pub const Place = enum(u8) { none, queued, waiting, running, done };

/// How a detached coroutine ended.
pub const Outcome = enum(u8) { pending, returned, failed, cancelled };

/// How the next run of a coroutine starts: by calling its function, by
/// finishing its pending `yield` with the values on its stack, or by
/// calling the native it waits in again.
pub const Entry = enum(u8) { fresh, results, restart };

const no_timer = std.math.maxInt(u32);

/// The scheduler record of a thread. A thread gets one when it first
/// waits or when it is detached, and keeps it until it is freed.
pub const Task = struct {
    thread: *Thread,

    // What the thread itself waits for.
    kind: Kind = .none,
    dir: Dir = .read,
    handle: Handle = undefined,
    /// The time on the monotonic clock at which the wait gives up, in
    /// nanoseconds, or zero.
    deadline: u64 = 0,
    /// The coroutine a `join` waits for, or the coroutine an `inner`
    /// wait resumed.
    target: ?*Thread = null,
    /// Set before the native runs again, and read through `waitIo`.
    wake: Wake = .none,
    /// True while `interp.restartNative` runs the native again.
    restarted: bool = false,
    /// The stack top above the base of the native frame when it waited.
    saved_top: u32 = 0,
    /// What the native keeps across its runs: a count and a pointer with
    /// the routine that releases it when the wait is abandoned.
    progress: usize = 0,
    ctx: ?*anyopaque = null,
    cancel: ?*const fn (g: *Global, ctx: *anyopaque) void = null,

    // The registration of a thread the scheduler wakes: a detached
    // coroutine, or a thread whose native runs the scheduler.
    reg: Kind = .none,
    reg_dir: Dir = .read,
    reg_handle: Handle = undefined,
    reg_target: ?*Task = null,
    timer: u32 = no_timer,
    /// True for a thread whose native runs the scheduler while it waits.
    /// An event only sets `wake` on it.
    driver: bool = false,
    /// Links of the run queue or of a list of waiters.
    prev: ?*Task = null,
    next: ?*Task = null,

    // A detached coroutine.
    detached: bool = false,
    place: Place = .none,
    entry: Entry = .fresh,
    outcome: Outcome = .pending,
    /// True once a `coroutine.resume` received the results or the error.
    collected: bool = false,
    /// Arguments on the stack for the next run.
    nargs: u32 = 0,
    /// Results kept at the top of the stack of a finished coroutine.
    nres: u32 = 0,
    /// Waiters that were woken by the end of this coroutine and have not
    /// read its results yet.
    fin_waiters: u32 = 0,
    joiners: List = .{},
    live_prev: ?*Task = null,
    live_next: ?*Task = null,
};

const List = struct {
    head: ?*Task = null,
    tail: ?*Task = null,

    fn append(q: *List, t: *Task) void {
        t.next = null;
        t.prev = q.tail;
        if (q.tail) |last| last.next = t else q.head = t;
        q.tail = t;
    }

    fn prepend(q: *List, t: *Task) void {
        t.prev = null;
        t.next = q.head;
        if (q.head) |first| first.prev = t else q.tail = t;
        q.head = t;
    }

    fn remove(q: *List, t: *Task) void {
        if (t.prev) |p| p.next = t.next else q.head = t.next;
        if (t.next) |n| n.prev = t.prev else q.tail = t.prev;
        t.prev = null;
        t.next = null;
    }

    fn pop(q: *List) ?*Task {
        const t = q.head orelse return null;
        q.remove(t);
        return t;
    }
};

const Timer = struct { deadline: u64, task: *Task };

const IoEntry = struct {
    waiters: List = .{},
    /// True while the poller of the system watches this handle.
    registered: bool = false,
};

pub const Sched = struct {
    queue: List = .{},
    queued: usize = 0,
    /// Every detached coroutine that has not ended. The collector treats
    /// them as roots.
    live: ?*Task = null,
    nlive: usize = 0,
    timers: std.ArrayList(Timer) = .empty,
    ios: std.AutoHashMapUnmanaged(usize, IoEntry) = .empty,
    io_waiters: usize = 0,
    poller: Poller = .{},
    /// Set while the error of a detached coroutine that nothing collected
    /// stops the program. No handler catches an error while it is set.
    fatal: bool = false,
    /// Set while the state closes.
    closing: bool = false,
    /// Set once the state released the scheduler.
    released: bool = false,
    /// Set once `enableNotify` gave other threads a way to wake the
    /// scheduler. A scheduler with nothing else to wait for then waits
    /// for them.
    notified: bool = false,
};

pub inline fn taskOf(l: *Thread) ?*Task {
    return l.task;
}

pub fn ensureTask(l: *Thread) Error!*Task {
    if (l.task) |t| return t;
    const t = l.g.gpa.create(Task) catch return l.raiseMem();
    t.* = .{ .thread = l };
    l.task = t;
    return t;
}

/// The monotonic clock, in nanoseconds.
pub fn now(g: *Global) u64 {
    const ns = std.Io.Clock.awake.now(g.io).nanoseconds;
    return if (ns <= 0) 1 else @intCast(@min(ns, std.math.maxInt(u64)));
}

/// True while detached coroutines exist.
pub inline fn active(g: *Global) bool {
    return g.sched.nlive > 0;
}

/// The number of detached coroutines that have not ended.
pub fn pending(g: *Global) usize {
    return g.sched.nlive;
}

// ---------------------------------------------------------------------
// Waiting

/// True when `l` can suspend at a blocking operation: no native call
/// holds its stack, and every thread from it to a detached coroutine was
/// resumed by a `coroutine.resume` that passes the wait on.
pub fn canSuspend(l: *Thread) bool {
    var t = l;
    var expect: u32 = 0;
    while (true) {
        if (t.ncalls != expect) return false;
        if (t.task) |k| {
            if (k.detached) return k.place == .running;
        }
        if (!t.resumer_passes) return false;
        t = t.resumer orelse return false;
        expect = 1;
    }
}

/// Suspends `l` inside its running native, which already described the
/// wait in `t`. The error it returns unwinds to `resume` like a yield.
pub fn suspendThread(l: *Thread, t: *Task) Error {
    t.saved_top = l.top - l.base();
    l.transfer = 0;
    l.yielding = true;
    l.status = .suspended;
    return error.LusError;
}

/// True when the scheduler is running the native of `l` again.
pub inline fn restarted(l: *Thread) bool {
    return if (l.task) |t| t.restarted else false;
}

/// The count that the native of `l` saved before it waited, or zero in
/// its first run.
pub inline fn progress(l: *Thread) usize {
    return if (l.task) |t| (if (t.restarted) t.progress else 0) else 0;
}

/// Saves a count for the next run of the native of `l`.
pub fn saveProgress(l: *Thread, n: usize) Error!void {
    (try ensureTask(l)).progress = n;
}

/// Waits until `handle` is readable or writable, for at most
/// `timeout_ms` milliseconds when that is positive. A zero timeout
/// never waits. Returns true when the handle is ready and false when the
/// time ran out. In a thread that can suspend, it returns the error that
/// suspends the thread, and the native that runs again calls it again if
/// its operation still would block.
pub fn waitIo(l: *Thread, handle: Handle, dir: Dir, timeout_ms: i32) Error!bool {
    const g = l.g;
    if (timeout_ms == 0) return false;
    if (l.task) |t| {
        if (t.restarted and t.wake == .timeout) {
            t.wake = .none;
            return false;
        }
        t.wake = .none;
    }
    if (!active(g)) {
        // No coroutine could run in the meantime.
        return pollOne(handle, dir, timeout_ms);
    }
    const t = try ensureTask(l);
    t.kind = .io;
    t.handle = handle;
    t.dir = dir;
    t.target = null;
    t.deadline = if (timeout_ms > 0) now(g) + @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms else 0;
    if (canSuspend(l)) return suspendThread(l, t);
    return block(l, t);
}

/// Waits until the detached coroutine `co` ends. Returns when it has
/// ended, or the error that suspends the thread.
pub fn waitJoin(l: *Thread, co: *Thread) Error!void {
    const t = try ensureTask(l);
    t.wake = .none;
    t.kind = .join;
    t.target = co;
    t.deadline = 0;
    if (canSuspend(l)) return suspendThread(l, t);
    _ = try block(l, t);
}

/// Lets the coroutines that are ready run before the native of `l`
/// continues. In a thread that can suspend it returns the error that
/// suspends the thread, and the native runs again on its next turn.
pub fn pass(l: *Thread) Error!void {
    const g = l.g;
    if (!active(g)) return;
    if (canSuspend(l)) {
        const t = try ensureTask(l);
        t.kind = .pass;
        t.target = null;
        t.deadline = 0;
        return suspendThread(l, t);
    }
    try step(g, l, false);
}

/// True when the native of `l` runs again because the coroutine `co` it
/// waited for ended.
pub fn joined(l: *Thread, co: *Thread) bool {
    const t = l.task orelse return false;
    return t.kind == .join and t.target == co and t.wake == .ready;
}

/// Runs the scheduler from the native of `l` until the wait described in
/// `t` ends. Returns false when its time ran out.
fn block(l: *Thread, t: *Task) Error!bool {
    const g = l.g;
    t.driver = true;
    t.wake = .none;
    register(g, t, t);
    while (t.wake == .none) {
        step(g, l, true) catch |e| {
            unregister(g, t);
            t.driver = false;
            t.kind = .none;
            t.target = null;
            return e;
        };
    }
    const ready = t.wake == .ready;
    t.driver = false;
    if (t.kind != .join) {
        t.wake = .none;
        t.kind = .none;
        t.target = null;
    }
    return ready;
}

/// Forgets what the thread of `t` waited for, once its native returned
/// or its wait is abandoned.
pub fn clearWait(g: *Global, t: *Task) void {
    if (t.ctx) |ctx| {
        t.ctx = null;
        if (t.cancel) |f| f(g, ctx);
    }
    t.cancel = null;
    t.kind = .none;
    t.target = null;
    t.wake = .none;
    t.deadline = 0;
    t.progress = 0;
    t.restarted = false;
}

/// True when `r` waits for the coroutine `co` that it resumed.
pub fn awaits(r: *Thread, co: *Thread) bool {
    const t = r.task orelse return false;
    return t.kind == .inner and t.target == co and r.status == .suspended;
}

/// Abandons the wait of a thread that is closed while it waits. The
/// detached coroutine that waits through it runs again and finds it
/// closed.
pub fn abandonWait(co: *Thread) void {
    const g = co.g;
    const t = co.task orelse return;
    if (t.kind == .none and t.ctx == null) return;
    var cur = co;
    while (cur.resumer) |r| {
        if (!awaits(r, cur)) break;
        cur = r;
    }
    if (cur != co) {
        if (cur.task) |root| {
            if (root.reg != .none) wake(g, root, .ready);
        }
    }
    clearWait(g, t);
}

// ---------------------------------------------------------------------
// Registration

inline fn handleBits(h: Handle) usize {
    return if (is_windows) @intFromPtr(h) else @intCast(h);
}

inline fn ioKey(h: Handle, dir: Dir) usize {
    return (handleBits(h) << 1) | @backingInt(dir);
}

fn leafOf(r: *Task) *Task {
    var t = r;
    while (t.kind == .inner) {
        const child = t.target orelse break;
        t = child.task orelse break;
    }
    return t;
}

/// Records what the thread of `r` waits for, which `leaf` describes.
fn register(g: *Global, r: *Task, leaf: *Task) void {
    const s = &g.sched;
    switch (leaf.kind) {
        .io => {
            const key = ioKey(leaf.handle, leaf.dir);
            const gop = s.ios.getOrPut(g.gpa, key) catch return wakeNow(g, r);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (!s.poller.arm(g, leaf.handle, leaf.dir, gop.value_ptr)) {
                if (!Poller.persistent and gop.value_ptr.waiters.head == null) _ = s.ios.remove(key);
                return wakeNow(g, r);
            }
            gop.value_ptr.waiters.append(r);
            s.io_waiters += 1;
            r.reg = .io;
            r.reg_handle = leaf.handle;
            r.reg_dir = leaf.dir;
        },
        .join => {
            const target = if (leaf.target) |co| co.task else null;
            const tt = target orelse return wakeNow(g, r);
            if (tt.place == .done) return wakeNow(g, r);
            tt.joiners.append(r);
            r.reg = .join;
            r.reg_target = tt;
        },
        .none, .inner, .pass => return wakeNow(g, r),
    }
    if (leaf.deadline != 0) addTimer(g, r, leaf.deadline);
    if (r.detached) r.place = .waiting;
}

/// Wakes a thread whose wait could not be recorded. Its native runs
/// again and reports what its operation reports.
fn wakeNow(g: *Global, r: *Task) void {
    leafOf(r).wake = .ready;
    if (r.driver) return;
    enqueue(g, r, .restart);
}

fn unregister(g: *Global, r: *Task) void {
    const s = &g.sched;
    switch (r.reg) {
        .none, .inner, .pass => {},
        .io => {
            const key = ioKey(r.reg_handle, r.reg_dir);
            if (s.ios.getPtr(key)) |e| {
                e.waiters.remove(r);
                s.io_waiters -= 1;
                if (!Poller.persistent and e.waiters.head == null) _ = s.ios.remove(key);
            }
        },
        .join => if (r.reg_target) |tt| tt.joiners.remove(r),
    }
    r.reg = .none;
    r.reg_target = null;
    if (r.timer != no_timer) removeTimer(s, r.timer);
}

fn enqueue(g: *Global, t: *Task, entry: Entry) void {
    t.entry = entry;
    t.place = .queued;
    g.sched.queue.append(t);
    g.sched.queued += 1;
}

/// Ends the wait of `r` with `w`.
fn wake(g: *Global, r: *Task, w: Wake) void {
    unregister(g, r);
    leafOf(r).wake = w;
    if (r.driver) return;
    enqueue(g, r, .restart);
}

fn wakeIo(g: *Global, key: usize) void {
    while (true) {
        const e = g.sched.ios.getPtr(key) orelse return;
        const t = e.waiters.head orelse return;
        wake(g, t, .ready);
    }
}

/// Wakes every thread that waits for a handle, after the poller failed.
/// Each native then runs its operation again and reports its own error.
fn wakeAllIo(g: *Global) void {
    const s = &g.sched;
    var it = s.ios.valueIterator();
    while (it.next()) |e| e.registered = false;
    while (s.io_waiters > 0) {
        var keys = s.ios.iterator();
        const key = while (keys.next()) |e| {
            if (e.value_ptr.waiters.head != null) break e.key_ptr.*;
        } else return;
        wakeIo(g, key);
    }
}

/// Tells the scheduler that `handle` is about to close. Threads that wait
/// for it run again and find the closed socket.
pub fn forget(g: *Global, handle: Handle) void {
    const s = &g.sched;
    if (s.released) return;
    var seen = false;
    for ([_]Dir{ .read, .write }) |dir| {
        const key = ioKey(handle, dir);
        if (s.ios.getPtr(key)) |e| {
            seen = seen or e.registered;
            wakeIo(g, key);
            _ = s.ios.remove(key);
        }
    }
    if (seen) s.poller.forget(handle);
}

// ---------------------------------------------------------------------
// Timers: a binary heap ordered by deadline. Each task knows its index,
// so a wait that ends early removes its deadline.

fn addTimer(g: *Global, t: *Task, deadline: u64) void {
    const s = &g.sched;
    s.timers.append(g.gpa, .{ .deadline = deadline, .task = t }) catch return;
    t.timer = @intCast(s.timers.items.len - 1);
    siftUp(s, t.timer);
}

fn setTimer(s: *Sched, i: u32, e: Timer) void {
    s.timers.items[i] = e;
    e.task.timer = i;
}

fn siftUp(s: *Sched, start: u32) void {
    var i = start;
    const e = s.timers.items[i];
    while (i > 0) {
        const parent = (i - 1) / 2;
        const p = s.timers.items[parent];
        if (p.deadline <= e.deadline) break;
        setTimer(s, i, p);
        i = parent;
    }
    setTimer(s, i, e);
}

fn siftDown(s: *Sched, start: u32) void {
    const items = s.timers.items;
    const n: u32 = @intCast(items.len);
    var i = start;
    const e = items[i];
    while (true) {
        var child = 2 * i + 1;
        if (child >= n) break;
        if (child + 1 < n and items[child + 1].deadline < items[child].deadline) child += 1;
        if (e.deadline <= items[child].deadline) break;
        setTimer(s, i, items[child]);
        i = child;
    }
    setTimer(s, i, e);
}

fn removeTimer(s: *Sched, i: u32) void {
    const removed = s.timers.items[i].task;
    const last = s.timers.pop().?;
    removed.timer = no_timer;
    if (i == s.timers.items.len) return;
    setTimer(s, i, last);
    siftDown(s, i);
    siftUp(s, last.task.timer);
}

fn fireTimers(g: *Global) void {
    const s = &g.sched;
    if (s.timers.items.len == 0) return;
    const t = now(g);
    while (s.timers.items.len > 0 and s.timers.items[0].deadline <= t) {
        wake(g, s.timers.items[0].task, .timeout);
    }
}

// ---------------------------------------------------------------------
// Detached coroutines

fn linkLive(s: *Sched, t: *Task) void {
    t.live_prev = null;
    t.live_next = s.live;
    if (s.live) |h| h.live_prev = t;
    s.live = t;
    s.nlive += 1;
}

fn unlinkLive(s: *Sched, t: *Task) void {
    if (t.live_prev) |p| p.live_next = t.live_next else s.live = t.live_next;
    if (t.live_next) |n| n.live_prev = t.live_prev;
    t.live_prev = null;
    t.live_next = null;
    s.nlive -= 1;
}

/// Hands the suspended coroutine of `t` to the scheduler. Its stack holds
/// `nargs` values for its first run.
pub fn attach(g: *Global, t: *Task, entry: Entry, nargs: u32) void {
    t.detached = true;
    t.outcome = .pending;
    t.collected = false;
    t.nargs = nargs;
    linkLive(&g.sched, t);
    enqueue(g, t, entry);
}

/// Ends the detached coroutine of `t` and wakes the threads that wait for
/// it.
fn finish(g: *Global, t: *Task, outcome: Outcome) void {
    t.place = .done;
    t.outcome = outcome;
    unlinkLive(&g.sched, t);
    while (t.joiners.head) |j| {
        t.fin_waiters += 1;
        wake(g, j, .ready);
    }
}

/// Takes a detached coroutine that has not ended out of the scheduler, so
/// that `coroutine.close` can close it.
pub fn cancel(g: *Global, t: *Task) void {
    const s = &g.sched;
    switch (t.place) {
        .queued => {
            s.queue.remove(t);
            s.queued -= 1;
        },
        .waiting => unregister(g, t),
        .none, .running, .done => return,
    }
    t.collected = true;
    finish(g, t, .cancelled);
}

/// The detached coroutine `co` when it failed and nothing received its
/// error.
pub fn uncollected(co: *Thread) ?*Task {
    const t = co.task orelse return null;
    if (t.detached and t.outcome == .failed and !t.collected) return t;
    return null;
}

/// Runs the detached coroutine of `t` from the thread `l` until it ends,
/// yields, or waits.
fn runTask(g: *Global, l: *Thread, t: *Task) Error!void {
    const s = &g.sched;
    const co = t.thread;
    if (l.ncalls >= Thread.max_ncalls or g.native_depth >= Thread.max_ncalls) {
        t.place = .queued;
        s.queue.prepend(t);
        s.queued += 1;
        return l.raiseFmt("C stack overflow", .{});
    }
    t.place = .running;
    const nargs = t.nargs;
    t.nargs = 0;
    const coroutine = @import("../lib/coroutine.zig");
    switch (coroutine.runDetached(l, co, t.entry, nargs)) {
        .yielded => {
            co.status = .suspended;
            if (t.kind != .none) {
                register(g, t, leafOf(t));
            } else {
                // A plain yield lets the other coroutines run. Its values
                // are dropped.
                co.top -= co.transfer;
                enqueue(g, t, .results);
            }
        },
        .returned => {
            co.status = .dead;
            t.nres = co.transfer;
            finish(g, t, .returned);
        },
        .failed => {
            co.status = .err;
            if (s.fatal or g.halting) {
                // The error stops the program, so it leaves through the
                // thread that runs the scheduler.
                t.collected = true;
                finish(g, t, .failed);
                return l.raise(co.err);
            }
            finish(g, t, .failed);
            // The collector reports the error if nothing collects it.
            if (co.hdr.finalize == .none) {
                if (g.finobj.append(g.gpa, &co.hdr)) |_| {
                    co.hdr.finalize = .pending;
                } else |_| {}
            }
        },
    }
}

/// Runs the coroutines that are ready, then waits for the next event
/// when `wait` is set and nothing is ready.
fn step(g: *Global, l: *Thread, wait: bool) Error!void {
    const s = &g.sched;
    var n = s.queued;
    while (n > 0) : (n -= 1) {
        const t = s.queue.pop() orelse break;
        s.queued -= 1;
        try runTask(g, l, t);
    }
    var timeout: ?u64 = null;
    // The coroutines that just ran may have ended the wait of the caller.
    const woken = if (l.task) |me| me.driver and me.wake != .none else false;
    if (s.queued > 0 or !wait or woken) {
        timeout = 0;
    } else if (s.timers.items.len > 0) {
        const d = s.timers.items[0].deadline;
        const t = now(g);
        timeout = if (d > t) d - t else 0;
    }
    if (timeout == null and s.io_waiters == 0 and !s.notified) {
        if (s.nlive == 0 and (l.task == null or !l.task.?.driver)) return;
        return l.raiseFmt("deadlock: every coroutine waits for another coroutine", .{});
    }
    if (s.io_waiters > 0 or s.notified or (timeout orelse 1) != 0) s.poller.wait(g, timeout);
    fireTimers(g);
}

/// Runs detached coroutines until none is left, as `lus` does after the
/// main chunk. Raises the error of a coroutine that failed when nothing
/// collected it.
pub fn drain(l: *Thread) Error!void {
    const g = l.g;
    while (g.sched.nlive > 0) try step(g, l, true);
    try reportUncollected(l);
}

/// Runs the detached coroutines that are ready and returns.
pub fn poll(l: *Thread) Error!void {
    const g = l.g;
    if (g.sched.nlive > 0) try step(g, l, false);
}

/// Raises the error of the first detached coroutine that failed with
/// nothing left to collect it, with the traceback of the coroutine in
/// `l.err_traceback`.
pub fn reportUncollected(l: *Thread) Error!void {
    const g = l.g;
    for ([_]*std.ArrayList(*gc.Header){ &g.finobj, &g.tobefnz }) |list| {
        for (list.items) |h| {
            if (h.tag != .thread) continue;
            const co = h.as(Thread);
            const t = uncollected(co) orelse continue;
            t.collected = true;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(g.gpa);
            @import("debug.zig").traceback(co, &buf, 0) catch {};
            l.err_traceback = state.newStringIn(g, buf.items) catch null;
            return l.raise(co.err);
        }
    }
}

/// Raises the error of the detached coroutine `co`, which the collector
/// found unreachable before anything collected the error. The error
/// stops the program: no handler catches it.
pub fn raiseUncollected(l: *Thread, t: *Task) Error {
    const g = l.g;
    const co = t.thread;
    t.collected = true;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g.gpa);
    const msg = @import("../api.zig").errorMessage(l, co.err);
    buf.appendSlice(g.gpa, msg) catch return l.raiseMem();
    buf.append(g.gpa, '\n') catch return l.raiseMem();
    @import("debug.zig").traceback(co, &buf, 0) catch {};
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') buf.items.len -= 1;
    const s = state.newStringIn(g, buf.items) catch return l.raise(co.err);
    g.sched.fatal = true;
    return l.raise(Value.obj(.string, s));
}

// ---------------------------------------------------------------------
// Waking the scheduler from another thread

/// Gives other threads a way to wake the scheduler of `g` while it waits
/// in its poller: an EVFILT_USER event of kqueue, an eventfd of epoll, or
/// a pipe. The thread that owns the state calls this once. Returns false
/// on a system without such a source.
pub fn enableNotify(g: *Global) bool {
    const s = &g.sched;
    if (s.notified) return true;
    if (!s.poller.enableWake(g)) return false;
    s.notified = true;
    return true;
}

/// Wakes the scheduler of `g` from any thread, after `enableNotify`. The
/// poller returns from its wait, and the scheduler looks at its queues
/// again.
pub fn notify(g: *Global) void {
    g.sched.poller.wake();
}

// ---------------------------------------------------------------------
// The collector and the end of the state

/// Detached coroutines that have not ended are roots.
pub fn markRoots(g: *Global, m: anytype) void {
    var t = g.sched.live;
    while (t) |task| : (t = task.live_next) m.mark(Value.obj(.thread, task.thread));
}

/// Releases the record of a thread that the collector frees.
pub fn threadFreed(g: *Global, l: *Thread) void {
    const t = l.task orelse return;
    l.task = null;
    const s = &g.sched;
    if (!s.released) {
        if (t.reg != .none or t.timer != no_timer) unregister(g, t);
        if (t.place == .queued) {
            s.queue.remove(t);
            s.queued -= 1;
        }
        if (t.detached and t.place != .done and t.place != .none) unlinkLive(s, t);
    }
    if (t.ctx) |ctx| {
        if (t.cancel) |f| f(g, ctx);
    }
    g.gpa.destroy(t);
}

/// Closes every detached coroutine that has not ended, which runs their
/// pending to-be-closed variables. A state does this when it closes.
pub fn closeAll(g: *Global) void {
    const s = &g.sched;
    s.closing = true;
    const coroutine = @import("../lib/coroutine.zig");
    var rounds: usize = 0;
    while (s.live) |t| : (rounds += 1) {
        if (rounds > 1_000_000) break;
        if (t.place == .running) {
            // The state closes from inside this coroutine.
            unlinkLive(s, t);
            continue;
        }
        cancel(g, t);
        coroutine.closeCancelled(t.thread);
    }
    release(g);
}

/// Ends the bookkeeping of the scheduler, before the heap is freed.
pub fn release(g: *Global) void {
    g.sched.released = true;
}

/// Frees what the scheduler holds. No coroutine runs afterwards.
pub fn deinit(g: *Global) void {
    const s = &g.sched;
    s.poller.deinit(g);
    s.timers.deinit(g.gpa);
    s.ios.deinit(g.gpa);
}

// ---------------------------------------------------------------------
// Pollers

/// Waits on one handle without the poller of the scheduler, for a thread
/// that blocks while no detached coroutine exists.
fn pollOne(handle: Handle, dir: Dir, timeout_ms: i32) bool {
    if (is_windows or is_wasi) return true;
    var fds = [_]posix.pollfd{.{
        .fd = handle,
        .events = if (dir == .write) posix.POLL.OUT else posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms) catch return true;
    return n != 0;
}

/// True when `handle` is readable or writable now.
pub fn readyNow(handle: Handle, dir: Dir) bool {
    if (is_wasi) return true;
    if (is_windows) {
        var fds = [_]WsaPoll.Fd{.{ .fd = @intFromPtr(handle), .events = if (dir == .write) WsaPoll.wrnorm else WsaPoll.rdnorm, .revents = 0 }};
        return WsaPoll.WSAPoll(&fds, 1, 0) != 0;
    }
    return pollOne(handle, dir, 0);
}

const Poller = switch (os) {
    .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => Kqueue,
    .linux => Epoll,
    .windows => WsaPoll,
    .wasi => WasiClock,
    else => PosixPoll,
};

fn timespecOf(ns: u64) posix.timespec {
    return .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
}

fn millisOf(timeout: ?u64) i32 {
    const ns = timeout orelse return -1;
    const ms = (ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

/// kqueue. A handle is registered once per direction, with EV_CLEAR, and
/// stays registered until it closes. An event is then an edge: a native
/// waits only after its operation reported that it would block, so the
/// next edge always follows. Registrations collect in a change list that
/// the next `kevent` call submits together with the wait.
const Kqueue = struct {
    const persistent = true;
    const c = std.c;
    const max_changes = 64;

    kq: posix.fd_t = -1,
    /// The change list, allocated with the queue. A state that never
    /// waits for a socket holds neither.
    changes: []c.Kevent = &.{},
    nchanges: usize = 0,

    fn open(p: *Kqueue, g: *Global) bool {
        if (p.kq >= 0) return true;
        const list = g.gpa.alloc(c.Kevent, max_changes) catch return false;
        const fd = c.kqueue();
        if (fd < 0) {
            g.gpa.free(list);
            return false;
        }
        _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        p.changes = list;
        p.kq = fd;
        return true;
    }

    fn change(handle: Handle, dir: Dir, flags: u16) c.Kevent {
        return .{
            .ident = @intCast(handle),
            .filter = if (dir == .write) c.EVFILT.WRITE else c.EVFILT.READ,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
    }

    fn arm(p: *Kqueue, g: *Global, handle: Handle, dir: Dir, e: *IoEntry) bool {
        if (e.registered) return true;
        if (!p.open(g)) return false;
        if (p.nchanges == max_changes) p.flush(g);
        p.changes[p.nchanges] = change(handle, dir, c.EV.ADD | c.EV.CLEAR);
        p.nchanges += 1;
        e.registered = true;
        return true;
    }

    /// Submits the change list without waiting.
    fn flush(p: *Kqueue, g: *Global) void {
        p.wait(g, 0);
    }

    fn wait(p: *Kqueue, g: *Global, timeout: ?u64) void {
        if (!p.open(g)) return wakeAllIo(g);
        var ts: posix.timespec = undefined;
        const tsp: ?*const posix.timespec = if (timeout) |ns| blk: {
            ts = timespecOf(ns);
            break :blk &ts;
        } else null;
        var events: [64]c.Kevent = undefined;
        const n = c.kevent(p.kq, p.changes.ptr, @intCast(p.nchanges), &events, events.len, tsp);
        p.nchanges = 0;
        if (n < 0) {
            if (posix.errno(n) == .INTR) return;
            return wakeAllIo(g);
        }
        for (events[0..@intCast(n)]) |ev| {
            if (ev.filter != c.EVFILT.READ and ev.filter != c.EVFILT.WRITE) continue;
            const key = (ev.ident << 1) | @intFromBool(ev.filter == c.EVFILT.WRITE);
            if (ev.flags & c.EV.ERROR != 0) {
                // The registration failed. The native runs again and
                // reports the error of its own operation.
                if (g.sched.ios.getPtr(key)) |e| e.registered = false;
            }
            wakeIo(g, key);
        }
    }

    fn enableWake(p: *Kqueue, g: *Global) bool {
        if (!p.open(g)) return false;
        var add = [_]c.Kevent{.{ .ident = 0, .filter = c.EVFILT.USER, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 }};
        var none: [1]c.Kevent = undefined;
        const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
        return c.kevent(p.kq, &add, 1, &none, 0, &zero) == 0;
    }

    /// Triggers the user event. `kevent` may be called from any thread.
    fn wake(p: *Kqueue) void {
        var trigger = [_]c.Kevent{.{ .ident = 0, .filter = c.EVFILT.USER, .flags = 0, .fflags = c.NOTE.TRIGGER, .data = 0, .udata = 0 }};
        var none: [1]c.Kevent = undefined;
        const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
        _ = c.kevent(p.kq, &trigger, 1, &none, 0, &zero);
    }

    fn forget(p: *Kqueue, handle: Handle) void {
        var keep: usize = 0;
        for (p.changes[0..p.nchanges]) |ch| {
            if (ch.ident == @as(usize, @intCast(handle))) continue;
            p.changes[keep] = ch;
            keep += 1;
        }
        p.nchanges = keep;
        if (p.kq < 0) return;
        var del = [_]c.Kevent{ change(handle, .read, c.EV.DELETE), change(handle, .write, c.EV.DELETE) };
        var none: [1]c.Kevent = undefined;
        const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
        _ = c.kevent(p.kq, del[0..1].ptr, 1, &none, 0, &zero);
        _ = c.kevent(p.kq, del[1..2].ptr, 1, &none, 0, &zero);
    }

    fn deinit(p: *Kqueue, g: *Global) void {
        if (p.kq >= 0) _ = c.close(p.kq);
        if (p.changes.len > 0) g.gpa.free(p.changes);
        p.changes = &.{};
        p.nchanges = 0;
        p.kq = -1;
    }
};

/// epoll. A handle is registered once for both directions, edge
/// triggered, and stays registered until it closes.
const Epoll = struct {
    const persistent = true;
    const linux = std.os.linux;

    ep: posix.fd_t = -1,
    /// The eventfd that other threads write to, or -1.
    wake_fd: posix.fd_t = -1,

    fn enableWake(p: *Epoll, _: *Global) bool {
        if (p.wake_fd >= 0) return true;
        if (!p.open()) return false;
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return false;
        const fd: posix.fd_t = @intCast(rc);
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
        if (linux.errno(linux.epoll_ctl(p.ep, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) {
            _ = linux.close(fd);
            return false;
        }
        p.wake_fd = fd;
        return true;
    }

    fn wake(p: *Epoll) void {
        const one: u64 = 1;
        _ = linux.write(p.wake_fd, std.mem.asBytes(&one), 8);
    }

    fn open(p: *Epoll) bool {
        if (p.ep >= 0) return true;
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return false;
        p.ep = @intCast(rc);
        return true;
    }

    fn arm(p: *Epoll, g: *Global, handle: Handle, dir: Dir, e: *IoEntry) bool {
        if (e.registered) return true;
        if (!p.open()) return false;
        const other = g.sched.ios.getPtr(ioKey(handle, if (dir == .read) .write else .read));
        if (other == null or !other.?.registered) {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP | linux.EPOLL.ET,
                .data = .{ .fd = handle },
            };
            switch (linux.errno(linux.epoll_ctl(p.ep, linux.EPOLL.CTL_ADD, handle, &ev))) {
                .SUCCESS, .EXIST => {},
                else => return false,
            }
        }
        e.registered = true;
        return true;
    }

    fn wait(p: *Epoll, g: *Global, timeout: ?u64) void {
        if (!p.open()) return wakeAllIo(g);
        var events: [64]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(p.ep, &events, events.len, millisOf(timeout));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return,
            else => return wakeAllIo(g),
        }
        for (events[0..rc]) |ev| {
            const fd: Handle = ev.data.fd;
            if (fd == p.wake_fd) {
                var count: [8]u8 = undefined;
                _ = linux.read(fd, &count, 8);
                continue;
            }
            const bad = linux.EPOLL.HUP | linux.EPOLL.ERR;
            if (ev.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | bad) != 0) wakeIo(g, ioKey(fd, .read));
            if (ev.events & (linux.EPOLL.OUT | bad) != 0) wakeIo(g, ioKey(fd, .write));
        }
    }

    fn forget(p: *Epoll, handle: Handle) void {
        if (p.ep < 0) return;
        _ = linux.epoll_ctl(p.ep, linux.EPOLL.CTL_DEL, handle, null);
    }

    fn deinit(p: *Epoll, _: *Global) void {
        if (p.wake_fd >= 0) _ = linux.close(p.wake_fd);
        if (p.ep >= 0) _ = linux.close(p.ep);
        p.wake_fd = -1;
        p.ep = -1;
    }
};

/// Collects the handles that have waiters, for the pollers that take the
/// whole set on every call.
fn collectKeys(g: *Global, keys: *std.ArrayList(usize)) bool {
    var it = g.sched.ios.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.waiters.head == null) continue;
        keys.append(g.gpa, e.key_ptr.*) catch return false;
    }
    return true;
}

/// poll, for POSIX systems without a poller of their own.
const PosixPoll = struct {
    const persistent = false;

    /// The pipe that other threads write to, or -1.
    pipe: [2]posix.fd_t = .{ -1, -1 },

    fn arm(_: *PosixPoll, _: *Global, _: Handle, _: Dir, _: *IoEntry) bool {
        return true;
    }

    fn enableWake(p: *PosixPoll, _: *Global) bool {
        if (p.pipe[0] >= 0) return true;
        var fds: [2]posix.fd_t = undefined;
        if (posix.system.pipe(&fds) != 0) return false;
        for (fds) |fd| {
            _ = posix.system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
            const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
            const nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
            if (flags >= 0) _ = posix.system.fcntl(fd, posix.F.SETFL, flags | nonblock);
        }
        p.pipe = fds;
        return true;
    }

    fn wake(p: *PosixPoll) void {
        const one = [_]u8{1};
        _ = posix.system.write(p.pipe[1], &one, 1);
    }

    fn wait(p: *PosixPoll, g: *Global, timeout: ?u64) void {
        var keys: std.ArrayList(usize) = .empty;
        defer keys.deinit(g.gpa);
        if (!collectKeys(g, &keys)) return wakeAllIo(g);
        const fds = g.gpa.alloc(posix.pollfd, keys.items.len + 1) catch return wakeAllIo(g);
        defer g.gpa.free(fds);
        for (keys.items, fds[0..keys.items.len]) |key, *fd| {
            fd.* = .{ .fd = @intCast(key >> 1), .events = if (key & 1 != 0) posix.POLL.OUT else posix.POLL.IN, .revents = 0 };
        }
        // The pipe comes last. A negative descriptor is skipped by poll.
        fds[keys.items.len] = .{ .fd = p.pipe[0], .events = posix.POLL.IN, .revents = 0 };
        const n = posix.poll(fds, millisOf(timeout)) catch return wakeAllIo(g);
        if (n == 0) return;
        if (fds[keys.items.len].revents != 0) {
            var sink: [64]u8 = undefined;
            while (posix.system.read(p.pipe[0], &sink, sink.len) == sink.len) {}
        }
        for (keys.items, fds[0..keys.items.len]) |key, fd| {
            if (fd.revents != 0) wakeIo(g, key);
        }
    }

    fn forget(_: *PosixPoll, _: Handle) void {}

    fn deinit(p: *PosixPoll, _: *Global) void {
        for (p.pipe) |fd| {
            if (fd >= 0) _ = posix.system.close(fd);
        }
        p.pipe = .{ -1, -1 };
    }
};

/// WSAPoll. A call that fails wakes every waiter, and each operation
/// then blocks in its own system call.
const WsaPoll = struct {
    const persistent = false;
    const Fd = extern struct { fd: usize, events: i16, revents: i16 };
    const rdnorm: i16 = 0x0100;
    const wrnorm: i16 = 0x0010;
    extern "ws2_32" fn WSAPoll(fds: [*]Fd, nfds: u32, timeout: i32) callconv(.winapi) i32;

    fn arm(_: *WsaPoll, _: *Global, _: Handle, _: Dir, _: *IoEntry) bool {
        return true;
    }

    fn wait(_: *WsaPoll, g: *Global, timeout: ?u64) void {
        var keys: std.ArrayList(usize) = .empty;
        defer keys.deinit(g.gpa);
        if (!collectKeys(g, &keys)) return wakeAllIo(g);
        if (keys.items.len == 0) return;
        const fds = g.gpa.alloc(Fd, keys.items.len) catch return wakeAllIo(g);
        defer g.gpa.free(fds);
        for (keys.items, fds) |key, *fd| {
            fd.* = .{ .fd = key >> 1, .events = if (key & 1 != 0) wrnorm else rdnorm, .revents = 0 };
        }
        const n = WSAPoll(fds.ptr, @intCast(fds.len), millisOf(timeout));
        if (n < 0) return wakeAllIo(g);
        if (n == 0) return;
        for (keys.items, fds) |key, fd| {
            if (fd.revents != 0) wakeIo(g, key);
        }
    }

    fn enableWake(_: *WsaPoll, _: *Global) bool {
        return false;
    }
    fn wake(_: *WsaPoll) void {}
    fn forget(_: *WsaPoll, _: Handle) void {}
    fn deinit(_: *WsaPoll, _: *Global) void {}
};

/// WASI has no sockets here, so its poller only sleeps until the next
/// deadline, with a clock subscription of `poll_oneoff`.
const WasiClock = struct {
    const persistent = false;
    const wasi = std.os.wasi;

    fn arm(_: *WasiClock, _: *Global, _: Handle, _: Dir, _: *IoEntry) bool {
        return false;
    }

    fn wait(_: *WasiClock, _: *Global, timeout: ?u64) void {
        const ns = timeout orelse return;
        if (ns == 0) return;
        const sub: wasi.subscription_t = .{
            .userdata = 0,
            .u = .{ .tag = .CLOCK, .u = .{ .clock = .{ .id = .MONOTONIC, .timeout = ns, .precision = 0, .flags = 0 } } },
        };
        var event: wasi.event_t = undefined;
        var nevents: usize = 0;
        _ = wasi.poll_oneoff(&sub, &event, 1, &nevents);
    }

    fn enableWake(_: *WasiClock, _: *Global) bool {
        return false;
    }
    fn wake(_: *WasiClock) void {}
    fn forget(_: *WasiClock, _: Handle) void {}
    fn deinit(_: *WasiClock, _: *Global) void {}
};

test "timers fire in the order of their deadlines" {
    const g = try state.create(std.testing.allocator, std.testing.io);
    defer state.destroy(g);
    var tasks: [6]Task = undefined;
    const deadlines = [_]u64{ 50, 10, 40, 20, 60, 30 };
    for (&tasks, deadlines) |*t, d| {
        t.* = .{ .thread = g.main_thread, .driver = true };
        addTimer(g, t, d);
    }
    // A wait that ends early takes its deadline out of the heap.
    removeTimer(&g.sched, tasks[3].timer);
    try std.testing.expectEqual(no_timer, tasks[3].timer);
    var last: u64 = 0;
    var seen: usize = 0;
    while (g.sched.timers.items.len > 0) : (seen += 1) {
        const first = g.sched.timers.items[0];
        try std.testing.expect(first.deadline >= last);
        try std.testing.expectEqual(@as(u32, 0), first.task.timer);
        last = first.deadline;
        removeTimer(&g.sched, 0);
    }
    try std.testing.expectEqual(@as(usize, 5), seen);
    try std.testing.expectEqual(@as(u64, 60), last);
}

test "another thread wakes the poller" {
    if (is_windows or is_wasi) return;
    const g = try state.create(std.testing.allocator, std.testing.io);
    defer state.destroy(g);
    try std.testing.expect(enableNotify(g));
    const waker = try std.Thread.spawn(.{}, notify, .{g});
    // Without the wake this wait would last a minute.
    const start = now(g);
    g.sched.poller.wait(g, 60 * std.time.ns_per_s);
    waker.join();
    try std.testing.expect(now(g) - start < 30 * std.time.ns_per_s);
}
