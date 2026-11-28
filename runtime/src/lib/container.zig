//! ZIP and tar containers for `vector.archive` (spec/design/archive.md).
//!
//! Each format has `list`, `read`, `pack`, and `unpack`. An archive is a
//! string, a vector, or an open file. A file is read with positional reads
//! from its start, so a large archive streams without loading whole.
//!
//! The readers and writers are written here over the layouts of the ZIP
//! application note and of POSIX ustar and pax, since `std.zip` reads
//! only from a seekable file and `std.tar` hides the fields that `list`
//! reports. Deflate comes from `std.compress.flate` and CRC-32 from
//! `std.hash.Crc32`.
//!
//! `unpack` keeps every write inside the target directory. Entry names
//! with an absolute path, a drive letter, a backslash, a NUL byte, or a
//! `..` component raise. Every directory on the way to an entry is opened
//! without following symbolic links. A symbolic link is created only when
//! its target stays inside. Hard links and special files raise. Sizes are
//! counted from the bytes actually written, against a total and an entry
//! limit, and ZIP entries whose data overlap raise.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const pledge = @import("../vm/pledge.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const iolib = @import("io.zig");
const os = @import("os.zig");
const archive = @import("archive.zig");
const tables = @import("../vm/table.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Dir = std.Io.Dir;
const File = std.Io.File;
const flate = std.compress.flate;
const Crc32 = std.hash.Crc32;

const default_max: u64 = 512 * 1024 * 1024;
const default_entries: u64 = 10_000;
/// The largest central directory, PAX header, or GNU long name read.
const max_meta = 64 * 1024 * 1024;
const max_ext_header = 1024 * 1024;
const max_link = 4096;

const Format = enum { zip, tar };

pub fn register(l: *Thread, t: *Table) Error!void {
    const zip = try l.newTable(0, 4);
    try aux.setField(l, t, "zip", Value.obj(.table, zip));
    try aux.setFuncs(l, zip, .fields, "vector.archive.zip", &.{
        .{ .name = "list", .func = zipList },
        .{ .name = "read", .func = zipRead },
        .{ .name = "pack", .func = zipPack },
        .{ .name = "unpack", .func = zipUnpack },
    });
    const tar = try l.newTable(0, 4);
    try aux.setField(l, t, "tar", Value.obj(.table, tar));
    try aux.setFuncs(l, tar, .fields, "vector.archive.tar", &.{
        .{ .name = "list", .func = tarList },
        .{ .name = "read", .func = tarRead },
        .{ .name = "pack", .func = tarPack },
        .{ .name = "unpack", .func = tarUnpack },
    });
}

fn zipList(l: *Thread) Error!u32 {
    return list(l, .zip);
}
fn tarList(l: *Thread) Error!u32 {
    return list(l, .tar);
}
fn zipRead(l: *Thread) Error!u32 {
    return read(l, .zip);
}
fn tarRead(l: *Thread) Error!u32 {
    return read(l, .tar);
}
fn zipPack(l: *Thread) Error!u32 {
    return pack(l, .zip);
}
fn tarPack(l: *Thread) Error!u32 {
    return pack(l, .tar);
}
fn zipUnpack(l: *Thread) Error!u32 {
    return unpack(l, .zip);
}
fn tarUnpack(l: *Thread) Error!u32 {
    return unpack(l, .tar);
}

// ---------------------------------------------------------------------
// Entry names

/// Writes the normalized form of an entry name into `out`: its components
/// joined by `/`, without empty and `.` components. A name that could
/// reach outside the target directory is unsafe. An empty result names
/// the target directory itself.
fn normalize(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) error{ Unsafe, OutOfMemory }!void {
    out.clearRetainingCapacity();
    if (name.len == 0 or name[0] == '/') return error.Unsafe;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return error.Unsafe;
    if (std.mem.indexOfAny(u8, name, "\\\x00") != null) return error.Unsafe;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) return error.Unsafe;
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, c);
    }
}

/// True when a symbolic link at the normalized path `link` with target
/// `target` resolves inside the target directory: the target is relative,
/// its `..` components all come first, and they climb no higher than the
/// directory that holds the link. Names after the climb then only descend.
fn linkStaysInside(link: []const u8, target: []const u8) bool {
    if (target.len == 0 or target[0] == '/') return false;
    if (target.len >= 2 and std.ascii.isAlphabetic(target[0]) and target[1] == ':') return false;
    if (std.mem.indexOfAny(u8, target, "\\\x00") != null) return false;
    const depth = std.mem.count(u8, link, "/");
    var ups: usize = 0;
    var descending = false;
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (descending) return false;
            ups += 1;
            if (ups > depth) return false;
        } else descending = true;
    }
    return true;
}

fn unsafeName(l: *Thread, name: []const u8) Error {
    return l.raiseFmt("unsafe entry name '{s}'", .{name});
}

// ---------------------------------------------------------------------
// Sources

/// The bytes of an archive: a string or vector in memory, or an open file
/// read with positional reads.
const Source = struct {
    bytes: []const u8 = "",
    file: ?File = null,
    len: u64,
    io: std.Io,

    fn readRaw(s: *const Source, off: u64, buf: []u8) error{ Truncated, ReadFailed }!void {
        if (off > s.len or buf.len > s.len - off) return error.Truncated;
        if (s.file) |f| {
            const n = f.readPositionalAll(s.io, buf, off) catch return error.ReadFailed;
            if (n != buf.len) return error.Truncated;
        } else {
            @memcpy(buf, s.bytes[@intCast(off)..][0..buf.len]);
        }
    }

    fn readAt(s: *const Source, l: *Thread, off: u64, buf: []u8) Error!void {
        s.readRaw(off, buf) catch |e| return switch (e) {
            error.Truncated => l.raiseFmt("truncated archive", .{}),
            error.ReadFailed => l.raiseFmt("cannot read archive", .{}),
        };
    }

    /// Reads `n` bytes at `off` into a new allocation.
    fn alloc(s: *const Source, l: *Thread, gpa: std.mem.Allocator, off: u64, n: u64) Error![]u8 {
        if (off > s.len or n > s.len - off) return l.raiseFmt("truncated archive", .{});
        const buf = gpa.alloc(u8, @intCast(n)) catch return l.raiseMem();
        errdefer gpa.free(buf);
        try s.readAt(l, off, buf);
        return buf;
    }
};

fn checkSource(l: *Thread, i: u32) Error!Source {
    const v = l.arg(i);
    if (iolib.toHandle(l, v)) |h| {
        if (h.closed) return l.raiseFmt("attempt to use a closed file", .{});
        if (!h.readable) return aux.argError(l, i, "file is not readable", .{});
        const len = h.file.length(l.g.io) catch |e| return l.raiseFmt("cannot read archive ({s})", .{os.errnoOf(e).msg});
        return .{ .file = h.file, .len = len, .io = l.g.io };
    }
    if (v.tag != .string and v.tag != .vector and !v.isNumber()) return aux.typeError(l, i, "string, vector, or file");
    const b = try vector.checkData(l, i);
    return .{ .bytes = b, .len = b.len, .io = l.g.io };
}

// ---------------------------------------------------------------------
// Entries

const Kind = enum {
    file,
    directory,
    symlink,
    link,
    special,
};

/// One entry of either format. Names and targets are valid text, read
/// lossily from the archive's bytes.
const Entry = struct {
    name: []const u8,
    kind: Kind,
    size: u64,
    mode: u32,
    mtime: i64,
    target: []const u8 = "",
    // ZIP fields.
    method: u16 = 0,
    flags: u16 = 0,
    crc: u32 = 0,
    compressed: u64 = 0,
    /// The local header of a ZIP entry, or the data of a tar entry.
    offset: u64 = 0,
    /// The name as stored, which the ZIP local header must repeat.
    raw_name: []const u8 = "",
};

fn lossy(l: *Thread, arena: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    wtf8.appendLossy(arena, &out, bytes) catch return l.raiseMem();
    return out.items;
}

/// The entries of an archive, read into `arena`.
fn entriesOf(l: *Thread, arena: std.mem.Allocator, src: *const Source, format: Format) Error![]Entry {
    return switch (format) {
        .zip => zipEntries(l, arena, src),
        .tar => tarEntries(l, arena, src),
    };
}

const kind_names = [_][]const u8{ "file", "directory", "symlink", "link", "special" };

fn list(l: *Thread, format: Format) Error!u32 {
    const src = try checkSource(l, 1);
    var arena_state = std.heap.ArenaAllocator.init(l.g.gpa);
    defer arena_state.deinit();
    const entries = try entriesOf(l, arena_state.allocator(), &src, format);
    const t = try l.newTable(@intCast(entries.len), 0);
    try l.push(Value.obj(.table, t));
    for (entries, 1..) |e, i| {
        const r = try l.newTable(0, 8);
        try ops.rawSet(l, t, Value.int(@intCast(i)), Value.obj(.table, r));
        try aux.setField(l, r, "name", try l.newStringValue(e.name));
        try aux.setField(l, r, "kind", try l.newStringValue(kind_names[@backingInt(e.kind)]));
        try aux.setField(l, r, "size", Value.int(if (e.kind == .symlink) 0 else @intCast(@min(e.size, std.math.maxInt(i64)))));
        try aux.setField(l, r, "mode", Value.int(e.mode));
        try aux.setField(l, r, "mtime", Value.int(e.mtime));
        if (e.kind == .symlink or e.kind == .link) try aux.setField(l, r, "target", try l.newStringValue(e.target));
        if (format == .zip) {
            try aux.setField(l, r, "method", try l.newStringValue(if (e.method == 0) "store" else "deflate"));
            try aux.setField(l, r, "compressed", Value.int(@intCast(@min(e.compressed, std.math.maxInt(i64)))));
        }
    }
    return 1;
}

/// A limit on the bytes an operation writes, counted as they are written.
const Budget = struct {
    left: u64,
    max: u64,

    fn take(b: *Budget, l: *Thread, n: usize) Error!void {
        if (n > b.left) return l.raiseFmt("archive exceeds size limit ({d} bytes)", .{b.max});
        b.left -= n;
    }
};

/// Where extracted bytes go: memory for `read`, a file for `unpack`.
const Sink = struct {
    list: ?*std.ArrayList(u8) = null,
    file: ?File = null,
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8 = "",

    fn write(s: *Sink, l: *Thread, bytes: []const u8) Error!void {
        if (s.list) |li| {
            li.appendSlice(s.gpa, bytes) catch return l.raiseMem();
        } else {
            s.file.?.writeStreamingAll(s.io, bytes) catch return l.raiseFmt("cannot write '{s}'", .{s.path});
        }
    }
};

/// Writes the contents of a file or symlink entry to `sink`, checking its
/// size and, for ZIP, its CRC-32.
fn extract(l: *Thread, src: *const Source, format: Format, e: *const Entry, sink: *Sink, budget: *Budget) Error!void {
    switch (format) {
        .tar => {
            var off = e.offset;
            var left = e.size;
            var buf: [64 * 1024]u8 = undefined;
            while (left > 0) {
                const n: usize = @intCast(@min(left, buf.len));
                try src.readAt(l, off, buf[0..n]);
                try budget.take(l, n);
                try sink.write(l, buf[0..n]);
                off += n;
                left -= n;
            }
        },
        .zip => try zipExtract(l, src, e, sink, budget),
    }
}

/// The options table at argument `i`: `max` bytes, `entries`, and
/// `overwrite`.
const Options = struct { max: u64 = default_max, entries: u64 = default_entries, overwrite: bool = false };

fn checkOptions(l: *Thread, i: u32) Error!Options {
    var o: Options = .{};
    if (l.arg(i).isNil()) return o;
    const t = try aux.checkTable(l, i);
    inline for (.{ "max", "entries" }) |f| {
        const v = try aux.getField(l, t, f);
        if (!v.isNil()) {
            const n = (if (v.isNumber()) ops.toIntegerStrict(v) else null) orelse return aux.argError(l, i, "option '" ++ f ++ "' must be an integer", .{});
            if (n <= 0) return aux.argError(l, i, "option '" ++ f ++ "' out of range", .{});
            @field(o, f) = @intCast(n);
        }
    }
    o.overwrite = (try aux.getField(l, t, "overwrite")).truthy();
    return o;
}

fn read(l: *Thread, format: Format) Error!u32 {
    const src = try checkSource(l, 1);
    const want_raw = try aux.checkBytes(l, 2);
    const max_arg = try aux.optInt(l, 3, 0);
    const max: u64 = if (max_arg > 0) @intCast(max_arg) else default_max;
    const gpa = l.g.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var want: std.ArrayList(u8) = .empty;
    normalize(arena, &want, want_raw) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.Unsafe => return unsafeName(l, want_raw),
    };
    const entries = try entriesOf(l, arena, &src, format);
    var norm: std.ArrayList(u8) = .empty;
    for (entries) |*e| {
        normalize(arena, &norm, e.name) catch |err| switch (err) {
            error.OutOfMemory => return l.raiseMem(),
            error.Unsafe => continue,
        };
        if (!std.mem.eql(u8, norm.items, want.items)) continue;
        if (e.kind != .file) return l.raiseFmt("'{s}' is not a file", .{e.name});
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var sink: Sink = .{ .list = &out, .gpa = gpa, .io = l.g.io };
        var budget: Budget = .{ .left = max, .max = max };
        try extract(l, &src, format, e, &sink, &budget);
        return aux.ret(l, Value.obj(.vector, try vector.newVectorFrom(l, &out)));
    }
    return aux.ret(l, .nil);
}

// ---------------------------------------------------------------------
// Unpacking

fn filePermissions(executable: bool) File.Permissions {
    if (comptime @hasDecl(File.Permissions, "fromMode")) {
        return .fromMode(if (executable) 0o755 else 0o644);
    }
    return .default_file;
}

fn dirPermissions() File.Permissions {
    if (comptime @hasDecl(File.Permissions, "fromMode")) return .fromMode(0o755);
    return .default_dir;
}

/// Opens the directory `name` in `parent` without following a symbolic
/// link, creating it when it does not exist.
fn enterDir(l: *Thread, io: std.Io, parent: Dir, name: []const u8, path: []const u8) Error!Dir {
    var created = false;
    while (true) {
        if (parent.openDir(io, name, .{ .follow_symlinks = false })) |d| {
            return d;
        } else |e| switch (e) {
            error.FileNotFound => if (!created) {
                parent.createDir(io, name, dirPermissions()) catch |e2| switch (e2) {
                    error.PathAlreadyExists => {},
                    else => return l.raiseFmt("cannot create '{s}' ({s})", .{ path, os.errnoOf(e2).msg }),
                };
                created = true;
                continue;
            } else return l.raiseFmt("cannot create '{s}'", .{path}),
            error.NotDir, error.SymLinkLoop => return l.raiseFmt("cannot write '{s}' (a parent is a symlink or a file)", .{path}),
            else => return l.raiseFmt("cannot open '{s}' ({s})", .{ path, os.errnoOf(e).msg }),
        }
    }
}

fn unpack(l: *Thread, format: Format) Error!u32 {
    const src = try checkSource(l, 1);
    const root_path = try aux.checkBytes(l, 2);
    const opts = try checkOptions(l, 3);
    const gpa = l.g.gpa;
    const io = l.g.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try entriesOf(l, arena, &src, format);
    if (entries.len > opts.entries) return l.raiseFmt("archive exceeds entry limit ({d} entries)", .{opts.entries});
    if (format == .zip) try zipCheckLayout(l, arena, &src, entries);

    var budget: Budget = .{ .left = opts.max, .max = opts.max };

    // Check every name, type, and link target before writing anything, so
    // that a hostile archive leaves the target untouched.
    const names = arena.alloc([]const u8, entries.len) catch return l.raiseMem();
    const targets = arena.alloc([]const u8, entries.len) catch return l.raiseMem();
    var norm: std.ArrayList(u8) = .empty;
    for (entries, names, targets) |*e, *name, *target| {
        normalize(arena, &norm, e.name) catch |err| switch (err) {
            error.OutOfMemory => return l.raiseMem(),
            error.Unsafe => return unsafeName(l, e.name),
        };
        if (norm.items.len == 0 and e.kind != .directory) return unsafeName(l, e.name);
        switch (e.kind) {
            .link, .special => return l.raiseFmt("unsupported entry type '{s}' for '{s}'", .{ kind_names[@backingInt(e.kind)], e.name }),
            else => {},
        }
        name.* = arena.dupe(u8, norm.items) catch return l.raiseMem();
        target.* = e.target;
        if (e.kind == .symlink) {
            if (format == .zip) {
                // A ZIP symlink stores its target as the entry's data.
                if (e.size > max_link) return l.raiseFmt("symlink '{s}' points outside the target directory", .{e.name});
                var out: std.ArrayList(u8) = .empty;
                var sink: Sink = .{ .list = &out, .gpa = arena, .io = io };
                try zipExtract(l, &src, e, &sink, &budget);
                target.* = try lossy(l, arena, out.items);
            }
            if (!linkStaysInside(name.*, target.*)) return l.raiseFmt("symlink '{s}' points outside the target directory", .{e.name});
        }
    }

    try pledge.require(l, "fs:write", root_path);
    Dir.cwd().createDirPath(io, root_path) catch |e| return l.raiseFmt("cannot create '{s}' ({s})", .{ root_path, os.errnoOf(e).msg });
    var root = Dir.cwd().openDir(io, root_path, .{}) catch |e| return l.raiseFmt("cannot open '{s}' ({s})", .{ root_path, os.errnoOf(e).msg });
    defer root.close(io);

    var full: std.ArrayList(u8) = .empty;
    var written: u32 = 0;
    for (entries, names, targets) |*e, rel, target| {
        if (rel.len == 0) continue;
        full.clearRetainingCapacity();
        full.print(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, root_path, "/"), rel }) catch return l.raiseMem();
        try pledge.require(l, "fs:write", full.items);

        // Walk the parent directories, then create the last component.
        var dir = root;
        var owned = false;
        defer if (owned) dir.close(io);
        var leaf = rel;
        while (std.mem.indexOfScalar(u8, leaf, '/')) |slash| {
            const next = try enterDir(l, io, dir, leaf[0..slash], full.items);
            if (owned) dir.close(io);
            dir = next;
            owned = true;
            leaf = leaf[slash + 1 ..];
        }
        switch (e.kind) {
            .directory => {
                const d = try enterDir(l, io, dir, leaf, full.items);
                d.close(io);
            },
            .symlink => {
                if (opts.overwrite) dir.deleteFile(io, leaf) catch {};
                dir.symLink(io, target, leaf, .{}) catch |err| switch (err) {
                    error.PathAlreadyExists => return l.raiseFmt("file exists: {s}", .{full.items}),
                    else => return l.raiseFmt("cannot create '{s}' ({s})", .{ full.items, os.errnoOf(err).msg }),
                };
            },
            .file => {
                const perm = filePermissions(e.mode & 0o111 != 0);
                var f = dir.createFile(io, leaf, .{ .exclusive = true, .permissions = perm }) catch |err| blk: switch (err) {
                    error.PathAlreadyExists => {
                        if (!opts.overwrite) return l.raiseFmt("file exists: {s}", .{full.items});
                        // Remove what is there, a file or a link, never
                        // following it, then create the file afresh.
                        dir.deleteFile(io, leaf) catch |e2| switch (e2) {
                            error.IsDir => return l.raiseFmt("'{s}' is a directory", .{full.items}),
                            else => return l.raiseFmt("cannot replace '{s}' ({s})", .{ full.items, os.errnoOf(e2).msg }),
                        };
                        break :blk dir.createFile(io, leaf, .{ .exclusive = true, .permissions = perm }) catch |e3|
                            return l.raiseFmt("cannot create '{s}' ({s})", .{ full.items, os.errnoOf(e3).msg });
                    },
                    else => return l.raiseFmt("cannot create '{s}' ({s})", .{ full.items, os.errnoOf(err).msg }),
                };
                defer f.close(io);
                var sink: Sink = .{ .file = f, .gpa = gpa, .io = io, .path = full.items };
                try extract(l, &src, format, e, &sink, &budget);
            },
            .link, .special => unreachable,
        }
        written += 1;
    }
    return aux.ret(l, Value.int(written));
}

// ---------------------------------------------------------------------
// Packing

const PackEntry = struct {
    name: []const u8,
    kind: Kind,
    data: []const u8 = "",
    target: []const u8 = "",
    mode: u32,
    mtime: i64,
    deflate: bool,
};

fn fieldString(l: *Thread, t: *Table, name: []const u8, i: usize) Error!?[]const u8 {
    const v = try aux.getField(l, t, name);
    if (v.isNil()) return null;
    if (v.tag != .string) return l.raiseFmt("bad entry #{d} to 'pack' (field '{s}' must be a string)", .{ i, name });
    return v.as(object.String).bytes();
}

fn fieldInt(l: *Thread, t: *Table, name: []const u8, i: usize) Error!?i64 {
    const v = try aux.getField(l, t, name);
    if (v.isNil()) return null;
    return (if (v.isNumber()) ops.toIntegerStrict(v) else null) orelse
        l.raiseFmt("bad entry #{d} to 'pack' (field '{s}' must be an integer)", .{ i, name });
}

fn checkMethod(l: *Thread, s: []const u8, i: usize) Error!bool {
    if (std.mem.eql(u8, s, "deflate")) return true;
    if (std.mem.eql(u8, s, "store")) return false;
    return l.raiseFmt("bad entry #{d} to 'pack' (invalid method '{s}')", .{ i, s });
}

fn pack(l: *Thread, format: Format) Error!u32 {
    const entries_t = try aux.checkTable(l, 1);
    var default_deflate = true;
    var level: u4 = 6;
    if (!l.arg(2).isNil()) {
        const o = try aux.checkTable(l, 2);
        if (try fieldString(l, o, "method", 0)) |m| default_deflate = try checkMethod(l, m, 0);
        if (try fieldInt(l, o, "level", 0)) |lv| {
            if (lv < 0 or lv > 9) return aux.argError(l, 2, "compression level must be 0-9", .{});
            level = @intCast(lv);
        }
    }
    const gpa = l.g.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayList(PackEntry) = .empty;
    const n: usize = @intCast(@max(tables.length(entries_t), 0));
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const ev = tables.getInt(entries_t, @intCast(i));
        if (ev.tag != .table) return l.raiseFmt("bad entry #{d} to 'pack' (table expected)", .{i});
        const et = ev.as(Table);
        const raw = (try fieldString(l, et, "name", i)) orelse return l.raiseFmt("bad entry #{d} to 'pack' (field 'name' missing)", .{i});
        var norm: std.ArrayList(u8) = .empty;
        normalize(arena, &norm, raw) catch |e| switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.Unsafe => return unsafeName(l, raw),
        };
        if (norm.items.len == 0) return unsafeName(l, raw);
        const kind_s = (try fieldString(l, et, "kind", i)) orelse if (raw[raw.len - 1] == '/') "directory" else "file";
        const kind: Kind = if (std.mem.eql(u8, kind_s, "file")) .file else if (std.mem.eql(u8, kind_s, "directory")) .directory else if (std.mem.eql(u8, kind_s, "symlink")) .symlink else return l.raiseFmt("bad entry #{d} to 'pack' (invalid kind '{s}')", .{ i, kind_s });
        var e: PackEntry = .{
            .name = norm.items,
            .kind = kind,
            .mode = if (kind == .directory) 0o755 else if (kind == .symlink) 0o777 else 0o644,
            .mtime = (try fieldInt(l, et, "mtime", i)) orelse 0,
            .deflate = default_deflate,
        };
        if (try fieldInt(l, et, "mode", i)) |m| {
            if (m < 0 or m > 0o7777) return l.raiseFmt("bad entry #{d} to 'pack' (field 'mode' out of range)", .{i});
            e.mode = @intCast(m);
        }
        if (try fieldString(l, et, "method", i)) |m| e.deflate = try checkMethod(l, m, i);
        switch (kind) {
            .file => {
                const dv = try aux.getField(l, et, "data");
                if (dv.tag == .vector) {
                    e.data = dv.as(object.Vector).bytes.items;
                } else if (dv.tag == .string) {
                    e.data = dv.as(object.String).bytes();
                } else if (!dv.isNil()) {
                    return l.raiseFmt("bad entry #{d} to 'pack' (field 'data' must be a string or vector)", .{i});
                }
            },
            .symlink => {
                e.target = (try fieldString(l, et, "target", i)) orelse return l.raiseFmt("bad entry #{d} to 'pack' (field 'target' missing)", .{i});
                if (e.target.len == 0 or e.target.len > max_link or std.mem.indexOfScalar(u8, e.target, 0) != null)
                    return l.raiseFmt("bad entry #{d} to 'pack' (invalid symlink target)", .{i});
            },
            else => {},
        }
        items.append(arena, e) catch return l.raiseMem();
    }

    // A zip header holds the length of a name in 16 bits, with the slash
    // that ends the name of a directory.
    if (format == .zip) for (items.items, 1..) |e, at| {
        if (e.name.len + 1 > std.math.maxInt(u16)) return l.raiseFmt("bad entry #{d} to 'pack' (the name is too long for a zip archive)", .{at});
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const ok = switch (format) {
        .zip => zipWrite(&out.writer, arena, items.items, level, .{}),
        .tar => tarWrite(&out.writer, arena, items.items),
    };
    ok catch return l.raiseMem();
    var bytes = out.toArrayList();
    defer bytes.deinit(gpa);
    return aux.ret(l, Value.obj(.vector, try vector.newVectorFrom(l, &bytes)));
}

// ---------------------------------------------------------------------
// ZIP (PKWARE APPNOTE 6.3)

const sig_local = 0x04034b50;
const sig_central = 0x02014b50;
const sig_end = 0x06054b50;
const sig_end64 = 0x06064b50;
const sig_locator64 = 0x07064b50;
const flag_encrypted = 1;
const flag_utf8 = 1 << 11;
const s_ifmt = 0o170000;
const s_ifdir = 0o040000;
const s_iflnk = 0o120000;
const s_ifreg = 0o100000;

fn rd16(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], .little);
}
fn rd32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}
fn rd64(b: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, b[i..][0..8], .little);
}

fn badZip(l: *Thread, comptime why: []const u8) Error {
    return l.raiseFmt("invalid ZIP archive (" ++ why ++ ")", .{});
}

/// Days from 1970-01-01 to a civil date (proleptic Gregorian).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const dos_epoch: i64 = 315532800;

fn fromDosTime(date: u16, time: u16) i64 {
    const month: i64 = (date >> 5) & 15;
    const day: i64 = date & 31;
    if (month < 1 or month > 12 or day < 1) return dos_epoch;
    const days = daysFromCivil(1980 + @as(i64, date >> 9), month, day);
    return days * 86400 + @as(i64, time >> 11) * 3600 + @as(i64, (time >> 5) & 63) * 60 + @as(i64, time & 31) * 2;
}

fn toDosTime(t_in: i64) struct { date: u16, time: u16 } {
    const max: i64 = daysFromCivil(2107, 12, 31) * 86400 + 86398;
    const t = std.math.clamp(t_in, dos_epoch, max);
    const days = @divFloor(t, 86400);
    const secs = t - days * 86400;
    // Civil date from days (inverse of daysFromCivil).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{
        .date = @intCast(((y - 1980) << 9) | (m << 5) | d),
        .time = @intCast((@divFloor(secs, 3600) << 11) | (@mod(@divFloor(secs, 60), 60) << 5) | @divFloor(@mod(secs, 60), 2)),
    };
}

const End = struct { count: u64, cd_size: u64, cd_off: u64, end_off: u64 };

fn zipEnd(l: *Thread, src: *const Source) Error!End {
    const tail_len: usize = @intCast(@min(src.len, 22 + 65535));
    if (tail_len < 22) return badZip(l, "no end of central directory");
    var buf: [22 + 65535]u8 = undefined;
    const tail = buf[0..tail_len];
    const tail_off = src.len - tail_len;
    try src.readAt(l, tail_off, tail);
    var at: usize = tail_len - 22;
    while (true) : (at -= 1) {
        if (rd32(tail, at) == sig_end and at + 22 + rd16(tail, at + 20) == tail_len) break;
        if (at == 0) return badZip(l, "no end of central directory");
    }
    const e = tail[at..];
    var end: End = .{ .count = rd16(e, 10), .cd_size = rd32(e, 12), .cd_off = rd32(e, 16), .end_off = tail_off + at };
    if (rd16(e, 4) != 0 and rd16(e, 4) != 0xffff) return badZip(l, "multiple disks");
    if (end.count == 0xffff or end.cd_size == 0xffffffff or end.cd_off == 0xffffffff) {
        if (end.end_off < 20) return badZip(l, "missing ZIP64 locator");
        var loc: [20]u8 = undefined;
        try src.readAt(l, end.end_off - 20, &loc);
        if (rd32(&loc, 0) != sig_locator64) return badZip(l, "missing ZIP64 locator");
        const off64 = rd64(&loc, 8);
        var rec: [56]u8 = undefined;
        if (off64 > end.end_off - 20) return badZip(l, "bad ZIP64 record");
        try src.readAt(l, off64, &rec);
        if (rd32(&rec, 0) != sig_end64) return badZip(l, "bad ZIP64 record");
        end.count = rd64(&rec, 32);
        end.cd_size = rd64(&rec, 40);
        end.cd_off = rd64(&rec, 48);
        end.end_off = off64;
    }
    if (end.cd_off > end.end_off or end.cd_size > end.end_off - end.cd_off) return badZip(l, "central directory out of bounds");
    if (end.cd_size > max_meta) return badZip(l, "central directory too large");
    return end;
}

fn zipEntries(l: *Thread, arena: std.mem.Allocator, src: *const Source) Error![]Entry {
    const end = try zipEnd(l, src);
    const cd = try src.alloc(l, arena, end.cd_off, end.cd_size);
    if (end.count > cd.len / 46) return badZip(l, "entry count exceeds central directory");
    const out = arena.alloc(Entry, @intCast(end.count)) catch return l.raiseMem();
    var p: usize = 0;
    for (out) |*e| {
        if (cd.len - p < 46 or rd32(cd, p) != sig_central) return badZip(l, "bad central directory header");
        const h = cd[p..];
        const made_by = rd16(h, 4);
        const name_len = rd16(h, 28);
        const extra_len = rd16(h, 30);
        const comment_len = rd16(h, 32);
        const var_len = @as(usize, name_len) + extra_len + comment_len;
        if (h.len - 46 < var_len) return badZip(l, "bad central directory header");
        const raw_name = h[46..][0..name_len];
        const extra = h[46 + name_len ..][0..extra_len];
        e.* = .{
            .name = try lossy(l, arena, raw_name),
            .raw_name = raw_name,
            .kind = .file,
            .flags = rd16(h, 8),
            .method = rd16(h, 10),
            .mtime = fromDosTime(rd16(h, 14), rd16(h, 12)),
            .crc = rd32(h, 16),
            .compressed = rd32(h, 20),
            .size = rd32(h, 24),
            .offset = rd32(h, 42),
            .mode = 0,
        };
        // Extra fields: ZIP64 sizes and offset, and the Unix timestamp.
        var x: usize = 0;
        while (extra.len - x >= 4) {
            const id = rd16(extra, x);
            const len = rd16(extra, x + 2);
            if (extra.len - x - 4 < len) break;
            const body = extra[x + 4 ..][0..len];
            if (id == 0x0001) {
                var q: usize = 0;
                inline for (.{ "size", "compressed", "offset" }) |f| {
                    if (@field(e, f) == 0xffffffff) {
                        if (body.len - q < 8) return badZip(l, "bad ZIP64 extra field");
                        @field(e, f) = rd64(body, q);
                        q += 8;
                    }
                }
            } else if (id == 0x5455 and len >= 5 and body[0] & 1 != 0) {
                e.mtime = std.mem.readInt(i32, body[1..5], .little);
            }
            x += 4 + len;
        }
        const ext_attr = rd32(h, 38);
        const unix_mode: u32 = if (made_by >> 8 == 3) ext_attr >> 16 else 0;
        const is_dir = (raw_name.len > 0 and raw_name[raw_name.len - 1] == '/') or (unix_mode & s_ifmt == s_ifdir) or (unix_mode == 0 and ext_attr & 0x10 != 0);
        if (is_dir) {
            e.kind = .directory;
        } else if (unix_mode & s_ifmt == s_iflnk) {
            e.kind = .symlink;
        }
        e.mode = if (unix_mode != 0) unix_mode & 0o7777 else if (e.kind == .directory) 0o755 else 0o644;
        p += 46 + var_len;
    }
    // A symlink's target is its data, read on demand by unpack and listed
    // here only for small archives held in memory.
    for (out) |*e| {
        if (e.kind == .symlink and e.method == 0 and e.size <= max_link and e.flags & flag_encrypted == 0) {
            const data_off = localDataOffset(src, e) catch continue;
            var t: [max_link]u8 = undefined;
            src.readRaw(data_off, t[0..@intCast(e.size)]) catch continue;
            e.target = try lossy(l, arena, t[0..@intCast(e.size)]);
        }
    }
    return out;
}

const LocalError = error{ Truncated, ReadFailed, BadHeader, Mismatch };

fn localDataOffset(src: *const Source, e: *const Entry) LocalError!u64 {
    var h: [30]u8 = undefined;
    try src.readRaw(e.offset, &h);
    if (rd32(&h, 0) != sig_local) return error.BadHeader;
    const name_len = rd16(&h, 26);
    const extra_len = rd16(&h, 28);
    if (name_len != e.raw_name.len) return error.Mismatch;
    var name_buf: [65535]u8 = undefined;
    try src.readRaw(e.offset + 30, name_buf[0..name_len]);
    if (!std.mem.eql(u8, name_buf[0..name_len], e.raw_name)) return error.Mismatch;
    const data_off = e.offset + 30 + name_len + extra_len;
    if (data_off > src.len or e.compressed > src.len - data_off) return error.Truncated;
    return data_off;
}

/// The offset of an entry's data, after checking its local header.
fn zipDataOffset(l: *Thread, src: *const Source, e: *const Entry) Error!u64 {
    return localDataOffset(src, e) catch |err| switch (err) {
        error.Truncated => l.raiseFmt("truncated archive", .{}),
        error.ReadFailed => l.raiseFmt("cannot read archive", .{}),
        error.BadHeader => badZip(l, "bad local header"),
        error.Mismatch => badZip(l, "local header does not match central directory"),
    };
}

/// Checks that every entry's local header matches the central directory
/// and that no two entries share bytes, which stops an archive from
/// reaching a high ratio by pointing many entries at the same data.
fn zipCheckLayout(l: *Thread, arena: std.mem.Allocator, src: *const Source, entries: []const Entry) Error!void {
    const Range = struct { start: u64, end: u64 };
    const ranges = arena.alloc(Range, entries.len) catch return l.raiseMem();
    for (entries, ranges) |*e, *r| {
        const data_off = try zipDataOffset(l, src, e);
        r.* = .{ .start = e.offset, .end = data_off + e.compressed };
    }
    std.mem.sort(Range, ranges, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lt);
    var i: usize = 1;
    while (i < ranges.len) : (i += 1) {
        if (ranges[i].start < ranges[i - 1].end) return l.raiseFmt("invalid ZIP archive (overlapping entries)", .{});
    }
}

/// A reader over the stored bytes of a ZIP entry, from memory or from a
/// file with positional reads.
const RangeReader = struct {
    src: *const Source,
    off: u64,
    left: u64,
    l: *Thread,
    raised: ?Error = null,
    interface: std.Io.Reader,

    fn init(l: *Thread, src: *const Source, off: u64, len: u64, buf: []u8) RangeReader {
        return .{ .src = src, .off = off, .left = len, .l = l, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RangeReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.left == 0) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n: usize = @intCast(@min(self.left, dest.len));
        self.src.readAt(self.l, self.off, dest[0..n]) catch |e| {
            self.raised = e;
            return error.ReadFailed;
        };
        self.off += n;
        self.left -= n;
        w.advance(n);
        return n;
    }
};

fn zipExtract(l: *Thread, src: *const Source, e: *const Entry, sink: *Sink, budget: *Budget) Error!void {
    if (e.flags & flag_encrypted != 0) return l.raiseFmt("encrypted entry '{s}' is not supported", .{e.name});
    if (e.method != 0 and e.method != 8) return l.raiseFmt("unsupported compression method {d} in '{s}'", .{ e.method, e.name });
    const data_off = try zipDataOffset(l, src, e);
    var crc = Crc32.init();
    var total: u64 = 0;
    var chunk: [64 * 1024]u8 = undefined;
    if (e.method == 0) {
        if (e.compressed != e.size) return l.raiseFmt("size of '{s}' does not match its header", .{e.name});
        var off = data_off;
        var left = e.size;
        while (left > 0) {
            const n: usize = @intCast(@min(left, chunk.len));
            try src.readAt(l, off, chunk[0..n]);
            try budget.take(l, n);
            crc.update(chunk[0..n]);
            try sink.write(l, chunk[0..n]);
            off += n;
            left -= n;
        }
        total = e.size;
    } else {
        var in_buf: [16 * 1024]u8 = undefined;
        var rr = RangeReader.init(l, src, data_off, e.compressed, &in_buf);
        var window: [flate.max_window_len]u8 = undefined;
        var d: flate.Decompress = .init(&rr.interface, .raw, &window);
        while (true) {
            const n = d.reader.readSliceShort(&chunk) catch {
                if (rr.raised) |raised| return raised;
                const why = d.err orelse error.ReadFailed;
                if (why == error.EndOfStream) return l.raiseFmt("truncated archive", .{});
                return l.raiseFmt("invalid ZIP archive (deflate data of '{s}': {s})", .{ e.name, @errorName(why) });
            };
            if (n > e.size - total) return l.raiseFmt("size of '{s}' does not match its header", .{e.name});
            try budget.take(l, n);
            crc.update(chunk[0..n]);
            try sink.write(l, chunk[0..n]);
            total += n;
            if (n < chunk.len) break;
        }
    }
    if (total != e.size) return l.raiseFmt("size of '{s}' does not match its header", .{e.name});
    if (crc.final() != e.crc) return l.raiseFmt("checksum mismatch in '{s}'", .{e.name});
}

/// Thresholds at which the writer switches to ZIP64 records. Tests lower
/// them to cover those records without gigabytes of data.
const Zip64At = struct { count: u64 = 0xffff, size: u64 = 0xffffffff };

fn zipWrite(w: *std.Io.Writer, arena: std.mem.Allocator, entries: []const PackEntry, level: u4, at: Zip64At) !void {
    const Central = struct { name: []const u8, crc: u32, csize: u64, usize: u64, offset: u64, method: u16, date: u16, time: u16, attr: u32, mtime: ?i32 };
    var central: std.ArrayList(Central) = .empty;
    var window: [flate.max_window_len]u8 = undefined;
    var name_buf: std.ArrayList(u8) = .empty;
    var pos: u64 = 0;
    for (entries) |e| {
        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice(arena, e.name);
        if (e.kind == .directory) try name_buf.append(arena, '/');
        const name = try arena.dupe(u8, name_buf.items);
        const content: []const u8 = switch (e.kind) {
            .file => e.data,
            .symlink => e.target,
            else => "",
        };
        var data = content;
        var method: u16 = 0;
        if (e.kind == .file and e.deflate) {
            var buf = try std.Io.Writer.Allocating.initCapacity(arena, content.len / 2 + 64);
            try archive.flateWrite(&buf.writer, &window, .raw, level, content);
            data = buf.written();
            method = 8;
        }
        const crc = Crc32.hash(content);
        const dos = toDosTime(e.mtime);
        const mtime32: ?i32 = std.math.cast(i32, e.mtime);
        const big = content.len >= at.size or data.len >= at.size;
        var local_extra: std.ArrayList(u8) = .empty;
        if (big) {
            try appendLe(arena, &local_extra, u16, 0x0001);
            try appendLe(arena, &local_extra, u16, 16);
            try appendLe(arena, &local_extra, u64, content.len);
            try appendLe(arena, &local_extra, u64, data.len);
        }
        if (mtime32) |t| {
            try appendLe(arena, &local_extra, u16, 0x5455);
            try appendLe(arena, &local_extra, u16, 5);
            try local_extra.append(arena, 1);
            try appendLe(arena, &local_extra, i32, t);
        }
        var h: [30]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], sig_local, .little);
        std.mem.writeInt(u16, h[4..6], if (big) 45 else 20, .little);
        std.mem.writeInt(u16, h[6..8], flag_utf8, .little);
        std.mem.writeInt(u16, h[8..10], method, .little);
        std.mem.writeInt(u16, h[10..12], dos.time, .little);
        std.mem.writeInt(u16, h[12..14], dos.date, .little);
        std.mem.writeInt(u32, h[14..18], crc, .little);
        std.mem.writeInt(u32, h[18..22], if (big) 0xffffffff else @intCast(data.len), .little);
        std.mem.writeInt(u32, h[22..26], if (big) 0xffffffff else @intCast(content.len), .little);
        std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
        std.mem.writeInt(u16, h[28..30], @intCast(local_extra.items.len), .little);
        try w.writeAll(&h);
        try w.writeAll(name);
        try w.writeAll(local_extra.items);
        try w.writeAll(data);
        const type_bits: u32 = switch (e.kind) {
            .directory => s_ifdir,
            .symlink => s_iflnk,
            else => s_ifreg,
        };
        try central.append(arena, .{
            .name = name,
            .crc = crc,
            .csize = data.len,
            .usize = content.len,
            .offset = pos,
            .method = method,
            .date = dos.date,
            .time = dos.time,
            .attr = ((type_bits | e.mode) << 16) | @as(u32, if (e.kind == .directory) 0x10 else 0),
            .mtime = mtime32,
        });
        pos += 30 + name.len + local_extra.items.len + data.len;
    }
    const cd_off = pos;
    for (central.items) |c| {
        var extra: std.ArrayList(u8) = .empty;
        var z64: std.ArrayList(u8) = .empty;
        if (c.usize >= at.size) try appendLe(arena, &z64, u64, c.usize);
        if (c.csize >= at.size) try appendLe(arena, &z64, u64, c.csize);
        if (c.offset >= at.size) try appendLe(arena, &z64, u64, c.offset);
        if (z64.items.len > 0) {
            try appendLe(arena, &extra, u16, 0x0001);
            try appendLe(arena, &extra, u16, @intCast(z64.items.len));
            try extra.appendSlice(arena, z64.items);
        }
        if (c.mtime) |t| {
            try appendLe(arena, &extra, u16, 0x5455);
            try appendLe(arena, &extra, u16, 5);
            try extra.append(arena, 1);
            try appendLe(arena, &extra, i32, t);
        }
        var h: [46]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], sig_central, .little);
        std.mem.writeInt(u16, h[4..6], (3 << 8) | 45, .little);
        std.mem.writeInt(u16, h[6..8], if (z64.items.len > 0) 45 else 20, .little);
        std.mem.writeInt(u16, h[8..10], flag_utf8, .little);
        std.mem.writeInt(u16, h[10..12], c.method, .little);
        std.mem.writeInt(u16, h[12..14], c.time, .little);
        std.mem.writeInt(u16, h[14..16], c.date, .little);
        std.mem.writeInt(u32, h[16..20], c.crc, .little);
        std.mem.writeInt(u32, h[20..24], if (c.csize >= at.size) 0xffffffff else @intCast(c.csize), .little);
        std.mem.writeInt(u32, h[24..28], if (c.usize >= at.size) 0xffffffff else @intCast(c.usize), .little);
        std.mem.writeInt(u16, h[28..30], @intCast(c.name.len), .little);
        std.mem.writeInt(u16, h[30..32], @intCast(extra.items.len), .little);
        std.mem.writeInt(u16, h[32..34], 0, .little);
        std.mem.writeInt(u16, h[34..36], 0, .little);
        std.mem.writeInt(u16, h[36..38], 0, .little);
        std.mem.writeInt(u32, h[38..42], c.attr, .little);
        std.mem.writeInt(u32, h[42..46], if (c.offset >= at.size) 0xffffffff else @intCast(c.offset), .little);
        try w.writeAll(&h);
        try w.writeAll(c.name);
        try w.writeAll(extra.items);
        pos += 46 + c.name.len + extra.items.len;
    }
    const cd_size = pos - cd_off;
    const count: u64 = central.items.len;
    const need64 = count >= at.count or cd_size >= at.size or cd_off >= at.size;
    if (need64) {
        var r: [56]u8 = undefined;
        std.mem.writeInt(u32, r[0..4], sig_end64, .little);
        std.mem.writeInt(u64, r[4..12], 44, .little);
        std.mem.writeInt(u16, r[12..14], (3 << 8) | 45, .little);
        std.mem.writeInt(u16, r[14..16], 45, .little);
        std.mem.writeInt(u32, r[16..20], 0, .little);
        std.mem.writeInt(u32, r[20..24], 0, .little);
        std.mem.writeInt(u64, r[24..32], count, .little);
        std.mem.writeInt(u64, r[32..40], count, .little);
        std.mem.writeInt(u64, r[40..48], cd_size, .little);
        std.mem.writeInt(u64, r[48..56], cd_off, .little);
        try w.writeAll(&r);
        var loc: [20]u8 = undefined;
        std.mem.writeInt(u32, loc[0..4], sig_locator64, .little);
        std.mem.writeInt(u32, loc[4..8], 0, .little);
        std.mem.writeInt(u64, loc[8..16], pos, .little);
        std.mem.writeInt(u32, loc[16..20], 1, .little);
        try w.writeAll(&loc);
    }
    var end: [22]u8 = undefined;
    std.mem.writeInt(u32, end[0..4], sig_end, .little);
    std.mem.writeInt(u16, end[4..6], 0, .little);
    std.mem.writeInt(u16, end[6..8], 0, .little);
    std.mem.writeInt(u16, end[8..10], if (count >= at.count) 0xffff else @intCast(count), .little);
    std.mem.writeInt(u16, end[10..12], if (count >= at.count) 0xffff else @intCast(count), .little);
    std.mem.writeInt(u32, end[12..16], if (cd_size >= at.size) 0xffffffff else @intCast(cd_size), .little);
    std.mem.writeInt(u32, end[16..20], if (cd_off >= at.size) 0xffffffff else @intCast(cd_off), .little);
    std.mem.writeInt(u16, end[20..22], 0, .little);
    try w.writeAll(&end);
}

fn appendLe(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

// ---------------------------------------------------------------------
// tar (POSIX ustar and pax, with GNU long names)

fn badTar(l: *Thread, comptime why: []const u8) Error {
    return l.raiseFmt("invalid tar archive (" ++ why ++ ")", .{});
}

fn cstr(b: []const u8) []const u8 {
    return b[0 .. std.mem.indexOfScalar(u8, b, 0) orelse b.len];
}

/// A numeric header field: octal digits, or base-256 when the high bit of
/// its first byte is set.
fn parseNumber(b: []const u8) ?u64 {
    if (b.len > 0 and b[0] & 0x80 != 0) {
        if (b[0] & 0x40 != 0) return null;
        var v: u64 = b[0] & 0x3f;
        for (b[1..]) |c| {
            if (v >> 56 != 0) return null;
            v = (v << 8) | c;
        }
        return v;
    }
    var i: usize = 0;
    while (i < b.len and b[i] == ' ') i += 1;
    var v: u64 = 0;
    var digits: usize = 0;
    while (i < b.len and b[i] >= '0' and b[i] <= '7') : (i += 1) {
        if (v >> 61 != 0) return null;
        v = v * 8 + (b[i] - '0');
        digits += 1;
    }
    while (i < b.len) : (i += 1) {
        if (b[i] != ' ' and b[i] != 0) return null;
    }
    return v;
}

const Pax = struct { path: ?[]const u8 = null, linkpath: ?[]const u8 = null, size: ?u64 = null, mtime: ?i64 = null };

fn parsePax(l: *Thread, arena: std.mem.Allocator, data: []const u8, pax: *Pax) Error!void {
    var rest = data;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return badTar(l, "bad pax record");
        const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return badTar(l, "bad pax record");
        if (len <= sp + 1 or len > rest.len or rest[len - 1] != '\n') return badTar(l, "bad pax record");
        const kv = rest[sp + 1 .. len - 1];
        rest = rest[len..];
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return badTar(l, "bad pax record");
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "path")) {
            pax.path = try lossy(l, arena, v);
        } else if (std.mem.eql(u8, k, "linkpath")) {
            pax.linkpath = try lossy(l, arena, v);
        } else if (std.mem.eql(u8, k, "size")) {
            pax.size = std.fmt.parseInt(u64, v, 10) catch return badTar(l, "bad pax size");
        } else if (std.mem.eql(u8, k, "mtime")) {
            const whole = v[0 .. std.mem.indexOfScalar(u8, v, '.') orelse v.len];
            pax.mtime = std.fmt.parseInt(i64, whole, 10) catch return badTar(l, "bad pax mtime");
        }
    }
}

fn padded(n: u64) u64 {
    return (n + 511) / 512 * 512;
}

fn tarEntries(l: *Thread, arena: std.mem.Allocator, src: *const Source) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var pos: u64 = 0;
    var pax: Pax = .{};
    var gnu_name: ?[]const u8 = null;
    var gnu_link: ?[]const u8 = null;
    while (true) {
        var h: [512]u8 = undefined;
        if (pos >= src.len) return l.raiseFmt("truncated archive", .{});
        try src.readAt(l, pos, &h);
        if (std.mem.allEqual(u8, &h, 0)) break;
        const stored = parseNumber(h[148..156]) orelse return badTar(l, "bad header checksum");
        var unsigned: u64 = 0;
        var signed: i64 = 0;
        for (h, 0..) |c, i| {
            const b: u8 = if (i >= 148 and i < 156) ' ' else c;
            unsigned += b;
            signed += @as(i8, @bitCast(b));
        }
        if (stored != unsigned and @as(i64, @intCast(stored)) != signed) return badTar(l, "bad header checksum");
        const size = parseNumber(h[124..136]) orelse return badTar(l, "bad size field");
        const typeflag = h[156];
        const data_off = pos + 512;
        switch (typeflag) {
            'x', 'g', 'L', 'K' => {
                if (size > max_ext_header) return badTar(l, "extended header too large");
                const data = try src.alloc(l, arena, data_off, size);
                switch (typeflag) {
                    'x' => try parsePax(l, arena, data, &pax),
                    'L' => gnu_name = try lossy(l, arena, cstr(data)),
                    'K' => gnu_link = try lossy(l, arena, cstr(data)),
                    else => {},
                }
                pos = data_off + padded(size);
                continue;
            },
            else => {},
        }
        const ustar = std.mem.eql(u8, h[257..263], "ustar\x00");
        const base = cstr(h[0..100]);
        const prefix = if (ustar) cstr(h[345..500]) else "";
        const name = pax.path orelse gnu_name orelse blk: {
            if (prefix.len == 0) break :blk try lossy(l, arena, base);
            const joined = std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, base }) catch return l.raiseMem();
            break :blk try lossy(l, arena, joined);
        };
        const real_size = pax.size orelse size;
        var kind: Kind = switch (typeflag) {
            '0', 0, '7' => .file,
            '5' => .directory,
            '2' => .symlink,
            '1' => .link,
            else => .special,
        };
        if (kind == .file and name.len > 0 and name[name.len - 1] == '/') kind = .directory;
        const mtime: i64 = pax.mtime orelse blk: {
            const m = parseNumber(h[136..148]) orelse return badTar(l, "bad mtime field");
            break :blk std.math.cast(i64, m) orelse return badTar(l, "bad mtime field");
        };
        const mode = parseNumber(h[100..108]) orelse return badTar(l, "bad mode field");
        const has_data = kind == .file or kind == .special;
        const entry_size: u64 = if (has_data) real_size else 0;
        out.append(arena, .{
            .name = name,
            .kind = kind,
            .size = entry_size,
            .mode = @intCast(mode & 0o7777),
            .mtime = mtime,
            .target = pax.linkpath orelse gnu_link orelse try lossy(l, arena, cstr(h[157..257])),
            .offset = data_off,
        }) catch return l.raiseMem();
        if (data_off > src.len or entry_size > src.len - data_off) return l.raiseFmt("truncated archive", .{});
        pos = data_off + padded(entry_size);
        pax = .{};
        gnu_name = null;
        gnu_link = null;
    }
    return out.items;
}

fn octal(field: []u8, v: u64) bool {
    // The field holds its digits and a terminating NUL.
    var x = v;
    var i = field.len - 1;
    field[i] = 0;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
    }
    return x == 0;
}

fn paxRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
    // The length counts itself, so find the width that fits.
    const body = key.len + val.len + 3;
    var len = body + 1;
    while (true) {
        const digits = std.fmt.count("{d}", .{len});
        if (body + digits == len) break;
        len = body + digits;
    }
    try out.print(gpa, "{d} {s}={s}\n", .{ len, key, val });
}

fn tarHeader(w: *std.Io.Writer, name: []const u8, prefix: []const u8, typeflag: u8, mode: u32, size: u64, mtime: u64, link: []const u8) !void {
    var h: [512]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    _ = octal(h[100..108], mode);
    _ = octal(h[108..116], 0);
    _ = octal(h[116..124], 0);
    _ = octal(h[124..136], size);
    _ = octal(h[136..148], mtime);
    @memset(h[148..156], ' ');
    h[156] = typeflag;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    _ = octal(h[329..337], 0);
    _ = octal(h[337..345], 0);
    @memcpy(h[345..][0..prefix.len], prefix);
    var sum: u32 = 0;
    for (h) |c| sum += c;
    _ = octal(h[148..155], sum);
    h[155] = ' ';
    try w.writeAll(&h);
}

const max_octal11: u64 = 0o77777777777;

fn tarWrite(w: *std.Io.Writer, arena: std.mem.Allocator, entries: []const PackEntry) !void {
    var name_buf: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice(arena, e.name);
        if (e.kind == .directory) try name_buf.append(arena, '/');
        const full = name_buf.items;
        // Fit the name into ustar's name and prefix fields, or else carry
        // it in a pax record.
        var name: []const u8 = full;
        var prefix: []const u8 = "";
        var need_path = false;
        if (full.len > 100) {
            need_path = true;
            var i: usize = @min(full.len - 1, 155);
            while (i > 0) : (i -= 1) {
                if (full[i] == '/' and full.len - i - 1 <= 100 and full.len - i - 1 > 0) {
                    prefix = full[0..i];
                    name = full[i + 1 ..];
                    need_path = false;
                    break;
                }
            }
            if (need_path) {
                name = full[full.len - 100 ..];
                prefix = "";
            }
        }
        const size: u64 = if (e.kind == .file) e.data.len else 0;
        const mtime_ok = e.mtime >= 0 and e.mtime <= max_octal11;
        const link = if (e.kind == .symlink) e.target else "";
        var records: std.ArrayList(u8) = .empty;
        if (need_path) try paxRecord(arena, &records, "path", full);
        if (link.len > 100) try paxRecord(arena, &records, "linkpath", link);
        if (size > max_octal11) try paxRecord(arena, &records, "size", try std.fmt.allocPrint(arena, "{d}", .{size}));
        if (!mtime_ok) try paxRecord(arena, &records, "mtime", try std.fmt.allocPrint(arena, "{d}", .{e.mtime}));
        if (records.items.len > 0) {
            const base = std.fs.path.basename(e.name);
            const pax_name = try std.fmt.allocPrint(arena, "PaxHeader/{s}", .{base[base.len - @min(base.len, 90) ..]});
            try tarHeader(w, pax_name, "", 'x', 0o644, records.items.len, if (mtime_ok) @intCast(e.mtime) else 0, "");
            try w.writeAll(records.items);
            try w.splatByteAll(0, @intCast(padded(records.items.len) - records.items.len));
        }
        const typeflag: u8 = switch (e.kind) {
            .directory => '5',
            .symlink => '2',
            else => '0',
        };
        try tarHeader(w, name, prefix, typeflag, e.mode, if (size > max_octal11) 0 else size, if (mtime_ok) @intCast(e.mtime) else 0, link[0..@min(link.len, 100)]);
        try w.writeAll(e.data[0..@intCast(size)]);
        try w.splatByteAll(0, @intCast(padded(size) - size));
    }
    try w.splatByteAll(0, 1024);
}

// ---------------------------------------------------------------------
// Tests

test "entry names" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try normalize(gpa, &out, "./a//b/./c");
    try std.testing.expectEqualStrings("a/b/c", out.items);
    for ([_][]const u8{ "", "/etc/passwd", "a/../../b", "..", "C:x", "a\\b", "a\x00b" }) |bad| {
        try std.testing.expectError(error.Unsafe, normalize(gpa, &out, bad));
    }
    try normalize(gpa, &out, "./");
    try std.testing.expectEqualStrings("", out.items);
}

test "symlink targets" {
    try std.testing.expect(linkStaysInside("a/b/link", "../c"));
    try std.testing.expect(linkStaysInside("a/b/link", "../../c"));
    try std.testing.expect(!linkStaysInside("a/b/link", "../../../c"));
    try std.testing.expect(!linkStaysInside("link", "../x"));
    try std.testing.expect(!linkStaysInside("a/link", "x/../../y"));
    try std.testing.expect(!linkStaysInside("a/link", "/etc"));
    try std.testing.expect(linkStaysInside("link", "x/y"));
    try std.testing.expect(!linkStaysInside("link", ""));
}

test "DOS time round trip" {
    const t: i64 = 1700000000;
    const d = toDosTime(t);
    try std.testing.expectEqual(t, fromDosTime(d.date, d.time));
    try std.testing.expectEqual(dos_epoch, fromDosTime(toDosTime(0).date, toDosTime(0).time));
}

test "tar numbers" {
    try std.testing.expectEqual(@as(?u64, 0o644), parseNumber("0000644\x00"));
    try std.testing.expectEqual(@as(?u64, 0o12), parseNumber("   12 \x00"));
    try std.testing.expectEqual(@as(?u64, null), parseNumber("12x"));
    try std.testing.expectEqual(@as(?u64, 0x0102), parseNumber(&.{ 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2 }));
}

test "ZIP64 records round trip" {
    // Lowered thresholds make the writer use every ZIP64 record on a tiny
    // archive, which the reader must then follow.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]PackEntry{
        .{ .name = "a.txt", .kind = .file, .data = "hello hello hello", .mode = 0o644, .mtime = 0, .deflate = true },
        .{ .name = "b.txt", .kind = .file, .data = "world", .mode = 0o644, .mtime = 0, .deflate = false },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try zipWrite(&out.writer, arena, &entries, 6, .{ .count = 1, .size = 1 });
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, &.{ 'P', 'K', 6, 6 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &.{ 'P', 'K', 6, 7 }) != null);

    const api = @import("../api.zig");
    const l = try api.newState(gpa, std.testing.io);
    defer api.close(l);
    const src: Source = .{ .bytes = bytes, .len = bytes.len, .io = std.testing.io };
    const got = try zipEntries(l, arena, &src);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a.txt", got[0].name);
    try std.testing.expectEqual(@as(u64, 17), got[0].size);
    try std.testing.expectEqual(@as(u64, 5), got[1].size);
    try zipCheckLayout(l, arena, &src, got);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var sink: Sink = .{ .list = &data, .gpa = gpa, .io = std.testing.io };
    var budget: Budget = .{ .left = 100, .max = 100 };
    try zipExtract(l, &src, &got[1], &sink, &budget);
    try std.testing.expectEqualStrings("world", data.items);
}
