//! Counts of the opcode sequences the interpreter runs, for builds made
//! with `-Dop-profile=true`. The plain loop reports every instruction it
//! dispatches, and the CLI prints the counts of every pair and of every
//! run of three to standard error when the program ends.
//! `tools/op-ngrams.js` runs the bench corpus this way and ranks the
//! sequences, which is how candidates for fused instructions are found.
//! A pair that is already fused is dispatched once, so it counts as its
//! first opcode followed by whatever runs after the pair.

const std = @import("std");
const opc = @import("../compile/opcodes.zig");
const build_options = @import("build_options");
const Op = opc.Op;

pub const enabled = build_options.op_profile;

const n = @typeInfo(Op).@"enum".field_values.len;

var pairs: if (enabled) [n * n]u64 else void = if (enabled) @splat(0) else {};
var triples: if (enabled) [n * n * n]u64 else void = if (enabled) @splat(0) else {};
var prev1: usize = 0;
var prev2: usize = 0;

/// Records that the plain loop dispatches `op`.
pub inline fn note(op: Op) void {
    if (!enabled) return;
    const o: usize = @backingInt(op);
    pairs[prev1 * n + o] += 1;
    triples[(prev2 * n + prev1) * n + o] += 1;
    prev2 = prev1;
    prev1 = o;
}

/// Prints one line per sequence that ran: its count and its opcodes.
pub fn dump() void {
    if (!enabled) return;
    const names = @typeInfo(Op).@"enum".field_names;
    for (0..n) |a| for (0..n) |b| {
        const c2 = pairs[a * n + b];
        if (c2 != 0) std.debug.print("{d} {s} {s}\n", .{ c2, names[a], names[b] });
        for (0..n) |c| {
            const c3 = triples[(a * n + b) * n + c];
            if (c3 != 0) std.debug.print("{d} {s} {s} {s}\n", .{ c3, names[a], names[b], names[c] });
        }
    };
}
