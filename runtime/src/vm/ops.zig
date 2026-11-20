//! Generic semantics used by the interpreter's slow paths and by the
//! standard library: indexing with metamethods, arithmetic with coercion,
//! comparison, concatenation, length, and conversion to strings and
//! numbers. Fast paths in the interpreter must agree with these bit for
//! bit or decline.

const std = @import("std");
const opc = @import("../compile/opcodes.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const state = @import("state.zig");
const table = @import("table.zig");
const numeric = @import("numeric.zig");
const wtf8 = @import("wtf8.zig");
const lexer = @import("../syntax/lexer.zig");
const interp = @import("interp.zig");
const fdigits = @import("fdigits.zig");
const Value = value.Value;
const Thread = state.Thread;
const Table = object.Table;
const String = object.String;
const TM = state.TM;
const Error = state.Error;

const max_tag_loop = 2000;

// ---------------------------------------------------------------------
// Indexing

pub fn index(l: *Thread, obj: Value, key: Value) Error!Value {
    var t = obj;
    var loop: u32 = 0;
    while (loop < max_tag_loop) : (loop += 1) {
        var tm: Value = undefined;
        if (t.tag == .table) {
            const tab = t.as(Table);
            const k = try normKey(l, key);
            const v = table.get(tab, k);
            if (!v.isNil()) return v;
            const mt = tab.metatable orelse return .nil;
            tm = state.tmLookup(l.g, mt, .index);
            if (tm.isNil()) return .nil;
        } else {
            tm = l.metamethod(t, .index);
            if (tm.isNil()) return indexError(l, t, key);
        }
        if (tm.tag == .closure or tm.tag == .native) {
            return callMeta(l, tm, &.{ t, key });
        }
        t = tm;
    }
    return l.raiseFmt("'__index' chain too long, possible loop", .{});
}

fn indexError(l: *Thread, t: Value, key: Value) Error {
    _ = key;
    return l.typeError(t, "index");
}

pub fn setIndex(l: *Thread, obj: Value, key: Value, val: Value) Error!void {
    var t = obj;
    var loop: u32 = 0;
    while (loop < max_tag_loop) : (loop += 1) {
        var tm: Value = undefined;
        if (t.tag == .table) {
            const tab = t.as(Table);
            const k = try normKey(l, key);
            if (tab.metatable) |mt| {
                const existing = table.get(tab, k);
                if (existing.isNil()) {
                    tm = state.tmLookup(l.g, mt, .newindex);
                    if (!tm.isNil()) {
                        if (tm.tag == .closure or tm.tag == .native) {
                            _ = try callMeta(l, tm, &.{ t, key, val });
                            return;
                        }
                        t = tm;
                        continue;
                    }
                }
            }
            return rawSet(l, tab, k, val);
        }
        tm = l.metamethod(t, .newindex);
        if (tm.isNil()) return indexError(l, t, key);
        if (tm.tag == .closure or tm.tag == .native) {
            _ = try callMeta(l, tm, &.{ t, key, val });
            return;
        }
        t = tm;
    }
    return l.raiseFmt("'__newindex' chain too long, possible loop", .{});
}

/// Normalizes bigint and decimal keys. Integer and float keys are
/// normalized inside the table.
pub inline fn normKey(l: *Thread, key: Value) Error!Value {
    if (key.tag == .bigint or key.tag == .decimal) return numeric.normalizeKey(l, key);
    return key;
}

pub fn rawSet(l: *Thread, t: *Table, key: Value, val: Value) Error!void {
    if (t.readonly) return l.raiseRun("attempt to modify a readonly table", .{});
    const k = try normKey(l, key);
    switch (k.tag) {
        .nil => return l.raiseRun("table index is nil", .{}),
        .float => if (std.math.isNan(k.asFloat())) return l.raiseRun("table index is NaN", .{}),
        else => {},
    }
    const hlen = t.hash.len;
    const alen = t.asize;
    table.set(l.g.gpa, t, k, val) catch return l.raiseMem();
    if (t.hash.len != hlen or t.asize != alen) learnTableSize(l.g, t);
    if (val.tag.isCollectable() or k.tag.isCollectable()) @import("gc.zig").barrierTable(l.g, t, k, val);
}

/// Size feedback for constructors. When the array or hash part of the
/// table that the last `newtable` instruction made grows, before a
/// collection ends, the instruction learns to make room for what the
/// table holds now, up to `max_learned` slots in each part. Records that a program builds field by field,
/// such as `{}` followed by stores or `{key = k}` followed by more
/// fields, then get their final hash part at construction. The C operand
/// of `newtable` is only a size hint, so every tier stays correct with
/// any value there. Tiers that compiled the instruction keep the hint
/// they saw.
noinline fn learnTableSize(g: *state.Global, t: *Table) void {
    const site = &g.new_table;
    if (site.table != t or site.cycle != g.cycles) return;
    const used = t.hash_used;
    const asize = t.asize;
    if (used > state.NewTableSite.max_learned or asize > state.NewTableSite.max_learned) {
        site.table = null;
        return;
    }
    // An array part grows to a power of two, and the hint takes the
    // elements the part holds, so a list of three gets three slots.
    var elems: usize = 0;
    for (0..asize) |i| elems += @intFromBool(!table.arrayIsNil(t, i));
    const ins = site.ins.?;
    if (used > opc.c(ins.*)) opc.setC(ins, @intCast(used));
    if (elems > opc.b(ins.*)) opc.setB(ins, @intCast(elems));
}

// ---------------------------------------------------------------------
// Calls from native code into Lus values

/// Calls `f` with `args` and returns its first result.
pub fn call1(l: *Thread, f: Value, args: []const Value) Error!Value {
    const base = l.top;
    _ = try callN(l, f, args, 1);
    const r = l.stack[base];
    l.top = base;
    return r;
}

/// Calls the metamethod `tm`. Inside the interpreter (when
/// `l.meta_finish` is set) a Lus metamethod is pushed as a frame and
/// `error.MetaCall` returns control to the interpreter, which runs it and
/// applies the finish action to its result. This keeps the metamethod
/// free to yield. Elsewhere it is an ordinary call.
pub fn callMeta(l: *Thread, tm: Value, args: []const Value) Error!Value {
    const fin = l.meta_finish;
    l.meta_finish = null;
    if (fin) |f| if (tm.tag == .closure) {
        try l.ensure(args.len + 2);
        const func = l.top;
        l.stack[func] = tm;
        for (args, 0..) |v, i| l.stack[func + 1 + i] = v;
        l.top = func + 1 + @as(u32, @intCast(args.len));
        const want: i32 = switch (f) {
            .discard, .redo => 0,
            else => 1,
        };
        _ = interp.precall(l, func, @intCast(args.len), want) catch |e| return switch (e) {
            error.Yield => unreachable,
            else => |x| x,
        };
        l.frame().finish = f.pack();
        return error.MetaCall;
    };
    return call1(l, tm, args);
}

/// Calls `f` with `args`, leaving `want` results (or all, when want is -1)
/// on the stack starting at the old top. Returns the result count.
pub fn callN(l: *Thread, f: Value, args: []const Value, want: i32) Error!u32 {
    try l.ensure(args.len + 2);
    const func = l.top;
    l.stack[func] = f;
    for (args, 0..) |v, i| l.stack[func + 1 + i] = v;
    l.top = func + 1 + @as(u32, @intCast(args.len));
    return interp.call(l, func, @intCast(args.len), want);
}

// ---------------------------------------------------------------------
// Arithmetic

pub const ArithOp = numeric.ArithOp;

pub fn tmForArith(op: ArithOp) TM {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .idiv => .idiv,
        .unm => .unm,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        .bnot => .bnot,
    };
}

/// Full arithmetic semantics: numbers of every subtype, string coercion,
/// then metamethods.
pub fn arith(l: *Thread, op: ArithOp, a: Value, b: Value) Error!Value {
    if (try arithRaw(l, op, a, b)) |r| return r;
    // Coerce numeric strings. Bitwise operators never coerce.
    if (!isBitwise(op)) {
        const na = toNumberCoerce(a);
        const nb = toNumberCoerce(b);
        if (na != null and nb != null) {
            if (try arithRaw(l, op, na.?, nb.?)) |r| return r;
        }
    }
    const event = tmForArith(op);
    var tm = l.metamethod(a, event);
    if (tm.isNil()) tm = l.metamethod(b, event);
    if (!tm.isNil()) return callMeta(l, tm, &.{ a, b });
    return arithError(l, op, a, b);
}

fn isBitwise(op: ArithOp) bool {
    return switch (op) {
        .band, .bor, .bxor, .shl, .shr, .bnot => true,
        else => false,
    };
}

fn arithError(l: *Thread, op: ArithOp, a: Value, b: Value) Error {
    if (isBitwise(op)) {
        const bad = if (!a.isNumber()) a else if (!b.isNumber()) b else if (toIntegerStrict(a) == null) a else b;
        if (bad.isNumber()) {
            if (@import("debug.zig").varInfo(l, bad)) |vi| {
                return l.raiseFmt("number ({s} '{s}') has no integer representation", .{ vi.kind, vi.name });
            }
            return l.raiseFmt("number has no integer representation", .{});
        }
        return l.typeError(bad, "perform bitwise operation on");
    }
    if (a.tag == .string or b.tag == .string) {
        // Strings take part in arithmetic only as numerals.
        const name = @tagName(tmForArith(op));
        return l.raiseFmt("attempt to {s} a '{s}' with a '{s}'", .{ name, l.typeNameOf(a), l.typeNameOf(b) });
    }
    const bad = if (!a.isNumber()) a else b;
    return l.typeError(bad, "perform arithmetic on");
}

/// Arithmetic on number operands only. Returns null when an operand is not
/// a number or a bitwise operand has no integer representation.
pub fn arithRaw(l: *Thread, op: ArithOp, a: Value, b: Value) Error!?Value {
    if (a.tag == .integer and b.tag == .integer) {
        const x = a.asInt();
        const y = b.asInt();
        return switch (op) {
            .add => Value.int(x +% y),
            .sub => Value.int(x -% y),
            .mul => Value.int(x *% y),
            .div => Value.float(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y))),
            .mod => blk: {
                if (y == 0) return l.raiseFmt("attempt to perform 'n%%0'", .{});
                break :blk Value.int(imod(x, y));
            },
            .idiv => blk: {
                if (y == 0) return l.raiseFmt("attempt to divide by zero", .{});
                break :blk Value.int(idiv(x, y));
            },
            .pow => Value.float(std.math.pow(f64, @floatFromInt(x), @floatFromInt(y))),
            .unm => Value.int(0 -% x),
            .band => Value.int(x & y),
            .bor => Value.int(x | y),
            .bxor => Value.int(x ^ y),
            .shl => Value.int(shiftLeft(x, y)),
            .shr => Value.int(shiftLeft(x, 0 -% y)),
            .bnot => Value.int(~x),
        };
    }
    if (!a.isNumber() or !b.isNumber()) return null;
    if (a.tag == .bigint or a.tag == .decimal or b.tag == .bigint or b.tag == .decimal) {
        return numeric.arith(l, op, a, b);
    }
    // At least one float.
    switch (op) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            const x = toIntegerStrict(a) orelse return null;
            const y = toIntegerStrict(b) orelse return null;
            return arithRaw(l, op, Value.int(x), Value.int(y));
        },
        else => {},
    }
    const x = toFloat(a);
    const y = toFloat(b);
    return Value.float(switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .mod => numeric.fmod(x, y),
        .idiv => @floor(x / y),
        .pow => std.math.pow(f64, x, y),
        .unm => -x,
        else => unreachable,
    });
}

pub inline fn imod(x: i64, y: i64) i64 {
    if (y == -1) return 0;
    const m = @rem(x, y);
    return if (m != 0 and (m ^ y) < 0) m + y else m;
}

pub inline fn idiv(x: i64, y: i64) i64 {
    if (y == -1) return 0 -% x;
    var q = @divTrunc(x, y);
    if (@rem(x, y) != 0 and ((x ^ y) < 0)) q -= 1;
    return q;
}

pub inline fn shiftLeft(x: i64, y: i64) i64 {
    if (y <= -64 or y >= 64) return 0;
    const ux: u64 = @bitCast(x);
    if (y >= 0) return @bitCast(ux << @intCast(y));
    return @bitCast(ux >> @intCast(-y));
}

pub fn toFloat(v: Value) f64 {
    return switch (v.tag) {
        .integer => @floatFromInt(v.asInt()),
        .float => v.asFloat(),
        else => std.math.nan(f64),
    };
}

/// Converts a number with an exact integer value to an integer.
pub fn toIntegerStrict(v: Value) ?i64 {
    return switch (v.tag) {
        .integer => v.asInt(),
        .float => floatToInt(v.asFloat()),
        .bigint => numeric.bigToInt(v.as(numeric.BigInt)),
        else => null,
    };
}

pub fn floatToInt(f: f64) ?i64 {
    if (f != @floor(f)) return null;
    if (f >= -9.223372036854775808e18 and f < 9.223372036854775808e18) return @intFromFloat(f);
    return null;
}

/// Converts strings holding numerals to numbers, as arithmetic does.
pub fn toNumberCoerce(v: Value) ?Value {
    switch (v.tag) {
        .integer, .float, .bigint, .decimal => return v,
        .string => {
            // A plain decimal integer of at most 18 digits, which cannot
            // overflow, is the common case and converts directly.
            const raw = v.as(String).bytes();
            if (raw.len > 0 and raw.len <= 18) {
                const neg = raw[0] == '-';
                const digits = raw[@intFromBool(neg)..];
                if (digits.len > 0) {
                    var acc: i64 = 0;
                    for (digits) |c| {
                        const d = c -% '0';
                        if (d > 9) break;
                        acc = acc * 10 + d;
                    } else return Value.int(if (neg) -acc else acc);
                }
            }
            const s = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
            const n = lexer.parseNumber(s) orelse return null;
            return switch (n) {
                .integer => |i| Value.int(i),
                .float => |f| Value.float(f),
            };
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------
// Comparison

pub fn rawEqual(l: *Thread, a: Value, b: Value) bool {
    if (a.tag == b.tag) {
        return switch (a.tag) {
            .nil, .true, .false => true,
            .integer, .light => a.payload == b.payload,
            .float => a.asFloat() == b.asFloat(),
            .string => a.payload == b.payload or stringEqual(a.as(String), b.as(String)),
            .bigint, .decimal => numeric.compare(l.g.gpa, a, b) == .eq,
            else => a.payload == b.payload,
        };
    }
    if (a.isNumber() and b.isNumber()) {
        if (a.tag == .integer and b.tag == .float) return @as(f64, @floatFromInt(a.asInt())) == b.asFloat() and floatToInt(b.asFloat()) == a.asInt();
        if (a.tag == .float and b.tag == .integer) return rawEqual(l, b, a);
        return numeric.compare(l.g.gpa, a, b) == .eq;
    }
    return false;
}

fn stringEqual(x: *String, y: *String) bool {
    // Short strings are interned, so distinct pointers mean distinct
    // strings unless both are long.
    if (x.flags.interned and y.flags.interned) return false;
    return x.len == y.len and x.hash == y.hash and std.mem.eql(u8, x.bytes(), y.bytes());
}

pub fn equal(l: *Thread, a: Value, b: Value) Error!bool {
    if (rawEqual(l, a, b)) return true;
    if (a.tag != b.tag) return false;
    if (a.tag != .table and a.tag != .userdata) return false;
    var tm = l.metamethod(a, .eq);
    if (tm.isNil()) tm = l.metamethod(b, .eq);
    if (tm.isNil()) return false;
    return (try callMeta(l, tm, &.{ a, b })).truthy();
}

pub fn lessThan(l: *Thread, a: Value, b: Value) Error!bool {
    if (a.tag == .integer and b.tag == .integer) return a.asInt() < b.asInt();
    if (a.isNumber() and b.isNumber()) return numLess(l, a, b, false);
    if (a.tag == .string and b.tag == .string) return strLess(a.as(String), b.as(String), false);
    return compareTM(l, a, b, .lt);
}

pub fn lessEqual(l: *Thread, a: Value, b: Value) Error!bool {
    if (a.tag == .integer and b.tag == .integer) return a.asInt() <= b.asInt();
    if (a.isNumber() and b.isNumber()) return numLess(l, a, b, true);
    if (a.tag == .string and b.tag == .string) return strLess(a.as(String), b.as(String), true);
    return compareTM(l, a, b, .le);
}

fn numLess(l: *Thread, a: Value, b: Value, or_equal: bool) bool {
    if (a.tag == .float and b.tag == .float) return if (or_equal) a.asFloat() <= b.asFloat() else a.asFloat() < b.asFloat();
    if ((a.tag == .integer or a.tag == .float) and (b.tag == .integer or b.tag == .float)) {
        return intFloatLess(a, b, or_equal);
    }
    const o = numeric.compare(l.g.gpa, a, b) orelse return false;
    return if (or_equal) o != .gt else o == .lt;
}

fn intFloatLess(a: Value, b: Value, or_equal: bool) bool {
    // Exact comparison between an integer and a float.
    if (a.tag == .integer) {
        const i = a.asInt();
        const f = b.asFloat();
        if (std.math.isNan(f)) return false;
        if (f >= 9.223372036854775808e18) return true;
        if (f < -9.223372036854775808e18) return false;
        const fl = if (or_equal) @floor(f) else @ceil(f);
        const fi: i64 = @intFromFloat(fl);
        return if (or_equal) i <= fi else i < fi;
    }
    const f = a.asFloat();
    const i = b.asInt();
    if (std.math.isNan(f)) return false;
    if (f >= 9.223372036854775808e18) return false;
    if (f < -9.223372036854775808e18) return true;
    const fl = if (or_equal) @ceil(f) else @floor(f);
    const fi: i64 = @intFromFloat(fl);
    return if (or_equal) fi <= i else fi < i;
}

fn strLess(a: *String, b: *String, or_equal: bool) bool {
    const o = std.mem.order(u8, a.bytes(), b.bytes());
    return if (or_equal) o != .gt else o == .lt;
}

fn compareTM(l: *Thread, a: Value, b: Value, event: TM) Error!bool {
    var tm = l.metamethod(a, event);
    if (tm.isNil()) tm = l.metamethod(b, event);
    if (!tm.isNil()) return (try callMeta(l, tm, &.{ a, b })).truthy();
    const ta = value.typeName(a.tag);
    const tb = value.typeName(b.tag);
    if (std.mem.eql(u8, ta, tb)) return l.raiseFmt("attempt to compare two {s} values", .{l.typeNameOf(a)});
    return l.raiseFmt("attempt to compare {s} with {s}", .{ l.typeNameOf(a), l.typeNameOf(b) });
}

// ---------------------------------------------------------------------
// Length

pub fn length(l: *Thread, v: Value) Error!Value {
    switch (v.tag) {
        .string => return Value.int(v.as(String).chars),
        .table => {
            const t = v.as(Table);
            if (t.metatable) |mt| {
                const tm = state.tmLookup(l.g, mt, .len);
                if (!tm.isNil()) return callMeta(l, tm, &.{v});
            }
            return Value.int(table.length(t));
        },
        .vector => return Value.int(@intCast(v.as(object.Vector).bytes.items.len)),
        else => {
            const tm = l.metamethod(v, .len);
            if (!tm.isNil()) return callMeta(l, tm, &.{v});
            return l.typeError(v, "get length of");
        },
    }
}

// ---------------------------------------------------------------------
// Strings

/// Writes the decimal digits of `u` at the end of `tmp`, two at a time,
/// and returns the index of the first digit. The room before that index
/// takes a sign.
pub fn intDigits(tmp: *[20]u8, u_in: u64) usize {
    var u = u_in;
    var i: usize = tmp.len;
    while (u >= 100) {
        const r: usize = @intCast(u % 100);
        u /= 100;
        i -= 2;
        tmp[i..][0..2].* = digit_pairs[r * 2 ..][0..2].*;
    }
    if (u >= 10) {
        i -= 2;
        tmp[i..][0..2].* = digit_pairs[@as(usize, @intCast(u)) * 2 ..][0..2].*;
    } else {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(u));
    }
    return i;
}

const digit_pairs = blk: {
    var d: [200]u8 = undefined;
    for (0..100) |k| {
        d[2 * k] = '0' + k / 10;
        d[2 * k + 1] = '0' + k % 10;
    }
    break :blk d;
};

/// Formats a number the way `tostring` does.
pub fn numberToBuf(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: Value) !void {
    switch (v.tag) {
        .integer => {
            // Integers are the most common number in concatenations, so
            // they skip the general formatter.
            var tmp: [20]u8 = undefined;
            var i = intDigits(&tmp, @abs(v.asInt()));
            if (v.asInt() < 0) {
                i -= 1;
                tmp[i] = '-';
            }
            try buf.appendSlice(gpa, tmp[i..]);
        },
        .float => try formatFloat(gpa, buf, v.asFloat()),
        .bigint => {
            const s = try numeric.bigToString(gpa, v.as(numeric.BigInt));
            defer gpa.free(s);
            try buf.appendSlice(gpa, s);
        },
        .decimal => {
            const s = try numeric.decimalToString(gpa, v.as(numeric.Decimal));
            defer gpa.free(s);
            try buf.appendSlice(gpa, s);
        },
        else => unreachable,
    }
}

/// Lua's "%.14g" float formatting, plus a trailing ".0" when the result
/// looks like an integer.
pub fn formatFloat(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: f64) !void {
    if (std.math.isNan(f)) {
        try buf.appendSlice(gpa, if (std.math.signbit(f)) "-nan" else "nan");
        return;
    }
    if (std.math.isInf(f)) {
        try buf.appendSlice(gpa, if (f < 0) "-inf" else "inf");
        return;
    }
    const start = buf.items.len;
    try formatG(gpa, buf, f, 14);
    // Use more digits when 14 do not read back as the same float.
    const back = std.fmt.parseFloat(f64, buf.items[start..]) catch f;
    if (back != f) {
        buf.items.len = start;
        try formatG(gpa, buf, f, 17);
    }
    const s = buf.items[start..];
    if (std.mem.indexOfAny(u8, s, ".eEn") == null) try buf.appendSlice(gpa, ".0");
}

/// Significant digits of a finite nonzero |f| rounded half to even to `p`
/// digits (as C printf does), and the decimal exponent of the first digit.
pub const Digits = struct { buf: [64]u8, len: usize, exp: i32 };

pub fn roundedDigits(f: f64, p: usize) Digits {
    const a = @abs(f);
    // Fast path: the shortest round-trip digits. Rounding them to p
    // digits matches rounding the exact value whenever p is at most 15 and
    // the cut does not land on an apparent tie.
    var tmp: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&tmp, "{e}", .{a}) catch unreachable;
    const epos = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp0 = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch 0;
    var all: [32]u8 = undefined;
    var n: usize = 0;
    for (sci[0..epos]) |ch| {
        if (ch != '.') {
            all[n] = ch;
            n += 1;
        }
    }
    const tie = p < n and all[p] == '5' and std.mem.allEqual(u8, all[p + 1 .. n], '0');
    // A subnormal has fewer significant bits than 15 decimal digits, so
    // its shortest digits can stray from the exact value it holds.
    if (p <= 15 and !tie and a >= std.math.floatMin(f64)) {
        return roundSlice(all[0..n], exp0, p);
    }
    // Exact path through a big-integer expansion of the double.
    var heap: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    var dec = fdigits.Decimal.init(fba.allocator(), a) catch return roundSlice(all[0..n], exp0, p);
    dec.round(@intCast(p));
    var out: Digits = .{ .buf = undefined, .len = @min(dec.digits.items.len, p), .exp = dec.exp };
    @memcpy(out.buf[0..out.len], dec.digits.items[0..out.len]);
    if (out.len == 0) {
        out.buf[0] = '0';
        out.len = 1;
    }
    return out;
}

fn roundSlice(all: []const u8, exp0: i32, p: usize) Digits {
    var exp = exp0;
    const n = all.len;
    var out: Digits = .{ .buf = undefined, .len = @min(p, n), .exp = exp };
    @memcpy(out.buf[0..out.len], all[0..out.len]);
    if (p < n) {
        const next = all[p];
        const rest_nonzero = !std.mem.allEqual(u8, all[p + 1 .. n], '0');
        const last_odd = p > 0 and (all[p - 1] - '0') % 2 == 1;
        if (next > '5' or (next == '5' and (rest_nonzero or last_odd))) {
            var i = out.len;
            while (i > 0) {
                i -= 1;
                if (out.buf[i] == '9') {
                    out.buf[i] = '0';
                } else {
                    out.buf[i] += 1;
                    break;
                }
            } else {
                std.mem.copyBackwards(u8, out.buf[1 .. out.len + 1], out.buf[0..out.len]);
                out.buf[0] = '1';
                exp += 1;
                out.exp = exp;
            }
        }
    }
    return out;
}

/// C printf "%.*g" for finite values.
pub fn formatG(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: f64, precision: usize) !void {
    const p = if (precision == 0) 1 else precision;
    if (f == 0) {
        try buf.appendSlice(gpa, if (std.math.signbit(f)) "-0" else "0");
        return;
    }
    if (f < 0) try buf.append(gpa, '-');
    const d = roundedDigits(f, p);
    // Strip trailing zeros (%g without the # flag).
    var len = d.len;
    while (len > 1 and d.buf[len - 1] == '0') len -= 1;
    const digits = d.buf[0..len];
    const exp = d.exp;
    if (exp < -4 or exp >= @as(i32, @intCast(p))) {
        try buf.append(gpa, digits[0]);
        if (len > 1) {
            try buf.append(gpa, '.');
            try buf.appendSlice(gpa, digits[1..]);
        }
        try buf.append(gpa, 'e');
        try buf.append(gpa, if (exp < 0) '-' else '+');
        const ae: u32 = @abs(exp);
        if (ae < 10) try buf.append(gpa, '0');
        try buf.print(gpa, "{d}", .{ae});
    } else if (exp >= 0) {
        const int_len: usize = @intCast(exp + 1);
        if (len <= int_len) {
            try buf.appendSlice(gpa, digits);
            try buf.appendNTimes(gpa, '0', int_len - len);
        } else {
            try buf.appendSlice(gpa, digits[0..int_len]);
            try buf.append(gpa, '.');
            try buf.appendSlice(gpa, digits[int_len..]);
        }
    } else {
        try buf.appendSlice(gpa, "0.");
        try buf.appendNTimes(gpa, '0', @intCast(-exp - 1));
        try buf.appendSlice(gpa, digits);
    }
}

/// `tostring` without metamethods for primitive values. Appends to `buf`.
pub fn rawToBuf(l: *Thread, buf: *std.ArrayList(u8), v: Value) !void {
    const gpa = l.g.gpa;
    switch (v.tag) {
        .nil => try buf.appendSlice(gpa, "nil"),
        .true => try buf.appendSlice(gpa, "true"),
        .false => try buf.appendSlice(gpa, "false"),
        .integer, .float, .bigint, .decimal => try numberToBuf(gpa, buf, v),
        .string => try buf.appendSlice(gpa, v.as(String).bytes()),
        else => try buf.print(gpa, "{s}: 0x{x:0>14}", .{ l.typeNameOf(v), v.payload }),
    }
}

/// Full `tostring`, honoring `__tostring` and `__name`.
pub fn toString(l: *Thread, v: Value) Error!*String {
    // __tostring applies to every type, strings included, as in the
    // reference runtime. The absence cache keeps the common case cheap.
    const tm = l.metamethod(v, .tostring);
    if (!tm.isNil()) {
        const r = try call1(l, tm, &.{v});
        if (r.tag == .string) return r.as(String);
        // A numeric result reads as its numeral.
        if (r.isNumber()) return toString(l, r);
        return l.raiseFmt("'__tostring' must return a string", .{});
    }
    if (v.tag == .string) return v.as(String);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    rawToBuf(l, &buf, v) catch return l.raiseMem();
    return l.newString(buf.items);
}

/// Concatenates values for the `..` operator. Strings and numbers join
/// directly. Other values use `__concat`, pairwise from the right.
pub fn concat(l: *Thread, first: u32, n: u32) Error!Value {
    // Right to left, collapsing runs of strings and numbers. The operands
    // are re-read from the stack after every metamethod call, which may
    // reallocate it.
    var acc = l.stack[first + n - 1];
    var i: usize = n - 1;
    while (i > 0) {
        i -= 1;
        const lhs = l.stack[first + i];
        if (isStringLike(lhs) and isStringLike(acc)) {
            // Find the longest run of string-like values ending at i.
            var j = i;
            while (j > 0 and isStringLike(l.stack[first + j - 1])) j -= 1;
            acc = try joinStrings(l, l.stack[first + j .. first + i + 1], acc);
            i = j;
            continue;
        }
        var tm = l.metamethod(lhs, .concat);
        if (tm.isNil()) tm = l.metamethod(acc, .concat);
        if (tm.isNil()) {
            const bad = if (isStringLike(lhs)) acc else lhs;
            return l.typeError(bad, "concatenate");
        }
        acc = try call1(l, tm, &.{ lhs, acc });
    }
    return acc;
}

fn isStringLike(v: Value) bool {
    return v.tag == .string or v.isNumber();
}

fn joinStrings(l: *Thread, parts: []const Value, last: Value) Error!Value {
    var stack: [concat_stack]u8 = undefined;
    var first = std.heap.BufferFirstAllocator.init(&stack, l.g.gpa);
    var sb: state.StringBuffer = .{ .g = l.g };
    var gpa = first.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Reserve the whole result at once. A number takes at most
    // `number_room` bytes unless it is a big integer or a decimal, which
    // grow the buffer as needed. A long result is built where its string
    // will live.
    var room = concatRoom(last);
    for (parts) |p| room += concatRoom(p);
    if (longResult(room)) gpa = sb.allocator();
    buf.ensureTotalCapacityPrecise(gpa, room) catch return l.raiseMem();
    var ascii = true;
    var chars: usize = 0;
    for (parts) |p| try appendForConcat(l, gpa, &buf, p, &ascii, &chars);
    try appendForConcat(l, gpa, &buf, last, &ascii, &chars);
    const s = finishConcat(l.g, &sb, gpa, &buf, ascii, chars) catch return l.raiseMem();
    return Value.obj(.string, s);
}

/// True when a concatenation reserving `room` bytes builds its result in
/// a `state.StringBuffer`, because the result may be a large object.
pub inline fn longResult(room: usize) bool {
    return String.allocSize(room) > @import("heap.zig").max_small;
}

/// Creates the string of a concatenation built in `buf`, whose allocator
/// is `gpa`: in place when `gpa` is the allocator of `sb`, and as a copy
/// otherwise.
pub fn finishConcat(g: *state.Global, sb: *state.StringBuffer, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), ascii: bool, chars: usize) std.mem.Allocator.Error!*String {
    if (gpa.ptr == @as(*anyopaque, sb)) return state.stringFromBuffer(g, sb, buf, ascii, chars);
    return state.newStringKnown(g, buf.items, ascii, chars);
}

/// Size of the stack buffers that hold short concatenation results
/// before they are copied into a new string.
pub const concat_stack = 256;

/// Room for the text of an integer or a float.
const number_room = 32;

/// Bytes to reserve for a string or number operand of a concatenation.
pub fn concatRoom(v: Value) usize {
    return if (v.tag == .string) v.as(String).len else number_room;
}

/// Appends a string or number, joining a trailing lead surrogate with a
/// leading trail surrogate as WTF-8 requires. `gpa` is the allocator of
/// `buf`.
pub fn appendForConcat(l: *Thread, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: Value, ascii: *bool, chars: *usize) Error!void {
    if (v.tag == .string) {
        const s = v.as(String);
        const b = s.bytes();
        if (!s.flags.ascii) {
            if (wtf8.leadingTrailSurrogate(b)) |trail| {
                if (wtf8.trailingLeadSurrogate(buf.items)) |lead| {
                    buf.items.len -= 3;
                    var tmp: [4]u8 = undefined;
                    const n = wtf8.encode(wtf8.combineSurrogates(lead, trail), &tmp);
                    buf.appendSlice(gpa, tmp[0..n]) catch return l.raiseMem();
                    buf.appendSlice(gpa, b[3..]) catch return l.raiseMem();
                    chars.* += s.chars - 1;
                    ascii.* = false;
                    return;
                }
            }
        }
        buf.appendSlice(gpa, b) catch return l.raiseMem();
        chars.* += s.chars;
        ascii.* = ascii.* and s.flags.ascii;
        return;
    }
    const before = buf.items.len;
    numberToBuf(gpa, buf, v) catch return l.raiseMem();
    chars.* += buf.items.len - before;
}

test "float formatting" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const cases = [_]struct { f64, []const u8 }{
        .{ 1.0, "1.0" },                             .{ 0.1, "0.1" },       .{ 1e100, "1e+100" },
        .{ 123456789012345.0, "123456789012345.0" }, .{ -2.5, "-2.5" },     .{ 1.0 / 3.0, "0.33333333333333331" },
        .{ 1e15, "1e+15" },                          .{ 0.0001, "0.0001" }, .{ 0.00001, "1e-05" },
        .{ 3.14159, "3.14159" },
    };
    for (cases) |cs| {
        buf.clearRetainingCapacity();
        try formatFloat(gpa, &buf, cs[0]);
        try std.testing.expectEqualStrings(cs[1], buf.items);
    }
}
