//! I/O fault injection, compiled in by `-Dfail-io=true`.
//!
//! `wrap` returns an `Io` whose file and socket operations go through a
//! countdown before they reach the real implementation. Every streamed
//! read and write of a file or a socket, every positional read and write,
//! and every file open takes a number. `LUS_FAIL_IO=N` makes operation N
//! fail with the error a real system reports for it: `InputOutput` for a
//! read, `NoSpaceLeft` for a write, `ConnectionResetByPeer` for a socket,
//! and `ProcessFdQuotaExceeded` for an open. `LUS_FAIL_IO=N:short` makes
//! every file read and write from operation N on move at most one byte,
//! which a correct caller retries. Sockets keep their full transfers in
//! this mode: the scheduler waits for a socket edge after a short
//! transfer, which on a real system means the buffer is empty or full,
//! and a short transfer with data still waiting would never see that
//! edge. `LUS_FAIL_IO=count` fails nothing and prints
//! how many operations a run made (`main.zig`). `tests/oom/run.lus --io`
//! sweeps N.
//!
//! The wrapped `Io` keeps the userdata of the real one, so every operation
//! it does not override reaches the real implementation unchanged.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

pub const enabled = @import("build_options").fail_io;

pub const Mode = enum { off, fail, short };

pub var mode: Mode = .off;
pub var target: usize = 0;
pub var count: std.atomic.Value(usize) = .init(0);

var inner: *const Io.VTable = undefined;
var vtable: Io.VTable = undefined;

/// The `Io` to give every state of the process, with faults injected.
pub fn wrap(io: Io) Io {
    if (!enabled) return io;
    inner = io.vtable;
    vtable = io.vtable.*;
    vtable.operate = operate;
    vtable.fileReadPositional = fileReadPositional;
    vtable.fileWritePositional = fileWritePositional;
    vtable.dirOpenFile = dirOpenFile;
    vtable.dirCreateFile = dirCreateFile;
    return .{ .userdata = io.userdata, .vtable = &vtable };
}

const Fault = enum { none, fail, short };

/// Numbers the operation being made and says what happens to it.
fn next() Fault {
    const n = count.fetchAdd(1, .monotonic) + 1;
    return switch (mode) {
        .off => .none,
        .fail => if (n == target) .fail else .none,
        .short => if (n >= target) .short else .none,
    };
}

/// The first byte of the first nonempty buffer, so a read fills one byte.
fn oneRead(data: []const []u8, store: *[1][]u8) []const []u8 {
    for (data) |d| if (d.len > 0) {
        store[0] = d[0..1];
        return store;
    };
    return data;
}

fn oneWrite(header: []const u8, data: []const []const u8, store: *[1][]const u8) []const []const u8 {
    if (header.len > 0) {
        store[0] = header[0..1];
        return store;
    }
    for (data) |d| if (d.len > 0) {
        store[0] = d[0..1];
        return store;
    };
    return data;
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    if (operation == .device_io_control) return inner.operate(userdata, operation);
    switch (next()) {
        .none => return inner.operate(userdata, operation),
        .fail => return switch (operation) {
            .file_read_streaming => .{ .file_read_streaming = error.InputOutput },
            .file_write_streaming => .{ .file_write_streaming = error.NoSpaceLeft },
            .net_receive => .{ .net_receive = .{ error.ConnectionResetByPeer, 0 } },
            .net_send => .{ .net_send = .{ error.NetworkDown, 0 } },
            .net_read => .{ .net_read = error.ConnectionResetByPeer },
            .net_write => .{ .net_write = error.ConnectionResetByPeer },
            .device_io_control => unreachable,
        },
        .short => {
            var op = operation;
            var rstore: [1][]u8 = undefined;
            var wstore: [1][]const u8 = undefined;
            switch (op) {
                .file_read_streaming => |*r| r.data = oneRead(r.data, &rstore),
                .file_write_streaming => |*w| {
                    w.data = oneWrite(w.header, w.data, &wstore);
                    w.header = &.{};
                    w.splat = 1;
                },
                else => {},
            }
            return inner.operate(userdata, op);
        },
    }
}

fn fileReadPositional(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    var store: [1][]u8 = undefined;
    return switch (next()) {
        .none => inner.fileReadPositional(userdata, file, data, offset),
        .fail => error.InputOutput,
        .short => inner.fileReadPositional(userdata, file, oneRead(data, &store), offset),
    };
}

fn fileWritePositional(userdata: ?*anyopaque, file: File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize {
    var store: [1][]const u8 = undefined;
    return switch (next()) {
        .none => inner.fileWritePositional(userdata, file, header, data, splat, offset),
        .fail => error.NoSpaceLeft,
        .short => inner.fileWritePositional(userdata, file, &.{}, oneWrite(header, data, &store), 1, offset),
    };
}

fn dirOpenFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    return switch (next()) {
        .fail => error.ProcessFdQuotaExceeded,
        else => inner.dirOpenFile(userdata, dir, sub_path, options),
    };
}

fn dirCreateFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    return switch (next()) {
        .fail => error.ProcessFdQuotaExceeded,
        else => inner.dirCreateFile(userdata, dir, sub_path, options),
    };
}

/// Reads `LUS_FAIL_IO`: `N`, `N:short`, or `count`. Returns whether the
/// run reports its count at exit.
pub fn setup(spec: []const u8) bool {
    if (std.mem.eql(u8, spec, "count")) return true;
    var it = std.mem.splitScalar(u8, spec, ':');
    target = std.fmt.parseInt(usize, it.next() orelse return false, 10) catch return false;
    const kind = it.next() orelse "fail";
    mode = if (std.mem.eql(u8, kind, "short")) .short else .fail;
    return false;
}
