//! Modules: `require` and the `package` table.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const interp = @import("../vm/interp.zig");
const api = @import("../api.zig");
const aux = @import("aux.zig");
const pledge = @import("../vm/pledge.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

pub const default_path = "./?.lus;./?/init.lus;./?.lua;./?/init.lua";

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
    const searchers = try l.newTable(2, 0);
    try ops.rawSet(l, searchers, Value.int(1), try aux.native(l, searcherPreload, "searcher_preload"));
    try ops.rawSet(l, searchers, Value.int(2), try aux.native(l, searcherLus, "searcher_Lus"));
    try aux.setField(l, pkg, "searchers", Value.obj(.table, searchers));
    try aux.setFuncs(l, pkg, &.{.{ .name = "searchpath", .func = searchpath }});
    try aux.setGlobal(l, "require", try aux.native(l, require, "require"));
    // Every library opened so far is registered as loaded.
    const globals = l.g.globals.as(Table);
    for ([_][]const u8{ "string", "table", "math", "os", "io", "coroutine", "utf8", "debug", "package" }) |name| {
        const v = try aux.getField(l, globals, name);
        if (!v.isNil()) try aux.setField(l, loaded, name, v);
    }
    try aux.setField(l, loaded, "_G", l.g.globals);
}

fn envPath(l: *Thread) ?[]const u8 {
    const env = l.g.environ orelse return null;
    return env.get("LUS_PATH");
}

fn packageTable(l: *Thread) Error!*Table {
    const p = try aux.getField(l, l.g.globals.as(Table), "package");
    if (p.tag != .table) return l.raiseFmt("'package' must be a table", .{});
    return p.as(Table);
}

/// Searches `path` (a ';'-separated template list) for `name`, replacing
/// '.' with the directory separator. Returns the first readable file.
pub fn search(l: *Thread, name: []const u8, path: []const u8, tried: *std.ArrayList(u8)) Error!?[]u8 {
    const gpa = l.g.gpa;
    const io = l.g.io;
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(gpa);
    for (name) |ch| mod.append(gpa, if (ch == '.') '/' else ch) catch return l.raiseMem();
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |tmpl| {
        if (tmpl.len == 0) continue;
        const file = std.mem.replaceOwned(u8, gpa, tmpl, "?", mod.items) catch return l.raiseMem();
        if (std.Io.Dir.cwd().statFile(io, file, .{})) |_| {
            if (!pledge.allowed(l, "fs:read", file)) {
                tried.print(gpa, "\n\tno file '{s}' (permission \"fs:read\" denied)", .{file}) catch return l.raiseMem();
                gpa.free(file);
                continue;
            }
            return file;
        } else |_| {
            tried.print(gpa, "\n\tno file '{s}'", .{file}) catch return l.raiseMem();
            gpa.free(file);
        }
    }
    return null;
}

fn searchpath(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    const path = try aux.checkBytes(l, 2);
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    if (try search(l, name, path, &tried)) |f| {
        defer l.g.gpa.free(f);
        return aux.retStr(l, f);
    }
    try l.push(.nil);
    try l.push(try l.newStringValue(tried.items));
    return 2;
}

fn searcherPreload(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const pre = try aux.getField(l, try packageTable(l), "preload");
    if (pre.tag != .table) return l.raiseFmt("'package.preload' must be a table", .{});
    const f = table.getStr(pre.as(Table), name);
    if (f.isNil()) {
        const msg = std.fmt.allocPrint(l.g.gpa, "\n\tno field package.preload['{s}']", .{name.bytes()}) catch return l.raiseMem();
        defer l.g.gpa.free(msg);
        return aux.retStr(l, msg);
    }
    try l.push(f);
    try l.push(try l.newStringValue(":preload:"));
    return 2;
}

fn searcherLus(l: *Thread) Error!u32 {
    const name = try aux.checkBytes(l, 1);
    if (!pledge.allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});
    const path = try aux.getField(l, try packageTable(l), "path");
    if (path.tag != .string) return l.raiseFmt("'package.path' must be a string", .{});
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(l.g.gpa);
    const file = (try search(l, name, path.as(String).bytes(), &tried)) orelse return aux.retStr(l, tried.items);
    defer l.g.gpa.free(file);
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

fn require(l: *Thread) Error!u32 {
    const name = try aux.checkString(l, 1);
    const pkg = try packageTable(l);
    const loaded_v = try aux.getField(l, l.g.registry.as(Table), "_LOADED");
    const loaded = loaded_v.as(Table);
    const existing = table.getStr(loaded, name);
    if (existing.truthy()) return aux.ret(l, existing);
    const searchers = try aux.getField(l, pkg, "searchers");
    if (searchers.tag != .table) return l.raiseFmt("'package.searchers' must be a table", .{});
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
        l.top = base;
        if (loader.tag == .closure or loader.tag == .native) {
            const r = try ops.call1(l, loader, &.{ Value.obj(.string, name), extra });
            if (!r.isNil()) try ops.rawSet(l, loaded, Value.obj(.string, name), r);
            var final = table.getStr(loaded, name);
            if (final.isNil()) {
                final = .true;
                try ops.rawSet(l, loaded, Value.obj(.string, name), final);
            }
            try l.push(final);
            try l.push(extra);
            return 2;
        }
        if (loader.tag == .string) msg.appendSlice(l.g.gpa, loader.as(String).bytes()) catch return l.raiseMem();
    }
}
