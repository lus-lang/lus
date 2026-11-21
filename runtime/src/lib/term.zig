//! Terminals: whether a file is one, and raw input mode. Raw mode is a
//! property of the terminal that the whole process shares, so the mode
//! from before the first switch is kept here once, and the process puts
//! it back when it ends, whichever state switched.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const posix_tty = !windows and builtin.os.tag != .wasi;

pub fn isatty(io: std.Io, file: std.Io.File) bool {
    if (builtin.os.tag == .wasi) return false;
    return file.isTty(io) catch false;
}

const Saved = if (windows) u32 else if (posix_tty) std.posix.termios else void;

/// The terminal in raw mode and its mode from before, guarded by `lock`.
var raw_handle: ?std.Io.File.Handle = null;
var saved: Saved = undefined;
var lock: std.atomic.Value(bool) = .init(false);

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

const win = if (windows) struct {
    const w = std.os.windows;
    extern "kernel32" fn GetConsoleMode(console: w.HANDLE, mode: *u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetConsoleMode(console: w.HANDLE, mode: u32) callconv(.winapi) w.BOOL;
    const processed_input: u32 = 0x0001;
    const line_input: u32 = 0x0002;
    const echo_input: u32 = 0x0004;
    const virtual_terminal_input: u32 = 0x0200;
} else struct {};

pub const RawError = error{ NotATerminal, Unsupported };

/// Switches the terminal of `file` to raw input when `on` is set: no
/// echo, no line editing, and no signals from keys, so each key arrives
/// as soon as it is pressed and Ctrl-C arrives as the byte 3. Output keeps
/// turning a line feed into a new line. Switching back restores the mode
/// from before the first switch.
pub fn setRaw(io: std.Io, file: std.Io.File, on: bool) RawError!void {
    if (!posix_tty and !windows) return error.Unsupported;
    if (!isatty(io, file)) return error.NotATerminal;
    acquire();
    defer release();
    if (!on) {
        restoreLocked();
        return;
    }
    if (raw_handle != null) return;
    if (comptime windows) {
        var mode: u32 = 0;
        if (!win.GetConsoleMode(file.handle, &mode).toBool()) return error.NotATerminal;
        const raw = (mode & ~(win.processed_input | win.line_input | win.echo_input)) | win.virtual_terminal_input;
        if (!win.SetConsoleMode(file.handle, raw).toBool()) return error.Unsupported;
        saved = mode;
    } else {
        const old = std.posix.tcgetattr(file.handle) catch return error.NotATerminal;
        var t = old;
        t.iflag.BRKINT = false;
        t.iflag.ICRNL = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        t.iflag.IXON = false;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.IEXTEN = false;
        t.lflag.ISIG = false;
        t.cc[@backingInt(std.posix.V.MIN)] = 1;
        t.cc[@backingInt(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(file.handle, .FLUSH, t) catch return error.Unsupported;
        saved = old;
    }
    raw_handle = file.handle;
}

fn restoreLocked() void {
    const h = raw_handle orelse return;
    if (comptime windows) {
        _ = win.SetConsoleMode(h, saved);
    } else if (comptime posix_tty) {
        std.posix.tcsetattr(h, .FLUSH, saved) catch {};
    }
    raw_handle = null;
}

/// Puts a terminal in raw mode back as it was. The process calls this as
/// it ends.
pub fn restore() void {
    if (!posix_tty and !windows) return;
    acquire();
    defer release();
    restoreLocked();
}
