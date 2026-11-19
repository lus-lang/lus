//! Developer tools behind `lus <command>`: test, fmt, check, ast, doc,
//! debug, build.

const std = @import("std");

pub fn run(init: std.process.Init, cmd: []const u8, args: []const []const u8) !u8 {
    if (std.mem.eql(u8, cmd, "test")) return @import("tools/test.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "ast")) return @import("tools/ast.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "fmt")) return @import("tools/fmt.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "build")) return @import("tools/build.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "check")) return @import("tools/check.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "doc")) return @import("tools/doc.zig").run(init, args);
    std.debug.print("lus {s}: not available yet\n", .{cmd});
    return 1;
}
