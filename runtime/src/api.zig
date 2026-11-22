//! Embedding interface used by the CLI, the test runner, the WASM entry
//! points, and the C ABI: create a state, load chunks, call functions
//! with protection, and read results.

const std = @import("std");
const dump = @import("compile/dump.zig");
const value = @import("vm/value.zig");
const object = @import("vm/object.zig");
const state = @import("vm/state.zig");
const interp = @import("vm/interp.zig");
const ops = @import("vm/ops.zig");
const gc = @import("vm/gc.zig");
const sched = @import("vm/sched.zig");
const codegen = @import("compile/codegen.zig");
const Value = value.Value;
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;

/// The version of the runtime, as `lus -v` prints it.
pub const version = "Lus " ++ @import("build_options").version;

pub const Options = struct {
    /// Libraries to open. All by default.
    libs: bool = true,
};

pub fn newState(gpa: std.mem.Allocator, io: std.Io) !*Thread {
    const g = try state.create(gpa, io);
    const l = g.main_thread;
    return l;
}

/// Creates a state whose strings hash with `seed`. A worker takes the
/// seed of its creator.
pub fn newStateSeeded(gpa: std.mem.Allocator, io: std.Io, seed: u64) !*Thread {
    const g = try state.createSeeded(gpa, io, seed);
    return g.main_thread;
}

pub fn openLibs(l: *Thread) Error!void {
    // Opening the libraries is bounded startup work that builds many
    // tables before they are reachable, so the collector waits until it
    // is done.
    const g = l.g;
    const was_stopped = g.gc_stopped;
    g.gc_stopped = true;
    defer g.gc_stopped = was_stopped;
    try @import("lib/init.zig").openAll(l);
}

pub fn close(l: *Thread) void {
    const g = l.g;
    // Detached coroutines close first, which runs their pending
    // to-be-closed variables while everything they use is alive.
    closeCoroutines(g);
    // Finalizers run next, while worker handles still reach their domain.
    finalizeAll(g);
    closeRest(g);
}

/// The part of `close` after the finalizers: workers created by this
/// state stop before anything is freed, then output flushes and the
/// state is freed.
fn closeRest(g: *state.Global) void {
    if (@import("build_options").workers) @import("lib/worker.zig").closeState(g);
    // Finalizers may print, so standard output flushes after them.
    @import("lib/out.zig").deinit(g);
    if (g.ext.get("flags.compile")) |p| {
        const map: *std.StringHashMapUnmanaged(Value) = @ptrCast(@alignCast(p));
        map.deinit(g.gpa);
        g.gpa.destroy(map);
    }
    @import("vm/pledge.zig").deinit(g);
    @import("lib/os.zig").deinitEnviron(g);
    state.destroy(g);
}

/// Closes a state just before the process exits. It runs the finalizers,
/// stops the workers, and flushes output as `close` does. Builds without
/// runtime safety then leave the heap to the exit of the process instead
/// of returning it object by object, which reads every live object once
/// more. Safe builds free everything, so their allocators still check
/// the whole teardown.
///
/// Workers stop at their next wait. When one is still running after a
/// short grace, nothing that it may share is freed, and
/// `workers_abandoned` tells the caller to end the process at once,
/// which ends the thread of that worker.
pub fn closeForExit(l: *Thread) void {
    const g = l.g;
    closeCoroutines(g);
    finalizeAll(g);
    if (@import("build_options").workers and !@import("lib/worker.zig").stopForExit(g)) {
        workers_abandoned = true;
        @import("lib/out.zig").deinit(g);
        return;
    }
    if (std.debug.runtime_safety) return closeRest(g);
    if (@import("build_options").workers) @import("lib/worker.zig").closeState(g);
    @import("lib/out.zig").deinit(g);
}

/// Set by `closeForExit` when a worker did not stop in time.
pub var workers_abandoned = false;

/// Compiles `src` and pushes the resulting function. On any error, a
/// syntax error or running out of memory, pushes the error value and
/// returns error.LusError, so callers find the message on the stack top.
pub fn load(l: *Thread, src: []const u8, chunkname: []const u8) Error!void {
    const top = l.top;
    loadRaw(l, src, chunkname) catch |e| {
        l.top = top;
        // The stack keeps spare slots above its top, so this push only
        // fails when the thread has no stack at all.
        l.push(l.err) catch {};
        return e;
    };
}

/// Compiles `src` and pushes the resulting function, or sets `l.err` and
/// returns error.LusError.
fn loadRaw(l: *Thread, src: []const u8, chunkname: []const u8) Error!void {
    const g = l.g;
    if (dump.isBinary(src)) {
        const was_stopped = g.gc_stopped;
        g.gc_stopped = true;
        defer g.gc_stopped = was_stopped;
        const p = dump.undump(g, src, chunkname) catch |e| switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.Malformed => {
                const s = try l.newString("bad binary format (truncated or corrupted chunk)");
                l.err = Value.obj(.string, s);
                return error.LusError;
            },
        };
        const cl = try newMainClosure(l, p, g.globals);
        try l.push(Value.obj(.closure, cl));
        return;
    }
    const r = codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flagsTable(g), .debug = g.debugger != null, .meta_grants = .{ .thread = l } }) catch return l.raiseMem();
    switch (r) {
        .err => |msg| {
            defer g.gpa.free(msg);
            const s = try l.newString(msg);
            l.err = Value.obj(.string, s);
            return error.LusError;
        },
        .ok => |p| {
            const cl = try newMainClosure(l, p, g.globals);
            try l.push(Value.obj(.closure, cl));
        },
    }
}

/// The compile-time flags set by `setFlags`, as the compiler reads them.
pub fn flagsTable(g: *Global) ?*const std.StringHashMapUnmanaged(Value) {
    const p = g.ext.get("flags.compile") orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Creates a closure for a main chunk prototype with `env` as `_ENV`.
pub fn newMainClosure(l: *Thread, p: *object.Proto, env: Value) Error!*object.Closure {
    const g = l.g;
    const n = p.upvals.len;
    const cl = gc.alloc(g, object.Closure, .closure, object.Closure.allocSize(n)) catch return l.raiseMem();
    cl.proto = p;
    cl.nupvals = @intCast(n);
    for (cl.upvals()) |*u| {
        const up = gc.alloc(g, object.Upvalue, .upvalue, @sizeOf(object.Upvalue)) catch return l.raiseMem();
        up.* = .{ .hdr = up.hdr, .loc = undefined, .closed = .nil, .open = false };
        up.loc = &up.closed;
        u.* = up;
    }
    if (n > 0) cl.upvals()[0].closed = env;
    return cl;
}

/// Calls the function at `top - nargs - 1` with protection. On success,
/// leaves `want` results (or all, with -1) where the function was and
/// returns true. On error, leaves the error value there and returns false.
pub fn pcall(l: *Thread, nargs: u32, want: i32) bool {
    const func = l.top - nargs - 1;
    const depth = l.frames.items.len;
    const tbc_len = l.tbc.items.len;
    const ncalls = l.ncalls;
    _ = interp.call(l, func, nargs, want) catch {
        interp.unwindTo(l, depth);
        l.tbc.items.len = @min(l.tbc.items.len, tbc_len);
        l.ncalls = ncalls;
        // An error that stops the program ends at the outermost call.
        if (l.g.native_depth == 0) l.g.sched.fatal = false;
        l.stack[func] = l.err;
        l.top = func + 1;
        return false;
    };
    return true;
}

/// Runs the detached coroutines of the state. With `wait` set it runs
/// them until none is left, as `lus` does after the main chunk, and then
/// reports the error of a coroutine that failed with nothing left to
/// collect it. Without it, it runs the coroutines that are ready and
/// returns. On error it returns false with the error value in `l.err`
/// and, for the error of a coroutine, its traceback in
/// `l.err_traceback`.
pub fn runPending(l: *Thread, wait: bool) bool {
    const r = if (wait) sched.drain(l) else sched.poll(l);
    r catch {
        if (l.g.native_depth == 0) l.g.sched.fatal = false;
        return false;
    };
    return true;
}

/// Closes the detached coroutines that have not ended, running their
/// pending to-be-closed variables, and keeps the scheduler for later
/// ones.
pub fn closePending(l: *Thread) void {
    sched.closeLive(l.g);
}

/// The number of detached coroutines that have not ended.
pub fn pendingCoroutines(l: *Thread) usize {
    return sched.pending(l.g);
}

/// Closes every detached coroutine that has not ended, from the main
/// thread with nothing else running.
fn closeCoroutines(g: *state.Global) void {
    const main = g.main_thread;
    main.top = 0;
    main.frames.items.len = 0;
    main.tbc.items.len = 0;
    sched.closeAll(g);
}

/// Converts the error value at the top of the stack into a message.
pub fn errorMessage(l: *Thread, v: Value) []const u8 {
    if (v.tag == .string) return v.as(object.String).bytes();
    if (v.isNil()) return "<no error object>";
    const s = ops.toString(l, v) catch return "(error object is not a string)";
    return s.bytes();
}

/// Runs `src` as a chunk with `args` as its varargs. Returns null on
/// success, or the error message (owned by the GC until the next
/// collection; copy it if needed).
pub fn doString(l: *Thread, src: []const u8, chunkname: []const u8) ?[]const u8 {
    const base = l.top;
    load(l, src, chunkname) catch {
        const msg = errorMessage(l, l.stack[l.top - 1]);
        l.top = base;
        return msg;
    };
    if (!pcall(l, 0, 0)) {
        const msg = errorMessage(l, l.stack[l.top - 1]);
        l.top = base;
        return msg;
    }
    l.top = base;
    return null;
}

/// Defines compile-time flags (`-F name[=value]`). A flag without a value
/// is true, a numeral becomes a number, anything else a string. The flags
/// are visible to compile-time folding and as the read-only global
/// `flags`, which exists even when no flag is given.
pub fn setFlags(l: *Thread, specs: []const []const u8) !void {
    const g = l.g;
    const map = try g.gpa.create(std.StringHashMapUnmanaged(Value));
    map.* = .empty;
    // Until the state's extension table holds the map, it is ours to free.
    var owned = true;
    errdefer if (owned) {
        map.deinit(g.gpa);
        g.gpa.destroy(map);
    };
    for (specs) |spec| {
        var name = spec;
        var v: Value = .true;
        if (std.mem.indexOfScalar(u8, spec, '=')) |eq| {
            name = spec[0..eq];
            const raw = spec[eq + 1 ..];
            if (@import("syntax/lexer.zig").parseNumber(raw)) |n| {
                v = switch (n) {
                    .integer => |i| Value.int(i),
                    .float => |f| Value.float(f),
                };
            } else {
                v = Value.obj(.string, try l.newString(raw));
                try g.fixed.append(g.gpa, v.header());
            }
        }
        try map.put(g.gpa, name, v);
    }
    try g.ext.put(g.gpa, "flags.compile", map);
    owned = false;
    // The runtime view is a read-only table holding every flag.
    const data = try l.newTable(0, map.count());
    try l.push(Value.obj(.table, data));
    defer l.top -= 1;
    var it = map.iterator();
    while (it.next()) |e| try ops.rawSet(l, data, try l.newStringValue(e.key_ptr.*), e.value_ptr.*);
    data.setReadonly(true);
    try @import("lib/auxlib.zig").setGlobal(l, "flags", Value.obj(.table, data));
}

/// Grants the command line permissions (`-P`). Pledge arrives with the
/// capability registry; until then grants are accepted and recorded.
pub fn grantPledges(l: *Thread, specs: []const []const u8) Error!void {
    try @import("vm/pledge.zig").hostGrant(l, specs);
}

/// Makes the global table, and every library table up to two levels below
/// it, read-only (`--readonly-env`). The module cache stays writable so
/// `require` keeps working. Workers started from this state afterward
/// freeze their environment as well.
pub fn freezeEnv(l: *Thread) void {
    const table = @import("vm/table.zig");
    const g = l.g;
    g.env_frozen = true;
    const reg = g.registry.as(object.Table);
    const loaded_key = state.newStringKnown(g, "_LOADED", true, 7) catch return;
    const loaded = table.getStr(reg, loaded_key);
    const skip: ?*object.Table = if (loaded.tag == .table) loaded.as(object.Table) else null;
    freezeTable(g.globals.as(object.Table), skip, 2);
}

fn freezeTable(t: *object.Table, skip: ?*object.Table, depth: u32) void {
    const table = @import("vm/table.zig");
    if (t == skip) return;
    t.setReadonly(true);
    if (depth == 0) return;
    var key: Value = .nil;
    while (table.next(t, key) catch null) |e| : (key = e.key) {
        if (e.val.tag == .table and !e.val.as(object.Table).isReadonly()) freezeTable(e.val.as(object.Table), skip, depth - 1);
    }
}

/// Runs the finalizer of every object that still has one, as a closing
/// state does, so resources held by tables and userdata are released. The
/// most recently registered object is finalized first.
fn finalizeAll(g: *state.Global) void {
    const main = g.main_thread;
    main.top = 0;
    main.frames.items.len = 0;
    main.tbc.items.len = 0;
    for (g.finobj.items) |hdr| g.tobefnz.append(g.gpa, hdr) catch break;
    g.finobj.items.len = 0;
    g.gc_stopped = true;
    @import("lib/base.zig").runFinalizers(main) catch {};
}
