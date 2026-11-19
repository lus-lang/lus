//! The base library: global functions.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const interp = @import("../vm/interp.zig");
const numeric = @import("../vm/numeric.zig");
const lexer = @import("../syntax/lexer.zig");
const api = @import("../api.zig");
const aux = @import("aux.zig");
const out = @import("out.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;

pub const funcs = [_]aux.Reg{
    .{ .name = "assert", .func = assert },
    .{ .name = "collectgarbage", .func = collectgarbage },
    .{ .name = "dofile", .func = dofile },
    .{ .name = "error", .func = @"error" },
    .{ .name = "getmetatable", .func = getmetatable },
    .{ .name = "ipairs", .func = ipairs },
    .{ .name = "load", .func = load },
    .{ .name = "loadfile", .func = loadfile },
    .{ .name = "next", .func = next },
    .{ .name = "pairs", .func = pairs },
    .{ .name = "pcall", .func = pcall },
    .{ .name = "print", .func = print },
    .{ .name = "rawequal", .func = rawequal },
    .{ .name = "rawget", .func = rawget },
    .{ .name = "rawlen", .func = rawlen },
    .{ .name = "rawset", .func = rawset },
    .{ .name = "select", .func = select },
    .{ .name = "setmetatable", .func = setmetatable },
    .{ .name = "tonumber", .func = tonumber },
    .{ .name = "tostring", .func = tostring },
    .{ .name = "type", .func = @"type" },
    .{ .name = "warn", .func = warn },
    .{ .name = "xpcall", .func = xpcall },
    .{ .name = "range", .func = range },
    .{ .name = "bigint", .func = bigint },
    .{ .name = "decimal", .func = decimal },
};

pub fn open(l: *Thread) Error!void {
    const g = l.g;
    const globals = g.globals.as(Table);
    try aux.setFuncs(l, globals, &funcs);
    try aux.setField(l, globals, "_G", g.globals);
    try aux.setField(l, globals, "_VERSION", try l.newStringValue("Lus 2.0"));
    // `range` is recognized by the numeric loop lowering.
    const r = try aux.getField(l, globals, "range");
    g.ext.put(g.gpa, "range", @ptrFromInt(r.payload)) catch return l.raiseMem();
}

fn print(l: *Thread) Error!u32 {
    const n = l.argCount();
    const o = out.stdout(l.g);
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) o.write(l.g, "\t");
        const v = l.arg(i);
        if (v.tag == .string) {
            o.write(l.g, v.as(String).bytes());
        } else {
            const s = try ops.toString(l, v);
            o.write(l.g, s.bytes());
        }
    }
    o.write(l.g, "\n");
    return 0;
}

fn @"type"(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    return aux.retStr(l, value.typeName(v.tag));
}

fn tostring(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    return aux.ret(l, Value.obj(.string, try ops.toString(l, v)));
}

fn tonumber(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (l.arg(2).isNil()) {
        if (v.isNumber()) return aux.ret(l, v);
        if (v.tag == .string) {
            if (ops.toNumberCoerce(v)) |n| return aux.ret(l, n);
        } else if (v.tag == .enum_value) {
            return aux.retInt(l, v.as(object.EnumValue).index + 1);
        } else {
            _ = try aux.checkAny(l, 1);
        }
        return aux.retNil(l);
    }
    const base = try aux.checkInt(l, 2);
    if (base < 2 or base > 36) return aux.argError(l, 2, "base out of range", .{});
    const s = std.mem.trim(u8, try aux.checkBytes(l, 1), " \t\n\r\x0b\x0c");
    var neg = false;
    var digits = s;
    if (digits.len > 0 and digits[0] == '-') {
        neg = true;
        digits = digits[1..];
    }
    if (digits.len == 0) return aux.retNil(l);
    var acc: u64 = 0;
    for (digits) |ch| {
        const d: u64 = if (std.ascii.isDigit(ch)) ch - '0' else if (std.ascii.isAlphabetic(ch)) std.ascii.toLower(ch) - 'a' + 10 else return aux.retNil(l);
        if (d >= base) return aux.retNil(l);
        acc = acc *% @as(u64, @intCast(base)) +% d;
    }
    const r: i64 = @bitCast(acc);
    return aux.retInt(l, if (neg) 0 -% r else r);
}

fn @"error"(l: *Thread) Error!u32 {
    const v = l.arg(1);
    const level = try aux.optInt(l, 2, 1);
    if (v.tag == .string and level > 0) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(l.g.gpa);
        l.where(&buf, @intCast(level)) catch return l.raiseMem();
        buf.appendSlice(l.g.gpa, v.as(String).bytes()) catch return l.raiseMem();
        return l.raise(try l.newStringValue(buf.items));
    }
    return l.raise(v);
}

fn assert(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.truthy()) return l.argCount();
    if (l.argCount() < 2) {
        _ = try aux.checkAny(l, 1);
        return l.raiseFmt("assertion failed!", .{});
    }
    return l.raise(l.arg(2));
}

fn getmetatable(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const mt = l.metatable(v) orelse return aux.retNil(l);
    const protected = table.getStr(mt, l.g.tm_names[@intFromEnum(state.TM.metatable)].?);
    if (!protected.isNil()) return aux.ret(l, protected);
    return aux.ret(l, Value.obj(.table, mt));
}

fn setmetatable(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    const mtv = l.arg(2);
    if (mtv.tag != .nil and mtv.tag != .table) return aux.typeError(l, 2, "nil or table");
    if (t.metatable) |old| {
        if (!table.getStr(old, l.g.tm_names[@intFromEnum(state.TM.metatable)].?).isNil()) {
            return l.raiseFmt("cannot change a protected metatable", .{});
        }
    }
    t.metatable = if (mtv.tag == .table) mtv.as(Table) else null;
    if (t.metatable) |mt| {
        gc.barrierBack(l.g, &t.hdr);
        try registerFinalizer(l, &t.hdr, mt);
    }
    return aux.ret(l, l.arg(1));
}

pub fn registerFinalizer(l: *Thread, h: *gc.Header, mt: *Table) Error!void {
    if (h.finalize != .none) return;
    const gcm = table.getStr(mt, l.g.tm_names[@intFromEnum(state.TM.gc)].?);
    if (gcm.isNil()) return;
    h.finalize = .pending;
    l.g.finobj.append(l.g.gpa, h) catch return l.raiseMem();
}

fn rawequal(l: *Thread) Error!u32 {
    const a = try aux.checkAny(l, 1);
    const b = try aux.checkAny(l, 2);
    return aux.retBool(l, ops.rawEqual(l, a, b));
}

fn rawget(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    const k = try ops.normKey(l, try aux.checkAny(l, 2));
    return aux.ret(l, table.get(t, k));
}

fn rawset(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    _ = try aux.checkAny(l, 2);
    _ = try aux.checkAny(l, 3);
    try ops.rawSet(l, t, l.arg(2), l.arg(3));
    return aux.ret(l, l.arg(1));
}

fn rawlen(l: *Thread) Error!u32 {
    const v = l.arg(1);
    return switch (v.tag) {
        .table => aux.retInt(l, table.length(v.as(Table))),
        .string => aux.retInt(l, v.as(String).chars),
        else => aux.argError(l, 1, "table or string expected", .{}),
    };
}

fn select(l: *Thread) Error!u32 {
    const n: i64 = @intCast(l.argCount());
    const sel = l.arg(1);
    if (sel.tag == .string and std.mem.eql(u8, sel.as(String).bytes(), "#")) return aux.retInt(l, n - 1);
    var i = try aux.checkInt(l, 1);
    if (i < 0) {
        i = n + i;
    } else if (i > n) {
        i = n;
    }
    if (i < 1) return aux.argError(l, 1, "index out of range", .{});
    // Results are the arguments after position i, already on the stack.
    return @intCast(n - i);
}

fn next(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    const r = table.next(t, try ops.normKey(l, l.arg(2))) catch return l.raiseFmt("invalid key to 'next'", .{});
    if (r) |kv| {
        try l.push(kv.key);
        try l.push(kv.val);
        return 2;
    }
    return aux.retNil(l);
}

fn pairs(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const tm = l.metamethod(v, .pairs);
    if (!tm.isNil()) {
        const base = l.top;
        _ = try ops.callN(l, tm, &.{v}, 3);
        _ = base;
        return 3;
    }
    if (v.tag != .table) return aux.typeError(l, 1, "table");
    const nxt = try aux.getField(l, l.g.globals.as(Table), "next");
    try l.push(if (nxt.isNil()) try aux.native(l, next, "next") else nxt);
    try l.push(v);
    try l.push(.nil);
    return 3;
}

fn ipairsAux(l: *Thread) Error!u32 {
    const t = l.arg(1);
    const i = (try aux.checkInt(l, 2)) +% 1;
    const v = if (t.tag == .table and t.as(Table).metatable == null) table.getInt(t.as(Table), i) else try ops.index(l, t, Value.int(i));
    if (v.isNil()) return aux.retNil(l);
    try l.push(Value.int(i));
    try l.push(v);
    return 2;
}

fn ipairs(l: *Thread) Error!u32 {
    _ = try aux.checkAny(l, 1);
    try l.push(try aux.native(l, ipairsAux, "ipairs_aux"));
    try l.push(l.arg(1));
    try l.push(Value.int(0));
    return 3;
}

fn rangeAux(l: *Thread) Error!u32 {
    // state = {limit, step}; control = current value
    const st = l.arg(1).as(Table);
    const limit = table.getInt(st, 1);
    const step = table.getInt(st, 2);
    const cur = try ops.arith(l, .add, l.arg(2), step);
    const fwd = if (step.tag == .integer) step.asInt() > 0 else ops.toFloat(step) > 0;
    const done = if (fwd) try ops.lessThan(l, limit, cur) else try ops.lessThan(l, cur, limit);
    if (done) return aux.retNil(l);
    return aux.ret(l, cur);
}

/// `range(a, b [, step])` and `range(n)`, an iterator over a numeric
/// sequence. Inside `for` it compiles to a numeric loop.
fn range(l: *Thread) Error!u32 {
    var start = try aux.checkNumber(l, 1);
    var limit: Value = undefined;
    if (l.arg(2).isNil()) {
        limit = start;
        start = Value.int(1);
    } else limit = try aux.checkNumber(l, 2);
    const step = try aux.optNumber(l, 3, Value.int(1));
    if (ops.toFloat(step) == 0 and step.tag != .bigint and step.tag != .decimal) return aux.argError(l, 3, "step must not be zero", .{});
    const st = try l.newTable(2, 0);
    try ops.rawSet(l, st, Value.int(1), limit);
    try ops.rawSet(l, st, Value.int(2), step);
    try l.push(try aux.native(l, rangeAux, "range_aux"));
    try l.push(Value.obj(.table, st));
    try l.push(try ops.arith(l, .sub, start, step));
    return 3;
}

fn bigint(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const g = l.g;
    switch (v.tag) {
        .bigint => return aux.ret(l, v),
        .integer => return aux.ret(l, Value.obj(.bigint, numeric.bigFromInt(g, v.asInt()) catch return l.raiseMem())),
        .float => {
            const f = v.asFloat();
            if (f != @floor(f) or !std.math.isFinite(f)) return aux.argError(l, 1, "number has no integer representation", .{});
            var buf: [400]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.0}", .{f}) catch return l.raiseMem();
            return aux.ret(l, Value.obj(.bigint, numeric.parseBigLiteral(g, s) catch return l.raiseMem()));
        },
        .decimal => {
            var m = (numeric.decIntegral(g.gpa, v.as(numeric.Decimal)) catch return l.raiseMem()) orelse return aux.argError(l, 1, "number has no integer representation", .{});
            defer m.deinit();
            return aux.ret(l, Value.obj(.bigint, numeric.newBigFromConst(g, m.toConst()) catch return l.raiseMem()));
        },
        .string => {
            const s = std.mem.trim(u8, v.as(String).bytes(), " \t\n\r");
            const b = numeric.parseBigLiteral(g, s) catch return aux.retNil(l);
            return aux.ret(l, Value.obj(.bigint, b));
        },
        else => return aux.typeError(l, 1, "number"),
    }
}

fn decimal(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const g = l.g;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g.gpa);
    switch (v.tag) {
        .decimal => return aux.ret(l, v),
        .integer, .bigint => ops.numberToBuf(g.gpa, &buf, v) catch return l.raiseMem(),
        .float => {
            // Shortest round-trip representation.
            buf.print(g.gpa, "{d}", .{v.asFloat()}) catch return l.raiseMem();
        },
        .string => buf.appendSlice(g.gpa, std.mem.trim(u8, v.as(String).bytes(), " \t\n\r")) catch return l.raiseMem(),
        else => return aux.typeError(l, 1, "number"),
    }
    const d = numeric.parseDecimalLiteral(g, buf.items) catch return aux.retNil(l);
    return aux.ret(l, Value.obj(.decimal, d));
}

fn collectgarbage(l: *Thread) Error!u32 {
    const opts = [_][]const u8{ "collect", "stop", "restart", "count", "step", "isrunning", "generational", "incremental" };
    const o = try aux.checkOption(l, 1, "collect", &opts);
    const g = l.g;
    switch (o) {
        0 => {
            gc.fullCollect(g);
            try runFinalizers(l);
            return aux.retInt(l, 0);
        },
        1 => {
            g.gc_stopped = true;
            return aux.retInt(l, 0);
        },
        2 => {
            g.gc_stopped = false;
            return aux.retInt(l, 0);
        },
        3 => return aux.ret(l, Value.float(@as(f64, @floatFromInt(g.allocated)) / 1024.0)),
        4 => {
            gc.fullCollect(g);
            try runFinalizers(l);
            return aux.retBool(l, true);
        },
        5 => return aux.retBool(l, !g.gc_stopped),
        6, 7 => return aux.retStr(l, "incremental"),
        else => unreachable,
    }
}

/// Runs pending `__gc` finalizers. Errors in finalizers are reported as
/// warnings, as in Lua.
pub fn runFinalizers(l: *Thread) Error!void {
    const g = l.g;
    while (g.tobefnz.pop()) |h| {
        h.finalize = .done;
        const v = switch (h.tag) {
            .table => Value.obj(.table, h),
            .userdata => Value.obj(.userdata, h),
            else => continue,
        };
        const tm = l.metamethod(v, .gc);
        if (tm.tag != .closure and tm.tag != .native) continue;
        const saved = l.top;
        try l.push(tm);
        try l.push(v);
        if (!api.pcall(l, 1, 0)) {
            const msg = api.errorMessage(l, l.stack[l.top - 1]);
            out.warning(g, "error in __gc", msg);
        }
        l.top = saved;
    }
}

fn warn(l: *Thread) Error!u32 {
    const n = l.argCount();
    if (n == 0) return aux.argError(l, 1, "string expected, got no value", .{});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    var i: u32 = 1;
    while (i <= n) : (i += 1) buf.appendSlice(l.g.gpa, try aux.checkBytes(l, i)) catch return l.raiseMem();
    const msg = buf.items;
    if (n == 1 and msg.len > 0 and msg[0] == '@') {
        if (std.mem.eql(u8, msg, "@on")) l.g.warn_on = true;
        if (std.mem.eql(u8, msg, "@off")) l.g.warn_on = false;
        return 0;
    }
    if (l.g.warn_on) out.warning(l.g, null, msg);
    return 0;
}

fn pcall(l: *Thread) Error!u32 {
    _ = try aux.checkAny(l, 1);
    const func = l.base();
    const nargs = l.argCount() - 1;
    if (api.pcall(l, nargs, -1)) {
        // Results are at func: shift them up one to insert `true`.
        const n = l.top - func;
        try l.ensure(1);
        var i = n;
        while (i > 0) : (i -= 1) l.stack[func + i] = l.stack[func + i - 1];
        l.stack[func] = .true;
        l.top = func + n + 1;
        return n + 1;
    }
    const err = l.stack[l.top - 1];
    l.top = func;
    try l.push(.false);
    try l.push(err);
    return 2;
}

fn xpcall(l: *Thread) Error!u32 {
    const handler = try aux.checkFunction(l, 2);
    const base = l.base();
    const nargs = l.argCount() - 2;
    // Move the function above the handler: [f, h, args] -> [h, f, args]
    const f = l.stack[base];
    l.stack[base] = handler;
    l.stack[base + 1] = f;
    const func = base + 1;
    l.top = func + 1 + nargs;
    if (api.pcall(l, nargs, -1)) {
        const n = l.top - func;
        l.stack[base] = .true;
        return n + 1;
    }
    const err = l.stack[l.top - 1];
    l.top = base + 1;
    const r = try ops.call1(l, handler, &.{err});
    l.top = base;
    try l.push(.false);
    try l.push(r);
    return 2;
}

fn load(l: *Thread) Error!u32 {
    const chunk = l.arg(1);
    var src: []const u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |o| l.g.gpa.free(o);
    if (chunk.tag == .string) {
        src = chunk.as(String).bytes();
    } else if (chunk.tag == .closure or chunk.tag == .native) {
        // Reader function: concatenate pieces until nil or "".
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(l.g.gpa);
        while (true) {
            const piece = try ops.call1(l, chunk, &.{});
            if (piece.isNil()) break;
            if (piece.tag != .string) return l.raiseFmt("reader function must return a string", .{});
            const b = piece.as(String).bytes();
            if (b.len == 0) break;
            buf.appendSlice(l.g.gpa, b) catch return l.raiseMem();
        }
        owned = buf.toOwnedSlice(l.g.gpa) catch return l.raiseMem();
        src = owned.?;
    } else return aux.typeError(l, 1, "string");
    const default_name = if (chunk.tag == .string) src else "=(load)";
    const name = (try aux.optString(l, 2, default_name)).?;
    const name_copy = l.g.gpa.dupe(u8, name) catch return l.raiseMem();
    defer l.g.gpa.free(name_copy);
    const env_given = l.hasArg(4);
    const env = l.arg(4);
    api.load(l, src, name_copy) catch {
        const msg = l.stack[l.top - 1];
        l.top -= 1;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    if (env_given) {
        const cl = l.stack[l.top - 1].as(object.Closure);
        if (cl.nupvals > 0) cl.upvals()[0].closed = env;
    }
    return 1;
}

pub fn readFile(l: *Thread, path: []const u8) Error![]u8 {
    const io = l.g.io;
    return std.Io.Dir.cwd().readFileAlloc(io, path, l.g.gpa, .unlimited) catch |e| {
        return l.raiseFmt("cannot open {s} ({s})", .{ path, @errorName(e) });
    };
}

fn loadfile(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const src = readFile(l, path) catch {
        const msg = l.err;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    defer l.g.gpa.free(src);
    const name = std.fmt.allocPrint(l.g.gpa, "@{s}", .{path}) catch return l.raiseMem();
    defer l.g.gpa.free(name);
    api.load(l, src, name) catch {
        const msg = l.stack[l.top - 1];
        l.top -= 1;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    if (l.hasArg(3)) {
        const cl = l.stack[l.top - 1].as(object.Closure);
        if (cl.nupvals > 0) cl.upvals()[0].closed = l.arg(3);
    }
    return 1;
}

fn dofile(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const src = try readFile(l, path);
    defer l.g.gpa.free(src);
    const name = std.fmt.allocPrint(l.g.gpa, "@{s}", .{path}) catch return l.raiseMem();
    defer l.g.gpa.free(name);
    const base = l.top;
    api.load(l, src, name) catch return l.raise(l.stack[l.top - 1]);
    _ = try interp.call(l, base, 0, -1);
    return l.top - base;
}
