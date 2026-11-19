//! The routines native code calls. Every opcode has a step routine, which
//! is the interpreter's own body for that opcode, instantiated to run one
//! instruction. Native code falls back to it whenever an inline fast path
//! does not apply, so the tiers share one definition of every opcode.

const std = @import("std");
const state = @import("../vm/state.zig");
const interp = @import("../vm/interp.zig");
const opc = @import("../compile/opcodes.zig");
const Thread = state.Thread;
const Op = opc.Op;

pub const StepFn = *const fn (l: *Thread, pc: u32, stop: usize) callconv(.c) usize;

fn StepOf(comptime o: Op) type {
    return struct {
        /// Runs the instruction before `pc` in the top frame and returns
        /// an `interp.Step` code.
        fn step(l: *Thread, pc: u32, stop: usize) callconv(.c) usize {
            l.frames.items[l.frames.items.len - 1].pc = pc;
            return interp.run(l, stop, .{ .step = o }) catch |e| {
                l.meta_finish = null;
                return switch (e) {
                    // A metamethod frame was pushed. It runs like a call.
                    error.MetaCall => interp.Step.dispatch,
                    error.LusError => interp.Step.failed,
                    error.Yield => interp.Step.yielded,
                    error.SwitchLoop, error.EnterJit => interp.Step.interpret,
                };
            };
        }
    };
}

const op_values = @typeInfo(Op).@"enum".field_values;
const op_count = op_values.len;

/// The step routine of every opcode, indexed by opcode.
pub const steps: [op_count]StepFn = blk: {
    var t: [op_count]StepFn = undefined;
    for (op_values) |v| t[v] = &StepOf(@fromBackingInt(v)).step;
    break :blk t;
};
