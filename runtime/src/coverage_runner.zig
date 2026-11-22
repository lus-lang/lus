//! The test runner of the unit tests in a `-Dcoverage=true` build.
//!
//! The build instruments the unit tests as it instruments `lus`, which
//! puts the test runner of the Zig library into its fuzzing mode, and that
//! mode runs only under the build server. This runner runs each test once
//! in the terminal, and each fuzz test on its corpus, so that `zig build
//! test -Dcoverage=true` with `LUS_COVERAGE` set writes the edges of the
//! unit tests as `lus` writes its own.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// The fuzzer of the Zig library, which the instrumented build links, calls
// back into the runner through these. This runner never starts it.
comptime {
    for ([_][]const u8{
        "runner_test_run",          "runner_test_name",  "runner_start_input_poller",
        "runner_stop_input_poller", "runner_futex_wait", "runner_futex_wake",
        "runner_broadcast_input",
    }) |name| @export(&unused, .{ .name = name });
}

fn unused() callconv(.c) noreturn {
    @panic("the coverage runner does not fuzz");
}

/// With `LUS_COVERAGE_REPORT` set, only the test that prints the report
/// runs (`lus.zig`).
const report_test = "coverage of the unit tests";

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    var ok: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    const reporting = std.c.getenv("LUS_COVERAGE_REPORT") != null;
    for (builtin.test_functions) |t| {
        if (reporting and std.mem.indexOf(u8, t.name, report_test) == null) continue;
        testing.allocator_instance = .init(std.heap.page_allocator, .{});
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            _ = testing.allocator_instance.deinit();
        }
        testing.log_level = .warn;
        testing.environ = init.environ;
        if (t.func()) |_| {
            ok += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                failed += 1;
                std.debug.print("{s}: FAIL ({t})\n", .{ t.name, err });
            },
        }
    }
    std.debug.print("{d} passed, {d} skipped, {d} failed\n", .{ ok, skipped, failed });
    if (failed != 0) std.process.exit(1);
}

/// Runs a fuzz test on its corpus, as the runner of the Zig library does
/// outside its fuzzing mode.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
}
