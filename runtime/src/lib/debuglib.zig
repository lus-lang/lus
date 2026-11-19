//! The `debug` library.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const debug = @import("../vm/debug.zig");
const aux = @import("aux.zig");
const astexport = @import("../syntax/astexport.zig");
const format = @import("../syntax/format.zig");
const codegen = @import("../compile/codegen.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;
const Closure = object.Closure;

pub const funcs = [_]aux.Reg{
    .{ .name = "traceback", .func = traceback },
    .{ .name = "debug", .func = debugRepl },
    .{ .name = "getinfo", .func = getinfo },
    .{ .name = "getlocal", .func = getlocal },
    .{ .name = "setlocal", .func = setlocal },
    .{ .name = "getupvalue", .func = getupvalue },
    .{ .name = "setupvalue", .func = setupvalue },
    .{ .name = "upvalueid", .func = upvalueid },
    .{ .name = "upvaluejoin", .func = upvaluejoin },
    .{ .name = "getmetatable", .func = getmetatable },
    .{ .name = "setmetatable", .func = setmetatable },
    .{ .name = "getregistry", .func = getregistry },
    .{ .name = "gethook", .func = gethook },
    .{ .name = "sethook", .func = sethook },
    .{ .name = "getuservalue", .func = getuservalue },
    .{ .name = "setuservalue", .func = setuservalue },

    .{ .name = "parse", .func = parse },
    .{ .name = "format", .func = formatSource },
};

pub fn open(l: *Thread) Error!void {
    const t = try aux.newLib(l, &funcs);
    try aux.setGlobal(l, "debug", Value.obj(.table, t));
}

/// Optional leading thread argument. Returns the thread and the index of
/// the first remaining argument.
fn threadArg(l: *Thread) struct { *Thread, u32 } {
    if (l.arg(1).tag == .thread) return .{ l.arg(1).as(Thread), 2 };
    return .{ l, 1 };
}

fn traceback(l: *Thread) Error!u32 {
    const ta = threadArg(l);
    const co = ta[0];
    const a = ta[1];
    const msg = l.arg(a);
    if (!msg.isNil() and msg.tag != .string and !msg.isNumber()) return aux.ret(l, msg);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    if (!msg.isNil()) {
        const s = try ops.toString(l, msg);
        buf.appendSlice(l.g.gpa, s.bytes()) catch return l.raiseMem();
        buf.append(l.g.gpa, '\n') catch return l.raiseMem();
    }
    const default_level: i64 = if (co == l) 1 else 0;
    const level = try aux.optInt(l, a + 1, default_level);
    debug.traceback(co, &buf, @intCast(@max(level, 0))) catch return l.raiseMem();
    return aux.retStr(l, buf.items);
}

fn frameAt(co: *Thread, level: i64) ?usize {
    if (level < 0) return null;
    const n = co.frames.items.len;
    if (@as(usize, @intCast(level)) >= n) return null;
    return n - 1 - @as(usize, @intCast(level));
}

fn getinfo(l: *Thread) Error!u32 {
    const ta = threadArg(l);
    const co = ta[0];
    const a = ta[1];
    const what = (try aux.optString(l, a + 1, "flnSrtu")).?;
    if (what.len > 0 and what[0] == '>') return aux.argError(l, a + 1, "invalid option '>'", .{});
    const target = l.arg(a);
    var func: Value = .nil;
    var fi: ?usize = null;
    if (target.tag == .closure or target.tag == .native) {
        func = target;
    } else {
        const level = try aux.checkInt(l, a);
        fi = frameAt(co, level) orelse return aux.retNil(l);
        const f = co.frames.items[fi.?];
        func = if (f.closure) |c| Value.obj(.closure, c) else if (f.native) |n| Value.obj(.native, n) else .nil;
    }
    const t = try l.newTable(0, 12);
    const tv = Value.obj(.table, t);
    try l.push(tv);
    const cl: ?*Closure = if (func.tag == .closure) func.as(Closure) else null;
    for (what) |ch| switch (ch) {
        'S' => {
            if (cl) |c| {
                const p = c.proto;
                const src = if (p.source) |s| s.bytes() else "=?";
                try aux.setField(l, t, "source", try l.newStringValue(src));
                var sbuf: [id_size]u8 = undefined;
                try aux.setField(l, t, "short_src", try l.newStringValue(chunkId(&sbuf, src)));
                try aux.setField(l, t, "linedefined", Value.int(p.line_defined));
                try aux.setField(l, t, "lastlinedefined", Value.int(p.last_line_defined));
                try aux.setField(l, t, "what", try l.newStringValue(if (p.line_defined == 0) "main" else "Lua"));
            } else {
                try aux.setField(l, t, "source", try l.newStringValue("=[C]"));
                try aux.setField(l, t, "short_src", try l.newStringValue("[C]"));
                try aux.setField(l, t, "linedefined", Value.int(-1));
                try aux.setField(l, t, "lastlinedefined", Value.int(-1));
                try aux.setField(l, t, "what", try l.newStringValue("C"));
            }
        },
        'l' => {
            var line: i64 = -1;
            if (fi) |i| if (co.frames.items[i].closure) |c| {
                line = state.currentLine(c.proto, co.frames.items[i].pc);
            };
            try aux.setField(l, t, "currentline", Value.int(line));
        },
        'u' => {
            if (cl) |c| {
                try aux.setField(l, t, "nups", Value.int(c.nupvals));
                try aux.setField(l, t, "nparams", Value.int(c.proto.num_params));
                try aux.setField(l, t, "isvararg", Value.boolean(c.proto.is_vararg));
            } else {
                const nups: i64 = if (func.tag == .native) func.as(state.Native).nupvals else 0;
                try aux.setField(l, t, "nups", Value.int(nups));
                try aux.setField(l, t, "nparams", Value.int(0));
                try aux.setField(l, t, "isvararg", Value.true);
            }
        },
        'n' => {
            if (fi) |i| if (debug.funcName(co, i)) |n| {
                try aux.setField(l, t, "name", try l.newStringValue(n.name));
                try aux.setField(l, t, "namewhat", try l.newStringValue(n.kind));
                continue;
            };
            try aux.setField(l, t, "namewhat", try l.newStringValue(""));
        },
        't' => {
            const tail = if (fi) |i| co.frames.items[i].tail else false;
            try aux.setField(l, t, "istailcall", Value.boolean(tail));
        },
        'r' => {
            try aux.setField(l, t, "ftransfer", Value.int(0));
            try aux.setField(l, t, "ntransfer", Value.int(0));
        },
        'f' => try aux.setField(l, t, "func", func),
        'L' => {
            if (cl) |c| {
                const lines = try l.newTable(0, c.proto.lines.len);
                for (c.proto.lines) |ln| try ops.rawSet(l, lines, Value.int(ln), .true);
                try aux.setField(l, t, "activelines", Value.obj(.table, lines));
            }
        },
        else => return aux.argError(l, a + 1, "invalid option", .{}),
    };
    return 1;
}

/// Locals of frame `fi` active at its current pc, in declaration order.
fn activeLocal(co: *Thread, fi: usize, n: i64) ?struct { []const u8, u32 } {
    const f = co.frames.items[fi];
    const cl = f.closure orelse return null;
    const p = cl.proto;
    const pc = if (f.pc == 0) 0 else f.pc - 1;
    var k: i64 = 0;
    for (p.locvars) |lv| {
        if (lv.start_pc > pc) continue;
        if (lv.end_pc != 0 and lv.end_pc <= pc) continue;
        k += 1;
        if (k == n) return .{ lv.name.bytes(), f.base + lv.reg };
    }
    // Varargs: negative indices.
    if (n < 0 and -n <= f.nvarargs) {
        const idx = f.func - f.nvarargs + @as(u32, @intCast(-n - 1));
        return .{ "(vararg)", idx };
    }
    return null;
}

fn getlocal(l: *Thread) Error!u32 {
    const ta = threadArg(l);
    const co = ta[0];
    const a = ta[1];
    const n = try aux.checkInt(l, a + 1);
    // A native function has no named parameters.
    if (l.arg(a).tag == .native) return aux.retNil(l);
    if (l.arg(a).tag == .closure) {
        // Parameter names of a function.
        const p = l.arg(a).as(Closure).proto;
        if (n >= 1 and n <= p.num_params) {
            var k: i64 = 0;
            for (p.locvars) |lv| {
                if (lv.start_pc != 0) continue;
                k += 1;
                if (k == n) return aux.ret(l, Value.obj(.string, lv.name));
            }
        }
        return aux.retNil(l);
    }
    const level = try aux.checkInt(l, a);
    const fi = frameAt(co, level + if (co == l) @as(i64, 0) else 0) orelse return aux.argError(l, a, "level out of range", .{});
    const loc = activeLocal(co, fi, n) orelse return aux.retNil(l);
    try l.push(try l.newStringValue(loc[0]));
    try l.push(co.stack[loc[1]]);
    return 2;
}

fn setlocal(l: *Thread) Error!u32 {
    const ta = threadArg(l);
    const co = ta[0];
    const a = ta[1];
    const level = try aux.checkInt(l, a);
    const n = try aux.checkInt(l, a + 1);
    const fi = frameAt(co, level) orelse return aux.argError(l, a, "level out of range", .{});
    const loc = activeLocal(co, fi, n) orelse return aux.retNil(l);
    co.stack[loc[1]] = l.arg(a + 2);
    return aux.retStr(l, loc[0]);
}

fn upvalueOf(l: *Thread, fi: u32, ni: u32) Error!?struct { []const u8, *Value } {
    const f = l.arg(fi);
    const n = try aux.checkInt(l, ni);
    switch (f.tag) {
        .closure => {
            const c = f.as(Closure);
            if (n < 1 or n > c.nupvals) return null;
            const idx: usize = @intCast(n - 1);
            const name = if (c.proto.upvals[idx].name) |s| s.bytes() else "?";
            return .{ name, c.upvals()[idx].loc };
        },
        .native => {
            const nat = f.as(state.Native);
            if (n < 1 or n > nat.nupvals) return null;
            return .{ "", &nat.upvalues()[@intCast(n - 1)] };
        },
        else => return aux.typeError(l, fi, "function"),
    }
}

fn getupvalue(l: *Thread) Error!u32 {
    const u = (try upvalueOf(l, 1, 2)) orelse return 0;
    try l.push(try l.newStringValue(u[0]));
    try l.push(u[1].*);
    return 2;
}

fn setupvalue(l: *Thread) Error!u32 {
    _ = try aux.checkAny(l, 3);
    const u = (try upvalueOf(l, 1, 2)) orelse return 0;
    u[1].* = l.arg(3);
    return aux.retStr(l, u[0]);
}

fn upvalueid(l: *Thread) Error!u32 {
    const f = try aux.checkFunction(l, 1);
    const n = try aux.checkInt(l, 2);
    if (f.tag == .closure) {
        const c = f.as(Closure);
        if (n < 1 or n > c.nupvals) return aux.retNil(l);
        return aux.ret(l, Value.light(c.upvals()[@intCast(n - 1)]));
    }
    const nat = f.as(state.Native);
    if (n < 1 or n > nat.nupvals) return aux.retNil(l);
    return aux.ret(l, Value.light(&nat.upvalues()[@intCast(n - 1)]));
}

fn upvaluejoin(l: *Thread) Error!u32 {
    if (l.arg(1).tag != .closure) return aux.argError(l, 1, "Lua function expected", .{});
    if (l.arg(3).tag != .closure) return aux.argError(l, 3, "Lua function expected", .{});
    const c1 = l.arg(1).as(Closure);
    const c2 = l.arg(3).as(Closure);
    const n1 = try aux.checkInt(l, 2);
    const n2 = try aux.checkInt(l, 4);
    if (n1 < 1 or n1 > c1.nupvals) return aux.argError(l, 2, "invalid upvalue index", .{});
    if (n2 < 1 or n2 > c2.nupvals) return aux.argError(l, 4, "invalid upvalue index", .{});
    c1.upvals()[@intCast(n1 - 1)] = c2.upvals()[@intCast(n2 - 1)];
    return 0;
}

fn getmetatable(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const mt = l.metatable(v) orelse return aux.retNil(l);
    return aux.ret(l, Value.obj(.table, mt));
}

fn setmetatable(l: *Thread) Error!u32 {
    const v = l.arg(1);
    const mtv = l.arg(2);
    if (mtv.tag != .nil and mtv.tag != .table) return aux.typeError(l, 2, "nil or table");
    const mt: ?*Table = if (mtv.tag == .table) mtv.as(Table) else null;
    switch (v.tag) {
        .table => v.as(Table).metatable = mt,
        .userdata => v.as(object.Userdata).metatable = mt,
        else => l.g.type_metatables[value.typeSlot(v.tag)] = mt,
    }
    return aux.ret(l, v);
}

fn getregistry(l: *Thread) Error!u32 {
    return aux.ret(l, l.g.registry);
}

// ---------------------------------------------------------------------
// Hooks
//
// The installed hook of each thread is recorded in a weak-keyed registry
// table, as `{ hook, mask, count }`. The table is the single record of
// installed hooks, so `gethook` reports exactly what `sethook` installed.

const hook_key = "_HOOKKEY";

fn hookTable(l: *Thread) Error!*Table {
    const reg = l.g.registry.as(Table);
    const cur = try aux.getField(l, reg, hook_key);
    if (cur.tag == .table) return cur.as(Table);
    const t = try l.newTable(0, 1);
    try aux.setField(l, reg, hook_key, Value.obj(.table, t));
    try aux.setField(l, t, "__mode", try l.newStringValue("k"));
    t.metatable = t;
    return t;
}

/// The hook function installed on `l`, if any.
pub fn hookFunction(l: *Thread) ?Value {
    const reg = l.g.registry.as(Table);
    const key = state.newStringKnown(l.g, hook_key, true, hook_key.len) catch return null;
    const t = table.getStr(reg, key);
    if (t.tag != .table) return null;
    const rec = table.get(t.as(Table), Value.obj(.thread, l));
    if (rec.tag != .table) return null;
    const f = table.getInt(rec.as(Table), 1);
    return if (f.isNil()) null else f;
}

/// The events an attached debugger needs, which `sethook` never clears.
fn debuggerMask(l: *Thread) u8 {
    return if (l.g.debugger) |d| d.mask else 0;
}

fn gethook(l: *Thread) Error!u32 {
    const co = threadArg(l)[0];
    const t = try hookTable(l);
    const rec = table.get(t, Value.obj(.thread, co));
    if (rec.tag != .table) return aux.retNil(l);
    const r = rec.as(Table);
    try l.push(table.getInt(r, 1));
    try l.push(table.getInt(r, 2));
    try l.push(table.getInt(r, 3));
    return 3;
}

/// debug.sethook([thread,] hook, mask [, count]). With no hook, the
/// thread's hook is removed.
fn sethook(l: *Thread) Error!u32 {
    const ta = threadArg(l);
    const co = ta[0];
    const a = ta[1];
    const t = try hookTable(l);
    const key = Value.obj(.thread, co);
    if (l.arg(a).isNil()) {
        try ops.rawSet(l, t, key, .nil);
        co.hook_mask = debuggerMask(l);
        return 0;
    }
    const smask = try aux.checkBytes(l, a + 1);
    _ = try aux.checkFunction(l, a);
    const count = try aux.optInt(l, a + 2, 0);
    // The mask keeps the call, return, and line flags in that order.
    var buf: [3]u8 = undefined;
    var n: usize = 0;
    for ("crl") |ch| if (std.mem.indexOfScalar(u8, smask, ch) != null) {
        buf[n] = ch;
        n += 1;
    };
    if (n == 0 and count <= 0) {
        try ops.rawSet(l, t, key, .nil);
        co.hook_mask = debuggerMask(l);
        return 0;
    }
    const rec = try l.newTable(3, 0);
    try l.push(Value.obj(.table, rec));
    try ops.rawSet(l, rec, Value.int(1), l.arg(a));
    try ops.rawSet(l, rec, Value.int(2), try l.newStringValue(buf[0..n]));
    try ops.rawSet(l, rec, Value.int(3), Value.int(@max(count, 0)));
    try ops.rawSet(l, t, key, Value.obj(.table, rec));
    var mask: u8 = 0;
    for (buf[0..n]) |ch| mask |= switch (ch) {
        'c' => Thread.hook_call,
        'r' => Thread.hook_ret,
        else => Thread.hook_line,
    };
    if (count > 0) mask |= Thread.hook_countm;
    co.hook_count = @intCast(@max(count, 0));
    co.hook_left = co.hook_count;
    co.hook_oldfi = std.math.maxInt(usize);
    co.hook_mask = mask | debuggerMask(l);
    return 0;
}

// ---------------------------------------------------------------------
// User values

/// debug.getuservalue(u [, n]): the n-th user value of a full userdata and
/// true, or fail when `u` is not a full userdata or has no such slot.
fn getuservalue(l: *Thread) Error!u32 {
    const n = try aux.optInt(l, 2, 1);
    const v = l.arg(1);
    if (v.tag != .userdata) return aux.retNil(l);
    const vals = v.as(object.Userdata).userValues();
    if (n < 1 or n > vals.len) return aux.retNil(l);
    try l.push(vals[@intCast(n - 1)]);
    try l.push(.true);
    return 2;
}

/// debug.setuservalue(u, value [, n]): stores `value` in the n-th user
/// value of `u` and returns `u`, or fail when the slot does not exist.
fn setuservalue(l: *Thread) Error!u32 {
    const n = try aux.optInt(l, 3, 1);
    if (l.arg(1).tag != .userdata) return aux.typeError(l, 1, "userdata");
    const v = try aux.checkAny(l, 2);
    const vals = l.arg(1).as(object.Userdata).userValues();
    if (n < 1 or n > vals.len) return aux.retNil(l);
    vals[@intCast(n - 1)] = v;
    return aux.ret(l, l.arg(1));
}

// ---------------------------------------------------------------------
// Chunk names

/// The size of a `short_src` buffer, including room for a terminator.
const id_size = 60;

/// Formats a chunk name for `short_src`: "=name" keeps the name, "@file"
/// keeps the file name and shortens it from the front, and source text
/// becomes `[string "first line"]`, shortened with "...". The result is
/// cut on character boundaries so it stays valid text.
fn chunkId(buf: *[id_size]u8, src: []const u8) []const u8 {
    const max = id_size - 1;
    if (src.len > 0 and src[0] == '=') {
        return copyPrefix(buf, src[1..], max);
    }
    if (src.len > 0 and src[0] == '@') {
        const name = src[1..];
        if (name.len <= max) return copyPrefix(buf, name, max);
        var start = name.len - (max - 3);
        while (start < name.len and (name[start] & 0xC0) == 0x80) start += 1;
        @memcpy(buf[0..3], "...");
        @memcpy(buf[3 .. 3 + name.len - start], name[start..]);
        return buf[0 .. 3 + name.len - start];
    }
    const pre = "[string \"";
    const rets = "...";
    const pos = "\"]";
    const room = id_size - (pre.len + rets.len + pos.len) - 1;
    var len: usize = 0;
    @memcpy(buf[0..pre.len], pre);
    len = pre.len;
    const nl = std.mem.indexOfScalar(u8, src, '\n');
    if (src.len < room and nl == null) {
        @memcpy(buf[len .. len + src.len], src);
        len += src.len;
    } else {
        var n = nl orelse src.len;
        if (n > room) n = room;
        while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(buf[len .. len + n], src[0..n]);
        len += n;
        @memcpy(buf[len .. len + rets.len], rets);
        len += rets.len;
    }
    @memcpy(buf[len .. len + pos.len], pos);
    return buf[0 .. len + pos.len];
}

fn copyPrefix(buf: *[id_size]u8, s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------
// debug.parse

/// `debug.parse(code [, chunkname [, options]])` returns the syntax tree
/// of `code` as nested tables and nil, or nil and an error message. The
/// options table takes `comments` and `recover`, both true by default.
/// With `recover`, a parse that stops at an error still returns the tree
/// read so far, with the errors listed in its `errors` array.
fn parse(l: *Thread) Error!u32 {
    // Source read in binary mode arrives as a vector.
    const code = if (l.arg(1).tag == .vector) (try @import("vector.zig").checkVector(l, 1)).bytes.items else try aux.checkBytes(l, 1);
    const chunkname = (try aux.optString(l, 2, "=(parse)")).?;
    var opts: astexport.Options = .{ .chunkname = chunkname };
    const o = l.arg(3);
    if (o.tag == .table) {
        const c = try aux.getField(l, o.as(Table), "comments");
        if (!c.isNil()) opts.comments = c.truthy();
        const r = try aux.getField(l, o.as(Table), "recover");
        if (!r.isNil()) opts.recover = r.truthy();
    }
    var arena_state = std.heap.ArenaAllocator.init(l.g.gpa);
    defer arena_state.deinit();
    const checker: astexport.Checker = .{ .ctx = l.g, .check = checkChunk };
    const res = astexport.run(l.g.gpa, arena_state.allocator(), code, opts, checker) catch return l.raiseMem();
    switch (res) {
        .fail => |msg| return aux.retFail(l, msg),
        .tree => |root| {
            // The tables are built with the collector paused, so that a
            // table is safe before it is linked into its parent.
            const g = l.g;
            const was_stopped = g.gc_stopped;
            g.gc_stopped = true;
            defer g.gc_stopped = was_stopped;
            const t = try nodeTable(l, root);
            try l.push(Value.obj(.table, t));
            try l.push(.nil);
            return 2;
        },
    }
}

// ---------------------------------------------------------------------
// debug.format

/// `debug.format(code [, chunkname [, indent]])` returns `code` formatted
/// with `indent` spaces per level (4 by default), or nil and an error
/// message when it does not parse.
fn formatSource(l: *Thread) Error!u32 {
    const code = if (l.arg(1).tag == .vector) (try @import("vector.zig").checkVector(l, 1)).bytes.items else try aux.checkBytes(l, 1);
    const chunkname = (try aux.optString(l, 2, "=format")).?;
    const width = try aux.optInt(l, 3, 4);
    if (width > 64) return aux.argError(l, 3, "indent width too large", .{});
    var arena_state = std.heap.ArenaAllocator.init(l.g.gpa);
    defer arena_state.deinit();
    const checker: astexport.Checker = .{ .ctx = l.g, .check = checkChunk };
    const opts: format.Options = .{
        .chunkname = chunkname,
        .indent_width = if (width > 0) @intCast(width) else 4,
        .checker = checker,
    };
    const res = format.format(l.g.gpa, arena_state.allocator(), code, opts) catch return l.raiseMem();
    switch (res) {
        .fail => |msg| return aux.retFail(l, msg),
        .ok => |text| {
            // Comments keep their bytes, so a source with raw bytes in a
            // comment can produce text that is not WTF-8. Each invalid
            // sequence then becomes U+FFFD.
            try l.push(try astString(l, text));
            return 1;
        },
    }
}

/// Compiles the parsed chunk to report the errors the reference parser
/// raises while parsing (assignment to a constant, a missing label).
fn checkChunk(ctx: *anyopaque, arena: std.mem.Allocator, chunk: @import("../syntax/ast.zig").Chunk, chunkname: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const g: *state.Global = @ptrCast(@alignCast(ctx));
    const r = try codegen.compileAst(g, arena, chunk, .{ .chunkname = chunkname });
    switch (r) {
        .ok => return null,
        .err => |m| {
            defer g.gpa.free(m);
            return try arena.dupe(u8, m);
        },
    }
}

fn astString(l: *Thread, s: []const u8) Error!Value {
    const str = state.newStringIn(l.g, s) catch |e| switch (e) {
        error.OutOfMemory => return l.raiseMem(),
        error.InvalidUtf8 => blk: {
            // A string literal of raw bytes: strings hold WTF-8, so each
            // invalid sequence becomes U+FFFD.
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(l.g.gpa);
            @import("../vm/wtf8.zig").appendLossy(l.g.gpa, &buf, s) catch return l.raiseMem();
            break :blk state.newStringIn(l.g, buf.items) catch return l.raiseMem();
        },
    };
    return Value.obj(.string, str);
}

fn astValue(l: *Thread, v: astexport.Val) Error!Value {
    return switch (v) {
        .int => |i| Value.int(i),
        .float => |f| Value.float(f),
        .str => |s| try astString(l, s),
        .boolean => |b| Value.boolean(b),
        .node => |n| Value.obj(.table, try nodeTable(l, n)),
        .list => |list| Value.obj(.table, try listTable(l, list)),
    };
}

fn listTable(l: *Thread, list: []const *astexport.Node) Error!*Table {
    const t = try l.newTable(list.len, 0);
    for (list, 0..) |n, i| {
        try ops.rawSet(l, t, Value.int(@intCast(i + 1)), Value.obj(.table, try nodeTable(l, n)));
    }
    return t;
}

fn nodeTable(l: *Thread, n: *const astexport.Node) Error!*Table {
    const t = try l.newTable(0, n.fields.items.len + 6);
    if (n.type) |ty| try aux.setField(l, t, "type", try astString(l, ty));
    try aux.setField(l, t, "line", Value.int(n.line));
    try aux.setField(l, t, "column", Value.int(n.column));
    if (n.endline > 0) {
        try aux.setField(l, t, "endline", Value.int(n.endline));
        try aux.setField(l, t, "endcolumn", Value.int(n.endcolumn));
    }
    for (n.fields.items) |f| try aux.setField(l, t, f.key, try astValue(l, f.val));
    if (n.children.items.len > 0) {
        try aux.setField(l, t, "children", Value.obj(.table, try listTable(l, n.children.items)));
    }
    return t;
}

// ---------------------------------------------------------------------
// debug.debug

/// debug.debug(): reads lines from standard input and runs each as a
/// chunk, until end of input or a line that reads `cont`. Errors are
/// printed and the loop goes on. Running the lines needs the `load`
/// permission, like any other code loaded at run time.
fn debugRepl(l: *Thread) Error!u32 {
    try @import("../vm/pledge.zig").require(l, "load", null);
    const out = @import("out.zig");
    const api = @import("../api.zig");
    const io = l.g.io;
    const stdin = std.Io.File.stdin();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(l.g.gpa);
    while (true) {
        out.stderr(l.g, "lus_debug> ");
        line.clearRetainingCapacity();
        var eof = false;
        while (true) {
            var byte: [1]u8 = undefined;
            var bufs = [_][]u8{&byte};
            const n = stdin.readStreaming(io, &bufs) catch 0;
            if (n == 0) {
                eof = true;
                break;
            }
            if (byte[0] == '\n') break;
            line.append(l.g.gpa, byte[0]) catch return l.raiseMem();
        }
        if (eof and line.items.len == 0) return 0;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line.items, "\r"), "cont")) return 0;
        const base = l.top;
        const ok = blk: {
            api.load(l, line.items, "=(debug command)") catch break :blk false;
            break :blk api.pcall(l, 0, 0);
        };
        if (!ok) {
            const msg = api.errorMessage(l, l.stack[l.top - 1]);
            out.stderr(l.g, msg);
            out.stderr(l.g, "\n");
        }
        l.top = base;
        if (eof) return 0;
    }
}

