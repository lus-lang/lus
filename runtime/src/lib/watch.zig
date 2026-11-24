//! `fs.watch(path, options)`: a coroutine that hands over changes to the
//! files under `path`. Each resume waits for the next change and returns
//! an event `{kind = ..., path = ...}`, where `kind` is "create",
//! "modify", "remove", or "rescan" (the system dropped events, so the
//! program should look at the tree again).
//!
//! The backends are inotify on Linux, FSEvents on macOS, and
//! ReadDirectoryChangesW on Windows. Every backend feeds one queue, which
//! merges the events of a path that follow each other within 50 ms, so
//! the steps of an editor saving a file arrive as one change. inotify is
//! read in the thread of the state through the poller of the scheduler.
//! FSEvents calls back on a dispatch queue thread and ReadDirectoryChangesW
//! runs on a thread of its own, and both wake the scheduler with
//! `sched.notify`. FSEvents is loaded with dlopen when the first watch
//! starts, so programs that never watch do not link CoreServices.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const sched = @import("../vm/sched.zig");
const pledge = @import("../vm/pledge.zig");
const aux = @import("auxlib.zig");
const base_lib = @import("base.zig");
const os_lib = @import("os.zig");
const events = @import("events.zig");
const walk = @import("walk.zig");
const Value = value.Value;
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const String = object.String;
const Dir = std.Io.Dir;

const os_tag = builtin.os.tag;
const windows = os_tag == .windows;
const linux = os_tag == .linux;
const macos = os_tag == .macos;
pub const supported = linux or macos or windows;
const sep: u8 = if (windows) '\\' else '/';

/// Events of one path that follow each other this closely merge.
const merge_ns: u64 = 50 * std.time.ns_per_ms;

const Kind = enum {
    create,
    modify,
    remove,
    rescan,

    fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

const Event = struct { kind: Kind, path: []u8, at: u64 };

const gpa = std.heap.smp_allocator;

/// What the backends and the thread of the state share.
const Shared = struct {
    lock_word: std.atomic.Mutex = .unlocked,
    queue: std.ArrayList(Event) = .empty,
    g: *Global,
    /// The path the program passed, which every reported path starts with.
    root: []u8,
    /// The resolved path of the root, which FSEvents reports.
    root_real: []u8,
    recursive: bool,
    /// Set when the root is a file: only events of the file itself count.
    is_file: bool,
    /// Paths that FSEvents reported as created during the watch. Its flags
    /// accumulate, so a later change of such a file still carries the
    /// created flag.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// When the watch started, in nanoseconds of the real time clock.
    start_real: i128 = 0,

    fn lock(s: *Shared) void {
        while (!s.lock_word.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(s: *Shared) void {
        s.lock_word.unlock();
    }

    fn deinit(s: *Shared) void {
        for (s.queue.items) |e| gpa.free(e.path);
        s.queue.deinit(gpa);
        var it = s.seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.seen.deinit(gpa);
        gpa.free(s.root);
        gpa.free(s.root_real);
        gpa.destroy(s);
    }

    /// Adds an event, merging it with an event of the same path that was
    /// not delivered yet. Called with the lock held.
    fn pushLocked(s: *Shared, kind: Kind, path: []const u8, at: u64) void {
        if (kind != .rescan) for (s.queue.items, 0..) |*e, i| {
            if (e.kind == .rescan or !std.mem.eql(u8, e.path, path)) continue;
            e.at = at;
            switch (kind) {
                .modify => {},
                .remove => if (e.kind == .create) {
                    // A file that came and went in the window never existed
                    // for the program.
                    gpa.free(e.path);
                    _ = s.queue.orderedRemove(i);
                } else {
                    e.kind = .remove;
                },
                .create => if (e.kind == .remove) {
                    e.kind = .modify;
                },
                .rescan => unreachable,
            }
            return;
        };
        const p = gpa.dupe(u8, path) catch return;
        s.queue.append(gpa, .{ .kind = kind, .path = p, .at = at }) catch gpa.free(p);
    }

    fn push(s: *Shared, kind: Kind, path: []const u8) void {
        const at = monotonic();
        s.lock();
        s.pushLocked(kind, path, at);
        s.unlock();
    }

    /// Takes the first event whose window has passed, or returns how long
    /// to wait for one, or null when the queue is empty.
    fn take(s: *Shared, now: u64) union(enum) { event: Event, wait_ns: u64, empty } {
        s.lock();
        defer s.unlock();
        var soonest: ?u64 = null;
        for (s.queue.items, 0..) |e, i| {
            if (e.kind == .rescan or now >= e.at + merge_ns) return .{ .event = s.queue.orderedRemove(i) };
            const left = e.at + merge_ns - now;
            if (soonest == null or left < soonest.?) soonest = left;
        }
        if (soonest) |w| return .{ .wait_ns = w };
        return .empty;
    }
};

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn monotonic() u64 {
    var ts: std.c.timespec = undefined;
    if (windows) return GetTickCount64() * std.time.ns_per_ms;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Watcher = struct {
    shared: ?*Shared = null,
    filter: ?walk.Filter = null,
    backend: Backend = .{},
};

const watcher_key = "fs.watcher";

pub fn open(l: *Thread, fs_t: *Table) Error!void {
    if (!supported) return;
    const mt = try l.newTable(0, 4);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setField(l, mt, "__close", try aux.native(l, close, "__close"));
    try aux.setField(l, mt, "__gc", try aux.native(l, close, "__gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue("watcher"));
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), watcher_key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, watcher_key, mt) catch return l.raiseMem();
    try aux.setField(l, fs_t, "watch", try aux.native(l, watch, "watch"));
}

fn watcherMt(l: *Thread) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(watcher_key).?));
}

fn toWatcher(l: *Thread, v: Value) ?*Watcher {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != watcherMt(l)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn close(l: *Thread) Error!u32 {
    const w = toWatcher(l, l.arg(1)) orelse return 0;
    stop(w);
    return 0;
}

fn stop(w: *Watcher) void {
    const s = w.shared orelse return;
    w.backend.stop(s);
    // The backend has stopped its thread or drained its callback queue, so
    // no callback runs any more. Taking the lock orders the last one that
    // ran, which released it, before the free, in a way ThreadSanitizer
    // also sees through the callbacks of the system.
    s.lock();
    s.unlock();
    s.deinit();
    w.shared = null;
    if (w.filter) |*f| f.g.deinit();
    w.filter = null;
}

/// `fs.watch(path [, options])`.
fn watch(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const opts: ?*Table = if (l.arg(2).isNil()) null else try aux.checkTable(l, 2);
    try pledge.require(l, "fs:read", path);
    var recursive = false;
    var glob: ?[]const u8 = null;
    if (opts) |t| {
        const r = try aux.getField(l, t, "recursive");
        if (!r.isNil()) {
            if (r.tag != .true and r.tag != .false) return aux.argError(l, 2, "option 'recursive' must be a boolean", .{});
            recursive = r.tag == .true;
        }
        const g = try aux.getField(l, t, "glob");
        if (!g.isNil()) {
            if (g.tag != .string) return aux.argError(l, 2, "option 'glob' must be a string", .{});
            glob = g.as(String).bytes();
        }
    }
    const io = l.g.io;
    const st = Dir.cwd().statFile(io, path, .{}) catch |e| return l.raiseFmt("cannot watch '{s}': {s}", .{ path, os_lib.errnoOf(e).msg });
    if (!sched.enableNotify(l.g)) return l.raiseFmt("cannot watch '{s}': the scheduler has no wake source", .{path});

    const mt = watcherMt(l);
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Watcher), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Watcher);
    u.nuser = 0;
    u.metatable = mt;
    const w: *Watcher = @ptrCast(@alignCast(u.data()));
    w.* = .{};
    const uv = Value.obj(.userdata, u);
    try l.push(uv);
    try base_lib.registerFinalizer(l, &u.hdr, mt);

    const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, if (windows) "/\\" else "/") else path;
    const s = gpa.create(Shared) catch return l.raiseMem();
    s.* = .{
        .g = l.g,
        .root = gpa.dupe(u8, trimmed) catch {
            gpa.destroy(s);
            return l.raiseMem();
        },
        .root_real = undefined,
        .recursive = recursive,
        .is_file = st.kind != .directory,
    };
    s.root_real = blk: {
        const r = Dir.cwd().realPathFileAlloc(io, path, gpa) catch break :blk gpa.dupe(u8, trimmed) catch {
            gpa.free(s.root);
            gpa.destroy(s);
            return l.raiseMem();
        };
        defer gpa.free(r);
        break :blk gpa.dupe(u8, r) catch {
            gpa.free(s.root);
            gpa.destroy(s);
            return l.raiseMem();
        };
    };
    {
        var ts: std.c.timespec = undefined;
        if (!windows and std.c.clock_gettime(.REALTIME, &ts) == 0) s.start_real = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    w.shared = s;
    if (glob) |gl| w.filter = try walk.compileFilter(l, gpa, gl);
    w.backend.start(l, s) catch |e| {
        const msg = switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.Unavailable => "file notifications are unavailable",
            error.Failed => "the system refused the watch",
        };
        stop(w);
        return l.raiseFmt("cannot watch '{s}': {s}", .{ path, msg });
    };
    _ = try events.repeating(l, wait, "watch", uv);
    return 1;
}

/// The relative path of `path` below the root, for the glob.
fn relative(s: *Shared, path: []const u8) []const u8 {
    if (path.len > s.root.len and std.mem.startsWith(u8, path, s.root)) return path[s.root.len + 1 ..];
    return std.fs.path.basename(path);
}

/// Waits for the next event and returns it as a table.
fn wait(l: *Thread) Error!u32 {
    const w = toWatcher(l, l.arg(1)) orelse return aux.typeError(l, 1, "watcher");
    while (true) {
        if (l.event_closed) {
            stop(w);
            try events.checkClosed(l);
        }
        const s = w.shared orelse return l.raiseFmt("the watch is closed", .{});
        w.backend.poll(l, s);
        switch (s.take(monotonic())) {
            .event => |e| {
                defer gpa.free(e.path);
                if (e.kind != .rescan) {
                    if (w.filter) |*f| {
                        var rel_buf: std.ArrayList(u8) = .empty;
                        defer rel_buf.deinit(gpa);
                        const rel = relative(s, e.path);
                        rel_buf.appendSlice(gpa, rel) catch return l.raiseMem();
                        if (windows) std.mem.replaceScalar(u8, rel_buf.items, '\\', '/');
                        if (!f.matches(rel_buf.items, std.fs.path.basename(e.path))) continue;
                    }
                    // A path outside the grant is never reported.
                    if (!pledge.allowed(l, "fs:read", e.path)) continue;
                }
                const t = try l.newTable(0, 2);
                try l.push(Value.obj(.table, t));
                try aux.setField(l, t, "kind", try l.newStringValue(e.kind.name()));
                try aux.setField(l, t, "path", try os_lib.lossyString(l, e.path));
                return 1;
            },
            .wait_ns => |ns| {
                const ms: i32 = @intCast(@min(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
                try w.backend.wait(l, @max(ms, 1));
            },
            .empty => try w.backend.wait(l, -1),
        }
    }
}

// ---------------------------------------------------------------------
// Backends

const Backend = if (linux) Inotify else if (macos) FsEvents else if (windows) WinWatch else struct {
    fn start(_: *@This(), _: *Thread, _: *Shared) StartError!void {
        return error.Unavailable;
    }
    fn stop(_: *@This(), _: *Shared) void {}
    fn poll(_: *@This(), _: *Thread, _: *Shared) void {}
    fn wait(_: *@This(), l: *Thread, ms: i32) Error!void {
        try sched.waitNotifyFor(l, ms);
    }
};

const StartError = error{ OutOfMemory, Unavailable, Failed };

// --- inotify ----------------------------------------------------------

const Inotify = struct {
    fd: i32 = -1,
    /// The path each watch descriptor stands for.
    paths: std.AutoHashMapUnmanaged(i32, []u8) = .empty,

    const IN_MODIFY = 0x2;
    const IN_ATTRIB = 0x4;
    const IN_CLOSE_WRITE = 0x8;
    const IN_MOVED_FROM = 0x40;
    const IN_MOVED_TO = 0x80;
    const IN_CREATE = 0x100;
    const IN_DELETE = 0x200;
    const IN_DELETE_SELF = 0x400;
    const IN_MOVE_SELF = 0x800;
    const IN_Q_OVERFLOW = 0x4000;
    const IN_IGNORED = 0x8000;
    const IN_ONLYDIR = 0x1000000;
    const IN_ISDIR = 0x40000000;
    const IN_NONBLOCK = 0x800;
    const IN_CLOEXEC = 0x80000;
    const dir_mask = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF;
    const file_mask = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF;

    extern "c" fn inotify_init1(flags: c_uint) c_int;
    extern "c" fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;

    fn start(b: *Inotify, l: *Thread, s: *Shared) StartError!void {
        const fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (fd < 0) return error.Unavailable;
        b.fd = fd;
        if (s.is_file) {
            if (!try b.add(s.root, file_mask)) return error.Failed;
            return;
        }
        if (!try b.add(s.root, dir_mask | IN_ONLYDIR)) return error.Failed;
        if (s.recursive) try b.addTree(l, s, s.root, false);
    }

    /// Watches `path`. Returns false when the system refused.
    fn add(b: *Inotify, path: []const u8, mask: u32) error{OutOfMemory}!bool {
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        const wd = inotify_add_watch(b.fd, z, mask);
        if (wd < 0) return false;
        const gop = try b.paths.getOrPut(gpa, wd);
        if (gop.found_existing) gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = try gpa.dupe(u8, path);
        return true;
    }

    /// Watches every directory below `dir`. With `report`, also reports
    /// every entry found, for a directory that appeared during the watch
    /// and may have filled before its watch started.
    fn addTree(b: *Inotify, l: *Thread, s: *Shared, dir: []const u8, report: bool) error{OutOfMemory}!void {
        const io = l.g.io;
        var d = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            const p = try std.mem.concat(gpa, u8, &.{ dir, "/", ent.name });
            defer gpa.free(p);
            if (report) s.push(.create, p);
            if (ent.kind == .directory) {
                _ = try b.add(p, dir_mask | IN_ONLYDIR);
                try b.addTree(l, s, p, report);
            }
        }
    }

    fn stop(b: *Inotify, s: *Shared) void {
        if (b.fd >= 0) {
            // The scheduler drops its registration, since a later
            // descriptor may get the same number.
            sched.forget(s.g, b.fd);
            _ = std.c.close(b.fd);
        }
        b.fd = -1;
        var it = b.paths.valueIterator();
        while (it.next()) |p| gpa.free(p.*);
        b.paths.deinit(gpa);
    }

    /// Reads the events that are ready without waiting.
    fn poll(b: *Inotify, l: *Thread, s: *Shared) void {
        var buf: [16 * 1024]u8 align(@alignOf(u32)) = undefined;
        while (true) {
            const n = std.c.read(b.fd, &buf, buf.len);
            if (n <= 0) return;
            sched.opDone(l);
            var off: usize = 0;
            while (off + 16 <= @as(usize, @intCast(n))) {
                const wd = std.mem.readInt(i32, buf[off..][0..4], .little);
                const mask = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
                const len = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
                const raw = buf[off + 16 ..][0..len];
                off += 16 + len;
                const name = std.mem.sliceTo(raw, 0);
                b.handle(l, s, wd, mask, name) catch return;
            }
        }
    }

    fn handle(b: *Inotify, l: *Thread, s: *Shared, wd: i32, mask: u32, name: []const u8) error{OutOfMemory}!void {
        if (mask & IN_Q_OVERFLOW != 0) {
            s.push(.rescan, s.root);
            return;
        }
        const base = b.paths.get(wd) orelse return;
        if (mask & IN_IGNORED != 0) {
            if (b.paths.fetchRemove(wd)) |kv| gpa.free(kv.value);
            return;
        }
        if (name.len == 0) {
            // An event of the watched path itself.
            if (mask & (IN_DELETE_SELF | IN_MOVE_SELF) != 0) {
                if (std.mem.eql(u8, base, s.root)) s.push(.remove, base);
            } else if (s.is_file and mask & (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE) != 0) s.push(.modify, base);
            return;
        }
        const p = try std.mem.concat(gpa, u8, &.{ base, "/", name });
        defer gpa.free(p);
        if (mask & (IN_CREATE | IN_MOVED_TO) != 0) {
            s.push(.create, p);
            if (s.recursive and mask & IN_ISDIR != 0) {
                _ = try b.add(p, dir_mask | IN_ONLYDIR);
                try b.addTree(l, s, p, true);
            }
        } else if (mask & (IN_DELETE | IN_MOVED_FROM) != 0) {
            s.push(.remove, p);
        } else if (mask & (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE) != 0) {
            if (mask & IN_ISDIR == 0) s.push(.modify, p);
        }
    }

    fn wait(b: *Inotify, l: *Thread, ms: i32) Error!void {
        _ = try sched.waitIo(l, b.fd, .read, ms);
    }
};

// --- FSEvents ---------------------------------------------------------

const FsEvents = struct {
    stream: ?*anyopaque = null,
    queue: ?*anyopaque = null,

    const Callback = *const fn (stream: ?*anyopaque, info: ?*anyopaque, n: usize, paths: [*]const [*:0]const u8, flags: [*]const u32, ids: [*]const u64) callconv(.c) void;
    const Context = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        description: ?*const anyopaque = null,
    };
    const Api = struct {
        CFStringCreateWithBytes: *const fn (?*anyopaque, [*]const u8, isize, u32, u8) callconv(.c) ?*anyopaque,
        CFArrayCreate: *const fn (?*anyopaque, [*]const ?*anyopaque, isize, ?*const anyopaque) callconv(.c) ?*anyopaque,
        CFRelease: *const fn (?*anyopaque) callconv(.c) void,
        kCFTypeArrayCallBacks: *const anyopaque,
        FSEventStreamCreate: *const fn (?*anyopaque, Callback, *Context, ?*anyopaque, u64, f64, u32) callconv(.c) ?*anyopaque,
        FSEventStreamSetDispatchQueue: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
        FSEventStreamStart: *const fn (?*anyopaque) callconv(.c) u8,
        FSEventStreamStop: *const fn (?*anyopaque) callconv(.c) void,
        FSEventStreamInvalidate: *const fn (?*anyopaque) callconv(.c) void,
        FSEventStreamRelease: *const fn (?*anyopaque) callconv(.c) void,
        dispatch_queue_create: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque,
        dispatch_release: *const fn (?*anyopaque) callconv(.c) void,
        dispatch_sync_f: *const fn (?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) callconv(.c) void,
    };
    var api: ?Api = null;
    var api_tried = false;
    var api_lock: std.atomic.Mutex = .unlocked;

    const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
    const no_defer: u32 = 0x2;
    const watch_root: u32 = 0x4;
    const file_events: u32 = 0x10;
    const must_scan: u32 = 0x1;
    const user_dropped: u32 = 0x2;
    const kernel_dropped: u32 = 0x4;
    const root_changed: u32 = 0x20;
    const item_created: u32 = 0x100;
    const item_removed: u32 = 0x200;
    const item_meta: u32 = 0x400;
    const item_renamed: u32 = 0x800;
    const item_modified: u32 = 0x1000;
    const item_is_dir: u32 = 0x20000;
    const utf8: u32 = 0x08000100;
    const lstat = @extern(*const fn ([*:0]const u8, *std.c.Stat) callconv(.c) c_int, .{ .name = if (builtin.cpu.arch == .x86_64) "lstat$INODE64" else "lstat" });

    fn load() ?Api {
        while (!api_lock.tryLock()) std.atomic.spinLoopHint();
        defer api_lock.unlock();
        if (api_tried) return api;
        api_tried = true;
        const h = std.c.dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", .{ .LAZY = true }) orelse return null;
        var a: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names) |f| {
            const p = std.c.dlsym(h, f) orelse return null;
            @field(a, f) = @ptrCast(@alignCast(p));
        }
        api = a;
        return a;
    }

    fn onEvents(stream: ?*anyopaque, info: ?*anyopaque, n: usize, paths: [*]const [*:0]const u8, flags: [*]const u32, ids: [*]const u64) callconv(.c) void {
        _ = stream;
        _ = ids;
        const s: *Shared = @ptrCast(@alignCast(info.?));
        const at = monotonic();
        var any = false;
        s.lock();
        for (0..n) |i| {
            const f = flags[i];
            const real = std.mem.span(paths[i]);
            if (f & (must_scan | user_dropped | kernel_dropped | root_changed) != 0) {
                s.pushLocked(.rescan, s.root, at);
                any = true;
                continue;
            }
            // The path the program knows: the root it passed, then the part
            // below the resolved root.
            if (!std.mem.startsWith(u8, real, s.root_real)) continue;
            const rest = real[s.root_real.len..];
            if (rest.len > 0 and rest[0] != '/') continue;
            if (s.is_file) {
                if (rest.len != 0) continue;
            } else {
                if (rest.len == 0) continue;
                if (!s.recursive and std.mem.indexOfScalar(u8, rest[1..], '/') != null) continue;
            }
            const user = std.mem.concat(gpa, u8, &.{ s.root, rest }) catch continue;
            defer gpa.free(user);
            var st: std.c.Stat = undefined;
            const exists = lstat(paths[i], &st) == 0;
            const kind: ?Kind = kind: {
                if (!exists) {
                    if (s.seen.fetchRemove(real)) |kv| gpa.free(kv.key);
                    break :kind .remove;
                }
                // The flags of FSEvents accumulate and may leave out that an
                // item was created, so a path that appeared during the watch
                // is one born after it started, or one renamed into place,
                // that was not reported yet.
                const born = st.birthtimespec;
                const born_ns = @as(i128, born.sec) * std.time.ns_per_s + born.nsec;
                if (!s.seen.contains(real) and (born_ns >= s.start_real or f & item_renamed != 0)) {
                    if (gpa.dupe(u8, real)) |k| s.seen.put(gpa, k, {}) catch gpa.free(k) else |_| {}
                    break :kind .create;
                }
                if (f & item_is_dir != 0) break :kind null;
                if (f & (item_modified | item_meta | item_created | item_renamed) != 0) break :kind .modify;
                break :kind null;
            };
            if (kind) |k| {
                s.pushLocked(k, user, at);
                any = true;
            }
        }
        // The wake of the scheduler stays inside the lock, so the stop of
        // the watch, which takes the lock after the queue drains, comes
        // after it too.
        if (any) sched.notify(s.g);
        s.unlock();
    }

    fn start(b: *FsEvents, l: *Thread, s: *Shared) StartError!void {
        _ = l;
        const a = load() orelse return error.Unavailable;
        // A file is watched through its directory.
        const target = if (s.is_file) std.fs.path.dirname(s.root_real) orelse "/" else s.root_real;
        const str = a.CFStringCreateWithBytes(null, target.ptr, @intCast(target.len), utf8, 0) orelse return error.OutOfMemory;
        defer a.CFRelease(str);
        var items = [_]?*anyopaque{str};
        const arr = a.CFArrayCreate(null, &items, 1, a.kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
        defer a.CFRelease(arr);
        var ctx: Context = .{ .info = s };
        const stream = a.FSEventStreamCreate(null, onEvents, &ctx, arr, since_now, 0.02, no_defer | file_events | watch_root) orelse return error.Failed;
        const q = a.dispatch_queue_create("dev.lus.watch", null) orelse {
            a.FSEventStreamRelease(stream);
            return error.Failed;
        };
        a.FSEventStreamSetDispatchQueue(stream, q);
        if (a.FSEventStreamStart(stream) == 0) {
            a.FSEventStreamInvalidate(stream);
            a.FSEventStreamRelease(stream);
            a.dispatch_release(q);
            return error.Failed;
        }
        b.stream = stream;
        b.queue = q;
    }

    fn noop(_: ?*anyopaque) callconv(.c) void {}

    fn stop(b: *FsEvents, s: *Shared) void {
        _ = s;
        const a = api orelse return;
        const stream = b.stream orelse return;
        a.FSEventStreamStop(stream);
        a.FSEventStreamInvalidate(stream);
        a.FSEventStreamRelease(stream);
        // A callback that already started finishes before the shared
        // record goes away.
        a.dispatch_sync_f(b.queue, null, noop);
        a.dispatch_release(b.queue);
        b.stream = null;
        b.queue = null;
    }

    fn poll(_: *FsEvents, _: *Thread, _: *Shared) void {}

    fn wait(_: *FsEvents, l: *Thread, ms: i32) Error!void {
        try sched.waitNotifyFor(l, ms);
    }
};

// --- ReadDirectoryChangesW --------------------------------------------

const WinWatch = struct {
    dir: ?std.os.windows.HANDLE = null,
    thread: ?std.Thread = null,

    const w = std.os.windows;
    const FILE_LIST_DIRECTORY: w.DWORD = 0x1;
    const FILE_FLAG_BACKUP_SEMANTICS: w.DWORD = 0x02000000;
    const filter: w.DWORD = 0x1 | 0x2 | 0x8 | 0x10 | 0x40; // names, attributes, size, last write, creation
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: w.DWORD, share: w.DWORD, attributes: ?*anyopaque, disposition: w.DWORD, flags: w.DWORD, template: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(dir: w.HANDLE, buf: *anyopaque, len: w.DWORD, subtree: w.BOOL, filter: w.DWORD, returned: ?*w.DWORD, overlapped: ?*anyopaque, routine: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CancelIoEx(handle: w.HANDLE, overlapped: ?*anyopaque) callconv(.winapi) w.BOOL;

    fn start(b: *WinWatch, l: *Thread, s: *Shared) StartError!void {
        _ = l;
        const target = if (s.is_file) std.fs.path.dirname(s.root_real) orelse s.root_real else s.root_real;
        const name = std.unicode.wtf8ToWtf16LeAllocZ(gpa, target) catch return error.Failed;
        defer gpa.free(name);
        const h = CreateFileW(name, FILE_LIST_DIRECTORY, 0x1 | 0x2 | 0x4, null, 3, FILE_FLAG_BACKUP_SEMANTICS, null);
        if (h == w.INVALID_HANDLE_VALUE) return error.Failed;
        b.dir = h;
        b.thread = std.Thread.spawn(.{}, run, .{ h, s }) catch {
            w.CloseHandle(h);
            b.dir = null;
            return error.Failed;
        };
    }

    fn run(h: w.HANDLE, s: *Shared) void {
        var buf: [64 * 1024]u8 align(@alignOf(u32)) = undefined;
        while (true) {
            var got: w.DWORD = 0;
            if (!ReadDirectoryChangesW(h, &buf, buf.len, if (s.recursive) .TRUE else .FALSE, filter, &got, null, null).toBool()) return;
            const at = monotonic();
            s.lock();
            if (got == 0) {
                // The buffer overflowed.
                s.pushLocked(.rescan, s.root, at);
            } else {
                var off: usize = 0;
                while (true) {
                    const next = std.mem.readInt(u32, buf[off..][0..4], .little);
                    const action = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
                    const len = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
                    const name16: []const u16 = @ptrCast(@alignCast(buf[off + 12 ..][0..len]));
                    var name8: [1024]u8 = undefined;
                    var n8: usize = 0;
                    var it = std.unicode.Wtf16LeIterator.init(name16);
                    while (it.nextCodepoint()) |cp| {
                        if (n8 + 4 > name8.len) break;
                        n8 += std.unicode.wtf8Encode(cp, name8[n8..]) catch break;
                    }
                    const rel = name8[0..n8];
                    const kind: ?Kind = switch (action) {
                        1, 5 => .create,
                        2, 4 => .remove,
                        3 => .modify,
                        else => null,
                    };
                    if (kind) |k| {
                        // A file is watched through its directory, so the
                        // name is relative to that directory.
                        const dir = if (s.is_file) std.fs.path.dirname(s.root_real) orelse s.root_real else s.root_real;
                        if (std.mem.concat(gpa, u8, &.{ dir, "\\", rel })) |real| {
                            defer gpa.free(real);
                            const keep = if (s.is_file) std.ascii.eqlIgnoreCase(real, s.root_real) else true;
                            if (keep) {
                                const user = if (s.is_file) gpa.dupe(u8, s.root) catch null else std.mem.concat(gpa, u8, &.{ s.root, "\\", rel }) catch null;
                                if (user) |u| {
                                    s.pushLocked(k, u, at);
                                    gpa.free(u);
                                }
                            }
                        } else |_| {}
                    }
                    if (next == 0) break;
                    off += next;
                }
            }
            sched.notify(s.g);
            s.unlock();
        }
    }

    fn stop(b: *WinWatch, s: *Shared) void {
        _ = s;
        const h = b.dir orelse return;
        _ = CancelIoEx(h, null);
        w.CloseHandle(h);
        if (b.thread) |t| t.join();
        b.dir = null;
        b.thread = null;
    }

    fn poll(_: *WinWatch, _: *Thread, _: *Shared) void {}

    fn wait(_: *WinWatch, l: *Thread, ms: i32) Error!void {
        try sched.waitNotifyFor(l, ms);
    }
};

// ---------------------------------------------------------------------
// Tests of the queue, which set the clock themselves

fn testShared() Shared {
    return .{ .g = undefined, .root = &[_]u8{}, .root_real = &[_]u8{}, .recursive = false, .is_file = false };
}

fn freeQueue(s: *Shared) void {
    for (s.queue.items) |e| gpa.free(e.path);
    s.queue.deinit(gpa);
}

fn expectTake(s: *Shared, now: u64, kind: Kind, path: []const u8) !void {
    const e = switch (s.take(now)) {
        .event => |e| e,
        else => return error.TestExpectedEvent,
    };
    defer gpa.free(e.path);
    try std.testing.expectEqual(kind, e.kind);
    try std.testing.expectEqualStrings(path, e.path);
}

fn expectEmpty(s: *Shared, now: u64) !void {
    try std.testing.expect(s.take(now) == .empty);
}

const milli = std.time.ns_per_ms;

test "changes of one path within the window merge into its creation" {
    var s = testShared();
    defer freeQueue(&s);
    s.pushLocked(.create, "a", 0);
    s.pushLocked(.modify, "a", 10 * milli);
    s.pushLocked(.modify, "a", 20 * milli);
    // The window runs from the last change.
    try std.testing.expectEqual(@as(u64, 40 * milli), s.take(30 * milli).wait_ns);
    try expectTake(&s, 70 * milli, .create, "a");
    try expectEmpty(&s, 70 * milli);
}

test "a creation and a removal in one window leave nothing" {
    var s = testShared();
    defer freeQueue(&s);
    s.pushLocked(.create, "a", 0);
    s.pushLocked(.remove, "a", 10 * milli);
    try expectEmpty(&s, 100 * milli);
}

test "a removal and a creation in one window make a change" {
    var s = testShared();
    defer freeQueue(&s);
    s.pushLocked(.remove, "a", 0);
    s.pushLocked(.create, "a", 10 * milli);
    try expectTake(&s, 100 * milli, .modify, "a");
}

test "a change after a delivered event is an event of its own" {
    var s = testShared();
    defer freeQueue(&s);
    s.pushLocked(.create, "a", 0);
    try expectTake(&s, 50 * milli, .create, "a");
    s.pushLocked(.modify, "a", 60 * milli);
    try expectTake(&s, 110 * milli, .modify, "a");
}

test "events of different paths stay apart and keep their order" {
    var s = testShared();
    defer freeQueue(&s);
    s.pushLocked(.create, "a", 0);
    s.pushLocked(.create, "b", 1 * milli);
    s.pushLocked(.rescan, "", 2 * milli);
    // A rescan is handed over without a window.
    try expectTake(&s, 2 * milli, .rescan, "");
    try expectTake(&s, 60 * milli, .create, "a");
    try expectTake(&s, 60 * milli, .create, "b");
    try expectEmpty(&s, 60 * milli);
}
