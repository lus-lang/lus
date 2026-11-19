//! `lus test`: the built-in test runner.
//!
//! Test files are `*_test.lus` files. Every top-level function whose name
//! ends in `_test` is a test, and top-level code runs once as setup. A
//! top-level `NAME_cases` table runs `NAME_test` once per entry. In test
//! files `assert` reports the failing expression and the values of its
//! operands, `skip(reason)` skips the current test, and `snapshot(value)`
//! compares a value against `__snapshots__/FILE.snap`.
//!
//! Each file runs in its own child process inside a fresh temporary
//! directory, with a timeout, and files run in parallel.

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

const Options = struct {
    paths: std.ArrayList([]const u8) = .empty,
    filter: ?[]const u8 = null,
    update: bool = false,
    json: bool = false,
    jobs: usize = 0,
    timeout_s: i64 = 60,
    verbose: bool = false,
    tmp_root: []const u8 = "/tmp",
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
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < args.len) {
            i += 1;
            o.filter = args[i];
        } else if (std.mem.eql(u8, a, "--jobs") and i + 1 < args.len) {
            i += 1;
            o.jobs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--timeout") and i + 1 < args.len) {
            i += 1;
            o.timeout_s = try std.fmt.parseInt(i64, args[i], 10);
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

fn discover(gpa: std.mem.Allocator, io: std.Io, path: []const u8, files: *std.ArrayList([]const u8)) !void {
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
        if (!std.mem.endsWith(u8, entry.basename, "_test.lus")) continue;
        const skip_dirs = [_][]const u8{ "node_modules", ".git", "zig-out", ".zig-cache", "legacy" };
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
    for (o.paths.items) |p| discover(gpa, io, p, &files) catch return 2;
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    const results = try gpa.alloc(FileResult, files.items.len);
    defer {
        for (results) |*r| {
            r.report.deinit(gpa);
            r.records.deinit(gpa);
        }
        gpa.free(results);
    }
    for (results, files.items) |*r, f| r.* = .{ .path = f };
    const jobs = if (o.jobs > 0) o.jobs else @max(std.Thread.getCpuCount() catch 4, 1);
    var next = std.atomic.Value(usize).init(0);
    const Worker = struct {
        fn work(ctx: *const Ctx) void {
            while (true) {
                const idx = ctx.next.fetchAdd(1, .monotonic);
                if (idx >= ctx.results.len) return;
                runChild(ctx, &ctx.results[idx]) catch |e| {
                    ctx.results[idx].crashed = true;
                    ctx.results[idx].report.print(ctx.gpa, "runner error: {s}\n", .{@errorName(e)}) catch {};
                };
            }
        }
    };
    const ctx: Ctx = .{ .gpa = gpa, .io = io, .exe = exe, .results = results, .next = &next, .o = o };
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);
    var t: usize = 0;
    while (t < @min(jobs, results.len)) : (t += 1) {
        try threads.append(gpa, try std.Thread.spawn(.{}, Worker.work, .{&ctx}));
    }
    for (threads.items) |th| th.join();

    // Report.
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var bad_files: usize = 0;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    for (results) |*r| {
        passed += r.passed;
        failed += r.failed;
        skipped += r.skipped;
        const ok = r.failed == 0 and !r.crashed and !r.timed_out;
        if (!ok) bad_files += 1;
        if (o.json) {
            try report.appendSlice(gpa, r.records.items);
            continue;
        }
        const mark = if (ok) "ok  " else "FAIL";
        try report.print(gpa, "{s} {s} ({d} passed", .{ mark, r.path, r.passed });
        if (r.failed > 0) try report.print(gpa, ", {d} failed", .{r.failed});
        if (r.skipped > 0) try report.print(gpa, ", {d} skipped", .{r.skipped});
        try report.print(gpa, ", {d} ms)\n", .{r.millis});
        if (!ok or o.verbose) try report.appendSlice(gpa, r.report.items);
    }
    if (!o.json) {
        try report.print(gpa, "\n{d} files, {d} passed, {d} failed, {d} skipped\n", .{ results.len, passed, failed, skipped });
    }
    std.Io.File.stdout().writeStreamingAll(io, report.items) catch {};
    return if (bad_files == 0) 0 else 1;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    results: []FileResult,
    next: *std.atomic.Value(usize),
    o: *Options,
};

fn runChild(ctx: *const Ctx, r: *FileResult) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, r.path, gpa);
    defer gpa.free(abs);
    // A fresh working directory per file.
    const tmp_root = ctx.o.tmp_root;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(gpa, "{s}/lus-test-{x}", .{ std.mem.trimEnd(u8, tmp_root, "/"), std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ ctx.exe, "test", "--run-one", abs });
    if (ctx.o.update) try argv.append(gpa, "-u");
    if (ctx.o.filter) |f| try argv.appendSlice(gpa, &.{ "--filter", f });
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(ctx.o.timeout_s), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) {
            r.timed_out = true;
            try r.report.print(gpa, "  timed out after {d} s\n", .{ctx.o.timeout_s});
            return;
        }
        return e;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    r.millis = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, std.time.ns_per_ms));
    // Parse result records; everything else is test output.
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
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
    const clean = switch (res.term) {
        .exited => |code| code == 0 or code == 1,
        else => false,
    };
    if (!clean or (r.passed + r.failed + r.skipped == 0 and res.stderr.len > 0)) {
        r.crashed = !clean or r.failed == 0;
        try r.report.print(gpa, "  file error:\n", .{});
        var el = std.mem.splitScalar(u8, std.mem.trimEnd(u8, res.stderr, "\n"), '\n');
        while (el.next()) |m| try r.report.print(gpa, "       {s}\n", .{m});
    }
    if ((r.failed > 0 or r.crashed) and output.items.len > 0) {
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
    l.g.environ = init.environ_map;
    try api.setFlags(l, &.{});
    api.openLibs(l) catch return 2;
    var snap = Snapshots{ .gpa = gpa, .io = io, .path = path, .update = update };
    defer snap.deinit();
    snap.load() catch {};
    try installHelpers(l, &snap);

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
    const registry = l.stack[base];
    l.top = base;
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
            var k: i64 = 1;
            while (true) : (k += 1) {
                const entry = lus.vm.table.getInt(case_tbl.as(Table), k);
                if (entry.isNil()) break;
                const label = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, k });
                if (!runTest(l, &snap, label, fv, entry)) failed = true;
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
    // Each test runs in its own coroutine so a test's permission changes
    // and pending yields stay local to it.
    l.err_traceback = null;
    const ok = api.pcall(l, nargs, 0);
    var status: []const u8 = "pass";
    var msg: []const u8 = "";
    if (!ok) {
        const err = l.stack[l.top - 1];
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
}

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
