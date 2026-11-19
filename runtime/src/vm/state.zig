//! Global state, threads (coroutines), native functions, string interning,
//! error raising, and the stack API used by natives written in Zig.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const gc = @import("gc.zig");
const table = @import("table.zig");
const wtf8 = @import("wtf8.zig");
const Value = value.Value;
const Tag = value.Tag;
const String = object.String;
const Table = object.Table;
const Allocator = std.mem.Allocator;

/// The single error a Lus operation can fail with. The error value itself
/// is in `Thread.err`.
pub const Error = error{
    LusError,
    /// Internal: a metamethod frame was pushed for the interpreter to run.
    /// Raised only while `Thread.meta_finish` is set, which happens only
    /// inside the interpreter loop.
    MetaCall,
};

/// What the interpreter does with the result of a metamethod frame it
/// pushed instead of calling the metamethod natively.
pub const Finish = union(enum) {
    none,
    /// Store the result into this register of the caller.
    store: u8,
    /// Skip the next instruction when the result's truth differs from k.
    cond: bool,
    /// Drop the result.
    discard,
    /// Drop the result and run the calling instruction again (closing
    /// the next pending variable). When true, keep the stack top where the
    /// call left it, because a variable-count return reads it.
    redo: bool,
};

pub const NativeFn = *const fn (l: *Thread) Error!u32;

/// A native function object. Natives receive their arguments in the stack
/// window starting at `l.base()` and push results, returning their count.
pub const Native = struct {
    hdr: gc.Header,
    func: NativeFn,
    name: ?*String = null,
    nupvals: u32 = 0,

    pub inline fn upvalues(n: *Native) []Value {
        const base: [*]u8 = @ptrCast(n);
        const p: [*]Value = @ptrCast(@alignCast(base + @sizeOf(Native)));
        return p[0..n.nupvals];
    }
    pub inline fn allocSize(nup: usize) usize {
        return @sizeOf(Native) + nup * @sizeOf(Value);
    }
};

comptime {
    std.debug.assert(@sizeOf(Native) % 16 == 0 or @sizeOf(Native) % 8 == 0);
}

/// Metamethod events. The order matches `tm_event_names`.
pub const TM = enum(u8) {
    index,
    newindex,
    gc,
    mode,
    len,
    eq,
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    idiv,
    band,
    bor,
    bxor,
    shl,
    shr,
    unm,
    bnot,
    lt,
    le,
    concat,
    call,
    close,
    tostring,
    name,
    metatable,
    pairs,
};

pub const tm_event_names = [_][]const u8{
    "__index", "__newindex", "__gc",   "__mode",  "__len",      "__eq",   "__add",
    "__sub",   "__mul",      "__mod",  "__pow",   "__div",      "__idiv", "__band",
    "__bor",   "__bxor",     "__shl",  "__shr",   "__unm",      "__bnot", "__lt",
    "__le",    "__concat",   "__call", "__close", "__tostring", "__name", "__metatable",
    "__pairs",
};

const tm_count = tm_event_names.len;
const tag_count = @as(usize, @backingInt(Tag.upvalue)) + 1;

// ---------------------------------------------------------------------
// String interning set

pub const StringSet = struct {
    slots: []?*String = &.{},
    count: usize = 0,

    fn deinit(s: *StringSet, gpa: Allocator) void {
        if (s.slots.len > 0) gpa.free(s.slots);
    }

    fn find(s: *StringSet, b: []const u8, h: u32) ?*String {
        if (s.slots.len == 0) return null;
        const mask = s.slots.len - 1;
        var i: usize = h & mask;
        while (s.slots[i]) |p| : (i = (i + 1) & mask) {
            if (p.hash == h and p.len == b.len and std.mem.eql(u8, p.bytes(), b)) return p;
        }
        return null;
    }

    fn insert(s: *StringSet, gpa: Allocator, str: *String) !void {
        if ((s.count + 1) * 2 > s.slots.len) try s.grow(gpa);
        s.place(str);
        s.count += 1;
    }

    fn place(s: *StringSet, str: *String) void {
        const mask = s.slots.len - 1;
        var i: usize = str.hash & mask;
        while (s.slots[i] != null) : (i = (i + 1) & mask) {}
        s.slots[i] = str;
    }

    fn grow(s: *StringSet, gpa: Allocator) !void {
        const old = s.slots;
        const n = if (old.len == 0) 256 else old.len * 2;
        s.slots = try gpa.alloc(?*String, n);
        @memset(s.slots, null);
        for (old) |p| if (p) |str| s.place(str);
        if (old.len > 0) gpa.free(old);
    }

    /// Removes `str`, repairing the probe sequence after it.
    pub fn remove(s: *StringSet, str: *String) void {
        if (s.slots.len == 0) return;
        const mask = s.slots.len - 1;
        var i: usize = str.hash & mask;
        while (s.slots[i]) |p| : (i = (i + 1) & mask) {
            if (p == str) break;
        } else return;
        s.slots[i] = null;
        s.count -= 1;
        var j = (i + 1) & mask;
        while (s.slots[j]) |p| : (j = (j + 1) & mask) {
            s.slots[j] = null;
            s.place(p);
        }
    }
};

// ---------------------------------------------------------------------
// Global state

pub const Global = struct {
    gpa: Allocator,
    io: std.Io,
    /// The object heap: pages, size classes, and large objects.
    heap: @import("heap.zig").Heap = .{},
    /// The collector state: phase, gray lists, and pacing.
    gcs: gc.State = .{},
    /// Counts every byte the state holds. `gpa` allocates through it.
    counter: @import("heapcount.zig").Counting = undefined,
    /// The allocator the state was created with, which owns the Global.
    parent_gpa: Allocator = undefined,
    threshold: usize = 1 << 20,
    pause: usize = 200,
    gc_depth: u32 = 0,
    gc_stopped: bool = false,
    /// Allocation points seen, for the GC stress build.
    stress_tick: u32 = 0,
    cycles: u64 = 0,
    strings: StringSet = .{},
    seed: u64,
    registry: Value = .nil,
    /// The global environment table (`_G`).
    globals: Value = .nil,
    main_thread: *Thread = undefined,
    type_metatables: [tag_count]?*Table = @splat(null),
    tm_names: [tm_count]?*String = @splat(null),
    /// Objects that are never collected (interned names used by the VM).
    fixed: std.ArrayList(*gc.Header) = .empty,
    /// Objects with a `__gc` metamethod, and those ready to finalize.
    finobj: std.ArrayList(*gc.Header) = .empty,
    tobefnz: std.ArrayList(*gc.Header) = .empty,
    memerr: *String = undefined,
    /// Hooks installed by library modules (pledge state, worker hosts...).
    ext: std.StringHashMapUnmanaged(*anyopaque) = .empty,
    /// Program arguments and environment, provided by the host.
    args: []const []const u8 = &.{},
    environ: ?*std.process.Environ.Map = null,
    warn_on: bool = false,
    running_finalizers: bool = false,
    /// Native recursion depth across all threads (calls from natives into
    /// Lus and coroutine resumes), bounded to protect the native stack.
    native_depth: u32 = 0,
    /// Set when a worker state is being stopped by its creator. No
    /// exception handler catches errors while it is set, so the worker
    /// script unwinds completely.
    halting: bool = false,
};

// ---------------------------------------------------------------------
// Threads

pub const Frame = struct {
    /// Stack index of the called function value.
    func: u32,
    /// First register (first fixed parameter).
    base: u32,
    pc: u32 = 0,
    closure: ?*object.Closure = null,
    native: ?*Native = null,
    /// Number of results the caller wants, or -1 for all.
    want: i32,
    /// Number of extra (vararg) arguments stored below `func` relocation.
    nvarargs: u32 = 0,
    /// Set when this frame was entered by a re-entrant `call` from native
    /// code: returning from it returns from the interpreter loop.
    boundary: bool = false,
    /// Set when this frame was entered by a tail call (for tracebacks).
    tail: bool = false,
    /// Stack slot where results go (the original function slot, before
    /// vararg adjustment).
    ret: u32,
    /// Set on metamethod frames pushed by the interpreter.
    finish: Finish = .none,
    /// Set on the frame of a running debug hook.
    hook: bool = false,
};

pub const Status = enum(u8) { ok, suspended, running, normal, dead, err };

pub const Thread = struct {
    hdr: gc.Header,
    g: *Global,
    stack: []Value = &.{},
    top: u32 = 0,
    frames: std.ArrayList(Frame) = .empty,
    open_upvals: ?*object.Upvalue = null,
    /// Stack levels of to-be-closed variables, innermost last.
    tbc: std.ArrayList(u32) = .empty,
    status: Status = .ok,
    err: Value = .nil,
    /// Traceback captured when the error was raised, if requested.
    err_traceback: ?*String = null,
    /// Nesting of native-to-Lus calls, bounded to protect the native stack.
    ncalls: u32 = 0,
    /// The thread that resumed this one.
    resumer: ?*Thread = null,
    /// Values passed across resume and yield.
    transfer: u32 = 0,
    /// Set by `coroutine.yield` so the call machinery unwinds to `resume`.
    yielding: bool = false,
    /// Set by the interpreter just before an operation that may call a
    /// metamethod. A Lus metamethod then runs as an interpreter frame,
    /// which lets it yield. Any native call clears it.
    meta_finish: ?Finish = null,
    /// Set when a coroutine closes itself, to end its resume cleanly.
    self_closed: bool = false,
    /// Debug hook state (debug.sethook). The hook function itself lives in
    /// the registry. `hook_mask` combines the `hook_*` bits.
    hook_mask: u8 = 0,
    hook_count: u32 = 0,
    hook_left: u32 = 0,
    /// The last instruction and frame seen by the line hook.
    hook_oldpc: u32 = 0,
    hook_oldfi: usize = std.math.maxInt(usize),
    /// False while a hook runs, so hooks never fire recursively.
    allow_hook: bool = true,
    /// Marks the next frame entered from native code as a hook frame.
    hook_calling: bool = false,
    /// When set, the first error to reach a native call boundary records a
    /// traceback in `err_traceback` before the frames unwind.
    want_traceback: bool = false,
    /// Per-thread extension slots (permission set, debug hooks).
    pledges: ?*anyopaque = null,
    hook: ?*anyopaque = null,

    pub const max_stack = 1_000_000;
    pub const hook_call: u8 = 1;
    pub const hook_ret: u8 = 2;
    pub const hook_line: u8 = 4;
    pub const hook_countm: u8 = 8;
    pub const max_ncalls = 200;

    pub fn deinitStack(l: *Thread) void {
        const gpa = l.g.gpa;
        if (l.stack.len > 0) gpa.free(l.stack);
        l.frames.deinit(gpa);
        l.tbc.deinit(gpa);
    }

    pub fn traverse(l: *Thread, m: *gc.MarkerApi) void {
        for (l.stack[0..l.top]) |v| m.mark(v);
        // Clear the dead part so stale values never resurrect.
        for (l.stack[l.top..]) |*v| v.* = .nil;
        for (l.frames.items) |f| {
            if (f.closure) |c| m.markHeader(&c.hdr);
            if (f.native) |n| m.markHeader(&n.hdr);
        }
        var u = l.open_upvals;
        while (u) |up| : (u = up.next_open) m.markHeader(&up.hdr);
        m.mark(l.err);
        if (l.err_traceback) |s| m.markHeader(&s.hdr);
        if (l.resumer) |r| m.markHeader(&r.hdr);
    }

    // -----------------------------------------------------------------
    // Stack management

    /// Ensures room for `n` more values above `top`.
    pub fn ensure(l: *Thread, n: usize) Error!void {
        const need = @as(usize, l.top) + n;
        if (need <= l.stack.len) return;
        if (need > max_stack) return l.raiseMsg("stack overflow");
        var size = @max(l.stack.len * 2, 64);
        while (size < need) size *= 2;
        size = @min(size, max_stack + 256);
        const old = l.stack;
        const new = l.g.gpa.alloc(Value, size) catch return l.raiseMem();
        @memcpy(new[0..old.len], old);
        @memset(new[old.len..], Value.nil);
        l.stack = new;
        // Repoint open upvalues into the new stack.
        var u = l.open_upvals;
        while (u) |up| : (u = up.next_open) up.loc = &new[up.level];
        if (old.len > 0) l.g.gpa.free(old);
    }

    pub inline fn push(l: *Thread, v: Value) Error!void {
        if (l.top >= l.stack.len) try l.ensure(1);
        l.stack[l.top] = v;
        l.top += 1;
    }

    pub inline fn pop(l: *Thread) Value {
        l.top -= 1;
        return l.stack[l.top];
    }

    pub inline fn frame(l: *Thread) *Frame {
        return &l.frames.items[l.frames.items.len - 1];
    }

    /// First argument slot of the running native.
    pub inline fn base(l: *Thread) u32 {
        return l.frame().base;
    }

    /// Number of arguments passed to the running native.
    pub inline fn argCount(l: *Thread) u32 {
        return l.top - l.base();
    }

    /// Argument `i` (1-based), or nil when absent.
    pub inline fn arg(l: *Thread, i: u32) Value {
        const idx = l.base() + i - 1;
        return if (idx < l.top) l.stack[idx] else .nil;
    }

    pub inline fn hasArg(l: *Thread, i: u32) bool {
        return l.base() + i - 1 < l.top;
    }

    // -----------------------------------------------------------------
    // Errors

    pub fn raise(l: *Thread, v: Value) Error {
        l.err = v;
        return error.LusError;
    }

    pub fn raiseMem(l: *Thread) Error {
        l.err = Value.obj(.string, l.g.memerr);
        return error.LusError;
    }

    pub fn raiseMsg(l: *Thread, msg: []const u8) Error {
        const s = l.newString(msg) catch return error.LusError;
        return l.raise(Value.obj(.string, s));
    }

    /// Raises a string error prefixed with the position of the Lus code
    /// that called the running native (or of the running Lus function).
    pub fn raiseFmt(l: *Thread, comptime fmt: []const u8, args: anytype) Error {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(l.g.gpa);
        // Natives report the position of their caller. Errors raised by the
        // interpreter itself report the running Lus function.
        const level: usize = if (l.frames.items.len > 0 and l.frame().closure != null) 0 else 1;
        l.where(&buf, level) catch return l.raiseMem();
        buf.print(l.g.gpa, fmt, args) catch return l.raiseMem();
        return l.raiseMsg(buf.items);
    }

    /// Raises a runtime error from inside an operation. Only a running Lus
    /// function contributes a position, so the same error raised from a
    /// native (such as `rawset`) carries none.
    pub fn raiseRun(l: *Thread, comptime fmt: []const u8, args: anytype) Error {
        if (l.frames.items.len > 0 and l.frame().closure != null) return l.raiseFmt(fmt, args);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(l.g.gpa);
        buf.print(l.g.gpa, fmt, args) catch return l.raiseMem();
        return l.raiseMsg(buf.items);
    }

    /// Appends "source:line: " for the function at `level` (0 = running
    /// function, 1 = its caller), when that function is Lus code.
    pub fn where(l: *Thread, buf: *std.ArrayList(u8), level: usize) !void {
        const frames = l.frames.items;
        if (level >= frames.len) return;
        const f = frames[frames.len - 1 - level];
        // For a native at level 0 the useful position is the caller.
        if (f.closure) |c| {
            const line = currentLine(c.proto, f.pc);
            try buf.print(l.g.gpa, "{s}:{d}: ", .{ shortSource(c.proto), line });
        } else if (level == 0 and frames.len >= 2) {
            return l.where(buf, 1);
        }
    }

    pub fn typeError(l: *Thread, v: Value, op: []const u8) Error {
        if (@import("debug.zig").varInfo(l, v)) |vi| {
            return l.raiseFmt("attempt to {s} a {s} value ({s} '{s}')", .{ op, l.typeNameOf(v), vi.kind, vi.name });
        }
        return l.raiseFmt("attempt to {s} a {s} value", .{ op, l.typeNameOf(v) });
    }

    pub fn typeNameOf(l: *Thread, v: Value) []const u8 {
        // `__name` in the metatable overrides the name of userdata and
        // tables, as luaL_typeerror does.
        if (l.metatable(v)) |mt| {
            const n = table.getStr(mt, l.g.tm_names[@backingInt(TM.name)].?);
            if (n.tag == .string) return n.as(String).bytes();
        }
        return value.typeName(v.tag);
    }

    // -----------------------------------------------------------------
    // Object creation

    pub fn newString(l: *Thread, b: []const u8) Error!*String {
        return newStringIn(l.g, b) catch |e| switch (e) {
            error.OutOfMemory => l.raiseMem(),
            error.InvalidUtf8 => l.raiseFmt("invalid UTF-8 in string at byte {d}", .{wtf8.analyze(b).error_offset}),
        };
    }

    pub fn newStringValue(l: *Thread, b: []const u8) Error!Value {
        return Value.obj(.string, try l.newString(b));
    }

    pub fn newTable(l: *Thread, narr: usize, nhash: usize) Error!*Table {
        return newTableIn(l.g, narr, nhash) catch l.raiseMem();
    }

    pub fn metatable(l: *Thread, v: Value) ?*Table {
        return switch (v.tag) {
            .table => v.as(Table).metatable,
            .userdata => v.as(object.Userdata).metatable,
            else => l.g.type_metatables[value.typeSlot(v.tag)],
        };
    }

    /// Fast metamethod lookup with the absence cache.
    pub fn metamethod(l: *Thread, v: Value, event: TM) Value {
        const mt = l.metatable(v) orelse return .nil;
        return tmLookup(l.g, mt, event);
    }
};

pub fn tmLookup(g: *Global, mt: *Table, event: TM) Value {
    const bit: u16 = if (@backingInt(event) < 16) @as(u16, 1) << @intCast(@backingInt(event)) else 0;
    if (bit != 0 and mt.tm_absent & bit != 0) return .nil;
    const r = table.getStr(mt, g.tm_names[@backingInt(event)].?);
    if (r.isNil() and bit != 0) mt.tm_absent |= bit;
    return r;
}

pub fn rawGetStr(t: *Table, s: *String) ?Value {
    const v = table.getStr(t, s);
    return if (v.isNil()) null else v;
}

pub fn currentLine(p: *object.Proto, pc: u32) u32 {
    if (p.lines.len == 0) return 0;
    const i = if (pc == 0) 0 else @min(pc - 1, p.lines.len - 1);
    return p.lines[i];
}

pub fn shortSource(p: *object.Proto) []const u8 {
    const src = if (p.source) |s| s.bytes() else "?";
    return chunkId(src);
}

/// Formats a chunk name for messages: "@file" becomes "file", "=name"
/// becomes "name", and source text becomes `[string "first line..."]`.
pub fn chunkId(src: []const u8) []const u8 {
    if (src.len > 0 and (src[0] == '@' or src[0] == '=')) return src[1..];
    return src;
}

pub fn newStringIn(g: *Global, b: []const u8) (Allocator.Error || error{InvalidUtf8})!*String {
    const a = wtf8.analyze(b);
    if (!a.valid) return error.InvalidUtf8;
    return newStringKnown(g, b, a.ascii, a.chars);
}

/// Creates a string from bytes already known to be valid WTF-8.
pub fn newStringKnown(g: *Global, b: []const u8, ascii: bool, chars: usize) Allocator.Error!*String {
    const h = object.hashBytes(g.seed, b);
    const short = b.len <= String.short_max;
    if (short) {
        if (g.strings.find(b, h)) |s| {
            gc.touchInterned(g, s);
            return s;
        }
    }
    gc.maybeCollect(g);
    const s = try gc.allocUninit(g, String, .string, String.allocSize(b.len));
    s.len = @intCast(b.len);
    s.chars = @intCast(chars);
    s.hash = h;
    s.flags = .{ .ascii = ascii, .interned = short };
    s.crumbs = null;
    @memcpy(s.bytesMut(), b);
    const base: [*]u8 = @ptrCast(s);
    base[@sizeOf(String) + b.len] = 0;
    if (short) try g.strings.insert(g.gpa, s);
    return s;
}

pub fn newTableIn(g: *Global, narr: usize, nhash: usize) Allocator.Error!*Table {
    gc.maybeCollect(g);
    const t = try gc.allocUninit(g, Table, .table, @sizeOf(Table));
    t.* = .{ .hdr = t.hdr };
    if (narr > 0 or nhash > 0) table.resize(g.gpa, t, narr, nhash) catch return error.OutOfMemory;
    return t;
}

pub fn newNative(g: *Global, f: NativeFn, name: ?[]const u8, nup: u32) Allocator.Error!*Native {
    // The name is created first, because creating a string can collect
    // and nothing roots the native until it is returned. Allocating the
    // native itself never collects.
    const name_str = if (name) |s| try newStringKnown(g, s, true, s.len) else null;
    const n = try gc.allocUninit(g, Native, .native, Native.allocSize(nup));
    n.func = f;
    n.nupvals = nup;
    n.name = name_str;
    for (n.upvalues()) |*v| v.* = .nil;
    return n;
}

pub fn newThread(g: *Global) Allocator.Error!*Thread {
    try g.gcs.threads.ensureUnusedCapacity(g.gpa, 1);
    const l = try gc.allocUninit(g, Thread, .thread, @sizeOf(Thread));
    l.* = .{ .hdr = l.hdr, .g = g };
    gc.addThread(g, l);
    l.stack = try g.gpa.alloc(Value, 64);
    @memset(l.stack, Value.nil);
    return l;
}

// ---------------------------------------------------------------------
// Hooks for object kinds defined outside this file (protos, upvalues,
// bigints, decimals, queries). They are routed here so gc.zig stays
// independent of every library.

pub fn extraObjectSize(h: *gc.Header) usize {
    return switch (h.tag) {
        .proto => @sizeOf(object.Proto),
        .upvalue => @sizeOf(object.Upvalue),
        .bigint => @import("numeric.zig").BigInt.allocSizeOf(h),
        .decimal => @import("numeric.zig").Decimal.allocSizeOf(h),
        .query => @import("query.zig").Query.allocSizeOf(h),
        else => unreachable,
    };
}

pub fn extraAlign(tag: Tag) std.mem.Alignment {
    return switch (tag) {
        .proto => .of(object.Proto),
        .upvalue => .of(object.Upvalue),
        .bigint => .of(@import("numeric.zig").BigInt),
        .decimal => .of(@import("numeric.zig").Decimal),
        .query => .of(@import("query.zig").Query),
        else => unreachable,
    };
}

pub fn freeExtra(g: *Global, h: *gc.Header) void {
    const gpa = g.gpa;
    switch (h.tag) {
        .proto => {
            const p = h.as(object.Proto);
            gpa.free(p.code);
            gpa.free(p.ic);
            gpa.free(p.constants);
            gpa.free(p.protos);
            gpa.free(p.upvals);
            gpa.free(p.handlers);
            gpa.free(p.lines);
            gpa.free(p.locvars);
        },
        .upvalue, .userdata, .closure, .native, .enum_value => {},
        .bigint => @import("numeric.zig").BigInt.freeExtra(g, h),
        .decimal => @import("numeric.zig").Decimal.freeExtra(g, h),
        .query => @import("query.zig").Query.freeExtra(g, h),
        else => {},
    }
}

pub fn traverseExtra(m: *gc.MarkerApi, h: *gc.Header) void {
    switch (h.tag) {
        .proto => {
            const p = h.as(object.Proto);
            for (p.constants) |v| m.mark(v);
            for (p.protos) |q| m.markHeader(&q.hdr);
            for (p.upvals) |u| if (u.name) |s| m.markHeader(&s.hdr);
            for (p.locvars) |lv| m.markHeader(&lv.name.hdr);
            if (p.source) |s| m.markHeader(&s.hdr);
            if (p.name) |s| m.markHeader(&s.hdr);
        },
        .upvalue => {
            const u = h.as(object.Upvalue);
            m.mark(u.loc.*);
        },
        .query => @import("query.zig").Query.traverse(m, h),
        else => {},
    }
}

// ---------------------------------------------------------------------
// State creation

/// Bytes currently held by the state.
pub fn heapBytes(g: *const Global) usize {
    return g.counter.bytes;
}

pub fn create(gpa: Allocator, io: std.Io) !*Global {
    const g = try gpa.create(Global);
    var seed: u64 = 0x2545F4914F6CDD1D;
    seed ^= @intFromPtr(g);
    g.* = .{ .gpa = gpa, .io = io, .seed = seed };
    g.parent_gpa = gpa;
    g.counter = .{ .child = gpa };
    g.gpa = g.counter.allocator();
    g.gc_stopped = true; // no collection until the state is fully built
    g.memerr = try newStringKnown(g, "not enough memory", true, 17);
    try g.fixed.append(g.gpa, &g.memerr.hdr);
    for (tm_event_names, 0..) |name, i| {
        const s = try newStringKnown(g, name, true, name.len);
        g.tm_names[i] = s;
    }
    g.main_thread = try newThread(g);
    g.registry = Value.obj(.table, try newTableIn(g, 0, 4));
    g.globals = Value.obj(.table, try newTableIn(g, 0, 64));
    g.gc_stopped = false;
    return g;
}

pub fn destroy(g: *Global) void {
    const gpa = g.gpa;
    gc.freeAll(g);
    g.strings.deinit(gpa);
    g.fixed.deinit(gpa);
    g.finobj.deinit(gpa);
    g.tobefnz.deinit(gpa);
    g.ext.deinit(gpa);
    g.parent_gpa.destroy(g);
}
