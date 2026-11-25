//! Developer tools behind `lus <command>`: test, fmt, check, ast, doc,
//! debug, build, compile, help, agents, tree, version.

const std = @import("std");

/// Usage for the commands that read their options themselves.
const usages = .{
    .{ "test", "usage: lus test [-u] [--doc] [--bench] [--bench-time SECONDS] [--filter TEXT] [--jobs N] [--timeout SECONDS] [--file-timeout SECONDS] [--json] [-v] [PATH...]\n\nRuns every *_test.lus file under the given paths (default: the current\ndirectory). Each top-level function ending in _test is a test, and each one\nending in _bench is a benchmark, which a plain run calls once. --bench\nmeasures the benchmarks instead, each for --bench-time (default: 1 second),\nand compares them with the baseline that --bench -u saves. -u updates\nsnapshots. --doc runs the lus code blocks of Markdown files instead, skipping\nblocks fenced as ```lus nocheck. --timeout stops a file that writes no output\nfor that long (default: 60 seconds). --file-timeout stops a file that runs\nlonger than that in all (default: ten times the timeout).\n" },
    .{ "ast", "usage: lus ast [--no-comments] [--no-recover] FILE\n\nPrints the syntax tree of FILE as JSON.\n" },
    .{ "build", "usage: lus build [-o OUT] [-P PERM]... [-F NAME=VALUE]... [--include PATH[:ALIAS]]... MAIN.lus\n\nBundles MAIN.lus and the modules it requires into a standalone executable.\n" },
    .{ "compile", "usage: lus compile [-o OUT] [-s] [-F NAME=VALUE]... SCRIPT\n\nCompiles SCRIPT to a binary chunk (default output: SCRIPT.lusc). -s leaves out\ndebug information.\n" },
};

pub fn run(init: std.process.Init, cmd: []const u8, args: []const []const u8) !u8 {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        inline for (usages) |u| {
            if (std.mem.eql(u8, cmd, u[0])) {
                std.debug.print("{s}", .{u[1]});
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
    std.debug.print("lus {s}: not available yet\n", .{cmd});
    return 1;
}

/// `lus +REQUEST ARGS...` (`tools/version.zig`).
pub fn plus(init: std.process.Init, req: []const u8, args: []const []const u8) !u8 {
    return @import("tools/version.zig").plus(init, req, args);
}
