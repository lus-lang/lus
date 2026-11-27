//! The builtins behind `<lazy>` and `<observe>` locals
//! (`spec/design/lazy.md`, `spec/design/observe.md`). The compiler turns
//! such locals into hidden locals and generated functions
//! (`compile/codegen.zig`, `lazyLocal` and `observeLocal`), which call
//! these builtins. They reach compiled code as builtin constants, which
//! binary chunks store by number, so they never depend on the global
//! environment. Every builtin is a native except the update of observed
//! variables, a function written in Lus so that initializers may yield.

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
pub const natives = [_]state.NativeFn{ lazyWait, running, rethrow, closer, closeValue, obsCheck, obsBegin, obsEnd, obsRegister, obsUnregister, @import("context.zig").ctxNew };
pub const names = [_][]const u8{ "lazywait", "running", "rethrow", "closer", "closevalue", "obscheck", "obsbegin", "obsend", "obsregister", "obsunregister", "ctxnew", "obsrun" };

/// The name of the prototype of `obsrun`, by which binary chunks know it.
pub const run_proto_name = "observe update";

/// The update of observed variables (`spec/design/observe.md`, section 3):
/// collects the records of the dependents of a list, transitively, sorts
/// them by their numbers, then calls each update function once. A guard
/// ends the update however it ends.
const run_source =
    \\local list = ...
    \\local seen, recs, stack, top = {}, {}, { list }, 1
    \\while top > 0 do
    \\    local l = stack[top]
    \\    stack[top] = nil
    \\    top = top - 1
    \\    for i = 1, #l do
    \\        local r = l[i]
    \\        if not seen[r] then
    \\            seen[r] = true
    \\            recs[#recs + 1] = r
    \\            top = top + 1
    \\            stack[top] = r[3]
    \\        end
    \\    end
    \\end
    \\for i = 2, #recs do
    \\    local r = recs[i]
    \\    local j = i - 1
    \\    while j >= 1 and recs[j][2] > r[2] do
    \\        recs[j + 1] = recs[j]
    \\        j = j - 1
    \\    end
    \\    recs[j + 1] = r
    \\end
    \\__lus_builtin_obsbegin()
    \\local guard <close> = __lus_builtin_closer(__lus_builtin_obsend)
    \\for i = 1, #recs do
    \\    recs[i][1]()
    \\end
;

/// The name that code the compiler generates uses for a builtin. No
/// identifier of a program starts with it, so only the compiler names a
/// builtin.
pub const prefix = "\x01builtin.";
/// The name of a builtin in the source of the update of observed
/// variables, which the runtime compiles itself.
pub const text_prefix = "__lus_builtin_";

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
    const keys = comptime blk: {
        var k: [names.len][]const u8 = undefined;
        for (&k, 0..) |*x, j| x.* = std.fmt.comptimePrint("builtin.{d}", .{j});
        break :blk k;
    };
    const key = keys[i];
    if (i == natives.len) {
        if (g.ext.get(key)) |p| return Value.obj(.closure, @as(*object.Closure, @ptrCast(@alignCast(p))));
        const cl = try runClosure(g);
        try g.fixed.append(g.gpa, &cl.hdr);
        try g.ext.put(g.gpa, key, cl);
        return Value.obj(.closure, cl);
    }
    if (g.ext.get(key)) |p| return Value.obj(.native, @as(*state.Native, @ptrCast(@alignCast(p))));
    const n = try state.newNative(g, natives[i], names[i], 0);
    try g.fixed.append(g.gpa, &n.hdr);
    try g.ext.put(g.gpa, key, n);
    return Value.obj(.native, n);
}

/// The name of the bundled module that holds the update of observed
/// variables as a binary chunk, which `lus build` adds for a runtime
/// without the compiler.
pub const bundle_module = ".observe";

/// Compiles the update of observed variables in `g`.
pub fn compileUpdate(g: *Global) std.mem.Allocator.Error!*object.Proto {
    if (comptime !@import("build_options").compiler) unreachable;
    const codegen = @import("../compile/codegen.zig");
    const r = try codegen.compile(g, run_source, .{ .chunkname = "=observe", .meta_eval = false, .builtin_names = true });
    const p = switch (r) {
        .ok => |p| p,
        .err => |msg| std.debug.panic("the observe update does not compile: {s}", .{msg}),
    };
    p.name = state.newStringIn(g, run_proto_name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => unreachable,
    };
    return p;
}

/// The update of observed variables: compiled, or read from the chunk
/// that the bundle carries in a runtime without the compiler.
fn updateProto(g: *Global) std.mem.Allocator.Error!*object.Proto {
    if (comptime @import("build_options").compiler) return compileUpdate(g);
    const b = @import("package.zig").bundle orelse @panic("observed variables need the compiler, which this executable leaves out");
    const m = b.find(bundle_module) orelse @panic("observed variables need the compiler, which this executable leaves out");
    return @import("../compile/dump.zig").undump(g, m.data, "=observe") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => @panic("the bundled update of observed variables is malformed"),
    };
}

/// Makes the closure of the update of observed variables in `g`, whose
/// environment is empty because it names builtins only.
fn runClosure(g: *Global) std.mem.Allocator.Error!*object.Closure {
    const gc = @import("../vm/gc.zig");
    // Nothing roots the function until the closure holds it.
    const was = g.gc_stopped;
    g.gc_stopped = true;
    defer g.gc_stopped = was;
    const p = try updateProto(g);
    const n = p.upvals.len;
    const cl = try gc.alloc(g, object.Closure, .closure, object.Closure.allocSize(n));
    cl.proto = p;
    cl.nupvals = @intCast(n);
    for (cl.upvals()) |*u| {
        const up = try gc.alloc(g, object.Upvalue, .upvalue, @sizeOf(object.Upvalue));
        up.* = .{ .hdr = up.hdr, .loc = undefined, .closed = .nil, .open = false };
        up.loc = &up.closed;
        u.* = up;
    }
    return cl;
}

/// The state of observed variables in `g`: whether an update runs, and
/// the counter that numbers derived variables in declaration order.
fn observeState(l: *Thread) Error!*object.Table {
    const g = l.g;
    if (g.ext.get("observe.state")) |p| return @ptrCast(@alignCast(p));
    const t = try l.newTable(2, 0);
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    try ops.rawSet(l, t, Value.int(1), .false);
    try ops.rawSet(l, t, Value.int(2), Value.int(0));
    g.fixed.append(g.gpa, &t.hdr) catch return l.raiseMem();
    g.ext.put(g.gpa, "observe.state", t) catch return l.raiseMem();
    return t;
}

/// `obscheck(name)`: raises when an update of observed variables runs,
/// before an assignment to the observed variable `name`.
fn obsCheck(l: *Thread) Error!u32 {
    const st = try observeState(l);
    if (table.getInt(st, 1).truthy()) {
        const name = if (l.arg(1).tag == .string) l.arg(1).as(object.String).bytes() else "?";
        return l.raiseFmt("cannot assign observed variable '{s}' while its dependents update", .{name});
    }
    return 0;
}

fn obsBegin(l: *Thread) Error!u32 {
    try ops.rawSet(l, try observeState(l), Value.int(1), .true);
    return 0;
}

fn obsEnd(l: *Thread) Error!u32 {
    try ops.rawSet(l, try observeState(l), Value.int(1), .false);
    return 0;
}

/// `obsregister(update, own, deps...)`: the record of a derived variable,
/// `{ update, number, own, deps }`, added to the list of each dependency.
fn obsRegister(l: *Thread) Error!u32 {
    const st = try observeState(l);
    const n = table.getInt(st, 2).asInt() + 1;
    try ops.rawSet(l, st, Value.int(2), Value.int(n));
    const rec = try l.newTable(4, 0);
    try l.push(Value.obj(.table, rec));
    const deps = try l.newTable(l.argCount() -| 2, 0);
    try ops.rawSet(l, rec, Value.int(4), Value.obj(.table, deps));
    try ops.rawSet(l, rec, Value.int(1), l.arg(1));
    try ops.rawSet(l, rec, Value.int(2), Value.int(n));
    try ops.rawSet(l, rec, Value.int(3), l.arg(2));
    var i: u32 = 3;
    while (i <= l.argCount()) : (i += 1) {
        const list = l.arg(i);
        if (list.tag != .table) continue;
        const t = list.as(object.Table);
        try ops.rawSet(l, t, Value.int(table.length(t) + 1), Value.obj(.table, rec));
        try ops.rawSet(l, deps, Value.int(@intCast(i - 2)), list);
    }
    return 1;
}

/// `obsunregister(record)`: removes a record from the lists it was added
/// to, when the scope of its derived variable ends.
fn obsUnregister(l: *Thread) Error!u32 {
    const rv = l.arg(1);
    if (rv.tag != .table) return 0;
    const rec = rv.as(object.Table);
    const deps = table.getInt(rec, 4);
    if (deps.tag != .table) return 0;
    const dl = deps.as(object.Table);
    var k: i64 = 1;
    while (k <= table.length(dl)) : (k += 1) {
        const lv = table.getInt(dl, k);
        if (lv.tag != .table) continue;
        const t = lv.as(object.Table);
        const n = table.length(t);
        var i: i64 = 1;
        while (i <= n) : (i += 1) {
            const e = table.getInt(t, i);
            if (e.tag == .table and e.as(object.Table) == rec) {
                var j = i;
                while (j < n) : (j += 1) try ops.rawSet(l, t, Value.int(j), table.getInt(t, j + 1));
                try ops.rawSet(l, t, Value.int(n), .nil);
                break;
            }
        }
    }
    return 0;
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
        // The key is made first, since making it may collect.
        const key = try l.newStringValue("__close");
        try l.push(key);
        const n = state.newNative(g, closeGuard, "close", 0) catch return l.raiseMem();
        try ops.rawSet(l, t, key, Value.obj(.native, n));
        l.top -= 1;
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
