//! `os.spawn`: running a program without a shell. The program name is
//! looked up in `PATH`, the `exec` permission is checked against the name
//! as written and against the path it resolves to, and the child gets
//! pipes, files, or the streams of the parent as its standard streams.
//! The pipe ends of the parent are io handles in non-blocking mode, whose
//! reads and writes wait through the scheduler, and `p.exit` is a
//! coroutine that waits for the exit (lib/events.zig).
//!
//! On POSIX systems the exit of a child arrives as SIGCHLD through
//! `vm/sigwatch.zig`. On Windows a wait registered on the process handle
//! reports it.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const sched = @import("../vm/sched.zig");
const sigwatch = @import("../vm/sigwatch.zig");
const pledge = @import("../vm/pledge.zig");
const table = @import("../vm/table.zig");
const aux = @import("auxlib.zig");
const base_lib = @import("base.zig");
const io_lib = @import("io.zig");
const os_lib = @import("os.zig");
const shell = @import("shell.zig");
const out = @import("out.zig");
const events = @import("events.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const String = object.String;

const windows = builtin.os.tag == .windows;
pub const available = aux.can_spawn;

const Pid = if (windows) std.os.windows.HANDLE else std.posix.pid_t;

const Process = struct {
    pid: Pid,
    /// The numeric id the system gives the process.
    id: i64,
    status: ?shell.Status = null,
    /// Set once the process was reaped or handed to the watcher, after
    /// which `pid` is no longer valid.
    released: bool = false,
    wait_handle: if (windows) ?std.os.windows.HANDLE else void = if (windows) null else {},
};

const process_key = "os.process";

pub fn open(l: *Thread, os_t: *Table) Error!void {
    if (comptime !available) return;
    const mt = try l.newTable(0, 6);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    const methods = try aux.newLib(l, .methods, "os:process", &.{
        .{ .name = "kill", .func = pKill },
        .{ .name = "poll", .func = pPoll },
    });
    try aux.setField(l, mt, "__methods", Value.obj(.table, methods));
    try aux.setField(l, mt, "__index", try aux.native(l, pIndex, "__index"));
    try aux.setField(l, mt, "__close", try aux.native(l, pClose, "__close"));
    try aux.setField(l, mt, "__gc", try aux.native(l, pGc, "__gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue("process"));
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), process_key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, process_key, mt) catch return l.raiseMem();
    try aux.setField(l, os_t, "spawn", try aux.native(l, spawn, "spawn"));
}

fn processMt(l: *Thread) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(process_key).?));
}

fn toProcess(l: *Thread, v: Value) ?*Process {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != processMt(l)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn checkProcess(l: *Thread, i: u32) Error!*Process {
    return toProcess(l, l.arg(i)) orelse aux.typeError(l, i, "process");
}

// ---------------------------------------------------------------------
// Options

const Stream = union(enum) {
    inherit,
    pipe,
    null,
    stdout,
    file: std.Io.File,
};

fn streamOption(l: *Thread, opts: ?*Table, name: []const u8, allow_stdout: bool) Error!Stream {
    const t = opts orelse return .inherit;
    const v = try aux.getField(l, t, name);
    if (v.isNil()) return .inherit;
    if (v.tag == .string) {
        const s = v.as(String).bytes();
        if (std.mem.eql(u8, s, "inherit")) return .inherit;
        if (std.mem.eql(u8, s, "pipe")) return .pipe;
        if (std.mem.eql(u8, s, "null")) return .null;
        if (allow_stdout and std.mem.eql(u8, s, "stdout")) return .stdout;
    } else if (io_lib.fileOf(l, v)) |f| return .{ .file = f };
    if (allow_stdout) return aux.argError(l, 2, "option '{s}' must be \"inherit\", \"pipe\", \"null\", \"stdout\", or an open file", .{name});
    return aux.argError(l, 2, "option '{s}' must be \"inherit\", \"pipe\", \"null\", or an open file", .{name});
}

// ---------------------------------------------------------------------
// Finding the program

fn hasSep(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '/') != null or (windows and std.mem.indexOfScalar(u8, s, '\\') != null);
}

fn isAbsolute(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or (windows and p[0] == '\\')) return true;
    return windows and p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
}

/// Whether `path` names a regular file the process may run.
fn runnable(gpa: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    if (windows) return true;
    const z = gpa.dupeSentinel(u8, path, 0) catch return false;
    defer gpa.free(z);
    return std.c.access(z, std.c.X_OK) == 0;
}

/// The absolute path of the program `name`, or null when it is not found.
/// A name with a separator is a path, relative to `cwd` when that is
/// given. Any other name is looked up in the directories of `path_env`,
/// with the extensions of `pathext` on Windows.
fn findProgram(gpa: std.mem.Allocator, io: std.Io, name: []const u8, cwd: ?[]const u8, path_env: ?[]const u8, pathext: ?[]const u8) error{OutOfMemory}!?[]u8 {
    const delim: u8 = if (windows) ';' else ':';
    const sep: []const u8 = if (windows) "\\" else "/";
    var exts_buf: [1][]const u8 = .{""};
    var exts_list: std.ArrayList([]const u8) = .empty;
    defer exts_list.deinit(gpa);
    var exts: []const []const u8 = &exts_buf;
    if (windows) {
        // A name that already has an extension is tried as it is first.
        try exts_list.append(gpa, "");
        var it = std.mem.splitScalar(u8, pathext orelse ".COM;.EXE;.BAT;.CMD", ';');
        while (it.next()) |e| if (e.len > 0) try exts_list.append(gpa, e);
        exts = exts_list.items;
    }
    if (hasSep(name)) {
        const joined = if (cwd != null and !isAbsolute(name)) try std.mem.concat(gpa, u8, &.{ cwd.?, sep, name }) else try gpa.dupe(u8, name);
        defer gpa.free(joined);
        for (exts) |e| {
            const cand = try std.mem.concat(gpa, u8, &.{ joined, e });
            defer gpa.free(cand);
            if (runnable(gpa, io, cand)) return try absolute(gpa, io, cand);
        }
        return null;
    }
    var it = std.mem.splitScalar(u8, path_env orelse (if (windows) "" else "/usr/bin:/bin"), delim);
    while (it.next()) |dir| {
        const d = if (dir.len == 0) "." else dir;
        for (exts) |e| {
            const cand = try std.mem.concat(gpa, u8, &.{ d, sep, name, e });
            defer gpa.free(cand);
            if (runnable(gpa, io, cand)) return try absolute(gpa, io, cand);
        }
    }
    return null;
}

fn absolute(gpa: std.mem.Allocator, io: std.Io, path: []const u8) error{OutOfMemory}![]u8 {
    const r = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return gpa.dupe(u8, path);
    defer gpa.free(r);
    return gpa.dupe(u8, r);
}

// ---------------------------------------------------------------------
// os.spawn

fn spawn(l: *Thread) Error!u32 {
    const gpa = l.g.gpa;
    const io = l.g.io;
    const argv_t = try aux.checkTable(l, 1);
    const opts: ?*Table = if (l.arg(2).isNil()) null else try aux.checkTable(l, 2);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var i: i64 = 1;
    while (true) : (i += 1) {
        const v = table.getInt(argv_t, i);
        if (v.isNil()) break;
        if (v.tag != .string) return aux.argError(l, 1, "argument {d} must be a string", .{i});
        const s = v.as(String).bytes();
        if (std.mem.indexOfScalar(u8, s, 0) != null) return aux.argError(l, 1, "argument {d} contains a zero byte", .{i});
        argv.append(gpa, s) catch return l.raiseMem();
    }
    if (argv.items.len == 0) return aux.argError(l, 1, "the program name is missing", .{});
    if (argv.items[0].len == 0) return aux.argError(l, 1, "the program name is empty", .{});

    const stdin_opt = try streamOption(l, opts, "stdin", false);
    const stdout_opt = try streamOption(l, opts, "stdout", false);
    const stderr_opt = try streamOption(l, opts, "stderr", true);
    var cwd: ?[]const u8 = null;
    var env_map: ?std.process.Environ.Map = null;
    defer if (env_map) |*m| m.deinit();
    if (opts) |t| {
        const c = try aux.getField(l, t, "cwd");
        if (!c.isNil()) {
            if (c.tag != .string) return aux.argError(l, 2, "option 'cwd' must be a string", .{});
            cwd = c.as(String).bytes();
        }
        const e = try aux.getField(l, t, "env");
        if (!e.isNil()) {
            if (e.tag != .table) return aux.argError(l, 2, "option 'env' must be a table", .{});
            env_map = std.process.Environ.Map.init(gpa);
            var key: Value = .nil;
            while (table.next(e.as(Table), key) catch null) |kv| {
                key = kv.key;
                if (kv.key.tag != .string or kv.val.tag != .string) return aux.argError(l, 2, "option 'env' must map strings to strings", .{});
                const k = kv.key.as(String).bytes();
                if (k.len == 0 or std.mem.indexOfAny(u8, k, "=\x00") != null) return aux.argError(l, 2, "invalid environment variable name '{s}'", .{k});
                env_map.?.put(k, kv.val.as(String).bytes()) catch return l.raiseMem();
            }
        }
    }

    // The program is looked up in the PATH of the environment the child
    // gets.
    const path_env: ?[]const u8 = if (env_map) |m| m.get("PATH") orelse (if (windows) m.get("Path") else null) else os_lib.envGet(l, "PATH") orelse (if (windows) os_lib.envGet(l, "Path") else null);
    const pathext: ?[]const u8 = if (!windows) null else if (env_map) |m| m.get("PATHEXT") else os_lib.envGet(l, "PATHEXT");
    const name = argv.items[0];
    const resolved = findProgram(gpa, io, name, cwd, path_env, pathext) catch return l.raiseMem();
    defer if (resolved) |r| gpa.free(r);
    {
        // A permission by name covers the program that the name resolves
        // to through the `PATH` the state started with. A `PATH` that the
        // script chose reaches the child and decides nothing here.
        // A name that resolves to nothing runs nothing, so it keeps the
        // answer its permission gives.
        var by_name = !hasSep(name);
        if (by_name) if (resolved) |r| {
            const trusted = findProgram(gpa, io, name, null, os_lib.startupPath(l), pathext) catch return l.raiseMem();
            defer if (trusted) |t| gpa.free(t);
            by_name = if (trusted) |t| std.mem.eql(u8, t, r) else false;
        };
        const req = pledge.programRequest(gpa, if (by_name) name else null, resolved orelse "") catch return l.raiseMem();
        defer gpa.free(req);
        if (!pledge.allowed(l, "exec", req)) return l.raiseFmt("permission \"exec\" denied for '{s}'", .{name});
    }
    const exe = resolved orelse {
        try l.push(.nil);
        const msg = std.fmt.allocPrint(gpa, "cannot run '{s}': program not found", .{name}) catch return l.raiseMem();
        defer gpa.free(msg);
        try l.push(try os_lib.lossyString(l, msg));
        return 2;
    };
    out.flushAll(l.g);
    return spawnResolved(l, exe, argv.items, cwd, if (env_map) |*m| m else os_lib.ownedEnviron(l.g), stdin_opt, stdout_opt, stderr_opt);
}

fn stdIo(s: Stream) std.process.SpawnOptions.StdIo {
    return switch (s) {
        .inherit => .inherit,
        .pipe => .pipe,
        .null => .ignore,
        .stdout => unreachable,
        .file => |f| .{ .file = f },
    };
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const fl = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (fl < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
}

/// Pushes nil and the message of a failed start.
fn startError(l: *Thread, exe: []const u8, e: anyerror) Error!u32 {
    const gpa = l.g.gpa;
    const msg = std.fmt.allocPrint(gpa, "cannot run '{s}': {s}", .{ exe, os_lib.errnoOf(e).msg }) catch return l.raiseMem();
    defer gpa.free(msg);
    try l.push(.nil);
    try l.push(try os_lib.lossyString(l, msg));
    return 2;
}

const Ends = struct {
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
};

fn spawnResolved(l: *Thread, exe: []const u8, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map, sin: Stream, sout: Stream, serr: Stream) Error!u32 {
    var ends: Ends = .{};
    var pid: Pid = undefined;
    var id: i64 = 0;
    if (comptime windows) {
        const r = win.spawn(l.g.gpa, exe, argv, cwd, env, sin, sout, serr) catch |e| switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.UnsafeBatchArgument => return l.raiseFmt("an argument holds a character that a batch file cannot receive safely (%, !, \", or a line break)", .{}),
            else => return startError(l, exe, e),
        };
        ends = r.ends;
        pid = r.process;
        id = r.id;
    } else {
        const io = l.g.io;
        var so = if (sout == .stdout) unreachable else stdIo(sout);
        var se: std.process.SpawnOptions.StdIo = undefined;
        var merged: ?[2]c_int = null;
        if (serr == .stdout) {
            switch (sout) {
                .inherit => se = .{ .file = std.Io.File.stdout() },
                .null => se = .ignore,
                .file => |f| se = .{ .file = f },
                .pipe => {
                    var fds: [2]c_int = undefined;
                    if (std.c.pipe(&fds) != 0) return startError(l, exe, error.SystemResources);
                    for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
                    merged = fds;
                    const w: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
                    so = .{ .file = w };
                    se = .{ .file = w };
                },
                .stdout => unreachable,
            }
        } else se = stdIo(serr);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = exe } },
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .environ_map = env,
            .stdin = stdIo(sin),
            .stdout = so,
            .stderr = se,
        }) catch |e| {
            if (merged) |fds| {
                _ = std.c.close(fds[0]);
                _ = std.c.close(fds[1]);
            }
            return startError(l, exe, e);
        };
        if (merged) |fds| {
            _ = std.c.close(fds[1]);
            child.stdout = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        }
        ends = .{ .stdin = child.stdin, .stdout = child.stdout, .stderr = child.stderr };
        pid = child.id.?;
        id = pid;
    }
    if (!windows) {
        inline for (.{ "stdin", "stdout", "stderr" }) |f| if (@field(ends, f)) |file| setNonblocking(file.handle);
    }
    return pushProcess(l, pid, id, ends);
}

fn pushProcess(l: *Thread, pid: Pid, id: i64, ends: Ends) Error!u32 {
    const mt = processMt(l);
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Process), 4)) catch {
        closeEnds(l, ends);
        return l.raiseMem();
    };
    u.size = @sizeOf(Process);
    u.nuser = 4;
    u.metatable = mt;
    for (u.userValues()) |*v| v.* = .nil;
    const p: *Process = @ptrCast(@alignCast(u.data()));
    p.* = .{ .pid = pid, .id = id };
    const uv = Value.obj(.userdata, u);
    try l.push(uv);
    try base_lib.registerFinalizer(l, &u.hdr, mt);
    if (windows) win.watch(p);
    // Each end becomes an io handle before the next allocation can
    // collect, so none of them leaks. The process may turn old during any
    // of these allocations, so each store into it takes the barrier.
    const nb = true;
    if (ends.stdin) |f| u.userValues()[0] = io_lib.newPipeHandle(l, f, false, nb) catch |e| {
        closeEnds(l, .{ .stdout = ends.stdout, .stderr = ends.stderr });
        return e;
    };
    gc.barrierBack(l.g, &u.hdr);
    if (ends.stdout) |f| u.userValues()[1] = io_lib.newPipeHandle(l, f, true, nb) catch |e| {
        closeEnds(l, .{ .stderr = ends.stderr });
        return e;
    };
    gc.barrierBack(l.g, &u.hdr);
    if (ends.stderr) |f| u.userValues()[2] = try io_lib.newPipeHandle(l, f, true, nb);
    gc.barrierBack(l.g, &u.hdr);
    // The coroutine that waits for the exit.
    u.userValues()[3] = try events.once(l, waitNative, "exit", uv);
    gc.barrierBack(l.g, &u.hdr);
    l.top -= 1;
    return 1;
}

fn closeEnds(l: *Thread, ends: Ends) void {
    inline for (.{ "stdin", "stdout", "stderr" }) |f| if (@field(ends, f)) |file| file.close(l.g.io);
}

// ---------------------------------------------------------------------
// Waiting

fn decode(st: c_int) shell.Status {
    const s: u32 = @bitCast(st);
    if (s & 0x7f == 0) return .{ .exited = (s >> 8) & 0xff };
    return .{ .signal = s & 0x7f };
}

/// Whether the process has ended, reaping it when it just did.
fn tryReap(p: *Process) bool {
    if (p.status != null) return true;
    if (comptime windows) return win.tryReap(p);
    var st: c_int = 0;
    const r = std.c.waitpid(p.pid, &st, std.c.W.NOHANG);
    if (r == 0) return false;
    p.released = true;
    // Another waiter of the process reaped it, so how it ended is lost.
    p.status = if (r == p.pid) decode(st) else .{ .exited = 0 };
    return true;
}

/// Waits until the process ends. Inside a detached coroutine the wait
/// suspends it, and the native runs again after each child exit.
fn waitExit(l: *Thread, p: *Process) Error!shell.Status {
    if (tryReap(p)) return p.status.?;
    if (sigwatch.subscribe(l.g)) {
        while (!tryReap(p)) {
            try events.checkClosed(l);
            try sched.waitNotify(l);
        }
        return p.status.?;
    }
    // Without a wake source the thread blocks in the system call.
    if (comptime windows) {
        win.block(p);
        _ = tryReap(p);
    } else {
        var st: c_int = 0;
        while (true) {
            const r = std.c.waitpid(p.pid, &st, 0);
            if (r == p.pid) {
                p.status = decode(st);
                break;
            }
            if (r < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            p.status = .{ .exited = 0 };
            break;
        }
        p.released = true;
    }
    return p.status.?;
}

fn waitNative(l: *Thread) Error!u32 {
    const p = try checkProcess(l, 1);
    const st = try waitExit(l, p);
    return io_lib.pushStatus(l, st);
}

fn pPoll(l: *Thread) Error!u32 {
    const p = try checkProcess(l, 1);
    if (!tryReap(p)) return 0;
    return io_lib.pushStatus(l, p.status.?);
}

fn pKill(l: *Thread) Error!u32 {
    const p = try checkProcess(l, 1);
    var sig: i64 = 15;
    const a = l.arg(2);
    if (a.tag == .string) {
        const s = a.as(String).bytes();
        if (std.mem.eql(u8, s, "terminate")) sig = 15 else if (std.mem.eql(u8, s, "kill")) sig = 9 else if (std.mem.eql(u8, s, "interrupt")) sig = 2 else if (std.mem.eql(u8, s, "hangup")) sig = 1 else return aux.argError(l, 2, "unknown signal '{s}'", .{s});
    } else if (!a.isNil()) sig = try aux.checkInt(l, 2);
    if (tryReap(p)) return aux.retBool(l, false);
    if (comptime windows) return aux.retBool(l, win.terminate(p));
    if (sig < 0 or sig > 64) return aux.argError(l, 2, "signal number out of range", .{});
    const r = std.c.kill(p.pid, @fromBackingInt(@intCast(@as(u32, @intCast(sig)))));
    return aux.retBool(l, r == 0);
}

fn pIndex(l: *Thread) Error!u32 {
    const u = l.arg(1).as(Userdata);
    const p: *Process = @ptrCast(@alignCast(u.data()));
    const k = l.arg(2);
    if (k.tag == .string) {
        const s = k.as(String).bytes();
        if (std.mem.eql(u8, s, "pid")) return aux.ret(l, Value.int(p.id));
        if (std.mem.eql(u8, s, "stdin")) return aux.ret(l, u.userValues()[0]);
        if (std.mem.eql(u8, s, "stdout")) return aux.ret(l, u.userValues()[1]);
        if (std.mem.eql(u8, s, "stderr")) return aux.ret(l, u.userValues()[2]);
        if (std.mem.eql(u8, s, "exit")) return aux.ret(l, u.userValues()[3]);
    }
    const methods = (try aux.getField(l, processMt(l), "__methods")).as(Table);
    return aux.ret(l, try ops.index(l, Value.obj(.table, methods), k));
}

/// Leaving the scope of a `<close>` process closes its pipes, so a child
/// that reads its input sees the end of it, and then waits for the exit.
fn pClose(l: *Thread) Error!u32 {
    const p = toProcess(l, l.arg(1)) orelse return 0;
    const u = l.arg(1).as(Userdata);
    for (u.userValues()) |v| io_lib.closePipe(l, v);
    _ = try waitExit(l, p);
    return 0;
}

/// A collected process that still runs keeps running. Its exit is reaped
/// by the watcher, so it never stays a zombie.
fn pGc(l: *Thread) Error!u32 {
    const p = toProcess(l, l.arg(1)) orelse return 0;
    if (tryReap(p)) return 0;
    p.released = true;
    if (comptime windows) win.release(p) else sigwatch.adoptOrphan(p.pid);
    return 0;
}

// ---------------------------------------------------------------------
// Windows command lines

/// Appends `arg` quoted for `CommandLineToArgvW` and the C runtime, which
/// split the command line of a Windows program back into its arguments.
/// Backslashes are literal except before a quote, so a run of them that
/// precedes a quote, or the closing quote, is doubled.
pub fn appendArg(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) error{OutOfMemory}!void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) return buf.appendSlice(gpa, arg);
    try buf.append(gpa, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        if (c == '"') {
            try buf.appendNTimes(gpa, '\\', slashes * 2 + 1);
        } else try buf.appendNTimes(gpa, '\\', slashes);
        slashes = 0;
        try buf.append(gpa, c);
    }
    try buf.appendNTimes(gpa, '\\', slashes * 2);
    try buf.append(gpa, '"');
}

/// Appends `arg` for a batch file, which `cmd.exe` parses with rules of
/// its own. `%` and `!` expand variables and a quote or a line break ends
/// the argument early whatever the quoting, so an argument that holds one
/// of them cannot reach the batch file intact and is refused. Any other
/// argument with a space or a character that `cmd.exe` treats as an
/// operator is quoted.
pub fn appendBatchArg(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) error{ OutOfMemory, UnsafeBatchArgument }!void {
    if (std.mem.indexOfAny(u8, arg, "%!\"\r\n") != null) return error.UnsafeBatchArgument;
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t&|<>^(),;=") == null) return buf.appendSlice(gpa, arg);
    try buf.append(gpa, '"');
    try buf.appendSlice(gpa, arg);
    // A trailing backslash would escape the closing quote for a program
    // that the batch file passes the argument to.
    var n: usize = 0;
    while (n < arg.len and arg[arg.len - 1 - n] == '\\') n += 1;
    try buf.appendNTimes(gpa, '\\', n);
    try buf.append(gpa, '"');
}

fn isBatch(exe: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(exe, ".bat") or std.ascii.endsWithIgnoreCase(exe, ".cmd");
}

/// The command line for `argv`. A batch file runs as
/// `cmd.exe /d /e:ON /v:OFF /s /c ""exe" args"`, and `/s` makes `cmd.exe`
/// drop exactly the outer quotes.
pub fn commandLine(gpa: std.mem.Allocator, exe: []const u8, argv: []const []const u8) error{ OutOfMemory, UnsafeBatchArgument }![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (isBatch(exe)) {
        if (std.mem.indexOfAny(u8, exe, "%!\"\r\n") != null) return error.UnsafeBatchArgument;
        try buf.appendSlice(gpa, "cmd.exe /d /e:ON /v:OFF /s /c \"\"");
        try buf.appendSlice(gpa, exe);
        try buf.append(gpa, '"');
        for (argv[1..]) |a| {
            try buf.append(gpa, ' ');
            try appendBatchArg(gpa, &buf, a);
        }
        try buf.append(gpa, '"');
    } else {
        for (argv, 0..) |a, i| {
            if (i > 0) try buf.append(gpa, ' ');
            try appendArg(gpa, &buf, a);
        }
    }
    return buf.toOwnedSlice(gpa);
}

test "windows quoting" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { argv: []const []const u8, want: []const u8 }{
        .{ .argv = &.{ "prog", "a", "b c" }, .want = "prog a \"b c\"" },
        .{ .argv = &.{ "prog", "" }, .want = "prog \"\"" },
        .{ .argv = &.{ "prog", "say \"hi\"" }, .want = "prog \"say \\\"hi\\\"\"" },
        .{ .argv = &.{ "prog", "C:\\dir with space\\" }, .want = "prog \"C:\\dir with space\\\\\"" },
        .{ .argv = &.{ "prog", "a\\\\b" }, .want = "prog a\\\\b" },
        .{ .argv = &.{ "prog", "a\\\"b" }, .want = "prog \"a\\\\\\\"b\"" },
    };
    for (cases) |c| {
        const line = try commandLine(gpa, "C:\\prog.exe", c.argv);
        defer gpa.free(line);
        try std.testing.expectEqualStrings(c.want, line);
    }
    const bat = try commandLine(gpa, "C:\\t\\run.bat", &.{ "run", "x", "a b", "a&b" });
    defer gpa.free(bat);
    try std.testing.expectEqualStrings("cmd.exe /d /e:ON /v:OFF /s /c \"\"C:\\t\\run.bat\" x \"a b\" \"a&b\"\"", bat);
    try std.testing.expectError(error.UnsafeBatchArgument, commandLine(gpa, "run.cmd", &.{ "run", "100%" }));
    try std.testing.expectError(error.UnsafeBatchArgument, commandLine(gpa, "run.cmd", &.{ "run", "a\"b" }));
}

// ---------------------------------------------------------------------
// Windows processes

const win = if (windows) struct {
    const w = std.os.windows;
    const DUPLICATE_SAME_ACCESS: w.DWORD = 0x2;
    const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x20002;
    const WT_EXECUTEONLYONCE: w.ULONG = 0x8;
    const INFINITE: u32 = 0xFFFFFFFF;
    const GENERIC_READ: w.DWORD = 0x80000000;
    const GENERIC_WRITE: w.DWORD = 0x40000000;
    const FILE_SHARE_READ: w.DWORD = 0x1;
    const FILE_SHARE_WRITE: w.DWORD = 0x2;
    const OPEN_EXISTING: w.DWORD = 3;
    const STARTUPINFOEXW = extern struct {
        info: w.STARTUPINFOW,
        attribute_list: ?*anyopaque,
    };
    const WaitCallback = *const fn (?*anyopaque, w.BOOLEAN) callconv(.winapi) void;
    extern "kernel32" fn CreatePipe(read: *w.HANDLE, write: *w.HANDLE, attributes: ?*const w.SECURITY_ATTRIBUTES, size: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DuplicateHandle(source_process: w.HANDLE, source: w.HANDLE, target_process: w.HANDLE, target: *w.HANDLE, access: w.DWORD, inherit: w.BOOL, options: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: w.DWORD, flags: w.DWORD, size: *usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: w.DWORD, attribute: usize, value: *const anyopaque, size: usize, previous: ?*anyopaque, return_size: ?*usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetExitCodeProcess(process: w.HANDLE, code: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn TerminateProcess(process: w.HANDLE, code: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetProcessId(process: w.HANDLE) callconv(.winapi) w.DWORD;
    extern "kernel32" fn RegisterWaitForSingleObject(out: *?w.HANDLE, object: w.HANDLE, callback: WaitCallback, ctx: ?*anyopaque, ms: u32, flags: w.ULONG) callconv(.winapi) w.BOOL;
    extern "kernel32" fn UnregisterWait(handle: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: w.DWORD, share: w.DWORD, attributes: ?*const w.SECURITY_ATTRIBUTES, disposition: w.DWORD, flags: w.DWORD, template: ?w.HANDLE) callconv(.winapi) w.HANDLE;

    fn dup(h: w.HANDLE) ?w.HANDLE {
        if (h == w.INVALID_HANDLE_VALUE) return null;
        var d: w.HANDLE = undefined;
        const self = w.GetCurrentProcess();
        if (!DuplicateHandle(self, h, self, &d, 0, .TRUE, DUPLICATE_SAME_ACCESS).toBool()) return null;
        return d;
    }

    const Result = struct { process: w.HANDLE, id: i64, ends: Ends };

    const SpawnError = error{ OutOfMemory, UnsafeBatchArgument, SystemResources, FileNotFound, AccessDenied, NameTooLong, InvalidWtf8, Unexpected };

    fn spawn(gpa: std.mem.Allocator, exe: []const u8, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map, sin: Stream, sout: Stream, serr: Stream) SpawnError!Result {
        const line = try commandLine(gpa, exe, argv);
        defer gpa.free(line);
        const line_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidWtf8,
        };
        defer gpa.free(line_w);
        // A batch file runs through the cmd.exe of the system directory.
        const app_w: [:0]u16 = if (isBatch(exe)) blk: {
            const sys = std.mem.trimEnd(u16, w.getSystemDirectoryWtf16Le(), &.{ '/', '\\' });
            const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\cmd.exe");
            const app = try gpa.allocSentinel(u16, sys.len + suffix.len, 0);
            @memcpy(app[0..sys.len], sys);
            @memcpy(app[sys.len..], suffix);
            break :blk app;
        } else std.unicode.wtf8ToWtf16LeAllocZ(gpa, exe) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidWtf8,
        };
        defer gpa.free(app_w);
        const cwd_w: ?[:0]u16 = if (cwd) |c| std.unicode.wtf8ToWtf16LeAllocZ(gpa, c) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidWtf8,
        } else null;
        defer if (cwd_w) |c| gpa.free(c);

        // Handles the child receives, all inheritable duplicates that the
        // parent closes once CreateProcessW returns, and the parent ends
        // of the pipes, which it keeps on success.
        var child_h: [3]?w.HANDLE = .{ null, null, null };
        defer for (child_h) |h| if (h) |x| w.CloseHandle(x);
        var parent: [3]?w.HANDLE = .{ null, null, null };
        errdefer for (parent) |h| if (h) |x| w.CloseHandle(x);
        const params = w.peb().ProcessParameters;
        const inherited = [3]w.HANDLE{ params.hStdInput, params.hStdOutput, params.hStdError };
        const streams = [3]Stream{ sin, sout, serr };
        for (streams, 0..) |s, i| {
            switch (s) {
                .inherit => child_h[i] = dup(inherited[i]),
                .file => |f| child_h[i] = dup(f.handle),
                .null => {
                    const nul = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
                    const h = CreateFileW(nul, if (i == 0) GENERIC_READ else GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
                    if (h == w.INVALID_HANDLE_VALUE) return error.SystemResources;
                    defer w.CloseHandle(h);
                    child_h[i] = dup(h);
                },
                .pipe => {
                    var r: w.HANDLE = undefined;
                    var wr: w.HANDLE = undefined;
                    // A large buffer lets most writes finish at once.
                    if (!CreatePipe(&r, &wr, null, 1 << 16).toBool()) return error.SystemResources;
                    const mine = if (i == 0) wr else r;
                    const theirs = if (i == 0) r else wr;
                    parent[i] = mine;
                    child_h[i] = dup(theirs);
                    w.CloseHandle(theirs);
                },
                .stdout => child_h[i] = if (child_h[1]) |h| dup(h) else null,
            }
        }

        var list: [3]w.HANDLE = undefined;
        var count: usize = 0;
        for (child_h) |h| if (h) |v| {
            list[count] = v;
            count += 1;
        };
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_mem = try gpa.alignedAlloc(u8, .of(usize), @max(attr_size, 1));
        defer gpa.free(attr_mem);
        const attrs: *anyopaque = attr_mem.ptr;
        if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size).toBool()) return error.SystemResources;
        defer DeleteProcThreadAttributeList(attrs);
        if (count > 0 and !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &list, count * @sizeOf(w.HANDLE), null, null).toBool())
            return error.SystemResources;
        var si: STARTUPINFOEXW = .{
            .info = .{
                .cb = @sizeOf(STARTUPINFOEXW),
                .lpReserved = null,
                .lpDesktop = null,
                .lpTitle = null,
                .dwX = 0,
                .dwY = 0,
                .dwXSize = 0,
                .dwYSize = 0,
                .dwXCountChars = 0,
                .dwYCountChars = 0,
                .dwFillAttribute = 0,
                .dwFlags = w.STARTF_USESTDHANDLES,
                .wShowWindow = 0,
                .cbReserved2 = 0,
                .lpReserved2 = null,
                .hStdInput = child_h[0],
                .hStdOutput = child_h[1],
                .hStdError = child_h[2],
            },
            .attribute_list = attrs,
        };
        const env_block: ?std.process.Environ.WindowsBlock = if (env) |m| m.createWindowsBlock(gpa, .{ .zig_progress_handle = null }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return error.InvalidWtf8,
        } else null;
        defer if (env_block) |b| b.deinit(gpa);
        const env_ptr: ?[*:0]const u16 = if (env_block) |b| b.slice.ptr else null;
        var pi: w.PROCESS.INFORMATION = undefined;
        const inherit: w.BOOL = if (count > 0) .TRUE else .FALSE;
        if (!w.kernel32.CreateProcessW(app_w.ptr, line_w.ptr, null, null, inherit, .{ .extended_startupinfo_present = true, .create_unicode_environment = env_block != null }, env_ptr, if (cwd_w) |c| c.ptr else null, &si.info, &pi).toBool()) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .DIRECTORY => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .FILENAME_EXCED_RANGE => error.NameTooLong,
                else => error.Unexpected,
            };
        }
        w.CloseHandle(pi.hThread);
        const file = struct {
            fn of(h: ?w.HANDLE) ?std.Io.File {
                return if (h) |x| .{ .handle = x, .flags = .{ .nonblocking = false } } else null;
            }
        }.of;
        return .{
            .process = pi.hProcess,
            .id = GetProcessId(pi.hProcess),
            .ends = .{ .stdin = file(parent[0]), .stdout = file(parent[1]), .stderr = file(parent[2]) },
        };
    }

    fn onExit(ctx: ?*anyopaque, timed_out: w.BOOLEAN) callconv(.winapi) void {
        _ = ctx;
        _ = timed_out;
        sigwatch.childExited();
    }

    /// Registers a wait that reports the exit of `p` to the watcher.
    fn watch(p: *Process) void {
        var h: ?w.HANDLE = null;
        if (RegisterWaitForSingleObject(&h, p.pid, onExit, null, INFINITE, WT_EXECUTEONLYONCE).toBool()) p.wait_handle = h;
    }

    fn release(p: *Process) void {
        if (p.wait_handle) |h| _ = UnregisterWait(h);
        p.wait_handle = null;
        w.CloseHandle(p.pid);
    }

    fn tryReap(p: *Process) bool {
        if (p.released) return true;
        if (WaitForSingleObject(p.pid, 0) != 0) return false;
        var code: w.DWORD = 0;
        _ = GetExitCodeProcess(p.pid, &code);
        p.status = .{ .exited = code };
        p.released = true;
        release(p);
        return true;
    }

    fn block(p: *Process) void {
        _ = WaitForSingleObject(p.pid, INFINITE);
    }

    fn terminate(p: *Process) bool {
        return TerminateProcess(p.pid, 1).toBool();
    }
} else struct {};
