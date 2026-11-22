//! Global state, threads (coroutines), native functions, string interning,
//! error raising, and the stack API used by natives written in Zig.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const gc = @import("gc.zig");
const table = @import("table.zig");
const wtf8 = @import("wtf8.zig");
const inv = @import("inv.zig");
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
    /// Store the result into operand `n - 1` of the calling concat
    /// instruction, then concatenate its first `n` operands.
    concat: u8,

    /// The form a frame stores, which has a fixed layout.
    pub const Packed = extern struct {
        kind: Kind = .none,
        arg: u8 = 0,

        pub const Kind = enum(u8) { none, store, cond, discard, redo, concat };

        pub inline fn unpack(p: Packed) Finish {
            return switch (p.kind) {
                .none => .none,
                .store => .{ .store = p.arg },
                .cond => .{ .cond = p.arg != 0 },
                .discard => .discard,
                .redo => .{ .redo = p.arg != 0 },
                .concat => .{ .concat = p.arg },
            };
        }
    };

    pub inline fn pack(f: Finish) Packed {
        return switch (f) {
            .none => .{},
            .store => |r| .{ .kind = .store, .arg = r },
            .cond => |k| .{ .kind = .cond, .arg = @intFromBool(k) },
            .discard => .{ .kind = .discard },
            .redo => |keep| .{ .kind = .redo, .arg = @intFromBool(keep) },
            .concat => |n| .{ .kind = .concat, .arg = n },
        };
    }
};

pub const NativeFn = *const fn (l: *Thread) Error!u32;

/// The common case of a native, run without a frame of its own. It reads
/// its `nargs` arguments at `args` before it allocates anything, and it
/// returns the single result, or `leaf_miss` when the call needs the full
/// native. It never raises an error, never calls back into Lus code, and
/// never yields: every such case returns `leaf_miss`, and the full native
/// then runs the call from the start. The full native begins with the
/// same fast part, so both paths share one implementation. A leaf has
/// the C calling convention, which returns the two words of the result
/// in two registers.
pub const LeafFn = *const fn (l: *Thread, args: [*]const Value, nargs: u32) callconv(.c) Value;

/// What a leaf returns when the full native must run the call. Its tag
/// belongs to internal objects and never appears in a value.
pub const leaf_miss: Value = Value.make(0, .proto);

/// A native function object. Natives receive their arguments in the stack
/// window starting at `l.base()` and push results, returning their count.
pub const Native = struct {
    hdr: gc.Header,
    func: NativeFn,
    name: ?*String = null,
    /// The frameless fast part of `func`, when it has one.
    leaf: ?LeafFn = null,
    nupvals: u32 = 0,
    /// The leaf computes only the first result of `func`, so it runs only
    /// for a call that wants at most one result.
    leaf_first: bool = false,
    /// The native is the body of a coroutine that yields from inside it,
    /// such as a stream of `network.fetch`. A resume after a yield runs it
    /// again from its start, with the arguments it started with, rather
    /// than returning the resume arguments from it.
    generator: bool = false,

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
    /// Open addressing with linear probing, kept at most half full. A
    /// lookup reads two neighboring slots at once, so most lookups end at
    /// their first pair. Each slot packs the string pointer with the top
    /// 16 bits of its hash, so a probe that passes other strings compares
    /// hashes without loading those strings.
    slots: []u64 = &.{},
    count: usize = 0,

    /// Object addresses fit in 48 bits on every 64-bit target, and the
    /// 32-bit targets keep the whole hash below them.
    const tag_shift = if (@sizeOf(usize) == 8) 48 else 32;
    const addr_mask: u64 = (@as(u64, 1) << tag_shift) - 1;

    inline fn pack(str: *String) u64 {
        return @as(u64, @intFromPtr(str)) | tagOf(str.hash);
    }

    /// The hash bits a slot keeps. The lowest of them is always set, so
    /// no tag equals the bits of an empty slot.
    inline fn tagOf(h: u32) u64 {
        const tag: u64 = if (tag_shift == 48) h >> 16 else h;
        return (tag | 1) << tag_shift;
    }

    inline fn strOf(slot: u64) *String {
        return @ptrFromInt(@as(usize, @intCast(slot & addr_mask)));
    }

    fn deinit(s: *StringSet, gpa: Allocator) void {
        if (s.slots.len > 0) gpa.free(s.slots);
    }

    /// Probes two slots at a time and picks the candidate without a
    /// branch, so a string found in the second slot of its probe costs
    /// no more than one found in the first.
    inline fn find(s: *StringSet, b: []const u8, h: u32) ?*String {
        if (s.slots.len == 0) return null;
        const mask = s.slots.len - 1;
        const tag = tagOf(h);
        var i: usize = h & mask;
        while (true) : (i = (i + 2) & mask) {
            const x = s.slots[i];
            const y = s.slots[(i + 1) & mask];
            const xm = x & ~addr_mask == tag;
            const ym = y & ~addr_mask == tag;
            if (xm or ym) {
                const p = strOf(if (xm) x else y);
                // The slot tag already matched 16 bits of the hash, and
                // the bytes decide equality, so a hit compares only the
                // length and the bytes.
                if (p.len == b.len and shortEql(p.bytes().ptr, b)) return p;
                // A hash that matches only in its top bits is rare, so the
                // slots are compared again one at a time.
                return s.findFrom(b, h, i);
            }
            if (x == 0 or y == 0) return null;
        }
    }

    noinline fn findFrom(s: *StringSet, b: []const u8, h: u32, start: usize) ?*String {
        const mask = s.slots.len - 1;
        var i = start;
        while (s.slots[i] != 0) : (i = (i + 1) & mask) {
            const p = strOf(s.slots[i]);
            if (p.hash == h and p.len == b.len and shortEql(p.bytes().ptr, b)) return p;
        }
        return null;
    }

    fn insert(s: *StringSet, gpa: Allocator, str: *String) !void {
        if ((s.count + 1) * 2 > s.slots.len) try s.resize(gpa, @max(256, s.slots.len * 2));
        s.place(str);
        s.count += 1;
    }

    fn place(s: *StringSet, str: *String) void {
        const mask = s.slots.len - 1;
        var i: usize = str.hash & mask;
        while (s.slots[i] != 0) : (i = (i + 1) & mask) {}
        s.slots[i] = pack(str);
    }

    fn resize(s: *StringSet, gpa: Allocator, n: usize) !void {
        const old = s.slots;
        s.slots = try gpa.alloc(u64, n);
        @memset(s.slots, 0);
        for (old) |slot| if (slot != 0) s.place(strOf(slot));
        if (old.len > 0) gpa.free(old);
    }

    /// Halves the set while it is less than an eighth full, after a
    /// collection freed many strings.
    pub fn shrink(s: *StringSet, gpa: Allocator) void {
        var n = s.slots.len;
        while (n > 256 and s.count * 8 < n) n /= 2;
        if (n == s.slots.len) return;
        s.resize(gpa, n) catch {};
    }

    /// Removes `str`, repairing the probe sequence after it.
    pub fn remove(s: *StringSet, str: *String) void {
        if (s.slots.len == 0) return;
        const mask = s.slots.len - 1;
        const want = pack(str);
        var i: usize = str.hash & mask;
        while (s.slots[i] != 0) : (i = (i + 1) & mask) {
            if (s.slots[i] == want) break;
        } else return;
        s.slots[i] = 0;
        s.count -= 1;
        var j = (i + 1) & mask;
        while (s.slots[j] != 0) : (j = (j + 1) & mask) {
            const p = strOf(s.slots[j]);
            s.slots[j] = 0;
            s.place(p);
        }
    }
};

/// Compares the bytes at `a` with `b`, which is at most
/// `String.short_max` long. Two overlapping word loads cover a string of
/// 8 to 16 bytes, so short keys compare without a loop or a call. Every
/// string keeps a terminating zero after its bytes, but `b` may be a
/// slice of anything, so neither side is read past its end.
inline fn shortEql(a: [*]const u8, b: []const u8) bool {
    const n = b.len;
    if (n >= 8) {
        var i: usize = 0;
        while (i + 8 < n) : (i += 8) {
            if (std.mem.readInt(u64, a[i..][0..8], .little) != std.mem.readInt(u64, b[i..][0..8], .little)) return false;
        }
        return std.mem.readInt(u64, a[n - 8 ..][0..8], .little) == std.mem.readInt(u64, b[n - 8 ..][0..8], .little);
    }
    if (n >= 4) {
        return std.mem.readInt(u32, a[0..4], .little) == std.mem.readInt(u32, b[0..4], .little) and
            std.mem.readInt(u32, a[n - 4 ..][0..4], .little) == std.mem.readInt(u32, b[n - 4 ..][0..4], .little);
    }
    var i: usize = 0;
    while (i < n) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

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
    pause: usize = 175,
    /// The longest string in bytes that the state makes. A longer result
    /// raises the memory error. Tests lower it to reach the limit with
    /// small strings.
    max_string: usize = String.max_len,
    gc_depth: u32 = 0,
    gc_stopped: bool = false,
    /// Allocation points seen, for the GC stress build.
    stress_tick: u32 = 0,
    cycles: u64 = 0,
    /// The table the last `newtable` instruction made, with that
    /// instruction, for the size feedback of constructors (`ops.rawSet`).
    /// It is valid only during the collection cycle it was made in, since
    /// the function that holds the instruction stays alive until the next
    /// mark ends.
    new_table: NewTableSite = .{},
    /// The natives behind `next` and the iterator of `ipairs`, which the
    /// generic `for` runs inline over a plain table.
    iter_next: ?NativeFn = null,
    iter_ipairs: ?NativeFn = null,
    /// The last pattern whose start bytes a search computed, by its text
    /// (`firstSet` in `lib/string.zig`).
    first_set: FirstSetCache = .{},
    /// The string of each ASCII character that the program made, which
    /// lives as long as the state, so `newStringKnown` returns it without
    /// a lookup.
    ascii_chars: [128]?*String = @splat(null),
    strings: StringSet = .{},
    /// The shapes of this state's tables (`shape.zig`).
    shapes: @import("shape.zig").Shapes = .{},
    /// Set while the standard library opens. The tables it makes are
    /// namespaces and metatables, which code reads by name, so they keep
    /// their keys in hash parts from the start.
    dict_tables: bool = false,
    seed: u64,
    /// The last version 7 UUID and the last ULID that `crypto` made, which
    /// keep successive identifiers increasing within one state.
    uuid7_last: u128 = 0,
    ulid_last: u128 = 0,
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
    /// The blobs of strings of this heap that were sent to workers
    /// (`blob.zig`).
    blobs: std.AutoHashMapUnmanaged(*String, *@import("blob.zig").Blob) = .empty,
    /// Hooks installed by library modules (pledge state, worker hosts...).
    ext: std.StringHashMapUnmanaged(*anyopaque) = .empty,
    /// Program arguments and environment, provided by the host.
    args: []const []const u8 = &.{},
    environ: ?*std.process.Environ.Map = null,
    warn_on: bool = false,
    /// Set once `api.freezeEnv` has frozen the global environment. Workers
    /// started from this state freeze their own environment too.
    env_frozen: bool = false,
    running_finalizers: bool = false,
    /// Native recursion depth across all threads (calls from natives into
    /// Lus and coroutine resumes), bounded to protect the native stack.
    native_depth: u32 = 0,
    /// Set when a worker state is being stopped by its creator. No
    /// exception handler catches errors while it is set, so the worker
    /// script unwinds completely.
    halting: bool = false,
    /// A debugger written in Zig (`lus debug`), or null. It receives the
    /// hook events of every thread in place of the hook function set by
    /// `debug.sethook`. Code compiles with optimizations that hide locals
    /// turned off while it is attached.
    debugger: ?*const Debugger = null,
    /// The JIT of this state: its settings and its executable memory.
    jit: @import("../jit/jit.zig").State = .{},
    /// The scheduler of detached coroutines (`sched.zig`).
    sched: @import("sched.zig").Sched = .{},
};

/// The native hook entry point used by `lus debug`. Every thread created
/// while a debugger is attached starts with `mask`, so coroutines report
/// their events too.
pub const Debugger = struct {
    ctx: *anyopaque,
    /// Receives the events named as for `debug.sethook` ("line", "call",
    /// "tail call", "return", "count"). `line` is set for line events.
    /// Hooks are disabled on `l` while it runs.
    event: *const fn (ctx: *anyopaque, l: *Thread, event: []const u8, line: ?u32) Error!void,
    /// Called with the error in `l.err` when it reaches the interpreter,
    /// before the frames unwind and before a handler is searched.
    raised: *const fn (ctx: *anyopaque, l: *Thread) void,
    mask: u8,
};

// ---------------------------------------------------------------------
// Threads

/// A call frame. The layout is fixed, because native code writes the
/// frame of a call between two compiled functions itself: fields that
/// such a call stores together are neighbors, and the frame is 64 bytes,
/// so that the address of a frame is a shift and an add.
pub const Frame = extern struct {
    closure: ?*object.Closure = null,
    native: ?*Native = null,
    /// Stack index of the called function value.
    func: u32,
    /// First register (first fixed parameter).
    base: u32,
    /// Stack slot where results go (the original function slot, before
    /// vararg adjustment).
    ret: u32,
    /// Number of results the caller wants, or -1 for all.
    want: i32,
    pc: u32 = 0,
    /// Number of extra (vararg) arguments stored below `func` relocation.
    nvarargs: u32 = 0,
    /// Set when this frame was entered by a re-entrant `call` from native
    /// code: returning from it returns from the interpreter loop.
    boundary: bool = false,
    /// Set when this frame was entered by a tail call (for tracebacks).
    tail: bool = false,
    /// Set on the frame of a running debug hook.
    hook: bool = false,
    /// Set on a frame that native code pushed for a plain call between
    /// two Lus functions. Such a frame has no finish action and is not a
    /// boundary, and its caller is a Lus frame of the same run, so native
    /// code returns from it without asking the interpreter.
    lean: bool = false,
    /// Set on metamethod frames pushed by the interpreter.
    finish: Finish.Packed = .{},
    /// Set on a frame that the interpreter pushed for a plain call
    /// between two Lus functions. Like a lean frame, it has no finish
    /// action and is not a boundary, and its caller is a Lus frame of
    /// the same run, so one test of the flags word admits the short
    /// return.
    plain: bool = false,
    /// Set on a plain frame of a function that can own an open upvalue
    /// or a to-be-closed variable. A plain frame without it returns
    /// with nothing to close.
    closes: bool = false,
    /// On a lean frame, the address in native code where the caller
    /// continues.
    resume_at: usize = 0,
    /// On the frame of a native, nonzero once the call waited with a
    /// deadline that its scheduler record still holds (`sched.waitIo`).
    wait_mark: usize = 0,

    /// The word that holds the flags and the finish action, as a lean
    /// frame has it.
    pub const lean_flags: u64 = blk: {
        const f: Frame = .{ .func = 0, .base = 0, .ret = 0, .want = 0, .lean = true };
        const bytes = std.mem.asBytes(&f)[@offsetOf(Frame, "boundary")..][0..8];
        break :blk std.mem.readInt(u64, bytes, @import("builtin").cpu.arch.endian());
    };

    /// The word that holds the flags and the finish action, as a plain
    /// frame has it.
    pub const plain_flags: u64 = blk: {
        const f: Frame = .{ .func = 0, .base = 0, .ret = 0, .want = 0, .plain = true };
        const bytes = std.mem.asBytes(&f)[@offsetOf(Frame, "boundary")..][0..8];
        break :blk std.mem.readInt(u64, bytes, @import("builtin").cpu.arch.endian());
    };

    /// The bit of the flags word that `closes` sets.
    pub const closes_bit: u64 = flagMask("closes", 1) & 0x0101010101010101;

    /// A word of a frame. Frames are aligned to 4 bytes on 32-bit
    /// targets, so a word is only as aligned as the frame.
    pub const Word = *align(@alignOf(Frame)) u64;

    comptime {
        const Call = object.Proto.CallFlags;
        std.debug.assert(plain_flags == (Call{ .plain = true, .closes = false }).frameFlags());
        std.debug.assert(plain_flags | closes_bit == (Call{ .plain = true, .closes = true }).frameFlags());
        std.debug.assert(@offsetOf(Frame, "boundary") % @alignOf(Frame) == 0);
        std.debug.assert(@offsetOf(Frame, "pc") % @alignOf(Frame) == 0);
    }

    pub inline fn flagsWordPtr(f: *Frame) Word {
        return @ptrCast(&f.boundary);
    }
    /// The word that holds the saved pc and the count of extra arguments.
    pub inline fn pcWord(f: *Frame) Word {
        return @ptrCast(&f.pc);
    }

    /// The flags word of a frame, for tests of several flags at once.
    pub inline fn flagsWord(f: *const Frame) u64 {
        const p: *align(@alignOf(Frame)) const u64 = @ptrCast(&f.boundary);
        return p.*;
    }

    fn flagMask(comptime name: []const u8, comptime size: usize) u64 {
        var bytes: [8]u8 = @splat(0);
        const off = @offsetOf(Frame, name) - @offsetOf(Frame, "boundary");
        for (bytes[off..][0..size]) |*b| b.* = 0xFF;
        return std.mem.readInt(u64, &bytes, @import("builtin").cpu.arch.endian());
    }

    /// Bits of the flags word that are clear in a frame that returns
    /// straight to a Lus caller, and bits of which one is set in it.
    pub const short_clear: u64 = flagMask("boundary", 1) | flagMask("finish", 1);
    pub const short_any: u64 = flagMask("lean", 1) | flagMask("plain", 1);

    comptime {
        std.debug.assert(@offsetOf(Finish.Packed, "kind") == 0);
        // Native code exists only on 64-bit targets.
        if (@sizeOf(usize) == 8) {
            const assert = std.debug.assert;
            assert(@sizeOf(Frame) == 64);
            // The pairs and words that a lean call stores at once.
            assert(@offsetOf(Frame, "native") == @offsetOf(Frame, "closure") + 8);
            assert(@offsetOf(Frame, "base") == @offsetOf(Frame, "func") + 4);
            assert(@offsetOf(Frame, "want") == @offsetOf(Frame, "ret") + 4);
            assert(@offsetOf(Frame, "nvarargs") == @offsetOf(Frame, "pc") + 4);
            assert(@offsetOf(Frame, "pc") % 8 == 0);
            assert(@offsetOf(Frame, "boundary") % 8 == 0);
            assert(@offsetOf(Frame, "resume_at") == @offsetOf(Frame, "boundary") + 8);
        }
    }
};

pub const Status = enum(u8) { ok, suspended, running, normal, dead, err };

pub const Thread = struct {
    /// The header is the most aligned field, which puts it first whatever
    /// order the other fields take. Heap cells are aligned to 16 bytes.
    hdr: gc.Header align(16),
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
    /// The scheduler record of a thread that waited or was detached.
    task: ?*@import("sched.zig").Task = null,
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
    /// Set on a coroutine whose resumer passes a wait on to its own
    /// resumer (`sched.canSuspend`).
    resumer_passes: bool = false,
    /// Set on a coroutine that the runtime made to hand over events
    /// (`lib/events.zig`). Closing a coroutine that waits for it closes it
    /// as well.
    event: bool = false,
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
    /// Events left before the interpreter samples the running function
    /// for the JIT. The dispatch loop keeps it in a register while it runs.
    jit_budget: u32 = 1,

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

    pub fn traverse(l: *Thread, m: anytype) void {
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
            // The hidden control variable of `for a, b from ...` holds the
            // item whose fields the loop reads.
            if (std.mem.eql(u8, vi.name, "(for record)") and std.mem.eql(u8, vi.kind, "local"))
                return l.raiseFmt("'for ... from' needs an iterator that yields tables, got a {s} value", .{l.typeNameOf(v)});
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

/// Allocates a long string of `len` bytes, more than `String.short_max`,
/// whose bytes the caller writes before anything else allocates, and
/// then passes to `finishLong`. A result whose length is known up front
/// is written in place this way, without a buffer to copy from.
pub fn newLongUninit(g: *Global, len: usize) Allocator.Error!*String {
    std.debug.assert(len > String.short_max);
    try checkStringLen(g, len);
    gc.maybeCollect(g);
    // The contents are not known yet, so the cell keeps a breadcrumb
    // slot in case they are non-ASCII.
    const s = try gc.allocUninit(g, String, .string, String.allocSizeWith(len, true));
    s.len = @intCast(len);
    s.setChars(0);
    s.hash = 0;
    s.flags().* = .{ .crumb_slot = true };
    s.initCrumbs();
    const base: [*]u8 = @ptrCast(s);
    base[@sizeOf(String) + len] = 0;
    return s;
}

/// Completes a string from `newLongUninit` once its bytes, valid WTF-8,
/// are written.
pub fn finishLong(g: *Global, s: *String, ascii: bool, chars: usize) void {
    inv.assert(textMatches(s.bytesMut(), ascii, chars));
    s.setChars(@intCast(chars));
    s.flags().ascii = ascii;
    s.hash = object.hashBytes(g.seed, s.bytesMut());
}

/// Whether the bytes of a new string are valid WTF-8 with the flags its
/// creator computed. Many callers count characters while they build a
/// string, so a wrong count is a bug of the caller.
fn textMatches(b: []const u8, ascii: bool, chars: usize) bool {
    const a = wtf8.analyze(b);
    return a.valid and a.ascii == ascii and a.chars == chars;
}

/// Creates a string from bytes already known to be valid WTF-8.
pub inline fn newStringKnown(g: *Global, b: []const u8, ascii: bool, chars: usize) Allocator.Error!*String {
    // A short string that already exists is found inline. Creating a
    // string is the out-of-line part.
    if (b.len <= String.short_max) {
        if (b.len == 1 and b[0] < 0x80) {
            if (g.ascii_chars[b[0]]) |c| return c;
            return newAsciiChar(g, b[0]);
        }
        const h = object.hashBytes(g.seed, b);
        if (g.strings.find(b, h)) |s| {
            gc.touchInterned(g, s);
            return s;
        }
        return createString(g, b, ascii, chars, h);
    }
    return createString(g, b, ascii, chars, object.hashBytes(g.seed, b));
}

/// The string of the ASCII character `c`, made fixed and remembered the
/// first time the program asks for it.
noinline fn newAsciiChar(g: *Global, c: u8) Allocator.Error!*String {
    const b = [1]u8{c};
    const h = object.hashBytes(g.seed, &b);
    const str = if (g.strings.find(&b, h)) |found| blk: {
        gc.touchInterned(g, found);
        break :blk found;
    } else try createString(g, &b, true, 1, h);
    // A string that cannot be made fixed is still a valid result.
    g.fixed.append(g.gpa, &str.hdr) catch return str;
    g.ascii_chars[c] = str;
    return str;
}

/// Allocates a string with hash `h` that `newStringKnown` did not find.
/// Creates a string from valid WTF-8 bytes without interning it, for the
/// results of concatenation, which are often used once and dropped. A
/// short one is interned when it becomes a table key (`intern`), and it
/// compares by content with the interned strings until then.
pub fn newStringFresh(g: *Global, b: []const u8, ascii: bool, chars: usize) Allocator.Error!*String {
    // The shortest results, such as keys and small tokens, repeat often,
    // so interning them at once shares one object and lets lookups
    // compare pointers.
    if (b.len <= fresh_min) return newStringKnown(g, b, ascii, chars);
    return createStringAs(g, b, ascii, chars, object.hashBytes(g.seed, b), false);
}

/// The length up to which `newStringFresh` interns at once.
pub const fresh_min = 16;

/// The interned string with the text of `s`, a short string that is not
/// interned: the one the string table holds, or `s` itself, which joins
/// the table.
pub noinline fn intern(g: *Global, s: *String) Allocator.Error!*String {
    std.debug.assert(!s.flags().interned and s.len <= String.short_max);
    if (g.strings.find(s.bytes(), s.hash)) |twin| {
        gc.touchInterned(g, twin);
        return twin;
    }
    try g.strings.insert(g.gpa, s);
    s.flags().interned = true;
    inv.assert(internedOk(g, s));
    return s;
}

/// Fails with the memory error when a string of `len` bytes would pass
/// the limit of the state, which is at most what the 32-bit length of a
/// string holds.
pub inline fn checkStringLen(g: *const Global, len: usize) Allocator.Error!void {
    if (len > g.max_string) return error.OutOfMemory;
}

noinline fn createString(g: *Global, b: []const u8, ascii: bool, chars: usize, h: u32) Allocator.Error!*String {
    return createStringAs(g, b, ascii, chars, h, b.len <= String.short_max);
}

inline fn createStringAs(g: *Global, b: []const u8, ascii: bool, chars: usize, h: u32, short: bool) Allocator.Error!*String {
    try checkStringLen(g, b.len);
    gc.maybeCollect(g);
    const slot = String.needsCrumbs(ascii, chars);
    const s = try gc.allocUninit(g, String, .string, String.allocSizeWith(b.len, slot));
    s.len = @intCast(b.len);
    s.setChars(@intCast(chars));
    s.hash = h;
    s.flags().* = .{ .ascii = ascii, .interned = short, .crumb_slot = slot };
    s.initCrumbs();
    @memcpy(s.bytesMut(), b);
    inv.assert(textMatches(b, ascii, chars));
    const base: [*]u8 = @ptrCast(s);
    base[@sizeOf(String) + b.len] = 0;
    if (short) try g.strings.insert(g.gpa, s);
    inv.assert(internedOk(g, s));
    return s;
}

/// Whether a string is interned exactly when the string table holds it.
/// A fresh string may have an interned twin with the same text.
fn internedOk(g: *Global, s: *String) bool {
    if (s.len > String.short_max) return !s.flags().interned;
    const found = g.strings.find(s.bytes(), s.hash);
    return s.flags().interned == (found == s);
}

pub const FirstSetCache = struct {
    /// Patterns longer than the key are analyzed every time.
    key: [48]u8 = undefined,
    len: usize = std.math.maxInt(usize),
    start: usize = 0,
    set: ?u128 = null,
};

pub const NewTableSite = struct {
    table: ?*Table = null,
    ins: ?*u32 = null,
    /// The inline cache entry of the instruction, which learns the kind
    /// of its lists (`object.IcEntry.lists_words`).
    ic: ?*object.IcEntry = null,
    cycle: u64 = 0,

    /// The most hash entries a constructor learns to make room for.
    pub const max_learned = 8;
};

/// An allocator for byte buffers whose contents may become a long string
/// without a copy. Every block it hands out sits behind room for a string
/// header and before room for the terminating zero, so `stringFromBuffer`
/// turns a buffer longer than the largest small object into a large
/// string in place. Building a long result, such as the text of
/// `table.concat`, then holds its bytes once instead of twice.
pub const StringBuffer = struct {
    g: *Global,

    const head = @sizeOf(String);
    const block_align = @import("heap.zig").large_align;

    pub fn allocator(self: *StringBuffer) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    inline fn block(memory: []u8) []u8 {
        return (memory.ptr - head)[0 .. head + memory.len + 1];
    }

    fn alloc(ctx: *anyopaque, len: usize, _: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *StringBuffer = @ptrCast(@alignCast(ctx));
        const p = self.g.gpa.rawAlloc(head + len + 1, block_align, ra) orelse return null;
        return p + head;
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *StringBuffer = @ptrCast(@alignCast(ctx));
        return self.g.gpa.rawResize(block(memory), block_align, head + new_len + 1, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *StringBuffer = @ptrCast(@alignCast(ctx));
        const p = self.g.gpa.rawRemap(block(memory), block_align, head + new_len + 1, ra) orelse return null;
        return p + head;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, ra: usize) void {
        const self: *StringBuffer = @ptrCast(@alignCast(ctx));
        self.g.gpa.rawFree(block(memory), block_align, ra);
    }
};

/// Creates a string from the bytes of `list`, whose memory comes from the
/// allocator of `sb`, and leaves `list` empty. A result too long for a
/// small cell becomes the string in place: its block shrinks to the
/// string and joins the large objects. An allocator that shrinks a block
/// without moving it may keep the unused capacity of a buffer that grew,
/// at most a third of it, with the string. That costs less than a copy,
/// which holds the whole buffer and the string at once and leaves the
/// buffer to an allocator that may keep it resident.
pub fn stringFromBuffer(g: *Global, sb: *StringBuffer, list: *std.ArrayList(u8), ascii: bool, chars: usize) Allocator.Error!*String {
    const a = sb.allocator();
    defer {
        list.deinit(a);
        list.* = .empty;
    }
    const n = list.items.len;
    try checkStringLen(g, n);
    // A string that may build breadcrumbs needs a slot after its bytes,
    // which the buffer lacks, so it is copied.
    if (String.allocSize(n) <= @import("heap.zig").max_small or String.needsCrumbs(ascii, chars)) {
        return newStringKnown(g, list.items, ascii, chars);
    }
    gc.maybeCollect(g);
    if (list.capacity != n) {
        if (!a.resize(list.allocatedSlice(), n)) return newStringKnown(g, list.items, ascii, chars);
        list.capacity = n;
    }
    const mem = list.items.ptr - StringBuffer.head;
    try @import("heap.zig").adoptLarge(g, mem);
    list.* = .empty;
    const s: *String = @ptrCast(@alignCast(mem));
    s.hdr = .{ .tag = .string, .flags = .{ .large = true } };
    s.len = @intCast(n);
    s.setChars(@intCast(chars));
    s.flags().* = .{ .ascii = ascii };
    s.hash = object.hashBytes(g.seed, s.bytes());
    s.initCrumbs();
    mem[StringBuffer.head + n] = 0;
    return s;
}

/// Creates a table that holds the list `vals` in its array part, as a
/// parser makes it once it read every value. A list whose values all fit
/// an unboxed kind keeps one word per slot in the cell of its table,
/// where a constructor reserves a full value per slot so that the part
/// can box in place.
pub fn newListIn(g: *Global, vals: []const Value) Allocator.Error!*Table {
    var kind: Table.ArrayKind = .none;
    for (vals) |v| kind = table.joinKind(kind, v);
    if (kind == .boxed or vals.len == 0) {
        const t = try newTableIn(g, vals.len, 0);
        table.storeList(g.gpa, t, 0, vals) catch return error.OutOfMemory;
        return t;
    }
    gc.maybeCollect(g);
    const units = table.inlineUnitsSlots(vals.len, 0, @sizeOf(u64));
    const t = try gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit);
    t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) } };
    if (units > 0) {
        table.initInline(t, vals.len, 0);
    } else {
        table.resize(g.gpa, t, vals.len, 0) catch return error.OutOfMemory;
    }
    table.storeList(g.gpa, t, 0, vals) catch return error.OutOfMemory;
    return t;
}

pub fn newTableIn(g: *Global, narr: usize, nhash: usize) Allocator.Error!*Table {
    return newTableSlotsIn(g, narr, nhash, @sizeOf(Value));
}

/// A new table that keeps its keys in a hash part from the start, for a
/// namespace such as a library, whose many keys no shape would hold.
pub fn newDictIn(g: *Global, nhash: usize) Allocator.Error!*Table {
    gc.maybeCollect(g);
    const units = table.inlineUnitsDict(0, nhash, @sizeOf(Value));
    const t = try gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit);
    t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) }, .hash_used = 0 };
    if (units > 0) {
        table.initInline(t, 0, nhash);
    } else if (nhash > 0) {
        table.resize(g.gpa, t, 0, nhash) catch return error.OutOfMemory;
    }
    return t;
}

/// `newTableIn` for the constructor whose inline cache entry is `ic`. A
/// constructor whose lists all fit an unboxed kind so far keeps its list
/// in one word per slot in the cell.
pub inline fn newTableAt(g: *Global, narr: usize, nhash: usize, ic: *const object.IcEntry) Allocator.Error!*Table {
    const slot: usize = if (narr > 0 and ic.own == object.IcEntry.lists_words) @sizeOf(u64) else @sizeOf(Value);
    if (ic.shape != object.IcEntry.none) return newShapedIn(g, narr, nhash, slot, ic.shape);
    return newTableSlotsIn(g, narr, nhash, slot);
}

/// A new table with the shape `id` that its constructor learned, and nil
/// in every slot (`ops.learnShape`).
noinline fn newShapedIn(g: *Global, narr: usize, nhash: usize, slot: usize, id: u16) Allocator.Error!*Table {
    const sh = @import("shape.zig").get(id);
    const t = try newTableSlotsIn(g, narr, @max(nhash, sh.n), slot);
    if (t.isShaped() and t.slotCap() >= sh.n) t.setShapeId(id);
    return t;
}

fn newTableSlotsIn(g: *Global, narr: usize, nhash: usize, slot: usize) Allocator.Error!*Table {
    if (g.dict_tables and narr == 0) return newDictIn(g, nhash);
    gc.maybeCollect(g);
    // Small parts of known size live in the cell of the table itself.
    const units = table.inlineUnitsSlots(narr, nhash, slot);
    const t = try gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit);
    t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) } };
    if (units > 0) {
        table.initInline(t, narr, nhash);
    } else if (narr > 0 or nhash > 0) {
        table.resize(g.gpa, t, narr, nhash) catch return error.OutOfMemory;
    }
    return t;
}

pub fn newNative(g: *Global, f: NativeFn, name: ?[]const u8, nup: u32) Allocator.Error!*Native {
    // The name is created first, because creating a string can collect
    // and nothing roots the native until it is returned. Allocating the
    // native itself never collects.
    const name_str = if (name) |s| try newStringKnown(g, s, true, s.len) else null;
    const n = try gc.allocUninit(g, Native, .native, Native.allocSize(nup));
    n.func = f;
    n.leaf = null;
    n.leaf_first = false;
    n.nupvals = nup;
    n.name = name_str;
    for (n.upvalues()) |*v| v.* = .nil;
    return n;
}

pub fn newThread(g: *Global) Allocator.Error!*Thread {
    try g.gcs.threads.ensureUnusedCapacity(g.gpa, 1);
    const l = try gc.allocUninit(g, Thread, .thread, @sizeOf(Thread));
    l.* = .{ .hdr = l.hdr, .g = g };
    if (g.debugger) |d| l.hook_mask = d.mask;
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
            @import("../jit/jit.zig").freeProto(g, p);
            object.Proto.freeCode(gpa, p.code);
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

pub fn traverseExtra(m: anytype, h: *gc.Header) void {
    switch (h.tag) {
        .proto => {
            const p = h.as(object.Proto);
            for (p.constants) |v| m.mark(v);
            for (p.protos) |q| m.markHeader(&q.hdr);
            for (p.upvals) |u| if (u.name) |s| m.markHeader(&s.hdr);
            for (p.locvars) |lv| m.markHeader(&lv.name.hdr);
            if (p.source) |s| m.markHeader(&s.hdr);
            if (p.name) |s| m.markHeader(&s.hdr);
            const jit = @import("../jit/jit.zig");
            if (jit.has_opt) jit.opt.traverse(m, p);
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
    return createSeeded(gpa, io, null);
}

/// Creates a state whose strings hash with `seed`, or with a seed of its
/// own when `seed` is null. Workers take the seed of their creator, so
/// the strings they exchange keep their hashes (`blob.zig`).
pub fn createSeeded(gpa: Allocator, io: std.Io, seed_opt: ?u64) !*Global {
    const g = try gpa.create(Global);
    var seed: u64 = 0x2545F4914F6CDD1D;
    seed ^= @intFromPtr(g);
    @import("shape.zig").prepare();
    g.* = .{ .gpa = gpa, .io = io, .seed = seed_opt orelse seed };
    g.parent_gpa = gpa;
    g.counter = .init(gpa);
    g.gpa = g.counter.allocator();
    errdefer destroy(g);
    g.gc_stopped = true; // no collection until the state is fully built
    g.memerr = try newStringKnown(g, "not enough memory", true, 17);
    try g.fixed.append(g.gpa, &g.memerr.hdr);
    for (tm_event_names, 0..) |name, i| {
        const s = try newStringKnown(g, name, true, name.len);
        g.tm_names[i] = s;
    }
    g.main_thread = try newThread(g);
    g.registry = Value.obj(.table, try newDictIn(g, 4));
    g.globals = Value.obj(.table, try newDictIn(g, 64));
    g.gc_stopped = false;
    return g;
}

/// The state whose counting allocator `gpa` is, or null for any other
/// allocator. Every allocation of a state goes through its counting
/// allocator, so table operations that make shapes find the state there.
pub fn stateOf(gpa: Allocator) ?*Global {
    const Counting = @import("heapcount.zig").Counting;
    if (gpa.vtable != &Counting.vtable) return null;
    const c: *Counting = @ptrCast(@alignCast(gpa.ptr));
    return @alignCast(@fieldParentPtr("counter", c));
}

/// Keeps `key`, which a new shape holds, alive for as long as the state
/// lives.
pub fn pinKey(g: *Global, key: *String) Allocator.Error!void {
    try g.fixed.append(g.gpa, &key.hdr);
}

pub fn destroy(g: *Global) void {
    const gpa = g.gpa;
    const sched = @import("sched.zig");
    sched.release(g);
    gc.freeAll(g);
    sched.deinit(g);
    @import("../jit/jit.zig").deinit(g);
    g.strings.deinit(gpa);
    g.blobs.deinit(gpa);
    g.fixed.deinit(gpa);
    g.finobj.deinit(gpa);
    g.tobefnz.deinit(gpa);
    g.ext.deinit(gpa);
    g.shapes.deinit(g.gpa);
    g.parent_gpa.destroy(g);
}

test "a state that fails to build frees what it allocated" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn build(gpa: Allocator) !void {
            destroy(try create(gpa, std.testing.io));
        }
    }.build, .{});
}
