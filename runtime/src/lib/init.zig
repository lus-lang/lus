//! Opens the standard libraries.

const state = @import("../vm/state.zig");
const Thread = state.Thread;
const Error = state.Error;

pub fn openAll(l: *Thread) Error!void {
    try @import("base.zig").open(l);
    try @import("table.zig").open(l);
    try @import("math.zig").open(l);
    try @import("os.zig").open(l);
    try @import("utf8.zig").open(l);
}

test {
    _ = @import("table.zig");
    _ = @import("math.zig");
    _ = @import("os.zig");
    _ = @import("utf8.zig");
}
