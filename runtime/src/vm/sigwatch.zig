//! Process-wide delivery of signals and child exits to the states that
//! wait for them (`os.signal`, the process objects of `os.spawn`).
//!
//! On POSIX systems a handler counts each signal and writes its number to
//! a pipe. A watcher thread reads the pipe and calls `sched.notify` for
//! every state that subscribed, so the natives that wait with
//! `sched.waitNotify` look at the counts again. The handler does nothing
//! else, which keeps it safe to run at any point of the program. On
//! Windows the console control handler and the wait callbacks of child
//! processes already run on threads of their own, and they notify the
//! states directly.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const sched = @import("sched.zig");
const Global = state.Global;

const windows = builtin.os.tag == .windows;
pub const supported = builtin.os.tag != .wasi and builtin.os.tag != .freestanding;
const posix = supported and !windows;

pub const Sig = enum(u8) {
    child,
    interrupt,
    terminate,
    hangup,

    pub fn name(s: Sig) []const u8 {
        return switch (s) {
            .child => "child",
            .interrupt => "interrupt",
            .terminate => "terminate",
            .hangup => "hangup",
        };
    }

    fn posixSig(s: Sig) std.posix.SIG {
        return switch (s) {
            .child => .CHLD,
            .interrupt => .INT,
            .terminate => .TERM,
            .hangup => .HUP,
        };
    }
};

const n_sigs = @typeInfo(Sig).@"enum".field_values.len;

/// How many times each signal arrived since the process started, modulo
/// 2^32. A 32-bit count works on every target that has threads, and a
/// waiter compares counts with wrapping subtraction.
var counts: [n_sigs]std.atomic.Value(u32) = @splat(.init(0));
/// How many open handlers each signal has. The runtime handles a signal
/// while this is above zero.
var handlers: [n_sigs]u32 = @splat(0);
/// Set when a wait delivered an interrupt, and cleared when a wait for an
/// interrupt starts. An interrupt that arrives while it is set ends the
/// program with status 130.
pub var handling_interrupt = std.atomic.Value(bool).init(false);

var lock_word: std.atomic.Mutex = .unlocked;
var subscribers: std.ArrayList(*Global) = .empty;
/// Child processes whose objects were collected before they ended. The
/// watcher reaps them when a child exits.
var orphans: std.ArrayList(i32) = .empty;
var started = false;
var pipe_fds: [2]i32 = .{ -1, -1 };
var saved: [n_sigs]if (posix) std.posix.Sigaction else void = undefined;

fn lock() void {
    while (!lock_word.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    lock_word.unlock();
}

/// The number of times `s` arrived so far.
pub fn count(s: Sig) u32 {
    return counts[@backingInt(s)].load(.acquire);
}

/// Makes `g` receive a `sched.notify` whenever a signal it may wait for
/// arrives. Called from the thread of `g`. Returns false when the
/// scheduler of `g` has no wake source.
pub fn subscribe(g: *Global) bool {
    if (!supported) return false;
    if (!sched.enableNotify(g)) return false;
    if (!start()) return false;
    lock();
    defer unlock();
    for (subscribers.items) |s| if (s == g) return true;
    subscribers.append(std.heap.page_allocator, g) catch return false;
    return true;
}

/// Removes `g`, as its state closes.
pub fn forget(g: *Global) void {
    if (!supported) return;
    lock();
    defer unlock();
    for (subscribers.items, 0..) |s, i| if (s == g) {
        _ = subscribers.swapRemove(i);
        return;
    };
}

/// Wakes every subscriber.
fn notifyAll() void {
    lock();
    defer unlock();
    for (subscribers.items) |g| sched.notify(g);
}

/// Records that `s` arrived and wakes the subscribers, from any thread
/// that may lock (never from a signal handler).
pub fn deliver(s: Sig) void {
    if (s == .interrupt and handling_interrupt.load(.acquire)) std.process.exit(130);
    _ = counts[@backingInt(s)].fetchAdd(1, .acq_rel);
    notifyAll();
}

// ---------------------------------------------------------------------
// POSIX

fn onSignal(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx;
    const errno_saved = std.c._errno().*;
    defer std.c._errno().* = errno_saved;
    const b: u8 = @intCast(@backingInt(sig));
    _ = std.c.write(pipe_fds[1], @ptrCast(&b), 1);
}

fn watcher() void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) {
            if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return;
        }
        for (buf[0..@intCast(n)]) |b| {
            inline for (comptime std.enums.values(Sig)) |s| {
                if (b == @backingInt(s.posixSig())) {
                    if (s == .child) reapOrphans();
                    deliver(s);
                }
            }
        }
    }
}

fn reapOrphans() void {
    lock();
    defer unlock();
    var i: usize = 0;
    while (i < orphans.items.len) {
        var st: c_int = 0;
        const r = std.c.waitpid(orphans.items[i], &st, std.c.W.NOHANG);
        if (r != 0) {
            _ = orphans.swapRemove(i);
        } else i += 1;
    }
}

/// Starts the watcher and installs the handler of child exits, once.
fn start() bool {
    if (!posix) return supported;
    lock();
    defer unlock();
    if (started) return true;
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return false;
    for (fds) |fd| {
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    }
    // A full pipe drops the byte of a signal, never blocks the handler.
    const fl = std.c.fcntl(fds[1], std.c.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(fds[1], std.c.F.SETFL, fl | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    pipe_fds = fds;
    const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watcher, .{}) catch {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        pipe_fds = .{ -1, -1 };
        return false;
    };
    t.detach();
    install(.child);
    started = true;
    return true;
}

fn install(s: Sig) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = @as(@FieldType(std.posix.Sigaction, "flags"), std.posix.SA.SIGINFO | std.posix.SA.RESTART) | @as(@FieldType(std.posix.Sigaction, "flags"), if (s == .child) std.posix.SA.NOCLDSTOP else 0),
    };
    std.posix.sigaction(s.posixSig(), &act, &saved[@backingInt(s)]);
}

/// Hands the child `pid`, whose object was collected while it ran, to the
/// watcher, which reaps it when it ends.
pub fn adoptOrphan(pid: i32) void {
    if (!posix) return;
    {
        lock();
        defer unlock();
        orphans.append(std.heap.page_allocator, pid) catch return;
    }
    // It may have ended before it was listed.
    reapOrphans();
}

// ---------------------------------------------------------------------
// Handlers of os.signal

/// Starts handling `s`. While a signal has a handler it no longer ends the
/// program. Returns false when the system cannot deliver it.
pub fn hold(s: Sig) bool {
    if (!supported) return false;
    if (!start()) return false;
    if (windows) {
        if (s == .hangup) return false;
        lock();
        defer unlock();
        handlers[@backingInt(s)] += 1;
        if (!win_installed) {
            win_installed = SetConsoleCtrlHandler(onConsole, .TRUE).toBool();
        }
        return win_installed;
    }
    lock();
    defer unlock();
    handlers[@backingInt(s)] += 1;
    if (handlers[@backingInt(s)] == 1) install(s);
    return true;
}

/// Stops one handler of `s`. The last one restores the action that was in
/// place before.
pub fn release(s: Sig) void {
    if (!supported) return;
    lock();
    defer unlock();
    const i = @backingInt(s);
    if (handlers[i] == 0) return;
    handlers[i] -= 1;
    if (handlers[i] > 0) return;
    if (s == .interrupt) handling_interrupt.store(false, .release);
    if (posix) std.posix.sigaction(s.posixSig(), &saved[i], null);
}

// ---------------------------------------------------------------------
// Windows

var win_installed = false;
const BOOL = std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

/// Runs on a thread the system creates for each console event. A close,
/// logoff, or shutdown event ends the process as soon as this returns, so
/// the thread stays here and the program has the time the system allows
/// (about five seconds) to shut down.
fn onConsole(kind: u32) callconv(.winapi) BOOL {
    const s: Sig = switch (kind) {
        0, 1 => .interrupt,
        2, 5, 6 => .terminate,
        else => return .FALSE,
    };
    lock();
    const handled = handlers[@backingInt(s)] > 0;
    unlock();
    if (!handled) return .FALSE;
    deliver(s);
    if (s == .terminate) Sleep(0xFFFFFFFF);
    return .TRUE;
}

/// Records the exit of a child on Windows, from the wait callback of its
/// process handle.
pub fn childExited() void {
    deliver(.child);
}
