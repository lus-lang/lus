//! Embedding interface used by the CLI, the test runner, the WASM entry
//! points, and the C ABI: create a state, load chunks, call functions
//! with protection, and read results.

const std = @import("std");
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
    try @import("lib/init.zig").openAll(l);
}

pub fn close(l: *Thread) void {
    state.destroy(l.g);
}

/// Compiles `src` and pushes the resulting function. On a syntax error,
/// pushes the message string and returns error.LusError.
pub fn load(l: *Thread, src: []const u8, chunkname: []const u8) Error!void {
    const g = l.g;
    const r = codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flagsTable(g) }) catch return l.raiseMem();
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
