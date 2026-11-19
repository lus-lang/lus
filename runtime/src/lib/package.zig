//! Modules: `require` and the `package` table.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const api = @import("../api.zig");
const aux = @import("aux.zig");
const pledge = @import("../vm/pledge.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

pub const default_path = "./?.lus;./?/init.lus;./?.lua;./?/init.lua";

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

pub fn open(l: *Thread) Error!void {
    const pkg = try l.newTable(0, 8);
    const pv = Value.obj(.table, pkg);
    try aux.setGlobal(l, "package", pv);
    const path = envPath(l) orelse default_path;
    try aux.setField(l, pkg, "path", try l.newStringValue(path));
    try aux.setField(l, pkg, "cpath", try l.newStringValue(""));
    try aux.setField(l, pkg, "config", try l.newStringValue("/\n;\n?\n!\n-\n"));
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
    try aux.setFuncs(l, pkg, &.{
        .{ .name = "searchpath", .func = searchpath },
        .{ .name = "loadlib", .func = loadlib },
    });
    try aux.setGlobal(l, "require", try withPackage(l, require, "require", pkg));
    // Every library opened so far is registered as loaded.
    const globals = l.g.globals.as(Table);
    for ([_][]const u8{ "string", "table", "math", "os", "io", "coroutine", "utf8", "debug", "package" }) |name| {
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
    return searchSep(l, name, path, ".", "/", tried);
}

fn searchpath(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const path = try aux.checkBytes(l, 2);
    const sep = (try aux.optString(l, 3, ".")).?;
    const rep = (try aux.optString(l, 4, "/")).?;
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

/// Bundled modules belong to standalone executables. A plain interpreter
/// carries no bundle, so this searcher finds nothing.
fn searcherBundle(l: *Thread) Error!u32 {
    _ = try aux.checkString(l, 1);
    return 0;
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

fn require(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const pkg = packageTable(l);
    const loaded_v = try aux.getField(l, l.g.registry.as(Table), "_LOADED");
    const loaded = loaded_v.as(Table);
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
