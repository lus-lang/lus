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
const aux = @import("auxlib.zig");
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
    .{ .name = "print", .func = print },
    .{ .name = "arity", .func = arity },
    .{ .name = "rawequal", .func = rawequal },
    .{ .name = "rawget", .func = rawget },
    .{ .name = "rawlen", .func = rawlen },
    .{ .name = "rawset", .func = rawset },
    .{ .name = "select", .func = select },
    .{ .name = "setmetatable", .func = setmetatable, .leaf = setmetatableLeaf },
    .{ .name = "tonumber", .func = tonumber, .leaf = tonumberLeaf },
    .{ .name = "tostring", .func = tostring },
    .{ .name = "type", .func = @"type" },
    .{ .name = "warn", .func = warn },
    .{ .name = "bigint", .func = bigint },
    .{ .name = "decimal", .func = decimal },
    .{ .name = "pledge", .func = pledgeFn },
};

pub fn open(l: *Thread) Error!void {
    const g = l.g;
    const globals = g.globals.as(Table);
    try aux.setFuncs(l, globals, .fields, "", &funcs);
    try aux.setField(l, globals, "_G", g.globals);
    try aux.setField(l, globals, "_VERSION", try l.newStringValue("Lus 2.0"));
    // The generic `for` steps these iterators itself (`interp.tforcall`).
    g.iter_next = next;
    g.iter_ipairs = ipairsAux;
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

/// `tonumber` of one number or string, without a frame.
fn tonumberLeaf(_: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs != 1) return state.leaf_miss;
    const v = args[0];
    if (v.tag == .integer or v.tag == .float) return v;
    if (v.tag != .string) return state.leaf_miss;
    return ops.toNumberCoerce(v) orelse .nil;
}

fn tonumber(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (l.arg(2).isNil()) {
        // Bigints and decimals convert to the nearest float
        // (spec/design/numbers.md).
        if (v.tag == .bigint or v.tag == .decimal) return aux.ret(l, Value.float(@import("../vm/numeric.zig").toFloat(l.g.gpa, v)));
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
    if (v.tag != .string) return aux.typeError(l, 1, "string");
    const s = std.mem.trim(u8, try aux.checkBytes(l, 1), " \t\n\r\x0b\x0c");
    var neg = false;
    var digits = s;
    if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) {
        neg = digits[0] == '-';
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
    return raiseObject(l, v);
}

/// Raises `v`, replacing a nil error object with a descriptive message.
fn raiseObject(l: *Thread, v: Value) Error {
    if (v.isNil()) return l.raise(try l.newStringValue("<no error object>"));
    return l.raise(v);
}

fn assert(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.truthy()) return l.argCount();
    if (l.argCount() < 2) {
        _ = try aux.checkAny(l, 1);
        return l.raiseFmt("assertion failed!", .{});
    }
    const msg = l.arg(2);
    if (msg.tag == .string) {
        // A string message carries the position of the assert call.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(l.g.gpa);
        l.where(&buf, 1) catch return l.raiseMem();
        buf.appendSlice(l.g.gpa, msg.as(String).bytes()) catch return l.raiseMem();
        return l.raise(try l.newStringValue(buf.items));
    }
    return raiseObject(l, msg);
}

fn getmetatable(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const mt = l.metatable(v) orelse return aux.retNil(l);
    const protected = table.getStr(mt, l.g.tm_names[@backingInt(state.TM.metatable)].?);
    if (!protected.isNil()) return aux.ret(l, protected);
    return aux.ret(l, Value.obj(.table, mt));
}

fn setmetatable(l: *Thread) Error!u32 {
    const b = l.base();
    const r = setmetatableLeaf(l, l.stack.ptr + b, l.top - b);
    if (r.tag != state.leaf_miss.tag) return aux.ret(l, r);
    return setmetatableSlow(l);
}

/// The common call of `setmetatable` (`state.LeafFn`): a table without a
/// metatable gets a metatable that is known to lack `__gc`, which needs
/// no check beyond the types.
fn setmetatableLeaf(l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value {
    if (nargs != 2) return state.leaf_miss;
    const tv = args[0];
    const mv = args[1];
    if (tv.tag != .table or mv.tag != .table) return state.leaf_miss;
    const t = tv.as(Table);
    const mt = mv.as(Table);
    const gc_bit = @as(u16, 1) << @backingInt(state.TM.gc);
    if (t.metatable != null or t.isReadonly() or mt.tm_absent & gc_bit == 0) return state.leaf_miss;
    t.metatable = mt;
    gc.barrierBack(l.g, &t.hdr);
    return tv;
}

/// Every other call of `setmetatable`, kept out of line so the common
/// call above runs without saving registers.
noinline fn setmetatableSlow(l: *Thread) Error!u32 {
    const t = try aux.checkTable(l, 1);
    const mtv = l.arg(2);
    if (mtv.tag != .nil and mtv.tag != .table) return aux.typeError(l, 2, "nil or table");
    // A metatable could redirect every access, so a read-only table keeps
    // the one it has.
    if (t.isReadonly()) return l.raiseRun("attempt to modify a readonly table", .{});
    if (t.metatable) |old| {
        if (!table.getStr(old, l.g.tm_names[@backingInt(state.TM.metatable)].?).isNil()) {
            return l.raiseFmt("cannot change a protected metatable", .{});
        }
    }
    t.metatable = if (mtv.tag == .table) mtv.as(Table) else null;
    // The collector traces the table again, with or without a metatable,
    // so a table that was weak under its old one is strong from now on.
    gc.barrierBack(l.g, &t.hdr);
    if (t.metatable) |mt| try registerFinalizer(l, &t.hdr, mt);
    return aux.ret(l, l.arg(1));
}

pub fn registerFinalizer(l: *Thread, h: *gc.Header, mt: *Table) Error!void {
    // The metatable's absence cache answers for the common metatable
    // without `__gc` without a hash lookup.
    if (state.tmLookup(l.g, mt, .gc).isNil()) return;
    // A new metatable with a finalizer on an object that already has one
    // makes the finalizer run with the permissions of this thread.
    try @import("../vm/pledge.zig").noteFinalizer(l, h);
    if (h.finalize != .none) return;
    l.g.finobj.append(l.g.gpa, h) catch return l.raiseMem();
    h.finalize = .pending;
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

/// `arity(f)`: the number of parameters that the function `f` declares
/// and whether it takes extra arguments. It tells what a function is and
/// nothing of what it holds, so it needs no permission.
fn arity(l: *Thread) Error!u32 {
    const v = l.arg(1);
    switch (v.tag) {
        .closure => {
            const p = v.as(object.Closure).proto;
            try l.push(Value.int(p.num_params));
            try l.push(Value.boolean(p.is_vararg));
            return 2;
        },
        // A function of the runtime or of a host declares no parameters
        // in a form the runtime can read.
        .native => return aux.retNil(l),
        else => return aux.typeError(l, 1, "function"),
    }
}

fn rawlen(l: *Thread) Error!u32 {
    const v = l.arg(1);
    return switch (v.tag) {
        .table => aux.retInt(l, table.length(v.as(Table))),
        .string => aux.retInt(l, v.as(String).chars()),
        else => aux.typeError(l, 1, "table or string"),
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
            const b = numeric.parseBigText(g, s) catch |e| switch (e) {
                error.OutOfRange => return numeric.raiseBigRange(l),
                error.OutOfMemory => return l.raiseMem(),
                else => return aux.retNil(l),
            };
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
        .integer => ops.numberToBuf(g.gpa, &buf, v) catch return l.raiseMem(),
        .bigint => {
            // A bigint converts without text, so the limit of its numeral
            // leaves the larger limit of a decimal in place.
            const c = v.as(numeric.BigInt).toConst();
            const r = numeric.decRange(g.gpa, c, 0) catch return l.raiseMem();
            if (r != .ok) return numeric.raiseRange(l, r);
            return aux.ret(l, Value.obj(.decimal, numeric.newDecFromConst(g, c, 0) catch return l.raiseMem()));
        },
        .float => {
            // Shortest round-trip representation.
            buf.print(g.gpa, "{d}", .{v.asFloat()}) catch return l.raiseMem();
        },
        .string => buf.appendSlice(g.gpa, std.mem.trim(u8, v.as(String).bytes(), " \t\n\r")) catch return l.raiseMem(),
        else => return aux.typeError(l, 1, "number"),
    }
    // Text that is not a numeral gives nil, and a numeral past the limits
    // of a decimal raises, since it names a value the program cannot hold.
    const d = numeric.parseDecimalLiteral(g, buf.items) catch |e| switch (e) {
        error.OutOfRange => return numeric.raiseRange(l, numeric.rangeOfText(buf.items)),
        error.OutOfMemory => return l.raiseMem(),
        else => return aux.retNil(l),
    };
    return aux.ret(l, Value.obj(.decimal, d));
}

fn collectgarbage(l: *Thread) Error!u32 {
    const opts = [_][]const u8{ "collect", "stop", "restart", "count", "step", "isrunning", "generational", "incremental", "param" };
    const o = try aux.checkOption(l, 1, "collect", &opts);
    const g = l.g;
    // The collector cannot be driven from inside a finalizer.
    if (g.running_finalizers) return aux.retNil(l);
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
        3 => return aux.ret(l, Value.float(@as(f64, @floatFromInt(g.counter.bytes)) / 1024.0)),
        4 => {
            const done = gc.stepCollect(g, try aux.optInt(l, 2, 0));
            try runFinalizers(l);
            return aux.retBool(l, done);
        },
        5 => return aux.retBool(l, !g.gc_stopped),
        6, 7 => {
            const prev = gc.setMode(g, if (o == 6) .generational else .incremental);
            return aux.retStr(l, @tagName(prev));
        },
        8 => {
            const p = try aux.checkOption(l, 2, null, std.meta.fieldNames(gc.Param));
            const v = try aux.optInt(l, 3, -1);
            return aux.retInt(l, gc.setParam(g, @fromBackingInt(@intCast(p)), v));
        },
        else => unreachable,
    }
}

/// Runs pending `__gc` finalizers. Errors in finalizers are reported as
/// warnings, as in Lua.
pub fn runFinalizers(l: *Thread) Error!void {
    const g = l.g;
    // Finalizers never nest: one running finalizer does not start the
    // queue again at its own safe points.
    if (g.running_finalizers) return;
    g.running_finalizers = true;
    defer g.running_finalizers = false;
    while (g.tobefnz.pop()) |h| {
        // The object is an ordinary object again: setting a metatable with
        // __gc inside its finalizer registers it for one more round.
        h.finalize = .none;
        // The finalizer runs with the permissions of the thread that
        // registered it.
        const pledge = @import("../vm/pledge.zig");
        const scope = pledge.beginFinalizer(l, h);
        defer pledge.endFinalizer(l, scope);
        const v = switch (h.tag) {
            .table => Value.obj(.table, h),
            .userdata => Value.obj(.userdata, h),
            .thread => {
                // A detached coroutine failed and became unreachable
                // before anything collected its error, which stops the
                // program.
                const sched = @import("../vm/sched.zig");
                if (g.sched.closing) continue;
                if (sched.uncollected(h.as(Thread))) |t| return sched.raiseUncollected(l, t);
                continue;
            },
            else => continue,
        };
        const tm = l.metamethod(v, .gc);
        if (tm.isNil()) continue;
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

fn load(l: *Thread) Error!u32 {
    try requireLoad(l);
    const chunk = l.arg(1);
    var src: []const u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |o| l.g.gpa.free(o);
    if (chunk.tag == .string) {
        src = chunk.as(String).bytes();
    } else if (chunk.tag == .vector) {
        // Binary chunks from string.dump arrive as vectors.
        src = chunk.as(object.Vector).bytes.items;
    } else if (chunk.tag == .closure or chunk.tag == .native) {
        // Reader function: concatenate pieces until nil or "". An error
        // while reading fails the load like a syntax error does.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(l.g.gpa);
        readChunk(l, chunk, &buf) catch |e| switch (e) {
            // A state shutting down unwinds through every protection.
            error.LusError => if (l.g.halting or l.g.sched.fatal) return e else {
                const msg = l.err;
                try l.push(.nil);
                try l.push(msg);
                return 2;
            },
            else => |x| return x,
        };
        owned = buf.toOwnedSlice(l.g.gpa) catch return l.raiseMem();
        src = owned.?;
    } else return aux.typeError(l, 1, "string");
    const default_name = if (chunk.tag == .string) src else if (chunk.tag == .vector) "=(load)" else "=(load)";
    const name = (try aux.optString(l, 2, default_name)).?;
    const name_copy = l.g.gpa.dupe(u8, name) catch return l.raiseMem();
    defer l.g.gpa.free(name_copy);
    const env_given = l.hasArg(4);
    const env = l.arg(4);
    if (try modeRejects(l, src, (try aux.optString(l, 3, "bt")).?)) return 2;
    api.load(l, src, name_copy) catch {
        const msg = l.stack[l.top - 1];
        l.top -= 1;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    if (env_given) {
        const cl = l.stack[l.top - 1].as(object.Closure);
        if (cl.nupvals > 0) {
            cl.upvals()[0].closed = env;
            gc.barrierBack(l.g, &cl.upvals()[0].hdr);
        }
    }
    return 1;
}

fn readChunk(l: *Thread, reader: Value, buf: *std.ArrayList(u8)) Error!void {
    while (true) {
        const piece = try ops.call1(l, reader, &.{});
        if (piece.isNil()) return;
        if (piece.tag != .string) return l.raiseMsg("reader function must return a string");
        const b = piece.as(String).bytes();
        if (b.len == 0) return;
        buf.appendSlice(l.g.gpa, b) catch return l.raiseMem();
    }
}

pub fn readFile(l: *Thread, path: []const u8) Error![]u8 {
    const io = l.g.io;
    return std.Io.Dir.cwd().readFileAlloc(io, path, l.g.gpa, .unlimited) catch |e| {
        return l.raiseFmt("cannot open {s} ({s})", .{ path, @errorName(e) });
    };
}

/// Whether `src` is a binary chunk.
pub fn isBinaryChunk(src: []const u8) bool {
    return @import("../compile/dump.zig").isBinary(src);
}

/// Whether `l` may hand the binary chunk `src` to the loader. The loader
/// trusts a binary chunk as it trusts the compiler, so a script loads one
/// only with the `bytecode` permission, which the host alone grants.
pub fn mayLoadBinary(l: *Thread) bool {
    const pledge = @import("../vm/pledge.zig");
    return pledge.allowed(l, pledge.bytecode, null);
}

/// Raises the permission error when `src` is a binary chunk that `l` may
/// not load.
pub fn requireBytecode(l: *Thread, src: []const u8) Error!void {
    if (!isBinaryChunk(src)) return;
    const pledge = @import("../vm/pledge.zig");
    try pledge.require(l, pledge.bytecode, null);
}

/// Checks a chunk against a load mode such as "b", "t", or "bt". When
/// the mode rejects the chunk, pushes the conventional failure and
/// returns true. A binary chunk also needs the `bytecode` permission.
fn modeRejects(l: *Thread, src: []const u8, mode: []const u8) Error!bool {
    const binary = isBinaryChunk(src);
    if (binary) try requireBytecode(l, src);
    const want: u8 = if (binary) 'b' else 't';
    if (std.mem.indexOfScalar(u8, mode, want) != null) return false;
    const msg = std.fmt.allocPrint(l.g.gpa, "attempt to load a {s} chunk (mode is '{s}')", .{ if (binary) "binary" else "text", mode }) catch return l.raiseMem();
    defer l.g.gpa.free(msg);
    _ = try aux.retFail(l, msg);
    return true;
}

fn loadfile(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    try requireLoad(l);
    try @import("../vm/pledge.zig").require(l, "fs:read", path);
    const src = readFile(l, path) catch {
        const msg = l.err;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    defer l.g.gpa.free(src);
    const name = std.fmt.allocPrint(l.g.gpa, "@{s}", .{path}) catch return l.raiseMem();
    defer l.g.gpa.free(name);
    if (try modeRejects(l, src, (try aux.optString(l, 2, "bt")).?)) return 2;
    api.load(l, src, name) catch {
        const msg = l.stack[l.top - 1];
        l.top -= 1;
        try l.push(.nil);
        try l.push(msg);
        return 2;
    };
    if (l.hasArg(3)) {
        const cl = l.stack[l.top - 1].as(object.Closure);
        if (cl.nupvals > 0) {
            cl.upvals()[0].closed = l.arg(3);
            gc.barrierBack(l.g, &cl.upvals()[0].hdr);
        }
    }
    return 1;
}

fn dofile(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    try requireLoad(l);
    try @import("../vm/pledge.zig").require(l, "fs:read", path);
    const src = try readFile(l, path);
    defer l.g.gpa.free(src);
    const name = std.fmt.allocPrint(l.g.gpa, "@{s}", .{path}) catch return l.raiseMem();
    defer l.g.gpa.free(name);
    const base = l.top;
    try requireBytecode(l, src);
    api.load(l, src, name) catch return l.raise(l.stack[l.top - 1]);
    _ = try interp.call(l, base, 0, -1);
    return l.top - base;
}

fn pledgeFn(l: *Thread) Error!u32 {
    const pledge = @import("../vm/pledge.zig");
    const n = l.argCount();
    var results: std.ArrayList(bool) = .empty;
    defer results.deinit(l.g.gpa);
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const spec = try aux.checkBytes(l, i);
        const r = try pledge.apply(l, spec, false);
        results.append(l.g.gpa, r == .granted) catch return l.raiseMem();
    }
    for (results.items) |b| try l.push(Value.boolean(b));
    return n;
}

fn requireLoad(l: *Thread) Error!void {
    if (!@import("../vm/pledge.zig").allowed(l, "load", null)) return l.raiseFmt("permission \"load\" denied", .{});
}
