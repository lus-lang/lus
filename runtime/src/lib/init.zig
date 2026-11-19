//! Opens the standard libraries.

const state = @import("../vm/state.zig");
const Thread = state.Thread;
const Error = state.Error;

pub fn openAll(l: *Thread) Error!void {
    try @import("base.zig").open(l);
}
