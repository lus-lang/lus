//! Garbage collector. A precise, non-moving mark and sweep over the page
//! heap of `heap.zig`, with full weak table, ephemeron, and finalizer
//! semantics. Marking sets a bit in the mark bitmap of the page of an
//! object (or in the header of a large object). Sweeping is lazy: the
//! allocator sweeps a page when it reaches it, and collector steps sweep
//! the pages that the allocator does not reach. Allocation and barrier
//! entry points are the ones the incremental and generational modes use,
//! so the interpreter never has to change when the collector does.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const state_mod = @import("state.zig");
const heap = @import("heap.zig");
const Value = value.Value;
const Tag = value.Tag;
const Global = state_mod.Global;
const Thread = state_mod.Thread;
const Allocator = std.mem.Allocator;

pub const Header = struct {
    /// Every object starts with its header, and a header pointer converts
    /// to the object pointer. Struct layout places the most aligned fields
    /// first, so the header takes the largest alignment of any object
    /// field. On 64-bit targets pointers already have it. On 32-bit
    /// targets (wasm32) 16-byte alignment puts the header ahead of the
    /// 8-byte values and integers, and it keeps the values that trail a
    /// native or a userdata aligned.
    tag: Tag align(if (@sizeOf(usize) == 8) 8 else 16),
    flags: Flags = .{},
    /// Set on objects that wait for (or already ran) their finalizer.
    finalize: Finalize = .none,

    pub const Flags = packed struct(u8) {
        /// Set while the object is black: marked and traced in the
        /// current collection. A store into an object with the bit set
        /// takes the slow path of the write barrier.
        barrier: bool = false,
        /// Set on free cells of a page.
        free: bool = false,
        /// Set on objects allocated outside the pages.
        large: bool = false,
        /// The mark bit of a large object. Small objects keep theirs in
        /// the bitmap of their page.
        mark: bool = false,
        _pad: u4 = 0,
    };

    pub const Finalize = enum(u8) { none, pending, done };

    pub inline fn as(h: *Header, comptime T: type) *T {
        return @ptrCast(@alignCast(h));
    }
};

/// Objects that hold no references live in leaf pages.
fn kindOf(comptime tag: Tag) heap.Kind {
    return switch (tag) {
        .string, .bigint, .decimal, .vector => .leaf,
        else => .scan,
    };
}

inline fn allocMem(g: *Global, comptime tag: Tag, size: usize) Allocator.Error![*]u8 {
    if (size <= heap.max_small) return heap.allocSmall(g, comptime kindOf(tag), size);
    return heap.allocLarge(g, size);
}

/// Allocates a zeroed object of type `T` with `size` bytes in total. The
/// caller initializes the fields.
pub inline fn alloc(g: *Global, comptime T: type, comptime tag: Tag, size: usize) Allocator.Error!*T {
    const mem = try allocMem(g, tag, size);
    @memset(mem[0..size], 0);
    return initHeader(T, tag, mem, size);
}

/// Allocates an object without clearing it, for callers that initialize
/// every field before anything else can observe the object.
pub inline fn allocUninit(g: *Global, comptime T: type, comptime tag: Tag, size: usize) Allocator.Error!*T {
    return initHeader(T, tag, try allocMem(g, tag, size), size);
}

inline fn initHeader(comptime T: type, comptime tag: Tag, mem: [*]u8, size: usize) *T {
    comptime std.debug.assert(@offsetOf(T, "hdr") == 0);
    const obj: *T = @ptrCast(@alignCast(mem));
    obj.hdr = .{ .tag = tag, .flags = .{ .large = size > heap.max_small } };
    return obj;
}

pub fn objectSize(h: *Header) usize {
    return switch (h.tag) {
        .string => object.String.allocSize(h.as(object.String).len),
        .table => @sizeOf(object.Table),
        .closure => object.Closure.allocSize(h.as(object.Closure).nupvals),
        .native => state_mod.Native.allocSize(h.as(state_mod.Native).nupvals),
        .userdata => object.Userdata.allocSize(h.as(object.Userdata).size, h.as(object.Userdata).nuser),
        .thread => @sizeOf(Thread),
        .vector => @sizeOf(object.Vector),
        .enum_root => @sizeOf(object.EnumRoot),
        .enum_value => @sizeOf(object.EnumValue),
        else => state_mod.extraObjectSize(h),
    };
}

/// Releases what a dead object owns outside its cell. The cell itself
/// goes back to its page, or the large object to the backing allocator.
pub fn releaseObject(g: *Global, h: *Header) void {
    const gpa = g.gpa;
    switch (h.tag) {
        .string => {
            const s = h.as(object.String);
            if (s.flags.interned) g.strings.remove(s);
            s.freeExtra(gpa);
        },
        .table => {
            const t = h.as(object.Table);
            if (t.array.len > 0) gpa.free(t.array);
            if (t.hash.len > 0) gpa.free(t.hash);
        },
        .thread => {
            @import("pledge.zig").release(h.as(Thread));
            h.as(Thread).deinitStack();
        },
        .vector => h.as(object.Vector).bytes.deinit(gpa),
        .enum_root => {
            const r = h.as(object.EnumRoot);
            gpa.free(r.names);
            gpa.free(r.values);
        },
        else => state_mod.freeExtra(g, h),
    }
}

pub inline fn isMarked(h: *const Header) bool {
    if (h.flags.large) return h.flags.mark;
    return heap.isMarkedSmall(h);
}

/// Sets the mark of an object and returns true when it was clear.
inline fn setMark(h: *Header) bool {
    if (h.flags.large) {
        if (h.flags.mark) return false;
        h.flags.mark = true;
        return true;
    }
    return heap.setMarkSmall(h);
}

/// Called when the string table hands out an existing string. A string
/// that the last collection found dead stays in the table until its page
/// is swept, so finding it again revives it.
pub inline fn touchInterned(g: *Global, s: *object.String) void {
    if (g.gcs.phase == .sweep) reviveInterned(s);
}

fn reviveInterned(s: *object.String) void {
    if (heap.pageOf(&s.hdr).needs_sweep) _ = setMark(&s.hdr);
}

// ---------------------------------------------------------------------
// Barriers. Called on every store of a collectable value into a heap
// object. The stop-the-world collector never overlaps the mutator, so the
// slow path only clears the bit.

pub inline fn barrierBack(g: *Global, h: *Header) void {
    if (h.flags.barrier) barrierSlow(g, h);
}

fn barrierSlow(g: *Global, h: *Header) void {
    _ = g;
    h.flags.barrier = false;
}

// ---------------------------------------------------------------------
// Collector state

pub const Phase = enum(u8) {
    /// No collection is in progress.
    pause,
    /// Marking finished and pages wait for their sweep.
    sweep,
};

pub const State = struct {
    phase: Phase = .pause,
    gray: std.ArrayList(*Header) = .empty,
    weak: std.ArrayList(*object.Table) = .empty,
    ephemerons: std.ArrayList(*object.Table) = .empty,
    /// Every thread, so that dead threads close their upvalues before
    /// their stacks go away.
    threads: std.ArrayList(*Thread) = .empty,
    /// The heap size at which the next collection work happens.
    next_check: usize = 1 << 20,
    stepsize: usize = 200 * @sizeOf(object.Table),

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.gray.deinit(gpa);
        s.weak.deinit(gpa);
        s.ephemerons.deinit(gpa);
        s.threads.deinit(gpa);
    }
};

/// Registers a new thread. The caller reserves room in the list first.
pub fn addThread(g: *Global, l: *Thread) void {
    g.gcs.threads.appendAssumeCapacity(l);
}

// ---------------------------------------------------------------------
// Collection

const stress = @import("build_options").gc_stress;

pub inline fn maybeCollect(g: *Global) void {
    if (stress != 0) return stressPoint(g);
    if (g.counter.bytes >= g.gcs.next_check) collectSlow(g);
}

fn stressPoint(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.stress_tick +%= 1;
    if (g.stress_tick % stress == 0) return fullCollect(g);
    if (g.counter.bytes >= g.gcs.next_check) collectSlow(g);
}

fn collectSlow(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    switch (g.gcs.phase) {
        .pause => {
            if (g.counter.bytes >= g.threshold) {
                collect(g);
                sweepStep(g);
            } else g.gcs.next_check = g.threshold;
        },
        .sweep => sweepStep(g),
    }
}

/// Sweeps a share of the pages that wait for their sweep.
fn sweepStep(g: *Global) void {
    const s = &g.gcs;
    if (heap.sweepSome(g, 4 * s.stepsize) and sweepLarge(g, std.math.maxInt(usize))) {
        finishSweep(g);
    } else {
        s.next_check = g.counter.bytes + s.stepsize;
    }
}

fn sweepLarge(g: *Global, budget: usize) bool {
    _ = budget;
    const h = &g.heap;
    for (h.large_sweep.items) |o| {
        if (isMarked(o)) {
            h.large.append(g.gpa, o) catch {
                // Keeping the object in the sweep list keeps it alive.
                continue;
            };
        } else {
            releaseObject(g, o);
            heap.freeLarge(g, o);
        }
    }
    h.large_sweep.clearRetainingCapacity();
    return true;
}

fn finishSweep(g: *Global) void {
    const s = &g.gcs;
    heap.releaseSegments(g);
    s.phase = .pause;
    // The product is formed in 64 bits, since it overflows a 32-bit
    // usize once the heap passes a few dozen megabytes.
    const next = (@as(u64, g.counter.bytes) *| g.pause) / 100;
    g.threshold = @intCast(@max(@min(next, std.math.maxInt(usize)), 256 * 1024));
    s.next_check = g.threshold;
}

/// Completes the sweep of the previous collection.
fn completeSweep(g: *Global) void {
    if (g.gcs.phase != .sweep) return;
    _ = heap.sweepSome(g, std.math.maxInt(usize));
    _ = sweepLarge(g, std.math.maxInt(usize));
    finishSweep(g);
}

/// Runs a complete collection, including its sweep.
pub fn fullCollect(g: *Global) void {
    if (g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    collect(g);
    completeSweep(g);
}

/// Marks the heap and leaves the sweep pending.
fn collect(g: *Global) void {
    completeSweep(g);
    heap.clearMarks(g);
    var m = Marker{ .g = g };
    m.markRoots();
    m.drain();
    m.convergeEphemerons();
    // Separate unreachable objects with finalizers and resurrect them for
    // one more cycle, so their finalizers see valid objects.
    m.separateFinalizable();
    m.drain();
    m.convergeEphemerons();
    m.clearWeak();
    closeDeadThreads(g);
    const h = &g.heap;
    heap.startSweep(g, true);
    h.large_sweep.appendSlice(g.gpa, h.large.items) catch {};
    h.large_sweep.appendSlice(g.gpa, h.large_young.items) catch {};
    if (h.large_sweep.items.len == h.large.items.len + h.large_young.items.len) {
        h.large.clearRetainingCapacity();
        h.large_young.clearRetainingCapacity();
    } else {
        // Out of memory: every large object survives this collection.
        h.large_sweep.clearRetainingCapacity();
        h.large.appendSlice(g.gpa, h.large_young.items) catch {};
        h.large_young.clearRetainingCapacity();
    }
    g.gcs.weak.clearRetainingCapacity();
    g.gcs.ephemerons.clearRetainingCapacity();
    g.gcs.phase = .sweep;
    g.cycles += 1;
}

/// Dead threads close their open upvalues before anything is freed, so
/// closures that survive keep the captured values instead of pointing
/// into a freed stack.
fn closeDeadThreads(g: *Global) void {
    const list = &g.gcs.threads;
    var keep: usize = 0;
    for (list.items) |t| {
        if (isMarked(&t.hdr)) {
            list.items[keep] = t;
            keep += 1;
        } else {
            @import("interp.zig").closeUpvals(t, 0);
        }
    }
    list.items.len = keep;
}

const Marker = struct {
    g: *Global,

    fn markValue(m: *Marker, v: Value) void {
        if (v.tag.isCollectable()) m.markObject(v.header());
    }

    fn markObject(m: *Marker, h: *Header) void {
        if (!setMark(h)) return;
        switch (h.tag) {
            // Leaf objects have no references to trace.
            .string, .bigint, .decimal, .vector => {},
            else => m.g.gcs.gray.append(m.g.gpa, h) catch m.traverse(h),
        }
    }

    fn markRoots(m: *Marker) void {
        const g = m.g;
        m.markObject(&g.main_thread.hdr);
        m.markValue(g.registry);
        m.markValue(g.globals);
        for (g.type_metatables) |mt| if (mt) |t| m.markObject(&t.hdr);
        for (g.tm_names) |s| if (s) |p| m.markObject(&p.hdr);
        for (g.fixed.items) |h| m.markObject(h);
        // Objects waiting in the finalizer queue stay alive.
        for (g.tobefnz.items) |h| m.markObject(h);
    }

    fn drain(m: *Marker) void {
        while (m.g.gcs.gray.pop()) |h| m.traverse(h);
    }

    fn traverse(m: *Marker, h: *Header) void {
        switch (h.tag) {
            .table => m.traverseTable(h.as(object.Table)),
            .closure => {
                const c = h.as(object.Closure);
                m.markObject(&c.proto.hdr);
                for (c.upvals()) |u| m.markObject(&u.hdr);
            },
            .native => {
                const n = h.as(state_mod.Native);
                if (n.name) |s| m.markObject(&s.hdr);
                for (n.upvalues()) |v| m.markValue(v);
            },
            .userdata => {
                const u = h.as(object.Userdata);
                if (u.metatable) |mt| m.markObject(&mt.hdr);
                for (u.userValues()) |v| m.markValue(v);
            },
            .thread => h.as(Thread).traverse(m),
            .enum_root => {
                const r = h.as(object.EnumRoot);
                for (r.names) |s| m.markObject(&s.hdr);
                for (r.values) |ev| if (ev) |e| m.markObject(&e.hdr);
            },
            .enum_value => m.markObject(&h.as(object.EnumValue).root.hdr),
            else => state_mod.traverseExtra(m, h),
        }
    }

    pub fn mark(m: *Marker, v: Value) void {
        m.markValue(v);
    }
    pub fn markHeader(m: *Marker, h: *Header) void {
        m.markObject(h);
    }

    fn traverseTable(m: *Marker, t: *object.Table) void {
        const gpa = m.g.gpa;
        if (t.metatable) |mt| m.markObject(&mt.hdr);
        t.weak_mode = weakModeOf(m.g, t);
        switch (t.weak_mode) {
            .none => {
                for (t.array) |v| m.markValue(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markValue(n.key);
                    m.markValue(n.val);
                }
            },
            .values => {
                // Keys are strong, values are weak.
                for (t.array) |v| m.markIfValueLike(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markValue(n.key);
                    m.markIfValueLike(n.val);
                }
                m.g.gcs.weak.append(gpa, t) catch {};
            },
            .keys => {
                // Ephemeron: a value is reachable only through its key.
                for (t.array) |v| m.markValue(v);
                for (t.hash) |n| {
                    if (!n.val.isNil()) m.markIfValueLike(n.key);
                }
                m.g.gcs.ephemerons.append(gpa, t) catch {};
                m.g.gcs.weak.append(gpa, t) catch {};
            },
            .both => {
                for (t.array) |v| m.markIfValueLike(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markIfValueLike(n.key);
                    m.markIfValueLike(n.val);
                }
                m.g.gcs.weak.append(gpa, t) catch {};
            },
        }
    }

    /// Strings and arbitrary-precision numbers are values, not objects,
    /// for weak tables: they are never cleared, so they must stay alive.
    fn markIfValueLike(m: *Marker, v: Value) void {
        if (isValueLike(v)) m.markValue(v);
    }

    fn convergeEphemerons(m: *Marker) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (m.g.gcs.ephemerons.items) |t| {
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    if (isMarkedOrNotCollectable(n.key) and n.val.tag.isCollectable() and !isMarked(n.val.header())) {
                        m.markValue(n.val);
                        changed = true;
                    }
                }
            }
            if (changed) m.drain();
        }
    }

    /// Moves unreachable objects with finalizers to the finalizer queue,
    /// keeping registration order. The queue runs from its end, so the
    /// most recently registered object is finalized first.
    fn separateFinalizable(m: *Marker) void {
        const g = m.g;
        var keep: usize = 0;
        for (g.finobj.items) |h| {
            if (!isMarked(h)) {
                g.tobefnz.append(g.gpa, h) catch {};
                m.markObject(h);
            } else {
                g.finobj.items[keep] = h;
                keep += 1;
            }
        }
        g.finobj.items.len = keep;
    }

    fn clearWeak(m: *Marker) void {
        for (m.g.gcs.weak.items) |t| {
            if (t.weak_mode == .values or t.weak_mode == .both) {
                for (t.array) |*v| {
                    if (!isMarkedOrNotCollectable(v.*) or isFinalizedObject(v.*)) v.* = .nil;
                }
            }
            for (t.hash) |*n| {
                if (n.val.isNil()) continue;
                const key_dead = (t.weak_mode == .keys or t.weak_mode == .both) and !isMarkedOrNotCollectable(n.key);
                const val_dead = (t.weak_mode == .values or t.weak_mode == .both) and (!isMarkedOrNotCollectable(n.val) or isFinalizedObject(n.val));
                if (key_dead or val_dead) n.val = .nil;
            }
        }
    }
};

pub const MarkerApi = Marker;

fn isMarkedOrNotCollectable(v: Value) bool {
    if (!v.tag.isCollectable()) return true;
    // Strings are values for weak table purposes and never collected from
    // weak tables, as in Lua.
    if (isValueLike(v)) return true;
    return isMarked(v.header());
}

fn isValueLike(v: Value) bool {
    return v.tag == .string or v.tag == .bigint or v.tag == .decimal;
}

fn isFinalizedObject(v: Value) bool {
    return v.tag.isCollectable() and v.header().finalize == .pending;
}

fn weakModeOf(g: *Global, t: *object.Table) object.Table.WeakMode {
    const mt = t.metatable orelse return .none;
    const mode = state_mod.rawGetStr(mt, g.tm_names[@backingInt(state_mod.TM.mode)].?) orelse return .none;
    if (mode.tag != .string) return .none;
    const b = mode.as(object.String).bytes();
    const k = std.mem.indexOfScalar(u8, b, 'k') != null;
    const v = std.mem.indexOfScalar(u8, b, 'v') != null;
    if (k and v) return .both;
    if (k) return .keys;
    if (v) return .values;
    return .none;
}

/// Frees every object. Used when a state closes.
pub fn freeAll(g: *Global) void {
    heap.freeAll(g);
    g.gcs.deinit(g.gpa);
}

// ---------------------------------------------------------------------
// Tuning parameters

/// The collector parameters that `collectgarbage("param", name)` names.
pub const Param = enum { minormul, majorminor, minormajor, pause, stepmul, stepsize };

/// Returns the value of a parameter, as a percentage or a byte count.
/// The stop-the-world stage is tuned by `pause` alone. The incremental
/// and generational parameters report fixed default values, because this
/// stage has no steps or generations for them to tune.
pub fn getParam(g: *const Global, p: Param) i64 {
    return switch (p) {
        .pause => @intCast(g.pause),
        .minormul => 20,
        .majorminor => 50,
        .minormajor => 70,
        .stepmul => 200,
        .stepsize => 200 * @sizeOf(object.Table),
    };
}

/// Sets a parameter when `v` is non-negative and returns its previous
/// value. Only `pause` is stored by the current stage.
pub fn setParam(g: *Global, p: Param, v: i64) i64 {
    const old = getParam(g, p);
    if (v >= 0 and p == .pause) g.pause = std.math.cast(usize, v) orelse std.math.maxInt(usize);
    return old;
}
