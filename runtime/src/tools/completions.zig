//! `lus completions SHELL`: prints the completion script of the `lus`
//! command line for bash, zsh, fish, or PowerShell.
//!
//! The scripts are the files of `packaging/share` that
//! `tools/build-cli.js` generates from `spec/tools/cli.json`, embedded at
//! build time, so the output matches what a package installs.

const std = @import("std");
const docs = @import("agent_docs");

const usage = @import("usage.zig").of("completions");

const Shell = enum { bash, zsh, fish, powershell };

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const shell = if (args.len == 1) std.meta.stringToEnum(Shell, args[0]) else null;
    const script = switch (shell orelse {
        if (args.len == 1) std.debug.print("lus completions: unknown shell '{s}'\n", .{args[0]});
        std.debug.print("{s}", .{usage});
        return 2;
    }) {
        .bash => docs.completions.bash,
        .zsh => docs.completions.zsh,
        .fish => docs.completions.fish,
        .powershell => docs.completions.powershell,
    };
    std.Io.File.stdout().writeStreamingAll(init.io, script) catch {};
    return 0;
}
