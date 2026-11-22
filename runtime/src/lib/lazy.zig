//! The natives behind `<lazy>` locals (`spec/design/lazy.md`). The
//! compiler turns a lazy local into hidden locals and a force function
//! (`compile/codegen.zig`, `lazyLocal`), which calls these natives. They
//! reach compiled code as builtin constants, which binary chunks store by
//! number, so they never depend on the global environment.

const std = @import("std");
const state = @import("../vm/state.zig");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const sched = @import("../vm/sched.zig");
const ops = @import("../vm/ops.zig");
const table = @import("../vm/table.zig");
const Thread = state.Thread;
const Global = state.Global;
const Value = value.Value;
const Error = state.Error;

/// The builtins in the order of their numbers, which binary chunks use.
pub const natives = [_]state.NativeFn{ lazyWait, running, rethrow, closer, closeValue };
pub const names = [_][]const u8{ "lazywait", "running", "rethrow", "closer", "closevalue" };

/// The name a compiled force function uses for builtin number `i`.
pub const prefix = "__lus_builtin_";

/// The number of the builtin named `name` (without the prefix), or null.
pub fn number(name: []const u8) ?u8 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return null;
}

/// The number of the builtin `f`, or null when it is none.
pub fn numberOf(f: state.NativeFn) ?u8 {
    for (natives, 0..) |n, i| if (n == f) return @intCast(i);
    return null;
}

/// The native object of builtin number `i` in `g`, created once and kept
/// for the life of the state.
pub fn get(g: *Global, i: u8) std.mem.Allocator.Error!Value {
    const keys = [_][]const u8{ "lazy.builtin.0", "lazy.builtin.1", "lazy.builtin.2", "lazy.builtin.3", "lazy.builtin.4" };
    const key = keys[i];
    if (g.ext.get(key)) |p| return Value.obj(.native, @as(*state.Native, @ptrCast(@alignCast(p))));
    const n = try state.newNative(g, natives[i], names[i], 0);
    try g.fixed.append(g.gpa, &n.hdr);
    try g.ext.put(g.gpa, key, n);
    return Value.obj(.native, n);
}

/// `lazywait(evaluator, name)`: called when a lazy variable is read while
/// the thread `evaluator` computes it. The thread that computes it raises
/// an error, since its initializer reads itself. A detached coroutine lets
/// the other coroutines run, and the force function checks the variable
/// again. Any other thread raises an error, since it cannot wait.
fn lazyWait(l: *Thread) Error!u32 {
    const who = l.arg(1);
    const name = if (l.arg(2).tag == .string) l.arg(2).as(object.String).bytes() else "?";
    const self_eval = who.tag == .thread and who.as(Thread) == l;
    if (!self_eval and sched.canSuspend(l)) {
        if (sched.restarted(l)) return 0;
        try sched.pass(l);
        return 0;
    }
    if (self_eval) return l.raiseFmt("lazy variable '{s}' read during its own initialization", .{name});
    return l.raiseFmt("lazy variable '{s}' read while another coroutine computes it", .{name});
}

/// `running()`: the running thread, which marks the variable as being
/// computed by it.
fn running(l: *Thread) Error!u32 {
    try l.push(Value.obj(.thread, l));
    return 1;
}

/// `rethrow(err)`: raises the error object of a failed initializer again,
/// unchanged.
fn rethrow(l: *Thread) Error!u32 {
    return l.raise(l.arg(1));
}

/// `closer(fn)`: a to-be-closed guard whose closing calls `fn` with the
/// error. A `<lazy, close>` local closes its value through one, since the
/// value exists only after the first read.
fn closer(l: *Thread) Error!u32 {
    const g = l.g;
    const mt: *object.Table = if (g.ext.get("lazy.closer.mt")) |p| @ptrCast(@alignCast(p)) else blk: {
        const t = try l.newTable(0, 1);
        try l.push(Value.obj(.table, t));
        const n = state.newNative(g, closeGuard, "close", 0) catch return l.raiseMem();
        try ops.rawSet(l, t, try l.newStringValue("__close"), Value.obj(.native, n));
        g.fixed.append(g.gpa, &t.hdr) catch return l.raiseMem();
        g.ext.put(g.gpa, "lazy.closer.mt", t) catch return l.raiseMem();
        l.top -= 1;
        break :blk t;
    };
    const guard = try l.newTable(1, 0);
    try l.push(Value.obj(.table, guard));
    try ops.rawSet(l, guard, Value.int(1), l.arg(1));
    guard.metatable = mt;
    return 1;
}

fn closeGuard(l: *Thread) Error!u32 {
    const guard = l.arg(1);
    if (guard.tag != .table) return 0;
    const f = table.getInt(guard.as(object.Table), 1);
    _ = try ops.callN(l, f, &.{l.arg(2)}, 0);
    return 0;
}

/// `closevalue(v, err, name)`: closes the computed value of a
/// `<lazy, close>` local as the end of its scope closes any `<close>`
/// local.
fn closeValue(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (!v.truthy()) return 0;
    const tm = l.metamethod(v, .close);
    if (tm.isNil()) {
        const name = if (l.arg(3).tag == .string) l.arg(3).as(object.String).bytes() else "?";
        return l.raiseFmt("variable '{s}' got a non-closable value", .{name});
    }
    _ = try ops.callN(l, tm, &.{ v, l.arg(2) }, 0);
    return 0;
}
