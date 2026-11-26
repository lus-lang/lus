//! `lus agents`: sets a project up for coding agents.
//!
//! Usage: lus agents init [DIR]
//!
//! `init` writes the agent skills built into this executable to
//! `DIR/.agents/skills`, the folder that agents across tools read, so the
//! skills always match the installed version of Lus. It links
//! `DIR/.claude/skills` to that folder, or links each skill into it when
//! `.claude/skills` is already a directory of its own, and copies the
//! skills where the system refuses symbolic links. Last, it writes a short
//! Lus section to `DIR/AGENTS.md`, creating the file if needed. Running it
//! again updates the skills and the text between the markers of that
//! section, and leaves the rest of `AGENTS.md` as it is.

const std = @import("std");
const docs = @import("agent_docs");

const usage = @import("usage.zig").of("agents");

/// The lines that open and close the text `init` owns in AGENTS.md.
const marker = "<!-- lus agents init -->";
const end_marker = "<!-- /lus agents init -->";

/// How the text of every earlier version of the section starts. Those
/// versions wrote this paragraph on one line after `marker` and no
/// `end_marker`.
const old_body_start = "This project uses Lus.";

/// The text between the markers.
const block = marker ++ "\n\n" ++ body ++ "\n" ++ end_marker;

/// The section that `init` appends to an AGENTS.md without one.
const section = "## Lus\n\n" ++ block ++ "\n";

const body =
    \\This project uses Lus. The skills in `.agents/skills/` explain how to write, test, and port Lus code, and they match the installed `lus`. After every change, run `lus check --json`, `lus fmt --write`, and `lus test`. `lus help NAME` prints the reference for a standard library function, and `lus help --search TEXT` finds one. Prose in this project follows the `lus-writing` skill in `.agents/skills/lus-writing`. That covers the README, documentation, doc comments, commit messages, and the changelog.
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
            if (root.statFile(io, link, .{ .follow_symlinks = false })) |entry| {
                // A copy from an earlier run gets the current files.
                if (entry.kind == .directory) try copySkill(arena, io, root, ".claude/skills", name);
                continue;
            } else |_| {}
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
        switch (try updateAgents(arena, text)) {
            .unchanged => {},
            .appended => |data| {
                try root.writeFile(io, .{ .sub_path = "AGENTS.md", .data = data });
                try w.writeAll("AGENTS.md gained a Lus section\n");
            },
            .updated => |data| {
                try root.writeFile(io, .{ .sub_path = "AGENTS.md", .data = data });
                try w.writeAll("AGENTS.md Lus section updated\n");
            },
            .unknown => try w.writeAll("AGENTS.md left as it is: the text after " ++ marker ++ " was not written by lus agents init. Remove the marker line to get a new Lus section.\n"),
        }
    } else {
        try root.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "# Agents\n\n" ++ section });
        try w.writeAll("AGENTS.md created with a Lus section\n");
    }
    return 0;
}

const AgentsUpdate = union(enum) {
    /// The file already holds the current section.
    unchanged,
    /// The file had no section, and this text appends one.
    appended: []const u8,
    /// The file had a section, and this text replaces its contents.
    updated: []const u8,
    /// The file has a marker without text that `init` recognizes.
    unknown,
};

/// Computes the new contents of an AGENTS.md that holds `text`. Only the
/// text between the markers changes. A section from an earlier version,
/// which has no end marker, is recognized by its paragraph and replaced
/// through the end of that line, and any other text after a lone marker
/// is left alone.
fn updateAgents(arena: std.mem.Allocator, text: []const u8) !AgentsUpdate {
    const start = std.mem.indexOf(u8, text, marker) orelse {
        const sep: []const u8 = if (text.len == 0 or std.mem.endsWith(u8, text, "\n\n")) "" else if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n";
        return .{ .appended = try std.mem.concat(arena, u8, &.{ text, sep, section }) };
    };
    const after = start + marker.len;
    const stop = if (std.mem.indexOfPos(u8, text, after, end_marker)) |e| e + end_marker.len else blk: {
        var i = after;
        while (i < text.len and (text[i] == '\n' or text[i] == '\r')) i += 1;
        if (!std.mem.startsWith(u8, text[i..], old_body_start)) return .unknown;
        break :blk std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
    };
    const data = try std.mem.concat(arena, u8, &.{ text[0..start], block, text[stop..] });
    return if (std.mem.eql(u8, data, text)) .unchanged else .{ .updated = data };
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

/// Writes the files of the skill `name` into `into/name`.
fn copySkill(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, into: []const u8, name: []const u8) !void {
    for (docs.skills) |f| {
        if (!std.mem.startsWith(u8, f.path, name) or f.path.len <= name.len or f.path[name.len] != '/') continue;
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
    try std.testing.expectEqualStrings("# Project\n\n" ++ section, agents);
    try std.testing.expect(std.mem.indexOf(u8, agents, "Prose in this project follows the `lus-writing` skill") != null);

    // A second run changes nothing.
    out.clearRetainingCapacity();
    _ = try initProject(a, io, tmp.dir, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "0 of "));
    try std.testing.expectEqualStrings(agents, try tmp.dir.readFileAlloc(io, "AGENTS.md", a, .unlimited));
}

test "updateAgents replaces a section of an earlier version and keeps the text around it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "# Project\n\nKeep this.\n\n## Lus\n\n" ++ marker ++ "\n\nThis project uses Lus. Old advice.\n\n## Deploy\n\nKeep this too.\n";
    const data = (try updateAgents(a, old)).updated;
    try std.testing.expectEqualStrings("# Project\n\nKeep this.\n\n## Lus\n\n" ++ block ++ "\n\n## Deploy\n\nKeep this too.\n", data);
    // The updated file is current, so a second run changes nothing.
    try std.testing.expect(try updateAgents(a, data) == .unchanged);
}

test "updateAgents replaces only the text between the markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edited = "Intro.\n\n## Lus\n\n" ++ marker ++ "\n\nStale text.\n\nMore stale text.\n" ++ end_marker ++ "\nOutro, with " ++ marker ++ "-free text.\n";
    const data = (try updateAgents(a, edited)).updated;
    try std.testing.expectEqualStrings("Intro.\n\n## Lus\n\n" ++ block ++ "\nOutro, with " ++ marker ++ "-free text.\n", data);
}

test "updateAgents leaves unknown text after a lone marker alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "## Lus\n\n" ++ marker ++ "\n\nOur own notes about Lus.\n";
    try std.testing.expect(try updateAgents(arena.allocator(), text) == .unknown);
}

test "updateAgents appends a section to a file without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = (try updateAgents(arena.allocator(), "# Project")).appended;
    try std.testing.expectEqualStrings("# Project\n\n" ++ section, data);
}

test "initProject updates an old section and refreshes the skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = "# Project\n\n## Lus\n\n" ++ marker ++ "\n\nThis project uses Lus. Old advice.\n\n## Mine\n\nUser text.\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = old });
    try tmp.dir.createDirPath(io, ".agents/skills/lus");
    try tmp.dir.writeFile(io, .{ .sub_path = ".agents/skills/lus/SKILL.md", .data = "stale" });

    var out: std.Io.Writer.Allocating = .init(a);
    _ = try initProject(a, io, tmp.dir, &out.writer);
    const agents = try tmp.dir.readFileAlloc(io, "AGENTS.md", a, .unlimited);
    try std.testing.expectEqualStrings("# Project\n\n## Lus\n\n" ++ block ++ "\n\n## Mine\n\nUser text.\n", agents);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "AGENTS.md Lus section updated") != null);
    const skill = try tmp.dir.readFileAlloc(io, ".agents/skills/lus/SKILL.md", a, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, skill, "---\nname: lus\n"));
}
