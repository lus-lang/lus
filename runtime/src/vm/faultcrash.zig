//! The power loss model of `LUS_FAIL_IO=N:powerloss`, after the crash
//! tests of SQLite.
//!
//! A write that no sync has made durable lives in the cache of the
//! operating system, and a power loss may keep it, lose it, or keep part
//! of it. The model records, for each such write, the bytes it replaced.
//! When the run reaches operation N, the model decides the fate of every
//! pending change at random and undoes the ones that the power loss
//! destroyed, then ends the process at once. It follows these rules.
//!
//! 1. A write reaches the disk in sectors of 512 bytes. A sector that a
//!    lost write touched holds the old bytes, the new bytes, or a torn
//!    mix: the new bytes up to some point and the old ones after it, or
//!    the reverse.
//! 2. A file grows before its new bytes arrive. A lost write past the old
//!    end of a file either leaves the old size or leaves the new size with
//!    garbage in the new region.
//! 3. Unsynced writes reach the disk in any order, or not at all. Syncing
//!    a file makes all its earlier writes durable, and is the only
//!    barrier.
//! 4. A creation, a rename, and a deletion change a directory, and become
//!    durable only when that directory is synced. A rename and a deletion
//!    happen entirely or not at all. The changes to the entry of one file
//!    survive in order: when a rename survives, so does the creation
//!    before it.
//! 5. With `LUS_FAIL_IO_PSOW=0`, a lost write may also destroy the bytes
//!    of its sectors that it did not write, which is what a disk without
//!    the powersafe overwrite property does. The default keeps them.
//!
//! The model tracks the files that the run opens through the paths of the
//! current directory, and the directories it opens to sync them. It knows
//! each file by an identity that survives renames. `LUS_FAIL_IO_SEED`
//! changes the random choices for the same N.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// The model needs the system calls of POSIX. Windows ends the run at the
/// crash point without undoing anything, as `kill` does.
pub const supported = builtin.os.tag != .windows;

const sector: u64 = 512;
const gpa = std.heap.page_allocator;

pub var psow = true;
pub var seed: u64 = 0;

const Rec = union(enum) {
    /// `old` holds the bytes the write replaced, up to the old size.
    write: struct { id: u32, offset: u64, len: u64, old_size: u64, old: []u8 },
    /// A change of size. `old` holds the bytes a shrink removed.
    truncate: struct { id: u32, new_size: u64, old_size: u64, old: []u8 },
    create: struct { id: u32, dir: [:0]u8 },
    rename: struct { id: u32, from: [:0]u8, to: [:0]u8, from_dir: [:0]u8, to_dir: [:0]u8, replaced: ?Saved },
    delete: struct { id: u32, path: [:0]u8, dir: [:0]u8, content: []u8 },
};

const Saved = struct { id: u32, content: []u8 };

var lock: std.atomic.Value(bool) = .init(false);
var pending: std.ArrayList(Rec) = .empty;
/// The current path of each file identity, or null once it is gone.
var paths: std.ArrayList(?[:0]u8) = .empty;
var fds: std.AutoHashMapUnmanaged(c.fd_t, u32) = .empty;
var dirfds: std.AutoHashMapUnmanaged(c.fd_t, [:0]u8) = .empty;
var cwd: []u8 = &.{};

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

/// The absolute, normalized form of a path of the current directory.
fn absolute(path: []const u8) ?[:0]u8 {
    if (cwd.len == 0) {
        var buf: [4096]u8 = undefined;
        const p = c.getcwd(&buf, buf.len) orelse return null;
        cwd = gpa.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(p)))) catch return null;
    }
    const r = std.fs.path.resolveAllocPosix(gpa, &.{ cwd, path }) catch return null;
    defer gpa.free(r);
    return gpa.dupeSentinel(u8, r, 0) catch null;
}

fn parent(path: [:0]const u8) [:0]u8 {
    const d = std.fs.path.dirnamePosix(path) orelse "/";
    return gpa.dupeSentinel(u8, d, 0) catch @constCast("/");
}

fn idOfPath(path: []const u8) ?u32 {
    for (paths.items, 0..) |p, i| if (p) |q| if (std.mem.eql(u8, q, path)) return @intCast(i);
    return null;
}

fn newId(path: [:0]u8) ?u32 {
    paths.append(gpa, path) catch return null;
    return @intCast(paths.items.len - 1);
}

fn exists(path: [*:0]const u8) bool {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

fn sizeOf(path: [*:0]const u8) ?u64 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK.END);
    return if (end < 0) null else @intCast(end);
}

/// The bytes of `path` from `offset`, at most `len` of them.
fn readRange(path: [*:0]const u8, offset: u64, len: u64) []u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return &.{};
    defer _ = c.close(fd);
    const buf = gpa.alloc(u8, @intCast(len)) catch return &.{};
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.pread(fd, buf.ptr + got, buf.len - got, @intCast(offset + got));
        if (n <= 0) break;
        got += @intCast(n);
    }
    return buf[0..got];
}

fn readAll(path: [*:0]const u8) []u8 {
    return readRange(path, 0, sizeOf(path) orelse return &.{});
}

// ---------------------------------------------------------------------
// Recording, called by `faultio.zig` before each operation reaches the
// system.

/// A file of the current directory opened as `fd`. `creating` says that
/// the open may create it, and `truncating` that it empties the file.
pub fn opened(sub_path: []const u8, creating: bool, truncating: bool) void {
    acquire();
    defer release();
    const path = absolute(sub_path) orelse return;
    const was = exists(path);
    if (idOfPath(path)) |id| {
        gpa.free(path);
        if (truncating and was) noteTruncate(id, 0);
        last_open = id;
        return;
    }
    const id = newId(path) orelse return;
    last_open = id;
    if (!was and creating) {
        pending.append(gpa, .{ .create = .{ .id = id, .dir = parent(path) } }) catch {};
    } else if (truncating and was) {
        noteTruncate(id, 0);
    }
}

var last_open: ?u32 = null;

/// Binds the descriptor that the open of `opened` returned.
pub fn bind(fd: c.fd_t) void {
    acquire();
    defer release();
    if (last_open) |id| fds.put(gpa, fd, id) catch {};
    last_open = null;
}

pub fn openedDir(sub_path: []const u8, fd: c.fd_t) void {
    acquire();
    defer release();
    const path = absolute(sub_path) orelse return;
    dirfds.put(gpa, fd, path) catch {};
}

pub fn closed(fd: c.fd_t) void {
    acquire();
    defer release();
    _ = fds.remove(fd);
    if (dirfds.fetchRemove(fd)) |kv| gpa.free(kv.value);
}

fn noteTruncate(id: u32, new_size: u64) void {
    const path = paths.items[id] orelse return;
    const old_size = sizeOf(path) orelse return;
    const old = if (new_size < old_size) readRange(path, new_size, old_size - new_size) else @as([]u8, &.{});
    pending.append(gpa, .{ .truncate = .{ .id = id, .new_size = new_size, .old_size = old_size, .old = old } }) catch {};
}

/// A write of `len` bytes to `fd`, at `offset`, or at the current position
/// of the descriptor when `offset` is null.
pub fn writing(fd: c.fd_t, offset: ?u64, len: u64) void {
    if (len == 0) return;
    acquire();
    defer release();
    const id = fds.get(fd) orelse return;
    const path = paths.items[id] orelse return;
    const old_size = sizeOf(path) orelse return;
    const at: u64 = offset orelse blk: {
        const fl = c.fcntl(fd, c.F.GETFL);
        if (fl >= 0 and (fl & @as(c_int, @bitCast(c.O{ .APPEND = true }))) != 0) break :blk old_size;
        const pos = c.lseek(fd, 0, c.SEEK.CUR);
        break :blk if (pos < 0) old_size else @intCast(pos);
    };
    const old = if (at < old_size) readRange(path, at, @min(len, old_size - at)) else @as([]u8, &.{});
    pending.append(gpa, .{ .write = .{ .id = id, .offset = at, .len = len, .old_size = old_size, .old = old } }) catch {};
}

pub fn settingLength(fd: c.fd_t, new_size: u64) void {
    acquire();
    defer release();
    const id = fds.get(fd) orelse return;
    noteTruncate(id, new_size);
}

/// A sync of `fd`. A file sync makes the writes and size changes of that
/// file durable, and a directory sync the entries changed in it.
pub fn syncing(fd: c.fd_t) void {
    acquire();
    const id = fds.get(fd);
    const dir = dirfds.get(fd);
    release();
    if (id) |i| syncId(i);
    if (dir) |d| {
        acquire();
        defer release();
        syncDir(d);
    }
}

fn syncId(id: u32) void {
    acquire();
    defer release();
    var i: usize = 0;
    while (i < pending.items.len) {
        const durable = switch (pending.items[i]) {
            .write => |w| w.id == id,
            .truncate => |t| t.id == id,
            else => false,
        };
        if (durable) _ = pending.orderedRemove(i) else i += 1;
    }
}

/// Makes the entry changes in `dir` durable. The caller holds the lock.
fn syncDir(dir: []const u8) void {
    var i: usize = 0;
    while (i < pending.items.len) {
        var durable = false;
        switch (pending.items[i]) {
            .create => |cr| durable = std.mem.eql(u8, cr.dir, dir),
            .delete => |d| durable = std.mem.eql(u8, d.dir, dir),
            .rename => |*r| {
                // A rename between two directories is durable once both are.
                if (std.mem.eql(u8, r.from_dir, dir)) r.from_dir = @constCast("");
                if (std.mem.eql(u8, r.to_dir, dir)) r.to_dir = @constCast("");
                durable = r.from_dir.len == 0 and r.to_dir.len == 0;
            },
            else => {},
        }
        if (durable) _ = pending.orderedRemove(i) else i += 1;
    }
}

pub fn renaming(from_sub: []const u8, to_sub: []const u8) void {
    acquire();
    defer release();
    const from = absolute(from_sub) orelse return;
    const to = absolute(to_sub) orelse return;
    const id = idOfPath(from) orelse newId(gpa.dupeSentinel(u8, from, 0) catch return) orelse return;
    var replaced: ?Saved = null;
    if (exists(to)) {
        const rid = idOfPath(to) orelse newId(gpa.dupeSentinel(u8, to, 0) catch return) orelse return;
        replaced = .{ .id = rid, .content = readAll(to) };
        paths.items[rid] = null;
    }
    paths.items[id] = to;
    pending.append(gpa, .{ .rename = .{ .id = id, .from = from, .to = to, .from_dir = parent(from), .to_dir = parent(to), .replaced = replaced } }) catch {};
}

pub fn deleting(sub_path: []const u8) void {
    acquire();
    defer release();
    const path = absolute(sub_path) orelse return;
    if (!exists(path)) return;
    const id = idOfPath(path) orelse newId(gpa.dupeSentinel(u8, path, 0) catch return) orelse return;
    const content = readAll(path);
    paths.items[id] = null;
    pending.append(gpa, .{ .delete = .{ .id = id, .path = path, .dir = parent(path), .content = content } }) catch {};
}

// ---------------------------------------------------------------------
// Recording by path, for the SQLite VFS of `lib/sqlite.zig`, which opens
// its files through the system and not through `std.Io`.

pub fn openedPath(path: []const u8, creating: bool) void {
    opened(path, creating, false);
    acquire();
    last_open = null;
    release();
}

fn idOf(path: []const u8) ?u32 {
    const abs = absolute(path) orelse return null;
    defer gpa.free(abs);
    return idOfPath(abs);
}

pub fn writingPath(path: []const u8, offset: u64, len: u64) void {
    if (len == 0) return;
    acquire();
    defer release();
    const id = idOf(path) orelse return;
    const p = paths.items[id] orelse return;
    const old_size = sizeOf(p) orelse return;
    const old = if (offset < old_size) readRange(p, offset, @min(len, old_size - offset)) else @as([]u8, &.{});
    pending.append(gpa, .{ .write = .{ .id = id, .offset = offset, .len = len, .old_size = old_size, .old = old } }) catch {};
}

pub fn truncatingPath(path: []const u8, size: u64) void {
    acquire();
    defer release();
    noteTruncate(idOf(path) orelse return, size);
}

/// A sync of the file at `path`, and of its directory when `dir` is set,
/// as SQLite does after it creates a journal.
pub fn syncingPath(path: []const u8, dir: bool) void {
    acquire();
    const id = idOf(path);
    release();
    if (id) |i| syncId(i);
    if (dir) syncingDirPath(path);
}

/// A sync of the directory that holds `path`.
pub fn syncingDirPath(path: []const u8) void {
    acquire();
    defer release();
    const abs = absolute(path) orelse return;
    defer gpa.free(abs);
    syncDir(parent(abs));
}

// ---------------------------------------------------------------------
// The power loss.

var prng: std.Random.DefaultPrng = undefined;

fn rand() std.Random {
    return prng.random();
}

/// Sectors of each file that a durable or surviving write owns, which an
/// earlier lost write must not undo.
var claimed: std.AutoHashMapUnmanaged(u64, void) = .empty;

fn claimKey(id: u32, s: u64) u64 {
    return (@as(u64, id) << 40) | s;
}

fn writeAt(fd: c.fd_t, bytes: []const u8, offset: u64) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.pwrite(fd, bytes.ptr + done, bytes.len - done, @intCast(offset + done));
        if (n <= 0) return;
        done += @intCast(n);
    }
}

fn garbage(fd: c.fd_t, from: u64, to: u64) void {
    if (to <= from) return;
    var buf: [sector]u8 = undefined;
    var at = from;
    while (at < to) {
        const n: usize = @intCast(@min(sector, to - at));
        rand().bytes(buf[0..n]);
        writeAt(fd, buf[0..n], at);
        at += n;
    }
}

/// Restores the old bytes of a lost write over `[lo, hi)`, garbage where
/// the file had no bytes before.
fn revert(fd: c.fd_t, w: anytype, lo: u64, hi: u64) void {
    if (hi <= lo) return;
    const old_end = w.offset + w.old.len;
    if (lo < old_end) {
        const a = lo - w.offset;
        const b = @min(hi, old_end) - w.offset;
        writeAt(fd, w.old[@intCast(a)..@intCast(b)], lo);
    }
    if (hi > old_end) garbage(fd, @max(lo, old_end), hi);
}

fn undoWrite(w: anytype) void {
    const path = paths.items[w.id] orelse return;
    const end = w.offset + w.len;
    const first = w.offset / sector;
    const last = (end - 1) / sector;
    if (rand().boolean()) {
        var s = first;
        while (s <= last) : (s += 1) claimed.put(gpa, claimKey(w.id, s), {}) catch {};
        return;
    }
    const fd = c.open(path, .{ .ACCMODE = .RDWR });
    if (fd < 0) return;
    defer _ = c.close(fd);
    const size_now: u64 = blk: {
        const e = c.lseek(fd, 0, c.SEEK.END);
        break :blk if (e < 0) 0 else @intCast(e);
    };
    var s = first;
    var any_claimed_past_old = false;
    while (s <= last) : (s += 1) {
        if (claimed.contains(claimKey(w.id, s))) {
            if ((s + 1) * sector > w.old_size) any_claimed_past_old = true;
            continue;
        }
        const lo = @max(w.offset, s * sector);
        const hi = @min(end, (s + 1) * sector);
        const choice = rand().uintLessThan(u8, 4);
        switch (choice) {
            0 => revert(fd, w, lo, hi),
            1 => {
                claimed.put(gpa, claimKey(w.id, s), {}) catch {};
                continue;
            },
            2 => revert(fd, w, lo + rand().uintLessThan(u64, hi - lo), hi),
            else => revert(fd, w, lo, lo + rand().uintLessThan(u64, hi - lo)),
        }
        if (!psow) {
            garbage(fd, s * sector, lo);
            garbage(fd, hi, @min((s + 1) * sector, size_now));
        }
    }
    // A lost write past the old end leaves either the old size or the new
    // size with garbage, which `revert` already wrote.
    if (end > w.old_size and !any_claimed_past_old and rand().boolean()) {
        _ = c.ftruncate(fd, @intCast(w.old_size));
    }
}

fn undoTruncate(t: anytype) void {
    if (rand().boolean()) return;
    const path = paths.items[t.id] orelse return;
    const fd = c.open(path, .{ .ACCMODE = .RDWR });
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.ftruncate(fd, @intCast(t.old_size));
    if (t.old.len > 0) writeAt(fd, t.old, t.new_size);
}

fn recreate(path: [:0]const u8, content: []const u8) void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    writeAt(fd, content, 0);
}

/// File identities whose entry kept a later change, so their earlier
/// entry changes survive too.
var entry_kept: std.AutoHashMapUnmanaged(u32, void) = .empty;

/// Whether an entry change of `id` survives, and records it.
fn keepEntry(id: u32) bool {
    const keep = entry_kept.contains(id) or rand().boolean();
    if (keep) entry_kept.put(gpa, id, {}) catch {};
    return keep;
}

/// Undoes what the power loss destroyed and ends the process.
pub fn powerLoss(n: usize) noreturn {
    acquire();
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&n));
    prng = .init(h.final());
    var i = pending.items.len;
    while (i > 0) {
        i -= 1;
        switch (pending.items[i]) {
            .write => |w| undoWrite(w),
            .truncate => |t| undoTruncate(t),
            .create => |cr| if (!keepEntry(cr.id)) {
                if (paths.items[cr.id]) |p| _ = c.unlink(p);
                paths.items[cr.id] = null;
            },
            .rename => |r| if (!keepEntry(r.id)) {
                _ = c.rename(r.to, r.from);
                paths.items[r.id] = r.from;
                if (r.replaced) |rep| {
                    recreate(r.to, rep.content);
                    paths.items[rep.id] = r.to;
                }
            },
            .delete => |d| if (!keepEntry(d.id)) {
                recreate(d.path, d.content);
                paths.items[d.id] = d.path;
            },
        }
    }
    report("power loss", n);
    c._exit(137);
}

/// Ends the process at once, as a kill does.
pub fn kill(n: usize) noreturn {
    report("kill", n);
    if (supported) c._exit(137);
    std.process.exit(137);
}

fn report(what: []const u8, n: usize) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "lus: simulated {s} at I/O operation {d}\n", .{ what, n }) catch return;
    if (supported) _ = c.write(2, msg.ptr, msg.len) else std.debug.print("{s}", .{msg});
}
