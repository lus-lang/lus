//! Coroutines that hand over events. An API that waits for something to
//! happen returns a coroutine, and resuming the coroutine waits for the
//! next event: a signal, a change to a file, or the exit of a process. The
//! coroutine is a plain one whose body calls a native that waits and then
//! yields what the native returned, so the rule for waits through plain
//! coroutines applies (spec/design/coroutines.md): resumed from a
//! detached coroutine, the wait suspends that coroutine, and resumed
//! anywhere else it blocks while the detached coroutines run.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const co_lib = @import("coroutine.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

const source =
    \\local create, yield, resume = ...
    \\local function repeating(wait, h)
    \\    local co = create(function()
    \\        local handle <close> = h
    \\        -- The first resume stops here, so that closing the coroutine
    \\        -- closes the handle even before the program resumed it.
    \\        yield()
    \\        while true do
    \\            yield(wait(handle))
    \\        end
    \\    end)
    \\    resume(co)
    \\    return co
    \\end
    \\local function once(wait, h)
    \\    return create(function()
    \\        return wait(h)
    \\    end)
    \\end
    \\return repeating, once
;

const key = "events.factories";

/// The two factories, compiled once per state and kept in the registry.
fn factories(l: *Thread) Error!*Table {
    const g = l.g;
    if (g.ext.get(key)) |p| return @ptrCast(@alignCast(p));
    const top = l.top;
    defer l.top = top;
    api.load(l, source, "=events") catch return l.raise(l.err);
    const chunk = l.stack[l.top - 1];
    const create = try aux.native(l, co_lib.create, "create");
    try l.push(create);
    const yield = try aux.native(l, co_lib.yield, "yield");
    try l.push(yield);
    const resume_fn = try aux.native(l, co_lib.resumeNative, "resume");
    try l.push(resume_fn);
    const base = l.top;
    _ = try ops.callN(l, chunk, &.{ create, yield, resume_fn }, 2);
    const t = try l.newTable(2, 0);
    try l.push(Value.obj(.table, t));
    try ops.rawSet(l, t, Value.int(1), l.stack[base]);
    try ops.rawSet(l, t, Value.int(2), l.stack[base + 1]);
    try aux.setField(l, g.registry.as(Table), key, Value.obj(.table, t));
    g.ext.put(g.gpa, key, t) catch return l.raiseMem();
    return t;
}

/// Pushes a coroutine that calls the native `wait` with `handle` on every
/// resume and yields its results. Closing the coroutine closes `handle`,
/// which needs a `__close` metamethod.
pub fn repeating(l: *Thread, wait: state.NativeFn, name: []const u8, handle: Value) Error!Value {
    return make(l, 1, wait, name, handle);
}

/// Pushes a coroutine that calls `wait` with `handle` once and ends with
/// its results.
pub fn once(l: *Thread, wait: state.NativeFn, name: []const u8, handle: Value) Error!Value {
    return make(l, 2, wait, name, handle);
}

fn make(l: *Thread, which: i64, wait: state.NativeFn, name: []const u8, handle: Value) Error!Value {
    const t = try factories(l);
    const f = @import("../vm/table.zig").getInt(t, which);
    const w = try aux.native(l, wait, name);
    try l.push(w);
    const r = try ops.call1(l, f, &.{ w, handle });
    r.as(Thread).event = true;
    l.top -= 1;
    try l.push(r);
    return r;
}

// ---------------------------------------------------------------------
// coroutine.sleep

const sched = @import("../vm/sched.zig");
const gc = @import("../vm/gc.zig");
const Userdata = object.Userdata;

/// The state of one sleep: its length, and the time it ends once the first
/// resume started it.
const Sleep = struct { ns: u64, deadline: u64 = 0, forever: bool = false };

/// `coroutine.sleep(seconds)` returns a coroutine whose resume waits until
/// `seconds` have passed and then ends it.
pub fn sleep(l: *Thread) Error!u32 {
    const v = l.arg(1);
    const secs: f64 = switch (v.tag) {
        .integer => @floatFromInt(v.asInt()),
        .float => v.asFloat(),
        else => @import("time.zig").durationSeconds(l, v) orelse return aux.typeError(l, 1, "number or duration"),
    };
    if (std.math.isNan(secs) or secs < 0) return aux.argError(l, 1, "the time must not be negative", .{});
    // An infinite time parks the coroutine until something closes it.
    const forever = std.math.isInf(secs);
    const ns: u64 = if (forever or secs >= 1e10) std.math.maxInt(u64) / 2 else @intFromFloat(secs * 1e9);
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Sleep), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Sleep);
    u.nuser = 0;
    u.metatable = null;
    const st: *Sleep = @ptrCast(@alignCast(u.data()));
    st.* = .{ .ns = ns, .forever = forever };
    const uv = Value.obj(.userdata, u);
    try l.push(uv);
    _ = try once(l, sleepWait, "sleep", uv);
    return 1;
}

/// Raises "closed" in an event coroutine that another coroutine closed
/// while it waited, so the resume that waits for it returns false and
/// "closed".
pub fn checkClosed(l: *Thread) Error!void {
    if (l.event_closed) return l.raise(try l.newStringValue("closed"));
}

fn sleepWait(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.tag != .userdata) return 0;
    // The state of a sleep is a userdata of this size with no metatable.
    if (v.as(Userdata).metatable != null or v.as(Userdata).size != @sizeOf(Sleep)) return 0;
    const st: *Sleep = @ptrCast(@alignCast(v.as(Userdata).data()));
    const g = l.g;
    if (st.forever) {
        while (true) {
            try checkClosed(l);
            try sched.waitPark(l);
        }
    }
    if (st.deadline == 0) st.deadline = sched.now(g) + st.ns;
    while (true) {
        try checkClosed(l);
        const at = sched.now(g);
        if (at >= st.deadline) return 0;
        const left = (st.deadline - at + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        try sched.waitNotifyFor(l, @intCast(@min(left, std.math.maxInt(i32))));
    }
}
