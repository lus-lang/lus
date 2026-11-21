//! Opens the standard libraries. The network, worker, SQLite, and
//! archive libraries are optional (`-Dnet`, `-Dworkers`, `-Dsqlite`,
//! `-Darchive`). A library left out is never registered and its code is
//! compiled out.

const build_options = @import("build_options");
const state = @import("../vm/state.zig");
const Thread = state.Thread;
const Error = state.Error;

pub fn openAll(l: *Thread) Error!void {
    // The standard output and the capability registry are made here, where
    // running out of memory raises an error, and are only looked up later.
    _ = @import("out.zig").prepare(l.g) catch return l.raiseMem();
    _ = @import("../vm/pledge.zig").prepare(l.g) catch return l.raiseMem();
    l.g.dict_tables = true;
    defer l.g.dict_tables = false;
    try @import("base.zig").open(l);
    try @import("string.zig").open(l);
    try @import("table.zig").open(l);
    try @import("math.zig").open(l);
    try @import("os.zig").open(l);
    try @import("utf8.zig").open(l);
    try @import("coroutine.zig").open(l);
    try @import("debuglib.zig").open(l);
    try @import("vector.zig").open(l);
    if (build_options.archive) try @import("archive.zig").open(l);
    try @import("io.zig").open(l);
    try @import("json.zig").open(l);
    try @import("../vm/ext.zig").openEnums(l);
    try @import("../vm/ext.zig").openQueries(l);
    try @import("vector.zig").registerString(l);
    try @import("transcode.zig").register(l);
    try @import("fs.zig").open(l);
    if (build_options.net) try @import("network.zig").open(l);
    try @import("time.zig").open(l);
    try @import("csv.zig").open(l);
    if (build_options.workers) try @import("worker.zig").open(l);
    // package last, so it registers the libraries above as loaded.
    try @import("package.zig").open(l);
}

test {
    _ = @import("string.zig");
    _ = @import("table.zig");
    _ = @import("math.zig");
    _ = @import("os.zig");
    _ = @import("timecore.zig");
    _ = @import("time.zig");
    _ = @import("csv.zig");
    _ = @import("utf8.zig");
    _ = @import("json.zig");
    _ = @import("pack.zig");
    _ = @import("fs.zig");
    _ = @import("transcode.zig");
    if (build_options.archive) _ = @import("archive.zig");
}
