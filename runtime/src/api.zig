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
const codegen = @import("compile/codegen.zig");
const Value = value.Value;
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;

pub const Options = struct {
    /// Libraries to open. All by default.
    libs: bool = true,
};

pub fn newState(gpa: std.mem.Allocator, io: std.Io) !*Thread {
    const g = try state.create(gpa, io);
    const l = g.main_thread;
    return l;
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
    // Workers created by this state stop before anything is freed.
    if (@import("build_options").workers) @import("lib/worker.zig").closeState(g);
    if (g.ext.get("flags.compile")) |p| {
        const map: *std.StringHashMapUnmanaged(Value) = @ptrCast(@alignCast(p));
        map.deinit(g.gpa);
        g.gpa.destroy(map);
    }
    @import("vm/pledge.zig").deinit(g);
    state.destroy(g);
}

/// Compiles `src` and pushes the resulting function. On a syntax error,
/// pushes the message string and returns error.LusError.
pub fn load(l: *Thread, src: []const u8, chunkname: []const u8) Error!void {
    const g = l.g;
    if (dump.isBinary(src)) {
        const was_stopped = g.gc_stopped;
        g.gc_stopped = true;
        defer g.gc_stopped = was_stopped;
        const p = dump.undump(g, src, chunkname) catch |e| switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.Malformed => {
                const s = try l.newString("bad binary format (truncated or corrupted chunk)");
                try l.push(Value.obj(.string, s));
                l.err = Value.obj(.string, s);
                return error.LusError;
            },
        };
        const cl = try newMainClosure(l, p, g.globals);
        try l.push(Value.obj(.closure, cl));
        return;
    }
    const r = codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flagsTable(g), .debug = g.debugger != null }) catch return l.raiseMem();
    switch (r) {
        .err => |msg| {
            defer g.gpa.free(msg);
            const s = try l.newString(msg);
            try l.push(Value.obj(.string, s));
            l.err = Value.obj(.string, s);
            return error.LusError;
        },
        .ok => |p| {
            const cl = try newMainClosure(l, p, g.globals);
            try l.push(Value.obj(.closure, cl));
        },
    }
}

fn flagsTable(g: *Global) ?*const std.StringHashMapUnmanaged(Value) {
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
        l.stack[func] = l.err;
        l.top = func + 1;
        return false;
    };
    return true;
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
    // The runtime view is a read-only table holding every flag.
    const data = try l.newTable(0, map.count());
    try l.push(Value.obj(.table, data));
    defer l.top -= 1;
    var it = map.iterator();
    while (it.next()) |e| try ops.rawSet(l, data, try l.newStringValue(e.key_ptr.*), e.value_ptr.*);
    data.readonly = true;
    try @import("lib/aux.zig").setGlobal(l, "flags", Value.obj(.table, data));
}

/// Grants the command line permissions (`-P`). Pledge arrives with the
/// capability registry; until then grants are accepted and recorded.
pub fn grantPledges(l: *Thread, specs: []const []const u8) Error!void {
    try @import("vm/pledge.zig").hostGrant(l, specs);
}

/// Makes the global table, and every library table up to two levels below
/// it, read-only (`--readonly-env`). The module cache stays writable so
/// `require` keeps working.
pub fn freezeEnv(l: *Thread) void {
    const table = @import("vm/table.zig");
    const g = l.g;
    const reg = g.registry.as(object.Table);
    const loaded_key = state.newStringKnown(g, "_LOADED", true, 7) catch return;
    const loaded = table.getStr(reg, loaded_key);
    const skip: ?*object.Table = if (loaded.tag == .table) loaded.as(object.Table) else null;
    freezeTable(g.globals.as(object.Table), skip, 2);
}

fn freezeTable(t: *object.Table, skip: ?*object.Table, depth: u32) void {
    const table = @import("vm/table.zig");
    if (t == skip) return;
    t.readonly = true;
    if (depth == 0) return;
    var key: Value = .nil;
    while (table.next(t, key) catch null) |e| : (key = e.key) {
        if (e.val.tag == .table and !e.val.as(object.Table).readonly) freezeTable(e.val.as(object.Table), skip, depth - 1);
    }
}
