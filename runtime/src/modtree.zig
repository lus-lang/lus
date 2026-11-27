//! The require tree of a program (`spec/design/modules.md`, section 2).
//!
//! `scan` finds the literal requires of a chunk in its syntax tree and
//! notes whether the chunk loads modules dynamically. `Index` follows the
//! literal requires of a program from its main chunk, resolves each name
//! through the starting `package.path`, and compiles every module it finds
//! once. `require` then loads a module of the index from its compiled form
//! when it reaches the same file unchanged.
//!
//! The index changes nothing that a program observes. It never runs a
//! module. A module that fails to compile keeps its error, which `require`
//! raises when the program requires that module. Each `require` still
//! resolves its name through the current `package.path` and checks its
//! permissions, so the index only moves reading and compiling earlier.

const std = @import("std");
const ast = @import("syntax/ast.zig");
const parser = @import("syntax/parser.zig");
const resolve = @import("syntax/resolve.zig");
const walk = @import("syntax/walk.zig");
const Allocator = std.mem.Allocator;

/// What `scan` found in one chunk.
pub const Scan = struct {
    /// The names of the literal requires, in source order, with repeats.
    literal: []const []const u8,
    /// Whether the chunk contains a dynamic require: a call of `require`
    /// with another argument than one string constant, another use of the
    /// global `require`, a use of `load`, `loadfile`, `dofile`, or `rawget`,
    /// or a read of `_G` or `_ENV` through a computed key.
    dynamic: bool,
};

/// Whether a name reference is the global of that name, which a local
/// does not hide.
fn isGlobal(ref: ?*const resolve.Ref) bool {
    const r = ref orelse return true;
    const b = r.binding orelse return true;
    return b.kind == .global or b.kind == .global_star;
}

const Scanner = struct {
    arena: Allocator,
    res: resolve.Result,
    literal: std.ArrayList([]const u8) = .empty,
    dynamic: bool = false,
    /// Global references to `require` that are the function of a call.
    require_calls: u32 = 0,

    fn globalName(s: *Scanner, e: *const ast.Expr, name: []const u8) bool {
        if (e.kind != .name) return false;
        if (!std.mem.eql(u8, e.kind.name.text, name)) return false;
        return isGlobal(s.res.refAt(e.span.start));
    }

    fn visit(s: *Scanner, slot: **ast.Expr) anyerror!void {
        const e = slot.*;
        switch (e.kind) {
            .call => |c| {
                var callee = c.callee;
                while (callee.kind == .paren) callee = callee.kind.paren;
                if (s.globalName(callee, "require")) {
                    s.require_calls += 1;
                    if (c.args.len == 1 and c.args[0].kind == .string) {
                        try s.literal.append(s.arena, c.args[0].kind.string);
                    } else {
                        s.dynamic = true;
                    }
                }
            },
            .index => |ix| {
                if ((s.globalName(ix.obj, "_G") or isEnv(s, ix.obj)) and ix.key.kind != .string) s.dynamic = true;
            },
            else => {},
        }
    }

    fn isEnv(s: *Scanner, e: *const ast.Expr) bool {
        if (e.kind != .name or !std.mem.eql(u8, e.kind.name.text, "_ENV")) return false;
        _ = s;
        return true;
    }
};

/// Scans `src`. Returns null when it does not parse, in which case the
/// index records the compile error instead.
pub fn scan(gpa: Allocator, arena: Allocator, src: []const u8, chunkname: []const u8) Allocator.Error!?Scan {
    var diag: ?[]const u8 = null;
    const chunk = parser.parse(gpa, arena, src, .{ .chunkname = chunkname }, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return scanChunk(arena, chunk);
}

/// Scans a parsed chunk without changing it.
pub fn scanChunk(arena: Allocator, chunk: ast.Chunk) Allocator.Error!?Scan {
    const res = try resolve.resolve(arena, chunk);
    var s: Scanner = .{ .arena = arena, .res = res };
    const v: walk.Visitor(*Scanner) = .{ .ctx = &s, .func = Scanner.visit };
    v.block(chunk.block) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    // Every global reference to these names other than the function of a
    // literal or dynamic require call loads code by name.
    var require_refs: u32 = 0;
    for (res.refs) |r| {
        const global = r.binding == null or r.binding.?.kind == .global or r.binding.?.kind == .global_star;
        if (!global) continue;
        if (std.mem.eql(u8, r.name, "require")) {
            if (r.write) s.dynamic = true else require_refs += 1;
        } else if (std.mem.eql(u8, r.name, "load") or std.mem.eql(u8, r.name, "loadfile") or
            std.mem.eql(u8, r.name, "dofile") or std.mem.eql(u8, r.name, "rawget"))
        {
            s.dynamic = true;
        }
    }
    if (require_refs > s.require_calls) s.dynamic = true;
    return .{ .literal = s.literal.items, .dynamic = s.dynamic };
}

/// One module of the index.
pub const Entry = struct {
    /// The module name of the first literal require that reached it.
    name: []u8,
    /// The path as `require` builds it from `package.path`.
    path: []u8,
    size: u64,
    mtime: i96,
    /// The compiled module as a binary chunk, or null after an error.
    chunk: ?[]u8,
    /// The compile error, when the module does not compile.
    err: ?[]const u8,
};

pub const Index = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Whether any chunk of the tree contains a dynamic require.
    dynamic: bool = false,
    /// The state whose flags compiled the index. A state with other flags
    /// compiles its modules itself.
    owner: ?*const anyopaque = null,
    /// Whether the index was compiled with compile-time flags.
    flagged: bool = false,

    pub fn deinit(ix: *Index) void {
        for (ix.entries.items) |e| {
            ix.gpa.free(e.name);
            ix.gpa.free(e.path);
            if (e.chunk) |c| ix.gpa.free(c);
            if (e.err) |m| ix.gpa.free(m);
        }
        ix.entries.deinit(ix.gpa);
    }

    pub fn find(ix: *const Index, path: []const u8) ?*const Entry {
        for (ix.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) return e;
        return null;
    }

    pub fn hasPath(ix: *const Index, path: []const u8) bool {
        return ix.find(path) != null;
    }
};

/// Where the index looks for modules and which files it may read.
pub const Options = struct {
    /// The allocator of the process, which owns the index. The index
    /// outlives the state that builds it, so it must never use the
    /// allocator of that state.
    gpa: Allocator,
    /// The `package.path` that the program starts with.
    path: []const u8,
    /// Decides whether the command line could ever let the program read a
    /// file. The index skips a file it refuses.
    may_read: ?*const fn (ctx: *anyopaque, path: []const u8) bool = null,
    ctx: *anyopaque = undefined,
    /// Module names that other searchers answer first: the standard
    /// library, preincluded modules, and the bundle.
    skip: *const fn (name: []const u8) bool,
    /// Decides whether the command line could ever let the program fetch
    /// a URL. Null turns fetching before the run off.
    may_fetch: ?*const fn (ctx: *anyopaque, url: []const u8) bool = null,
};

const api = @import("api.zig");
const codegen = @import("compile/codegen.zig");
const dump = @import("compile/dump.zig");
const state = @import("vm/state.zig");
const remote = @import("remote.zig");

/// The first file that a template of `path` names for `name`, as the
/// searcher of `require` builds it, or null.
fn resolveName(gpa: Allocator, io: std.Io, name: []const u8, opts: Options) !?[]u8 {
    const sep = std.fs.path.sep_str;
    const mod = try std.mem.replaceOwned(u8, gpa, name, ".", sep);
    defer gpa.free(mod);
    var it = std.mem.splitScalar(u8, opts.path, ';');
    while (it.next()) |tmpl| {
        const file = try std.mem.replaceOwned(u8, gpa, tmpl, "?", mod);
        if (opts.may_read) |f| if (!f(opts.ctx, file)) {
            gpa.free(file);
            continue;
        };
        if (std.Io.Dir.cwd().statFile(io, file, .{})) |st| {
            if (st.kind != .directory) return file;
        } else |_| {}
        gpa.free(file);
    }
    return null;
}

/// Builds the index of the program whose main chunk is `src`. The state
/// `l` provides the compile-time flags and the heap the compiler uses.
/// The index never runs code.
pub fn build(l: *state.Thread, src: []const u8, chunkname: []const u8, opts: Options) !*Index {
    const g = l.g;
    const gpa = opts.gpa;
    const io = g.io;
    const ix = try gpa.create(Index);
    errdefer gpa.destroy(ix);
    ix.* = .{ .gpa = gpa, .owner = g, .flagged = api.flagsTable(g) != null and api.flagsTable(g).?.count() > 0 };
    errdefer ix.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var queue: std.ArrayList([]u8) = .empty;
    defer {
        for (queue.items) |q| gpa.free(q);
        queue.deinit(gpa);
    }

    // A chunk that never mentions require has no literal requires.
    if (std.mem.indexOf(u8, src, "require") != null) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        if (try scan(gpa, arena_state.allocator(), src, chunkname)) |sc| {
            if (sc.dynamic) ix.dynamic = true;
            for (sc.literal) |n| try queue.append(gpa, try gpa.dupe(u8, n));
        }
    }

    var urls: std.ArrayList([]u8) = .empty;
    defer {
        for (urls.items) |u| gpa.free(u);
        urls.deinit(gpa);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const name = queue.items[head];
        if (seen.contains(name)) continue;
        try seen.put(gpa, try gpa.dupe(u8, name), {});
        if (remote.isUrl(name)) {
            try urls.append(gpa, try gpa.dupe(u8, name));
            continue;
        }
        if (opts.skip(name)) continue;
        const file = (try resolveName(gpa, io, name, opts)) orelse continue;
        if (ix.hasPath(file)) {
            gpa.free(file);
            continue;
        }
        errdefer gpa.free(file);
        const st = std.Io.Dir.cwd().statFile(io, file, .{}) catch {
            gpa.free(file);
            continue;
        };
        const msrc = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(256 << 20)) catch {
            gpa.free(file);
            continue;
        };
        defer gpa.free(msrc);
        const mname = try std.fmt.allocPrint(gpa, "@{s}", .{file});
        defer gpa.free(mname);
        var entry: Entry = .{
            .name = try gpa.dupe(u8, name),
            .path = file,
            .size = st.size,
            .mtime = st.mtime.nanoseconds,
            .chunk = null,
            .err = null,
        };
        errdefer gpa.free(entry.name);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var diag: ?[]const u8 = null;
        if (parser.parse(gpa, arena, msrc, .{ .chunkname = mname }, &diag)) |chunk| {
            if (std.mem.indexOf(u8, msrc, "require") != null) {
                if (try scanChunk(arena, chunk)) |sc| {
                    if (sc.dynamic) ix.dynamic = true;
                    for (sc.literal) |n| try queue.append(gpa, try gpa.dupe(u8, n));
                }
            }
            const was_stopped = g.gc_stopped;
            g.gc_stopped = true;
            defer g.gc_stopped = was_stopped;
            // Compiling for the index runs no code of the module. A module
            // with compile-time evaluation compiles at its `require`, after
            // the permission checks of the load and with the permissions
            // the requiring thread holds then.
            var deferred = false;
            const r = try codegen.compileAst(g, arena, chunk, .{ .chunkname = mname, .flags = api.flagsTable(g), .meta_grants = .none, .meta_deferred = &deferred });
            switch (r) {
                .err => |m| {
                    // The compiler allocates the message with the state.
                    defer g.gpa.free(m);
                    if (!deferred) entry.err = try gpa.dupe(u8, m);
                },
                .ok => |p| entry.chunk = dump.dump(gpa, p, false) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // A module the binary format cannot hold compiles at
                    // its require, as without the index.
                    error.Unsupported => null,
                },
            }
        } else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => entry.err = try gpa.dupe(u8, diag orelse "syntax error"),
        }
        if (entry.chunk == null and entry.err == null) {
            gpa.free(entry.name);
            gpa.free(entry.path);
            continue;
        }
        try ix.entries.append(gpa, entry);
    }
    if (opts.may_fetch) |may| if (remote.store) |st| try prefetch(gpa, st, urls.items, may, opts.ctx);
    return ix;
}

/// Fetches the remote modules of the tree before the program runs: the
/// literal URL requires, the `requires` of atmosphere releases, and the
/// literal requires of modules from generic servers. A failure is left
/// for the `require` that names the module to raise.
fn prefetch(gpa: Allocator, st: *remote.Store, start: []const []u8, may: *const fn (*anyopaque, []const u8) bool, ctx: *anyopaque) !void {
    var queue: std.ArrayList([]u8) = .empty;
    defer {
        for (queue.items) |q| gpa.free(q);
        queue.deinit(gpa);
    }
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    for (start) |u| {
        const n = remote.normalize(gpa, u, &why) catch continue;
        try queue.append(gpa, n);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const url = queue.items[head];
        if (!may(ctx, url)) continue;
        st.lock();
        defer st.unlock();
        if (st.peek(url) != null) continue;
        const p = st.getGuarded(url, &why, .{ .ctx = ctx, .allow = may }) catch continue;
        // A fetch before the run is the expected one, so `require` prints
        // no warning for it.
        p.fetched = false;
        for (p.requires) |r| {
            const n = remote.normalize(gpa, r, &why) catch continue;
            try queue.append(gpa, n);
        }
        if (p.kind != .generic or std.mem.indexOf(u8, p.source, "require") == null) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const sc = (try scan(gpa, arena_state.allocator(), p.source, url)) orelse continue;
        for (sc.literal) |lit| {
            if (remote.isUrl(lit)) {
                const n = remote.normalize(gpa, lit, &why) catch continue;
                try queue.append(gpa, n);
            } else if (!isBuiltin(lit)) {
                // A relative name of a generic module names a file beside it.
                const rel = try std.mem.replaceOwned(u8, gpa, lit, ".", "/");
                defer gpa.free(rel);
                const cand = try std.mem.concat(gpa, u8, &.{ remote.dirOf(url), rel, ".lus" });
                try queue.append(gpa, cand);
            }
        }
    }
}

fn isBuiltin(name: []const u8) bool {
    return @import("lib/package.zig").answeredEarly(name);
}

/// The compiled form of the module at `path` for a state with the global
/// `g`, when the index holds that file unchanged. Returns the entry, whose
/// `err` is the compile error to raise when it is set.
pub fn lookup(g: *const state.Global, path: []const u8, io: std.Io) ?*const Entry {
    if (comptime !@import("build_options").compiler) return null;
    const ix = current orelse return null;
    // The index compiled with the flags of its owner. Another state uses
    // it only when neither compiles with flags.
    if (g != @as(*const state.Global, @ptrCast(@alignCast(ix.owner.?)))) {
        if (ix.flagged) return null;
        if (api.flagsTable(@constCast(g))) |f| if (f.count() > 0) return null;
    }
    if (g.debugger != null) return null;
    const e = ix.find(path) orelse return null;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.size != e.size or st.mtime.nanoseconds != e.mtime) return null;
    return e;
}

/// The index of the running program. The CLI builds it before the main
/// chunk runs and never changes it afterwards, so workers read it freely.
pub var current: ?*const Index = null;

test "scan" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try scan(gpa, arena,
        \\local a = require("lib.a")
        \\local b = require "b"
        \\local function f() return require("c") end
        \\local t = {}
        \\t.require("not")
    , "=t")).?;
    try std.testing.expectEqual(@as(usize, 3), s.literal.len);
    try std.testing.expectEqualStrings("lib.a", s.literal[0]);
    try std.testing.expectEqualStrings("c", s.literal[2]);
    try std.testing.expect(!s.dynamic);

    const cases = [_][]const u8{
        "local m = require(name)",
        "local m = require(`plugins.$kind`)",
        "local r = require",
        "print(catch require, 'x')",
        "load('return 1')",
        "local f = _G[k]",
        "local f = _ENV[k]",
        "local v = rawget(_G, 'require')",
        "require = nil",
    };
    for (cases) |c| {
        const d = (try scan(gpa, arena, c, "=t")).?;
        std.testing.expect(d.dynamic) catch |e| {
            std.debug.print("not dynamic: {s}\n", .{c});
            return e;
        };
    }
    // A local named require is not the global.
    const loc = (try scan(gpa, arena, "local require = function() end\nrequire(x)\nlocal load = 1", "=t")).?;
    try std.testing.expect(!loc.dynamic);
    try std.testing.expectEqual(@as(usize, 0), loc.literal.len);
    // A constant key on _G is not dynamic.
    try std.testing.expect(!(try scan(gpa, arena, "local p = _G.print\nlocal q = _G['print']", "=t")).?.dynamic);
    try std.testing.expect((try scan(gpa, arena, "local x = = 1", "=t")) == null);
}

test "the index outlives the state that builds it" {
    // The CLI frees the index after it closes the state, so the index owns
    // its memory through the allocator of the process.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "good.lus", .data = "return { x = 1 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.lus", .data = "local x = = 1\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/?.lus", .{dir});
    defer gpa.free(path);
    const l = try api.newState(gpa, io);
    const Skip = struct {
        fn none(_: []const u8) bool {
            return false;
        }
    };
    const ix = try build(l, "local g = require(\"good\")\nlocal b = require(\"bad\")\n", "=main", .{ .gpa = gpa, .path = path, .skip = Skip.none });
    try std.testing.expectEqual(@as(usize, 2), ix.entries.items.len);
    api.close(l);
    ix.deinit();
    gpa.destroy(ix);
}
