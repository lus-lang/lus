//! The recursive directory walk behind `fs.walk` and the globs of
//! `fs.list` that reach below the listed directory. The walk is depth
//! first. It reads a directory when it reaches it, sorts the names of each
//! directory by their bytes, and reports every entry before the entries
//! inside it. A directory that `fs:read` does not cover is reported but
//! not entered.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const pledge = @import("../vm/pledge.zig");
const aux = @import("auxlib.zig");
const base_lib = @import("base.zig");
const os = @import("os.zig");
const glob = @import("glob.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const Dir = std.Io.Dir;

const windows = builtin.os.tag == .windows;
const sep: u8 = if (windows) '\\' else '/';

pub const Kind = enum { file, directory };

/// A glob that matches the name of an entry when it has no `/`, and its
/// path relative to the start of the walk otherwise.
pub const Filter = struct {
    g: glob.Glob,
    by_name: bool,

    pub fn matches(f: *const Filter, rel: []const u8, name: []const u8) bool {
        return f.g.match(if (f.by_name) name else rel);
    }
};

const Frame = struct {
    path: []u8,
    rel: []u8,
    names: [][]u8,
    kinds: []std.Io.File.Kind,
    idx: usize = 0,
    /// The depth of the entries of this directory: 1 for the entries of the
    /// starting directory.
    depth: u32,
    /// The resolved path, kept to find cycles when links are followed.
    real: ?[:0]u8,

    fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        for (f.names) |n| gpa.free(n);
        gpa.free(f.names);
        gpa.free(f.kinds);
        gpa.free(f.path);
        gpa.free(f.rel);
        if (f.real) |r| gpa.free(r);
    }
};

const Pending = struct { path: []u8, rel: []u8, depth: u32 };

pub const Entry = struct {
    path: []const u8,
    rel: []const u8,
    kind: Kind,
    is_link: bool,
};

pub const Walker = struct {
    gpa: std.mem.Allocator,
    root: []u8,
    /// 0 for no limit.
    max_depth: u32 = 0,
    follow: bool = false,
    skip_errors: bool = false,
    filter: ?Filter = null,
    excludes: std.ArrayList(Filter) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    pending: ?Pending = null,
    started: bool = false,
    closed: bool = false,
    /// The path and relative path of the last entry returned.
    cur_path: std.ArrayList(u8) = .empty,
    cur_rel: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Walker) void {
        if (w.closed) return;
        w.closed = true;
        for (w.stack.items) |*f| f.deinit(w.gpa);
        w.stack.deinit(w.gpa);
        if (w.pending) |p| {
            w.gpa.free(p.path);
            w.gpa.free(p.rel);
            w.pending = null;
        }
        if (w.filter) |*f| f.g.deinit();
        for (w.excludes.items) |*f| f.g.deinit();
        w.excludes.deinit(w.gpa);
        w.cur_path.deinit(w.gpa);
        w.cur_rel.deinit(w.gpa);
        w.gpa.free(w.root);
    }

    fn join(w: *Walker, a: []const u8, b: []const u8, s: u8) error{OutOfMemory}![]u8 {
        if (a.len == 0) return w.gpa.dupe(u8, b);
        const needs = a[a.len - 1] != '/' and !(windows and a[a.len - 1] == '\\');
        return std.mem.concat(w.gpa, u8, &.{ a, if (needs) &[_]u8{s} else "", b });
    }

    /// Reads the directory at `path` into a new frame. Returns false when
    /// the directory was skipped after an error.
    fn enter(w: *Walker, l: *Thread, path: []u8, rel: []u8, depth: u32) Error!bool {
        const gpa = w.gpa;
        const io = l.g.io;
        var owned = true;
        defer if (owned) {
            gpa.free(path);
            gpa.free(rel);
        };
        var real: ?[:0]u8 = null;
        if (w.follow) {
            real = Dir.cwd().realPathFileAlloc(io, path, gpa) catch null;
            if (real) |r| for (w.stack.items) |f| if (f.real) |fr| if (std.mem.eql(u8, fr, r)) {
                // A link back to a directory that the walk is inside.
                gpa.free(r);
                return false;
            };
        }
        errdefer if (real) |r| gpa.free(r);
        var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| {
            if (real) |r| gpa.free(r);
            real = null;
            if (e == error.NotDir and !w.started) return l.raiseFmt("{s} is not a directory", .{path});
            if (w.skip_errors and w.started) return false;
            return l.raiseFmt("cannot list directory {s}: {s}", .{ path, os.errnoOf(e).msg });
        };
        defer dir.close(io);
        var names: std.ArrayList([]u8) = .empty;
        var kinds: std.ArrayList(std.Io.File.Kind) = .empty;
        defer {
            if (owned) {
                for (names.items) |n| gpa.free(n);
            }
            names.deinit(gpa);
            kinds.deinit(gpa);
        }
        var it = dir.iterate();
        while (true) {
            const entry = it.next(io) catch |e| {
                if (real) |r| gpa.free(r);
                real = null;
                if (w.skip_errors and w.started) return false;
                return l.raiseFmt("cannot list directory {s}: {s}", .{ path, os.errnoOf(e).msg });
            };
            const ent = entry orelse break;
            if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
            const n = gpa.dupe(u8, ent.name) catch return l.raiseMem();
            names.append(gpa, n) catch {
                gpa.free(n);
                return l.raiseMem();
            };
            kinds.append(gpa, ent.kind) catch return l.raiseMem();
        }
        // Sort the names and keep each kind with its name.
        const Pair = struct { name: []u8, kind: std.Io.File.Kind };
        const pairs = gpa.alloc(Pair, names.items.len) catch return l.raiseMem();
        defer gpa.free(pairs);
        for (pairs, names.items, kinds.items) |*p, n, k| p.* = .{ .name = n, .kind = k };
        std.mem.sort(Pair, pairs, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        for (pairs, 0..) |p, i| {
            names.items[i] = p.name;
            kinds.items[i] = p.kind;
        }
        const name_slice = names.toOwnedSlice(gpa) catch return l.raiseMem();
        const kind_slice = kinds.toOwnedSlice(gpa) catch {
            names = .fromOwnedSlice(name_slice);
            return l.raiseMem();
        };
        w.stack.append(gpa, .{ .path = path, .rel = rel, .names = name_slice, .kinds = kind_slice, .depth = depth, .real = real }) catch {
            for (name_slice) |n| gpa.free(n);
            gpa.free(name_slice);
            gpa.free(kind_slice);
            return l.raiseMem();
        };
        owned = false;
        return true;
    }

    /// Returns the next entry, or null when the walk is over. The slices of
    /// the entry stay valid until the next call.
    pub fn next(w: *Walker, l: *Thread) Error!?Entry {
        const gpa = w.gpa;
        const io = l.g.io;
        if (w.closed) return null;
        if (!w.started) {
            const p = gpa.dupe(u8, w.root) catch return l.raiseMem();
            const r = gpa.dupe(u8, "") catch {
                gpa.free(p);
                return l.raiseMem();
            };
            _ = try w.enter(l, p, r, 1);
            w.started = true;
        }
        if (w.pending) |p| {
            w.pending = null;
            _ = try w.enter(l, p.path, p.rel, p.depth);
        }
        while (w.stack.items.len > 0) {
            const top = &w.stack.items[w.stack.items.len - 1];
            if (top.idx == top.names.len) {
                var f = w.stack.pop().?;
                f.deinit(gpa);
                continue;
            }
            const name = top.names[top.idx];
            const dkind = top.kinds[top.idx];
            top.idx += 1;
            const depth = top.depth;
            w.cur_path.clearRetainingCapacity();
            w.cur_rel.clearRetainingCapacity();
            {
                const jp = w.join(top.path, name, sep) catch return l.raiseMem();
                defer gpa.free(jp);
                w.cur_path.appendSlice(gpa, jp) catch return l.raiseMem();
                const jr = w.join(top.rel, name, '/') catch return l.raiseMem();
                defer gpa.free(jr);
                w.cur_rel.appendSlice(gpa, jr) catch return l.raiseMem();
            }
            const path = w.cur_path.items;
            const rel = w.cur_rel.items;
            var excluded = false;
            for (w.excludes.items) |*f| if (f.matches(rel, name)) {
                excluded = true;
            };
            if (excluded) continue;
            var kind: Kind = .file;
            var is_link = false;
            switch (dkind) {
                .directory => kind = .directory,
                .sym_link, .unknown => {
                    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch null;
                    if (st) |s| {
                        is_link = s.kind == .sym_link;
                        if (is_link) {
                            if (Dir.cwd().statFile(io, path, .{})) |t| {
                                if (t.kind == .directory) kind = .directory;
                            } else |_| {}
                        } else if (s.kind == .directory) kind = .directory;
                    }
                },
                else => {},
            }
            const reported = if (w.filter) |*f| f.matches(rel, name) else true;
            if (kind == .directory and (!is_link or w.follow) and
                (w.max_depth == 0 or depth < w.max_depth) and
                (w.filter == null or w.filter.?.by_name or w.filter.?.g.mayContain(rel)) and
                pledge.allowed(l, "fs:read", path))
            {
                const p = gpa.dupe(u8, path) catch return l.raiseMem();
                const r = gpa.dupe(u8, rel) catch {
                    gpa.free(p);
                    return l.raiseMem();
                };
                if (reported) {
                    // Enter the directory on the next call, so that an error
                    // reading it comes after the entry itself.
                    w.pending = .{ .path = p, .rel = r, .depth = depth + 1 };
                } else {
                    _ = try w.enter(l, p, r, depth + 1);
                    continue;
                }
            }
            if (!reported) continue;
            return .{ .path = path, .rel = rel, .kind = kind, .is_link = is_link };
        }
        return null;
    }
};

pub fn compileFilter(l: *Thread, gpa: std.mem.Allocator, pattern: []const u8) Error!Filter {
    const g = glob.compile(gpa, pattern) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.TooManyAlternatives => return l.raiseFmt("glob '{s}' expands to more than {d} patterns", .{ pattern, glob.max_alternatives }),
    };
    return .{ .g = g, .by_name = std.mem.indexOfScalar(u8, pattern, '/') == null and !g.deep };
}

// ---------------------------------------------------------------------
// fs.walk

const walker_key = "fs.walker";

pub fn open(l: *Thread) Error!void {
    const mt = try l.newTable(0, 3);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    try aux.setField(l, mt, "__gc", try aux.native(l, walkerGc, "__gc"));
    try aux.setField(l, mt, "__close", try aux.native(l, walkerGc, "__close"));
    try aux.setField(l, mt, "__name", try l.newStringValue(walker_key));
    try aux.setField(l, mt, "__metatable", .false);
    try aux.setField(l, l.g.registry.as(Table), walker_key, Value.obj(.table, mt));
    l.g.ext.put(l.g.gpa, walker_key, mt) catch return l.raiseMem();
}

fn walkerMt(l: *Thread) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(walker_key).?));
}

fn toWalker(l: *Thread, v: Value) ?*Walker {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != walkerMt(l)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn walkerGc(l: *Thread) Error!u32 {
    if (toWalker(l, l.arg(1))) |w| w.deinit();
    return 0;
}

/// Reads one option of the table at argument 2.
fn optField(l: *Thread, opts: ?*Table, name: []const u8) Error!Value {
    const t = opts orelse return .nil;
    return aux.getField(l, t, name);
}

fn optionString(l: *Thread, v: Value, name: []const u8) Error![]const u8 {
    if (v.tag != .string) return aux.argError(l, 2, "option '{s}' must be a string", .{name});
    return v.as(object.String).bytes();
}

/// `fs.walk(dir [, options])`.
pub fn walk(l: *Thread) Error!u32 {
    const dir = try aux.checkBytes(l, 1);
    const opts: ?*Table = if (l.arg(2).isNil()) null else try aux.checkTable(l, 2);
    try pledge.require(l, "fs:read", dir);
    const gpa = l.g.gpa;
    const mt = walkerMt(l);
    gc.maybeCollect(l.g);
    const u = gc.alloc(l.g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Walker), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Walker);
    u.nuser = 0;
    u.metatable = mt;
    const w: *Walker = @ptrCast(@alignCast(u.data()));
    // Closed until it owns its root, so that a collection in between frees
    // nothing.
    w.* = .{ .gpa = gpa, .root = &.{}, .closed = true };
    const uv = Value.obj(.userdata, u);
    try l.push(uv);
    try base_lib.registerFinalizer(l, &u.hdr, mt);
    w.root = gpa.dupe(u8, dir) catch return l.raiseMem();
    w.closed = false;

    const depth = try optField(l, opts, "depth");
    if (!depth.isNil()) {
        const d = ops.toIntegerStrict(depth) orelse return aux.argError(l, 2, "option 'depth' must be an integer", .{});
        if (d < 1) return aux.argError(l, 2, "option 'depth' must be at least 1", .{});
        w.max_depth = @intCast(@min(d, std.math.maxInt(u32)));
    }
    const links = try optField(l, opts, "links");
    if (!links.isNil()) {
        const s = try optionString(l, links, "links");
        if (std.mem.eql(u8, s, "follow")) w.follow = true else if (!std.mem.eql(u8, s, "list"))
            return aux.argError(l, 2, "option 'links' must be \"list\" or \"follow\"", .{});
    }
    const errs = try optField(l, opts, "errors");
    if (!errs.isNil()) {
        const s = try optionString(l, errs, "errors");
        if (std.mem.eql(u8, s, "skip")) w.skip_errors = true else if (!std.mem.eql(u8, s, "raise"))
            return aux.argError(l, 2, "option 'errors' must be \"raise\" or \"skip\"", .{});
    }
    const g = try optField(l, opts, "glob");
    if (!g.isNil()) w.filter = try compileFilter(l, gpa, try optionString(l, g, "glob"));
    const ex = try optField(l, opts, "exclude");
    switch (ex.tag) {
        .nil => {},
        .string => {
            const f = try compileFilter(l, gpa, ex.as(object.String).bytes());
            w.excludes.append(gpa, f) catch {
                var ff = f;
                ff.g.deinit();
                return l.raiseMem();
            };
        },
        .table => {
            var i: i64 = 1;
            while (true) : (i += 1) {
                const item = @import("../vm/table.zig").getInt(ex.as(Table), i);
                if (item.isNil()) break;
                if (item.tag != .string) return aux.argError(l, 2, "option 'exclude' must hold strings", .{});
                const f = try compileFilter(l, gpa, item.as(object.String).bytes());
                w.excludes.append(gpa, f) catch {
                    var ff = f;
                    ff.g.deinit();
                    return l.raiseMem();
                };
            }
        },
        else => return aux.argError(l, 2, "option 'exclude' must be a string or a table of strings", .{}),
    }
    const n = state.newNative(l.g, walkStep, "walk", 1) catch return l.raiseMem();
    n.upvalues()[0] = uv;
    try l.push(Value.obj(.native, n));
    try l.push(.nil);
    try l.push(.nil);
    try l.push(uv);
    return 4;
}

fn walkStep(l: *Thread) Error!u32 {
    const w = toWalker(l, l.frame().native.?.upvalues()[0]).?;
    const e = (try w.next(l)) orelse {
        w.deinit();
        try l.push(.nil);
        return 1;
    };
    try l.push(try os.lossyString(l, e.path));
    try l.push(try l.newStringValue(if (e.kind == .directory) "directory" else "file"));
    try l.push(Value.boolean(e.is_link));
    return 3;
}

/// The part of `fs.list` for a glob that reaches below `path`. Pushes the
/// table of matching relative paths.
pub fn listDeep(l: *Thread, path: []const u8, f: Filter) Error!u32 {
    var w: Walker = .{ .gpa = l.g.gpa, .root = l.g.gpa.dupe(u8, path) catch {
        var ff = f;
        ff.g.deinit();
        return l.raiseMem();
    }, .filter = f };
    defer w.deinit();
    const t = try l.newTable(0, 0);
    try l.push(Value.obj(.table, t));
    var idx: i64 = 1;
    while (try w.next(l)) |e| {
        try ops.rawSet(l, t, Value.int(idx), try os.lossyString(l, e.rel));
        idx += 1;
    }
    return 1;
}
