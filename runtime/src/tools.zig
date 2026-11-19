//! Developer tools behind `lus <command>`: test, fmt, check, ast, doc,
//! debug, build.

const std = @import("std");

pub fn run(init: std.process.Init, cmd: []const u8, args: []const []const u8) !u8 {
    _ = init;
    _ = args;
    std.debug.print("lus {s}: not available yet\n", .{cmd});
    return 1;
}
