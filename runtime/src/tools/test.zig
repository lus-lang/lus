//! `lus test`: the built-in test runner.
//!
//! Test files are `*_test.lus` files. Every top-level function whose name
//! ends in `_test` is a test, and top-level code runs once as setup. A
//! top-level `NAME_cases` table runs `NAME_test` once per entry. In test
//! files `assert` reports the failing expression and the values of its
//! operands, `skip(reason)` skips the current test, and `snapshot(value)`
//! compares a value against `__snapshots__/FILE.snap`. `raises(f, pattern)`
//! expects `f` to raise and returns the error, and `same(a, b)` compares
//! two values structurally. `TEST_DIR` names the directory of the test
//! file, for fixtures, and the environment variable `LUS_EXE` names the
//! interpreter running the tests.
//!
//! Each file runs in its own child process inside a fresh temporary
//! directory, and files run in parallel. The result of a file is printed
//! as soon as it ends. A file that writes no output for the timeout, or
//! that runs longer than the file timeout, is reported as timed out, and
//! every process it started is killed.

const std = @import("std");
const lus = @import("../lus.zig");
const ast = lus.syntax.ast;
const parser = lus.syntax.parser;
const walk = @import("../syntax/walk.zig");
const api = lus.api;
const aux = lus.lib.aux;
const ops = lus.vm.ops;
const out = lus.lib.out;
const Value = lus.vm.value.Value;
const Thread = lus.vm.state.Thread;
const Table = lus.vm.object.Table;
const String = lus.vm.object.String;
const Error = lus.vm.state.Error;
const shell = @import("../lib/shell.zig");

const Options = struct {
    paths: std.ArrayList([]const u8) = .empty,
    filter: ?[]const u8 = null,
    update: bool = false,
    json: bool = false,
    jobs: usize = 0,
    timeout_s: i64 = 60,
    /// The longest a file may run in all, output or not. Ten times the
    /// timeout unless `--file-timeout` sets it.
    file_timeout_s: ?i64 = null,
    verbose: bool = false,
    /// Run the `lus` code blocks of Markdown files instead of test files.
    doc: bool = false,
    tmp_root: []const u8 = "/tmp",

    fn fileTimeout(o: *const Options) i64 {
        return o.file_timeout_s orelse o.timeout_s *| 10;
    }
};

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    // Child mode: run one file and print result records.
    if (args.len >= 2 and std.mem.eql(u8, args[0], "--run-one")) {
        var filter: ?[]const u8 = null;
        var update = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-u")) update = true;
            if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
                filter = args[i + 1];
                i += 1;
            }
        }
        if (isDoc(args[1])) return runDocFile(init, args[1], filter);
        return runOne(init, args[1], filter, update);
    }
    var o: Options = .{};
    defer o.paths.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--update")) {
            o.update = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "-v")) {
            o.verbose = true;
        } else if (std.mem.eql(u8, a, "--doc")) {
            o.doc = true;
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < args.len) {
            i += 1;
            o.filter = args[i];
        } else if (std.mem.eql(u8, a, "--jobs") and i + 1 < args.len) {
            i += 1;
            o.jobs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--timeout") and i + 1 < args.len) {
            i += 1;
            o.timeout_s = try std.fmt.parseInt(i64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--file-timeout") and i + 1 < args.len) {
            i += 1;
            o.file_timeout_s = try std.fmt.parseInt(i64, args[i], 10);
        } else {
            try o.paths.append(gpa, a);
        }
    }
    if (o.paths.items.len == 0) try o.paths.append(gpa, ".");
    if (init.environ_map.get("TMPDIR")) |t| o.tmp_root = t;
    return runAll(init, &o);
}

// ---------------------------------------------------------------------
// Parent: discovery, parallel execution, reporting

const FileResult = struct {
    path: []const u8,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    crashed: bool = false,
    timed_out: bool = false,
    report: std.ArrayList(u8) = .empty,
    records: std.ArrayList(u8) = .empty,
    millis: i64 = 0,
};

fn isDoc(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

fn discover(gpa: std.mem.Allocator, io: std.Io, path: []const u8, files: *std.ArrayList([]const u8), doc: bool) !void {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        std.debug.print("lus test: cannot open {s}\n", .{path});
        return error.NotFound;
    };
    if (st.kind != .directory) {
        try files.append(gpa, try gpa.dupe(u8, path));
        return;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (doc) {
            if (!isDoc(entry.basename)) continue;
        } else if (!std.mem.endsWith(u8, entry.basename, "_test.lus")) continue;
        const skip_dirs = [_][]const u8{ "node_modules", ".git", "zig-out", ".zig-cache" };
        var skip = false;
        for (skip_dirs) |d| {
            if (std.mem.indexOf(u8, entry.path, d) != null) skip = true;
        }
        if (skip) continue;
        try files.append(gpa, try std.fs.path.join(gpa, &.{ path, entry.path }));
    }
}

fn runAll(init: std.process.Init, o: *Options) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    for (o.paths.items) |p| discover(gpa, io, p, &files, o.doc) catch return 2;
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    const results = try gpa.alloc(FileResult, files.items.len);
    for (results, files.items) |*r, f| r.* = .{ .path = f };
    const jobs = if (o.jobs > 0) o.jobs else @max(std.Thread.getCpuCount() catch 4, 1);
    var pool: Pool = .{ .gpa = gpa, .io = io, .exe = exe, .o = o, .results = results, .jobs = @min(jobs, results.len) };
    pool.lock();
    while (pool.live < pool.jobs) try pool.startWorker();
    pool.unlock();
    pool.watch();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var bad_files: usize = 0;
    var broken: usize = 0;
    for (results) |*r| {
        passed += r.passed;
        failed += r.failed;
        skipped += r.skipped;
        if (r.failed > 0 or r.crashed or r.timed_out) bad_files += 1;
        // A file that crashed, timed out, or failed to load runs no test,
        // so the summary counts it apart from failed tests.
        if (r.crashed or r.timed_out) broken += 1;
    }
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    if (!o.json) {
        try report.print(gpa, "\n{d} files, {d} passed, {d} failed, {d} skipped", .{ results.len, passed, failed, skipped });
        if (broken > 0) try report.print(gpa, ", {d} {s} with errors", .{ broken, if (broken == 1) "file" else "files" });
        try report.append(gpa, '\n');
    }
    std.Io.File.stdout().writeStreamingAll(io, report.items) catch {};
    const code: u8 = if (bad_files == 0) 0 else 1;
    // A worker left behind may still hold its file, so the process ends
    // here without waiting for it or freeing what it might touch.
    if (pool.left_behind) std.process.exit(code);
    for (pool.threads.items) |th| th.join();
    pool.threads.deinit(gpa);
    for (pool.slots.items) |slot| gpa.destroy(slot);
    pool.slots.deinit(gpa);
    for (results) |*r| {
        r.report.deinit(gpa);
        r.records.deinit(gpa);
    }
    gpa.free(results);
    return code;
}

/// How long a file that was killed for its timeout has to end before
/// the runner reports it and moves on without its worker.
const grace_ns: i96 = 5 * std.time.ns_per_s;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// What the workers and the watchdog share. `mutex` guards every field
/// after it and the slots.
const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    o: *Options,
    results: []FileResult,
    /// How many files run at once.
    jobs: usize,
    mutex: std.Io.Mutex = .init,
    /// One slot per worker ever started, including the workers left
    /// behind. Each slot is allocated on its own, so its address stays
    /// valid for its worker while the list grows.
    slots: std.ArrayList(*Slot) = .empty,
    /// The index of the next file to pool.
    next: usize = 0,
    /// How many files have been reported.
    finished: usize = 0,
    /// How many workers run and were not left behind.
    live: usize = 0,
    /// True when the watchdog reported a file whose worker never came back.
    left_behind: bool = false,
    threads: std.ArrayList(std.Thread) = .empty,

    fn lock(pool: *Pool) void {
        pool.mutex.lockUncancelable(pool.io);
    }

    fn unlock(pool: *Pool) void {
        pool.mutex.unlock(pool.io);
    }

    /// Starts a worker on a slot of its own. The caller holds the lock.
    fn startWorker(pool: *Pool) !void {
        const slot = try pool.gpa.create(Slot);
        errdefer pool.gpa.destroy(slot);
        slot.* = .{};
        try pool.slots.ensureUnusedCapacity(pool.gpa, 1);
        try pool.threads.ensureUnusedCapacity(pool.gpa, 1);
        pool.threads.appendAssumeCapacity(try std.Thread.spawn(.{}, work, .{ pool, slot }));
        pool.slots.appendAssumeCapacity(slot);
        pool.live += 1;
    }

    /// Prints the result of a file as soon as it is known. Each result
    /// is one unbuffered write, so it reaches a pipe or a log at once.
    /// The caller holds the lock.
    fn publish(pool: *Pool, r: *const FileResult) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(pool.gpa);
        formatResult(pool.gpa, pool.o, r, &text) catch {};
        std.Io.File.stdout().writeStreamingAll(pool.io, text.items) catch {};
        pool.finished += 1;
    }

    /// Records that the file of `slot` made progress, which restarts its
    /// timeout.
    fn touch(pool: *Pool, slot: *Slot) void {
        pool.lock();
        defer pool.unlock();
        slot.active_at = nowNs(pool.io);
    }

    fn work(pool: *Pool, slot: *Slot) void {
        while (true) {
            pool.lock();
            if (slot.left or pool.next >= pool.results.len) {
                pool.unlock();
                return;
            }
            const index = pool.next;
            pool.next += 1;
            const now = nowNs(pool.io);
            slot.* = .{ .file = index, .started_at = now, .active_at = now };
            pool.unlock();
            var r: FileResult = .{ .path = pool.results[index].path };
            runChild(pool, slot, &r) catch |e| {
                r.crashed = true;
                r.report.print(pool.gpa, "runner error: {s}\n", .{@errorName(e)}) catch {};
            };
            pool.lock();
            const left = slot.left;
            if (!left) {
                pool.results[index] = r;
                pool.publish(&pool.results[index]);
                slot.file = null;
            }
            pool.unlock();
            if (left) {
                r.report.deinit(pool.gpa);
                r.records.deinit(pool.gpa);
                return;
            }
        }
    }

    /// Runs on the main thread until every file is reported. A file
    /// whose child shows no progress for the timeout, or runs longer than
    /// the file timeout, has its whole process tree killed. When its
    /// worker still has not come back after the grace period, because a
    /// call it made blocks in the system, the file is reported as timed
    /// out and a new worker takes its place for the rest of the files.
    fn watch(pool: *Pool) void {
        const timeout_ns = @as(i96, pool.o.timeout_s) * std.time.ns_per_s;
        const file_timeout_ns = @as(i96, pool.o.fileTimeout()) * std.time.ns_per_s;
        while (true) {
            pool.lock();
            if (pool.finished == pool.results.len) {
                pool.unlock();
                return;
            }
            const t = nowNs(pool.io);
            for (pool.slots.items) |slot| {
                const index = slot.file orelse continue;
                if (slot.left) continue;
                if (slot.killed_at) |k| {
                    if (t - k < grace_ns) continue;
                    slot.left = true;
                    slot.file = null;
                    pool.left_behind = true;
                    pool.live -= 1;
                    const r = &pool.results[index];
                    r.timed_out = true;
                    r.millis = @intCast(@divTrunc(t - slot.started_at, std.time.ns_per_ms));
                    timeoutReport(pool.gpa, pool.o, slot.cause, &r.report) catch {};
                    r.report.appendSlice(pool.gpa, "  the runner left it behind when it did not stop\n") catch {};
                    pool.publish(r);
                } else if (t - slot.active_at >= timeout_ns or t - slot.started_at >= file_timeout_ns) {
                    slot.killed_at = t;
                    slot.cause = if (t - slot.active_at >= timeout_ns) .silent else .total;
                    if (slot.tree) |tree| tree.kill();
                }
            }
            // Workers left behind no longer count, so new ones take the
            // rest of the files. They start after the scan, so the scan
            // never sees a slot it added.
            while (pool.live < pool.jobs and pool.next < pool.results.len) {
                pool.startWorker() catch {
                    if (pool.live == 0) pool.failRest();
                    break;
                };
            }
            pool.unlock();
            pool.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }

    /// Reports every file not yet started as a runner error, when no
    /// worker could be started for them. The caller holds the lock.
    fn failRest(pool: *Pool) void {
        while (pool.next < pool.results.len) : (pool.next += 1) {
            const r = &pool.results[pool.next];
            r.crashed = true;
            r.report.print(pool.gpa, "runner error: no worker could start\n", .{}) catch {};
            pool.publish(r);
        }
    }
};

/// Why the watchdog stopped a file.
const Cause = enum {
    /// The file wrote no output for the timeout.
    silent,
    /// The file ran longer than the file timeout.
    total,
};

/// The line that reports why a file timed out.
fn timeoutReport(gpa: std.mem.Allocator, o: *const Options, cause: Cause, report: *std.ArrayList(u8)) !void {
    switch (cause) {
        .silent => try report.print(gpa, "  timed out after {d} s without output\n", .{o.timeout_s}),
        .total => try report.print(gpa, "  timed out after running for the file timeout of {d} s\n", .{o.fileTimeout()}),
    }
}

/// The file a worker runs and what the watchdog knows about it.
const Slot = struct {
    file: ?usize = null,
    /// When the file started.
    started_at: i96 = 0,
    /// When the file started or last wrote output.
    active_at: i96 = 0,
    /// The processes of the file, once its child runs.
    tree: ?ProcessTree = null,
    /// When the watchdog killed the processes of the file, and why.
    killed_at: ?i96 = null,
    cause: Cause = .silent,
    /// True when the watchdog reported the file without its worker.
    left: bool = false,
};

const windows = @import("builtin").os.tag == .windows;

/// The processes that one test file starts. The child that runs a file
/// leads a process group of its own on POSIX systems and runs in a job
/// object on Windows. Every process it starts through `io.popen` or
/// `os.execute` joins that group or job, so the runner can stop all of
/// them when the file times out and when it ends.
const ProcessTree = struct {
    id: if (windows) std.os.windows.HANDLE else std.posix.pid_t,

    /// Takes in a child that was started suspended on Windows and lets
    /// it pool. Returns null when no job object could hold it, and the
    /// child then runs without one.
    fn adopt(child: *std.process.Child) ?ProcessTree {
        if (comptime !windows) return .{ .id = child.id.? };
        defer _ = win.ResumeThread(child.thread_handle);
        const job = win.CreateJobObjectW(null, null) orelse return null;
        var limits = std.mem.zeroes(win.ExtendedLimit);
        limits.basic.LimitFlags = win.kill_on_job_close;
        if (!win.SetInformationJobObject(job, win.extended_limit_information, &limits, @sizeOf(win.ExtendedLimit)).toBool() or
            !win.AssignProcessToJobObject(job, child.id.?).toBool())
        {
            std.os.windows.CloseHandle(job);
            return null;
        }
        return .{ .id = job };
    }

    fn kill(tree: ProcessTree) void {
        if (comptime windows) {
            _ = win.TerminateJobObject(tree.id, 124);
        } else {
            _ = std.posix.system.kill(-tree.id, .KILL);
        }
    }

    /// Whether `settle` can wait for the leader without reaping it.
    const can_settle = switch (@import("builtin").os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };

    /// Waits until the leader of the group has exited and kills the rest
    /// of the group, on POSIX systems that can wait for a child without
    /// reaping it. The leader stays a zombie until it is reaped, which
    /// keeps its process group id from naming another group. Returns
    /// false when the group was left as it was.
    fn settle(tree: ProcessTree) bool {
        if (comptime windows or !can_settle) return false;
        const p_pid: c_int = 1;
        const wexited: c_int = 0x4;
        const wnowait: c_int = if (@import("builtin").os.tag == .linux) 0x01000000 else 0x20;
        var info: [256]u8 align(16) = undefined;
        while (posix_wait.waitid(p_pid, @intCast(tree.id), &info, wexited | wnowait) != 0) {
            if (std.posix.errno(-1) != .INTR) return false;
        }
        tree.kill();
        return true;
    }

    /// Kills what remains of the tree once its child has ended. A group
    /// that `settle` already killed is not signalled again, since its
    /// leader may be reaped and its id reused.
    fn release(tree: ProcessTree, settled: bool) void {
        if (!settled) tree.kill();
        if (comptime windows) std.os.windows.CloseHandle(tree.id);
    }
};

const posix_wait = struct {
    extern "c" fn waitid(idtype: c_int, id: c_uint, info: *anyopaque, options: c_int) c_int;
};

const win = if (windows) struct {
    const w = std.os.windows;
    const kill_on_job_close: u32 = 0x2000;
    const extended_limit_information: c_int = 9;
    const BasicLimit = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: u32,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: u32,
        Affinity: usize,
        PriorityClass: u32,
        SchedulingClass: u32,
    };
    const ExtendedLimit = extern struct {
        basic: BasicLimit,
        io_counters: [6]u64,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: w.HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: w.HANDLE, process: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateJobObject(job: w.HANDLE, code: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ResumeThread(thread: w.HANDLE) callconv(.winapi) u32;
} else struct {};

/// Appends the lines that report one file.
fn formatResult(gpa: std.mem.Allocator, o: *const Options, r: *const FileResult, text: *std.ArrayList(u8)) !void {
    if (o.json) return text.appendSlice(gpa, r.records.items);
    const ok = r.failed == 0 and !r.crashed and !r.timed_out;
    const mark = if (ok) "ok  " else "FAIL";
    try text.print(gpa, "{s} {s} ({d} passed", .{ mark, r.path, r.passed });
    if (r.failed > 0) try text.print(gpa, ", {d} failed", .{r.failed});
    if (r.skipped > 0) try text.print(gpa, ", {d} skipped", .{r.skipped});
    try text.print(gpa, ", {d} ms)\n", .{r.millis});
    if (!ok or o.verbose) try text.appendSlice(gpa, r.report.items);
}

fn runChild(pool: *Pool, slot: *Slot, r: *FileResult) !void {
    const gpa = pool.gpa;
    const io = pool.io;
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, r.path, gpa);
    defer gpa.free(abs);
    // A fresh working directory per file.
    const tmp_root = pool.o.tmp_root;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(gpa, "{s}/lus-test-{x}", .{ std.mem.trimEnd(u8, tmp_root, "/"), std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ pool.exe, "test", "--run-one", abs });
    if (pool.o.update) try argv.append(gpa, "-u");
    if (pool.o.filter) |f| try argv.appendSlice(gpa, &.{ "--filter", f });
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (comptime windows) null else 0,
        .start_suspended = windows,
    });
    defer if (child.id != null) child.kill(io);
    const tree = ProcessTree.adopt(&child);
    {
        pool.lock();
        defer pool.unlock();
        slot.tree = tree;
        if (slot.killed_at != null) if (tree) |t| t.kill();
    }
    // Every way out kills what remains of the processes of the file.
    var settled = false;
    defer {
        pool.lock();
        defer pool.unlock();
        slot.tree = null;
        if (tree) |t| t.release(settled);
    }

    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    // On an error the processes die before the reader is torn down, so
    // no read it still has pending waits on a writer that lives on.
    errdefer if (tree) |t| t.kill();
    // The reads wait without a timeout. The watchdog kills the processes
    // of a file that stops making progress, which closes the pipes.
    while (reader.fill(64, .none)) |_| {
        pool.touch(slot);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    // The rest of the group dies before the leader is reaped, and the
    // watchdog no longer signals a group whose leader may be gone.
    if (tree) |t| {
        if (t.settle()) {
            settled = true;
            pool.lock();
            defer pool.unlock();
            slot.tree = null;
        }
    }
    const status = try shell.wait(io, &child);
    const stdout = try reader.toOwnedSlice(0);
    defer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    defer gpa.free(stderr);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    r.millis = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, std.time.ns_per_ms));
    var cause: Cause = .silent;
    {
        pool.lock();
        defer pool.unlock();
        r.timed_out = slot.killed_at != null;
        cause = slot.cause;
    }
    // Parse the result records. Everything else is test output.
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "\x1e")) {
            const rec = line[1..];
            try r.records.appendSlice(gpa, rec);
            try r.records.append(gpa, '\n');
            const st = recordField(rec, "status");
            const name = recordField(rec, "name");
            if (std.mem.eql(u8, st, "pass")) {
                r.passed += 1;
            } else if (std.mem.eql(u8, st, "skip")) {
                r.skipped += 1;
                const why = try unescape(gpa, recordField(rec, "message"));
                defer gpa.free(why);
                try r.report.print(gpa, "  skip {s}: {s}\n", .{ name, why });
            } else {
                r.failed += 1;
                const msg = try unescape(gpa, recordField(rec, "message"));
                defer gpa.free(msg);
                try r.report.print(gpa, "  FAIL {s}\n", .{name});
                var ml = std.mem.splitScalar(u8, msg, '\n');
                while (ml.next()) |m| try r.report.print(gpa, "       {s}\n", .{m});
            }
        } else if (line.len > 0) {
            try output.appendSlice(gpa, line);
            try output.append(gpa, '\n');
        }
    }
    if (r.timed_out) {
        // The tests reported above ended, and the next one never did.
        try timeoutReport(gpa, pool.o, cause, &r.report);
    } else {
        // The full exit code counts, so a Windows code such as 256 or a
        // crash code is never clean.
        const clean = switch (status) {
            .exited => |code| code == 0 or code == 1,
            .signal => false,
        };
        if (!clean or (r.passed + r.failed + r.skipped == 0 and stderr.len > 0)) {
            r.crashed = !clean or r.failed == 0;
            try r.report.print(gpa, "  file error:\n", .{});
        }
    }
    if (r.timed_out or r.crashed) {
        if (stderr.len > 0) {
            if (r.timed_out) try r.report.print(gpa, "  standard error:\n", .{});
            var el = std.mem.splitScalar(u8, std.mem.trimEnd(u8, stderr, "\n"), '\n');
            while (el.next()) |m| try r.report.print(gpa, "       {s}\n", .{m});
        }
    }
    if ((r.failed > 0 or r.crashed or r.timed_out) and output.items.len > 0) {
        try r.report.print(gpa, "  output:\n", .{});
        var ol = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.items, "\n"), '\n');
        while (ol.next()) |m| try r.report.print(gpa, "       {s}\n", .{m});
    }
}

/// Extracts a string field from a one-line JSON record.
fn recordField(rec: []const u8, key: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return "";
    const at = std.mem.indexOf(u8, rec, pat) orelse return "";
    const start = at + pat.len;
    var i = start;
    while (i < rec.len) : (i += 1) {
        if (rec[i] == '\\') {
            i += 1;
            continue;
        }
        if (rec[i] == '"') break;
    }
    return rec[start..@min(i, rec.len)];
}

fn unescape(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try o.append(gpa, switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                else => s[i],
            });
        } else try o.append(gpa, s[i]);
    }
    return o.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------
// Child: run one file

const TestEntry = struct { name: []const u8 };

fn runOne(init: std.process.Init, path: []const u8, filter: ?[]const u8, update: bool) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        std.debug.print("cannot open {s} ({s})\n", .{ path, @errorName(e) });
        return 2;
    };
    defer gpa.free(src);
    const l = try api.newState(gpa, io);
    defer api.close(l);
    defer out.deinit(l.g);
    // Tests that start the interpreter find it through LUS_EXE.
    if (init.environ_map.get("LUS_EXE") == null) {
        if (std.process.executablePathAlloc(io, gpa)) |exe| {
            defer gpa.free(exe);
            init.environ_map.put("LUS_EXE", exe) catch {};
        } else |_| {}
    }
    l.g.environ = init.environ_map;
    try api.setFlags(l, &.{});
    api.openLibs(l) catch return 2;
    var snap = Snapshots{ .gpa = gpa, .io = io, .path = path, .update = update };
    defer snap.deinit();
    snap.load() catch {};
    try installHelpers(l, &snap);
    // TEST_DIR is the directory holding the test file, for fixtures. The
    // test itself runs in a fresh temporary directory.
    try aux.setGlobal(l, "TEST_DIR", try l.newStringValue(std.fs.path.dirname(path) orelse "."));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chunkname = try std.fmt.allocPrint(arena, "@{s}", .{std.fs.path.basename(path)});
    var diag: ?[]const u8 = null;
    var chunk = parser.parse(gpa, arena, src, .{ .chunkname = chunkname }, &diag) catch {
        std.debug.print("{s}\n", .{diag orelse "syntax error"});
        return 2;
    };
    var tests: std.ArrayList([]const u8) = .empty;
    var cases: std.ArrayList([]const u8) = .empty;
    try transform(arena, &chunk, src, &tests, &cases);
    const r = try lus.compile.codegen.compileAst(l.g, arena, chunk, .{ .chunkname = chunkname });
    const p = switch (r) {
        .err => |m| {
            defer gpa.free(m);
            std.debug.print("{s}\n", .{m});
            return 2;
        },
        .ok => |p| p,
    };
    // Run the file's top-level code: it returns the test registry.
    const base = l.top;
    const cl = try api.newMainClosure(l, p, l.g.globals);
    try l.push(Value.obj(.closure, cl));
    l.want_traceback = true;
    if (!api.pcall(l, 0, 1)) {
        reportFileError(l);
        return 2;
    }
    // Coroutines that the top-level code detached end before the tests.
    l.err_traceback = null;
    if (!api.runPending(l, true)) {
        reportFileError(l);
        return 2;
    }
    // The registry of tests stays on the stack so it remains rooted while
    // the tests run and allocate.
    const registry = l.stack[base];
    l.top = base + 1;
    var failed = false;
    for (tests.items, 0..) |name, ti| {
        if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
        const fv = lus.vm.table.getInt(registry.as(Table), @intCast(ti * 2 + 2));
        const case_name = try std.fmt.allocPrint(arena, "{s}_cases", .{name[0 .. name.len - "_test".len]});
        var case_tbl: Value = .nil;
        for (cases.items, 0..) |cn, ci| {
            if (std.mem.eql(u8, cn, case_name)) case_tbl = lus.vm.table.getInt(registry.as(Table), @intCast(tests.items.len * 2 + ci + 1));
        }
        if (case_tbl.tag == .table) {
            // Positional entries run in order, then keyed entries, each
            // labelled by its key.
            const ct = case_tbl.as(Table);
            var k: i64 = 1;
            while (true) : (k += 1) {
                const entry = lus.vm.table.getInt(ct, k);
                if (entry.isNil()) break;
                const label = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, k });
                if (!runTest(l, &snap, label, fv, entry)) failed = true;
            }
            const positional = k - 1;
            var key: Value = .nil;
            while (lus.vm.table.next(ct, key) catch null) |e| : (key = e.key) {
                if (e.key.tag == .integer and e.key.asInt() >= 1 and e.key.asInt() <= positional) continue;
                const label = if (e.key.tag == .string)
                    try std.fmt.allocPrint(arena, "{s}[{s}]", .{ name, e.key.as(String).bytes() })
                else
                    try std.fmt.allocPrint(arena, "{s}[?]", .{name});
                if (!runTest(l, &snap, label, fv, e.val)) failed = true;
            }
        } else {
            if (!runTest(l, &snap, name, fv, null)) failed = true;
        }
    }
    snap.save() catch |e| std.debug.print("cannot write snapshots ({s})\n", .{@errorName(e)});
    out.flushAll(l.g);
    return if (failed) 1 else 0;
}

fn reportFileError(l: *Thread) void {
    const msg = api.errorMessage(l, l.err);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.print(l.g.gpa, "{s}\n", .{msg}) catch return;
    if (l.err_traceback) |tb| buf.print(l.g.gpa, "{s}\n", .{tb.bytes()}) catch {};
    out.stderr(l.g, buf.items);
}

// ---------------------------------------------------------------------
// Doc tests

/// Runs every ```lus code block of a Markdown file as its own test, in a
/// fresh state with every permission granted. A block whose fence reads
/// ```lus nocheck is a fragment and is skipped.
fn runDocFile(init: std.process.Init, path: []const u8, filter: ?[]const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        std.debug.print("cannot open {s} ({s})\n", .{ path, @errorName(e) });
        return 2;
    };
    defer gpa.free(src);
    var failed = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: usize = 0;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var in_block = false;
    var skip_block = false;
    var start_line: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimStart(u8, raw, " \t");
        if (!in_block) {
            if (std.mem.startsWith(u8, line, "```lus")) {
                // A fence such as ```lusc names another language.
                const after = line["```lus".len..];
                if (after.len > 0 and std.ascii.isAlphanumeric(after[0])) continue;
                const meta = std.mem.trim(u8, after, " \t\r");
                in_block = true;
                skip_block = std.mem.indexOf(u8, meta, "nocheck") != null;
                start_line = lineno + 1;
                code.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            in_block = false;
            const name = try std.fmt.allocPrint(gpa, "line {d}", .{start_line});
            defer gpa.free(name);
            if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
            if (skip_block) {
                writeRecord(gpa, io, "skip", name, "nocheck");
                continue;
            }
            if (!try runDocBlock(init, path, start_line, code.items, name)) failed = true;
            continue;
        }
        try code.appendSlice(gpa, raw);
        try code.append(gpa, '\n');
    }
    return if (failed) 1 else 0;
}

fn runDocBlock(init: std.process.Init, path: []const u8, line: usize, code: []const u8, name: []const u8) !bool {
    const gpa = init.gpa;
    const io = init.io;
    const l = try api.newState(gpa, io);
    l.g.environ = init.environ_map;
    try api.setFlags(l, &.{});
    api.openLibs(l) catch {
        api.close(l);
        return false;
    };
    api.grantPledges(l, &.{"all"}) catch {};
    const chunkname = try std.fmt.allocPrint(gpa, "={s}:{d}", .{ std.fs.path.basename(path), line });
    defer gpa.free(chunkname);
    var ok = true;
    var msg: []u8 = &.{};
    defer gpa.free(msg);
    api.load(l, code, chunkname) catch {
        ok = false;
    };
    if (ok) ok = api.pcall(l, 0, 0);
    if (!ok) msg = try gpa.dupe(u8, api.errorMessage(l, l.stack[l.top - 1]));
    if (ok and !api.runPending(l, true)) {
        ok = false;
        msg = try gpa.dupe(u8, api.errorMessage(l, l.err));
    }
    api.close(l);
    writeRecord(gpa, io, if (ok) "pass" else "fail", name, msg);
    return ok;
}

fn writeRecord(gpa: std.mem.Allocator, io: std.Io, status: []const u8, name: []const u8, msg: []const u8) void {
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    rec.appendSlice(gpa, "\x1e{\"status\":\"") catch return;
    rec.appendSlice(gpa, status) catch return;
    rec.appendSlice(gpa, "\",\"name\":\"") catch return;
    jsonEscape(gpa, &rec, name) catch return;
    rec.appendSlice(gpa, "\",\"message\":\"") catch return;
    jsonEscape(gpa, &rec, msg) catch return;
    rec.appendSlice(gpa, "\"}\n") catch return;
    std.Io.File.stdout().writeStreamingAll(io, rec.items) catch {};
}

fn runTest(l: *Thread, snap: *Snapshots, name: []const u8, f: Value, case: ?Value) bool {
    const gpa = l.g.gpa;
    snap.begin(name);
    const base = l.top;
    l.push(f) catch return false;
    var nargs: u32 = 0;
    if (case) |cv| {
        if (cv.tag == .table) {
            var k: i64 = 1;
            while (true) : (k += 1) {
                const v = lus.vm.table.getInt(cv.as(Table), k);
                if (v.isNil()) break;
                l.push(v) catch return false;
                nargs += 1;
            }
        } else {
            l.push(cv) catch return false;
            nargs = 1;
        }
    }
    // Each test starts from the file's permissions, and its pledge
    // changes are undone afterwards, so tests stay independent.
    l.err_traceback = null;
    const pledge = lus.vm.pledge;
    const saved = pledge.save(l);
    var ok = api.pcall(l, nargs, 0);
    var err: Value = if (ok) .nil else l.stack[l.top - 1];
    // A test ends when the coroutines it detached have ended. One that
    // failed with nothing left to collect its error fails the test.
    if (!api.runPending(l, true) and ok) {
        ok = false;
        err = l.err;
        l.push(err) catch {};
    }
    pledge.restore(l, saved);
    var status: []const u8 = "pass";
    var msg: []const u8 = "";
    if (!ok) {
        if (skipReason(l, err)) |reason| {
            status = "skip";
            msg = reason;
        } else {
            status = "fail";
            msg = api.errorMessage(l, err);
        }
    }
    l.top = base;
    out.flushAll(l.g);
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    rec.appendSlice(gpa, "\x1e{\"status\":\"") catch return false;
    rec.appendSlice(gpa, status) catch return false;
    rec.appendSlice(gpa, "\",\"name\":\"") catch return false;
    jsonEscape(gpa, &rec, name) catch return false;
    rec.appendSlice(gpa, "\",\"message\":\"") catch return false;
    jsonEscape(gpa, &rec, msg) catch return false;
    rec.appendSlice(gpa, "\"}\n") catch return false;
    std.Io.File.stdout().writeStreamingAll(l.g.io, rec.items) catch {};
    return ok or std.mem.eql(u8, status, "skip");
}

fn jsonEscape(gpa: std.mem.Allocator, o: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try o.appendSlice(gpa, "\\\""),
        '\\' => try o.appendSlice(gpa, "\\\\"),
        '\n' => try o.appendSlice(gpa, "\\n"),
        '\t' => try o.appendSlice(gpa, "\\t"),
        0...8, 11...31 => try o.print(gpa, "\\u{x:0>4}", .{c}),
        else => try o.append(gpa, c),
    };
}

// ---------------------------------------------------------------------
// Source transformation

fn appendOnce(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |n| if (std.mem.eql(u8, n, name)) return;
    try list.append(arena, name);
}

/// Collects tests and case tables, rewrites `assert` into power asserts,
/// and makes the chunk return its tests as {name1, fn1, ..., cases...}.
fn transform(arena: std.mem.Allocator, chunk: *ast.Chunk, src: []const u8, tests: *std.ArrayList([]const u8), cases: *std.ArrayList([]const u8)) !void {
    const stats = chunk.block.stats;
    for (stats) |s| {
        switch (s.kind) {
            .local_function => |lf| {
                if (std.mem.endsWith(u8, lf.name.text, "_test")) try tests.append(arena, lf.name.text);
            },
            .function => |f| {
                if (f.path.len == 1 and f.method == null and std.mem.endsWith(u8, f.path[0].text, "_test")) try tests.append(arena, f.path[0].text);
            },
            .local => |l| {
                for (l.names) |n| {
                    if (std.mem.endsWith(u8, n.name.text, "_test")) try tests.append(arena, n.name.text);
                    if (std.mem.endsWith(u8, n.name.text, "_cases")) try cases.append(arena, n.name.text);
                }
            },
            .global => |g| {
                for (g.names) |n| {
                    if (std.mem.endsWith(u8, n.name.text, "_cases")) try appendOnce(arena, cases, n.name.text);
                }
            },
            // A case table may also be a plain global assignment.
            .assign => |a| {
                for (a.targets) |t| {
                    if (t.kind == .name and std.mem.endsWith(u8, t.kind.name.text, "_cases")) try appendOnce(arena, cases, t.kind.name.text);
                }
            },
            else => {},
        }
    }
    // Power asserts.
    const V = walk.Visitor(*const Rewrite);
    const rw: Rewrite = .{ .arena = arena, .src = src };
    const v: V = .{ .ctx = &rw, .func = Rewrite.visit };
    try v.block(chunk.block);
    // return { name1, fn1, ..., case1, ... }
    var fields: std.ArrayList(ast.Field) = .empty;
    const span = chunk.block.span;
    for (tests.items) |name| {
        try fields.append(arena, .{ .kind = .{ .positional = try mk(arena, span, .{ .string = name }) } });
        try fields.append(arena, .{ .kind = .{ .positional = try mk(arena, span, .{ .name = .{ .text = name, .span = span } }) } });
    }
    for (cases.items) |name| {
        try fields.append(arena, .{ .kind = .{ .positional = try mk(arena, span, .{ .name = .{ .text = name, .span = span } }) } });
    }
    const tbl = try mk(arena, span, .{ .table = try fields.toOwnedSlice(arena) });
    const ret = try arena.create(ast.Stat);
    const vals = try arena.alloc(*ast.Expr, 1);
    vals[0] = tbl;
    ret.* = .{ .span = span, .line = chunk.block.end_line, .kind = .{ .return_ = vals } };
    var new_stats = try arena.alloc(*ast.Stat, stats.len + 1);
    @memcpy(new_stats[0..stats.len], stats);
    new_stats[stats.len] = ret;
    if (stats.len > 0 and stats[stats.len - 1].kind == .return_) return error.TestFileReturns;
    chunk.block.stats = new_stats;
}

fn mk(arena: std.mem.Allocator, span: ast.Span, kind: ast.Expr.Kind) !*ast.Expr {
    const e = try arena.create(ast.Expr);
    e.* = .{ .span = span, .line = 0, .kind = kind };
    return e;
}

const Rewrite = struct {
    arena: std.mem.Allocator,
    src: []const u8,

    fn visit(rw: *const Rewrite, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        if (e.kind != .call) return;
        const c = e.kind.call;
        if (c.callee.kind != .name or !std.mem.eql(u8, c.callee.kind.name.text, "assert")) return;
        if (c.args.len < 1 or c.args.len > 2) return;
        const subject = c.args[0];
        const text = rw.src[subject.span.start..@min(subject.span.end, rw.src.len)];
        const src_lit = try mkLine(rw.arena, subject, .{ .string = text });
        var args: std.ArrayList(*ast.Expr) = .empty;
        var callee_name: []const u8 = "__lus_assert";
        if (subject.kind == .binop) {
            const b = subject.kind.binop;
            switch (b.op) {
                .eq, .ne, .lt, .le, .gt, .ge => {
                    callee_name = "__lus_assert_cmp";
                    try args.append(rw.arena, b.lhs);
                    try args.append(rw.arena, b.rhs);
                    try args.append(rw.arena, try mkLine(rw.arena, subject, .{ .string = b.op.symbol() }));
                },
                else => try args.append(rw.arena, subject),
            }
        } else try args.append(rw.arena, subject);
        try args.append(rw.arena, src_lit);
        if (c.args.len == 2) try args.append(rw.arena, c.args[1]);
        const callee = try mkLine(rw.arena, c.callee, .{ .name = .{ .text = callee_name, .span = c.callee.span } });
        e.kind = .{ .call = .{ .callee = callee, .args = try args.toOwnedSlice(rw.arena), .args_kind = .parens } };
    }
};

fn mkLine(arena: std.mem.Allocator, like: *ast.Expr, kind: ast.Expr.Kind) !*ast.Expr {
    const e = try arena.create(ast.Expr);
    e.* = .{ .span = like.span, .line = like.line, .kind = kind };
    return e;
}

// ---------------------------------------------------------------------
// Helpers available inside test files

fn installHelpers(l: *Thread, snap: *Snapshots) !void {
    const g = l.g;
    try aux.setGlobal(l, "__lus_assert", try aux.native(l, powerAssert, "assert"));
    try aux.setGlobal(l, "__lus_assert_cmp", try aux.native(l, powerAssertCmp, "assert"));
    try aux.setGlobal(l, "skip", try aux.native(l, skipFn, "skip"));
    try g.ext.put(g.gpa, "test.snapshots", snap);
    try aux.setGlobal(l, "snapshot", try aux.native(l, snapshotFn, "snapshot"));
    // `raises` and `same` are written in Lus, so they behave exactly like
    // the code under test.
    api.load(l, helpers_src, "=(lus test)") catch return error.LusError;
    if (!api.pcall(l, 0, 0)) return error.LusError;
}

/// raises(f, pattern, ...): calls f(...), fails the test unless it raises,
/// checks the message against the optional Lus pattern and returns the
/// error value. same(a, b): deep structural equality of two values.
const helpers_src =
    \\local catchfn = function(f, ...) return catch f(...) end
    \\local function raises(f, pattern, ...)
    \\    local ok, err = catchfn(f, ...)
    \\    if ok then error("expected an error, but the call succeeded", 2) end
    \\    if pattern ~= nil and not tostring(err):find(pattern) then
    \\        error(`expected an error matching '$(pattern)', got: $(tostring(err))`, 2)
    \\    end
    \\    return err
    \\end
    \\local function same(a, b, seen)
    \\    if a == b then return true end
    \\    if type(a) ~= "table" or type(b) ~= "table" then return false end
    \\    seen = seen or {}
    \\    if seen[a] == b then return true end
    \\    seen[a] = b
    \\    for k, v in pairs(a) do
    \\        if not same(v, b[k], seen) then return false end
    \\    end
    \\    for k in pairs(b) do
    \\        if a[k] == nil then return false end
    \\    end
    \\    return true
    \\end
    \\_G.raises = raises
    \\_G.same = same
;

fn repr(l: *Thread, buf: *std.ArrayList(u8), v: Value, depth: u32) Error!void {
    const gpa = l.g.gpa;
    switch (v.tag) {
        .string => {
            buf.append(gpa, '"') catch return l.raiseMem();
            for (v.as(String).bytes()) |ch| switch (ch) {
                '"' => buf.appendSlice(gpa, "\\\"") catch return l.raiseMem(),
                '\\' => buf.appendSlice(gpa, "\\\\") catch return l.raiseMem(),
                '\n' => buf.appendSlice(gpa, "\\n") catch return l.raiseMem(),
                else => buf.append(gpa, ch) catch return l.raiseMem(),
            };
            buf.append(gpa, '"') catch return l.raiseMem();
        },
        .table => {
            if (depth > 3 or l.metatable(v) != null and !l.metamethod(v, .tostring).isNil()) {
                const s = try ops.toString(l, v);
                buf.appendSlice(gpa, s.bytes()) catch return l.raiseMem();
                return;
            }
            const t = v.as(Table);
            buf.appendSlice(gpa, "{") catch return l.raiseMem();
            // Sequence part first, then other keys sorted by their repr.
            const n = lus.vm.table.length(t);
            var i: i64 = 1;
            while (i <= n) : (i += 1) {
                if (i > 1) buf.appendSlice(gpa, ", ") catch return l.raiseMem();
                try repr(l, buf, lus.vm.table.getInt(t, i), depth + 1);
            }
            var keys: std.ArrayList([]const u8) = .empty;
            defer {
                for (keys.items) |k| gpa.free(k);
                keys.deinit(gpa);
            }
            var k: Value = .nil;
            while (lus.vm.table.next(t, k) catch null) |kv| : (k = kv.key) {
                if (kv.key.tag == .integer and kv.key.asInt() >= 1 and kv.key.asInt() <= n) continue;
                var kb: std.ArrayList(u8) = .empty;
                if (kv.key.tag == .string) {
                    kb.appendSlice(gpa, kv.key.as(String).bytes()) catch return l.raiseMem();
                } else {
                    kb.append(gpa, '[') catch return l.raiseMem();
                    try repr(l, &kb, kv.key, depth + 1);
                    kb.append(gpa, ']') catch return l.raiseMem();
                }
                kb.appendSlice(gpa, " = ") catch return l.raiseMem();
                try repr(l, &kb, kv.val, depth + 1);
                keys.append(gpa, kb.toOwnedSlice(gpa) catch return l.raiseMem()) catch return l.raiseMem();
            }
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (keys.items, 0..) |kt, idx| {
                if (n > 0 or idx > 0) buf.appendSlice(gpa, ", ") catch return l.raiseMem();
                buf.appendSlice(gpa, kt) catch return l.raiseMem();
            }
            buf.appendSlice(gpa, "}") catch return l.raiseMem();
        },
        else => {
            const s = try ops.toString(l, v);
            buf.appendSlice(gpa, s.bytes()) catch return l.raiseMem();
        },
    }
}

fn powerAssert(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.truthy()) return aux.ret(l, v);
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.print(gpa, "assertion failed: {s}", .{(try aux.checkString(l, 2)).bytes()}) catch return l.raiseMem();
    if (!l.arg(3).isNil()) {
        buf.appendSlice(gpa, "\n  message: ") catch return l.raiseMem();
        try repr(l, &buf, l.arg(3), 0);
    }
    buf.appendSlice(gpa, "\n  value: ") catch return l.raiseMem();
    try repr(l, &buf, v, 0);
    return l.raiseFmt("{s}", .{buf.items});
}

fn powerAssertCmp(l: *Thread) Error!u32 {
    const a = l.arg(1);
    const b = l.arg(2);
    const op = (try aux.checkString(l, 3)).bytes();
    const ok = if (std.mem.eql(u8, op, "==")) try ops.equal(l, a, b) else if (std.mem.eql(u8, op, "~=")) !(try ops.equal(l, a, b)) else if (std.mem.eql(u8, op, "<")) try ops.lessThan(l, a, b) else if (std.mem.eql(u8, op, "<=")) try ops.lessEqual(l, a, b) else if (std.mem.eql(u8, op, ">")) try ops.lessThan(l, b, a) else try ops.lessEqual(l, b, a);
    if (ok) return aux.ret(l, .true);
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.print(gpa, "assertion failed: {s}", .{(try aux.checkString(l, 4)).bytes()}) catch return l.raiseMem();
    if (!l.arg(5).isNil()) {
        buf.appendSlice(gpa, "\n  message: ") catch return l.raiseMem();
        try repr(l, &buf, l.arg(5), 0);
    }
    buf.appendSlice(gpa, "\n  left:  ") catch return l.raiseMem();
    try repr(l, &buf, a, 0);
    buf.appendSlice(gpa, "\n  right: ") catch return l.raiseMem();
    try repr(l, &buf, b, 0);
    return l.raiseFmt("{s}", .{buf.items});
}

const skip_marker = "\x00lus-skip:";

fn skipFn(l: *Thread) Error!u32 {
    const reason = (try aux.optString(l, 1, "skipped")).?;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.appendSlice(l.g.gpa, skip_marker) catch return l.raiseMem();
    buf.appendSlice(l.g.gpa, reason) catch return l.raiseMem();
    return l.raise(Value.obj(.string, lus.vm.state.newStringKnown(l.g, buf.items, false, buf.items.len) catch return l.raiseMem()));
}

fn skipReason(l: *Thread, err: Value) ?[]const u8 {
    _ = l;
    if (err.tag != .string) return null;
    const s = err.as(String).bytes();
    if (std.mem.startsWith(u8, s, skip_marker)) return s[skip_marker.len..];
    return null;
}

// ---------------------------------------------------------------------
// Snapshots

const Snapshots = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    update: bool,
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    touched: std.StringHashMapUnmanaged(void) = .empty,
    current: []const u8 = "",
    counter: usize = 0,
    dirty: bool = false,

    fn snapPath(s: *Snapshots) ![]u8 {
        const dir = std.fs.path.dirname(s.path) orelse ".";
        const base = std.fs.path.basename(s.path);
        return std.fmt.allocPrint(s.gpa, "{s}/__snapshots__/{s}.snap", .{ dir, base });
    }

    fn load(s: *Snapshots) !void {
        const p = try s.snapPath();
        defer s.gpa.free(p);
        const data = try std.Io.Dir.cwd().readFileAlloc(s.io, p, s.gpa, .unlimited);
        defer s.gpa.free(data);
        // Format: "== key\n<value lines>\n" repeated.
        var it = std.mem.splitSequence(u8, data, "\n== ");
        var first = true;
        while (it.next()) |chunk| {
            var c = chunk;
            if (first) {
                first = false;
                if (!std.mem.startsWith(u8, c, "== ")) continue;
                c = c[3..];
            }
            const nl = std.mem.indexOfScalar(u8, c, '\n') orelse continue;
            const key = try s.gpa.dupe(u8, c[0..nl]);
            const val = try s.gpa.dupe(u8, std.mem.trimEnd(u8, c[nl + 1 ..], "\n"));
            try s.entries.put(s.gpa, key, val);
        }
    }

    fn begin(s: *Snapshots, name: []const u8) void {
        s.current = name;
        s.counter = 0;
    }

    fn save(s: *Snapshots) !void {
        if (!s.dirty) return;
        const p = try s.snapPath();
        defer s.gpa.free(p);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(s.io, d);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(s.gpa);
        var it = s.entries.iterator();
        while (it.next()) |e| try buf.print(s.gpa, "== {s}\n{s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = p, .data = buf.items });
    }

    fn deinit(s: *Snapshots) void {
        var it = s.entries.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.entries.deinit(s.gpa);
        s.touched.deinit(s.gpa);
    }
};

fn snapshotFn(l: *Thread) Error!u32 {
    const g = l.g;
    const s: *Snapshots = @ptrCast(@alignCast(g.ext.get("test.snapshots").?));
    const gpa = g.gpa;
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(gpa);
    try repr(l, &val, try aux.checkAny(l, 1), 0);
    s.counter += 1;
    const key = std.fmt.allocPrint(gpa, "{s} #{d}", .{ s.current, s.counter }) catch return l.raiseMem();
    if (s.entries.get(key)) |existing| {
        defer gpa.free(key);
        if (std.mem.eql(u8, existing, val.items)) return 0;
        if (s.update) {
            const nv = gpa.dupe(u8, val.items) catch return l.raiseMem();
            const old = s.entries.getPtr(key).?;
            gpa.free(old.*);
            old.* = nv;
            s.dirty = true;
            return 0;
        }
        return l.raiseFmt("snapshot mismatch ({s})\n  expected: {s}\n  actual:   {s}\n  (run lus test -u to update)", .{ key, existing, val.items });
    }
    // New snapshot: record it.
    s.entries.put(gpa, key, gpa.dupe(u8, val.items) catch return l.raiseMem()) catch return l.raiseMem();
    s.dirty = true;
    return 0;
}
