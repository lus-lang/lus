//! The Lus home: the per-user directory that holds installed versions and
//! the module cache (`spec/design/modules.md`, section 1).
//!
//! It is `LUS_HOME` when that is set, otherwise `~/.lus` on POSIX systems
//! and `%LOCALAPPDATA%\lus` on Windows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;
pub const exe_name = if (is_windows) "lus.exe" else "lus";
pub const sep = std.fs.path.sep_str;

/// Returns the path of the Lus home, or null when neither `LUS_HOME` nor
/// the home directory of the user is known.
pub fn path(gpa: Allocator, env: ?*const std.process.Environ.Map) Allocator.Error!?[]u8 {
    const e = env orelse return null;
    if (e.get("LUS_HOME")) |h| if (h.len > 0) return try gpa.dupe(u8, h);
    if (is_windows) {
        const local = e.get("LOCALAPPDATA") orelse return null;
        return try std.fs.path.join(gpa, &.{ local, "lus" });
    }
    const home = e.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(gpa, &.{ home, ".lus" });
}

/// Joins path components below the home.
pub fn join(gpa: Allocator, home: []const u8, parts: []const []const u8) Allocator.Error![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.append(gpa, home);
    try all.appendSlice(gpa, parts);
    return std.fs.path.join(gpa, all.items);
}

/// Writes `data` to `dir/name` through a temporary file and a rename, so
/// a reader sees the old content or the new one.
pub fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    // The temporary file goes in the directory of `name`, so the rename
    // stays within one directory.
    const base = std.fs.path.basename(name);
    const parent = name[0 .. name.len - base.len];
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{s}.{x}", .{ parent, base, rnd });
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    dir.rename(tmp, dir, name, io) catch |e| {
        dir.deleteFile(io, tmp) catch {};
        return e;
    };
}

/// An exclusive lock on `home/lock`, held while a command changes the home.
pub const Lock = struct {
    file: Io.File,

    pub fn acquire(io: Io, dir: Io.Dir) !Lock {
        const f = try dir.createFile(io, "lock", .{ .truncate = false });
        errdefer f.close(io);
        try f.lock(io, .exclusive);
        return .{ .file = f };
    }

    pub fn release(l: Lock, io: Io) void {
        l.file.unlock(io);
        l.file.close(io);
    }
};
