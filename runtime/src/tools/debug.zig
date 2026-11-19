//! `lus debug`: runs a script under the Debug Adapter Protocol.
//!
//! Usage: lus debug [--stdio | --port N] [-P perm]... [SCRIPT [ARGS...]]
//!
//! The adapter speaks DAP over standard input and output by default, or
//! over one TCP connection on 127.0.0.1 with `--port`. The script comes
//! from the command line or from the `program` field of the launch
//! request.
//!
//! The debugger is written in Zig and runs no Lus code in the debuggee of
//! its own. It attaches to the interpreter through `Global.debugger`, the
//! native hook entry point: every thread runs the hooked interpreter loop
//! with line events on, and the interpreter reports each error before it
//! searches for a handler. Breakpoints, stepping, and pausing are all
//! decided on line events. A line event costs one hash lookup by source
//! string (cached per chunk) and one bit test when breakpoints exist.
//!
//! Stepping compares stack depths. The depth of a thread counts its frames
//! and the frames of every thread that resumed it, so a coroutine stacks
//! on top of its resumer. "Step over" stops at the next line at the same
//! depth or shallower, "step out" at the next line strictly shallower, and
//! "step in" at the next line anywhere.
//!
//! While the program runs, a reader thread queues incoming requests. The
//! line hook handles them between lines, so `pause` and new breakpoints
//! take effect without stopping the program. While the program is
//! stopped, the interpreter thread waits for requests and answers them,
//! which is when the stack, variables, and expressions are inspected.
//!
//! The program's standard output and standard error are captured through
//! pipes and forwarded as `output` events. Its standard input reads as
//! empty in stdio mode, because the protocol owns the real one.

const std = @import("std");
const builtin = @import("builtin");
const lus = @import("../lus.zig");
const dap = @import("dap.zig");
const api = lus.api;
const out = lus.lib.out;
const aux = lus.lib.aux;
const value = lus.vm.value;
const object = lus.vm.object;
const state = lus.vm.state;
const table = lus.vm.table;
const ops = lus.vm.ops;
const gc = lus.vm.gc;
const vmdebug = lus.vm.debug;
const Value = value.Value;
const Thread = state.Thread;
const Table = object.Table;
const String = object.String;
const Closure = object.Closure;
const Allocator = std.mem.Allocator;
const Json = dap.Json;
const JsonValue = std.json.Value;
const fd_t = std.c.fd_t;

const usage =
    \\usage: lus debug [--stdio | --port N] [-P perm]... [SCRIPT [ARGS...]]
    \\
    \\  --stdio     speak the Debug Adapter Protocol on standard input and
    \\              output (the default)
    \\  --port N    accept one client on 127.0.0.1:N instead
    \\  -P perm     grant a permission to the program (also --pledge)
    \\
    \\Without SCRIPT, the program comes from the launch request.
    \\
;

/// The thread id reported for the program. Coroutines appear in the
/// stack of this one thread, above the frames that resumed them.
const thread_id = 1;

/// Tables expanded with more array entries than this are paged.
const page_threshold = 100;

/// Variables longer than this are cut in the variables view.
const max_value_len = 1000;

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    if (comptime builtin.os.tag == .windows) {
        std.debug.print("lus debug: not available on Windows yet\n", .{});
        return 1;
    }
    const gpa = init.gpa;
    var port: ?u16 = null;
    var pledges: std.ArrayList([]const u8) = .empty;
    defer pledges.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--stdio")) {
            port = null;
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) return usageError("'--port' needs a number");
            port = std.fmt.parseInt(u16, args[i], 10) catch return usageError("bad port number");
        } else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--pledge")) {
            i += 1;
            if (i >= args.len) return usageError("'-P' needs a permission");
            try pledges.append(gpa, args[i]);
        } else if (std.mem.startsWith(u8, a, "-P") and a.len > 2) {
            try pledges.append(gpa, a[2..]);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (a.len > 1 and a[0] == '-') {
            return usageError("unknown option");
        } else break;
    }
    const script: ?[]const u8 = if (i < args.len) args[i] else null;
    const script_args: []const []const u8 = if (i + 1 < args.len) args[i + 1 ..] else &.{};

    // The protocol channel.
    var in_fd: fd_t = undefined;
    var out_fd: fd_t = undefined;
    if (port) |p| {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", p) catch unreachable;
        var server = addr.listen(init.io, .{ .reuse_address = true }) catch |e| {
            std.debug.print("lus debug: cannot listen on 127.0.0.1:{d} ({s})\n", .{ p, @errorName(e) });
            return 1;
        };
        std.debug.print("lus debug: listening on 127.0.0.1:{d}\n", .{p});
        const stream = server.accept(init.io) catch |e| {
            std.debug.print("lus debug: accept failed ({s})\n", .{@errorName(e)});
            return 1;
        };
        server.deinit(init.io);
        in_fd = stream.socket.handle;
        out_fd = stream.socket.handle;
    } else {
        in_fd = std.c.dup(0);
        out_fd = std.c.dup(1);
        if (in_fd < 0 or out_fd < 0) return 1;
        // The protocol owns the real standard input, so the program
        // reads an empty one.
        var p: [2]fd_t = undefined;
        if (std.c.pipe(&p) == 0) {
            _ = std.c.dup2(p[0], 0);
            _ = std.c.close(p[0]);
            _ = std.c.close(p[1]);
        }
    }

    var transport: dap.Transport = .{ .gpa = gpa, .io = init.io, .in_fd = in_fd, .out_fd = out_fd };
    var s: Session = .{
        .gpa = gpa,
        .init = init,
        .t = &transport,
        .cwd = try currentDir(gpa),
        .cli_pledges = pledges.items,
    };
    defer s.deinit();
    s.dbg = .{ .ctx = &s, .event = &onEvent, .raised = &onRaised, .mask = Thread.hook_line };
    if (script) |path| {
        s.program = try gpa.dupe(u8, path);
        for (script_args) |a| try s.program_args.append(gpa, try gpa.dupe(u8, a));
        s.program_from_cli = true;
    }

    // The program's output becomes output events.
    var capture = Capture.start(&s) catch {
        std.debug.print("lus debug: cannot capture the program output\n", .{});
        return 1;
    };
    try transport.startReader();

    // Configuration: initialize, breakpoints, launch, configurationDone.
    while (!(s.launched and s.configured)) {
        const msg = transport.wait() orelse return capture.abandon(0);
        s.dispatch(null, msg);
    }

    const code = s.execute();
    capture.finish();
    s.sendExited(code);
    s.sendEvent("terminated");
    // Answer until the client disconnects.
    while (transport.wait()) |msg| s.dispatch(null, msg);
    return code;
}

fn usageError(msg: []const u8) u8 {
    std.debug.print("lus debug: {s}\n{s}", .{ msg, usage });
    return 2;
}

fn currentDir(gpa: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const p = std.c.getcwd(&buf, buf.len) orelse return gpa.dupe(u8, ".");
    return gpa.dupe(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(p)), 0));
}

// ---------------------------------------------------------------------
// Output capture

/// Redirects standard output and standard error into pipes. One thread
/// per pipe forwards what the program writes as output events.
const Capture = struct {
    saved_out: fd_t,
    saved_err: fd_t,
    threads: [2]?std.Thread = .{ null, null },

    fn start(s: *Session) !Capture {
        var c: Capture = .{ .saved_out = std.c.dup(1), .saved_err = std.c.dup(2) };
        const names = [_][]const u8{ "stdout", "stderr" };
        for (names, 0..) |category, k| {
            var p: [2]fd_t = undefined;
            if (std.c.pipe(&p) != 0) return error.Pipe;
            const target: fd_t = @intCast(k + 1);
            _ = std.c.dup2(p[1], target);
            _ = std.c.close(p[1]);
            c.threads[k] = try std.Thread.spawn(.{}, forward, .{ s, p[0], category });
        }
        return c;
    }

    /// Closes the pipes and waits until everything written was sent.
    fn finish(c: *Capture) void {
        // In stdio mode the original standard output is the protocol
        // channel, so nothing else may write there.
        _ = std.c.dup2(c.saved_err, 1);
        _ = std.c.dup2(c.saved_err, 2);
        for (&c.threads) |*t| if (t.*) |th| {
            th.join();
            t.* = null;
        };
    }

    fn abandon(c: *Capture, code: u8) u8 {
        c.finish();
        return code;
    }

    fn forward(s: *Session, fd: fd_t, category: []const u8) void {
        var buf: [8192]u8 = undefined;
        var keep: usize = 0;
        while (true) {
            const n = dap.readSome(fd, buf[keep..]);
            if (n == 0) {
                if (keep > 0) s.sendOutput(category, buf[0..keep]);
                _ = std.c.close(fd);
                return;
            }
            const total = keep + n;
            // Hold back a character cut by the end of the read.
            const cut = if (total == buf.len) total else completePrefix(buf[0..total]);
            if (cut > 0) s.sendOutput(category, buf[0..cut]);
            std.mem.copyForwards(u8, buf[0 .. total - cut], buf[cut..total]);
            keep = total - cut;
        }
    }
};

/// The length of the longest prefix of `b` that does not end inside a
/// multi-byte UTF-8 sequence.
fn completePrefix(b: []const u8) usize {
    var i = b.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const c = b[i];
        if (c & 0xC0 == 0x80) continue;
        const need: usize = if (c < 0x80) 1 else if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else if (c >= 0xC0) 2 else 1;
        return if (back >= need) b.len else i;
    }
    return b.len;
}

// ---------------------------------------------------------------------
// Session state

const Step = enum { none, entry, in, over, out };

const Reason = enum {
    entry,
    step,
    breakpoint,
    pause,
    exception,
};

const Breakpoint = struct {
    id: i64,
    line: u32,
    condition: ?[]u8 = null,
    hit_condition: ?[]u8 = null,
    log_message: ?[]u8 = null,
    hits: u32 = 0,

    fn deinit(b: *Breakpoint, gpa: Allocator) void {
        if (b.condition) |x| gpa.free(x);
        if (b.hit_condition) |x| gpa.free(x);
        if (b.log_message) |x| gpa.free(x);
    }
};

/// The breakpoints of one source file, with a bit per line that has one.
const SourceBps = struct {
    bps: std.ArrayList(Breakpoint) = .empty,
    lines: std.DynamicBitSetUnmanaged = .{},

    fn deinit(sb: *SourceBps, gpa: Allocator) void {
        for (sb.bps.items) |*b| b.deinit(gpa);
        sb.bps.deinit(gpa);
        sb.lines.deinit(gpa);
    }

    fn hasLine(sb: *const SourceBps, line: u32) bool {
        return line < sb.lines.bit_length and sb.lines.isSet(line);
    }
};

/// A stack frame of a stopped program: frame `fi` of thread `th`, or the
/// label that separates a coroutine from the thread that resumed it.
const FrameRef = struct {
    th: *Thread,
    fi: usize,
    label: bool = false,

    fn frame(r: FrameRef) state.Frame {
        return r.th.frames.items[r.fi];
    }
};

/// What a variables reference expands to.
const Ref = union(enum) {
    locals: FrameRef,
    upvalues: FrameRef,
    /// A value kept in the anchor table, with the expression that reads
    /// it when one exists.
    value: struct { slot: i64, eval: ?[]const u8 },
};

const Request = struct {
    seq: i64,
    command: []const u8,
    args: ?std.json.ObjectMap,
};

const Command = enum {
    initialize,
    launch,
    attach,
    setBreakpoints,
    setExceptionBreakpoints,
    setFunctionBreakpoints,
    configurationDone,
    threads,
    stackTrace,
    scopes,
    variables,
    @"continue",
    next,
    stepIn,
    stepOut,
    pause,
    evaluate,
    source,
    exceptionInfo,
    disconnect,
    terminate,
};

const Session = struct {
    gpa: Allocator,
    init: std.process.Init,
    t: *dap.Transport,
    cwd: []u8,
    dbg: state.Debugger = undefined,

    // Launch configuration.
    program: ?[]u8 = null,
    program_args: std.ArrayList([]u8) = .empty,
    program_from_cli: bool = false,
    cli_pledges: []const []const u8,
    launch_pledges: std.ArrayList([]u8) = .empty,
    stop_on_entry: bool = false,
    no_debug: bool = false,
    launched: bool = false,
    configured: bool = false,

    // Breakpoints, by canonical path.
    sources: std.StringHashMapUnmanaged(*SourceBps) = .empty,
    bp_total: usize = 0,
    next_bp_id: i64 = 1,
    /// Source string of a chunk to its breakpoints. The strings are
    /// anchored in the registry, so a pointer always means one source.
    cache: std.AutoHashMapUnmanaged(*String, ?*SourceBps) = .empty,
    exc_raised: bool = false,
    exc_uncaught: bool = false,

    // Execution control.
    step: Step = .none,
    step_depth: usize = 0,
    pause_requested: bool = false,
    /// Set once an error was reported, until the next line runs, so an
    /// error crossing several native boundaries stops once.
    err_reported: bool = false,
    paused: bool = false,
    main: ?*Thread = null,

    // Valid while stopped.
    frames: std.ArrayList(FrameRef) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    anchor: ?*Table = null,
    anchor_n: i64 = 0,
    pause_arena: ?std.heap.ArenaAllocator = null,
    exception: ?[]const u8 = null,
    exception_trace: ?[]const u8 = null,

    fn deinit(s: *Session) void {
        const gpa = s.gpa;
        gpa.free(s.cwd);
        if (s.program) |p| gpa.free(p);
        for (s.program_args.items) |a| gpa.free(a);
        s.program_args.deinit(gpa);
        for (s.launch_pledges.items) |a| gpa.free(a);
        s.launch_pledges.deinit(gpa);
        var it = s.sources.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit(gpa);
            gpa.destroy(e.value_ptr.*);
        }
        s.sources.deinit(gpa);
        s.cache.deinit(gpa);
        s.frames.deinit(gpa);
        s.refs.deinit(gpa);
        if (s.pause_arena) |*a| a.deinit();
    }

    // -----------------------------------------------------------------
    // Messages

    fn dispatch(s: *Session, l: ?*Thread, msg: []u8) void {
        defer s.gpa.free(msg);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const root = std.json.parseFromSliceLeaky(JsonValue, a, msg, .{}) catch return;
        if (root != .object) return;
        const obj = root.object;
        const kind = getStr(obj, "type") orelse return;
        if (!std.mem.eql(u8, kind, "request")) return;
        const req: Request = .{
            .seq = getInt(obj, "seq") orelse 0,
            .command = getStr(obj, "command") orelse return,
            .args = getObj(obj, "arguments"),
        };
        s.handle(l, req, a) catch |e| {
            s.fail(req, switch (e) {
                error.NotStopped => "the program is not stopped",
                error.BadFrame => "unknown frame",
                error.BadReference => "unknown variables reference",
                error.NoProgram => "no program to debug: set 'program' in the launch configuration",
                else => @errorName(e),
            });
        };
    }

    fn handle(s: *Session, l: ?*Thread, req: Request, a: Allocator) !void {
        const cmd = std.meta.stringToEnum(Command, req.command) orelse {
            return s.fail(req, "unsupported request");
        };
        switch (cmd) {
            .initialize => {
                var j = try s.beginResponse(req);
                defer j.deinit();
                try j.key("body");
                try j.beginObject();
                try j.fieldBool("supportsConfigurationDoneRequest", true);
                try j.fieldBool("supportsConditionalBreakpoints", true);
                try j.fieldBool("supportsHitConditionalBreakpoints", true);
                try j.fieldBool("supportsLogPoints", true);
                try j.fieldBool("supportsEvaluateForHovers", true);
                try j.fieldBool("supportsTerminateRequest", true);
                try j.fieldBool("supportsExceptionInfoRequest", true);
                try j.key("exceptionBreakpointFilters");
                try j.beginArray();
                try j.beginObject();
                try j.fieldString("filter", "uncaught");
                try j.fieldString("label", "Uncaught Errors");
                try j.fieldBool("default", true);
                try j.endObject();
                try j.beginObject();
                try j.fieldString("filter", "raised");
                try j.fieldString("label", "All Raised Errors");
                try j.fieldBool("default", false);
                try j.endObject();
                try j.endArray();
                try j.endObject();
                try s.finishResponse(&j);
                s.sendEvent("initialized");
            },
            .launch => {
                const args = req.args;
                if (!s.program_from_cli) {
                    if (args) |o| if (getStr(o, "program")) |p| {
                        s.program = try s.gpa.dupe(u8, p);
                        if (getArr(o, "args")) |arr| for (arr.items) |v| {
                            if (v == .string) try s.program_args.append(s.gpa, try s.gpa.dupe(u8, v.string));
                        };
                    };
                }
                if (args) |o| {
                    if (getStr(o, "cwd")) |dir| try s.changeDir(dir);
                    s.stop_on_entry = getBool(o, "stopOnEntry") orelse false;
                    s.no_debug = getBool(o, "noDebug") orelse false;
                    if (getArr(o, "pledges")) |arr| for (arr.items) |v| {
                        if (v == .string) try s.launch_pledges.append(s.gpa, try s.gpa.dupe(u8, v.string));
                    };
                }
                if (s.program == null) return error.NoProgram;
                s.launched = true;
                try s.ok(req);
            },
            .attach => return s.fail(req, "lus debug launches programs and cannot attach"),
            .setBreakpoints => try s.setBreakpoints(req, a),
            .setExceptionBreakpoints => {
                s.exc_raised = false;
                s.exc_uncaught = false;
                if (req.args) |o| if (getArr(o, "filters")) |arr| for (arr.items) |v| {
                    if (v != .string) continue;
                    if (std.mem.eql(u8, v.string, "raised")) s.exc_raised = true;
                    if (std.mem.eql(u8, v.string, "uncaught")) s.exc_uncaught = true;
                };
                try s.ok(req);
            },
            .setFunctionBreakpoints => {
                var j = try s.beginResponse(req);
                defer j.deinit();
                try j.key("body");
                try j.beginObject();
                try j.key("breakpoints");
                try j.beginArray();
                try j.endArray();
                try j.endObject();
                try s.finishResponse(&j);
            },
            .configurationDone => {
                s.configured = true;
                try s.ok(req);
            },
            .threads => {
                var j = try s.beginResponse(req);
                defer j.deinit();
                try j.key("body");
                try j.beginObject();
                try j.key("threads");
                try j.beginArray();
                try j.beginObject();
                try j.fieldInt("id", thread_id);
                try j.fieldString("name", "main");
                try j.endObject();
                try j.endArray();
                try j.endObject();
                try s.finishResponse(&j);
            },
            .pause => {
                if (!s.paused) s.pause_requested = true;
                try s.ok(req);
            },
            .@"continue", .next, .stepIn, .stepOut => {
                if (s.paused) {
                    const th = l.?;
                    s.step = switch (cmd) {
                        .next => .over,
                        .stepIn => .in,
                        .stepOut => .out,
                        else => .none,
                    };
                    s.step_depth = depth(th);
                    s.paused = false;
                }
                if (cmd == .@"continue") {
                    var j = try s.beginResponse(req);
                    defer j.deinit();
                    try j.key("body");
                    try j.beginObject();
                    try j.fieldBool("allThreadsContinued", true);
                    try j.endObject();
                    try s.finishResponse(&j);
                } else try s.ok(req);
            },
            .stackTrace => try s.stackTrace(req),
            .scopes => try s.scopes(req),
            .variables => try s.variables(req, a),
            .evaluate => try s.evaluateRequest(l, req, a),
            .source => try s.sourceRequest(req, a),
            .exceptionInfo => {
                const msg = s.exception orelse return error.NotStopped;
                var j = try s.beginResponse(req);
                defer j.deinit();
                try j.key("body");
                try j.beginObject();
                try j.fieldString("exceptionId", "error");
                try j.fieldString("description", msg);
                try j.fieldString("breakMode", if (s.exc_raised) "always" else "unhandled");
                try j.key("details");
                try j.beginObject();
                try j.fieldString("message", msg);
                if (s.exception_trace) |tb| try j.fieldString("stackTrace", tb);
                try j.endObject();
                try j.endObject();
                try s.finishResponse(&j);
            },
            .disconnect, .terminate => {
                try s.ok(req);
                if (cmd == .terminate) s.sendEvent("terminated");
                if (s.main) |m| out.flushAll(m.g);
                std.process.exit(0);
            },
        }
    }

    fn changeDir(s: *Session, dir: []const u8) !void {
        const z = try s.gpa.dupeSentinel(u8, dir, 0);
        defer s.gpa.free(z);
        if (std.c.chdir(z) != 0) return error.CannotChangeDirectory;
        s.gpa.free(s.cwd);
        s.cwd = try currentDir(s.gpa);
    }

    // -----------------------------------------------------------------
    // Responses and events

    fn beginResponse(s: *Session, req: Request) !Json {
        var j: Json = .{ .gpa = s.gpa };
        errdefer j.deinit();
        try j.beginObject();
        try j.fieldInt("seq", s.t.nextSeq());
        try j.fieldString("type", "response");
        try j.fieldInt("request_seq", req.seq);
        try j.fieldBool("success", true);
        try j.fieldString("command", req.command);
        return j;
    }

    fn finishResponse(s: *Session, j: *Json) !void {
        try j.endObject();
        s.t.send(j.buf.items);
    }

    fn ok(s: *Session, req: Request) !void {
        var j = try s.beginResponse(req);
        defer j.deinit();
        try s.finishResponse(&j);
    }

    fn fail(s: *Session, req: Request, message: []const u8) void {
        var j: Json = .{ .gpa = s.gpa };
        defer j.deinit();
        (struct {
            fn write(jj: *Json, ss: *Session, r: Request, m: []const u8) !void {
                try jj.beginObject();
                try jj.fieldInt("seq", ss.t.nextSeq());
                try jj.fieldString("type", "response");
                try jj.fieldInt("request_seq", r.seq);
                try jj.fieldBool("success", false);
                try jj.fieldString("command", r.command);
                try jj.fieldString("message", m);
                try jj.endObject();
            }
        }).write(&j, s, req, message) catch return;
        s.t.send(j.buf.items);
    }

    fn beginEvent(s: *Session, j: *Json, name: []const u8) !void {
        try j.beginObject();
        try j.fieldInt("seq", s.t.nextSeq());
        try j.fieldString("type", "event");
        try j.fieldString("event", name);
    }

    fn sendEvent(s: *Session, name: []const u8) void {
        var j: Json = .{ .gpa = s.gpa };
        defer j.deinit();
        s.beginEvent(&j, name) catch return;
        j.endObject() catch return;
        s.t.send(j.buf.items);
    }

    fn sendExited(s: *Session, code: u8) void {
        var j: Json = .{ .gpa = s.gpa };
        defer j.deinit();
        (struct {
            fn write(jj: *Json, ss: *Session, c: u8) !void {
                try ss.beginEvent(jj, "exited");
                try jj.key("body");
                try jj.beginObject();
                try jj.fieldInt("exitCode", c);
                try jj.endObject();
                try jj.endObject();
            }
        }).write(&j, s, code) catch return;
        s.t.send(j.buf.items);
    }

    /// Sends an output event. Called from the forwarding threads too.
    fn sendOutput(s: *Session, category: []const u8, text: []const u8) void {
        var j: Json = .{ .gpa = s.gpa };
        defer j.deinit();
        (struct {
            fn write(jj: *Json, ss: *Session, c: []const u8, t: []const u8) !void {
                try ss.beginEvent(jj, "output");
                try jj.key("body");
                try jj.beginObject();
                try jj.fieldString("category", c);
                try jj.fieldString("output", t);
                try jj.endObject();
                try jj.endObject();
            }
        }).write(&j, s, category, text) catch return;
        s.t.send(j.buf.items);
    }

    fn sendStopped(s: *Session, reason: Reason, text: ?[]const u8, bp: ?i64) void {
        var j: Json = .{ .gpa = s.gpa };
        defer j.deinit();
        (struct {
            fn write(jj: *Json, ss: *Session, r: Reason, t: ?[]const u8, b: ?i64) !void {
                try ss.beginEvent(jj, "stopped");
                try jj.key("body");
                try jj.beginObject();
                try jj.fieldString("reason", @tagName(r));
                try jj.fieldInt("threadId", thread_id);
                try jj.fieldBool("allThreadsStopped", true);
                if (r == .exception) try jj.fieldString("description", "Paused on error");
                if (t) |x| try jj.fieldString("text", x);
                if (b) |id| {
                    try jj.key("hitBreakpointIds");
                    try jj.beginArray();
                    try jj.int(id);
                    try jj.endArray();
                }
                try jj.endObject();
                try jj.endObject();
            }
        }).write(&j, s, reason, text, bp) catch return;
        s.t.send(j.buf.items);
    }

    // -----------------------------------------------------------------
    // Running the program

    fn execute(s: *Session) u8 {
        return s.executeInner() catch |e| {
            std.debug.print("lus debug: {s}\n", .{@errorName(e)});
            return 1;
        };
    }

    fn executeInner(s: *Session) !u8 {
        const gpa = s.gpa;
        const io = s.init.io;
        const path = s.program orelse return error.NoProgram;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "lus");
        try argv.append(gpa, path);
        for (s.program_args.items) |a| try argv.append(gpa, a);
        var grants: std.ArrayList([]const u8) = .empty;
        defer grants.deinit(gpa);
        try grants.appendSlice(gpa, s.cli_pledges);
        for (s.launch_pledges.items) |p| try grants.append(gpa, p);

        const l = try api.newState(gpa, io);
        defer api.close(l);
        defer out.deinit(l.g);
        s.main = l;
        defer s.main = null;
        defer s.cache.clearRetainingCapacity();
        l.g.environ = s.init.environ_map;
        l.g.args = argv.items;
        try api.setFlags(l, &.{});
        if (!s.no_debug) {
            l.g.debugger = &s.dbg;
            l.hook_mask = s.dbg.mask;
            l.hook_oldfi = std.math.maxInt(usize);
        }
        api.openLibs(l) catch {
            std.debug.print("lus: cannot open libraries\n", .{});
            return 1;
        };
        api.grantPledges(l, grants.items) catch {
            reportError(l);
            return 1;
        };
        try setArgTable(l, argv.items);

        const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            std.debug.print("lus: cannot open {s} ({s})\n", .{ path, @errorName(e) });
            return 1;
        };
        defer gpa.free(src);
        const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{path});
        defer gpa.free(chunkname);
        if (s.stop_on_entry) s.step = .entry;
        const base = l.top;
        api.load(l, src, chunkname) catch {
            reportError(l);
            return 1;
        };
        for (s.program_args.items) |a| try l.push(try l.newStringValue(a));
        l.want_traceback = true;
        l.err_traceback = null;
        const ok_run = api.pcall(l, @intCast(s.program_args.items.len), 0);
        l.want_traceback = false;
        if (!ok_run) {
            reportError(l);
            l.top = base;
            out.flushAll(l.g);
            return 1;
        }
        l.top = base;
        out.flushAll(l.g);
        return 0;
    }

    // -----------------------------------------------------------------
    // Hook events

    fn onLine(s: *Session, l: *Thread, line: u32) Error!void {
        s.err_reported = false;
        if (s.t.pending.load(.acquire)) s.drain(l);
        var reason: ?Reason = null;
        if (s.pause_requested) {
            s.pause_requested = false;
            reason = .pause;
        }
        switch (s.step) {
            .none => {},
            .entry => reason = .entry,
            .in => reason = reason orelse .step,
            .over => if (depth(l) <= s.step_depth) {
                reason = reason orelse .step;
            },
            .out => if (depth(l) < s.step_depth) {
                reason = reason orelse .step;
            },
        }
        var hit: ?i64 = null;
        if (s.bp_total > 0) {
            hit = try s.checkBreakpoint(l, line);
            if (hit != null) reason = .breakpoint;
        }
        if (reason) |r| try s.stop(l, r, null, hit);
    }

    fn onError(s: *Session, l: *Thread) void {
        if (!l.allow_hook or s.err_reported) return;
        s.err_reported = true;
        if (!s.exc_raised and !s.exc_uncaught) return;
        if (!s.exc_raised and hasHandler(l)) return;
        l.allow_hook = false;
        defer l.allow_hook = true;
        const saved_top = l.top;
        defer l.top = saved_top;
        protectTop(l);
        const err = l.err;
        const saved_tb = l.err_traceback;
        defer {
            l.err = err;
            l.err_traceback = saved_tb;
        }
        // Keep the error value alive while the program is stopped.
        l.push(err) catch return;
        const msg = s.gpa.dupe(u8, api.errorMessage(l, err)) catch return;
        defer s.gpa.free(msg);
        var tb: std.ArrayList(u8) = .empty;
        defer tb.deinit(l.g.gpa);
        vmdebug.traceback(l, &tb, 0) catch {};
        s.exception = msg;
        s.exception_trace = tb.items;
        defer {
            s.exception = null;
            s.exception_trace = null;
        }
        s.stop(l, .exception, msg, null) catch {};
    }

    /// Handles requests that arrived while the program runs.
    fn drain(s: *Session, l: *Thread) void {
        while (s.t.poll()) |msg| s.dispatch(l, msg);
        if (s.t.isClosed()) std.process.exit(0);
    }

    fn stop(s: *Session, l: *Thread, reason: Reason, text: ?[]const u8, bp: ?i64) Error!void {
        out.flushAll(l.g);
        s.step = .none;
        s.pause_requested = false;
        try s.beginPause(l);
        defer s.endPause(l);
        s.paused = true;
        s.sendStopped(reason, text, bp);
        while (s.paused) {
            const msg = s.t.wait() orelse std.process.exit(0);
            s.dispatch(l, msg);
        }
    }

    fn beginPause(s: *Session, l: *Thread) Error!void {
        s.pause_arena = std.heap.ArenaAllocator.init(s.gpa);
        s.frames.clearRetainingCapacity();
        s.refs.clearRetainingCapacity();
        const anchor = try l.newTable(0, 0);
        try aux.setField(l, l.g.registry.as(Table), "lus.debug.anchor", Value.obj(.table, anchor));
        s.anchor = anchor;
        s.anchor_n = 0;
        var th: ?*Thread = l;
        while (th) |t| : (th = t.resumer) {
            if (t != l) s.frames.append(s.gpa, .{ .th = t, .fi = 0, .label = true }) catch return l.raiseMem();
            var i = t.frames.items.len;
            while (i > 0) {
                i -= 1;
                if (t.frames.items[i].hook) continue;
                s.frames.append(s.gpa, .{ .th = t, .fi = i }) catch return l.raiseMem();
            }
        }
    }

    fn endPause(s: *Session, l: *Thread) void {
        s.frames.clearRetainingCapacity();
        s.refs.clearRetainingCapacity();
        s.anchor = null;
        aux.setField(l, l.g.registry.as(Table), "lus.debug.anchor", .nil) catch {};
        if (s.pause_arena) |*a| a.deinit();
        s.pause_arena = null;
    }

    fn arena(s: *Session) Allocator {
        return s.pause_arena.?.allocator();
    }

    // -----------------------------------------------------------------
    // Breakpoints

    fn setBreakpoints(s: *Session, req: Request, a: Allocator) !void {
        const o = req.args orelse return error.MissingArguments;
        const src = getObj(o, "source") orelse return error.MissingArguments;
        const path = getStr(src, "path") orelse return s.fail(req, "breakpoints need a source path");
        const key = try s.canonical(path);
        var sb: *SourceBps = undefined;
        if (s.sources.get(key)) |existing| {
            s.gpa.free(key);
            sb = existing;
            s.bp_total -= sb.bps.items.len;
            for (sb.bps.items) |*b| b.deinit(s.gpa);
            sb.bps.clearRetainingCapacity();
        } else {
            sb = try s.gpa.create(SourceBps);
            sb.* = .{};
            try s.sources.put(s.gpa, key, sb);
        }
        var max_line: u32 = 0;
        if (getArr(o, "breakpoints")) |arr| for (arr.items) |v| {
            if (v != .object) continue;
            const line = getInt(v.object, "line") orelse continue;
            if (line < 1) continue;
            var b: Breakpoint = .{ .id = s.next_bp_id, .line = @intCast(line) };
            s.next_bp_id += 1;
            if (nonEmpty(getStr(v.object, "condition"))) |c| b.condition = try s.gpa.dupe(u8, c);
            if (nonEmpty(getStr(v.object, "hitCondition"))) |c| b.hit_condition = try s.gpa.dupe(u8, c);
            if (nonEmpty(getStr(v.object, "logMessage"))) |c| b.log_message = try s.gpa.dupe(u8, c);
            try sb.bps.append(s.gpa, b);
            max_line = @max(max_line, b.line);
        };
        sb.lines.deinit(s.gpa);
        sb.lines = try std.DynamicBitSetUnmanaged.initEmpty(s.gpa, max_line + 1);
        for (sb.bps.items) |b| sb.lines.set(b.line);
        s.bp_total += sb.bps.items.len;
        s.cache.clearRetainingCapacity();

        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.key("breakpoints");
        try j.beginArray();
        for (sb.bps.items) |b| {
            try j.beginObject();
            try j.fieldInt("id", b.id);
            try j.fieldBool("verified", true);
            try j.fieldInt("line", b.line);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
        try s.finishResponse(&j);
        _ = a;
    }

    /// The breakpoint id to stop at on this line, after conditions, hit
    /// counts, and log messages.
    fn checkBreakpoint(s: *Session, l: *Thread, line: u32) Error!?i64 {
        const cl = l.frame().closure orelse return null;
        const src = cl.proto.source orelse return null;
        const sb = (try s.lookupSource(l, src)) orelse return null;
        if (!sb.hasLine(line)) return null;
        for (sb.bps.items) |*b| {
            if (b.line != line) continue;
            if (b.condition) |c| if (!s.conditionHolds(l, c)) continue;
            b.hits += 1;
            if (b.hit_condition) |h| if (!hitMatches(h, b.hits)) continue;
            if (b.log_message) |m| {
                s.logPoint(l, m);
                continue;
            }
            return b.id;
        }
        return null;
    }

    fn lookupSource(s: *Session, l: *Thread, src: *String) Error!?*SourceBps {
        if (s.cache.get(src)) |e| return e;
        var found: ?*SourceBps = null;
        const b = src.bytes();
        if (b.len > 1 and b[0] == '@') {
            const key = s.canonical(b[1..]) catch return l.raiseMem();
            defer s.gpa.free(key);
            found = s.sources.get(key);
        }
        // Anchor the string so its address keeps naming this source.
        const reg = l.g.registry.as(Table);
        var anchors = try aux.getField(l, reg, "lus.debug.sources");
        if (anchors.tag != .table) {
            anchors = Value.obj(.table, try l.newTable(0, 4));
            try aux.setField(l, reg, "lus.debug.sources", anchors);
        }
        try ops.rawSet(l, anchors.as(Table), Value.obj(.string, src), .true);
        s.cache.put(s.gpa, src, found) catch return l.raiseMem();
        return found;
    }

    /// An absolute path with symbolic links resolved, so the paths of the
    /// client and of chunk names compare equal.
    fn canonical(s: *Session, path: []const u8) ![]u8 {
        const abs = try std.fs.path.resolveAlloc(s.gpa, &.{ s.cwd, path });
        const z = try s.gpa.dupeSentinel(u8, abs, 0);
        defer s.gpa.free(z);
        var buf: [std.c.PATH_MAX]u8 = undefined;
        if (std.c.realpath(z, &buf)) |r| {
            s.gpa.free(abs);
            return s.gpa.dupe(u8, std.mem.sliceTo(r, 0));
        }
        return abs;
    }

    fn conditionHolds(s: *Session, l: *Thread, cond: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const top: FrameRef = .{ .th = l, .fi = l.frames.items.len - 1 };
        const r = s.evaluate(l, top, cond, arena_state.allocator(), false, false);
        if (r.err) |m| {
            const text = std.fmt.allocPrint(arena_state.allocator(), "breakpoint condition '{s}' failed: {s}\n", .{ cond, m }) catch return true;
            s.sendOutput("console", text);
            return true;
        }
        return r.n > 0 and r.values[0].truthy();
    }

    /// Prints a log message, with each `{expression}` replaced by its value.
    fn logPoint(s: *Session, l: *Thread, msg: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const top: FrameRef = .{ .th = l, .fi = l.frames.items.len - 1 };
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < msg.len) {
            if (msg[i] == '{') if (std.mem.indexOfScalarPos(u8, msg, i + 1, '}')) |close| {
                const r = s.evaluate(l, top, msg[i + 1 .. close], a, false, false);
                if (r.err) |m| {
                    buf.print(a, "<{s}>", .{m}) catch return;
                } else if (r.n > 0) {
                    describe(l, a, &buf, r.values[0], false, 0) catch return;
                } else buf.appendSlice(a, "nil") catch return;
                i = close + 1;
                continue;
            };
            buf.append(a, msg[i]) catch return;
            i += 1;
        }
        buf.append(a, '\n') catch return;
        s.sendOutput("console", buf.items);
    }

    // -----------------------------------------------------------------
    // Inspection

    fn stackTrace(s: *Session, req: Request) !void {
        if (!s.paused) return error.NotStopped;
        const o = req.args;
        const start: usize = @intCast(@max(0, if (o) |x| getInt(x, "startFrame") orelse 0 else 0));
        const levels: usize = @intCast(@max(0, if (o) |x| getInt(x, "levels") orelse 0 else 0));
        const end = if (levels == 0) s.frames.items.len else @min(s.frames.items.len, start + levels);
        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.key("stackFrames");
        try j.beginArray();
        var k = start;
        while (k < end) : (k += 1) try s.writeFrame(&j, k);
        try j.endArray();
        try j.fieldInt("totalFrames", @intCast(s.frames.items.len));
        try j.endObject();
        try s.finishResponse(&j);
    }

    fn writeFrame(s: *Session, j: *Json, k: usize) !void {
        const r = s.frames.items[k];
        try j.beginObject();
        try j.fieldInt("id", @intCast(k + 1));
        if (r.label) {
            try j.fieldString("name", "coroutine resumed here");
            try j.fieldInt("line", 0);
            try j.fieldInt("column", 0);
            try j.fieldString("presentationHint", "label");
            try j.endObject();
            return;
        }
        const fr = r.frame();
        var namebuf: [256]u8 = undefined;
        const name = frameName(r, &namebuf);
        if (fr.closure) |cl| {
            const p = cl.proto;
            try j.fieldString("name", name);
            try s.writeSource(j, p);
            try j.fieldInt("line", state.currentLine(p, fr.pc));
            try j.fieldInt("column", 1);
        } else {
            var buf: [300]u8 = undefined;
            try j.fieldString("name", std.fmt.bufPrint(&buf, "[C] {s}", .{name}) catch name);
            try j.fieldInt("line", 0);
            try j.fieldInt("column", 0);
            try j.fieldString("presentationHint", "subtle");
        }
        try j.endObject();
    }

    fn writeSource(s: *Session, j: *Json, p: *object.Proto) !void {
        const src = if (p.source) |x| x.bytes() else "?";
        try j.key("source");
        try j.beginObject();
        if (src.len > 1 and src[0] == '@') {
            const abs = try std.fs.path.resolveAlloc(s.arena(), &.{ s.cwd, src[1..] });
            try j.fieldString("name", std.fs.path.basename(abs));
            try j.fieldString("path", abs);
        } else {
            try j.fieldString("name", state.chunkId(src));
            try j.fieldString("presentationHint", "deemphasize");
        }
        try j.endObject();
    }

    fn frameAt(s: *Session, id: ?i64) !FrameRef {
        const n = id orelse return error.BadFrame;
        if (n < 1 or n > s.frames.items.len) return error.BadFrame;
        return s.frames.items[@intCast(n - 1)];
    }

    fn scopes(s: *Session, req: Request) !void {
        if (!s.paused) return error.NotStopped;
        const r = try s.frameAt(if (req.args) |o| getInt(o, "frameId") else null);
        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.key("scopes");
        try j.beginArray();
        if (!r.label) {
            const l = s.main.?;
            if (r.frame().closure) |cl| {
                try s.writeScope(&j, "Locals", "locals", try s.newRef(.{ .locals = r }), false);
                if (cl.nupvals > 0) try s.writeScope(&j, "Upvalues", null, try s.newRef(.{ .upvalues = r }), false);
            }
            const env = frameEnv(l, r);
            try s.writeScope(&j, "Globals", null, try s.valueRef(l, env, null), true);
        }
        try j.endArray();
        try j.endObject();
        try s.finishResponse(&j);
    }

    fn writeScope(s: *Session, j: *Json, name: []const u8, hint: ?[]const u8, ref: i64, expensive: bool) !void {
        _ = s;
        try j.beginObject();
        try j.fieldString("name", name);
        if (hint) |h| try j.fieldString("presentationHint", h);
        try j.fieldInt("variablesReference", ref);
        try j.fieldBool("expensive", expensive);
        try j.endObject();
    }

    fn newRef(s: *Session, r: Ref) !i64 {
        try s.refs.append(s.gpa, r);
        return @intCast(s.refs.items.len);
    }

    /// Anchors `v` until the program continues and returns its slot.
    fn anchorValue(s: *Session, l: *Thread, v: Value) Error!i64 {
        s.anchor_n += 1;
        try ops.rawSet(l, s.anchor.?, Value.int(s.anchor_n), v);
        return s.anchor_n;
    }

    /// A variables reference for `v`, or 0 when it has nothing to expand.
    fn valueRef(s: *Session, l: *Thread, v: Value, eval: ?[]const u8) !i64 {
        if (!expandable(l, v)) return 0;
        const slot = try s.anchorValue(l, v);
        return s.newRef(.{ .value = .{ .slot = slot, .eval = eval } });
    }

    fn variables(s: *Session, req: Request, a: Allocator) !void {
        if (!s.paused) return error.NotStopped;
        const o = req.args orelse return error.BadReference;
        const id = getInt(o, "variablesReference") orelse return error.BadReference;
        if (id < 1 or id > s.refs.items.len) return error.BadReference;
        const ref = s.refs.items[@intCast(id - 1)];
        const filter = getStr(o, "filter");
        const start: usize = @intCast(@max(0, getInt(o, "start") orelse 0));
        const count: usize = @intCast(@max(0, getInt(o, "count") orelse 0));
        const l = s.main.?;
        // The current thread may be a coroutine. Inspection runs on it.
        const cur = if (s.frames.items.len > 0) s.frames.items[0].th else l;

        var list: std.ArrayList(Var) = .empty;
        switch (ref) {
            .locals => |r| try collectLocals(a, &list, r),
            .upvalues => |r| try collectUpvalues(a, &list, r.frame().closure.?),
            .value => |vr| {
                const v = table.getInt(s.anchor.?, vr.slot);
                try collectChildren(cur, a, &list, v, vr.eval, filter, start, count);
            },
        }

        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.key("variables");
        try j.beginArray();
        for (list.items) |v| try s.writeVariable(cur, &j, v);
        try j.endArray();
        try j.endObject();
        try s.finishResponse(&j);
    }

    fn writeVariable(s: *Session, l: *Thread, j: *Json, v: Var) !void {
        const a = s.arena();
        var buf: std.ArrayList(u8) = .empty;
        try describe(l, a, &buf, v.value, true, 0);
        if (buf.items.len > max_value_len) {
            var cut: usize = max_value_len;
            while (cut > 0 and buf.items[cut] & 0xC0 == 0x80) cut -= 1;
            buf.items.len = cut;
            try buf.appendSlice(a, "...");
        }
        const eval = if (v.eval) |e| try a.dupe(u8, e) else null;
        try j.beginObject();
        try j.fieldString("name", v.name);
        try j.fieldString("value", buf.items);
        try j.fieldString("type", l.typeNameOf(v.value));
        try j.fieldInt("variablesReference", try s.valueRef(l, v.value, eval));
        if (eval) |e| try j.fieldString("evaluateName", e);
        if (v.value.tag == .table) {
            const n = table.length(v.value.as(Table));
            if (n > page_threshold) try j.fieldInt("indexedVariables", n);
        }
        try j.endObject();
    }

    fn evaluateRequest(s: *Session, l: ?*Thread, req: Request, a: Allocator) !void {
        if (!s.paused) return error.NotStopped;
        const th = l.?;
        const o = req.args orelse return error.MissingArguments;
        const expr = getStr(o, "expression") orelse return error.MissingArguments;
        const context = getStr(o, "context") orelse "repl";
        const fref: ?FrameRef = if (getInt(o, "frameId")) |id| try s.frameAt(id) else if (s.frames.items.len > 0) s.frames.items[0] else null;
        const repl = std.mem.eql(u8, context, "repl");
        const r = s.evaluate(th, if (fref) |f| (if (f.label) null else f) else null, expr, a, repl, true);
        if (r.err) |m| return s.fail(req, m);
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < r.n) : (i += 1) {
            if (i > 0) try buf.appendSlice(a, ", ");
            try describe(th, a, &buf, r.values[i], true, 0);
        }
        if (r.n == 0) try buf.appendSlice(a, if (repl) "" else "nil");
        const first = if (r.n > 0) r.values[0] else Value.nil;
        var ref: i64 = 0;
        if (r.n > 0 and expandable(th, first)) {
            const eval = try s.arena().dupe(u8, expr);
            ref = try s.newRef(.{ .value = .{ .slot = r.slot, .eval = eval } });
        }
        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.fieldString("result", buf.items);
        try j.fieldString("type", th.typeNameOf(first));
        try j.fieldInt("variablesReference", ref);
        try j.endObject();
        try s.finishResponse(&j);
    }

    fn sourceRequest(s: *Session, req: Request, a: Allocator) !void {
        const o = req.args orelse return error.MissingArguments;
        const src = getObj(o, "source") orelse return s.fail(req, "source not available");
        const path = getStr(src, "path") orelse return s.fail(req, "source not available");
        const text = std.Io.Dir.cwd().readFileAlloc(s.init.io, path, a, .unlimited) catch return s.fail(req, "cannot read the source");
        var j = try s.beginResponse(req);
        defer j.deinit();
        try j.key("body");
        try j.beginObject();
        try j.fieldString("content", text);
        try j.endObject();
        try s.finishResponse(&j);
    }

    // -----------------------------------------------------------------
    // Expressions

    const Eval = struct {
        err: ?[]const u8 = null,
        values: [8]Value = undefined,
        n: usize = 0,
        /// Anchor slot of the first value, when asked for.
        slot: i64 = 0,
    };

    /// Evaluates `expr` in the environment of frame `fref` on thread `l`.
    /// Locals and upvalues of the frame read as names, other names read
    /// from the frame's `_ENV`, and every assignment to a name fails.
    /// With `stmt_ok`, text that is not an expression runs as statements.
    fn evaluate(s: *Session, l: *Thread, fref: ?FrameRef, expr: []const u8, a: Allocator, stmt_ok: bool, anchor_first: bool) Eval {
        var r: Eval = .{};
        const saved_top = l.top;
        const saved_err = l.err;
        const saved_tb = l.err_traceback;
        const saved_want = l.want_traceback;
        const saved_hook = l.allow_hook;
        l.want_traceback = false;
        l.allow_hook = false;
        defer {
            l.top = saved_top;
            l.err = saved_err;
            l.err_traceback = saved_tb;
            l.want_traceback = saved_want;
            l.allow_hook = saved_hook;
        }
        protectTop(l);
        const base = l.top;
        buildEnv(l, fref) catch return evalFail(&r, a, "cannot build the evaluation environment");
        const env = l.stack[base];
        const src = std.fmt.allocPrint(a, "return {s}", .{expr}) catch return evalFail(&r, a, "out of memory");
        api.load(l, src, "=(debug)") catch {
            l.top = base + 1;
            if (!stmt_ok) return evalFail(&r, a, api.errorMessage(l, l.err));
            api.load(l, expr, "=(debug)") catch return evalFail(&r, a, api.errorMessage(l, l.err));
        };
        const func = l.top - 1;
        const cl = l.stack[func].as(Closure);
        if (cl.nupvals > 0) {
            const up = cl.upvals()[0];
            up.closed = env;
            gc.barrierBack(l.g, &up.hdr);
        }
        // The frame's extra arguments are the expression's `...`.
        var nargs: u32 = 0;
        if (fref) |f| {
            const fr = f.frame();
            if (fr.closure != null and fr.nvarargs > 0) {
                l.ensure(fr.nvarargs) catch return evalFail(&r, a, "stack overflow");
                var k: u32 = 0;
                while (k < fr.nvarargs) : (k += 1) {
                    l.stack[l.top] = f.th.stack[fr.func - fr.nvarargs + k];
                    l.top += 1;
                }
                nargs = fr.nvarargs;
            }
        }
        if (!api.pcall(l, nargs, -1)) return evalFail(&r, a, api.errorMessage(l, l.stack[func]));
        r.n = @min(l.top - func, r.values.len);
        for (r.values[0..r.n], 0..) |*v, k| v.* = l.stack[func + k];
        if (anchor_first and r.n > 0 and s.anchor != null) {
            r.slot = s.anchorValue(l, r.values[0]) catch 0;
        }
        return r;
    }
};

fn evalFail(r: *Session.Eval, a: Allocator, msg: []const u8) Session.Eval {
    r.err = a.dupe(u8, msg) catch "out of memory";
    return r.*;
}

const Error = state.Error;

fn onEvent(ctx: *anyopaque, l: *Thread, event: []const u8, line: ?u32) Error!void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    if (line) |n| if (std.mem.eql(u8, event, "line")) return s.onLine(l, n);
}

fn onRaised(ctx: *anyopaque, l: *Thread) void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    s.onError(l);
}

/// Frames of `l` and of every thread that resumed it.
fn depth(l: *Thread) usize {
    var n: usize = 0;
    var t: ?*Thread = l;
    while (t) |th| : (t = th.resumer) n += th.frames.items.len;
    return n;
}

/// Raises the stack top above the registers of the running Lus function,
/// so code run from a hook cannot overwrite them.
fn protectTop(l: *Thread) void {
    if (l.frames.items.len == 0) return;
    const fr = l.frame();
    if (fr.closure) |cl| l.top = @max(l.top, fr.base + cl.proto.max_stack);
}

/// True when a `catch` of a running function covers the error being
/// raised on `l`. A coroutine whose resumer is in `coroutine.resume`
/// counts as caught, because `resume` returns the error.
fn hasHandler(l: *Thread) bool {
    var t: ?*Thread = l;
    while (t) |th| : (t = th.resumer) {
        var i = th.frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = th.frames.items[i];
            const cl = fr.closure orelse continue;
            const pc = if (fr.pc == 0) 0 else fr.pc - 1;
            for (cl.proto.handlers) |h| if (pc >= h.start_pc and pc < h.end_pc) return true;
        }
        if (th.resumer) |r| if (r.frames.items.len > 0) {
            if (r.frame().native) |n| if (n.name) |name| {
                if (std.mem.eql(u8, name.bytes(), "resume")) return true;
            };
        };
    }
    return false;
}

fn hitMatches(cond: []const u8, hits: u32) bool {
    const c = std.mem.trim(u8, cond, " \t");
    const ops_list = [_][]const u8{ ">=", "<=", "==", ">", "<", "%", "=" };
    var op: []const u8 = "==";
    var rest = c;
    for (ops_list) |o| if (std.mem.startsWith(u8, c, o)) {
        op = o;
        rest = c[o.len..];
        break;
    };
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, rest, " \t"), 10) catch return true;
    if (std.mem.eql(u8, op, ">=")) return hits >= n;
    if (std.mem.eql(u8, op, "<=")) return hits <= n;
    if (std.mem.eql(u8, op, ">")) return hits > n;
    if (std.mem.eql(u8, op, "<")) return hits < n;
    if (std.mem.eql(u8, op, "%")) return n != 0 and hits % n == 0;
    return hits == n;
}

/// The `_ENV` a frame reads globals from.
fn frameEnv(l: *Thread, r: FrameRef) Value {
    if (r.frame().closure) |cl| {
        for (cl.proto.upvals, 0..) |u, i| {
            const n = u.name orelse continue;
            if (std.mem.eql(u8, n.bytes(), "_ENV") and i < cl.nupvals) {
                const v = cl.upvals()[i].loc.*;
                if (v.tag == .table) return v;
            }
        }
    }
    return l.g.globals;
}

fn readonlyNewindex(l: *Thread) Error!u32 {
    const k = l.arg(2);
    if (k.tag == .string) return l.raiseFmt("cannot assign to '{s}': expressions in the debugger are read-only", .{k.as(String).bytes()});
    return l.raiseFmt("expressions in the debugger are read-only", .{});
}

/// Pushes the environment table of an evaluation: the frame's upvalues
/// and active locals by name, falling back to the frame's `_ENV`.
fn buildEnv(l: *Thread, fref: ?FrameRef) Error!void {
    // The environment itself stays empty, so every assignment reaches
    // `__newindex`. Reads go to a table of the frame's names, and from
    // there to the frame's `_ENV`.
    const env = try l.newTable(0, 0);
    try l.push(Value.obj(.table, env));
    const mt = try l.newTable(0, 2);
    env.metatable = mt;
    const names = try l.newTable(0, 8);
    try aux.setField(l, mt, "__index", Value.obj(.table, names));
    try aux.setField(l, mt, "__newindex", try aux.native(l, readonlyNewindex, "__newindex"));
    const names_mt = try l.newTable(0, 1);
    names.metatable = names_mt;
    const parent = if (fref) |f| frameEnv(l, f) else l.g.globals;
    try aux.setField(l, names_mt, "__index", parent);
    const f = fref orelse return;
    const fr = f.frame();
    const cl = fr.closure orelse return;
    for (cl.proto.upvals, 0..) |u, i| {
        if (i >= cl.nupvals) break;
        const n = u.name orelse continue;
        if (std.mem.eql(u8, n.bytes(), "_ENV")) continue;
        try ops.rawSet(l, names, Value.obj(.string, n), cl.upvals()[i].loc.*);
    }
    const pc = if (fr.pc == 0) 0 else fr.pc - 1;
    for (cl.proto.locvars) |lv| {
        if (!activeAt(lv, pc) or isInternal(lv.name.bytes())) continue;
        try ops.rawSet(l, names, Value.obj(.string, lv.name), f.th.stack[fr.base + lv.reg]);
    }
}

fn activeAt(lv: object.LocVar, pc: u32) bool {
    return lv.start_pc <= pc and (lv.end_pc == 0 or pc < lv.end_pc);
}

fn isInternal(name: []const u8) bool {
    return name.len == 0 or name[0] == '(';
}

// ---------------------------------------------------------------------
// Variables

const Var = struct {
    name: []const u8,
    value: Value,
    eval: ?[]const u8 = null,
};

fn collectLocals(a: Allocator, list: *std.ArrayList(Var), r: FrameRef) !void {
    const fr = r.frame();
    const cl = fr.closure orelse return;
    const pc = if (fr.pc == 0) 0 else fr.pc - 1;
    for (cl.proto.locvars) |lv| {
        if (!activeAt(lv, pc) or isInternal(lv.name.bytes())) continue;
        const name = lv.name.bytes();
        const v = r.th.stack[fr.base + lv.reg];
        // An inner local hides an outer one with the same name.
        for (list.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.value = v;
                break;
            }
        } else try list.append(a, .{ .name = name, .value = v, .eval = name });
    }
    if (fr.nvarargs > 0) {
        var k: u32 = 0;
        while (k < fr.nvarargs) : (k += 1) {
            const name = try std.fmt.allocPrint(a, "...[{d}]", .{k + 1});
            try list.append(a, .{ .name = name, .value = r.th.stack[fr.func - fr.nvarargs + k] });
        }
    }
}

fn collectUpvalues(a: Allocator, list: *std.ArrayList(Var), cl: *Closure) !void {
    for (cl.proto.upvals, 0..) |u, i| {
        if (i >= cl.nupvals) break;
        const name = if (u.name) |n| n.bytes() else "?";
        if (std.mem.eql(u8, name, "_ENV")) continue;
        try list.append(a, .{ .name = name, .value = cl.upvals()[i].loc.*, .eval = name });
    }
}

fn collectChildren(l: *Thread, a: Allocator, list: *std.ArrayList(Var), v: Value, eval: ?[]const u8, filter: ?[]const u8, start: usize, count: usize) !void {
    switch (v.tag) {
        .table => {
            const t = v.as(Table);
            const alen: i64 = table.length(t);
            const paged = alen > page_threshold;
            const want_indexed = filter == null or std.mem.eql(u8, filter.?, "indexed");
            const want_named = filter == null or std.mem.eql(u8, filter.?, "named");
            if (want_indexed and (paged or filter != null)) {
                const first: i64 = @intCast(start + 1);
                const last: i64 = if (count == 0) alen else @min(alen, first + @as(i64, @intCast(count)) - 1);
                var i = first;
                while (i <= last) : (i += 1) try appendEntry(l, a, list, Value.int(i), table.getInt(t, i), eval);
            }
            if (want_named or (!paged and filter == null)) {
                var key: Value = .nil;
                while (table.next(t, key) catch null) |e| : (key = e.key) {
                    // Paged array entries are listed by index above.
                    if ((paged or filter != null) and e.key.tag == .integer and e.key.asInt() >= 1 and e.key.asInt() <= alen) continue;
                    try appendEntry(l, a, list, e.key, e.val, eval);
                }
            }
            if (want_named) if (t.metatable) |mt| try list.append(a, .{ .name = "[metatable]", .value = Value.obj(.table, mt) });
        },
        .closure => try collectUpvalues(a, list, v.as(Closure)),
        else => if (l.metatable(v)) |mt| try list.append(a, .{ .name = "[metatable]", .value = Value.obj(.table, mt) }),
    }
}

fn appendEntry(l: *Thread, a: Allocator, list: *std.ArrayList(Var), k: Value, v: Value, eval: ?[]const u8) !void {
    var name: std.ArrayList(u8) = .empty;
    var child_eval: ?[]const u8 = null;
    if (k.tag == .string and isIdentifier(k.as(String).bytes())) {
        try name.appendSlice(a, k.as(String).bytes());
        if (eval) |e| child_eval = try std.fmt.allocPrint(a, "{s}.{s}", .{ e, name.items });
    } else {
        try name.append(a, '[');
        try describe(l, a, &name, k, true, 1);
        try name.append(a, ']');
        if (eval) |e| if (k.tag == .string or k.tag == .integer) {
            child_eval = try std.fmt.allocPrint(a, "{s}{s}", .{ e, name.items });
        };
    }
    try list.append(a, .{ .name = name.items, .value = v, .eval = child_eval });
}

fn isIdentifier(b: []const u8) bool {
    if (b.len == 0 or std.ascii.isDigit(b[0])) return false;
    for (b) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn expandable(l: *Thread, v: Value) bool {
    return switch (v.tag) {
        .table => true,
        .closure => v.as(Closure).nupvals > 0,
        .nil, .true, .false, .integer, .float, .string => false,
        else => l.metatable(v) != null,
    };
}

/// Appends a short description of `v` without running any Lus code.
/// Tables show their first entries, down to `max_depth` levels.
fn describe(l: *Thread, a: Allocator, buf: *std.ArrayList(u8), v: Value, quote: bool, level: u32) Allocator.Error!void {
    switch (v.tag) {
        .string => {
            const b = v.as(String).bytes();
            if (!quote) return buf.appendSlice(a, b);
            try buf.append(a, '"');
            for (b) |c| switch (c) {
                '"' => try buf.appendSlice(a, "\\\""),
                '\\' => try buf.appendSlice(a, "\\\\"),
                '\n' => try buf.appendSlice(a, "\\n"),
                '\r' => try buf.appendSlice(a, "\\r"),
                '\t' => try buf.appendSlice(a, "\\t"),
                0...8, 11, 12, 14...0x1f, 0x7f => try buf.print(a, "\\{d}", .{c}),
                else => try buf.append(a, c),
            };
            try buf.append(a, '"');
        },
        .table => {
            const t = v.as(Table);
            if (t.metatable) |mt| {
                const n = table.getStr(mt, l.g.tm_names[@backingInt(state.TM.name)].?);
                if (n.tag == .string) try buf.print(a, "{s} ", .{n.as(String).bytes()});
            }
            if (level >= 1) return buf.appendSlice(a, "{...}");
            try buf.append(a, '{');
            const alen = table.length(t);
            var shown: usize = 0;
            var key: Value = .nil;
            while (table.next(t, key) catch null) |e| : (key = e.key) {
                if (shown == 5) {
                    try buf.appendSlice(a, ", ...");
                    break;
                }
                if (shown > 0) try buf.appendSlice(a, ", ");
                const in_array = e.key.tag == .integer and e.key.asInt() >= 1 and e.key.asInt() <= alen;
                if (!in_array) {
                    if (e.key.tag == .string and isIdentifier(e.key.as(String).bytes())) {
                        try buf.appendSlice(a, e.key.as(String).bytes());
                    } else {
                        try buf.append(a, '[');
                        try describe(l, a, buf, e.key, true, level + 1);
                        try buf.append(a, ']');
                    }
                    try buf.appendSlice(a, " = ");
                }
                try describe(l, a, buf, e.val, true, level + 1);
                shown += 1;
            }
            try buf.append(a, '}');
        },
        .closure => {
            const p = v.as(Closure).proto;
            if (p.line_defined == 0) {
                try buf.print(a, "function <{s}> (main chunk)", .{state.shortSource(p)});
            } else {
                try buf.print(a, "function <{s}:{d}>", .{ state.shortSource(p), p.line_defined });
            }
        },
        .native => {
            const n = v.as(state.Native);
            if (n.name) |name| try buf.print(a, "native function '{s}'", .{name.bytes()}) else try buf.appendSlice(a, "native function");
        },
        .thread => {
            const th = v.as(Thread);
            try buf.print(a, "thread ({s})", .{@tagName(th.status)});
        },
        else => {
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(l.g.gpa);
            ops.rawToBuf(l, &tmp, v) catch return error.OutOfMemory;
            try buf.appendSlice(a, tmp.items);
        },
    }
}

fn frameName(r: FrameRef, buf: *[256]u8) []const u8 {
    const fr = r.frame();
    if (vmdebug.calleeName(r.th, r.fi, buf)) |n| return n.name;
    if (fr.closure) |cl| {
        if (cl.proto.line_defined == 0) return "main chunk";
        return std.fmt.bufPrint(buf, "function <{s}:{d}>", .{ state.shortSource(cl.proto), cl.proto.line_defined }) catch "?";
    }
    if (vmdebug.globalName(r.th, r.th.stack[fr.func], buf)) |g| return g;
    if (fr.native) |n| if (n.name) |name| return name.bytes();
    return "?";
}

// ---------------------------------------------------------------------
// Program setup, shared in spirit with `lus run`

fn setArgTable(l: *Thread, argv: []const []const u8) !void {
    const t = try l.newTable(argv.len, 2);
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    for (argv, 0..) |a, i| {
        const v = try l.newStringValue(a);
        try ops.rawSet(l, t, Value.int(@as(i64, @intCast(i)) - 1), v);
    }
    try aux.setGlobal(l, "arg", Value.obj(.table, t));
}

fn reportError(l: *Thread) void {
    const msg = api.errorMessage(l, l.err);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.print(l.g.gpa, "lus: {s}\n", .{msg}) catch return;
    if (l.err_traceback) |tb| buf.print(l.g.gpa, "{s}\n", .{tb.bytes()}) catch {};
    out.stderr(l.g, buf.items);
}

// ---------------------------------------------------------------------
// JSON access

fn getStr(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn getBool(o: std.json.ObjectMap, k: []const u8) ?bool {
    const v = o.get(k) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn getObj(o: std.json.ObjectMap, k: []const u8) ?std.json.ObjectMap {
    const v = o.get(k) orelse return null;
    return if (v == .object) v.object else null;
}

fn getArr(o: std.json.ObjectMap, k: []const u8) ?std.json.Array {
    const v = o.get(k) orelse return null;
    return if (v == .array) v.array else null;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const x = s orelse return null;
    return if (std.mem.trim(u8, x, " \t").len == 0) null else x;
}

test "hit conditions" {
    try std.testing.expect(hitMatches("3", 3));
    try std.testing.expect(!hitMatches("3", 2));
    try std.testing.expect(hitMatches(">= 2", 5));
    try std.testing.expect(hitMatches("%2", 4));
    try std.testing.expect(!hitMatches("%2", 3));
}

test "complete utf-8 prefix" {
    try std.testing.expectEqual(@as(usize, 3), completePrefix("abc"));
    try std.testing.expectEqual(@as(usize, 1), completePrefix("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), completePrefix("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), completePrefix("a\xe2\x82"));
}
