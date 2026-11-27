//! Compile-time evaluation (`spec/design/meta.md`). The initializer of a
//! `<meta>` local, and an `if` condition known at compile time, run in a
//! meta state: a fresh state with the standard library, the build flags
//! of the compilation, and a permission set limited to the grants of the
//! compilation. One meta state serves every evaluation of one chunk, in
//! source order, and closes when the chunk is compiled.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../syntax/ast.zig");
const codegen = @import("codegen.zig");
const api = @import("../api.zig");
const vm = struct {
    const state = @import("../vm/state.zig");
    const object = @import("../vm/object.zig");
    const value = @import("../vm/value.zig");
    const table = @import("../vm/table.zig");
    const gc = @import("../vm/gc.zig");
    const numeric = @import("../vm/numeric.zig");
    const pledge = @import("../vm/pledge.zig");
};
const Value = vm.value.Value;
const Thread = vm.state.Thread;
const Global = vm.state.Global;
const Table = vm.object.Table;
const String = vm.object.String;
const Allocator = std.mem.Allocator;

pub const FlagsMap = std.StringHashMapUnmanaged(Value);

/// A raw store of a key that is never nil or NaN.
/// Stores without metamethods. The tables that compile-time evaluation
/// keeps are old to the collector, so each store tells it of the value.
fn tset(g: *vm.state.Global, t: *Table, k: Value, v: Value) Allocator.Error!void {
    vm.table.set(g.gpa, t, k, v) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    vm.gc.barrierTable(g, t, k, v);
}

/// Where the permissions of a meta state come from.
pub const Grants = union(enum) {
    /// Pure computation: every pledge returns false.
    none,
    /// The current permissions of a running thread, which limit what the
    /// initializers may pledge.
    thread: *Thread,
    /// Command line grants (`-P`) of a tool that compiles without running.
    specs: []const []const u8,
};

/// Interrupts reach initializers through SIGINT on POSIX hosts.
const can_interrupt = builtin.os.tag != .windows and builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

/// Set by SIGINT while a meta state exists. A count hook in the meta
/// state reads it and raises an error at the running line, so the build
/// stops with the position of the initializer that was running.
var interrupted = std.atomic.Value(bool).init(false);
var open_count: u32 = 0;
var saved_action: if (can_interrupt) std.posix.Sigaction else void = undefined;

fn onInterrupt(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    interrupted.store(true, .release);
}

/// Reports and consumes an interrupt. The error it leads to reports the
/// interrupt, so it is not raised again when the meta state closes.
fn interruptedNative(l: *Thread) vm.state.Error!u32 {
    try l.push(Value.boolean(interrupted.swap(false, .acq_rel)));
    return 1;
}

fn watchInterrupts() void {
    if (!can_interrupt) return;
    open_count += 1;
    if (open_count > 1) return;
    interrupted.store(false, .release);
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = onInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(.INT, &act, &saved_action);
}

fn unwatchInterrupts() void {
    if (!can_interrupt) return;
    open_count -= 1;
    if (open_count > 0) return;
    std.posix.sigaction(.INT, &saved_action, null);
    // An interrupt that arrived as an initializer ended still stops the
    // program, as it would have without a meta state.
    if (interrupted.load(.acquire)) std.posix.raise(.INT) catch {};
}

pub const Meta = struct {
    l: *Thread,
    /// The flags of the meta state, owned by its extension table.
    flags: ?*const FlagsMap,
    /// Holds every value that a later evaluation may receive, so the
    /// collector of the meta state keeps it.
    keep: *Table,
    nkeep: i64 = 0,

    pub fn close(m: *Meta, gpa: Allocator) void {
        api.close(m.l);
        gpa.destroy(m);
        unwatchInterrupts();
    }

    /// Keeps `v` alive for the rest of the compilation.
    pub fn retain(m: *Meta, v: Value) Allocator.Error!void {
        m.nkeep += 1;
        try tset(m.l.g, m.keep, Value.int(m.nkeep), v);
    }
};

pub const OpenError = Allocator.Error || error{MetaSetup};

/// Creates the meta state of a compilation of `g`.
pub fn open(g: *Global, flags: ?*const FlagsMap, grants: Grants) OpenError!*Meta {
    g.meta_opens +%= 1;
    const gpa = g.gpa;
    const m = try gpa.create(Meta);
    errdefer gpa.destroy(m);
    const l = api.newState(g.parent_gpa, g.io) catch return error.OutOfMemory;
    errdefer api.close(l);
    api.openLibs(l) catch return error.MetaSetup;
    const mg = l.g;
    m.* = .{ .l = l, .flags = null, .keep = undefined };
    m.keep = vm.state.newTableIn(mg, 0, 0) catch return error.OutOfMemory;
    try mg.fixed.append(mg.gpa, &m.keep.hdr);
    const empty: FlagsMap = .empty;
    m.flags = try copyFlags(l, flags orelse &empty);
    // A fixed seed makes initializers that draw random numbers produce
    // the same values on every build.
    if (api.doString(l, "math.randomseed(0)", "=meta") != null) return error.MetaSetup;
    if (can_interrupt) {
        const aux = @import("../lib/auxlib.zig");
        aux.setGlobal(l, "__lus_meta_interrupted", aux.native(l, interruptedNative, "interrupted") catch return error.MetaSetup) catch return error.MetaSetup;
        const hook = "debug.sethook(function() if __lus_meta_interrupted() then error('interrupted', 2) end end, '', 100000)";
        if (api.doString(l, hook, "=meta") != null) return error.MetaSetup;
        watchInterrupts();
    }
    limitPermissions(l, grants) catch return error.MetaSetup;
    return m;
}

/// Gives the meta state the flags of the compilation: the map that
/// folding in nested compilations reads, and the read-only global table.
fn copyFlags(l: *Thread, src: *const FlagsMap) OpenError!*const FlagsMap {
    const g = l.g;
    const map = try g.gpa.create(FlagsMap);
    map.* = .empty;
    var owned = true;
    errdefer if (owned) {
        map.deinit(g.gpa);
        g.gpa.destroy(map);
    };
    var it = src.iterator();
    while (it.next()) |e| {
        var v = e.value_ptr.*;
        if (v.tag == .string) {
            const s = vm.state.newStringIn(g, v.as(String).bytes()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => unreachable,
            };
            v = Value.obj(.string, s);
            try g.fixed.append(g.gpa, v.header());
        }
        try map.put(g.gpa, e.key_ptr.*, v);
    }
    try g.ext.put(g.gpa, "flags.compile", map);
    owned = false;
    const data = vm.state.newTableIn(g, 0, map.count()) catch return error.OutOfMemory;
    try g.fixed.append(g.gpa, &data.hdr);
    var mi = map.iterator();
    while (mi.next()) |e| {
        const k = vm.state.newStringIn(g, e.key_ptr.*) catch return error.OutOfMemory;
        try tset(g, data, Value.obj(.string, k), e.value_ptr.*);
    }
    data.setReadonly(true);
    @import("../lib/auxlib.zig").setGlobal(l, "flags", Value.obj(.table, data)) catch return error.MetaSetup;
    return map;
}

fn limitPermissions(l: *Thread, grants: Grants) !void {
    switch (grants) {
        .none => try vm.pledge.limitTo(l, null),
        .thread => |src| try vm.pledge.limitTo(l, src),
        .specs => |specs| {
            try vm.pledge.limitTo(l, null);
            try vm.pledge.hostGrant(l, specs);
        },
    }
}

/// A name that an evaluation receives: a `<meta>` local or a `<const>`
/// compile-time constant of the enclosing code, with its value in the
/// meta state.
pub const Known = struct { name: []const u8, value: Value };

pub const EvalResult = union(enum) {
    /// The value, in the meta state, kept alive until the meta state
    /// closes.
    ok: Value,
    /// The message of a compile error or of a raised error.
    err: []const u8,
};

/// Evaluates `e` in the meta state with the `known` names bound to their
/// values. A free name in `unknown` is a local of the enclosing code that
/// has no value at compile time, which is a compile error.
pub fn eval(
    m: *Meta,
    arena: Allocator,
    chunkname: []const u8,
    e: *ast.Expr,
    known: []const Known,
    unknown: *const std.StringHashMapUnmanaged(void),
) Allocator.Error!EvalResult {
    const l = m.l;
    const span = e.span;
    var stats: std.ArrayList(*ast.Stat) = .empty;
    if (known.len > 0) {
        const names = try arena.alloc(ast.AttName, known.len);
        for (known, names) |k, *n| n.* = .{ .name = .{ .text = k.name, .span = span } };
        const va = try arena.create(ast.Expr);
        va.* = .{ .span = span, .line = e.line, .kind = .vararg };
        const vals = try arena.alloc(*ast.Expr, 1);
        vals[0] = va;
        const s = try arena.create(ast.Stat);
        s.* = .{ .span = span, .line = e.line, .kind = .{ .local = .{ .names = names, .values = vals } } };
        try stats.append(arena, s);
    }
    const rets = try arena.alloc(*ast.Expr, 1);
    rets[0] = e;
    const r = try arena.create(ast.Stat);
    r.* = .{ .span = span, .line = e.line, .kind = .{ .return_ = rets } };
    try stats.append(arena, r);
    const block = try arena.create(ast.Block);
    block.* = .{ .stats = stats.items, .span = span, .end_line = e.line };
    const chunk: ast.Chunk = .{ .block = block, .source = "", .comments = &.{} };
    const res = try codegen.compileAst(l.g, arena, chunk, .{
        .chunkname = chunkname,
        .flags = m.flags,
        .meta_unknown = unknown,
        .meta_grants = .{ .thread = l },
    });
    const p = switch (res) {
        .ok => |p| p,
        .err => |msg| {
            const out = try arena.dupe(u8, msg);
            l.g.gpa.free(msg);
            return .{ .err = out };
        },
    };
    const base = l.top;
    defer l.top = base;
    const cl = api.newMainClosure(l, p, l.g.globals) catch return error.OutOfMemory;
    l.push(Value.obj(.closure, cl)) catch return error.OutOfMemory;
    for (known) |k| l.push(k.value) catch return error.OutOfMemory;
    if (!api.pcall(l, @intCast(known.len), 1)) {
        const msg = api.errorMessage(l, l.stack[l.top - 1]);
        return .{ .err = try arena.dupe(u8, msg) };
    }
    const v = l.stack[l.top - 1];
    try m.retain(v);
    return .{ .ok = v };
}

/// Converts a compile-time constant of the target state into the meta
/// state.
pub fn intoMeta(m: *Meta, v: Value) Allocator.Error!Value {
    const g = m.l.g;
    return switch (v.tag) {
        .string => blk: {
            const s = vm.state.newStringIn(g, v.as(String).bytes()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => unreachable,
            };
            const out = Value.obj(.string, s);
            try m.retain(out);
            break :blk out;
        },
        .bigint => blk: {
            const text = vm.numeric.bigToString(g.gpa, v.as(vm.numeric.BigInt)) catch return error.OutOfMemory;
            defer g.gpa.free(text);
            const b = vm.numeric.parseBigLiteral(g, text) catch return error.OutOfMemory;
            const out = Value.obj(.bigint, b);
            try m.retain(out);
            break :blk out;
        },
        .decimal => blk: {
            const text = vm.numeric.decimalToString(g.gpa, v.as(vm.numeric.Decimal)) catch return error.OutOfMemory;
            defer g.gpa.free(text);
            const d = vm.numeric.parseDecimalLiteral(g, text) catch return error.OutOfMemory;
            const out = Value.obj(.decimal, d);
            try m.retain(out);
            break :blk out;
        },
        else => v,
    };
}

pub const ConvertResult = union(enum) {
    ok: Value,
    /// The type that is not a meta value and the path to it.
    bad: struct { type_name: []const u8, path: []const u8 },
};

/// Copies a meta value from the meta state into `g`: scalars as they are,
/// strings and numbers as new objects, vectors as read-only vectors, and
/// tables as read-only tables that keep sharing and cycles.
pub fn intoTarget(m: *Meta, g: *Global, arena: Allocator, v: Value) Allocator.Error!ConvertResult {
    var cv: Converter = .{ .m = m, .g = g, .arena = arena };
    defer cv.seen.deinit(arena);
    const out = try cv.value(v, "");
    if (cv.bad) |b| return .{ .bad = b };
    return .{ .ok = out };
}

const Converter = struct {
    m: *Meta,
    g: *Global,
    arena: Allocator,
    seen: std.AutoHashMapUnmanaged(*Table, *Table) = .empty,
    bad: ?@FieldType(ConvertResult, "bad") = null,
    /// Tables entered and not yet left, which bounds the native stack.
    depth: u32 = 0,

    const max_depth = 200;

    fn value(cv: *Converter, v: Value, path: []const u8) Allocator.Error!Value {
        if (cv.bad != null) return .nil;
        const g = cv.g;
        switch (v.tag) {
            .nil, .true, .false, .integer, .float => return v,
            .string => {
                const s = vm.state.newStringIn(g, v.as(String).bytes()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidUtf8 => unreachable,
                };
                return Value.obj(.string, s);
            },
            .bigint => {
                const text = vm.numeric.bigToString(g.gpa, v.as(vm.numeric.BigInt)) catch return error.OutOfMemory;
                defer g.gpa.free(text);
                return Value.obj(.bigint, vm.numeric.parseBigLiteral(g, text) catch return error.OutOfMemory);
            },
            .decimal => {
                const text = vm.numeric.decimalToString(g.gpa, v.as(vm.numeric.Decimal)) catch return error.OutOfMemory;
                defer g.gpa.free(text);
                return Value.obj(.decimal, vm.numeric.parseDecimalLiteral(g, text) catch return error.OutOfMemory);
            },
            .vector => {
                const src = v.as(vm.object.Vector);
                const out = try vm.gc.alloc(g, vm.object.Vector, .vector, @sizeOf(vm.object.Vector));
                out.* = .{ .hdr = out.hdr };
                try out.bytes.appendSlice(g.gpa, src.bytes.items);
                out.hdr.spare8 = 1;
                return Value.obj(.vector, out);
            },
            .table => {
                const src = v.as(Table);
                if (cv.seen.get(src)) |done| return Value.obj(.table, done);
                if (src.metatable != null) {
                    cv.bad = .{ .type_name = "table with a metatable", .path = path };
                    return .nil;
                }
                if (cv.depth >= max_depth) {
                    cv.bad = .{ .type_name = "table nested too deeply", .path = path };
                    return .nil;
                }
                cv.depth += 1;
                defer cv.depth -= 1;
                const out = try vm.state.newTableIn(g, 0, 0);
                try cv.seen.put(cv.arena, src, out);
                var key: Value = .nil;
                while (vm.table.next(src, key) catch null) |kv| {
                    key = kv.key;
                    const sub = try cv.subPath(path, kv.key);
                    const k2 = try cv.value(kv.key, sub);
                    const v2 = try cv.value(kv.val, sub);
                    if (cv.bad != null) return .nil;
                    try tset(g, out, k2, v2);
                }
                out.setReadonly(true);
                return Value.obj(.table, out);
            },
            else => {
                cv.bad = .{ .type_name = vm.value.typeName(v.tag), .path = path };
                return .nil;
            },
        }
    }

    fn subPath(cv: *Converter, path: []const u8, key: Value) Allocator.Error![]const u8 {
        return switch (key.tag) {
            .string => if (path.len == 0)
                try cv.arena.dupe(u8, key.as(String).bytes())
            else
                try std.fmt.allocPrint(cv.arena, "{s}.{s}", .{ path, key.as(String).bytes() }),
            .integer => try std.fmt.allocPrint(cv.arena, "{s}[{d}]", .{ path, key.asInt() }),
            else => try std.fmt.allocPrint(cv.arena, "{s}[{s}]", .{ path, vm.value.typeName(key.tag) }),
        };
    }
};
