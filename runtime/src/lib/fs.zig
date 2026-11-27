//! The fs library: directory listing, file type queries, copying, moving,
//! removal, directory and link creation, and the `fs.path` helpers. Every
//! operation that touches the file system checks `fs:read` or `fs:write`
//! for the paths it names, as the legacy C library did. Names read from
//! the file system decode as WTF-8 on Windows and as UTF-8 with lossy
//! replacement elsewhere (spec/design/strings.md).

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const pledge = @import("../vm/pledge.zig");
const aux = @import("auxlib.zig");
const os = @import("os.zig");
const walk = @import("walk.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Dir = std.Io.Dir;

const windows = builtin.os.tag == .windows;
const sep: u8 = if (windows) '\\' else '/';
const sep_str: []const u8 = if (windows) "\\" else "/";
const delimiter: []const u8 = if (windows) ";" else ":";

pub const funcs = [_]aux.Reg{
    .{ .name = "list", .func = list },
    .{ .name = "copy", .func = copy },
    .{ .name = "move", .func = move },
    .{ .name = "remove", .func = remove },
    .{ .name = "sync", .func = sync },
    .{ .name = "type", .func = fsType },
    .{ .name = "follow", .func = follow },
    .{ .name = "createlink", .func = createLink },
    .{ .name = "createdirectory", .func = createDirectory },
    .{ .name = "walk", .func = walk.walk },
    .{ .name = "stat", .func = stat },
};

pub const path_funcs = [_]aux.Reg{
    .{ .name = "join", .func = pathJoin },
    .{ .name = "split", .func = pathSplit },
    .{ .name = "name", .func = pathName },
    .{ .name = "parent", .func = pathParent },
};

pub fn open(l: *Thread) Error!void {
    try walk.open(l);
    const t = try aux.newLib(l, .fields, "fs", &funcs);
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    const p = try aux.newLib(l, .fields, "fs.path", &path_funcs);
    try aux.setField(l, t, "path", Value.obj(.table, p));
    try @import("watch.zig").open(l, t);
    try aux.setField(l, p, "separator", try l.newStringValue(sep_str));
    try aux.setField(l, p, "delimiter", try l.newStringValue(delimiter));
    try aux.setGlobal(l, "fs", Value.obj(.table, t));
}

/// The C library text for a file system error, as `strerror` gives it.
fn errMsg(e: anyerror) []const u8 {
    return os.errnoOf(e).msg;
}

// ---------------------------------------------------------------------
// fs.path

fn isSep(c: u8) bool {
    return c == '/' or (windows and c == '\\');
}

fn isAbsolute(p: []const u8) bool {
    if (p.len == 0) return false;
    if (isSep(p[0])) return true;
    if (windows and p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSep(p[2])) return true;
    return false;
}

fn lastSep(p: []const u8) ?usize {
    var i = p.len;
    while (i > 0) {
        i -= 1;
        if (isSep(p[i])) return i;
    }
    return null;
}

fn pathJoin(l: *Thread) Error!u32 {
    const n = l.argCount();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const s = try aux.checkBytes(l, i);
        // Empty components are skipped.
        if (s.len == 0) continue;
        // An absolute component replaces everything before it.
        if (isAbsolute(s)) buf.clearRetainingCapacity();
        if (buf.items.len > 0 and !isSep(buf.items[buf.items.len - 1]) and !isSep(s[0]))
            buf.append(l.g.gpa, sep) catch return l.raiseMem();
        buf.appendSlice(l.g.gpa, s) catch return l.raiseMem();
    }
    return aux.retStr(l, buf.items);
}

fn pathSplit(l: *Thread) Error!u32 {
    const p = try aux.checkBytes(l, 1);
    const t = try l.newTable(0, 0);
    try l.push(Value.obj(.table, t));
    var idx: i64 = 1;
    var start: usize = 0;
    for (p, 0..) |c, i| {
        if (isSep(c)) {
            try ops.rawSet(l, t, Value.int(idx), try l.newStringValue(p[start..i]));
            idx += 1;
            start = i + 1;
        }
    }
    if (p.len > start) try ops.rawSet(l, t, Value.int(idx), try l.newStringValue(p[start..]));
    return 1;
}

fn pathName(l: *Thread) Error!u32 {
    const p = try aux.checkBytes(l, 1);
    if (lastSep(p)) |i| return aux.retStr(l, p[i + 1 ..]);
    return aux.retStr(l, p);
}

fn pathParent(l: *Thread) Error!u32 {
    const p = try aux.checkBytes(l, 1);
    if (lastSep(p)) |i| {
        // The parent of a top-level entry is the root itself.
        if (i == 0) return aux.retStr(l, p[0..1]);
        return aux.retStr(l, p[0..i]);
    }
    return aux.retStr(l, ".");
}

// ---------------------------------------------------------------------
// fs operations

fn list(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const glob = try aux.optString(l, 2, null);
    try pledge.require(l, "fs:read", path);
    var filter: ?walk.Filter = null;
    if (glob) |g| {
        filter = try walk.compileFilter(l, l.g.gpa, g);
        if (filter.?.g.deep) return walk.listDeep(l, path, filter.?);
    }
    defer if (filter) |*f| f.g.deinit();
    const io = l.g.io;
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => return l.raiseFmt("{s} is not a directory", .{path}),
        else => return l.raiseFmt("cannot list directory {s}: {s}", .{ path, errMsg(e) }),
    };
    defer dir.close(io);
    const t = try l.newTable(0, 0);
    try l.push(Value.obj(.table, t));
    var idx: i64 = 1;
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |e| return l.raiseFmt("cannot list directory {s}: {s}", .{ path, errMsg(e) });
        const ent = entry orelse break;
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        if (filter) |*f| if (!f.g.match(ent.name)) continue;
        try ops.rawSet(l, t, Value.int(idx), try os.lossyString(l, ent.name));
        idx += 1;
    }
    return 1;
}

fn copy(l: *Thread) Error!u32 {
    const src = try aux.checkBytes(l, 1);
    const dst = try aux.checkBytes(l, 2);
    try pledge.require(l, "fs:read", src);
    try pledge.require(l, "fs:write", dst);
    const io = l.g.io;
    const cwd = Dir.cwd();
    const in = cwd.openFile(io, src, .{}) catch |e|
        return l.raiseFmt("cannot open source '{s}': {s}", .{ src, errMsg(e) });
    defer in.close(io);
    const outf = cwd.createFile(io, dst, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return l.raiseFmt("target '{s}' already exists", .{dst}),
        else => return l.raiseFmt("cannot create target '{s}': {s}", .{ dst, errMsg(e) }),
    };
    var failed: ?anyerror = null;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var bufs = [_][]u8{&buf};
        const n = in.readStreaming(io, &bufs) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => {
                failed = e;
                break;
            },
        };
        if (n == 0) break;
        outf.writeStreamingAll(io, buf[0..n]) catch |e| {
            failed = e;
            break;
        };
    }
    outf.close(io);
    if (failed) |e| {
        // A partial copy is removed so failures leave nothing behind.
        cwd.deleteFile(io, dst) catch {};
        return l.raiseFmt("error copying '{s}' to '{s}': {s}", .{ src, dst, errMsg(e) });
    }
    return 0;
}

fn exists(l: *Thread, path: []const u8) bool {
    _ = Dir.cwd().statFile(l.g.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isDir(l: *Thread, path: []const u8) bool {
    const st = Dir.cwd().statFile(l.g.io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .directory;
}

/// A link keeps its text when it moves, and the system resolves a
/// relative text from the new directory. The place it then names needs
/// the permission that creating the link there would need.
fn checkMovedLink(l: *Thread, src: []const u8, dst: []const u8) Error!void {
    const cwd = Dir.cwd();
    const st = cwd.statFile(l.g.io, src, .{ .follow_symlinks = false }) catch return;
    if (st.kind != .sym_link) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.readLink(l.g.io, src, &buf) catch return;
    const target = buf[0..n];
    if (std.fs.path.isAbsolute(target)) return pledge.require(l, "fs:write", target);
    const dir = std.fs.path.dirname(dst) orelse ".";
    const from_link = std.fs.path.join(l.g.gpa, &.{ dir, target }) catch return l.raiseMem();
    defer l.g.gpa.free(from_link);
    if (!pledge.allowed(l, "fs:write", from_link)) return l.raiseFmt("permission \"fs:write\" denied for '{s}'", .{target});
}

fn move(l: *Thread) Error!u32 {
    const src = withoutTrailingSeparators(try aux.checkBytes(l, 1));
    const dst = withoutTrailingSeparators(try aux.checkBytes(l, 2));
    // A move renames the entry itself, so a link is checked where it
    // lies and stays a link.
    try pledge.requireNoFollow(l, "fs:read", src);
    try pledge.requireNoFollow(l, "fs:write", src);
    try pledge.requireNoFollow(l, "fs:write", dst);
    try checkMovedLink(l, src, dst);
    var replace = false;
    if (!l.arg(3).isNil()) {
        const opts = try aux.checkTable(l, 3);
        replace = (try aux.getField(l, opts, "replace")).truthy();
    }
    const io = l.g.io;
    const cwd = Dir.cwd();
    if (!exists(l, src)) return l.raiseFmt("cannot move '{s}': source does not exist", .{src});
    if (replace) {
        // One rename, which replaces the target in a single step, so a
        // reader of `dst` sees either the old entry or the new one.
        Dir.rename(cwd, src, cwd, dst, io) catch |e| switch (e) {
            error.CrossDevice => return l.raiseFmt("cannot move '{s}' to '{s}': cross-device move", .{ src, dst }),
            error.IsDir => return l.raiseFmt("cannot move '{s}' to '{s}': target is a directory", .{ src, dst }),
            error.NotDir => return l.raiseFmt("cannot move '{s}' to '{s}': target is not a directory", .{ src, dst }),
            error.DirNotEmpty => return l.raiseFmt("cannot move '{s}' to '{s}': target is a directory that is not empty", .{ src, dst }),
            else => return l.raiseFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errMsg(e) }),
        };
        return 0;
    }
    // Without `replace`, the move never replaces an existing target.
    Dir.renamePreserve(cwd, src, cwd, dst, io) catch |e| switch (e) {
        error.PathAlreadyExists => return l.raiseFmt("cannot move to '{s}': target already exists", .{dst}),
        error.CrossDevice => return l.raiseFmt("cannot move '{s}' to '{s}': cross-device move", .{ src, dst }),
        // A system without an exclusive rename links the source to the
        // target and then removes the source. A hard link to a directory
        // fails with EPERM, so the move checks the target and renames.
        error.OperationUnsupported, error.PermissionDenied => {
            if (e == error.PermissionDenied and !isDir(l, src)) return l.raiseFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errMsg(e) });
            if (exists(l, dst)) return l.raiseFmt("cannot move to '{s}': target already exists", .{dst});
            Dir.rename(cwd, src, cwd, dst, io) catch |e2| switch (e2) {
                error.CrossDevice => return l.raiseFmt("cannot move '{s}' to '{s}': cross-device move", .{ src, dst }),
                else => return l.raiseFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errMsg(e2) }),
            };
        },
        else => return l.raiseFmt("cannot move '{s}' to '{s}': {s}", .{ src, dst, errMsg(e) }),
    };
    return 0;
}

/// fs.sync(path): writes the entries of a directory, or the data of a
/// file, through to the storage device.
fn sync(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    try pledge.require(l, "fs:read", path);
    const io = l.g.io;
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return l.raiseFmt("cannot sync '{s}': path does not exist", .{path}),
        else => return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) }),
    };
    if (st.kind == .directory) {
        // A directory opened for iteration gets a descriptor that can be
        // synced. Linux opens one without iteration with `O_PATH`.
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |e| return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) });
        defer dir.close(io);
        @import("io.zig").syncFile(io, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }) catch |e| switch (e) {
            // Windows opens a directory without write access, and its file
            // systems commit the entries of a directory through their log.
            error.AccessDenied => if (!windows) return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) }),
            else => return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) }),
        };
        return 0;
    }
    // Windows flushes a file only through a handle with write access.
    var file = cwd.openFile(io, path, .{ .mode = if (windows) .read_write else .read_only }) catch |e| return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) });
    defer file.close(io);
    @import("io.zig").syncFile(io, file) catch |e| return l.raiseFmt("cannot sync '{s}': {s}", .{ path, errMsg(e) });
    return 0;
}

/// `path` without its trailing separators. A system call resolves a link
/// whose name ends in a separator, so a native that acts on a link itself
/// passes the name without them, which is also the name its permission
/// check reads.
fn withoutTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or (windows and path[end - 1] == '\\'))) end -= 1;
    return path[0..end];
}

fn remove(l: *Thread) Error!u32 {
    const path = withoutTrailingSeparators(try aux.checkBytes(l, 1));
    const recursive = l.arg(2).truthy();
    try pledge.requireNoFollow(l, "fs:write", path);
    const io = l.g.io;
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return l.raiseFmt("cannot remove '{s}': path does not exist", .{path}),
        else => return l.raiseFmt("cannot remove '{s}': {s}", .{ path, errMsg(e) }),
    };
    if (st.kind == .directory) {
        if (recursive) {
            cwd.deleteTree(io, path) catch |e|
                return l.raiseFmt("failed to remove directory '{s}' recursively: {s}", .{ path, errMsg(e) });
        } else {
            cwd.deleteDir(io, path) catch |e| switch (e) {
                error.DirNotEmpty => return l.raiseFmt("cannot remove directory '{s}': not empty", .{path}),
                else => return l.raiseFmt("cannot remove '{s}': {s}", .{ path, errMsg(e) }),
            };
        }
        return 0;
    }
    cwd.deleteFile(io, path) catch |e| return l.raiseFmt("cannot remove '{s}': {s}", .{ path, errMsg(e) });
    return 0;
}

fn fsType(l: *Thread) Error!u32 {
    const path = withoutTrailingSeparators(try aux.checkBytes(l, 1));
    // The type of a link is read from the link itself.
    try pledge.requireNoFollow(l, "fs:read", path);
    const io = l.g.io;
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return l.raiseFmt("path '{s}' does not exist", .{path}),
        else => return l.raiseFmt("cannot get type of '{s}': {s}", .{ path, errMsg(e) }),
    };
    const is_link = st.kind == .sym_link;
    var kind = st.kind;
    if (is_link) {
        // A link reports the type of its target. A dangling link is a
        // file, and so is a link whose target the script may not read.
        kind = .file;
        if (pledge.allowed(l, "fs:read", path)) {
            if (cwd.statFile(io, path, .{})) |target| kind = target.kind else |_| {}
        }
    }
    try l.push(try l.newStringValue(if (kind == .directory) "directory" else "file"));
    try l.push(Value.boolean(is_link));
    return 2;
}

/// `fs.stat(path [, options])` returns `{size, modified, kind}`.
fn stat(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    var follow_links = true;
    if (!l.arg(2).isNil()) {
        const t = try aux.checkTable(l, 2);
        const f = try aux.getField(l, t, "follow");
        if (!f.isNil()) {
            if (f.tag != .true and f.tag != .false) return aux.argError(l, 2, "option 'follow' must be a boolean", .{});
            follow_links = f.tag == .true;
        }
    }
    if (follow_links) try pledge.require(l, "fs:read", path) else try pledge.requireNoFollow(l, "fs:read", path);
    const st = Dir.cwd().statFile(l.g.io, path, .{ .follow_symlinks = follow_links }) catch |e| switch (e) {
        error.FileNotFound => return l.raiseFmt("path '{s}' does not exist", .{path}),
        else => return l.raiseFmt("cannot stat '{s}': {s}", .{ path, errMsg(e) }),
    };
    const t = try l.newTable(0, 3);
    try l.push(Value.obj(.table, t));
    try aux.setField(l, t, "size", Value.int(@intCast(@min(st.size, std.math.maxInt(i64)))));
    const kind: []const u8 = switch (st.kind) {
        .directory => "directory",
        .file => "file",
        .sym_link => "link",
        else => "other",
    };
    try aux.setField(l, t, "kind", try l.newStringValue(kind));
    const ns: i128 = st.mtime.nanoseconds;
    try @import("time.zig").pushWallInstant(l, @intCast(@divFloor(ns, std.time.ns_per_s)), @intCast(@mod(ns, std.time.ns_per_s)));
    try aux.setField(l, t, "modified", l.stack[l.top - 1]);
    l.top -= 1;
    return 1;
}

fn follow(l: *Thread) Error!u32 {
    const path = withoutTrailingSeparators(try aux.checkBytes(l, 1));
    try pledge.requireNoFollow(l, "fs:read", path);
    const io = l.g.io;
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |e|
        return l.raiseFmt("cannot stat '{s}': {s}", .{ path, errMsg(e) });
    if (st.kind != .sym_link) return l.raiseFmt("'{s}' is not a symbolic link", .{path});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.readLink(io, path, &buf) catch |e| switch (e) {
        error.NameTooLong => return l.raiseFmt("symlink target too long for '{s}'", .{path}),
        else => return l.raiseFmt("cannot read link '{s}': {s}", .{ path, errMsg(e) }),
    };
    return aux.ret(l, try os.lossyString(l, buf[0..n]));
}

fn createLink(l: *Thread) Error!u32 {
    const at = try aux.checkBytes(l, 1);
    const target = try aux.checkBytes(l, 2);
    try pledge.require(l, "fs:write", at);
    // The target is gated too, so a script cannot plant a link that leads
    // outside its writable scope. The system resolves a relative target
    // from the directory of the link, so the check reads it from there.
    if (std.fs.path.isAbsolute(target)) {
        try pledge.require(l, "fs:write", target);
    } else {
        const dir = std.fs.path.dirname(withoutTrailingSeparators(at)) orelse ".";
        const from_link = std.fs.path.join(l.g.gpa, &.{ dir, target }) catch return l.raiseMem();
        defer l.g.gpa.free(from_link);
        if (!pledge.allowed(l, "fs:write", from_link)) return l.raiseFmt("permission \"fs:write\" denied for '{s}'", .{target});
    }
    const io = l.g.io;
    const cwd = Dir.cwd();
    var is_dir = false;
    if (windows) {
        if (cwd.statFile(io, target, .{})) |st| is_dir = st.kind == .directory else |_| {}
    }
    cwd.symLink(io, target, at, .{ .is_directory = is_dir }) catch |e|
        return l.raiseFmt("failed to create symlink '{s}' -> '{s}': {s}", .{ at, target, errMsg(e) });
    return 0;
}

fn createDirectory(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const recursive = l.arg(2).truthy();
    try pledge.require(l, "fs:write", path);
    if (recursive) return createDirs(l, path);
    Dir.cwd().createDir(l.g.io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return l.raiseFmt("cannot create directory '{s}': already exists", .{path}),
        error.FileNotFound => return l.raiseFmt("cannot create directory '{s}': parent does not exist", .{path}),
        error.AccessDenied, error.PermissionDenied => return l.raiseFmt("cannot create directory '{s}': permission denied", .{path}),
        else => return l.raiseFmt("cannot create directory '{s}': {s}", .{ path, errMsg(e) }),
    };
    return 0;
}

/// Creates every missing directory along `path`. Each directory created
/// must itself be writable under the pledge, and `..` components are
/// refused so the walk never leaves the named tree.
fn createDirs(l: *Thread, path: []const u8) Error!u32 {
    if (path.len == 0) return 0;
    const io = l.g.io;
    const cwd = Dir.cwd();
    var it = std.mem.tokenizeAny(u8, path, if (windows) "/\\" else "/");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return l.raiseFmt("cannot create directory '{s}': '..' is denied", .{path});
    }
    it.reset();
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        // The prefix of `path` that ends with this component.
        const end = @intFromPtr(part.ptr) - @intFromPtr(path.ptr) + part.len;
        const prefix = path[0..end];
        if (windows and end == 2 and part[1] == ':') continue;
        const st = cwd.statFile(io, prefix, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                if (!pledge.allowed(l, "fs:write", prefix))
                    return l.raiseFmt("permission \"fs:write\" denied for '{s}'", .{path});
                cwd.createDir(io, prefix, .default_dir) catch |e2| switch (e2) {
                    error.PathAlreadyExists => {},
                    else => return l.raiseFmt("cannot create directory '{s}': {s}", .{ path, errMsg(e2) }),
                };
                continue;
            },
            else => return l.raiseFmt("cannot create directory '{s}': {s}", .{ path, errMsg(e) }),
        };
        if (st.kind != .directory)
            return l.raiseFmt("cannot create directory '{s}': {s}", .{ path, errMsg(error.NotDir) });
    }
    return 0;
}
