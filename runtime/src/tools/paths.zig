//! Expands the path arguments of `lus check` and `lus fmt`. A file stays
//! as given. A directory becomes every `.lus` file below it, sorted, with
//! the directories of dependencies and build output left out.

const std = @import("std");

/// Directory names that are never searched.
pub const skip_dirs = [_][]const u8{ "node_modules", ".git", "zig-out", ".zig-cache" };

/// Appends `path` to `files`, or the `.lus` files below it when it is a
/// directory. The appended strings belong to `arena`. Standard input,
/// written `-`, passes through.
pub fn expand(arena: std.mem.Allocator, io: std.Io, path: []const u8, files: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, path, "-")) return files.append(arena, path);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return files.append(arena, path);
    if (st.kind != .directory) return files.append(arena, path);

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    const first = files.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".lus")) continue;
        if (skipped(entry.path)) continue;
        try files.append(arena, try std.fs.path.join(arena, &.{ path, entry.path }));
    }
    std.mem.sort([]const u8, files.items[first..], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

/// True when a component of the relative path `rel` names a skipped
/// directory.
fn skipped(rel: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |part| {
        for (skip_dirs) |d| if (std.mem.eql(u8, part, d)) return true;
    }
    return false;
}

/// True for a test file, whose name ends in `_test.lus`.
pub fn isTestFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "_test.lus");
}

test skipped {
    try std.testing.expect(skipped("node_modules/x/a.lus"));
    try std.testing.expect(skipped("src/.git/a.lus"));
    try std.testing.expect(!skipped("src/zig-outer/a.lus"));
    try std.testing.expect(!skipped("a.lus"));
}
