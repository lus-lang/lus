//! The baseline JIT. It compiles a hot function to native code that runs
//! the same frames, on the same Lus stack, as the interpreter. The design
//! is described in `spec/design/jit.md`.
//!
//! This file holds the parts that are independent of the instruction set:
//! the settings, the hotness policy, the hand-over between the tiers, and
//! the lifetime of the code. `emit.zig` turns bytecode into instructions
//! through the assembler of the target (`a64.zig` or `x64.zig`), and
//! `mem.zig` manages executable memory.

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
/// backend and a way to map executable memory.
pub const enabled = build_options.jit and switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => switch (builtin.os.tag) {
        .macos, .linux => true,
        else => false,
    },
    else => false,
};

const mem = @import("mem.zig");
const emit = @import("emit.zig");
pub const helpers = @import("helpers.zig");

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
    arena: mem.Arena = .{},
    /// Functions that have native code now.
    live: usize = 0,
    /// Functions compiled since the state started.
    compiled: usize = 0,
} else struct {};

/// The native code of one function.
pub const Code = struct {
    /// The executable block. The entry sequence is at its start.
    block: []u8,
    /// Offset in the block of the code for each instruction.
    offs: []u32,
};

/// Reads the settings from the environment the host gave the state.
/// `LUS_JIT` is `off`, `on`, or `eager`, and `LUS_JIT_THRESHOLD` is the
/// number of events before a function compiles.
fn setup(g: *Global) void {
    const js = &g.jit;
    js.ready = true;
    const env = g.environ orelse return;
    if (env.get("LUS_JIT")) |v| {
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) {
            js.setting = .off;
        } else if (std.mem.eql(u8, v, "eager")) {
            js.setting = .eager;
            js.threshold = 1;
        }
    }
    if (js.setting == .on) if (env.get("LUS_JIT_THRESHOLD")) |v| {
        js.threshold = @max(std.fmt.parseInt(u32, v, 10) catch default_threshold, 1);
    };
}

/// The setting of the state, for `debug.jit`.
pub fn setting(g: *Global) Setting {
    if (!enabled) return .off;
    if (!g.jit.ready) setup(g);
    return g.jit.setting;
}

/// Whether the function has native code.
pub fn isCompiled(p: *const Proto) bool {
    return enabled and p.jit_code != null;
}

/// Called when the counter of a function reaches zero. Returns true when
/// the function has native code and the caller should hand its frame over.
pub noinline fn tick(l: *Thread, p: *Proto) bool {
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
    if (compile(l, p)) {
        p.jit_state = .compiled;
        p.hot = 1;
        return true;
    }
    p.jit_state = .declined;
    p.hot = 0;
    return false;
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
    return tick(l, p);
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
pub fn dispatch(l: *Thread) callconv(.c) Target {
    const fr = l.frame();
    const none: Target = .{ .addr = 0, .base = 0 };
    const cl = fr.closure orelse return none;
    const p = cl.proto;
    if (p.jit_code == null) {
        // A call into a function without native code counts toward its
        // threshold, as it does in the interpreter.
        if (fr.pc != 0) return none;
        p.hot -%= 1;
        if (p.hot != 0 or !tick(l, p)) return none;
    }
    const code: *Code = @ptrCast(@alignCast(p.jit_code.?));
    return .{ .addr = @intFromPtr(code.block.ptr) + code.offs[fr.pc], .base = fr.base };
}

const Enter = *const fn (l: *Thread, stop: usize, addr: usize, base: usize) callconv(.c) usize;

/// Runs frames in native code, starting with the top frame, until the
/// frame count drops to `stop` or a frame needs the interpreter.
pub fn run(l: *Thread, stop: usize) (Error || interp.YieldError || interp.LoopError)!void {
    if (!enabled) return error.SwitchLoop;
    const t = dispatch(l);
    if (t.addr == 0) return error.SwitchLoop;
    const code: *Code = @ptrCast(@alignCast(l.frame().closure.?.proto.jit_code.?));
    const enter: Enter = @ptrFromInt(@intFromPtr(code.block.ptr));
    return switch (enter(l, stop, t.addr, t.base)) {
        interp.Step.done => {},
        interp.Step.failed => error.LusError,
        interp.Step.yielded => error.Yield,
        interp.Step.interpret => error.SwitchLoop,
        else => unreachable,
    };
}

fn compile(l: *Thread, p: *Proto) bool {
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
    code.* = .{ .block = block, .offs = offs };
    p.jit_code = code;
    g.jit.live += 1;
    g.jit.compiled += 1;
    return true;
}

/// Frees the native code of a function that is being collected.
pub fn freeProto(g: *Global, p: *Proto) void {
    if (!enabled) return;
    const code: *Code = @ptrCast(@alignCast(p.jit_code orelse return));
    g.jit.arena.release(g.gpa, code.block);
    g.gpa.free(code.offs);
    g.gpa.destroy(code);
    p.jit_code = null;
    g.jit.live -= 1;
}

/// Releases the executable memory of a state that is closing.
pub fn deinit(g: *Global) void {
    if (!enabled) return;
    g.jit.arena.deinit(g.gpa);
}

test {
    _ = @import("a64.zig");
    _ = @import("x64.zig");
    if (enabled) {
        _ = mem;
        _ = emit;
    }
}
