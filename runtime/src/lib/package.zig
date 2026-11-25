//! Modules: `require` and the `package` table.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const pledge = @import("../vm/pledge.zig");
const modtree = @import("../modtree.zig");
const remote = @import("../remote.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

pub const default_path = "./?.lus;./?/init.lus;./?.lua;./?/init.lua";

/// The directory separator that replaces the dots of a module name, and the
/// first line of `package.config`, as in Lua.
const dirsep = if (@import("builtin").os.tag == .windows) "\\" else "/";

/// A module preincluded at startup with the CLI option `--include`. The
/// sources are read once under full authority and kept in memory, so
/// pledged code and worker states require them without file access.
pub const Preinclude = struct {
    /// Dotted module name, the key `require` looks up.
    name: []const u8,
    /// Path on disk, used for the chunk name.
    path: []const u8,
    src: []const u8,
};

/// The process-wide preinclude list. The CLI sets it before any state is
/// created and never changes it afterwards, so workers read it freely.
pub var preincludes: []const Preinclude = &.{};

const preinclude_key = "_PREINCLUDE";

/// The standard library modules that `package.loaded` holds from the
/// start, so `require` never searches a file for them.
pub const builtin_names = [_][]const u8{ "string", "table", "math", "os", "io", "coroutine", "utf8", "debug", "package", "vector", "fs", "network", "time", "worker", "_G" };

/// Whether a searcher before the file searcher answers `name`: a library
/// of the standard library, a preincluded module, or a module of the
/// bundle. The index of the require tree skips these names.
pub fn answeredEarly(name: []const u8) bool {
    for (builtin_names) |n| if (std.mem.eql(u8, n, name)) return true;
    for (preincludes) |p| if (std.mem.eql(u8, p.name, name)) return true;
    if (bundle) |b| if (b.find(name) != null) return true;
    return false;
}

/// The bundle of a standalone executable made by `lus build`, or null in
/// a plain interpreter. The CLI sets it before any state is created and
/// never changes it afterwards, so workers read it freely.
pub var bundle: ?*const @import("../bundle.zig").Bundle = null;

pub fn open(l: *Thread) Error!void {
    const pkg = try l.newTable(0, 8);
    const pv = Value.obj(.table, pkg);
    try aux.setGlobal(l, "package", pv);
    const path = envPath(l) orelse default_path;
    try aux.setField(l, pkg, "path", try l.newStringValue(path));
    try aux.setField(l, pkg, "cpath", try l.newStringValue(""));
    try aux.setField(l, pkg, "config", try l.newStringValue(dirsep ++ "\n;\n?\n!\n-\n"));
    const loaded = try l.newTable(0, 16);
    try aux.setField(l, pkg, "loaded", Value.obj(.table, loaded));
    // require uses the registry copy, so reassigning package.loaded does
    // not lose loaded modules (as in Lua).
    try aux.setField(l, l.g.registry.as(Table), "_LOADED", Value.obj(.table, loaded));
    try aux.setField(l, pkg, "preload", Value.obj(.table, try l.newTable(0, 4)));
    // The searchers and require hold the package table as an upvalue, so
    // they keep working when the global `package` is reassigned.
    const searchers = try l.newTable(6, 0);
    try aux.setField(l, pkg, "searchers", Value.obj(.table, searchers));
    const list = [_]struct { f: state.NativeFn, name: []const u8 }{
        .{ .f = searcherPreload, .name = "searcher_preload" },
        .{ .f = searcherPreinclude, .name = "searcher_preinclude" },
        .{ .f = searcherBundle, .name = "searcher_bundle" },
        .{ .f = searcherLus, .name = "searcher_Lua" },
        .{ .f = searcherC, .name = "searcher_C" },
        .{ .f = searcherCroot, .name = "searcher_Croot" },
    };
    for (list, 1..) |e, i| {
        try ops.rawSet(l, searchers, Value.int(@intCast(i)), try withPackage(l, e.f, e.name, pkg));
    }
    try aux.setFuncs(l, pkg, .fields, "package", &.{
        .{ .name = "searchpath", .func = searchpath },
        .{ .name = "loadlib", .func = loadlib },
    });
    try aux.setGlobal(l, "require", try withPackage(l, require, "require", pkg));
    // Every library opened so far is registered as loaded.
    const globals = l.g.globals.as(Table);
    for (builtin_names) |name| {
        const v = try aux.getField(l, globals, name);
        if (!v.isNil()) try aux.setField(l, loaded, name, v);
    }
    try aux.setField(l, loaded, "_G", l.g.globals);
}

fn withPackage(l: *Thread, f: state.NativeFn, name: []const u8, pkg: *Table) Error!Value {
    const n = state.newNative(l.g, f, name, 1) catch return l.raiseMem();
    n.upvalues()[0] = Value.obj(.table, pkg);
    return Value.obj(.native, n);
}

/// Compiles every preincluded module into a loader stored in the
/// registry. A source that fails to compile raises its syntax error,
/// whose chunk name names the file.
pub fn installPreincludes(l: *Thread) Error!void {
    if (preincludes.len == 0) return;
    const t = try l.newTable(0, @intCast(preincludes.len));
    try aux.setField(l, l.g.registry.as(Table), preinclude_key, Value.obj(.table, t));
    for (preincludes) |p| {
        const chunkname = std.fmt.allocPrint(l.g.gpa, "@{s}", .{p.path}) catch return l.raiseMem();
        defer l.g.gpa.free(chunkname);
        const base = l.top;
        try api.load(l, p.src, chunkname);
        try aux.setField(l, t, p.name, l.stack[l.top - 1]);
        l.top = base;
    }
}

fn envPath(l: *Thread) ?[]const u8 {
    const env = l.g.environ orelse return null;
    return env.get("LUS_PATH");
}

/// The package table captured by a searcher or by require.
fn packageTable(l: *Thread) *Table {
    return l.frame().native.?.upvalues()[0].as(Table);
}

/// Searches `path` (a ';'-separated template list) for `name`, replacing
/// each `sep` in the name with `rep`. Returns the first file that exists
/// and that the pledge allows reading. Otherwise appends a "no file" line
/// for every candidate to `tried`.
pub fn searchSep(l: *Thread, name: []const u8, path: []const u8, sep: []const u8, rep: []const u8, tried: *std.ArrayList(u8)) Error!?[]u8 {
    const gpa = l.g.gpa;
    const io = l.g.io;
    const mod = if (sep.len > 0 and std.mem.indexOf(u8, name, sep) != null)
        std.mem.replaceOwned(u8, gpa, name, sep, rep) catch return l.raiseMem()
    else
        gpa.dupe(u8, name) catch return l.raiseMem();
    defer gpa.free(mod);
    var it = std.mem.splitScalar(u8, path, ';');
    var first = true;
    while (it.next()) |tmpl| {
        // An empty template, such as the whole of an empty path, names no
        // file.
        if (tmpl.len == 0) continue;
        const file = std.mem.replaceOwned(u8, gpa, tmpl, "?", mod) catch return l.raiseMem();
        if (pledge.allowed(l, "fs:read", file)) {
            if (std.Io.Dir.cwd().statFile(io, file, .{})) |st| {
                if (st.kind != .directory) return file;
            } else |_| {}
        }
        tried.print(gpa, "{s}no file '{s}'", .{ if (first) "" else "\n\t", file }) catch return l.raiseMem();
        first = false;
        gpa.free(file);
    }
    return null;
}

/// Searches with the default separators, as `require` does.
pub fn search(l: *Thread, name: []const u8, path: []const u8, tried: *std.ArrayList(u8)) Error!?[]u8 {
    return searchSep(l, name, path, ".", dirsep, tried);
}

fn searchpath(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const path = try aux.checkBytes(l, 2);
    const sep = (try aux.optString(l, 3, ".")).?;
    const rep = (try aux.optString(l, 4, dirsep)).?;
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    if (try searchSep(l, name, path, sep, rep, &tried)) |f| {
        defer l.g.gpa.free(f);
        return aux.retStr(l, f);
    }
    try l.push(.nil);
    try l.push(try l.newStringValue(tried.items));
    return 2;
}

/// The message for a native library found on disk. Natives in this
/// runtime are Zig functions, so a C library cannot be linked in.
const native_unavailable = "native C libraries are unavailable in Lus 2.0";

/// package.loadlib(path, funcname): returns fail, a message, and the
/// failing phase. Loading native code is gated behind `fs:read` on the
/// library and the `load` permission.
fn loadlib(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    _ = try aux.checkBytes(l, 2);
    try pledge.require(l, "fs:read", path);
    if (!pledge.allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});
    try l.push(.nil);
    if (std.Io.Dir.cwd().statFile(l.g.io, path, .{})) |_| {
        try l.push(try l.newStringValue(native_unavailable));
    } else |e| {
        const msg = std.fmt.allocPrint(l.g.gpa, "cannot open {s}: {s}", .{ path, errnoText(e) }) catch return l.raiseMem();
        defer l.g.gpa.free(msg);
        try l.push(try l.newStringValue(msg));
    }
    try l.push(try l.newStringValue("open"));
    return 3;
}

fn errnoText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        else => @errorName(e),
    };
}

fn searcherPreload(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const pre = try aux.getField(l, packageTable(l), "preload");
    if (pre.tag != .table) return l.raiseFmt("'package.preload' must be a table", .{});
    const f = table.getStr(pre.as(Table), name);
    if (f.isNil()) {
        const msg = std.fmt.allocPrint(l.g.gpa, "no field package.preload['{s}']", .{name.bytes()}) catch return l.raiseMem();
        defer l.g.gpa.free(msg);
        return aux.retStr(l, msg);
    }
    try l.push(f);
    try l.push(try l.newStringValue(":preload:"));
    return 2;
}

fn searcherPreinclude(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const t = try aux.getField(l, l.g.registry.as(Table), preinclude_key);
    const f = if (t.tag == .table) table.getStr(t.as(Table), name) else Value.nil;
    if (f.tag != .closure and f.tag != .native) {
        const msg = std.fmt.allocPrint(l.g.gpa, "no preincluded module '{s}'", .{name.bytes()}) catch return l.raiseMem();
        defer l.g.gpa.free(msg);
        return aux.retStr(l, msg);
    }
    try l.push(f);
    try l.push(try l.newStringValue(":preinclude:"));
    return 2;
}

/// Finds modules in the bundle of a standalone executable. A plain
/// interpreter carries no bundle, so there this searcher finds nothing.
/// Loading a bundled module needs the `load` permission, as loading it
/// from a file does.
fn searcherBundle(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const b = bundle orelse return 0;
    const m = b.find(name) orelse {
        const msg = std.fmt.allocPrint(l.g.gpa, "no module '{s}' in the bundle", .{name}) catch return l.raiseMem();
        defer l.g.gpa.free(msg);
        return aux.retStr(l, msg);
    };
    // Bundled modules are part of the program, like preincluded ones, so
    // requiring them needs no permission.
    api.load(l, m.data, m.chunkname) catch {
        return l.raiseFmt("error loading bundled module '{s}':\n\t{s}", .{ name, api.errorMessage(l, l.err) });
    };
    for (b.modules, 0..) |x, i| if (std.mem.eql(u8, x.name, m.name)) api.bundleModuleLoaded(l, i);
    try l.push(try l.newStringValue(state.chunkId(m.chunkname)));
    return 2;
}

/// Looks `name` up in `package.<field>`, which must be a string.
fn findFile(l: *Thread, name: []const u8, comptime field: []const u8, tried: *std.ArrayList(u8)) Error!?[]u8 {
    const path = try aux.getField(l, packageTable(l), field);
    if (path.tag != .string) return l.raiseFmt("'package." ++ field ++ "' must be a string", .{});
    return search(l, name, path.as(String).bytes(), tried);
}

fn searcherLus(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    const file = (try findFile(l, name, "path", &tried)) orelse return aux.retStr(l, tried.items);
    defer l.g.gpa.free(file);
    if (!pledge.allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});
    // A module of the require tree that the index compiled from this very
    // file loads from its compiled form (`modtree.zig`).
    if (modtree.lookup(l.g, file, l.g.io)) |e| {
        const cn = std.fmt.allocPrint(l.g.gpa, "@{s}", .{file}) catch return l.raiseMem();
        defer l.g.gpa.free(cn);
        if (e.err) |msg| return l.raiseFmt("error loading module '{s}' from file '{s}':\n\t{s}", .{ name, file, msg });
        api.load(l, e.chunk.?, cn) catch {
            return l.raiseFmt("error loading module '{s}' from file '{s}':\n\t{s}", .{ name, file, api.errorMessage(l, l.err) });
        };
        try l.push(try l.newStringValue(file));
        return 2;
    }
    const src = try @import("base.zig").readFile(l, file);
    defer l.g.gpa.free(src);
    const chunkname = std.fmt.allocPrint(l.g.gpa, "@{s}", .{file}) catch return l.raiseMem();
    defer l.g.gpa.free(chunkname);
    api.load(l, src, chunkname) catch {
        return l.raiseFmt("error loading module '{s}' from file '{s}':\n\t{s}", .{ name, file, api.errorMessage(l, l.err) });
    };
    try l.push(try l.newStringValue(file));
    return 2;
}

fn nativeLoadError(l: *Thread, name: []const u8, file: []const u8) Error {
    if (!pledge.allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});
    return l.raiseFmt("error loading module '{s}' from file '{s}':\n\t{s}", .{ name, file, native_unavailable });
}

fn searcherC(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    const file = (try findFile(l, name, "cpath", &tried)) orelse return aux.retStr(l, tried.items);
    defer l.g.gpa.free(file);
    return nativeLoadError(l, name, file);
}

fn searcherCroot(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return 0;
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    const file = (try findFile(l, name[0..dot], "cpath", &tried)) orelse return aux.retStr(l, tried.items);
    defer l.g.gpa.free(file);
    return nativeLoadError(l, name, file);
}

/// The chunk name of the Lus function that called the running native,
/// without its `@`, or null.
fn callerSource(l: *Thread) ?[]const u8 {
    const frames = l.frames.items;
    if (frames.len < 2) return null;
    const f = frames[frames.len - 2];
    const c = f.closure orelse return null;
    const src = (c.proto.source orelse return null).bytes();
    if (src.len < 2 or src[0] != '@') return null;
    return src[1..];
}

fn isBuiltinName(name: []const u8) bool {
    for (builtin_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Calls `loader` for the module stored under `key` and records the
/// result in `loaded`, as `require` does. The loader receives the key and
/// `extra`.
fn runLoader(l: *Thread, loaded: *Table, key: Value, loader: Value, extra: Value) Error!u32 {
    const base = l.top;
    try l.push(loader);
    try l.push(extra);
    const r = try ops.call1(l, loader, &.{ key, extra });
    if (!r.isNil()) try ops.rawSet(l, loaded, key, r);
    var final = table.getStr(loaded, key.as(String));
    if (final.isNil()) {
        final = .true;
        try ops.rawSet(l, loaded, key, final);
    }
    l.top = base;
    try l.push(final);
    try l.push(extra);
    return 2;
}

/// Builds the flags that a module of an atmosphere package compiles with:
/// the program flags that carry the package's prefix, without the prefix,
/// and the declared defaults of the package for the others. Writes a
/// fingerprint of the result to `fp`, so a compiled chunk is shared only
/// between states that see the same flags. String values stay on the
/// stack while the caller compiles.
pub fn packageFlags(l: *Thread, gpa: std.mem.Allocator, pkg: *const remote.Package, sub: ?[]const u8, map: *std.StringHashMapUnmanaged(Value), fp: *std.ArrayList(u8)) Error!void {
    const prefix = pkg.flagPrefix(sub);
    if (api.flagsTable(l.g)) |prog| {
        var it = prog.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (k.len > prefix.len + 1 and std.mem.startsWith(u8, k, prefix) and k[prefix.len] == '.')
                map.put(gpa, k[prefix.len + 1 ..], e.value_ptr.*) catch return l.raiseMem();
        }
    }
    if (std.mem.eql(u8, prefix, pkg.name)) for (pkg.flag_defaults) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=');
        const fname = if (eq) |i| spec[0..i] else spec;
        if (map.contains(fname)) continue;
        var v: Value = .true;
        if (eq) |i| {
            const raw = spec[i + 1 ..];
            if (@import("../syntax/lexer.zig").parseNumber(raw)) |n| {
                v = switch (n) {
                    .integer => |x| Value.int(x),
                    .float => |x| Value.float(x),
                };
            } else {
                v = try l.newStringValue(raw);
                try l.push(v);
            }
        }
        map.put(gpa, fname, v) catch return l.raiseMem();
    };
    // The fingerprint lists the flags in a fixed order.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var kit = map.keyIterator();
    while (kit.next()) |k| keys.append(gpa, k.*) catch return l.raiseMem();
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (keys.items) |k| {
        const v = map.get(k).?;
        fp.print(gpa, "\x00{s}={d}:", .{ k, @backingInt(v.tag) }) catch return l.raiseMem();
        if (v.tag == .string) fp.appendSlice(gpa, v.as(String).bytes()) catch return l.raiseMem() else fp.print(gpa, "{d}", .{v.payload}) catch return l.raiseMem();
    }
}

/// `require` of a URL, or of a name inside a remote package (`remote.zig`).
/// Returns null when the name is neither, so `require` goes on as usual.
fn requireRemote(l: *Thread, name: []const u8, loaded: *Table) Error!?u32 {
    const caller = callerSource(l);
    const caller_url: ?[]const u8 = if (caller) |c| (if (remote.isUrl(c)) c[0 .. std.mem.indexOfScalar(u8, c, '#') orelse c.len] else null) else null;
    const is_url = remote.isUrl(name);
    if (!is_url and (caller_url == null or isBuiltinName(name))) return null;
    const st = remote.store orelse return l.raiseFmt("{s}", .{remote.unavailable});
    // Every buffer here goes through the store, which writes its messages
    // with its own allocator. The state's allocator is only for the state.
    const gpa = st.gpa;
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);

    // The package to load and the module inside it.
    var pkg_url: []u8 = undefined;
    var sub: ?[]const u8 = null;
    if (is_url) {
        pkg_url = remote.normalize(gpa, name, &why) catch |e| switch (e) {
            error.OutOfMemory => return l.raiseMem(),
            error.Remote => return l.raiseFmt("{s}", .{why.items}),
        };
    } else {
        st.lock();
        const owner = st.peek(caller_url.?);
        var kind = if (owner) |o| o.kind else remote.Kind.generic;
        st.unlock();
        // In a standalone executable the store is empty, and the bundle
        // tells a module of an atmosphere package by its key.
        if (owner == null) if (bundle) |b| {
            const k = std.mem.concat(gpa, u8, &.{ caller_url.?, "#", name }) catch return l.raiseMem();
            defer gpa.free(k);
            if (b.find(k) != null) kind = .atmosphere;
        };
        if (kind == .atmosphere) {
            pkg_url = gpa.dupe(u8, caller_url.?) catch return l.raiseMem();
            sub = name;
        } else {
            // A name inside a module from a generic server names a file
            // beside that module.
            const rel = std.mem.replaceOwned(u8, gpa, name, ".", "/") catch return l.raiseMem();
            defer gpa.free(rel);
            pkg_url = std.mem.concat(gpa, u8, &.{ remote.dirOf(caller_url.?), rel, ".lus" }) catch return l.raiseMem();
        }
    }
    defer gpa.free(pkg_url);
    const key_text = if (sub) |n| std.mem.concat(gpa, u8, &.{ pkg_url, "#", n }) catch return l.raiseMem() else gpa.dupe(u8, pkg_url) catch return l.raiseMem();
    defer gpa.free(key_text);
    const key = try l.newStringValue(key_text);
    try l.push(key);
    const existing = table.getStr(loaded, key.as(String));
    if (existing.truthy()) {
        l.top -= 1;
        return try aux.ret(l, existing);
    }

    // A standalone executable carries the remote modules it requires.
    // They are part of the program, so they need no permission.
    if (bundle) |b| if (b.find(key_text)) |m| {
        api.load(l, m.data, m.chunkname) catch {
            return l.raiseFmt("error loading bundled module '{s}':\n\t{s}", .{ name, api.errorMessage(l, l.err) });
        };
        const loader = l.stack[l.top - 1];
        const extra = try l.newStringValue(pkg_url);
        return try runLoader(l, loaded, key, loader, extra);
    };

    try pledge.require(l, "network:http", pkg_url);
    if (!pledge.allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});

    // Resolve, and read the source while the store is locked.
    st.lock();
    const pkg = st.get(pkg_url, &why) catch |e| {
        st.unlock();
        return switch (e) {
            error.OutOfMemory => l.raiseMem(),
            error.Remote => l.raiseFmt("{s}", .{why.items}),
        };
    };
    if (pkg.fetched and st.running and st.firstWarning(pkg_url)) {
        var pos: std.ArrayList(u8) = .empty;
        defer pos.deinit(gpa);
        l.where(&pos, 1) catch {};
        std.debug.print("lus: warning: {s}fetched {s} during execution. A literal require lets lus fetch it before the program starts.\n", .{ pos.items, pkg_url });
    }
    pkg.fetched = false;
    const chunkname = std.mem.concat(gpa, u8, &.{ "@", key_text }) catch {
        st.unlock();
        return l.raiseMem();
    };
    defer gpa.free(chunkname);
    // The modules of an atmosphere package read the flags of their package.
    var fmap: std.StringHashMapUnmanaged(Value) = .empty;
    defer fmap.deinit(gpa);
    var cache_key: std.ArrayList(u8) = .empty;
    defer cache_key.deinit(gpa);
    cache_key.appendSlice(gpa, chunkname) catch {
        st.unlock();
        return l.raiseMem();
    };
    if (pkg.kind == .atmosphere) packageFlags(l, gpa, pkg, sub, &fmap, &cache_key) catch |e| {
        st.unlock();
        return e;
    };
    const cached = if (st.compiled.get(cache_key.items)) |c| gpa.dupe(u8, c) catch null else null;
    const src: ?[]u8 = if (cached != null) null else pkg.read(gpa, l.g.io, sub) catch null;
    st.unlock();
    defer if (cached) |c| gpa.free(c);
    defer if (src) |x| gpa.free(x);
    if (cached == null and src == null) {
        return l.raiseFmt("module '{s}' not found in {s}", .{ name, pkg_url });
    }
    const code = cached orelse src.?;
    if (cached == null and pkg.kind == .atmosphere) {
        if (comptime !@import("build_options").compiler) return l.raiseFmt("the compiler is not part of this executable", .{});
        const r = @import("../compile/codegen.zig").compile(l.g, code, .{ .chunkname = chunkname, .flags = &fmap, .fold_flag_reads = true, .debug = l.g.debugger != null, .meta_grants = .{ .thread = l } }) catch return l.raiseMem();
        switch (r) {
            .err => |msg| {
                defer l.g.gpa.free(msg);
                return l.raiseFmt("error loading module '{s}' from {s}:\n\t{s}", .{ name, pkg_url, msg });
            },
            .ok => |p| {
                const cl = try api.newMainClosure(l, p, l.g.globals);
                try l.push(Value.obj(.closure, cl));
            },
        }
    } else {
        api.load(l, code, chunkname) catch {
            return l.raiseFmt("error loading module '{s}' from {s}:\n\t{s}", .{ name, pkg_url, api.errorMessage(l, l.err) });
        };
    }
    const loader = l.stack[l.top - 1];
    if (cached == null) {
        // Every later state loads the compiled chunk.
        if (loader.tag == .closure) {
            // The store outlives this state, so its entries use the
            // allocator of the store.
            const sg = gpa;
            if (@import("../compile/dump.zig").dump(sg, loader.as(object.Closure).proto, false)) |bin| {
                st.lock();
                defer st.unlock();
                if (!st.compiled.contains(cache_key.items)) {
                    const k = sg.dupe(u8, cache_key.items) catch null;
                    if (k) |kk| st.compiled.put(sg, kk, bin) catch {
                        sg.free(kk);
                        sg.free(bin);
                    } else sg.free(bin);
                } else sg.free(bin);
            } else |_| {}
        }
    }
    // The loader stays on the stack, above the flag strings, until
    // `runLoader` has called it.
    const extra = try l.newStringValue(pkg_url);
    return try runLoader(l, loaded, key, loader, extra);
}

/// Whether `package.preload` holds a loader for `name`.
fn preloaded(l: *Thread, pkg: *Table, name: *String) bool {
    const pre = aux.getField(l, pkg, "preload") catch return false;
    if (pre.tag != .table) return false;
    return !table.getStr(pre.as(Table), name).isNil();
}

fn require(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const pkg = packageTable(l);
    const loaded_v = try aux.getField(l, l.g.registry.as(Table), "_LOADED");
    const loaded = loaded_v.as(Table);
    // A URL that `package.loaded` or `package.preload` holds under its
    // exact name loads from there, as any other name does, so a host or a
    // test can provide a remote module without the network.
    const local = remote.isUrl(name.bytes()) and (table.getStr(loaded, name).truthy() or preloaded(l, pkg, name));
    // Every module of a program compiled ahead of time is bundled, so the
    // client of remote modules is linked only when the proof fails.
    if (!local) if (aux.guarded(.fields, "package", "remote", "require", requireRemote)) |remote_require| {
        if (try remote_require(l, name.bytes(), loaded)) |n| return n;
    };
    const existing = table.getStr(loaded, name);
    if (existing.truthy()) return aux.ret(l, existing);
    const searchers = try aux.getField(l, pkg, "searchers");
    if (searchers.tag != .table) return l.raiseFmt("'package.searchers' must be a table", .{});
    // Each searcher message goes on its own indented line.
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(l.g.gpa);
    var i: i64 = 1;
    while (true) : (i += 1) {
        const s = table.getInt(searchers.as(Table), i);
        if (s.isNil()) {
            return l.raiseFmt("module '{s}' not found:{s}", .{ name.bytes(), msg.items });
        }
        const base = l.top;
        _ = try ops.callN(l, s, &.{Value.obj(.string, name)}, 2);
        const loader = l.stack[base];
        const extra = l.stack[base + 1];
        if (loader.tag == .closure or loader.tag == .native) {
            // The loader and its data stay on the stack while it runs.
            const r = try ops.call1(l, loader, &.{ Value.obj(.string, name), extra });
            if (!r.isNil()) try ops.rawSet(l, loaded, Value.obj(.string, name), r);
            var final = table.getStr(loaded, name);
            if (final.isNil()) {
                final = .true;
                try ops.rawSet(l, loaded, Value.obj(.string, name), final);
            }
            l.top = base;
            try l.push(final);
            try l.push(extra);
            return 2;
        }
        l.top = base;
        if (loader.tag == .string) {
            msg.print(l.g.gpa, "\n\t{s}", .{loader.as(String).bytes()}) catch return l.raiseMem();
        }
    }
}
