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
//! A top-level function whose name ends in `_bench` is a benchmark. A plain
//! run calls each benchmark once, as a test, so a broken one fails early.
//! `--bench` runs only the benchmarks and measures them (`runBench`). When
//! a benchmark returns a function, the runner measures that function, so
//! the code before the return is setup. The results are compared with the
//! baseline in `__benchmarks__/FILE.json`, which `-u` writes.
//!
//! Each file runs in its own child process inside a fresh temporary
//! directory, and files run in parallel. The result of a file is printed
//! as soon as it ends. A file that writes no output for the timeout, or
//! that runs longer than the file timeout, is reported as timed out, and
//! every process it started is killed.

const std = @import("std");

const usage = @import("usage.zig").of("test");
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
    /// The permissions that `-P` grants to every test file.
    pledges: std.ArrayList([]const u8) = .empty,
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
    /// Measure only the benchmarks.
    bench: bool = false,
    /// How long each benchmark is measured, in milliseconds.
    bench_ms: u32 = 1000,
    /// Record which lines of the code under test run.
    coverage: bool = false,
    /// Print the tests and benchmarks instead of running them.
    list: bool = false,
    /// Where to write the coverage as an lcov tracefile.
    coverage_out: ?[]const u8 = null,
    /// The directory under which each file gets a fresh working directory.
    tmp_root: []const u8 = "",

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
        var bench: ?u32 = null;
        defer host_pledges.deinit(gpa);
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-u")) update = true;
            if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
                filter = args[i + 1];
                i += 1;
            }
            if (std.mem.eql(u8, args[i], "--display") and i + 1 < args.len) {
                record_file = args[i + 1];
                i += 1;
            }
            if (std.mem.eql(u8, args[i], "--coverage")) coverage_on = true;
            if (std.mem.eql(u8, args[i], "--doc")) doc_mode = true;
            if (std.mem.eql(u8, args[i], "-P") and i + 1 < args.len) {
                try host_pledges.append(gpa, args[i + 1]);
                i += 1;
            }
            if (std.mem.eql(u8, args[i], "--bench-ms") and i + 1 < args.len) {
                bench = std.fmt.parseInt(u32, args[i + 1], 10) catch 1000;
                i += 1;
            }
        }
        if (record_file.len == 0) record_file = args[1];
        if (isDoc(args[1]) or doc_mode) return runDocFile(init, args[1], filter);
        return runOne(init, args[1], filter, update, bench);
    }
    var o: Options = .{};
    defer o.paths.deinit(gpa);
    defer o.pledges.deinit(gpa);
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
        } else if (std.mem.eql(u8, a, "--bench")) {
            o.bench = true;
        } else if (std.mem.eql(u8, a, "--coverage")) {
            o.coverage = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if ((std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--pledge")) and i + 1 < args.len) {
            i += 1;
            try o.pledges.append(gpa, args[i]);
        } else if (std.mem.startsWith(u8, a, "-P") and a.len > 2) {
            try o.pledges.append(gpa, a[2..]);
        } else if (std.mem.eql(u8, a, "--coverage-out") and i + 1 < args.len) {
            i += 1;
            o.coverage = true;
            o.coverage_out = args[i];
        } else if (std.mem.eql(u8, a, "--bench-time") and i + 1 < args.len) {
            i += 1;
            const secs = try std.fmt.parseFloat(f64, args[i]);
            if (!(secs > 0 and secs <= 3600)) return error.InvalidBenchTime;
            o.bench_ms = @intFromFloat(@max(1, secs * 1000));
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
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus test: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        } else {
            try o.paths.append(gpa, a);
        }
    }
    if (o.paths.items.len == 0) try o.paths.append(gpa, ".");
    o.tmp_root = @import("../lib/os.zig").tempDirFrom(init.environ_map);
    if (o.list) return listTests(init, &o);
    return runAll(init, &o);
}

// ---------------------------------------------------------------------
// Parent: discovery, parallel execution, reporting

const FileResult = struct {
    path: []const u8,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    benches: usize = 0,
    crashed: bool = false,
    timed_out: bool = false,
    report: std.ArrayList(u8) = .empty,
    records: std.ArrayList(u8) = .empty,
    /// The coverage records of the file, one per line.
    coverage: std.ArrayList(u8) = .empty,
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
            if (!isDoc(entry.basename) and !std.mem.endsWith(u8, entry.basename, ".lus")) continue;
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

/// `--list`: prints `FILE: NAME` for every test and benchmark that a run
/// with the same paths and filter would start, or one JSON record per name
/// with `--json`, without running anything. A case table runs its test once
/// per entry, which only running its file can count, so a test is listed
/// once.
fn listTests(init: std.process.Init, o: *Options) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    for (o.paths.items) |p| discover(arena, io, p, &files, false) catch return 2;
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var listing: std.ArrayList(u8) = .empty;
    var status: u8 = 0;
    for (files.items) |file| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited) catch {
            std.debug.print("lus test: cannot read {s}\n", .{file});
            status = 2;
            continue;
        };
        var diag: ?[]const u8 = null;
        const chunk = parser.parse(gpa, arena, src, .{ .chunkname = file }, &diag) catch {
            std.debug.print("{s}\n", .{diag orelse "syntax error"});
            status = 1;
            continue;
        };
        var tests: std.ArrayList([]const u8) = .empty;
        var cases: std.ArrayList([]const u8) = .empty;
        var benches: std.ArrayList([]const u8) = .empty;
        try collectNames(arena, chunk, &tests, &cases, &benches);
        for ([_][]const []const u8{ tests.items, benches.items }, 0..) |names, k| for (names) |name| {
            if (o.filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
            if (o.json) {
                try listing.appendSlice(arena, "{\"file\":\"");
                try jsonEscape(arena, &listing, file);
                try listing.appendSlice(arena, "\",\"name\":\"");
                try jsonEscape(arena, &listing, name);
                try listing.print(arena, "\",\"kind\":\"{s}\"}}\n", .{if (k == 0) "test" else "bench"});
            } else try listing.print(arena, "{s}: {s}\n", .{ file, name });
        };
    }
    std.Io.File.stdout().writeStreamingAll(io, listing.items) catch {};
    return status;
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
    // Benchmarks run one file at a time unless --jobs says otherwise, so
    // that files do not compete for the processor while they measure.
    const jobs = if (o.jobs > 0) o.jobs else if (o.bench) 1 else @max(std.Thread.getCpuCount() catch 4, 1);
    var pool: Pool = .{ .gpa = gpa, .io = io, .exe = exe, .o = o, .results = results, .jobs = @min(jobs, results.len) };
    pool.lock();
    while (pool.live < pool.jobs) try pool.startWorker();
    pool.unlock();
    pool.watch();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var benches: usize = 0;
    var bad_files: usize = 0;
    var broken: usize = 0;
    for (results) |*r| {
        passed += r.passed;
        failed += r.failed;
        skipped += r.skipped;
        benches += r.benches;
        if (r.failed > 0 or r.crashed or r.timed_out) bad_files += 1;
        // A file that crashed, timed out, or failed to load runs no test,
        // so the summary counts it apart from failed tests.
        if (r.crashed or r.timed_out) broken += 1;
    }
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    if (!o.json) {
        if (o.bench) {
            try report.print(gpa, "\n{d} files, {d} {s}, {d} failed", .{ results.len, benches, if (benches == 1) "benchmark" else "benchmarks", failed });
        } else try report.print(gpa, "\n{d} files, {d} passed, {d} failed, {d} skipped", .{ results.len, passed, failed, skipped });
        if (broken > 0) try report.print(gpa, ", {d} {s} with errors", .{ broken, if (broken == 1) "file" else "files" });
        try report.append(gpa, '\n');
    }
    if (o.coverage) writeCoverage(gpa, io, o, results, &report) catch |e| {
        std.debug.print("lus test: cannot write the coverage ({s})\n", .{@errorName(e)});
    };
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
        r.coverage.deinit(gpa);
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
    // A source file whose doc comments hold no example stays out of the
    // report of a doc run.
    if (o.doc and ok and std.mem.endsWith(u8, r.path, ".lus") and r.passed + r.skipped == 0 and !o.verbose) return;
    const mark = if (ok) "ok  " else "FAIL";
    if (o.bench) {
        try text.print(gpa, "{s} {s} ({d} {s}", .{ mark, r.path, r.benches, if (r.benches == 1) "benchmark" else "benchmarks" });
    } else try text.print(gpa, "{s} {s} ({d} passed", .{ mark, r.path, r.passed });
    if (r.failed > 0) try text.print(gpa, ", {d} failed", .{r.failed});
    if (r.skipped > 0) try text.print(gpa, ", {d} skipped", .{r.skipped});
    try text.print(gpa, ", {d} ms)\n", .{r.millis});
    if (!ok or o.verbose or o.bench) try text.appendSlice(gpa, r.report.items);
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
    const dir = try std.fmt.allocPrint(gpa, "{s}{s}lus-test-{x}", .{ tmp_root, @import("../lib/os.zig").path_separator, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ pool.exe, "test", "--run-one", abs, "--display", r.path });
    if (pool.o.update) try argv.append(gpa, "-u");
    if (pool.o.filter) |f| try argv.appendSlice(gpa, &.{ "--filter", f });
    var ms_buf: [16]u8 = undefined;
    if (pool.o.bench) try argv.appendSlice(gpa, &.{ "--bench-ms", try std.fmt.bufPrint(&ms_buf, "{d}", .{pool.o.bench_ms}) });
    if (pool.o.coverage) try argv.append(gpa, "--coverage");
    if (pool.o.doc) try argv.append(gpa, "--doc");
    for (pool.o.pledges.items) |spec| try argv.appendSlice(gpa, &.{ "-P", spec });
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
            } else if (std.mem.eql(u8, st, "coverage")) {
                try r.coverage.appendSlice(gpa, rec);
                try r.coverage.append(gpa, '\n');
            } else if (std.mem.eql(u8, st, "bench")) {
                r.benches += 1;
                try formatBench(gpa, rec, name, &r.report);
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
        if (!clean or (r.passed + r.failed + r.skipped + r.benches == 0 and stderr.len > 0)) {
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

/// Extracts a numeric field from a one-line JSON record, or null when the
/// record has no such field.
fn recordNumber(rec: []const u8, key: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, rec, pat) orelse return null;
    const start = at + pat.len;
    var i = start;
    while (i < rec.len and rec[i] != ',' and rec[i] != '}') : (i += 1) {}
    return std.fmt.parseFloat(f64, rec[start..i]) catch null;
}

/// Writes a duration in nanoseconds with a unit that keeps three or four
/// significant digits.
fn writeDuration(gpa: std.mem.Allocator, text: *std.ArrayList(u8), ns: f64) !void {
    if (ns < 1e3) return text.print(gpa, "{d:.1} ns", .{ns});
    if (ns < 1e6) return text.print(gpa, "{d:.2} us", .{ns / 1e3});
    if (ns < 1e9) return text.print(gpa, "{d:.2} ms", .{ns / 1e6});
    return text.print(gpa, "{d:.3} s", .{ns / 1e9});
}

/// The relative change from `base` to `now` counts only when it exceeds
/// 2 percent and three times the larger relative spread of the two runs.
pub fn benchVerdict(now: f64, now_mad: f64, base: f64, base_mad: f64) []const u8 {
    if (!(base > 0) or !(now > 0)) return "no change";
    const change = (now - base) / base;
    const noise = @max(now_mad / now, base_mad / base);
    if (@abs(change) <= @max(0.02, 3 * noise)) return "no change";
    return if (change > 0) "slower" else "faster";
}

/// Formats the record of one measured benchmark.
fn formatBench(gpa: std.mem.Allocator, rec: []const u8, name: []const u8, text: *std.ArrayList(u8)) !void {
    const ns = recordNumber(rec, "ns") orelse 0;
    const mad = recordNumber(rec, "mad") orelse 0;
    try text.print(gpa, "  bench {s}: ", .{name});
    try writeDuration(gpa, text, ns);
    try text.print(gpa, " per call, spread {d:.1}%", .{if (ns > 0) 100 * mad / ns else 0});
    if (recordNumber(rec, "bytes")) |b| try text.print(gpa, ", {d:.0} bytes per call", .{b});
    if (recordNumber(rec, "base_ns")) |base| {
        const base_mad = recordNumber(rec, "base_mad") orelse 0;
        const change = if (base > 0) 100 * (ns - base) / base else 0;
        try text.print(gpa, ", {s}{d:.1}% against the baseline ({s})", .{ if (change >= 0) "+" else "", change, benchVerdict(ns, mad, base, base_mad) });
    }
    try text.append(gpa, '\n');
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

fn runOne(init: std.process.Init, path: []const u8, filter: ?[]const u8, update: bool, bench_ms: ?u32) !u8 {
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
    var cov: Coverage = .{ .gpa = gpa };
    defer cov.deinit();
    if (coverage_on) cov.attach(l);
    api.openLibs(l) catch return 2;
    // The grants of `-P` are host grants, as they are for `lus FILE`.
    api.grantPledges(l, host_pledges.items) catch {
        std.debug.print("lus test: {s}\n", .{api.errorMessage(l, l.err)});
        return 2;
    };
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
    var benches: std.ArrayList([]const u8) = .empty;
    try transform(arena, &chunk, src, &tests, &cases, &benches);
    const r = try lus.compile.codegen.compileAst(l.g, arena, chunk, .{ .chunkname = chunkname, .meta_grants = .{ .thread = l } });
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
    if (bench_ms) |ms| {
        var baselines: Baselines = .{ .gpa = gpa, .io = io, .path = path };
        defer baselines.deinit();
        baselines.load() catch {};
        const driver = try benchDriver(l);
        for (benches.items, 0..) |name, bi| {
            if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
            const fv = lus.vm.table.getInt(registry.as(Table), @intCast(tests.items.len * 2 + cases.items.len + bi + 1));
            if (!runBench(l, driver, name, fv, ms, &baselines)) failed = true;
        }
        if (update) baselines.save() catch |e| std.debug.print("cannot write the benchmark baseline ({s})\n", .{@errorName(e)});
        out.flushAll(l.g);
        return if (failed) 1 else 0;
    }
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
                if (!runTest(l, &snap, label, fv, entry, lineOf(fv))) failed = true;
            }
            const positional = k - 1;
            var key: Value = .nil;
            while (lus.vm.table.next(ct, key) catch null) |e| : (key = e.key) {
                if (e.key.tag == .integer and e.key.asInt() >= 1 and e.key.asInt() <= positional) continue;
                const label = if (e.key.tag == .string)
                    try std.fmt.allocPrint(arena, "{s}[{s}]", .{ name, e.key.as(String).bytes() })
                else
                    try std.fmt.allocPrint(arena, "{s}[?]", .{name});
                if (!runTest(l, &snap, label, fv, e.val, lineOf(fv))) failed = true;
            }
        } else {
            if (!runTest(l, &snap, name, fv, null, lineOf(fv))) failed = true;
        }
    }
    // A plain run calls each benchmark once, as a test.
    if (benches.items.len > 0) {
        const once = try aux.getField(l, l.g.globals.as(Table), "__lus_bench_once");
        for (benches.items, 0..) |name, bi| {
            if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
            const fv = lus.vm.table.getInt(registry.as(Table), @intCast(tests.items.len * 2 + cases.items.len + bi + 1));
            if (!runTest(l, &snap, name, once, fv, lineOf(fv))) failed = true;
        }
    }
    if (coverage_on) {
        l.g.debugger = null;
        cov.emit(l) catch |e| std.debug.print("cannot report the coverage ({s})\n", .{@errorName(e)});
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
    // The examples in the doc comments of a source file run like the code
    // blocks of a Markdown file, with the directory of the file on
    // `package.path` so that an example can require its own module.
    if (std.mem.endsWith(u8, path, ".lus")) {
        const text = try docText(gpa, src);
        defer gpa.free(text);
        return runDocText(init, path, text, filter, std.fs.path.dirname(path) orelse ".");
    }
    return runDocText(init, path, src, filter, null);
}

/// The text of the doc comments of a source file, as Markdown with one
/// line per source line, so the line of a code block is its line in the
/// source. A `---` line keeps what follows the dashes and one space, the
/// lines of a `--[[- ... ]]` comment keep their text, and every other line
/// becomes empty.
pub fn docText(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var in_long = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try text.append(gpa, '\n');
        first = false;
        const line = std.mem.trimStart(u8, raw, " \t");
        if (in_long) {
            if (std.mem.indexOf(u8, line, "]]")) |end| {
                in_long = false;
                try text.appendSlice(gpa, line[0..end]);
            } else try text.appendSlice(gpa, raw);
        } else if (std.mem.startsWith(u8, line, "--[[-")) {
            const rest = line["--[[-".len..];
            if (std.mem.indexOf(u8, rest, "]]")) |end| {
                try text.appendSlice(gpa, rest[0..end]);
            } else {
                in_long = true;
                try text.appendSlice(gpa, rest);
            }
        } else if (std.mem.startsWith(u8, line, "---") and !std.mem.startsWith(u8, line, "----")) {
            var rest = line[3..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try text.appendSlice(gpa, rest);
        }
    }
    return text.toOwnedSlice(gpa);
}

fn runDocText(init: std.process.Init, path: []const u8, src: []const u8, filter: ?[]const u8, module_dir: ?[]const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
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
                writeRecord(gpa, io, "skip", name, "nocheck", start_line, 0);
                continue;
            }
            if (!try runDocBlock(init, path, start_line, code.items, name, module_dir)) failed = true;
            continue;
        }
        try code.appendSlice(gpa, raw);
        try code.append(gpa, '\n');
    }
    return if (failed) 1 else 0;
}

fn runDocBlock(init: std.process.Init, path: []const u8, line: usize, code: []const u8, name: []const u8, module_dir: ?[]const u8) !bool {
    const gpa = init.gpa;
    const io = init.io;
    const l = try api.newState(gpa, io);
    l.g.environ = init.environ_map;
    try api.setFlags(l, &.{});
    api.openLibs(l) catch {
        api.close(l);
        return false;
    };
    // A block that pledges its permissions starts with none, as the same
    // code does under `lus`, so the denials that its comments show
    // happen. Any other block holds every permission.
    // The grants of `-P` reach it as they reach a script.
    if (std.mem.indexOf(u8, code, "pledge(") == null) {
        api.grantPledges(l, &.{"all"}) catch {};
    } else api.grantPledges(l, host_pledges.items) catch {};
    if (module_dir) |dir| prependPath(l, dir) catch {};
    const chunkname = try std.fmt.allocPrint(gpa, "={s}:{d}", .{ std.fs.path.basename(path), line });
    defer gpa.free(chunkname);
    var ok = true;
    var msg: []u8 = &.{};
    defer gpa.free(msg);
    // The block prints into a buffer, which its `-->` comments are then
    // compared with.
    var printed: std.ArrayList(u8) = .empty;
    defer printed.deinit(gpa);
    const o = try out.prepare(l.g);
    o.capture = &printed;
    api.load(l, code, chunkname) catch {
        ok = false;
    };
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    if (ok) ok = api.pcall(l, 0, 0);
    if (!ok) msg = try gpa.dupe(u8, api.errorMessage(l, l.stack[l.top - 1]));
    if (ok and !api.runPending(l, true)) {
        ok = false;
        msg = try gpa.dupe(u8, api.errorMessage(l, l.err));
    }
    out.flushAll(l.g);
    o.capture = null;
    const duration = msSince(io, start);
    api.close(l);
    if (ok) {
        if (try missingOutput(gpa, code, printed.items)) |missing| {
            ok = false;
            msg = missing;
        }
    }
    writeRecord(gpa, io, if (ok) "pass" else "fail", name, msg, line, duration);
    return ok;
}

/// Compares the `-->` comments of a code block with what the block
/// printed. Each comment must name a line of the output. Runs of
/// whitespace compare equal, so the tabs of `print` match the spaces of a
/// comment, and `...` in a comment matches any text, such as the position
/// in an error message. Returns the message of the first comment that
/// names no line, or null when every one does.
pub fn missingOutput(gpa: std.mem.Allocator, code: []const u8, printed: []const u8) !?[]u8 {
    return missingOutputOn(gpa, code, printed, if (windows) .windows else .posix);
}

/// The platforms that a `-->(PLATFORM)` comment can name.
const DocPlatform = enum { posix, windows };

/// `missingOutput` as it runs on `platform`, which decides the
/// `-->(PLATFORM)` comments that count. A comment for another platform
/// names no output. A comment that names no known platform fails.
fn missingOutputOn(gpa: std.mem.Allocator, code: []const u8, printed: []const u8, platform: DocPlatform) !?[]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |x| gpa.free(x);
        lines.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, printed, '\n');
    while (it.next()) |line| try lines.append(gpa, try normalize(gpa, line));
    var src = std.mem.splitScalar(u8, code, '\n');
    var n: usize = 0;
    while (src.next()) |line| {
        n += 1;
        const at = std.mem.indexOf(u8, line, "-->") orelse continue;
        var text = line[at + 3 ..];
        if (text.len > 0 and text[0] == '(') {
            const close = std.mem.indexOfScalar(u8, text, ')') orelse
                return try std.fmt.allocPrint(gpa, "line {d} of the block opens a platform with ( and never closes it", .{n});
            const name = text[1..close];
            const named = std.meta.stringToEnum(DocPlatform, name) orelse
                return try std.fmt.allocPrint(gpa, "line {d} of the block names the platform \"{s}\", which is neither posix nor windows", .{ n, name });
            if (named != platform) continue;
            text = text[close + 1 ..];
        }
        const want = try normalize(gpa, text);
        defer gpa.free(want);
        var found = false;
        for (lines.items) |got| {
            if (globMatch(want, got)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return try std.fmt.allocPrint(gpa, "line {d} of the block expects the output \"{s}\". The block printed:\n{s}", .{ n, want, printed });
        }
    }
    return null;
}

/// Collapses each run of whitespace into one space and trims both ends.
fn normalize(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, text, " \t\r")) |c| {
        if (c == ' ' or c == '\t' or c == '\r') {
            space = true;
            continue;
        }
        if (space) try buf.append(gpa, ' ');
        space = false;
        try buf.append(gpa, c);
    }
    return buf.toOwnedSlice(gpa);
}

/// Matches `text` against `pattern`, where `...` matches any text.
fn globMatch(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.indexOf(u8, pattern, "...") orelse return std.mem.eql(u8, pattern, text);
    const head = pattern[0..star];
    if (!std.mem.startsWith(u8, text, head)) return false;
    const rest = pattern[star + 3 ..];
    var i: usize = head.len;
    while (i <= text.len) : (i += 1) {
        if (globMatch(rest, text[i..])) return true;
    }
    return false;
}

test missingOutput {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try missingOutput(gpa, "print(1, 2)   --> 1  2\n", "1\t2\n"));
    try std.testing.expectEqual(@as(?[]u8, null), try missingOutput(gpa, "print(e)  --> ...: bad input\n", "x.lus:3: bad input\n"));
    const m = (try missingOutput(gpa, "print(3)  --> 4\n", "3\n")).?;
    defer gpa.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "expects the output \"4\"") != null);
    // A platform comment counts only on its own platform.
    const both = "print(sep)  -->(posix) /\n-->(windows) \\\n";
    try std.testing.expectEqual(@as(?[]u8, null), try missingOutputOn(gpa, both, "/\n", .posix));
    try std.testing.expectEqual(@as(?[]u8, null), try missingOutputOn(gpa, both, "\\\n", .windows));
    const w = (try missingOutputOn(gpa, both, "/\n", .windows)).?;
    defer gpa.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "expects the output \"\\\"") != null);
    const u = (try missingOutputOn(gpa, "print(1)  -->(linux) 1\n", "1\n", .posix)).?;
    defer gpa.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "neither posix nor windows") != null);
}

/// The path of the file a child runs, as the user named it, which every
/// record carries in its `file` field. A child runs one file, so this is
/// set once in child mode.
var record_file: []const u8 = "";
/// The permissions that `-P` grants to the file a child runs.
var host_pledges: std.ArrayList([]const u8) = .empty;

/// Writes the opening of a result record: `status`, `name`, `file`,
/// `line`, and `duration` in milliseconds. The caller adds any further
/// fields and closes the record.
fn recordHead(gpa: std.mem.Allocator, rec: *std.ArrayList(u8), status: []const u8, name: []const u8, line: usize, duration_ms: f64) !void {
    try rec.appendSlice(gpa, "\x1e{\"status\":\"");
    try rec.appendSlice(gpa, status);
    try rec.appendSlice(gpa, "\",\"name\":\"");
    try jsonEscape(gpa, rec, name);
    try rec.appendSlice(gpa, "\",\"file\":\"");
    try jsonEscape(gpa, rec, record_file);
    try rec.print(gpa, "\",\"line\":{d},\"duration\":{d:.3}", .{ line, duration_ms });
}

/// Puts the modules of `dir` first on `package.path`.
fn prependPath(l: *Thread, dir: []const u8) !void {
    const pkg = try aux.getField(l, l.g.globals.as(Table), "package");
    if (pkg.tag != .table) return;
    const old = try aux.getField(l, pkg.as(Table), "path");
    const rest = if (old.tag == .string) old.as(String).bytes() else "";
    const path = try std.fmt.allocPrint(l.g.gpa, "{s}/?.lus;{s}/?/init.lus;{s}", .{ dir, dir, rest });
    defer l.g.gpa.free(path);
    try aux.setField(l, pkg.as(Table), "path", try l.newStringValue(path));
}

fn writeRecord(gpa: std.mem.Allocator, io: std.Io, status: []const u8, name: []const u8, msg: []const u8, line: usize, duration_ms: f64) void {
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    recordHead(gpa, &rec, status, name, line, duration_ms) catch return;
    rec.appendSlice(gpa, ",\"message\":\"") catch return;
    jsonEscape(gpa, &rec, msg) catch return;
    rec.appendSlice(gpa, "\"}\n") catch return;
    std.Io.File.stdout().writeStreamingAll(io, rec.items) catch {};
}

fn msSince(io: std.Io, start: std.Io.Clock.Timestamp) f64 {
    const ns = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// The line where the function `f` is defined, or 0 for a native.
fn lineOf(f: Value) usize {
    return if (f.tag == .closure) f.as(lus.vm.object.Closure).proto.line_defined else 0;
}

fn runTest(l: *Thread, snap: *Snapshots, name: []const u8, f: Value, case: ?Value, line: usize) bool {
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
    const start = std.Io.Clock.Timestamp.now(l.g.io, .awake);
    var ok = api.pcall(l, nargs, 0);
    var err: Value = if (ok) .nil else l.stack[l.top - 1];
    // A test ends when the coroutines it detached have ended. One that
    // failed with nothing left to collect its error fails the test. A
    // test that already failed closes the coroutines it left, which may
    // wait for an event that its failure kept from happening.
    if (!ok) {
        api.closePending(l);
    } else if (!api.runPending(l, true)) {
        ok = false;
        err = l.err;
        l.push(err) catch {};
    }
    pledge.restore(l, saved);
    const duration = msSince(l.g.io, start);
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
    writeRecord(gpa, l.g.io, status, name, msg, line, duration);
    return ok or std.mem.eql(u8, status, "skip");
}

// ---------------------------------------------------------------------
// Coverage

/// Set in a child run with `--coverage`.
var coverage_on = false;

/// Set in a child run with `--doc`, where a `.lus` file runs the examples
/// of its doc comments.
var doc_mode = false;

const LineSet = std.AutoArrayHashMapUnmanaged(u32, void);

/// Records the lines that run, per source file, with the native line
/// hook that `lus debug` also uses. Every thread of the state runs the
/// hooked interpreter, so the JIT stays off while coverage runs.
const Coverage = struct {
    gpa: std.mem.Allocator,
    files: std.StringArrayHashMapUnmanaged(LineSet) = .empty,
    /// The file of the last line event, which most events repeat.
    last: ?usize = null,
    dbg: lus.vm.state.Debugger = undefined,

    fn attach(c: *Coverage, l: *Thread) void {
        c.dbg = .{ .ctx = c, .event = event, .raised = raised, .mask = Thread.hook_line };
        l.g.debugger = &c.dbg;
        l.hook_mask = c.dbg.mask;
        l.hook_oldfi = std.math.maxInt(usize);
    }

    fn event(ctx: *anyopaque, l: *Thread, ev: []const u8, line: ?u32) Error!void {
        _ = ev;
        const c: *Coverage = @ptrCast(@alignCast(ctx));
        const n = line orelse return;
        const cl = l.frame().closure orelse return;
        const src = (cl.proto.source orelse return).bytes();
        // Only chunks loaded from files, named `@PATH`, are covered.
        if (src.len < 2 or src[0] != '@') return;
        const path = src[1..];
        const idx = if (c.last) |i| (if (std.mem.eql(u8, c.files.keys()[i], path)) i else null) else null;
        const at = idx orelse blk: {
            const gop = c.files.getOrPut(c.gpa, path) catch return;
            if (!gop.found_existing) {
                gop.key_ptr.* = c.gpa.dupe(u8, path) catch {
                    c.files.swapRemoveAt(gop.index);
                    return;
                };
                gop.value_ptr.* = .empty;
            }
            break :blk gop.index;
        };
        c.last = at;
        c.files.values()[at].put(c.gpa, n, {}) catch {};
    }

    fn raised(_: *anyopaque, _: *Thread) void {}

    /// Writes one record per covered file that is no test file: the lines
    /// that ran and the lines that hold code, which come from compiling the
    /// file again.
    fn emit(c: *Coverage, l: *Thread) !void {
        const gpa = c.gpa;
        const io = l.g.io;
        for (c.files.keys(), c.files.values()) |path, hits| {
            if (std.mem.endsWith(u8, path, "_test.lus") or std.mem.indexOf(u8, path, "://") != null) continue;
            const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch continue;
            defer gpa.free(src);
            const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{path});
            defer gpa.free(chunkname);
            var lines: LineSet = .empty;
            defer lines.deinit(gpa);
            switch (try lus.compile.codegen.compile(l.g, src, .{ .chunkname = chunkname, .meta_eval = false })) {
                .err => |m| {
                    gpa.free(m);
                    continue;
                },
                .ok => |p| try codeLines(gpa, p, &lines),
            }
            var rec: std.ArrayList(u8) = .empty;
            defer rec.deinit(gpa);
            try recordHead(gpa, &rec, "coverage", path, 0, 0);
            try rec.appendSlice(gpa, ",\"message\":\"\",\"hit\":");
            try writeLineList(gpa, &rec, hits.keys());
            try rec.appendSlice(gpa, ",\"lines\":");
            try writeLineList(gpa, &rec, lines.keys());
            try rec.appendSlice(gpa, "}\n");
            std.Io.File.stdout().writeStreamingAll(io, rec.items) catch {};
        }
    }

    fn deinit(c: *Coverage) void {
        for (c.files.keys(), c.files.values()) |k, *v| {
            c.gpa.free(k);
            v.deinit(c.gpa);
        }
        c.files.deinit(c.gpa);
    }
};

/// Adds every line that an instruction of `p` or of its nested functions
/// comes from. The last instruction of a function is the return that the
/// compiler adds at its `end`, which never runs after an explicit
/// `return`, so its line counts only when it runs.
fn codeLines(gpa: std.mem.Allocator, p: *const lus.vm.object.Proto, set: *LineSet) !void {
    const n_code = if (p.lines.len > 0) p.lines.len - 1 else 0;
    for (p.lines[0..n_code]) |n| if (n > 0) try set.put(gpa, n, {});
    for (p.protos) |q| try codeLines(gpa, q, set);
}

fn writeLineList(gpa: std.mem.Allocator, rec: *std.ArrayList(u8), lines: []const u32) !void {
    const sorted = try gpa.dupe(u32, lines);
    defer gpa.free(sorted);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
    try rec.append(gpa, '[');
    for (sorted, 0..) |n, i| {
        if (i > 0) try rec.append(gpa, ',');
        try rec.print(gpa, "{d}", .{n});
    }
    try rec.append(gpa, ']');
}

/// Parses the array of integers under `key` in a one-line record.
fn recordLines(gpa: std.mem.Allocator, rec: []const u8, key: []const u8, set: *LineSet) !void {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":[", .{key}) catch return;
    const at = std.mem.indexOf(u8, rec, pat) orelse return;
    const start = at + pat.len;
    const end = std.mem.indexOfScalarPos(u8, rec, start, ']') orelse return;
    var it = std.mem.tokenizeScalar(u8, rec[start..end], ',');
    while (it.next()) |t| try set.put(gpa, std.fmt.parseInt(u32, t, 10) catch continue, {});
}

const FileCoverage = struct { hit: LineSet = .empty, lines: LineSet = .empty };

/// Merges the coverage records of every file, then writes a summary to
/// `report` and, with `--coverage-out`, an lcov tracefile. A line counts
/// as covered when any test file ran it.
fn writeCoverage(gpa: std.mem.Allocator, io: std.Io, o: *const Options, results: []const FileResult, report: *std.ArrayList(u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.StringArrayHashMapUnmanaged(FileCoverage) = .empty;
    for (results) |*r| {
        var it = std.mem.splitScalar(u8, r.coverage.items, '\n');
        while (it.next()) |rec| {
            if (rec.len == 0) continue;
            const name = try unescape(arena, recordField(rec, "name"));
            const gop = try files.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try recordLines(arena, rec, "hit", &gop.value_ptr.hit);
            try recordLines(arena, rec, "lines", &gop.value_ptr.lines);
        }
    }
    files.sort(struct {
        keys: [][]const u8,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx.keys[a], ctx.keys[b]);
        }
    }{ .keys = files.keys() });
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch "";

    var total: usize = 0;
    var covered: usize = 0;
    var lcov: std.ArrayList(u8) = .empty;
    if (!o.json) try report.print(gpa, "\ncoverage:\n", .{});
    for (files.keys(), files.values()) |path, *fc| {
        // A line can run without holding an instruction of its own, as
        // the line of a multi-line expression does.
        for (fc.hit.keys()) |n| try fc.lines.put(arena, n, {});
        const sorted = try arena.dupe(u32, fc.lines.keys());
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        var hit_count: usize = 0;
        for (sorted) |n| {
            if (fc.hit.contains(n)) hit_count += 1;
        }
        total += sorted.len;
        covered += hit_count;
        try lcov.print(arena, "SF:{s}\n", .{path});
        for (sorted) |n| try lcov.print(arena, "DA:{d},{d}\n", .{ n, @intFromBool(fc.hit.contains(n)) });
        try lcov.print(arena, "LF:{d}\nLH:{d}\nend_of_record\n", .{ sorted.len, hit_count });
        if (o.json) continue;
        // An absolute path shows relative to the working directory, as the
        // paths of the test files do.
        const rel = if (cwd.len > 0 and std.fs.path.isAbsolute(path)) try std.fs.path.relativeAlloc(arena, cwd, null, cwd, path) else path;
        const shown = if (rel.len > 0 and rel.len < path.len) rel else path;
        try report.print(gpa, "  {s}: {d} of {d} lines, {d:.1}%", .{ shown, hit_count, sorted.len, percent(hit_count, sorted.len) });
        try writeMissed(gpa, report, sorted, &fc.hit);
        try report.append(gpa, '\n');
    }
    if (!o.json) try report.print(gpa, "  total: {d} of {d} lines, {d:.1}%\n", .{ covered, total, percent(covered, total) });
    if (o.coverage_out) |out_path| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = lcov.items });
}

fn percent(part: usize, whole: usize) f64 {
    if (whole == 0) return 100;
    return 100 * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
}

/// Writes the lines that did not run as ranges, such as `missed 4, 9-12`,
/// with at most eight ranges.
fn writeMissed(gpa: std.mem.Allocator, report: *std.ArrayList(u8), sorted: []const u32, hit: *const LineSet) !void {
    var ranges: usize = 0;
    var i: usize = 0;
    while (i < sorted.len) : (i += 1) {
        if (hit.contains(sorted[i])) continue;
        var j = i;
        while (j + 1 < sorted.len and !hit.contains(sorted[j + 1])) j += 1;
        if (ranges == 8) {
            try report.appendSlice(gpa, ", ...");
            return;
        }
        try report.appendSlice(gpa, if (ranges == 0) ", missed " else ", ");
        if (j > i) try report.print(gpa, "{d}-{d}", .{ sorted[i], sorted[j] }) else try report.print(gpa, "{d}", .{sorted[i]});
        ranges += 1;
        i = j;
    }
}

// ---------------------------------------------------------------------
// Benchmarks

/// Calls `body` the given number of times in a Lus loop, so each call
/// costs what it costs in a program.
const bench_driver_src =
    \\local body, n = ...
    \\for _ = 1, n do body() end
;

fn benchDriver(l: *Thread) !Value {
    api.load(l, bench_driver_src, "=(lus test --bench)") catch return error.LusError;
    const v = l.stack[l.top - 1];
    // The driver stays in the globals of the state, which keep it alive.
    try aux.setGlobal(l, "__lus_bench_driver", v);
    l.top -= 1;
    return v;
}

/// One entry of a baseline: the median time per call and its spread.
const BaseEntry = struct { ns: f64, mad: f64 };

/// The baseline of a test file, `__benchmarks__/FILE.json` next to it: a
/// JSON object that maps each benchmark name to `{"ns": N, "mad": M}`.
const Baselines = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    entries: std.StringArrayHashMapUnmanaged(BaseEntry) = .empty,
    /// The results of this run, which `save` merges into the entries.
    fresh: std.StringArrayHashMapUnmanaged(BaseEntry) = .empty,

    fn filePath(b: *Baselines) ![]u8 {
        const dir = std.fs.path.dirname(b.path) orelse ".";
        return std.fmt.allocPrint(b.gpa, "{s}/__benchmarks__/{s}.json", .{ dir, std.fs.path.basename(b.path) });
    }

    fn load(b: *Baselines) !void {
        const p = try b.filePath();
        defer b.gpa.free(p);
        const data = try std.Io.Dir.cwd().readFileAlloc(b.io, p, b.gpa, .unlimited);
        defer b.gpa.free(data);
        const parsed = try std.json.parseFromSlice(std.json.Value, b.gpa, data, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const o = e.value_ptr.object;
            const ns = numberOf(o.get("ns")) orelse continue;
            const mad = numberOf(o.get("mad")) orelse 0;
            try b.entries.put(b.gpa, try b.gpa.dupe(u8, e.key_ptr.*), .{ .ns = ns, .mad = mad });
        }
    }

    fn numberOf(v: ?std.json.Value) ?f64 {
        return switch (v orelse return null) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    fn record(b: *Baselines, name: []const u8, e: BaseEntry) !void {
        try b.fresh.put(b.gpa, name, e);
    }

    fn save(b: *Baselines) !void {
        if (b.fresh.count() == 0) return;
        var it = b.fresh.iterator();
        while (it.next()) |e| {
            const gop = try b.entries.getOrPut(b.gpa, e.key_ptr.*);
            if (!gop.found_existing) gop.key_ptr.* = try b.gpa.dupe(u8, e.key_ptr.*);
            gop.value_ptr.* = e.value_ptr.*;
        }
        const p = try b.filePath();
        defer b.gpa.free(p);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(b.io, d);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(b.gpa);
        try buf.appendSlice(b.gpa, "{\n");
        var eit = b.entries.iterator();
        var first = true;
        while (eit.next()) |e| {
            if (!first) try buf.appendSlice(b.gpa, ",\n");
            first = false;
            try buf.appendSlice(b.gpa, "  \"");
            try jsonEscape(b.gpa, &buf, e.key_ptr.*);
            try buf.print(b.gpa, "\": {{\"ns\": {d:.3}, \"mad\": {d:.3}}}", .{ e.value_ptr.ns, e.value_ptr.mad });
        }
        try buf.appendSlice(b.gpa, "\n}\n");
        try std.Io.Dir.cwd().writeFile(b.io, .{ .sub_path = p, .data = buf.items });
    }

    fn deinit(b: *Baselines) void {
        for (b.entries.keys()) |k| b.gpa.free(k);
        b.entries.deinit(b.gpa);
        b.fresh.deinit(b.gpa);
    }
};

/// How many timed samples a benchmark takes at most.
const bench_samples = 20;

/// Runs the driver, which calls `body` `n` times, and returns the elapsed
/// nanoseconds, or null when a call raised, with the error object on the
/// stack.
fn timeCalls(l: *Thread, driver: Value, body: Value, n: i64) ?i96 {
    const io = l.g.io;
    l.push(driver) catch return null;
    l.push(body) catch return null;
    l.push(Value.int(n)) catch return null;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    if (!api.pcall(l, 2, 0)) return null;
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return start.durationTo(end).raw.nanoseconds;
}

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

/// The median and the median absolute deviation of `xs`, which it
/// reorders.
pub fn medianAndMad(xs: []f64, scratch: []f64) struct { median: f64, mad: f64 } {
    const med = median(xs);
    for (xs, scratch[0..xs.len]) |x, *d| d.* = @abs(x - med);
    return .{ .median = med, .mad = median(scratch[0..xs.len]) };
}

/// Measures one benchmark and writes its record. The benchmark runs once
/// as setup. When it returns a function, that function is the code
/// measured. Otherwise the benchmark itself is. Calibration doubles the
/// number of calls per sample until a sample takes a twentieth of the
/// budget, then up to 20 samples run within the budget. The time per call
/// is the median over the samples, with the median absolute deviation as
/// its spread. The bytes per call come from a separate run of at most 16
/// calls with the collector stopped.
fn runBench(l: *Thread, driver: Value, name: []const u8, f: Value, budget_ms: u32, baselines: *Baselines) bool {
    const g = l.g;
    const gpa = g.gpa;
    const io = g.io;
    const base = l.top;
    defer l.top = base;
    const pledge = lus.vm.pledge;
    const saved = pledge.save(l);
    defer pledge.restore(l, saved);
    l.err_traceback = null;

    const bench_start = std.Io.Clock.Timestamp.now(io, .awake);
    l.push(f) catch return false;
    if (!api.pcall(l, 0, 1)) return benchFailed(l, name, l.stack[l.top - 1], lineOf(f));
    // The body stays on the stack, which keeps it alive while it runs.
    const ret = l.stack[l.top - 1];
    const body = if (ret.tag == .closure or ret.tag == .native) ret else f;
    l.stack[l.top - 1] = body;

    const budget: i96 = @as(i96, budget_ms) * std.time.ns_per_ms;
    const target = @max(@divTrunc(budget, bench_samples), std.time.ns_per_ms);
    var n: i64 = 1;
    var spent: i96 = 0;
    while (true) {
        const t = timeCalls(l, driver, body, n) orelse return benchFailed(l, name, l.stack[l.top - 1], lineOf(f));
        spent += t;
        if (t >= target or n >= 1 << 40 or spent >= budget) break;
        // Grow toward the target, by at most ten times per step.
        const scale: i64 = if (t <= 0) 10 else @intCast(@min(10, @max(2, @divTrunc(target, t) + 1)));
        n *= scale;
    }

    var per_call: [bench_samples]f64 = undefined;
    var scratch: [bench_samples]f64 = undefined;
    var count: usize = 0;
    var elapsed: i96 = 0;
    while (count < bench_samples and (count < 3 or elapsed < budget)) : (count += 1) {
        const t = timeCalls(l, driver, body, n) orelse return benchFailed(l, name, l.stack[l.top - 1], lineOf(f));
        elapsed += t;
        per_call[count] = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(n));
    }
    const stats = medianAndMad(per_call[0..count], &scratch);

    const k: i64 = @min(n, 16);
    const was_stopped = g.gc_stopped;
    g.gc_stopped = true;
    const before = g.counter.bytes;
    const alloc_ok = timeCalls(l, driver, body, k) != null;
    const after = g.counter.bytes;
    g.gc_stopped = was_stopped;
    if (!alloc_ok) return benchFailed(l, name, l.stack[l.top - 1], lineOf(f));
    const bytes = @as(f64, @floatFromInt(after -| before)) / @as(f64, @floatFromInt(k));

    baselines.record(name, .{ .ns = stats.median, .mad = stats.mad }) catch {};
    out.flushAll(g);
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    recordHead(gpa, &rec, "bench", name, lineOf(f), msSince(io, bench_start)) catch return false;
    rec.print(gpa, ",\"message\":\"\",\"ns\":{d:.3},\"mad\":{d:.3},\"calls\":{d},\"samples\":{d},\"bytes\":{d:.1}", .{ stats.median, stats.mad, n, count, bytes }) catch return false;
    if (baselines.entries.get(name)) |old| {
        rec.print(gpa, ",\"base_ns\":{d:.3},\"base_mad\":{d:.3}", .{ old.ns, old.mad }) catch return false;
    }
    rec.appendSlice(gpa, "}\n") catch return false;
    std.Io.File.stdout().writeStreamingAll(io, rec.items) catch {};
    return true;
}

fn benchFailed(l: *Thread, name: []const u8, err: Value, line: usize) bool {
    const msg = api.errorMessage(l, err);
    out.flushAll(l.g);
    writeRecord(l.g.gpa, l.g.io, "fail", name, msg, line, 0);
    return false;
}

test docText {
    const src =
        \\--- Doubles a number.
        \\---
        \\--- ```lus
        \\--- assert(double(2) == 4)
        \\--- ```
        \\local function double(x) return 2 * x end
        \\--[[-
        \\```lus
        \\print(1)
        \\```
        \\]]
        \\---- a rule, not a doc comment
    ;
    const text = try docText(std.testing.allocator, src);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Doubles a number.\n\n```lus\nassert(double(2) == 4)\n```\n\n\n```lus\nprint(1)\n```\n\n", text);
}

test medianAndMad {
    var xs = [_]f64{ 5, 1, 3, 2, 4 };
    var scratch: [5]f64 = undefined;
    const r = medianAndMad(&xs, &scratch);
    try std.testing.expectEqual(@as(f64, 3), r.median);
    try std.testing.expectEqual(@as(f64, 1), r.mad);
}

test benchVerdict {
    try std.testing.expectEqualStrings("no change", benchVerdict(101, 1, 100, 1));
    try std.testing.expectEqualStrings("slower", benchVerdict(150, 1, 100, 1));
    try std.testing.expectEqualStrings("faster", benchVerdict(50, 1, 100, 1));
    // A spread of 10 percent hides a change of 20 percent.
    try std.testing.expectEqualStrings("no change", benchVerdict(120, 12, 100, 10));
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

/// Collects the names of the tests, case tables, and benchmarks that the
/// top level of a test file defines, in source order.
fn collectNames(arena: std.mem.Allocator, chunk: ast.Chunk, tests: *std.ArrayList([]const u8), cases: *std.ArrayList([]const u8), benches: *std.ArrayList([]const u8)) !void {
    const stats = chunk.block.stats;
    for (stats) |s| {
        switch (s.kind) {
            .local_function => |lf| {
                if (std.mem.endsWith(u8, lf.name.text, "_test")) try tests.append(arena, lf.name.text);
                if (std.mem.endsWith(u8, lf.name.text, "_bench")) try appendOnce(arena, benches, lf.name.text);
            },
            .function => |f| {
                if (f.path.len == 1 and f.method == null and std.mem.endsWith(u8, f.path[0].text, "_test")) try tests.append(arena, f.path[0].text);
                if (f.path.len == 1 and f.method == null and std.mem.endsWith(u8, f.path[0].text, "_bench")) try appendOnce(arena, benches, f.path[0].text);
            },
            .local => |l| {
                for (l.names) |n| {
                    if (std.mem.endsWith(u8, n.name.text, "_test")) try tests.append(arena, n.name.text);
                    if (std.mem.endsWith(u8, n.name.text, "_bench")) try appendOnce(arena, benches, n.name.text);
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
}

/// Collects tests and case tables, rewrites `assert` into power asserts,
/// and makes the chunk return its tests as {name1, fn1, ..., cases...}.
fn transform(arena: std.mem.Allocator, chunk: *ast.Chunk, src: []const u8, tests: *std.ArrayList([]const u8), cases: *std.ArrayList([]const u8), benches: *std.ArrayList([]const u8)) !void {
    const stats = chunk.block.stats;
    try collectNames(arena, chunk.*, tests, cases, benches);
    // Power asserts.
    const V = walk.Visitor(*const Rewrite);
    const rw: Rewrite = .{ .arena = arena, .src = src, .res = try lus.syntax.resolve.resolve(arena, chunk.*) };
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
    for (benches.items) |name| {
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
    /// The bindings of the chunk, which tell a local group from a value.
    res: lus.syntax.resolve.Result,

    fn visit(rw: *const Rewrite, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        if (e.kind != .call) return;
        const c = e.kind.call;
        if (c.callee.kind != .name or !std.mem.eql(u8, c.callee.kind.name.text, "assert")) return;
        if (c.args.len < 1) return;
        const subject = c.args[0];
        const text = rw.src[subject.span.start..@min(subject.span.end, rw.src.len)];
        const src_lit = try mkLine(rw.arena, subject, .{ .string = text });
        var args: std.ArrayList(*ast.Expr) = .empty;
        // The arguments after the subject follow unchanged, so the values of
        // a call in the last position all arrive, and the assert returns
        // what the standard one returns. A subject that is the only
        // argument comes last for the same reason.
        var callee_name: []const u8 = "__lus_assert";
        const cmp = subject.kind == .binop and switch (subject.kind.binop.op) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
        if (cmp) {
            const b = subject.kind.binop;
            callee_name = "__lus_assert_cmp";
            try args.append(rw.arena, b.lhs);
            try args.append(rw.arena, b.rhs);
            try args.append(rw.arena, try mkLine(rw.arena, subject, .{ .string = b.op.symbol() }));
            try args.append(rw.arena, src_lit);
            // The paths inside each side, as their source text and as a
            // function that reads them, which runs only when the
            // comparison fails.
            var paths: std.ArrayList(Probe) = .empty;
            try rw.collect(b.lhs, true, '<', &paths);
            try rw.collect(b.rhs, true, '>', &paths);
            if (paths.items.len == 0) {
                try args.append(rw.arena, try mkLine(rw.arena, subject, .nil));
                try args.append(rw.arena, try mkLine(rw.arena, subject, .nil));
            } else {
                var names: std.ArrayList(u8) = .empty;
                const values = try rw.arena.alloc(*ast.Expr, paths.items.len);
                for (paths.items, values, 0..) |pr, *v, i| {
                    if (i > 0) try names.append(rw.arena, '\n');
                    try names.append(rw.arena, pr.side);
                    try names.appendSlice(rw.arena, pr.text);
                    v.* = try clonePath(rw.arena, pr.expr);
                }
                try args.append(rw.arena, try mkLine(rw.arena, subject, .{ .string = names.items }));
                try args.append(rw.arena, try probeFunction(rw.arena, subject, values));
            }
        } else {
            try args.append(rw.arena, src_lit);
            try args.append(rw.arena, subject);
        }
        try args.appendSlice(rw.arena, c.args[1..]);
        const callee = try mkLine(rw.arena, c.callee, .{ .name = .{ .text = callee_name, .span = c.callee.span } });
        e.kind = .{ .call = .{ .callee = callee, .args = try args.toOwnedSlice(rw.arena), .args_kind = .parens } };
    }

    /// Collects the paths inside `e` in source order, each once per side.
    /// The side itself is left out, because the report shows its value.
    /// The function of a call is left out, which keeps `string` out of
    /// `string.format(...)`.
    fn collect(rw: *const Rewrite, e: *ast.Expr, root: bool, side: u8, list: *std.ArrayList(Probe)) !void {
        if (isPath(e)) {
            if (!root) try rw.add(e, side, list);
            if (e.kind == .index) {
                try rw.collect(e.kind.index.obj, false, side, list);
                if (isPath(e.kind.index.key)) try rw.collect(e.kind.index.key, false, side, list);
            }
            return;
        }
        switch (e.kind) {
            .binop => |b| {
                try rw.collect(b.lhs, false, side, list);
                try rw.collect(b.rhs, false, side, list);
            },
            .unop => |u| try rw.collect(u.operand, false, side, list),
            .paren => |p| try rw.collect(p, false, side, list),
            .index => |ix| {
                try rw.collect(ix.obj, false, side, list);
                try rw.collect(ix.key, false, side, list);
            },
            .call => |c| for (c.args) |a| try rw.collect(a, false, side, list),
            .method => |m| {
                try rw.collect(m.obj, false, side, list);
                for (m.args) |a| try rw.collect(a, false, side, list);
            },
            .interp => |parts| for (parts) |part| switch (part) {
                .expr => |x| try rw.collect(x, false, side, list),
                .text => {},
            },
            else => {},
        }
    }

    /// The name at the start of a path.
    fn rootName(e: *const ast.Expr) *const ast.Expr {
        return if (e.kind == .index) rootName(e.kind.index.obj) else e;
    }

    fn add(rw: *const Rewrite, e: *ast.Expr, side: u8, list: *std.ArrayList(Probe)) !void {
        // A local group is no value, so a function cannot capture it. Its
        // paths stay out.
        const root = rootName(e);
        if (rw.res.refAt(@intCast(root.span.start))) |ref| if (ref.binding) |b| if (b.kind == .group) return;
        const text = rw.src[@min(e.span.start, rw.src.len)..@min(e.span.end, rw.src.len)];
        var on_side: usize = 0;
        for (list.items) |p| if (p.side == side) {
            if (std.mem.eql(u8, p.text, text)) return;
            on_side += 1;
        };
        if (on_side >= max_probes_per_side) return;
        try list.append(rw.arena, .{ .side = side, .text = text, .expr = e });
    }
};

/// A variable or field path inside one side of an asserted comparison.
const Probe = struct { side: u8, text: []const u8, expr: *ast.Expr };

/// The most paths shown for one side.
const max_probes_per_side = 8;

/// Whether `e` reads a variable or a chain of fields with constant or
/// path keys, which reading again cannot change.
fn isPath(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .name => true,
        .index => |ix| isPath(ix.obj) and (isPath(ix.key) or ix.key.kind == .string or ix.key.kind == .integer),
        else => false,
    };
}

fn clonePath(arena: std.mem.Allocator, e: *const ast.Expr) !*ast.Expr {
    const c = try arena.create(ast.Expr);
    c.* = e.*;
    if (e.kind == .index) {
        const ix = e.kind.index;
        c.kind = .{ .index = .{ .obj = try clonePath(arena, ix.obj), .key = if (isPath(ix.key)) try clonePath(arena, ix.key) else ix.key, .dot = ix.dot } };
    }
    return c;
}

/// `function() return v1, v2, ... end` at the line of `like`.
fn probeFunction(arena: std.mem.Allocator, like: *ast.Expr, values: []*ast.Expr) !*ast.Expr {
    const ret = try arena.create(ast.Stat);
    ret.* = .{ .span = like.span, .line = like.line, .kind = .{ .return_ = values } };
    const stats = try arena.alloc(*ast.Stat, 1);
    stats[0] = ret;
    const block = try arena.create(ast.Block);
    block.* = .{ .stats = stats, .span = like.span, .end_line = like.line };
    const func = try arena.create(ast.Function);
    func.* = .{ .params = &.{}, .is_vararg = false, .body = block, .line = like.line, .end_line = like.line, .span = like.span, .name = "assert" };
    return mkLine(arena, like, .{ .function = func });
}

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
    \\_G.__lus_bench_once = function(f)
    \\    local body = f()
    \\    if type(body) == "function" then body() end
    \\end
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

/// `__lus_assert(source, value, ...)`: on success returns `value` and the
/// arguments after it, as the standard assert does.
fn powerAssert(l: *Thread) Error!u32 {
    const n = l.argCount();
    const v = l.arg(2);
    if (v.truthy()) return n - 1;
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.print(gpa, "assertion failed: {s}", .{(try aux.checkString(l, 1)).bytes()}) catch return l.raiseMem();
    if (!l.arg(3).isNil()) {
        buf.appendSlice(gpa, "\n  message: ") catch return l.raiseMem();
        try repr(l, &buf, l.arg(3), 0);
    }
    buf.appendSlice(gpa, "\n  value: ") catch return l.raiseMem();
    try repr(l, &buf, v, 0);
    return l.raiseFmt("{s}", .{buf.items});
}

/// `__lus_assert_cmp(lhs, rhs, op, source, names, probe, ...)`: on success
/// returns true and the arguments after `probe`, as the standard assert
/// returns the result of the comparison and its other arguments. `names`
/// lists the paths inside the two sides, one per line, each prefixed by
/// `<` for the left side or `>` for the right, and `probe` returns their
/// values. Both are nil when the sides hold no path.
fn powerAssertCmp(l: *Thread) Error!u32 {
    const a = l.arg(1);
    const b = l.arg(2);
    const op = (try aux.checkString(l, 3)).bytes();
    const ok = if (std.mem.eql(u8, op, "==")) try ops.equal(l, a, b) else if (std.mem.eql(u8, op, "~=")) !(try ops.equal(l, a, b)) else if (std.mem.eql(u8, op, "<")) try ops.lessThan(l, a, b) else if (std.mem.eql(u8, op, "<=")) try ops.lessEqual(l, a, b) else if (std.mem.eql(u8, op, ">")) try ops.lessThan(l, b, a) else try ops.lessEqual(l, b, a);
    if (ok) {
        const n = l.argCount();
        // The slot of the source becomes the result, followed by the
        // arguments after it.
        l.top = l.base() + n;
        l.stack[l.base() + 5] = .true;
        return n - 5;
    }
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.print(gpa, "assertion failed: {s}", .{(try aux.checkString(l, 4)).bytes()}) catch return l.raiseMem();
    if (!l.arg(7).isNil()) {
        buf.appendSlice(gpa, "\n  message: ") catch return l.raiseMem();
        try repr(l, &buf, l.arg(7), 0);
    }
    // The values of the paths inside each side. A probe that raises, as
    // `a.b.c` does when `a.b` is nil, shows the sides alone.
    var probe_base: ?u32 = null;
    var names: []const u8 = "";
    if (l.arg(5).tag == .string and l.arg(6).tag == .closure) {
        names = l.arg(5).as(String).bytes();
        const at = l.top;
        try l.push(l.arg(6));
        if (api.pcall(l, 0, -1)) probe_base = at else l.top = at;
    }
    var left_text: std.ArrayList(u8) = .empty;
    defer left_text.deinit(gpa);
    var right_text: std.ArrayList(u8) = .empty;
    defer right_text.deinit(gpa);
    try repr(l, &left_text, a, 0);
    try repr(l, &right_text, b, 0);
    buf.print(gpa, "\n  left:  {s}", .{left_text.items}) catch return l.raiseMem();
    try writeProbes(l, &buf, names, probe_base, '<');
    buf.print(gpa, "\n  right: {s}", .{right_text.items}) catch return l.raiseMem();
    try writeProbes(l, &buf, names, probe_base, '>');
    // Tables compare by reference, so two that print the same can still
    // differ.
    if (a.tag == .table and b.tag == .table and std.mem.eql(u8, op, "==") and std.mem.eql(u8, left_text.items, right_text.items)) {
        buf.appendSlice(gpa, "\n  note: both sides print the same, but == compares tables by reference, so these are two different tables. same(a, b) compares them by content.") catch return l.raiseMem();
    }
    return l.raiseFmt("{s}", .{buf.items});
}

/// Writes `path = value` for each path of `side`, skipping functions,
/// whose text says nothing about the failure.
fn writeProbes(l: *Thread, buf: *std.ArrayList(u8), names: []const u8, base: ?u32, side: u8) Error!void {
    const at = base orelse return;
    const gpa = l.g.gpa;
    var it = std.mem.splitScalar(u8, names, '\n');
    var i: u32 = 0;
    while (it.next()) |line| : (i += 1) {
        if (line.len < 2 or line[0] != side) continue;
        const v: Value = if (at + i < l.top) l.stack[at + i] else .nil;
        if (v.tag == .closure or v.tag == .native) continue;
        buf.print(gpa, "\n    {s} = ", .{line[1..]}) catch return l.raiseMem();
        try repr(l, buf, v, 0);
    }
}

const skip_marker = "\x00lus-skip:";

fn skipFn(l: *Thread) Error!u32 {
    const reason = (try aux.optString(l, 1, "skipped")).?;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.appendSlice(l.g.gpa, skip_marker) catch return l.raiseMem();
    buf.appendSlice(l.g.gpa, reason) catch return l.raiseMem();
    // The reason may hold any text, so the string counts its characters.
    return l.raise(try l.newStringValue(buf.items));
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
