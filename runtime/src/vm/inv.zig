//! Checks of internal invariants, in the manner of the `assert`, `ALWAYS`,
//! and `NEVER` macros of SQLite.
//!
//! The checks run in Debug builds, in the unit tests, and in any build
//! with `-Dinvariants=true`. Elsewhere a check behind `if (inv.enabled)`
//! compiles to nothing and costs nothing, so it may walk a whole
//! structure.
//!
//! `always(c)` and `never(c)` guard a defensive branch that no input
//! should reach: `if (inv.never(len > limit)) return error.Corrupt`. A
//! checking build panics when the branch is taken. A release build keeps
//! the test and takes the branch, so a broken invariant still ends in an
//! error. The coverage build replaces them with constants, so the branch
//! leaves the count of edges, and the report counts these marks instead.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// True when the checks run.
pub const enabled = build_options.invariants or builtin.mode == .debug or builtin.is_test;

/// True in the coverage build, where marked branches fold away.
const folding = build_options.coverage;

/// Panics when `c` is false in a checking build. `c` must have no effect.
/// The argument is evaluated before the call, so a check that calls a
/// function goes behind `if (inv.enabled)`, which leaves it out of a
/// release build.
pub inline fn assert(c: bool) void {
    if (enabled and !c) failed("invariant", @returnAddress());
}

/// `c`, which must be true. A checking build panics when it is false.
pub inline fn always(c: bool) bool {
    if (folding) return true;
    if (enabled and !c) failed("ALWAYS", @returnAddress());
    return c;
}

/// `c`, which must be false. A checking build panics when it is true.
pub inline fn never(c: bool) bool {
    if (folding) return false;
    if (enabled and c) failed("NEVER", @returnAddress());
    return c;
}

fn failed(comptime what: []const u8, ra: usize) noreturn {
    @branchHint(.cold);
    std.debug.panicExtra(ra, what ++ " failed", .{});
}

test "the checks run in the unit tests" {
    try std.testing.expect(enabled);
    try std.testing.expect(always(true) or folding);
    try std.testing.expect(!never(false));
}
