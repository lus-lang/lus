//! Argument checking and registration helpers shared by every native
//! library. These are the only routines that format "bad argument"
//! errors, so the messages stay uniform.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const numeric = @import("../vm/numeric.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const String = object.String;
const Table = object.Table;

pub const Reg = struct {
    name: []const u8,
    /// The native. The linker of `lus build --aot` sets it to null when
    /// the program never reaches the builtin (`spec/design/aot.md`,
    /// "Leaving out code"), and the registration then skips it.
    func: ?state.NativeFn,
    /// The frameless fast part of `func` (`state.LeafFn`), if any.
    leaf: ?state.LeafFn = null,
    /// The leaf computes only the first result (`state.Native.leaf_first`).
    leaf_first: bool = false,
};

/// True on targets that can start processes. WASI has no process
/// creation, so `os.execute` and `io.popen` raise there.
pub const can_spawn = @import("builtin").os.tag != .wasi;

/// Raises the standard error for an operation the target lacks.
pub fn unavailable(l: *Thread, what: []const u8) Error {
    return l.raiseFmt("{s} is not available on this platform", .{what});
}

/// Name of the running native for error messages.
pub fn fnName(l: *Thread) []const u8 {
    const f = l.frame();
    if (f.native) |n| if (n.name) |s| return s.bytes();
    return "?";
}

pub fn argError(l: *Thread, i: u32, comptime fmt: []const u8, args: anytype) Error {
    var buf: [256]u8 = undefined;
    const extra = std.fmt.bufPrint(&buf, fmt, args) catch "?";
    const debug = @import("../vm/debug.zig");
    var namebuf: [256]u8 = undefined;
    var idx = i;
    var name = fnName(l);
    if (l.frames.items.len > 0) {
        if (debug.calleeName(l, l.frames.items.len - 1, &namebuf)) |n| {
            name = n.name;
            // A method call passes the receiver as argument 1, which the
            // caller did not write: shift indices and name it "self".
            if (std.mem.eql(u8, n.kind, "method")) {
                idx -= 1;
                if (idx == 0) return l.raiseFmt("calling '{s}' on bad self ({s})", .{ name, extra });
            }
        } else if (debug.globalName(l, l.stack[l.frame().func], &namebuf)) |g| {
            name = g;
        }
    }
    return l.raiseFmt("bad argument #{d} to '{s}' ({s})", .{ idx, name, extra });
}

pub fn typeError(l: *Thread, i: u32, expected: []const u8) Error {
    const got = if (l.hasArg(i)) l.typeNameOf(l.arg(i)) else "no value";
    return argError(l, i, "{s} expected, got {s}", .{ expected, got });
}

pub fn checkAny(l: *Thread, i: u32) Error!Value {
    if (!l.hasArg(i)) return argError(l, i, "value expected", .{});
    return l.arg(i);
}

pub fn checkTable(l: *Thread, i: u32) Error!*Table {
    const v = l.arg(i);
    if (v.tag != .table) return typeError(l, i, "table");
    return v.as(Table);
}

pub inline fn checkInt(l: *Thread, i: u32) Error!i64 {
    const v = l.arg(i);
    if (v.tag == .integer) return v.asInt();
    return checkIntSlow(l, i);
}

/// `checkInt` for every argument that is not an integer already.
noinline fn checkIntSlow(l: *Thread, i: u32) Error!i64 {
    const v = l.arg(i);
    switch (v.tag) {
        .integer => return v.asInt(),
        .float, .bigint, .decimal => {
            if (ops.toIntegerStrict(v)) |n| return n;
            if (v.tag == .decimal) {
                if (numeric.decIntegral(l.g.gpa, v.as(numeric.Decimal)) catch null) |m| {
                    var mm = m;
                    defer mm.deinit();
                    if (mm.toConst().toInt(i64)) |n| return n else |_| {}
                }
            }
            return argError(l, i, "number has no integer representation", .{});
        },
        .string => {
            if (ops.toNumberCoerce(v)) |n| {
                if (ops.toIntegerStrict(n)) |x| return x;
                return argError(l, i, "number has no integer representation", .{});
            }
            return typeError(l, i, "number");
        },
        else => return typeError(l, i, "number"),
    }
}

pub fn optInt(l: *Thread, i: u32, default: i64) Error!i64 {
    if (l.arg(i).isNil()) return default;
    return checkInt(l, i);
}

pub fn checkNumber(l: *Thread, i: u32) Error!Value {
    const v = l.arg(i);
    if (v.isNumber()) return v;
    if (v.tag == .string) {
        if (ops.toNumberCoerce(v)) |n| return n;
    }
    return typeError(l, i, "number");
}

pub fn checkFloat(l: *Thread, i: u32) Error!f64 {
    const v = try checkNumber(l, i);
    return numeric.toFloat(l.g.gpa, v);
}

pub fn optNumber(l: *Thread, i: u32, default: Value) Error!Value {
    if (l.arg(i).isNil()) return default;
    return checkNumber(l, i);
}

/// String argument. Numbers are converted to strings, as in Lua.
pub fn checkString(l: *Thread, i: u32) Error!*String {
    const v = l.arg(i);
    if (v.tag == .string) return v.as(String);
    if (v.isNumber()) {
        const s = try ops.toString(l, v);
        // Replace the argument so the string stays reachable.
        l.stack[l.base() + i - 1] = Value.obj(.string, s);
        return s;
    }
    return typeError(l, i, "string");
}

pub fn checkBytes(l: *Thread, i: u32) Error![]const u8 {
    return (try checkString(l, i)).bytes();
}

pub fn optString(l: *Thread, i: u32, default: ?[]const u8) Error!?[]const u8 {
    if (l.arg(i).isNil()) return default;
    return try checkBytes(l, i);
}

pub fn checkFunction(l: *Thread, i: u32) Error!Value {
    const v = l.arg(i);
    if (v.tag != .closure and v.tag != .native) return typeError(l, i, "function");
    return v;
}

pub fn optBool(l: *Thread, i: u32, default: bool) bool {
    const v = l.arg(i);
    if (v.isNil()) return default;
    return v.truthy();
}

/// Checks that argument `i` is one of `names`, returning its index.
pub fn checkOption(l: *Thread, i: u32, default: ?[]const u8, names: []const []const u8) Error!usize {
    const s = if (default) |d| (try optString(l, i, d)).? else try checkBytes(l, i);
    for (names, 0..) |n, idx| if (std.mem.eql(u8, n, s)) return idx;
    return argError(l, i, "invalid option '{s}'", .{s});
}

// ---------------------------------------------------------------------
// Results

pub inline fn ret(l: *Thread, v: Value) Error!u32 {
    try l.push(v);
    return 1;
}

pub inline fn retInt(l: *Thread, v: i64) Error!u32 {
    return ret(l, Value.int(v));
}

pub inline fn retBool(l: *Thread, b: bool) Error!u32 {
    return ret(l, Value.boolean(b));
}

pub inline fn retStr(l: *Thread, s: []const u8) Error!u32 {
    return ret(l, try l.newStringValue(s));
}

pub inline fn retNil(l: *Thread) Error!u32 {
    return ret(l, .nil);
}

/// Returns `nil, message` (the conventional failure result).
pub fn retFail(l: *Thread, msg: []const u8) Error!u32 {
    try l.push(.nil);
    try l.push(try l.newStringValue(msg));
    return 2;
}

// ---------------------------------------------------------------------
// Registration

/// How the program reaches the entries of a registration of builtins.
/// The entries of a `fields` registration are reached by a path, such as
/// `table.insert`, or all at once when the program uses the table as a
/// value. The entries of a `methods` registration are reached by the
/// field names that the program reads. A `library` is reached both ways,
/// as `string` is through the metatable of strings. The entries of an
/// `always` registration, such as metamethods, are always kept.
pub const Kind = enum { fields, methods, library, always };

/// Creates a table that holds the builtins `funcs`, registered under
/// `path` (see `setFuncs`).
pub fn newLib(l: *Thread, comptime kind: Kind, comptime path: []const u8, comptime funcs: []const Reg) Error!*Table {
    // A library is a namespace that code reads by name, which a hash part
    // serves as well as a shape, without making one for each key.
    const t = state.newDictIn(l.g, funcs.len) catch return l.raiseMem();
    // Keep the table rooted while the natives are allocated.
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    try setFuncs(l, t, kind, path, funcs);
    return t;
}

/// Stores the builtins `funcs` in `t`. `path` names the table for the
/// linker: the global name of a library such as `string` or
/// `network.tcp`, the empty string for globals, and for methods the
/// library that alone creates the values, followed by a colon and the
/// type, such as `network:socket`. Methods of values that more than one
/// library can create have no library before the colon, such as
/// `:io.file`. A build for the link object (`-Dlink-object`)
/// exports a symbol for each registration whose name lists the kind, the
/// path, and the names of the entries, and which holds the address of
/// the array, so that the linker finds each entry's function by its
/// relocation.
pub fn setFuncs(l: *Thread, t: *Table, comptime kind: Kind, comptime path: []const u8, comptime funcs: []const Reg) Error!void {
    const S = struct {
        const array = funcs[0..funcs.len].*;
        const ref: *const anyopaque = &array;
    };
    if (@import("build_options").link_object and kind != .always) @export(&S.ref, .{ .name = guardName(kind, path, funcs) });
    for (&S.array) |*f| {
        // The linker writes the function after Zig compiled this load, so
        // the load must not fold to the constant.
        const func = @as(*const volatile ?state.NativeFn, &f.func).* orelse continue;
        const n = state.newNative(l.g, func, f.name, 0) catch return l.raiseMem();
        n.leaf = @as(*const volatile ?state.LeafFn, &f.leaf).*;
        n.leaf_first = f.leaf_first;
        try setField(l, t, f.name, Value.obj(.native, n));
    }
}

/// The symbol of a registration in the link object:
/// `lus.reg:KIND:PATH:NAME,NAME,...`.
fn guardName(comptime kind: Kind, comptime path: []const u8, comptime funcs: []const Reg) []const u8 {
    comptime {
        var name: []const u8 = "lus.reg:" ++ @tagName(kind) ++ ":" ++ path ++ ":";
        for (funcs, 0..) |f, i| name = name ++ (if (i == 0) "" else ",") ++ f.name;
        return name;
    }
}

/// The layout of `Reg`, which the converter of the link object reads.
pub const reg_layout = [_]u32{ @sizeOf(Reg), @offsetOf(Reg, "func"), @offsetOf(Reg, "leaf") };

comptime {
    if (@import("build_options").link_object) @export(&reg_layout, .{ .name = "lus.reg_layout" });
}

pub fn setField(l: *Thread, t: *Table, name: []const u8, v: Value) Error!void {
    // Creating the key can collect, so the table and the value stay on
    // the stack until the store.
    const top = l.top;
    defer l.top = top;
    try l.push(Value.obj(.table, t));
    try l.push(v);
    const k = try l.newString(name);
    try ops.rawSet(l, t, Value.obj(.string, k), v);
}

pub fn getField(l: *Thread, t: *Table, name: []const u8) Error!Value {
    const k = try l.newString(name);
    return table.getStr(t, k);
}

pub fn setGlobal(l: *Thread, name: []const u8, v: Value) Error!void {
    try setField(l, l.g.globals.as(Table), name, v);
}

pub fn native(l: *Thread, f: state.NativeFn, name: []const u8) Error!Value {
    const n = state.newNative(l.g, f, name, 0) catch return l.raiseMem();
    return Value.obj(.native, n);
}
