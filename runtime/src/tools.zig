//! Developer tools behind `lus <command>`: test, fmt, check, ast, doc,
//! debug, build, compile.

const std = @import("std");
const bundle = @import("bundle.zig");
const feedback = @import("compile/feedback.zig");

/// What the tools need from the command line program that hosts them.
pub const Host = struct {
    /// Runs a bundle as the standalone executable that carries it would,
    /// with `args` as its command line. With a profile, the run records
    /// the feedback of the chunks it loads.
    run_bundle: *const fn (init: std.process.Init, b: *const bundle.Bundle, args: []const []const u8, profile: ?*feedback.Profile) anyerror!u8,
};

/// Usage for the commands that read their options themselves.
const usages = .{
    .{ "test", "usage: lus test [-u] [--doc] [--filter TEXT] [--jobs N] [--timeout SECONDS] [--json] [-v] [PATH...]\n\nRuns every *_test.lus file under the given paths (default: the current\ndirectory). Each top-level function ending in _test is a test. -u updates\nsnapshots. --doc runs the lus code blocks of Markdown files instead, skipping\nblocks fenced as ```lus nocheck.\n" },
    .{ "ast", "usage: lus ast [--no-comments] [--no-recover] FILE\n\nPrints the syntax tree of FILE as JSON.\n" },
    .{ "build", "usage: lus build [-o OUT] [-P PERM]... [-F NAME=VALUE]... [--include PATH[:ALIAS]]... [--profile] MAIN.lus [-- ARGS...]\n\nBundles MAIN.lus and the modules it requires into a standalone executable.\n--profile runs the program once with ARGS and stores the functions that\nbecame hot, so that the executable starts warm.\n" },
    .{ "compile", "usage: lus compile [-o OUT] [-s] [-F NAME=VALUE]... [--profile [-P PERM]...] SCRIPT [-- ARGS...]\n\nCompiles SCRIPT to a binary chunk (default output: SCRIPT.lusc). -s leaves out\ndebug information. --profile runs SCRIPT once with ARGS and stores the\nfunctions that became hot, so that the chunk starts warm.\n" },
};

pub fn run(init: std.process.Init, cmd: []const u8, args: []const []const u8, host: Host) !u8 {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        inline for (usages) |u| {
            if (std.mem.eql(u8, cmd, u[0])) {
                std.debug.print("{s}", .{u[1]});
                return 0;
            }
        }
    }
    if (std.mem.eql(u8, cmd, "test")) return @import("tools/test.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "ast")) return @import("tools/ast.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "fmt")) return @import("tools/fmt.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "build")) return @import("tools/build.zig").run(init, args, host);
    if (std.mem.eql(u8, cmd, "compile")) return @import("tools/compile.zig").run(init, args, host);
    if (std.mem.eql(u8, cmd, "check")) return @import("tools/check.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "doc")) return @import("tools/doc.zig").run(init, args);
    if (std.mem.eql(u8, cmd, "debug")) return @import("tools/debug.zig").run(init, args);
    std.debug.print("lus {s}: not available yet\n", .{cmd});
    return 1;
}
