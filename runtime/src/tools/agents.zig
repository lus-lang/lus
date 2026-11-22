//! `lus agents`: sets a project up for coding agents.
//!
//! Usage: lus agents init [DIR]
//!
//! `init` writes the agent skills built into this executable to
//! `DIR/.agents/skills`, the folder that agents across tools read, so the
//! skills always match the installed version of Lus. It links
//! `DIR/.claude/skills` to that folder, or links each skill into it when
//! `.claude/skills` is already a directory of its own, and copies the
//! skills where the system refuses symbolic links. Last, it adds a short
//! Lus section to `DIR/AGENTS.md`, creating the file if needed. Running it
//! again updates the skills and leaves everything else as it is.

const std = @import("std");
const docs = @import("agent_docs");

const usage =
    \\usage: lus agents init [DIR]
    \\
    \\Writes the Lus skills for coding agents into DIR/.agents/skills (default:
    \\the current directory), links .claude/skills to them, and adds a Lus
    \\section to AGENTS.md.
    \\
;

/// The line that marks the section `init` adds to AGENTS.md.
const marker = "<!-- lus agents init -->";

const section =
    \\## Lus
    \\
++ marker ++
    \\
    \\
    \\This project uses Lus. The skills in `.agents/skills/` explain how to write, test, and port Lus code, and they match the installed `lus`. After every change, run `lus check --json`, `lus fmt --write`, and `lus test`. `lus help NAME` prints the reference for a standard library function, and `lus help --search TEXT` finds one. Documentation, READMEs, doc comments, and other text for people follow the `lus-writing` skill.
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "init") or args.len > 2) {
        std.debug.print("{s}", .{usage});
        return if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) 0 else 2;
    }
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = if (args.len == 2) args[1] else ".";
    var root = std.Io.Dir.cwd().openDir(io, target, .{}) catch |e| {
        std.debug.print("lus agents: cannot open {s} ({s})\n", .{ target, @errorName(e) });
        return 2;
    };
    defer root.close(io);

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    const w = &out.writer;
    const status = initProject(arena, io, root, w) catch |e| blk: {
        std.debug.print("lus agents: {s}\n", .{@errorName(e)});
        break :blk @as(u8, 1);
    };
    std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    return status;
}

/// Sets up the project in `root` and reports each step to `w`.
pub fn initProject(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, w: *std.Io.Writer) !u8 {
    // The skills.
    var written: usize = 0;
    for (docs.skills) |f| {
        const dest = try std.fmt.allocPrint(arena, ".agents/skills/{s}", .{f.path});
        if (try writeIfChanged(arena, io, root, dest, f.data)) written += 1;
    }
    try w.print("{d} of {d} skill files written to .agents/skills\n", .{ written, docs.skills.len });

    // .claude/skills, for agents that read only their own folder.
    try root.createDirPath(io, ".claude");
    const st = root.statFile(io, ".claude/skills", .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (st == null) {
        if (root.symLink(io, "../.agents/skills", ".claude/skills", .{ .is_directory = true })) {
            try w.writeAll(".claude/skills linked to .agents/skills\n");
        } else |_| {
            try copySkills(arena, io, root, ".claude/skills");
            try w.writeAll(".claude/skills written as a copy of .agents/skills\n");
        }
    } else if (st.?.kind == .directory) {
        for (try skillNames(arena)) |name| {
            const link = try std.fmt.allocPrint(arena, ".claude/skills/{s}", .{name});
            if (root.statFile(io, link, .{ .follow_symlinks = false })) |_| continue else |_| {}
            const to = try std.fmt.allocPrint(arena, "../../.agents/skills/{s}", .{name});
            if (root.symLink(io, to, link, .{ .is_directory = true })) {
                try w.print("{s} linked to .agents/skills/{s}\n", .{ link, name });
            } else |_| {
                try copySkills(arena, io, root, ".claude/skills");
                try w.print("{s} written as a copy\n", .{link});
            }
        }
    }

    // AGENTS.md.
    const existing = root.readFileAlloc(io, "AGENTS.md", arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (existing) |text| {
        if (std.mem.indexOf(u8, text, marker) == null) {
            const sep: []const u8 = if (text.len == 0 or std.mem.endsWith(u8, text, "\n\n")) "" else if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n";
            try root.writeFile(io, .{ .sub_path = "AGENTS.md", .data = try std.mem.concat(arena, u8, &.{ text, sep, section }) });
            try w.writeAll("AGENTS.md gained a Lus section\n");
        }
    } else {
        try root.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "# Agents\n\n" ++ section });
        try w.writeAll("AGENTS.md created with a Lus section\n");
    }
    return 0;
}

/// Writes `data` to `path` below `root` unless the file already holds
/// it, creating parent directories. Returns whether it wrote.
fn writeIfChanged(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, data: []const u8) !bool {
    if (root.readFileAlloc(io, path, arena, .unlimited)) |old| {
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| try root.createDirPath(io, parent);
    try root.writeFile(io, .{ .sub_path = path, .data = data });
    return true;
}

fn copySkills(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, into: []const u8) !void {
    for (docs.skills) |f| {
        _ = try writeIfChanged(arena, io, root, try std.fmt.allocPrint(arena, "{s}/{s}", .{ into, f.path }), f.data);
    }
}

/// The top-level skill folders, such as `lus` and `lus-rewrite`.
fn skillNames(arena: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (docs.skills) |f| {
        const slash = std.mem.indexOfScalar(u8, f.path, '/') orelse continue;
        const name = f.path[0..slash];
        for (names.items) |n| {
            if (std.mem.eql(u8, n, name)) break;
        } else try names.append(arena, name);
    }
    return names.items;
}

test skillNames {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const names = try skillNames(arena.allocator());
    try std.testing.expect(names.len >= 2);
    var has_lus = false;
    for (names) |n| has_lus = has_lus or std.mem.eql(u8, n, "lus");
    try std.testing.expect(has_lus);
}

test initProject {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "# Project\n" });

    var out: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), try initProject(a, io, tmp.dir, &out.writer));
    const skill = try tmp.dir.readFileAlloc(io, ".claude/skills/lus/SKILL.md", a, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, skill, "---\nname: lus\n"));
    const writing = try tmp.dir.readFileAlloc(io, ".agents/skills/lus-writing/SKILL.md", a, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, writing, "---\nname: lus-writing\n"));
    const agents = try tmp.dir.readFileAlloc(io, "AGENTS.md", a, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, agents, "# Project\n\n## Lus\n" ++ marker));
    try std.testing.expect(std.mem.indexOf(u8, agents, "`lus-writing` skill") != null);

    // A second run changes nothing.
    out.clearRetainingCapacity();
    _ = try initProject(a, io, tmp.dir, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "0 of "));
    try std.testing.expectEqualStrings(agents, try tmp.dir.readFileAlloc(io, "AGENTS.md", a, .unlimited));
}
