//! `io.sqlite`: the embedded SQLite binding (spec/stdlib/io/sqlite.md).
//!
//! Four userdata types cooperate here.
//!
//! - A database owns the `sqlite3` connection. Its single user value is the
//!   thread whose pledge set backs the connection's VFS, which keeps that
//!   thread alive for as long as the connection. The database also heads an
//!   intrusive list of its live statements, so closing it can finalize them
//!   first, as SQLite requires.
//! - A statement owns one `sqlite3_stmt`. Its user value is the database
//!   userdata, which keeps the connection alive. `finalizeStmt` is the only
//!   place that finalizes a statement, so a handle is never finalized twice.
//! - A cursor is one live iteration. Its user value is the statement
//!   userdata. A generation counter detects statements that were reset while
//!   an iterator was live. `db:query` and `stmt:query` return the cursor as
//!   the generic for's closing value, so breaking out of a loop still
//!   releases the statement.
//! - A table reference names one table of a database. It is the source a
//!   query expression pushes down into. Its user values are the database
//!   userdata and the table name.
//!
//! File-backed connections go through a pledge-aware VFS that checks every
//! file SQLite opens, deletes, or probes, and every shared-memory access. An
//! authorizer denies ATTACH with a filename (which also covers VACUUM INTO)
//! and the path-changing PRAGMAs. URI filenames are rejected at open, and
//! SQLITE_TEMP_STORE=3 keeps temp structures in memory. ":memory:" opens
//! with no pledge at all.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const table = @import("../vm/table.zig");
const wtf8 = @import("../vm/wtf8.zig");
const pledge = @import("../vm/pledge.zig");
const aux = @import("aux.zig");
const vector = @import("vector.zig");
const base_lib = @import("base.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Userdata = object.Userdata;
const String = object.String;
const Table = object.Table;

// ---------------------------------------------------------------------
// The SQLite C interface. Only the entry points this binding uses are
// declared, with the layouts of sqlite3.h.

pub const c = struct {
    pub const sqlite3 = opaque {};
    pub const stmt = opaque {};

    pub const OK = 0;
    pub const ERROR = 1;
    pub const PERM = 3;
    pub const NOMEM = 7;
    pub const READONLY = 8;
    pub const IOERR = 10;
    pub const NOTFOUND = 12;
    pub const CANTOPEN = 14;
    pub const ROW = 100;
    pub const DONE = 101;

    pub const IOERR_READ = IOERR | (1 << 8);
    pub const IOERR_WRITE = IOERR | (3 << 8);
    pub const IOERR_FSYNC = IOERR | (4 << 8);
    pub const IOERR_TRUNCATE = IOERR | (6 << 8);
    pub const IOERR_FSTAT = IOERR | (7 << 8);
    pub const IOERR_SHMOPEN = IOERR | (18 << 8);
    pub const IOERR_SHMLOCK = IOERR | (20 << 8);
    pub const IOERR_SHMMAP = IOERR | (21 << 8);

    pub const OPEN_READONLY = 0x1;
    pub const OPEN_READWRITE = 0x2;
    pub const OPEN_CREATE = 0x4;
    pub const OPEN_EXCLUSIVE = 0x10;
    pub const OPEN_URI = 0x40;
    pub const OPEN_MAIN_DB = 0x100;
    pub const OPEN_WAL = 0x80000;

    pub const ACCESS_READWRITE = 1;
    pub const SHM_LOCK = 2;
    pub const SHM_EXCLUSIVE = 8;

    pub const FCNTL_SET_LOCKPROXYFILE = 3;
    pub const FCNTL_SIZE_HINT = 5;
    pub const FCNTL_OVERWRITE = 11;
    pub const FCNTL_BEGIN_ATOMIC_WRITE = 31;
    pub const FCNTL_COMMIT_ATOMIC_WRITE = 32;
    pub const FCNTL_ROLLBACK_ATOMIC_WRITE = 33;

    pub const INTEGER = 1;
    pub const FLOAT = 2;
    pub const TEXT = 3;
    pub const BLOB = 4;

    pub const PRAGMA = 19;
    pub const ATTACH = 24;
    pub const DENY = 1;

    pub const UTF8 = 1;
    /// SQLITE_TRANSIENT: SQLite copies the bound bytes before returning.
    pub const TRANSIENT: isize = -1;

    pub const File = extern struct {
        pMethods: ?*const IoMethods,
    };

    pub const SyscallPtr = ?*const fn () callconv(.c) void;

    pub const IoMethods = extern struct {
        iVersion: c_int,
        xClose: ?*const fn (*File) callconv(.c) c_int,
        xRead: ?*const fn (*File, ?*anyopaque, c_int, i64) callconv(.c) c_int,
        xWrite: ?*const fn (*File, ?*const anyopaque, c_int, i64) callconv(.c) c_int,
        xTruncate: ?*const fn (*File, i64) callconv(.c) c_int,
        xSync: ?*const fn (*File, c_int) callconv(.c) c_int,
        xFileSize: ?*const fn (*File, *i64) callconv(.c) c_int,
        xLock: ?*const fn (*File, c_int) callconv(.c) c_int,
        xUnlock: ?*const fn (*File, c_int) callconv(.c) c_int,
        xCheckReservedLock: ?*const fn (*File, *c_int) callconv(.c) c_int,
        xFileControl: ?*const fn (*File, c_int, ?*anyopaque) callconv(.c) c_int,
        xSectorSize: ?*const fn (*File) callconv(.c) c_int,
        xDeviceCharacteristics: ?*const fn (*File) callconv(.c) c_int,
        xShmMap: ?*const fn (*File, c_int, c_int, c_int, *?*anyopaque) callconv(.c) c_int,
        xShmLock: ?*const fn (*File, c_int, c_int, c_int) callconv(.c) c_int,
        xShmBarrier: ?*const fn (*File) callconv(.c) void,
        xShmUnmap: ?*const fn (*File, c_int) callconv(.c) c_int,
        xFetch: ?*const fn (*File, i64, c_int, *?*anyopaque) callconv(.c) c_int,
        xUnfetch: ?*const fn (*File, i64, ?*anyopaque) callconv(.c) c_int,
    };

    pub const Vfs = extern struct {
        iVersion: c_int,
        szOsFile: c_int,
        mxPathname: c_int,
        pNext: ?*Vfs,
        zName: [*:0]const u8,
        pAppData: ?*anyopaque,
        xOpen: ?*const fn (*Vfs, ?[*:0]const u8, *File, c_int, ?*c_int) callconv(.c) c_int,
        xDelete: ?*const fn (*Vfs, [*:0]const u8, c_int) callconv(.c) c_int,
        xAccess: ?*const fn (*Vfs, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
        xFullPathname: ?*const fn (*Vfs, [*:0]const u8, c_int, [*]u8) callconv(.c) c_int,
        xDlOpen: ?*const fn (*Vfs, ?[*:0]const u8) callconv(.c) ?*anyopaque,
        xDlError: ?*const fn (*Vfs, c_int, [*]u8) callconv(.c) void,
        xDlSym: ?*const fn (*Vfs, ?*anyopaque, [*:0]const u8) callconv(.c) SyscallPtr,
        xDlClose: ?*const fn (*Vfs, ?*anyopaque) callconv(.c) void,
        xRandomness: ?*const fn (*Vfs, c_int, [*]u8) callconv(.c) c_int,
        xSleep: ?*const fn (*Vfs, c_int) callconv(.c) c_int,
        xCurrentTime: ?*const fn (*Vfs, *f64) callconv(.c) c_int,
        xGetLastError: ?*const fn (*Vfs, c_int, [*]u8) callconv(.c) c_int,
        xCurrentTimeInt64: ?*const fn (*Vfs, *i64) callconv(.c) c_int,
        xSetSystemCall: ?*const fn (*Vfs, [*:0]const u8, SyscallPtr) callconv(.c) c_int,
        xGetSystemCall: ?*const fn (*Vfs, [*:0]const u8) callconv(.c) SyscallPtr,
        xNextSystemCall: ?*const fn (*Vfs, ?[*:0]const u8) callconv(.c) ?[*:0]const u8,
    };

    pub const AuthFn = *const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;

    pub extern fn sqlite3_initialize() c_int;
    pub extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
    pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
    pub extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
    pub extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    pub extern fn sqlite3_errstr(rc: c_int) [*:0]const u8;
    pub extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    pub extern fn sqlite3_free(p: ?*anyopaque) void;
    pub extern fn sqlite3_set_authorizer(db: *sqlite3, f: ?AuthFn, arg: ?*anyopaque) c_int;
    pub extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
    pub extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, out: *?*stmt, tail: ?*?[*]const u8) c_int;
    pub extern fn sqlite3_finalize(s: ?*stmt) c_int;
    pub extern fn sqlite3_reset(s: *stmt) c_int;
    pub extern fn sqlite3_clear_bindings(s: *stmt) c_int;
    pub extern fn sqlite3_step(s: *stmt) c_int;
    pub extern fn sqlite3_next_stmt(db: *sqlite3, s: ?*stmt) ?*stmt;
    pub extern fn sqlite3_bind_parameter_count(s: *stmt) c_int;
    pub extern fn sqlite3_bind_parameter_name(s: *stmt, i: c_int) ?[*:0]const u8;
    pub extern fn sqlite3_bind_null(s: *stmt, i: c_int) c_int;
    pub extern fn sqlite3_bind_int64(s: *stmt, i: c_int, v: i64) c_int;
    pub extern fn sqlite3_bind_double(s: *stmt, i: c_int, v: f64) c_int;
    pub extern fn sqlite3_bind_text64(s: *stmt, i: c_int, p: [*]const u8, n: u64, destructor: isize, encoding: u8) c_int;
    pub extern fn sqlite3_bind_blob64(s: *stmt, i: c_int, p: ?*const anyopaque, n: u64, destructor: isize) c_int;
    pub extern fn sqlite3_column_count(s: *stmt) c_int;
    pub extern fn sqlite3_column_type(s: *stmt, i: c_int) c_int;
    pub extern fn sqlite3_column_int64(s: *stmt, i: c_int) i64;
    pub extern fn sqlite3_column_double(s: *stmt, i: c_int) f64;
    pub extern fn sqlite3_column_text(s: *stmt, i: c_int) ?[*]const u8;
    pub extern fn sqlite3_column_blob(s: *stmt, i: c_int) ?[*]const u8;
    pub extern fn sqlite3_column_bytes(s: *stmt, i: c_int) c_int;
    pub extern fn sqlite3_column_name(s: *stmt, i: c_int) ?[*:0]const u8;
    pub extern fn sqlite3_changes64(db: *sqlite3) i64;
    pub extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;
    pub extern fn sqlite3_stricmp(a: [*:0]const u8, b: [*:0]const u8) c_int;
    pub extern fn sqlite3_vfs_find(name: ?[*:0]const u8) ?*Vfs;
    pub extern fn sqlite3_vfs_register(vfs: *Vfs, make_default: c_int) c_int;
    pub extern fn sqlite3_vfs_unregister(vfs: *Vfs) c_int;
    pub extern fn sqlite3_create_filename(db: [*:0]const u8, journal: [*:0]const u8, wal: [*:0]const u8, n: c_int, params: [*]const [*:0]const u8) ?[*:0]const u8;
    pub extern fn sqlite3_free_filename(name: ?[*:0]const u8) void;
};

// ---------------------------------------------------------------------
// Pledge-aware VFS
//
// Every connection to a file gets its own VFS that wraps the platform one.
// Each callback checks the pledge set of the thread that opened the
// connection before it forwards the operation. Callbacks run inside
// SQLite's C frames, so they never raise and never allocate on the Lus
// heap. A denial is recorded in the VFS and turned into the standard
// permission error once control is back in the binding.

const path_cap = 1024;

const Owner = struct {
    vfs: c.Vfs,
    real: *c.Vfs,
    /// The thread whose pledge set authorizes operations. Cleared when a
    /// connection outlives its database handle, so late callbacks fail
    /// closed.
    l: ?*Thread,
    readonly: bool,
    denied: bool = false,
    denied_perm: []const u8 = "",
    denied_buf: [path_cap]u8 = undefined,
    denied_len: usize = 0,
    name: [48]u8 = undefined,

    fn deniedPath(o: *const Owner) []const u8 {
        return o.denied_buf[0..o.denied_len];
    }

    fn deny(o: *Owner, perm: []const u8, path: ?[]const u8) void {
        const p = path orelse "(temporary file)";
        const n = @min(p.len, o.denied_buf.len);
        @memcpy(o.denied_buf[0..n], p[0..n]);
        o.denied_len = n;
        o.denied_perm = perm;
        o.denied = true;
    }

    fn allow(o: *Owner, perm: []const u8, path: ?[]const u8) bool {
        if (o.l) |l| if (path) |p| if (pledge.allowed(l, perm, p)) {
            o.denied = false;
            return true;
        };
        o.deny(perm, path);
        return false;
    }
};

/// The wrapper file. The platform VFS's own file object follows it in the
/// same allocation, at `real_offset`.
const PFile = struct {
    base: c.File,
    real: *c.File,
    owner: *Owner,
    /// The name SQLite opened the file with. SQLite keeps it valid until
    /// xClose.
    path: [*:0]const u8,
    /// A URI filename this wrapper created for the platform VFS, if any.
    realname: ?[*:0]const u8 = null,
    can_write: bool = false,
    shm_read: bool = false,
    shm_write: bool = false,
    shm_bound: bool = false,

    fn pathSlice(f: *const PFile) []const u8 {
        return std.mem.span(f.path);
    }
};

const real_offset = std.mem.alignForward(usize, @sizeOf(PFile), 16);

fn ownerOf(v: *c.Vfs) *Owner {
    return @ptrCast(@alignCast(v.pAppData.?));
}

fn pfile(f: *c.File) *PFile {
    return @ptrCast(@alignCast(f));
}

/// Writes `path ++ suffix` into `buf`, or returns null when it does not fit.
fn sidecar(buf: []u8, path: []const u8, suffix: []const u8) ?[]const u8 {
    if (path.len + suffix.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    @memcpy(buf[path.len..][0..suffix.len], suffix);
    return buf[0 .. path.len + suffix.len];
}

fn shmAllowed(f: *PFile, write: bool) bool {
    const cached = if (write) &f.shm_write else &f.shm_read;
    if (cached.*) return true;
    var buf: [path_cap + 8]u8 = undefined;
    const p = sidecar(&buf, f.pathSlice(), "-shm");
    if (!f.owner.allow(if (write) "fs:write" else "fs:read", p)) return false;
    cached.* = true;
    return true;
}

/// Private bridge to the bundled SQLite's unix VFS (see sqlite3.h). It
/// hands the VFS an already opened -shm descriptor and its directory, and
/// marks this connection's view of the WAL index read-only even when a
/// writable connection in the process already owns the shared node.
const FCNTL_LUS_BOUND_SHM = 0x4c530001;

const BoundShm = extern struct {
    file_handle: i64,
    parent_handle: i64,
    delete_file: ?*const fn (i64, i64, [*:0]const u8) callconv(.c) c_int,
    readonly: c_int,
};

/// Binds a read-only connection's -shm file before its first use. Only
/// fs:read is needed, since the file is opened read-only. A missing file
/// would need creating, which raises a clear fs:write denial.
fn bindReadonlyShm(f: *PFile) c_int {
    if (!f.owner.readonly or f.shm_bound) return c.OK;
    if (builtin.os.tag == .windows) return c.OK;
    var buf: [path_cap + 8]u8 = undefined;
    const p = sidecar(buf[0 .. buf.len - 1], f.pathSlice(), "-shm") orelse return c.CANTOPEN;
    buf[p.len] = 0;
    const zpath: [*:0]const u8 = @ptrCast(&buf);
    const fd = std.c.open(zpath, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) {
        f.owner.deny("fs:write", p);
        return c.PERM;
    }
    defer _ = std.c.close(fd);
    const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return c.CANTOPEN;
    var dbuf: [path_cap + 8]u8 = undefined;
    const dir = if (slash == 0) "/" else p[0..slash];
    @memcpy(dbuf[0..dir.len], dir);
    dbuf[dir.len] = 0;
    const dirfd = std.c.open(@ptrCast(&dbuf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dirfd < 0) return c.CANTOPEN;
    defer _ = std.c.close(dirfd);
    var bound: BoundShm = .{ .file_handle = fd, .parent_handle = dirfd, .delete_file = null, .readonly = 1 };
    const rc = realMethods(f).xFileControl.?(f.real, FCNTL_LUS_BOUND_SHM, &bound);
    if (rc == c.OK) f.shm_bound = true;
    return rc;
}

fn denyShmWrite(f: *PFile) void {
    var buf: [path_cap + 8]u8 = undefined;
    f.owner.deny("fs:write", sidecar(&buf, f.pathSlice(), "-shm"));
}

fn realMethods(f: *PFile) *const c.IoMethods {
    return f.real.pMethods.?;
}

fn ioClose(file: *c.File) callconv(.c) c_int {
    const f = pfile(file);
    const rc = realMethods(f).xClose.?(f.real);
    c.sqlite3_free_filename(f.realname);
    f.realname = null;
    file.pMethods = null;
    return rc;
}

fn ioRead(file: *c.File, buf: ?*anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xRead.?(f.real, buf, amount, offset);
}

fn ioWrite(file: *c.File, buf: ?*const anyopaque, amount: c_int, offset: i64) callconv(.c) c_int {
    const f = pfile(file);
    if (!f.can_write) {
        f.owner.deny("fs:write", f.pathSlice());
        return c.IOERR_WRITE;
    }
    return realMethods(f).xWrite.?(f.real, buf, amount, offset);
}

fn ioTruncate(file: *c.File, size: i64) callconv(.c) c_int {
    const f = pfile(file);
    if (!f.can_write) {
        f.owner.deny("fs:write", f.pathSlice());
        return c.IOERR_TRUNCATE;
    }
    return realMethods(f).xTruncate.?(f.real, size);
}

fn ioSync(file: *c.File, flags: c_int) callconv(.c) c_int {
    const f = pfile(file);
    if (!f.can_write) {
        f.owner.deny("fs:write", f.pathSlice());
        return c.IOERR_FSYNC;
    }
    return realMethods(f).xSync.?(f.real, flags);
}

fn ioFileSize(file: *c.File, size: *i64) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xFileSize.?(f.real, size);
}

fn ioLock(file: *c.File, level: c_int) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xLock.?(f.real, level);
}

fn ioUnlock(file: *c.File, level: c_int) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xUnlock.?(f.real, level);
}

fn ioReserved(file: *c.File, out: *c_int) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xCheckReservedLock.?(f.real, out);
}

fn ioControl(file: *c.File, op: c_int, arg: ?*anyopaque) callconv(.c) c_int {
    const f = pfile(file);
    if (op == c.FCNTL_SET_LOCKPROXYFILE) {
        f.owner.deny("fs:write", f.pathSlice());
        return c.PERM;
    }
    const writes = switch (op) {
        c.FCNTL_SIZE_HINT, c.FCNTL_OVERWRITE, c.FCNTL_BEGIN_ATOMIC_WRITE, c.FCNTL_COMMIT_ATOMIC_WRITE, c.FCNTL_ROLLBACK_ATOMIC_WRITE => true,
        else => false,
    };
    if (writes and !f.can_write) {
        f.owner.deny("fs:write", f.pathSlice());
        return c.PERM;
    }
    return realMethods(f).xFileControl.?(f.real, op, arg);
}

fn ioSector(file: *c.File) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xSectorSize.?(f.real);
}

fn ioCharacteristics(file: *c.File) callconv(.c) c_int {
    const f = pfile(file);
    return realMethods(f).xDeviceCharacteristics.?(f.real);
}

fn ioShmMap(file: *c.File, page: c_int, size: c_int, write: c_int, out: *?*anyopaque) callconv(.c) c_int {
    const f = pfile(file);
    const m = realMethods(f);
    if (m.iVersion < 2 or m.xShmMap == null) return c.IOERR_SHMMAP;
    if (!shmAllowed(f, false)) return c.IOERR_SHMMAP;
    if (write != 0 and f.owner.readonly) {
        denyShmWrite(f);
        return c.READONLY;
    }
    if (!f.owner.readonly and !shmAllowed(f, true)) return c.IOERR_SHMMAP;
    if (bindReadonlyShm(f) != c.OK) return c.IOERR_SHMOPEN;
    return m.xShmMap.?(f.real, page, size, write, out);
}

fn ioShmLock(file: *c.File, offset: c_int, n: c_int, flags: c_int) callconv(.c) c_int {
    const f = pfile(file);
    const m = realMethods(f);
    if (f.owner.readonly and flags & c.SHM_LOCK != 0 and flags & c.SHM_EXCLUSIVE != 0) {
        denyShmWrite(f);
        return c.READONLY;
    }
    if (!shmAllowed(f, false) or (!f.owner.readonly and !shmAllowed(f, true))) return c.IOERR_SHMLOCK;
    if (bindReadonlyShm(f) != c.OK) return c.IOERR_SHMOPEN;
    if (m.iVersion < 2 or m.xShmLock == null) return c.IOERR_SHMLOCK;
    return m.xShmLock.?(f.real, offset, n, flags);
}

fn ioShmBarrier(file: *c.File) callconv(.c) void {
    const f = pfile(file);
    const m = realMethods(f);
    if (m.iVersion >= 2) if (m.xShmBarrier) |b| b(f.real);
}

fn ioShmUnmap(file: *c.File, remove: c_int) callconv(.c) c_int {
    const f = pfile(file);
    const m = realMethods(f);
    if (remove != 0 and !shmAllowed(f, true)) return c.IOERR_SHMOPEN;
    if (m.iVersion < 2 or m.xShmUnmap == null) return c.IOERR_SHMOPEN;
    return m.xShmUnmap.?(f.real, remove);
}

fn ioFetch(file: *c.File, offset: i64, amount: c_int, out: *?*anyopaque) callconv(.c) c_int {
    const f = pfile(file);
    const m = realMethods(f);
    if (m.iVersion < 3 or m.xFetch == null) {
        out.* = null;
        return c.OK;
    }
    return m.xFetch.?(f.real, offset, amount, out);
}

fn ioUnfetch(file: *c.File, offset: i64, p: ?*anyopaque) callconv(.c) c_int {
    const f = pfile(file);
    const m = realMethods(f);
    if (m.iVersion < 3 or m.xUnfetch == null) return c.OK;
    return m.xUnfetch.?(f.real, offset, p);
}

const io_methods: c.IoMethods = .{
    .iVersion = 3,
    .xClose = ioClose,
    .xRead = ioRead,
    .xWrite = ioWrite,
    .xTruncate = ioTruncate,
    .xSync = ioSync,
    .xFileSize = ioFileSize,
    .xLock = ioLock,
    .xUnlock = ioUnlock,
    .xCheckReservedLock = ioReserved,
    .xFileControl = ioControl,
    .xSectorSize = ioSector,
    .xDeviceCharacteristics = ioCharacteristics,
    .xShmMap = ioShmMap,
    .xShmLock = ioShmLock,
    .xShmBarrier = ioShmBarrier,
    .xShmUnmap = ioShmUnmap,
    .xFetch = ioFetch,
    .xUnfetch = ioUnfetch,
};

fn vfsOpen(v: *c.Vfs, zname: ?[*:0]const u8, file: *c.File, flags: c_int, outflags: ?*c_int) callconv(.c) c_int {
    const o = ownerOf(v);
    const f = pfile(file);
    const real: *c.File = @ptrCast(@alignCast(@as([*]u8, @ptrCast(file)) + real_offset));
    file.pMethods = null;
    const name = zname orelse {
        o.deny("fs:read", null);
        return c.CANTOPEN;
    };
    f.* = .{ .base = .{ .pMethods = null }, .real = real, .owner = o, .path = name };
    const path = std.mem.span(name);
    var rflags = flags;
    // A read-only connection consumes an existing WAL through a read-only
    // descriptor. Creating it, or any writable descriptor, stays gated.
    if (o.readonly and flags & c.OPEN_WAL != 0) {
        rflags &= ~@as(c_int, c.OPEN_READWRITE | c.OPEN_CREATE | c.OPEN_EXCLUSIVE);
        rflags |= c.OPEN_READONLY;
    }
    if (!o.allow("fs:read", path)) return c.PERM;
    if (rflags & c.OPEN_READWRITE != 0 and !o.allow("fs:write", path)) return c.PERM;
    var open_name: [*:0]const u8 = name;
    if (o.readonly and flags & c.OPEN_MAIN_DB != 0) {
        // A read-only connection maps the WAL index read-only, so it never
        // creates or writes the -shm file.
        const params = [_][*:0]const u8{ "readonly_shm", "1" };
        f.realname = c.sqlite3_create_filename(name, "", "", 1, &params) orelse return c.NOMEM;
        open_name = f.realname.?;
        rflags |= c.OPEN_URI;
    }
    f.can_write = rflags & c.OPEN_READWRITE != 0;
    @memset(@as([*]u8, @ptrCast(real))[0..@intCast(o.real.szOsFile)], 0);
    const rc = o.real.xOpen.?(o.real, open_name, real, rflags, outflags);
    if (rc == c.OK) {
        file.pMethods = &io_methods;
    } else {
        c.sqlite3_free_filename(f.realname);
        f.realname = null;
        // A read-only connection cannot create a missing WAL. Report the
        // write it would need rather than a bare open failure.
        if (o.readonly and flags & c.OPEN_WAL != 0) {
            var exists: c_int = 1;
            if (o.real.xAccess.?(o.real, name, 0, &exists) == c.OK and exists == 0) o.deny("fs:write", path);
        }
    }
    return rc;
}

fn vfsDelete(v: *c.Vfs, path: [*:0]const u8, syncdir: c_int) callconv(.c) c_int {
    const o = ownerOf(v);
    if (!o.allow("fs:write", std.mem.span(path))) return c.PERM;
    return o.real.xDelete.?(o.real, path, syncdir);
}

fn vfsAccess(v: *c.Vfs, path: [*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    const o = ownerOf(v);
    const p = std.mem.span(path);
    if (!o.allow("fs:read", p) or (flags == c.ACCESS_READWRITE and !o.allow("fs:write", p))) {
        out.* = 0;
        return c.PERM;
    }
    return o.real.xAccess.?(o.real, path, flags, out);
}

fn vfsFullPathname(v: *c.Vfs, path: [*:0]const u8, n: c_int, out: [*]u8) callconv(.c) c_int {
    const o = ownerOf(v);
    return o.real.xFullPathname.?(o.real, path, n, out);
}

fn vfsDlOpen(v: *c.Vfs, path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    // Extension loading is compiled out, so nothing reaches this.
    ownerOf(v).deny("fs:read", if (path) |p| std.mem.span(p) else null);
    return null;
}

fn vfsDlError(v: *c.Vfs, n: c_int, out: [*]u8) callconv(.c) void {
    _ = v;
    if (n > 0) out[0] = 0;
}

fn vfsDlSym(v: *c.Vfs, h: ?*anyopaque, sym: [*:0]const u8) callconv(.c) c.SyscallPtr {
    _ = v;
    _ = h;
    _ = sym;
    return null;
}

fn vfsDlClose(v: *c.Vfs, h: ?*anyopaque) callconv(.c) void {
    _ = v;
    _ = h;
}

fn vfsRandomness(v: *c.Vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    const o = ownerOf(v);
    return o.real.xRandomness.?(o.real, n, out);
}

fn vfsSleep(v: *c.Vfs, micros: c_int) callconv(.c) c_int {
    const o = ownerOf(v);
    return o.real.xSleep.?(o.real, micros);
}

fn vfsCurrentTime(v: *c.Vfs, out: *f64) callconv(.c) c_int {
    const o = ownerOf(v);
    return o.real.xCurrentTime.?(o.real, out);
}

fn vfsLastError(v: *c.Vfs, n: c_int, out: [*]u8) callconv(.c) c_int {
    const o = ownerOf(v);
    if (o.denied and n > 0) {
        const msg = std.fmt.bufPrint(out[0..@intCast(n - 1)], "permission {s} denied for '{s}'", .{ o.denied_perm, o.deniedPath() }) catch out[0..@intCast(n - 1)];
        out[msg.len] = 0;
        return c.PERM;
    }
    if (o.real.xGetLastError) |f| return f(o.real, n, out);
    return 0;
}

fn vfsCurrentTime64(v: *c.Vfs, out: *i64) callconv(.c) c_int {
    const o = ownerOf(v);
    if (o.real.iVersion >= 2) if (o.real.xCurrentTimeInt64) |f| return f(o.real, out);
    return c.NOTFOUND;
}

fn vfsSetSystemCall(v: *c.Vfs, name: [*:0]const u8, p: c.SyscallPtr) callconv(.c) c_int {
    const o = ownerOf(v);
    if (o.real.iVersion >= 3) if (o.real.xSetSystemCall) |f| return f(o.real, name, p);
    return c.NOTFOUND;
}

fn vfsGetSystemCall(v: *c.Vfs, name: [*:0]const u8) callconv(.c) c.SyscallPtr {
    const o = ownerOf(v);
    if (o.real.iVersion >= 3) if (o.real.xGetSystemCall) |f| return f(o.real, name);
    return null;
}

fn vfsNextSystemCall(v: *c.Vfs, name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const o = ownerOf(v);
    if (o.real.iVersion >= 3) if (o.real.xNextSystemCall) |f| return f(o.real, name);
    return null;
}

fn platformVfs() ?*c.Vfs {
    // Darwin's default VFS uses proxy locking styles, so the plain POSIX
    // one is preferred there, as in the legacy runtime.
    if (builtin.os.tag.isDarwin()) {
        if (c.sqlite3_vfs_find("unix-posix")) |v| return v;
    }
    return c.sqlite3_vfs_find(null);
}

fn createVfs(l: *Thread, readonly: bool) ?*Owner {
    const real = platformVfs() orelse return null;
    if (real.mxPathname < 1 or real.mxPathname >= path_cap) return null;
    const o = l.g.gpa.create(Owner) catch return null;
    o.* = .{ .vfs = undefined, .real = real, .l = l, .readonly = readonly };
    const name = std.fmt.bufPrintSentinel(&o.name, "lus-pledge-{x}", .{@intFromPtr(o)}, 0) catch unreachable;
    o.vfs = .{
        .iVersion = @min(real.iVersion, 3),
        .szOsFile = @intCast(real_offset + @as(usize, @intCast(real.szOsFile))),
        .mxPathname = real.mxPathname,
        .pNext = null,
        .zName = name.ptr,
        .pAppData = o,
        .xOpen = vfsOpen,
        .xDelete = vfsDelete,
        .xAccess = vfsAccess,
        .xFullPathname = vfsFullPathname,
        .xDlOpen = vfsDlOpen,
        .xDlError = vfsDlError,
        .xDlSym = vfsDlSym,
        .xDlClose = vfsDlClose,
        .xRandomness = vfsRandomness,
        .xSleep = vfsSleep,
        .xCurrentTime = vfsCurrentTime,
        .xGetLastError = vfsLastError,
        .xCurrentTimeInt64 = vfsCurrentTime64,
        .xSetSystemCall = vfsSetSystemCall,
        .xGetSystemCall = vfsGetSystemCall,
        .xNextSystemCall = vfsNextSystemCall,
    };
    if (c.sqlite3_vfs_register(&o.vfs, 0) != c.OK) {
        l.g.gpa.destroy(o);
        return null;
    }
    return o;
}

fn destroyVfs(g: *state.Global, o: ?*Owner) void {
    const v = o orelse return;
    _ = c.sqlite3_vfs_unregister(&v.vfs);
    g.gpa.destroy(v);
}

// ---------------------------------------------------------------------
// Handles

const db_mt_key = "sqlite.db";
const stmt_mt_key = "sqlite.stmt";
const cursor_mt_key = "sqlite.cursor";
const tableref_mt_key = "sqlite.tableref";

pub const Db = struct {
    /// Null once closed.
    db: ?*c.sqlite3,
    vfs: ?*Owner,
    readonly: bool,
    /// Live statements, finalized before the connection closes.
    stmts: ?*Stmt = null,
};

pub const Stmt = struct {
    /// Null once closed or finalized.
    stmt: ?*c.stmt,
    db: *Db,
    /// Bumped on every reset and finalize.
    generation: u32 = 0,
    prev: ?*Stmt = null,
    next: ?*Stmt = null,
};

pub const Cursor = struct {
    /// Null once spent or closed.
    stmt: ?*Stmt,
    /// The statement generation when the iteration began.
    generation: u32,
    /// Finalizes the statement on completion when set, resets it otherwise.
    owns: bool,
};

/// A statement userdata and its native state.
pub const StmtRef = struct { v: Value, p: *Stmt };

pub const TableRef = struct {
    db: *Db,
};

fn metatable(g: *state.Global, comptime key: []const u8) *Table {
    return @ptrCast(@alignCast(g.ext.get(key).?));
}

fn newUserdata(l: *Thread, comptime T: type, nuser: u16, comptime key: []const u8) Error!struct { v: Value, p: *T } {
    const g = l.g;
    gc.maybeCollect(g);
    const mt = metatable(g, key);
    const u = gc.alloc(g, Userdata, .userdata, Userdata.allocSize(@sizeOf(T), nuser)) catch return l.raiseMem();
    u.size = @sizeOf(T);
    u.nuser = nuser;
    u.metatable = mt;
    const v = Value.obj(.userdata, u);
    try l.push(v);
    try base_lib.registerFinalizer(l, &u.hdr, mt);
    return .{ .v = v, .p = @ptrCast(@alignCast(u.data())) };
}

fn toUd(l: *Thread, v: Value, comptime T: type, comptime key: []const u8) ?*T {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != metatable(l.g, key)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn userValue(v: Value, i: usize) Value {
    return v.as(Userdata).userValues()[i];
}

fn checkUd(l: *Thread, i: u32, comptime T: type, comptime key: []const u8) Error!*T {
    return toUd(l, l.arg(i), T, key) orelse aux.typeError(l, i, key);
}

/// Paths and SQL must be actual strings. The usual number coercion would
/// turn `io.sqlite(42)` into a database named "42".
fn checkStrict(l: *Thread, i: u32) Error![]const u8 {
    const v = l.arg(i);
    if (v.tag != .string) return aux.typeError(l, i, "string");
    return v.as(String).bytes();
}

fn checkDb(l: *Thread) Error!*Db {
    const d = try checkUd(l, 1, Db, db_mt_key);
    if (d.db == null) return l.raiseFmt("attempt to use a closed database", .{});
    return d;
}

fn checkStmt(l: *Thread) Error!*Stmt {
    const s = try checkUd(l, 1, Stmt, stmt_mt_key);
    if (s.stmt == null) return l.raiseFmt("attempt to use a closed statement", .{});
    if (s.db.db == null) return l.raiseFmt("attempt to use a closed database", .{});
    return s;
}

/// Raises the error of a failed SQLite call. A recorded VFS denial wins
/// over SQLite's own message, which only says the I/O failed. SQLite
/// errors carry no position, as in the legacy runtime.
fn raiseSqlite(l: *Thread, d: *Db, fallback: []const u8) Error {
    if (d.vfs) |o| if (o.denied) {
        o.denied = false;
        return raiseRaw(l, "permission \"{s}\" denied for '{s}'", .{ o.denied_perm, o.deniedPath() });
    };
    return l.raiseMsg(fallback);
}

/// Raises a formatted message without the position prefix, as the legacy
/// runtime does for SQLite's own errors.
fn raiseRaw(l: *Thread, comptime fmt: []const u8, args: anytype) Error {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.print(l.g.gpa, fmt, args) catch return l.raiseMem();
    return l.raiseMsg(buf.items);
}

fn errmsg(d: *Db) []const u8 {
    return std.mem.span(c.sqlite3_errmsg(d.db.?));
}

/// Runs `sql` through sqlite3_exec. The SQL is copied to add the
/// terminator SQLite needs.
fn execSql(l: *Thread, d: *Db, sql: []const u8) Error!void {
    const z = l.g.gpa.dupeSentinel(u8, sql, 0) catch return l.raiseMem();
    defer l.g.gpa.free(z);
    var err: ?[*:0]u8 = null;
    if (c.sqlite3_exec(d.db.?, z.ptr, null, null, &err) != c.OK) {
        defer c.sqlite3_free(err);
        var buf: [512]u8 = undefined;
        const msg = if (err) |e| copyMsg(&buf, std.mem.span(e)) else copyMsg(&buf, errmsg(d));
        return raiseSqlite(l, d, msg);
    }
}

fn copyMsg(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(buf.len, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

/// The single place a statement is finalized. Clearing the pointer and
/// bumping the generation makes every close, collection, and cursor
/// interleaving safe, since the other holders check the pointer first.
fn finalizeStmt(s: *Stmt) void {
    const st = s.stmt orelse return;
    _ = c.sqlite3_finalize(st);
    s.stmt = null;
    s.generation +%= 1;
    // Unlink from the database's live list.
    if (s.prev) |p| p.next = s.next else if (s.db.stmts == s) s.db.stmts = s.next;
    if (s.next) |n| n.prev = s.prev;
    s.prev = null;
    s.next = null;
}

/// Finalizes every live statement, then closes the connection.
fn closeDb(g: *state.Global, d: *Db) void {
    const db = d.db orelse return;
    while (d.stmts) |s| finalizeStmt(s);
    // Statements prepared outside this binding hold the connection too.
    while (c.sqlite3_next_stmt(db, null)) |st| _ = c.sqlite3_finalize(st);
    if (c.sqlite3_close(db) != c.OK) {
        // An outstanding operation keeps the connection alive as a zombie.
        // Detach it from the thread so late VFS callbacks fail closed. The
        // VFS stays registered because SQLite may still use it.
        if (d.vfs) |o| o.l = null;
        _ = c.sqlite3_close_v2(db);
        d.db = null;
        d.vfs = null;
        return;
    }
    d.db = null;
    destroyVfs(g, d.vfs);
    d.vfs = null;
}

// ---------------------------------------------------------------------
// Opening and closing

/// Denies ATTACH with a filename, which also covers the VACUUM INTO target.
/// Both would open files the pledge checks never saw. A nameless attach is
/// how plain VACUUM builds its temp database, which SQLITE_TEMP_STORE=3
/// keeps in memory, so it stays allowed.
fn authorizer(ud: ?*anyopaque, action: c_int, a3: ?[*:0]const u8, a4: ?[*:0]const u8, a5: ?[*:0]const u8, a6: ?[*:0]const u8) callconv(.c) c_int {
    _ = ud;
    _ = a4;
    _ = a5;
    _ = a6;
    if (action == c.ATTACH) if (a3) |name| if (name[0] != 0) return c.DENY;
    if (action == c.PRAGMA) if (a3) |name| {
        for ([_][*:0]const u8{ "data_store_directory", "temp_store_directory", "lock_proxy_file" }) |p| {
            if (c.sqlite3_stricmp(name, p) == 0) return c.DENY;
        }
    };
    return c.OK;
}

fn ioSqlite(l: *Thread) Error!u32 {
    const path = try checkStrict(l, 1);
    const mode = (try aux.optString(l, 2, "rw")).?;
    var readonly = false;
    if (std.mem.eql(u8, mode, "r")) {
        readonly = true;
    } else if (!std.mem.eql(u8, mode, "rw")) {
        return aux.argError(l, 2, "invalid mode", .{});
    }
    if (path.len == 0) return aux.argError(l, 1, "empty database path", .{});
    if (std.mem.startsWith(u8, path, "file:")) return aux.argError(l, 1, "URI filenames are not supported", .{});
    if (std.mem.indexOfScalar(u8, path, 0) != null) return aux.argError(l, 1, "database path contains a zero byte", .{});
    const in_memory = std.mem.eql(u8, path, ":memory:");
    // The database itself is checked here. The VFS checks each sidecar when
    // SQLite actually touches it, so unused paths need no grant.
    if (!in_memory) {
        try pledge.require(l, "fs:read", path);
        if (!readonly) try pledge.require(l, "fs:write", path);
    }
    // A closed handle comes first, so a raise leaves a consistent state.
    const ud = try newUserdata(l, Db, 1, db_mt_key);
    const d = ud.p;
    d.* = .{ .db = null, .vfs = null, .readonly = readonly };
    ud.v.as(Userdata).userValues()[0] = Value.obj(.thread, l);
    if (!in_memory) {
        d.vfs = createVfs(l, readonly) orelse return l.raiseFmt("cannot create pledge-aware SQLite VFS", .{});
    }
    const zpath = l.g.gpa.dupeSentinel(u8, path, 0) catch return l.raiseMem();
    defer l.g.gpa.free(zpath);
    const flags: c_int = if (readonly) c.OPEN_READONLY else c.OPEN_READWRITE | c.OPEN_CREATE;
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(zpath.ptr, &db, flags, if (d.vfs) |o| o.vfs.zName else null);
    if (rc != c.OK) {
        var buf: [512]u8 = undefined;
        const msg = copyMsg(&buf, if (db) |h| std.mem.span(c.sqlite3_errmsg(h)) else std.mem.span(c.sqlite3_errstr(rc)));
        const denied = if (d.vfs) |o| o.denied else false;
        var perm_buf: [path_cap + 64]u8 = undefined;
        const text = if (denied)
            std.fmt.bufPrint(&perm_buf, "permission \"{s}\" denied for '{s}'", .{ d.vfs.?.denied_perm, d.vfs.?.deniedPath() }) catch msg
        else
            null;
        _ = c.sqlite3_close(db);
        destroyVfs(l.g, d.vfs);
        d.vfs = null;
        if (text) |t| return l.raiseMsg(t);
        return raiseRaw(l, "cannot open database '{s}' ({s})", .{ path, msg });
    }
    d.db = db;
    _ = c.sqlite3_set_authorizer(db.?, authorizer, null);
    _ = c.sqlite3_busy_timeout(db.?, 5000);
    if (!in_memory and !readonly) {
        // File-backed databases run in WAL mode for reader and writer
        // concurrency. A corrupt or foreign file also surfaces here.
        var err: ?[*:0]u8 = null;
        if (c.sqlite3_exec(db.?, "PRAGMA journal_mode=WAL", null, null, &err) != c.OK) {
            var buf: [512]u8 = undefined;
            const msg = copyMsg(&buf, if (err) |e| std.mem.span(e) else errmsg(d));
            c.sqlite3_free(err);
            const o = d.vfs.?;
            if (o.denied) {
                var perm_buf: [path_cap + 64]u8 = undefined;
                const text = std.fmt.bufPrint(&perm_buf, "permission \"{s}\" denied for '{s}'", .{ o.denied_perm, o.deniedPath() }) catch msg;
                closeDb(l.g, d);
                return l.raiseMsg(text);
            }
            closeDb(l.g, d);
            return raiseRaw(l, "cannot open database '{s}' ({s})", .{ path, msg });
        }
    }
    return 1;
}

fn dbClose(l: *Thread) Error!u32 {
    const d = try checkDb(l);
    closeDb(l.g, d);
    return aux.retBool(l, true);
}

/// The tolerant variant behind both `__gc` and `__close`.
fn dbGc(l: *Thread) Error!u32 {
    const d = toUd(l, l.arg(1), Db, db_mt_key) orelse return 0;
    closeDb(l.g, d);
    return 0;
}

fn dbToString(l: *Thread) Error!u32 {
    const d = try checkUd(l, 1, Db, db_mt_key);
    const h = d.db orelse return aux.retStr(l, "database (closed)");
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, "database (0x{x})", .{@intFromPtr(h)}) catch "database");
}

// ---------------------------------------------------------------------
// Statement preparation and binding

/// Wraps a raw statement in a userdata anchored to the database userdata
/// `dbv` and links it into the database's live list. Pushes the userdata.
fn newStmt(l: *Thread, dbv: Value, st: *c.stmt) Error!StmtRef {
    const d = toUd(l, dbv, Db, db_mt_key).?;
    const ud = newUserdata(l, Stmt, 1, stmt_mt_key) catch |e| {
        _ = c.sqlite3_finalize(st);
        return e;
    };
    ud.v.as(Userdata).userValues()[0] = dbv;
    const s = ud.p;
    s.* = .{ .stmt = st, .db = d, .next = d.stmts };
    if (d.stmts) |h| h.prev = s;
    d.stmts = s;
    return .{ .v = ud.v, .p = s };
}

/// Prepares exactly one statement from `sql` on the database userdata
/// `dbv`, pushes its statement userdata, and returns it. The text after
/// the first statement may hold only whitespace and comments.
pub fn prepareSingle(l: *Thread, dbv: Value, sql: []const u8) Error!StmtRef {
    const d = toUd(l, dbv, Db, db_mt_key).?;
    const db = d.db orelse return l.raiseFmt("attempt to use a closed database", .{});
    if (sql.len > std.math.maxInt(c_int)) return l.raiseFmt("sql is too long", .{});
    var st: ?*c.stmt = null;
    var tail: ?[*]const u8 = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &st, &tail) != c.OK) {
        var buf: [512]u8 = undefined;
        return raiseSqlite(l, d, copyMsg(&buf, errmsg(d)));
    }
    const stmt = st orelse return l.raiseFmt("sql contains no statement", .{});
    const used = if (tail) |t| @intFromPtr(t) - @intFromPtr(sql.ptr) else sql.len;
    if (used < sql.len) {
        const rest = sql[used..];
        var more: ?*c.stmt = null;
        const rc = c.sqlite3_prepare_v2(db, rest.ptr, @intCast(rest.len), &more, null);
        if (more != null or rc != c.OK) {
            _ = c.sqlite3_finalize(more);
            _ = c.sqlite3_finalize(stmt);
            return l.raiseFmt("sql contains more than one statement", .{});
        }
    }
    return newStmt(l, dbv, stmt);
}

/// Binds `v` to parameter `idx` (1-based). nil binds NULL, booleans bind
/// 1 or 0, integers and floats bind natively, strings bind as TEXT, and
/// vectors bind as BLOB. A bigint that fits 64 bits binds as an integer.
/// Other bigints and decimals bind as their exact text, which SQLite's
/// numeric affinity converts on numeric columns.
pub fn bindValue(l: *Thread, s: *Stmt, idx: c_int, v: Value) Error!void {
    const st = s.stmt.?;
    const rc: c_int = switch (v.tag) {
        .nil => c.sqlite3_bind_null(st, idx),
        .false => c.sqlite3_bind_int64(st, idx, 0),
        .true => c.sqlite3_bind_int64(st, idx, 1),
        .integer => c.sqlite3_bind_int64(st, idx, v.asInt()),
        .float => c.sqlite3_bind_double(st, idx, v.asFloat()),
        .string => blk: {
            const b = v.as(String).bytes();
            break :blk c.sqlite3_bind_text64(st, idx, b.ptr, b.len, c.TRANSIENT, c.UTF8);
        },
        .vector => blk: {
            const vec = v.as(object.Vector);
            if (vec.detached) return l.raiseFmt("cannot bind a transferred vector to parameter {d}", .{idx});
            // A null data pointer would bind NULL, so an empty blob binds
            // through a non-null dummy pointer.
            const b = vec.bytes.items;
            const p: *const anyopaque = if (b.len > 0) b.ptr else "";
            break :blk c.sqlite3_bind_blob64(st, idx, p, b.len, c.TRANSIENT);
        },
        .bigint, .decimal => blk: {
            if (ops.toIntegerStrict(v)) |n| break :blk c.sqlite3_bind_int64(st, idx, n);
            const str = try ops.toString(l, v);
            const b = str.bytes();
            break :blk c.sqlite3_bind_text64(st, idx, b.ptr, b.len, c.TRANSIENT, c.UTF8);
        },
        else => return l.raiseFmt("cannot bind {s} value to parameter {d}", .{ l.typeNameOf(v), idx }),
    };
    if (rc != c.OK) return l.raiseMsg(errmsg(s.db));
}

/// Binds every parameter of the statement from `args`. Named parameters
/// (:name, @name, $name) bind from a single table argument, positional `?`
/// parameters bind from the values in order, and the two never mix.
fn bindValues(l: *Thread, s: *Stmt, args: []const Value) Error!void {
    const st = s.stmt.?;
    const np = c.sqlite3_bind_parameter_count(st);
    var named = false;
    var positional = false;
    var i: c_int = 1;
    while (i <= np) : (i += 1) {
        if (c.sqlite3_bind_parameter_name(st, i)) |name| {
            if (name[0] == '?') return l.raiseFmt("numbered parameters are not supported", .{});
            named = true;
        } else positional = true;
    }
    if (named and positional) return l.raiseFmt("statement mixes named and positional parameters", .{});
    if (named) {
        if (args.len != 1 or args[0].tag != .table) return l.raiseFmt("statement uses named parameters, but no table was given", .{});
        const t = args[0].as(Table);
        i = 1;
        while (i <= np) : (i += 1) {
            const name = std.mem.span(c.sqlite3_bind_parameter_name(st, i).?);
            const key = try l.newString(name[1..]);
            const v = table.getStr(t, key);
            if (v.isNil()) return l.raiseFmt("no value for parameter '{s}'", .{name});
            try bindValue(l, s, i, v);
        }
        return;
    }
    if (np > 0 and args.len == 1 and args[0].tag == .table) return l.raiseFmt("statement uses positional parameters, but a table was given", .{});
    if (args.len != np) return l.raiseFmt("statement has {d} parameters, but {d} values were given", .{ np, args.len });
    for (args, 0..) |v, k| try bindValue(l, s, @intCast(k + 1), v);
}

fn argSlice(l: *Thread, first: u32) []const Value {
    const n = l.argCount();
    if (n < first) return &.{};
    const b = l.base();
    return l.stack[b + first - 1 .. b + n];
}

/// Steps a statement to completion, discarding any rows.
fn runToCompletion(l: *Thread, s: *Stmt) Error!void {
    const st = s.stmt.?;
    var rc = c.sqlite3_step(st);
    while (rc == c.ROW) rc = c.sqlite3_step(st);
    if (rc != c.DONE) {
        var buf: [512]u8 = undefined;
        const msg = copyMsg(&buf, errmsg(s.db));
        _ = c.sqlite3_reset(st);
        return raiseSqlite(l, s.db, msg);
    }
}

// ---------------------------------------------------------------------
// Rows and iteration

/// Builds the current row as a table keyed by column name and pushes it.
/// NULL columns are absent. TEXT must be well-formed WTF-8 to become a
/// string. Other bytes raise, since a string never holds invalid UTF-8
/// (spec/design/strings.md), and selecting the column as a BLOB reads them
/// as a vector.
pub fn pushRow(l: *Thread, s: *Stmt) Error!void {
    const st = s.stmt.?;
    const ncols: usize = @intCast(c.sqlite3_column_count(st));
    const row = try l.newTable(0, ncols);
    try l.push(Value.obj(.table, row));
    var i: c_int = 0;
    while (i < ncols) : (i += 1) {
        const v: Value = switch (c.sqlite3_column_type(st, i)) {
            c.INTEGER => Value.int(c.sqlite3_column_int64(st, i)),
            c.FLOAT => Value.float(c.sqlite3_column_double(st, i)),
            c.TEXT => blk: {
                const p = c.sqlite3_column_text(st, i);
                const n: usize = @intCast(c.sqlite3_column_bytes(st, i));
                const bytes: []const u8 = if (p) |ptr| ptr[0..n] else "";
                const info = wtf8.analyze(bytes);
                if (!info.valid) {
                    const cname = std.mem.span(c.sqlite3_column_name(st, i) orelse "?");
                    return l.raiseFmt("invalid UTF-8 in TEXT column '{s}' at byte {d} (select it as a BLOB to read raw bytes)", .{ cname, info.error_offset });
                }
                const str = state.newStringKnown(l.g, bytes, info.ascii, info.chars) catch return l.raiseMem();
                break :blk Value.obj(.string, str);
            },
            c.BLOB => blk: {
                const p = c.sqlite3_column_blob(st, i);
                const n: usize = @intCast(c.sqlite3_column_bytes(st, i));
                const bytes: []const u8 = if (p) |ptr| ptr[0..n] else "";
                break :blk Value.obj(.vector, try vector.newVector(l, bytes));
            },
            else => continue,
        };
        try l.push(v);
        const cname = std.mem.span(c.sqlite3_column_name(st, i) orelse return l.raiseMem());
        const key = try l.newString(cname);
        try ops.rawSet(l, row, Value.obj(.string, key), v);
        l.top -= 1;
    }
}

fn queryIter(l: *Thread) Error!u32 {
    const cv = l.frame().native.?.upvalues()[0];
    const cur = toUd(l, cv, Cursor, cursor_mt_key).?;
    const s = cur.stmt orelse return aux.retNil(l);
    const st = s.stmt orelse return l.raiseFmt("attempt to use a closed statement", .{});
    if (s.db.db == null) return l.raiseFmt("attempt to use a closed database", .{});
    if (cur.generation != s.generation) return l.raiseFmt("statement was reset during iteration", .{});
    const rc = c.sqlite3_step(st);
    if (rc == c.ROW) {
        try pushRow(l, s);
        return 1;
    }
    cur.stmt = null;
    if (rc == c.DONE) {
        if (cur.owns) finalizeStmt(s) else _ = c.sqlite3_reset(st);
        return aux.retNil(l);
    }
    var buf: [512]u8 = undefined;
    const msg = copyMsg(&buf, errmsg(s.db));
    if (cur.owns) finalizeStmt(s) else _ = c.sqlite3_reset(st);
    return raiseSqlite(l, s.db, msg);
}

/// Creates a cursor over the statement userdata `sv` and returns its
/// iterator function. The cursor is pushed below it on the stack and is
/// the iterator's only upvalue. With `owns`, finishing or closing the
/// iteration finalizes the statement, otherwise it resets it.
pub fn makeCursor(l: *Thread, sv: Value, owns: bool) Error!struct { iter: Value, cursor: Value } {
    const s = toUd(l, sv, Stmt, stmt_mt_key).?;
    const ud = try newUserdata(l, Cursor, 1, cursor_mt_key);
    ud.v.as(Userdata).userValues()[0] = sv;
    ud.p.* = .{ .stmt = s, .generation = s.generation, .owns = owns };
    const n = state.newNative(l.g, queryIter, "query", 1) catch return l.raiseMem();
    n.upvalues()[0] = ud.v;
    return .{ .iter = Value.obj(.native, n), .cursor = ud.v };
}

/// Returns the generic for quadruple (iter, nil, nil, cursor). The cursor
/// doubles as the closing value, so early exits release the statement.
fn retQuery(l: *Thread, sv: Value, owns: bool) Error!u32 {
    const q = try makeCursor(l, sv, owns);
    try l.push(q.iter);
    try l.push(.nil);
    try l.push(.nil);
    try l.push(q.cursor);
    return 4;
}

/// Releases a cursor: finalizes (db:query) or resets (stmt:query) the
/// statement unless it was already finalized or reused. Tolerant, since
/// it backs both `__close` and `__gc`.
fn cursorClose(l: *Thread) Error!u32 {
    const cur = toUd(l, l.arg(1), Cursor, cursor_mt_key) orelse return 0;
    const s = cur.stmt orelse return 0;
    cur.stmt = null;
    if (s.stmt) |st| if (cur.generation == s.generation) {
        if (cur.owns) finalizeStmt(s) else _ = c.sqlite3_reset(st);
    };
    return 0;
}

// ---------------------------------------------------------------------
// Database methods

fn dbExec(l: *Thread) Error!u32 {
    const d = try checkDb(l);
    const sql = try checkStrict(l, 2);
    try execSql(l, d, sql);
    return 0;
}

fn dbRun(l: *Thread) Error!u32 {
    const d = try checkDb(l);
    const sql = try checkStrict(l, 2);
    const args = argSlice(l, 3);
    const s = try prepareSingle(l, l.arg(1), sql);
    try bindValues(l, s.p, args);
    try runToCompletion(l, s.p);
    finalizeStmt(s.p);
    try l.push(Value.int(c.sqlite3_changes64(d.db.?)));
    try l.push(Value.int(c.sqlite3_last_insert_rowid(d.db.?)));
    return 2;
}

fn dbQuery(l: *Thread) Error!u32 {
    _ = try checkDb(l);
    const sql = try checkStrict(l, 2);
    const args = argSlice(l, 3);
    const s = try prepareSingle(l, l.arg(1), sql);
    try bindValues(l, s.p, args);
    return retQuery(l, s.v, true);
}

fn dbPrepare(l: *Thread) Error!u32 {
    _ = try checkDb(l);
    const sql = try checkStrict(l, 2);
    _ = try prepareSingle(l, l.arg(1), sql);
    return 1;
}

fn dbTransaction(l: *Thread) Error!u32 {
    const d = try checkDb(l);
    const f = try aux.checkFunction(l, 2);
    try execSql(l, d, "BEGIN");
    const base = l.top;
    const n = ops.callN(l, f, &.{}, -1) catch |e| {
        if (d.db == null) return l.raiseFmt("database closed during transaction", .{});
        if (d.db) |db| _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return e;
    };
    if (d.db == null) return l.raiseFmt("database closed during transaction", .{});
    var err: ?[*:0]u8 = null;
    if (c.sqlite3_exec(d.db.?, "COMMIT", null, null, &err) != c.OK) {
        var buf: [512]u8 = undefined;
        const msg = copyMsg(&buf, if (err) |e| std.mem.span(e) else errmsg(d));
        c.sqlite3_free(err);
        _ = c.sqlite3_exec(d.db.?, "ROLLBACK", null, null, null);
        return raiseSqlite(l, d, msg);
    }
    std.debug.assert(l.top == base + n);
    return n;
}

// ---------------------------------------------------------------------
// Statement methods

/// Resets the statement for re-execution, invalidating any live iterator.
fn rearm(s: *Stmt) void {
    _ = c.sqlite3_reset(s.stmt.?);
    _ = c.sqlite3_clear_bindings(s.stmt.?);
    s.generation +%= 1;
}

fn stmtRun(l: *Thread) Error!u32 {
    const s = try checkStmt(l);
    rearm(s);
    try bindValues(l, s, argSlice(l, 2));
    try runToCompletion(l, s);
    _ = c.sqlite3_reset(s.stmt.?);
    const db = s.db.db.?;
    try l.push(Value.int(c.sqlite3_changes64(db)));
    try l.push(Value.int(c.sqlite3_last_insert_rowid(db)));
    return 2;
}

fn stmtQuery(l: *Thread) Error!u32 {
    const s = try checkStmt(l);
    rearm(s);
    try bindValues(l, s, argSlice(l, 2));
    return retQuery(l, l.arg(1), false);
}

fn stmtClose(l: *Thread) Error!u32 {
    const s = try checkStmt(l);
    finalizeStmt(s);
    return aux.retBool(l, true);
}

/// The tolerant variant behind both `__gc` and `__close`.
fn stmtGc(l: *Thread) Error!u32 {
    const s = toUd(l, l.arg(1), Stmt, stmt_mt_key) orelse return 0;
    finalizeStmt(s);
    return 0;
}

fn stmtToString(l: *Thread) Error!u32 {
    const s = try checkUd(l, 1, Stmt, stmt_mt_key);
    const st = s.stmt orelse return aux.retStr(l, "statement (closed)");
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, "statement (0x{x})", .{@intFromPtr(st)}) catch "statement");
}

// ---------------------------------------------------------------------
// Table references
//
// Indexing a database handle with a key that is not a method yields a
// table reference, the query source for that table. The query engine
// recognizes references with `toTableRef`, renders identifiers with
// `appendIdent`, and opens the pushed-down SELECT with `openSelect`, so
// every value still travels as a bound parameter.

/// `__index` of the database handle: methods win, and any other string key
/// yields a table reference.
fn dbIndex(l: *Thread) Error!u32 {
    const methods = l.frame().native.?.upvalues()[0].as(Table);
    const k = l.arg(2);
    const m = table.get(methods, try ops.normKey(l, k));
    if (!m.isNil()) return aux.ret(l, m);
    const d = try checkUd(l, 1, Db, db_mt_key);
    if (k.tag != .string) return aux.retNil(l);
    if (d.db == null) return l.raiseFmt("attempt to use a closed database", .{});
    const ud = try newUserdata(l, TableRef, 2, tableref_mt_key);
    ud.p.* = .{ .db = d };
    ud.v.as(Userdata).userValues()[0] = l.arg(1);
    ud.v.as(Userdata).userValues()[1] = k;
    return 1;
}

fn tableRefToString(l: *Thread) Error!u32 {
    _ = try checkUd(l, 1, TableRef, tableref_mt_key);
    const name = userValue(l.arg(1), 1).as(String).bytes();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.print(l.g.gpa, "table reference ({s})", .{name}) catch return l.raiseMem();
    return aux.retStr(l, buf.items);
}

/// A table reference seen by the query engine: the database userdata that
/// anchors it and the table name.
pub const TableRefInfo = struct {
    db_value: Value,
    db: *Db,
    name: *String,
};

/// Recognizes a table reference produced by indexing a database handle.
pub fn toTableRef(l: *Thread, v: Value) ?TableRefInfo {
    const t = toUd(l, v, TableRef, tableref_mt_key) orelse return null;
    return .{ .db_value = userValue(v, 0), .db = t.db, .name = userValue(v, 1).as(String) };
}

/// Appends `name` as a double-quoted SQL identifier, doubling interior
/// quotes.
pub fn appendIdent(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    try out.append(gpa, '"');
    for (name) |ch| {
        if (ch == '"') try out.append(gpa, '"');
        try out.append(gpa, ch);
    }
    try out.append(gpa, '"');
}

/// Prepares `sql` (one statement) on the database behind table reference
/// `ref`, binds `binds` to its `?` placeholders in order, and returns an
/// iterator over its rows that finalizes the statement when it is spent
/// or its cursor is closed. The statement and cursor userdata are pushed
/// on the stack, and the iterator keeps them alive through its upvalue.
pub fn openSelect(l: *Thread, ref: TableRefInfo, sql: []const u8, binds: []const Value) Error!Value {
    if (ref.db.db == null) return l.raiseFmt("attempt to use a closed database", .{});
    const s = try prepareSingle(l, ref.db_value, sql);
    for (binds, 0..) |v, i| try bindValue(l, s.p, @intCast(i + 1), v);
    const q = try makeCursor(l, s.v, true);
    return q.iter;
}

/// The raw connection behind a database handle, for embedders. Null when
/// `v` is not an open database.
pub fn toSqlite(l: *Thread, v: Value) ?*c.sqlite3 {
    const d = toUd(l, v, Db, db_mt_key) orelse return null;
    return d.db;
}

// ---------------------------------------------------------------------
// Registration

fn makeMeta(l: *Thread, comptime key: []const u8, methods: []const aux.Reg, meta: []const aux.Reg) Error!*Table {
    const mt = try l.newTable(0, 8);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setFuncs(l, mt, meta);
    if (methods.len > 0) {
        const m = try aux.newLib(l, methods);
        try aux.setField(l, mt, "__index", Value.obj(.table, m));
    }
    try aux.setField(l, mt, "__name", try l.newStringValue(key));
    try aux.setField(l, mt, "__metatable", .false);
    try anchor(l, key, mt);
    return mt;
}

/// Roots a metatable in the registry and records it for fast lookup.
fn anchor(l: *Thread, comptime key: []const u8, mt: *Table) Error!void {
    try aux.setField(l, l.g.registry.as(Table), key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, key, mt) catch return l.raiseMem();
}

/// Adds `sqlite` to the io table `io_t`. SQLite has a single entry point,
/// so it lives in the io table beside `io.open`.
pub fn register(l: *Thread, io_t: *Table) Error!void {
    if (c.sqlite3_initialize() != c.OK) return l.raiseFmt("cannot initialize sqlite", .{});
    // The database metatable indexes methods first and table references
    // after.
    const db_mt = try makeMeta(l, db_mt_key, &.{}, &.{
        .{ .name = "__gc", .func = dbGc },
        .{ .name = "__close", .func = dbGc },
        .{ .name = "__tostring", .func = dbToString },
    });
    const methods = try aux.newLib(l, &.{
        .{ .name = "exec", .func = dbExec },
        .{ .name = "run", .func = dbRun },
        .{ .name = "query", .func = dbQuery },
        .{ .name = "prepare", .func = dbPrepare },
        .{ .name = "transaction", .func = dbTransaction },
        .{ .name = "close", .func = dbClose },
    });
    try l.push(Value.obj(.table, methods));
    const idx = state.newNative(l.g, dbIndex, "index", 1) catch return l.raiseMem();
    idx.upvalues()[0] = Value.obj(.table, methods);
    try aux.setField(l, db_mt, "__index", Value.obj(.native, idx));
    l.top -= 1;
    _ = try makeMeta(l, stmt_mt_key, &.{
        .{ .name = "run", .func = stmtRun },
        .{ .name = "query", .func = stmtQuery },
        .{ .name = "close", .func = stmtClose },
    }, &.{
        .{ .name = "__gc", .func = stmtGc },
        .{ .name = "__close", .func = stmtGc },
        .{ .name = "__tostring", .func = stmtToString },
    });
    _ = try makeMeta(l, cursor_mt_key, &.{}, &.{
        .{ .name = "__gc", .func = cursorClose },
        .{ .name = "__close", .func = cursorClose },
    });
    _ = try makeMeta(l, tableref_mt_key, &.{}, &.{
        .{ .name = "__tostring", .func = tableRefToString },
    });
    try aux.setField(l, io_t, "sqlite", try aux.native(l, ioSqlite, "sqlite"));
}
