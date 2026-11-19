//! Opens the standard libraries.

const state = @import("../vm/state.zig");
const Thread = state.Thread;
const Error = state.Error;

pub fn openAll(l: *Thread) Error!void {
    try @import("base.zig").open(l);
    try @import("coroutine.zig").open(l);
    try @import("debuglib.zig").open(l);
    try @import("vector.zig").open(l);
    try @import("io.zig").open(l);
    try @import("../vm/ext.zig").openEnums(l);
    try @import("vector.zig").registerString(l);
    // package last, so it registers the libraries above as loaded.
    try @import("package.zig").open(l);
}
