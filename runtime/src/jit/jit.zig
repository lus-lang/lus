//! The baseline JIT. It compiles a hot function to native code that runs
//! the same frames, on the same Lus stack, as the interpreter. The design
//! is described in `spec/design/jit.md`.
//!
//! This file holds the parts that are independent of the instruction set:
//! the settings, the hotness policy, the hand-over between the tiers, and
//! the lifetime of the code. `emit.zig` turns bytecode into instructions
//! through the assembler of the target (`a64.zig` or `x64.zig`), and
//! `mem.zig` manages executable memory. On WebAssembly `wasm.zig` turns
//! bytecode into a module that the host instantiates
//! (`spec/design/wasmjit.md`).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const interp = @import("../vm/interp.zig");
const Thread = state.Thread;
const Global = state.Global;
const Proto = object.Proto;
const Error = state.Error;

/// True when this build has a JIT: the option is on and the target has a
/// backend and a way to map executable memory, or on WebAssembly a host
/// that instantiates modules.
pub const enabled = build_options.jit and switch (builtin.cpu.arch) {
    // Windows on arm64 compiles with everything it needs, and its gate
    // opens once CI has a runner for it (spec/design/platforms.md).
    .aarch64 => switch (builtin.os.tag) {
        .macos, .linux, .freebsd => true,
        else => false,
    },
    .x86_64 => switch (builtin.os.tag) {
        .macos, .linux, .windows, .freebsd => true,
        else => false,
    },
    .riscv64, .loongarch64, .powerpc64le, .s390x => builtin.os.tag == .linux,
    .wasm32 => builtin.os.tag == .wasi,
    else => false,
};

/// The calling convention of every routine that native code calls, and of
/// the entry sequence. Native code follows the System V convention on
/// x86-64, which on Windows makes Zig compile these routines, and the
/// calls into native code, with that convention too. The rest of the
/// runtime keeps the convention of the system.
pub const cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)
    .{ .x86_64_sysv = .{} }
else
    .c;

/// Whether the backend emits WebAssembly modules rather than machine code.
pub const is_wasm = builtin.cpu.arch == .wasm32;

/// Whether this build has the optimizing tier, which emits machine code.
pub const has_opt = enabled and !is_wasm;

const mem = @import("mem.zig");
const emit = @import("emit.zig");
const wasm = @import("wasm.zig");
pub const helpers = @import("helpers.zig");
/// The optimizing tier, which compiles what stays hot in baseline code.
pub const opt = @import("opt/opt.zig");

pub const default_threshold = 60;
/// Functions with more instructions than this stay in the interpreter,
/// which keeps every branch of a compiled function within reach.
const max_instructions = 30_000;

pub const Setting = enum { off, on, eager };

pub const State = if (enabled) struct {
    ready: bool = false,
    setting: Setting = .on,
    /// Events (calls, loop iterations, returns) before a function compiles.
    threshold: u32 = default_threshold,
    /// Length of the current sampling period of the interpreter.
    period: u32 = 1,
    seed: u32 = 12345,
    arena: if (is_wasm) void else mem.Arena = if (is_wasm) {} else .{},
    /// Functions that have native code now.
    live: usize = 0,
    /// Functions compiled since the state started.
    compiled: usize = 0,
    /// The optimizing tier: its setting, the events in baseline code
    /// before it compiles, and its counters.
    opt: opt.Setting = if (is_wasm) .off else .on,
    opt_threshold: u32 = opt.default_threshold,
    optimized: usize = 0,
    exits: usize = 0,
    /// Lists the intermediate representation of every compilation.
    opt_dump: bool = false,
    /// Bytes of tables that optimized code did not allocate since the
    /// last collection it asked for, and the count at which it asks.
    sunk: u64 = 0,
    sunk_limit: u64 = opt.sunk_step,
    /// Whether optimized code calls optimized code at its direct entry.
    direct: bool = true,
    /// The units that make direct calls.
    callers: std.ArrayList(*opt.Unit) = .empty,
    /// The lowest address of the native stack that a chain of direct
    /// calls may reach, and the native stack pointer that code leaving
    /// such a chain continues with.
    stack_floor: usize = 0,
    exit_sp: usize = 0,
    /// Bytes of native stack that a chain of direct calls may use below
    /// the entry into Lus code, or zero to let the stack of the thread
    /// decide.
    chain_budget: usize = 0,
    /// The lowest address that the chain of direct calls that runs now
    /// may reach. The call that starts a chain sets it.
    chain_limit: usize = 0,
} else struct {};

/// The native code of one function.
pub const Code = extern struct {
    /// Address of the executable block. The entry sequence is at its
    /// start.
    base: usize,
    /// Offset in the block of the code for each instruction.
    offs: [*]u32,
    /// Bytes in the block.
    size: usize,
    /// Entries in `offs`.
    count: usize,
    /// Offsets of the call entry, of the call entry behind its counter,
    /// and of the tail entry, or zero.
    call_entry: usize = 0,
    call_entry_plain: usize = 0,
    tail_entry: usize = 0,
};

/// Reads the settings from the environment the host gave the state.
/// `LUS_JIT` is `off`, `on`, `baseline`, `eager`, or `opt-eager`.
/// `baseline` and `eager` keep the optimizing tier off, and `opt-eager`
/// sends every function through both tiers at once.
/// `LUS_JIT_THRESHOLD` is the number of events before a function
/// compiles, and `LUS_JIT_OPT_THRESHOLD` the number of events in
/// baseline code before the optimizing tier compiles it.
/// `LUS_JIT_DIRECT=off` keeps optimized code from calling optimized
/// code directly, and a number gives a chain of direct calls that many
/// bytes of native stack, which the tests use to leave chains often.
fn setup(g: *Global) void {
    const js = &g.jit;
    js.ready = true;
    // A WebAssembly host that cannot instantiate modules leaves the state
    // interpreted.
    if (is_wasm and !wasm.available()) {
        js.setting = .off;
        return;
    }
    const env = g.environ orelse return;
    if (env.get("LUS_JIT")) |v| {
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) {
            js.setting = .off;
            js.opt = .off;
        } else if (std.mem.eql(u8, v, "eager")) {
            js.setting = .eager;
            js.threshold = 1;
            js.opt = .off;
        } else if (std.mem.eql(u8, v, "baseline")) {
            js.opt = .off;
        } else if (std.mem.eql(u8, v, "opt-eager")) {
            js.setting = .eager;
            js.threshold = 1;
            js.opt = if (is_wasm) .off else .eager;
            js.opt_threshold = 1;
        }
    }
    if (js.setting == .on) if (env.get("LUS_JIT_THRESHOLD")) |v| {
        js.threshold = @max(std.fmt.parseInt(u32, v, 10) catch default_threshold, 1);
    };
    if (js.opt == .on) if (env.get("LUS_JIT_OPT_THRESHOLD")) |v| {
        js.opt_threshold = @max(std.fmt.parseInt(u32, v, 10) catch opt.default_threshold, 1);
    };
    js.opt_dump = env.get("LUS_JIT_DUMP") != null;
    if (env.get("LUS_JIT_DIRECT")) |v| {
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) {
            js.direct = false;
        } else if (std.fmt.parseInt(usize, v, 10)) |bytes| {
            js.chain_budget = @max(bytes, 256);
        } else |_| {}
    }
}

/// Sets the JIT of a state from the host, in place of the environment.
/// The optimizing tier stays off until `configureOpt` turns it on.
pub fn configure(g: *Global, how: Setting, threshold: u32) void {
    if (!enabled) return;
    const js = &g.jit;
    js.ready = true;
    js.setting = if (is_wasm and !wasm.available()) .off else how;
    js.threshold = if (how == .eager) 1 else @max(threshold, 1);
    js.period = 1;
    js.opt = .off;
}

/// Sets the optimizing tier of a state from the host.
pub fn configureOpt(g: *Global, how: opt.Setting, threshold: u32) void {
    if (!has_opt) return;
    const js = &g.jit;
    js.opt = if (js.setting == .off) .off else how;
    js.opt_threshold = if (how == .eager) 1 else @max(threshold, 1);
}

/// The setting of the optimizing tier, for `debug.jit`.
pub fn optSetting(g: *Global) opt.Setting {
    if (!has_opt) return .off;
    if (!g.jit.ready) setup(g);
    return if (g.jit.setting == .off) .off else g.jit.opt;
}

/// How many pieces of optimized code the state compiled, and how often
/// optimized code left through a guard.
pub fn counters(g: *Global) [2]usize {
    if (!has_opt) return .{ 0, 0 };
    return .{ g.jit.optimized, g.jit.exits };
}

/// Whether the function has optimized code in use.
pub fn isOptimized(p: *Proto) bool {
    return has_opt and opt.isOptimized(p);
}

/// The setting of the state, for `debug.jit`.
pub fn setting(g: *Global) Setting {
    if (!enabled) return .off;
    if (!g.jit.ready) setup(g);
    return g.jit.setting;
}

/// Whether the state compiles functions, which decides the interpreter
/// loop it runs.
pub inline fn active(g: *Global) bool {
    if (!enabled) return false;
    if (!g.jit.ready) setup(g);
    return g.jit.setting != .off;
}

/// Whether the function has native code.
pub fn isCompiled(p: *const Proto) bool {
    return enabled and p.jit_code != null;
}

/// Called when the counter of a function reaches zero. Returns true when
/// the function has native code and the caller should hand its frame over.
pub noinline fn expire(l: *Thread, p: *Proto) bool {
    @branchHint(.cold);
    if (!enabled) return false;
    const g = l.g;
    if (!g.jit.ready) setup(g);
    switch (p.jit_state) {
        .compiled => {
            p.hot = 1;
            return true;
        },
        .declined => {
            p.hot = 0;
            return false;
        },
        .fresh => {
            if (g.jit.setting == .off) {
                p.jit_state = .declined;
                p.hot = 0;
                return false;
            }
            if (g.jit.threshold > 1) {
                p.jit_state = .counting;
                p.hot = g.jit.threshold - 1;
                return false;
            }
        },
        .counting => {},
    }
    switch (compile(l, p)) {
        .done => {
            p.jit_state = .compiled;
            p.hot = 1;
            return true;
        },
        // The host compiles the code in the background. The function
        // asks again after more events.
        .later => {
            p.jit_state = .counting;
            p.hot = @max(g.jit.threshold, default_threshold) *| 16;
            return false;
        },
        .failed => {},
    }
    p.jit_state = .declined;
    p.hot = 0;
    return false;
}

/// Charges a function for `weight` events at once.
pub noinline fn charge(l: *Thread, p: *Proto, weight: u64) bool {
    if (!enabled) return false;
    switch (p.jit_state) {
        .compiled => return true,
        .declined => return false,
        .fresh => {
            if (!l.g.jit.ready) setup(l.g);
            if (l.g.jit.setting != .off and l.g.jit.threshold > 1) {
                p.jit_state = .counting;
                p.hot = l.g.jit.threshold;
            }
        },
        .counting => {},
    }
    if (p.jit_state == .counting and p.hot > weight) {
        p.hot -= @intCast(weight);
        return false;
    }
    return expire(l, p);
}

/// Numeric loops with fewer iterations than this are not charged when
/// they start. The function around them reaches the threshold some other
/// way if it matters.
pub const loop_weight_min = 16;

pub const Sample = struct {
    /// Events until the next sample.
    budget: u32,
    /// The sampled function has native code.
    enter: bool,
};

/// The sampling budget of the interpreter ran out in the top frame.
/// The function is charged for the period, and the next period gets a
/// different length, so that a regular program cannot hide a function
/// from the samples.
pub noinline fn sample(l: *Thread) Sample {
    @branchHint(.cold);
    if (!enabled) return .{ .budget = std.math.maxInt(u32), .enter = false };
    const g = l.g;
    const p = l.frame().closure.?.proto;
    if (!g.jit.ready) setup(g);
    const js = &g.jit;
    if (js.setting == .off) return .{ .budget = std.math.maxInt(u32), .enter = false };
    const used = js.period;
    if (js.setting == .on and js.threshold > 1) {
        js.seed = js.seed *% 1103515245 +% 12345;
        js.period = 5 + ((js.seed >> 16) & 7);
    } else {
        js.period = 1;
    }
    return .{ .budget = js.period, .enter = charge(l, p, used) };
}

/// Whether native code should run the top frame of a thread that is about
/// to execute. A function entered at its first instruction counts a call.
pub inline fn entryCheck(l: *Thread) bool {
    if (!enabled) return false;
    const fr = l.frame();
    const cl = fr.closure orelse return false;
    const p = cl.proto;
    if (p.jit_code != null) return true;
    if (fr.pc != 0) return false;
    p.hot -%= 1;
    if (p.hot != 0) return false;
    return expire(l, p);
}

/// Whether the function of the top frame has native code.
pub inline fn hasCode(l: *Thread) bool {
    if (!enabled) return false;
    if (l.frames.items.len == 0) return false;
    const cl = l.frame().closure orelse return false;
    return cl.proto.jit_code != null;
}

/// Where native code continues: the address for the saved pc of the top
/// frame, and the base of that frame. A zero address sends the frame to
/// the interpreter.
pub const Target = extern struct {
    addr: usize,
    base: usize,
};

/// Finds the native code for the top frame. Native code calls this after
/// every step that changed the frame or the pc.
pub fn dispatch(l: *Thread) callconv(cc) Target {
    const fr = l.frame();
    const none: Target = .{ .addr = 0, .base = 0 };
    const cl = fr.closure orelse return none;
    const p = cl.proto;
    if (p.jit_code == null) {
        // A call into a function without native code counts toward its
        // threshold, as it does in the interpreter.
        if (fr.pc != 0) return none;
        p.hot -%= 1;
        if (p.hot != 0 or !expire(l, p)) return none;
    }
    // A function entered at its first instruction runs its optimized
    // code when it has some, and counts toward getting some otherwise.
    if (has_opt and fr.pc == 0 and l.g.jit.opt != .off) {
        const addr = opt.entry(l, p);
        if (addr != 0) return .{ .addr = addr, .base = fr.base };
    }
    const code: *Code = @ptrCast(@alignCast(p.jit_code.?));
    return .{ .addr = code.base + code.offs[fr.pc], .base = fr.base };
}

const Enter = *const fn (l: *Thread, stop: usize, addr: usize, base: usize) callconv(cc) usize;

/// Runs frames in native code, starting with the top frame, until the
/// frame count drops to `stop` or a frame needs the interpreter.
pub fn run(l: *Thread, stop: usize) (Error || interp.YieldError || interp.LoopError)!void {
    if (!enabled) return error.SwitchLoop;
    if (is_wasm) return wasm.run(l, stop);
    const t = dispatch(l);
    if (t.addr == 0) return error.SwitchLoop;
    if (has_opt) setFloor(&l.g.jit, @frameAddress(), l.g.native_depth <= 1);
    const code: *Code = @ptrCast(@alignCast(l.frame().closure.?.proto.jit_code.?));
    const enter: Enter = @ptrFromInt(code.base);
    return switch (enter(l, stop, t.addr, t.base)) {
        interp.Step.done => {},
        interp.Step.failed => error.LusError,
        interp.Step.yielded => error.Yield,
        interp.Step.interpret => error.SwitchLoop,
        else => unreachable,
    };
}

/// Sets the lowest address that a chain of direct calls may take the
/// native stack to, for an entry into native code whose frame is at
/// `here`. When the stack of the thread is known and `here` lies in it,
/// a chain may use it down to a reserve that the runtime keeps for
/// leaving the chain. On any other stack, and when the setting names a
/// budget, the outermost entry into Lus code gives the chains a budget
/// below itself, and an entry that finds itself outside that budget
/// starts another one.
fn setFloor(js: *State, here: usize, outermost: bool) void {
    const b = stackBounds();
    if (js.chain_budget == 0 and b.low != 0 and here > b.low + 2 * opt.direct_stack_reserve and here <= b.high) {
        js.stack_floor = b.low + opt.direct_stack_reserve;
        return;
    }
    const budget = if (js.chain_budget != 0) js.chain_budget else opt.direct_stack_budget;
    if (outermost or js.stack_floor == 0 or here < js.stack_floor or here - js.stack_floor > budget) js.stack_floor = here -| budget;
}

const Bounds = struct { low: usize = 0, high: usize = 0 };

extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, addr: *?*anyopaque, size: *usize) c_int;
extern "c" fn pthread_attr_get_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;

threadlocal var thread_bounds: ?Bounds = null;

/// The native stack of the running thread, or zeros when the system
/// does not tell. A thread asks once.
extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;

fn stackBounds() Bounds {
    if (thread_bounds) |b| return b;
    var b: Bounds = .{};
    if (builtin.os.tag == .windows) {
        // The limits span the whole reservation of the stack, which the
        // system commits a page at a time as the stack grows.
        var low: usize = 0;
        var high: usize = 0;
        GetCurrentThreadStackLimits(&low, &high);
        if (high > low) b = .{ .low = low, .high = high };
    } else if (builtin.link_libc) switch (builtin.os.tag) {
        .macos => {
            const self = std.c.pthread_self();
            const high = @intFromPtr(pthread_get_stackaddr_np(self));
            const size = pthread_get_stacksize_np(self);
            if (high > size and size != 0) b = .{ .low = high - size, .high = high };
        },
        .linux => {
            var attr: std.c.pthread_attr_t = undefined;
            if (pthread_getattr_np(std.c.pthread_self(), &attr) == 0) {
                var addr: ?*anyopaque = null;
                var size: usize = 0;
                if (pthread_attr_getstack(&attr, &addr, &size) == 0 and addr != null and size != 0) {
                    b = .{ .low = @intFromPtr(addr), .high = @intFromPtr(addr) + size };
                }
                _ = std.c.pthread_attr_destroy(&attr);
            }
            // The stack of a thread ends within the stack size limit below
            // its top. The C library reads the bounds of the main thread
            // from the memory map, and under an emulator that map can
            // include memory below the stack, such as its guard page.
            if (b.low != 0) {
                if (std.posix.getrlimit(.STACK)) |lim| {
                    if (lim.cur != 0 and lim.cur < b.high) b.low = @max(b.low, b.high - lim.cur);
                } else |_| {}
            }
        },
        .freebsd => {
            var attr: std.c.pthread_attr_t = undefined;
            if (std.c.pthread_attr_init(&attr) == .SUCCESS) {
                if (pthread_attr_get_np(std.c.pthread_self(), &attr) == 0) {
                    var addr: ?*anyopaque = null;
                    var size: usize = 0;
                    if (pthread_attr_getstack(&attr, &addr, &size) == 0 and addr != null and size != 0) {
                        b = .{ .low = @intFromPtr(addr), .high = @intFromPtr(addr) + size };
                    }
                }
                _ = std.c.pthread_attr_destroy(&attr);
            }
        },
        else => {},
    };
    thread_bounds = b;
    return b;
}

/// The outcome of compiling a function.
pub const Outcome = enum { done, failed, later };

const compile = if (is_wasm) wasm.compile else compileNative;

fn compileNative(l: *Thread, p: *Proto) Outcome {
    return if (compileMachine(l, p)) .done else .failed;
}

fn compileMachine(l: *Thread, p: *Proto) bool {
    const g = l.g;
    const gpa = g.gpa;
    if (p.code.len > max_instructions) return false;
    var e = emit.Emitter.init(gpa, l, p);
    defer e.deinit();
    const offs = gpa.alloc(u32, p.code.len + 1) catch return false;
    if (!e.run(offs)) {
        gpa.free(offs);
        return false;
    }
    const bytes = e.bytes();
    const code = gpa.create(Code) catch {
        gpa.free(offs);
        return false;
    };
    const block = g.jit.arena.alloc(gpa, bytes.len) orelse {
        gpa.free(offs);
        gpa.destroy(code);
        // Without executable memory nothing will ever compile.
        g.jit.setting = .off;
        return false;
    };
    mem.install(block, bytes);
    code.* = .{
        .base = @intFromPtr(block.ptr),
        .offs = offs.ptr,
        .size = block.len,
        .count = offs.len,
        .call_entry = e.call_entry,
        .call_entry_plain = e.call_entry_plain,
        .tail_entry = e.tail_entry,
    };
    p.opt_hot = g.jit.opt_threshold;
    p.jit_code = code;
    p.jit_entry = if (e.call_entry != 0) code.base + e.call_entry else 0;
    p.jit_tail = if (e.tail_entry != 0) code.base + e.tail_entry else 0;
    p.call.plain = false;
    g.jit.live += 1;
    g.jit.compiled += 1;
    return true;
}

/// Frees the native code of a function that is being collected.
pub fn freeProto(g: *Global, p: *Proto) void {
    if (!enabled) return;
    if (has_opt) opt.freeProto(g, p);
    if (is_wasm) {
        if (p.jit_code == null) return;
        wasm.release(p);
        p.jit_code = null;
        p.call.plain = !p.is_vararg;
        g.jit.live -= 1;
        return;
    }
    const code: *Code = @ptrCast(@alignCast(p.jit_code orelse return));
    g.jit.arena.release(g.gpa, @as([*]u8, @ptrFromInt(code.base))[0..code.size]);
    g.gpa.free(code.offs[0..code.count]);
    g.gpa.destroy(code);
    p.jit_code = null;
    p.jit_entry = 0;
    p.jit_tail = 0;
    p.call.plain = !p.is_vararg;
    g.jit.live -= 1;
}

/// Releases the executable memory of a state that is closing.
pub fn deinit(g: *Global) void {
    if (!enabled or is_wasm) return;
    g.jit.callers.deinit(g.gpa);
    g.jit.arena.deinit(g.gpa);
}

test {
    _ = @import("a64.zig");
    _ = @import("x64.zig");
    _ = @import("rv64.zig");
    _ = @import("la64.zig");
    _ = @import("ppc64.zig");
    _ = @import("s390x.zig");
    if (enabled) {
        _ = mem;
        _ = emit;
        _ = @import("tests.zig");
    }
}
