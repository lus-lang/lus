//! Developer tools behind `lus <command>`: test, fmt, check, ast, doc,
//! debug, build, compile, help, agents, tree, version, completions.

const std = @import("std");

/// The usage text of every command, generated from
/// `spec/tools/cli.json` by `tools/build-cli.js`.
pub const usage = @import("tools/usage.zig");

/// The embedded language server of `lus lsp`, which `main.zig` runs.
pub const lsp = @import("tools/lsp.zig");

pub fn run(init: std.process.Init, cmd: []const u8, args: []const []const u8) !u8 {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        for (usage.commands) |c| {
            if (std.mem.eql(u8, cmd, c.name)) {
                std.Io.File.stdout().writeStreamingAll(init.io, c.usage) catch {};
                return 0;
            }
        }
    }
    // The commands that run Lus code load remote modules as `lus` does.
    var remote_process: @import("remote.zig").Process = undefined;
    const runs_code = std.mem.eql(u8, cmd, "test") or std.mem.eql(u8, cmd, "debug");
    if (runs_code) remote_process.begin(init.gpa, init.io, init.environ_map, .{});
    defer if (runs_code) remote_process.end();
    if (std.mem.eql(u8, cmd, "test")) return @import("tools/test.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "ast")) return @import("tools/ast.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "fmt")) return @import("tools/fmt.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "build")) return @import("tools/build.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "compile")) return @import("tools/compile.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "check")) return @import("tools/check.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "doc")) return @import("tools/doc.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "debug")) return @import("tools/debug.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "help")) return @import("tools/help.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "agents")) return @import("tools/agents.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "tree")) return @import("tools/tree.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "version")) return @import("tools/version.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "completions")) return @import("tools/completions.zig").run(init, args);
    std.debug.print("lus {s}: not available yet\n", .{cmd});
    return 1;
}

/// `lus +REQUEST ARGS...` (`tools/version.zig`).
pub fn plus(init: std.process.Init, req: []const u8, args: []const []const u8) !u8 {
    return @import("tools/version.zig").plus(init, req, args);
}
