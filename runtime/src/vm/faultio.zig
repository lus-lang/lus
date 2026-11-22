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
//! edge. `LUS_FAIL_IO=N:kill` ends the process just before operation N,
//! as a kill does, and `LUS_FAIL_IO=N:powerloss` also undoes, at random,
//! what a power loss could destroy of the writes and directory changes
//! that no sync made durable (`faultcrash.zig`). Syncs, renames,
//! deletions, and changes of size are operations too, so a crash can land
//! between any two steps, and an N of 0 places it after the last one, as
//! the process exits. `LUS_FAIL_IO=count` fails nothing and prints
//! how many operations a run made (`main.zig`). `tests/oom/run.lus --io`
//! sweeps N.
//!
//! `LUS_FAIL_NET` injects network faults (`netStep`): `N:reset` resets
//! the connection at socket transfer N, a send or a receive, `N:eof` ends
//! the stream at receive N as a peer that closes does, `N:dns` fails name
//! lookup N, `N:refuse` refuses connection attempt N, and `N:abort` aborts
//! the connection that accept N takes, as a peer that gives up before the
//! accept does. Each kind counts its own steps. `LUS_FAIL_NET=count`
//! prints the count of each kind and the sockets still open at exit
//! (`main.zig`), which a run with any `LUS_FAIL_NET` prints too.
//! `tests/faults/network.lus` sweeps N.
//!
//! `LUS_CLOCK` scripts jumps of the real clock (`clockNow`). It is a list
//! such as `1:=1772953198,4:+3600,6:-86400`, where `N:=S` sets the real
//! clock to S seconds after the epoch at read N of it, and `N:+S` or `N:-S`
//! moves it forward or back by S seconds from read N on. Between jumps
//! the clock advances with the real one. Every other clock reads the real
//! one unchanged, so a jump moves `time.now` and leaves `time.monotonic`
//! and every timer alone. `LUS_CLOCK=count` prints how many times a run
//! read the real clock.
//!
//! The wrapped `Io` keeps the userdata of the real one, so every operation
//! it does not override reaches the real implementation unchanged.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
pub const crash = @import("faultcrash.zig");

pub const enabled = @import("build_options").fail_io;

pub const Mode = enum { off, fail, short, kill, powerloss };

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
    vtable.dirOpenDir = dirOpenDir;
    vtable.fileSync = fileSync;
    vtable.fileSetLength = fileSetLength;
    vtable.fileClose = fileClose;
    vtable.dirRename = dirRename;
    vtable.dirRenamePreserve = dirRenamePreserve;
    vtable.dirDeleteFile = dirDeleteFile;
    vtable.now = clockNow;
    return .{ .userdata = io.userdata, .vtable = &vtable };
}

const Fault = enum { none, fail, short };

/// Numbers the operation being made and says what happens to it. A crash
/// mode ends the process here, before operation N reaches the system.
fn next() Fault {
    const n = count.fetchAdd(1, .monotonic) + 1;
    return switch (mode) {
        .off => .none,
        .fail => if (n == target) .fail else .none,
        .short => if (n >= target) .short else .none,
        .kill => if (n == target) crash.kill(n) else .none,
        .powerloss => if (n == target) (if (crash.supported) crash.powerLoss(n) else crash.kill(n)) else .none,
    };
}

/// Ends the run in a crash mode whose N is 0, which places the crash after
/// the last operation, as the process exits.
pub fn atExit() void {
    if (target != 0) return;
    const n = count.load(.monotonic) + 1;
    switch (mode) {
        .kill => crash.kill(n),
        .powerloss => if (crash.supported) crash.powerLoss(n) else crash.kill(n),
        else => {},
    }
}

/// `LUS_WORKER_FAIL=N` fails step N of the message handling of workers: a
/// copy of a message into or out of a state, a push to an outbox or an
/// inbox, and a take from one. `LUS_WORKER_FAIL=count` prints how many
/// steps a run made. The steps of every thread share one count.
pub var worker_target: usize = 0;
pub var worker_count: std.atomic.Value(usize) = .init(0);
pub var worker_report = false;

/// Numbers a step of the message handling of workers, and says whether it
/// fails.
pub fn workerStep() ?usize {
    const n = worker_count.fetchAdd(1, .monotonic) + 1;
    return if (n == worker_target) n else null;
}

/// Reads `LUS_WORKER_FAIL`.
pub fn setupWorker(spec: []const u8) void {
    if (std.mem.eql(u8, spec, "count")) {
        worker_report = true;
        return;
    }
    worker_target = std.fmt.parseInt(usize, spec, 10) catch 0;
}

/// The jumps of `LUS_CLOCK`, in the order of the reads they start at.
const Jump = struct { at: usize, absolute: bool, seconds: i64 };
var jumps: [16]Jump = undefined;
var njumps: usize = 0;
pub var clock_reads: std.atomic.Value(usize) = .init(0);
pub var clock_report = false;
/// The nanoseconds that the scripted real clock is ahead of the real one.
var clock_offset: std.atomic.Value(i64) = .init(0);

fn clockNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const t = inner.now(userdata, clock);
    if (clock != .real) return t;
    const n = clock_reads.fetchAdd(1, .monotonic) + 1;
    for (jumps[0..njumps]) |j| {
        if (j.at != n) continue;
        const ns = @as(i64, j.seconds) * std.time.ns_per_s;
        if (j.absolute) {
            clock_offset.store(@intCast(@as(i96, ns) - t.nanoseconds), .monotonic);
        } else {
            _ = clock_offset.fetchAdd(ns, .monotonic);
        }
    }
    return .{ .nanoseconds = t.nanoseconds + clock_offset.load(.monotonic) };
}

/// Reads `LUS_CLOCK`. Returns whether the run reads the clock through the
/// script.
pub fn setupClock(spec: []const u8) bool {
    if (std.mem.eql(u8, spec, "count")) {
        clock_report = true;
        return true;
    }
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |item| {
        if (njumps == jumps.len) break;
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const at = std.fmt.parseInt(usize, item[0..colon], 10) catch continue;
        const rest = item[colon + 1 ..];
        if (rest.len < 2) continue;
        const absolute = rest[0] == '=';
        const seconds = std.fmt.parseInt(i64, if (absolute) rest[1..] else rest, 10) catch continue;
        jumps[njumps] = .{ .at = at, .absolute = absolute, .seconds = seconds };
        njumps += 1;
    }
    return njumps > 0;
}

/// `LUS_CANCEL_AT=N` closes the detached coroutine that makes suspension
/// N, as `coroutine.close` does, right after it suspends to wait for a
/// socket, a timer, another coroutine, or a notification.
/// `LUS_CANCEL_AT=count` prints how many suspensions a run made.
pub var cancel_target: usize = 0;
pub var cancel_count: std.atomic.Value(usize) = .init(0);
pub var cancel_report = false;

/// Numbers a suspension of a detached coroutine, and says whether the
/// coroutine is cancelled there. The states of every thread share one
/// count.
pub fn cancelStep() bool {
    if (!enabled) return false;
    return cancel_count.fetchAdd(1, .monotonic) + 1 == cancel_target;
}

/// Reads `LUS_CANCEL_AT`.
pub fn setupCancel(spec: []const u8) void {
    if (std.mem.eql(u8, spec, "count")) {
        cancel_report = true;
        return;
    }
    cancel_target = std.fmt.parseInt(usize, spec, 10) catch 0;
}

/// The network faults of `LUS_FAIL_NET`, and the steps each one counts.
pub const NetKind = enum { reset, eof, dns, refuse, abort };
pub const NetStep = enum { transfer, receive, lookup, connect, accept };

pub var net_kind: ?NetKind = null;
pub var net_target: usize = 0;
pub var net_report = false;
pub var net_counts: [5]std.atomic.Value(usize) = @splat(.init(0));

fn stepOf(k: NetKind) NetStep {
    return switch (k) {
        .reset => .transfer,
        .eof => .receive,
        .dns => .lookup,
        .refuse => .connect,
        .abort => .accept,
    };
}

/// Numbers a network step of each kind in `steps` and returns the fault
/// that lands on it, if any.
pub fn netStep(steps: []const NetStep) ?NetKind {
    if (!enabled) return null;
    var hit: ?NetKind = null;
    for (steps) |st| {
        const n = net_counts[@backingInt(st)].fetchAdd(1, .monotonic) + 1;
        const k = net_kind orelse continue;
        if (stepOf(k) == st and n == net_target) hit = k;
    }
    return hit;
}

/// The steps that a receive of a stream socket counts.
pub const receive_steps: []const NetStep = &.{ .transfer, .receive };
/// The steps that a send of a stream socket counts.
pub const send_steps: []const NetStep = &.{.transfer};

/// Reads `LUS_FAIL_NET`: `N:KIND` or `count`.
pub fn setupNet(spec: []const u8) void {
    net_report = true;
    if (std.mem.eql(u8, spec, "count")) return;
    var it = std.mem.splitScalar(u8, spec, ':');
    net_target = std.fmt.parseInt(usize, it.next() orelse return, 10) catch return;
    net_kind = std.meta.stringToEnum(NetKind, it.next() orelse "reset");
}

/// The number of open TCP and UDP sockets of the process, or null where
/// the count is not available. Local sockets that the C library keeps,
/// such as the one of the name service on macOS, do not count.
pub fn socketsOpen() ?usize {
    if (@import("builtin").os.tag == .windows) return null;
    const posix = std.posix;
    var n: usize = 0;
    var fd: posix.fd_t = 0;
    while (fd < 1024) : (fd += 1) {
        var addr: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        if (posix.errno(posix.system.getsockname(fd, @ptrCast(&addr), &len)) != .SUCCESS) continue;
        if (addr.family == posix.AF.INET or addr.family == posix.AF.INET6) n += 1;
    }
    return n;
}

/// Prints the counts of the network steps and the sockets still open.
pub fn reportNet() void {
    if (!enabled or !net_report) return;
    const c = &net_counts;
    std.debug.print("lus: network steps: {d} transfers, {d} receives, {d} lookups, {d} connects, {d} accepts\n", .{
        c[0].load(.monotonic), c[1].load(.monotonic), c[2].load(.monotonic), c[3].load(.monotonic), c[4].load(.monotonic),
    });
    if (socketsOpen()) |n| std.debug.print("lus: {d} sockets open at exit\n", .{n});
}

/// Numbers an operation of the SQLite VFS, and says whether it fails.
pub fn step() bool {
    return next() == .fail;
}

/// Whether the power loss model records the operations.
pub inline fn tracking() bool {
    return crash.supported and mode == .powerloss;
}

/// Whether `dir` is the current directory, whose paths the model tracks.
fn isCwd(dir: Dir) bool {
    return dir.handle == Dir.cwd().handle;
}

fn writeLen(header: []const u8, data: []const []const u8, splat: usize) u64 {
    var n: u64 = header.len;
    if (data.len == 0) return n;
    for (data[0 .. data.len - 1]) |d| n += d.len;
    return n + data[data.len - 1].len * splat;
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
    switch (operation) {
        .net_read => if (netStep(receive_steps)) |k| return .{ .net_read = if (k == .eof) .{ .data_len = 0 } else error.ConnectionResetByPeer },
        .net_write => if (netStep(send_steps) != null) return .{ .net_write = error.ConnectionResetByPeer },
        else => {},
    }
    const fault = next();
    if (tracking() and fault == .none) switch (operation) {
        .file_write_streaming => |w| crash.writing(w.file.handle, null, writeLen(w.header, w.data, w.splat)),
        else => {},
    };
    switch (fault) {
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
    const fault = next();
    if (tracking() and fault == .none) crash.writing(file.handle, offset, writeLen(header, data, splat));
    return switch (fault) {
        .none => inner.fileWritePositional(userdata, file, header, data, splat, offset),
        .fail => error.NoSpaceLeft,
        .short => inner.fileWritePositional(userdata, file, &.{}, oneWrite(header, data, &store), 1, offset),
    };
}

fn dirOpenFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    if (next() == .fail) return error.ProcessFdQuotaExceeded;
    const track = tracking() and isCwd(dir);
    if (track) crash.opened(sub_path, false, false);
    const f = try inner.dirOpenFile(userdata, dir, sub_path, options);
    if (track) crash.bind(f.handle);
    return f;
}

fn dirCreateFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    if (next() == .fail) return error.ProcessFdQuotaExceeded;
    const track = tracking() and isCwd(dir);
    if (track) crash.opened(sub_path, true, options.truncate);
    const f = try inner.dirCreateFile(userdata, dir, sub_path, options);
    if (track) crash.bind(f.handle);
    return f;
}

fn dirOpenDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
    const d = try inner.dirOpenDir(userdata, dir, sub_path, options);
    if (tracking() and isCwd(dir)) crash.openedDir(sub_path, d.handle);
    return d;
}

fn fileClose(userdata: ?*anyopaque, files: []const File) void {
    if (tracking()) for (files) |f| crash.closed(f.handle);
    inner.fileClose(userdata, files);
}

fn fileSync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    if (next() == .fail) return error.InputOutput;
    try inner.fileSync(userdata, file);
    if (tracking()) crash.syncing(file.handle);
}

fn fileSetLength(userdata: ?*anyopaque, file: File, len: u64) File.SetLengthError!void {
    if (next() == .fail) return error.InputOutput;
    if (tracking()) crash.settingLength(file.handle, len);
    return inner.fileSetLength(userdata, file, len);
}

fn dirRename(userdata: ?*anyopaque, old_dir: Dir, old_sub: []const u8, new_dir: Dir, new_sub: []const u8) Dir.RenameError!void {
    if (next() == .fail) return error.NoSpaceLeft;
    if (tracking() and isCwd(old_dir) and isCwd(new_dir)) crash.renaming(old_sub, new_sub);
    return inner.dirRename(userdata, old_dir, old_sub, new_dir, new_sub);
}

fn dirRenamePreserve(userdata: ?*anyopaque, old_dir: Dir, old_sub: []const u8, new_dir: Dir, new_sub: []const u8) Dir.RenamePreserveError!void {
    if (next() == .fail) return error.AccessDenied;
    try inner.dirRenamePreserve(userdata, old_dir, old_sub, new_dir, new_sub);
    if (tracking() and isCwd(old_dir) and isCwd(new_dir)) crash.renaming(old_sub, new_sub);
}

fn dirDeleteFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    if (next() == .fail) return error.AccessDenied;
    if (tracking() and isCwd(dir)) crash.deleting(sub_path);
    return inner.dirDeleteFile(userdata, dir, sub_path);
}

/// Reads `LUS_FAIL_IO`: `N`, `N:short`, `N:kill`, `N:powerloss`, or
/// `count`, and the seed and the powersafe overwrite setting of the power
/// loss model. Returns whether the run reports its count at exit.
pub fn setup(spec: []const u8, seed: ?[]const u8, psow: ?[]const u8) bool {
    if (seed) |sv| crash.seed = std.fmt.parseInt(u64, sv, 10) catch 0;
    if (psow) |pv| crash.psow = !std.mem.eql(u8, pv, "0");
    if (std.mem.eql(u8, spec, "count")) return true;
    var it = std.mem.splitScalar(u8, spec, ':');
    target = std.fmt.parseInt(usize, it.next() orelse return false, 10) catch return false;
    const kind = it.next() orelse "fail";
    mode = if (std.mem.eql(u8, kind, "short"))
        .short
    else if (std.mem.eql(u8, kind, "kill"))
        .kill
    else if (std.mem.eql(u8, kind, "powerloss"))
        .powerloss
    else
        .fail;
    return false;
}
