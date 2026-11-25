//! Garbage collector. A precise, non-moving mark and sweep over the page
//! heap of `heap.zig`, with full weak table, ephemeron, and finalizer
//! semantics. Marking sets a bit in the mark bitmap of the page of an
//! object (or in the header of a large object). Sweeping is lazy: the
//! allocator sweeps a page when it reaches it, and collector steps sweep
//! the pages that the allocator does not reach. Incremental mode
//! interleaves tri-color marking with the program under a goal-based
//! pacer. Generational mode keeps marks between collections, so marked
//! objects are old and minor collections trace only young ones. The
//! design is described in `spec/design/gc.md`.

const std = @import("std");
const inv = @import("inv.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const state_mod = @import("state.zig");
const heap = @import("heap.zig");
const table = @import("table.zig");
const gcpar = @import("gcpar.zig");
const Value = value.Value;
const Tag = value.Tag;
const Global = state_mod.Global;
const Thread = state_mod.Thread;
const Allocator = std.mem.Allocator;

pub const Header = extern struct {
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
    /// Bytes that the alignment of the header leaves over, which an
    /// object type may use. The struct is extern, so these fields fill
    /// the bytes after the tag in this order. Tables keep their read-only flag and the hint
    /// of their length here (`object.Table`).
    spare8: u8 = 0,
    spare32: u32 = 0,

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
        .string => h.as(object.String).cellSize(),
        .table => @sizeOf(object.Table) + @as(usize, h.as(object.Table).cell.inline_units) * object.Table.inline_unit,
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

/// True when a dead object owns something outside its cell, which
/// `releaseObject` must release, or is a string in the string table. A
/// sweep tests it inline, since most dead objects own nothing: a table
/// whose parts live in its cell, or a string that is not interned.
pub inline fn needsRelease(h: *Header) bool {
    switch (h.tag) {
        .table => {
            const t = h.as(object.Table);
            if (t.asize > 0 and !t.ownsInline(t.array_ptr)) return true;
            if (t.isShaped()) return t.slotCap() > 0 and !t.ownsInline(t.hash_ptr);
            return t.hash_len > 0 and !t.ownsInline(t.hash_ptr);
        },
        .string => {
            const f = h.as(object.String).flags().*;
            return f.interned or f.shared or f.cached or f.crumb_slot;
        },
        else => return true,
    }
}

/// Releases what a dead object owns outside its cell. The cell itself
/// goes back to its page, or the large object to the backing allocator.
pub fn releaseObject(g: *Global, h: *Header) void {
    const gpa = g.gpa;
    switch (h.tag) {
        .string => {
            const s = h.as(object.String);
            if (s.flags().interned) g.strings.remove(s);
            if (s.flags().shared or s.flags().cached) @import("blob.zig").drop(g, s);
            s.freeExtra(gpa);
        },
        .table => {
            @import("table.zig").freeParts(gpa, h.as(object.Table));
        },
        .thread => {
            @import("sched.zig").threadFreed(g, h.as(Thread));
            @import("pledge.zig").release(h.as(Thread));
            @import("context.zig").release(h.as(Thread));
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
// object, after the store. The fast path is a single test of the barrier
// bit, which only black objects carry. During a mark phase the barrier is
// backward: a store into a black object turns the object gray again, and
// the collector traces it once more before the mark phase ends. In
// generational mode, marked objects are old, and the same bit logs the
// first store into an old object since the last collection, so that the
// next minor collection traces it.

pub inline fn barrierBack(g: *Global, h: *Header) void {
    if (h.flags.barrier) barrierSlow(g, h);
}

/// The barrier for a store of `key` and `val` into a table. A large table
/// stays black and the stored values turn gray instead, so filling a big
/// table during a mark phase never traces it again. Smaller tables, and
/// weak tables, whose entries must not be marked through them, use the
/// backward barrier.
pub inline fn barrierTable(g: *Global, t: *object.Table, key: Value, val: Value) void {
    if (t.hdr.flags.barrier) barrierTableSlow(g, t, key, val);
}

/// Tables with at least this many slots use the forward barrier.
const big_table = 1024;

fn barrierTableSlow(g: *Global, t: *object.Table, key: Value, val: Value) void {
    const s = &g.gcs;
    if (t.weakMode() == .none and @as(usize, t.asize) + t.hash_len >= big_table and isMarked(&t.hdr)) {
        if (s.phase == .propagate) {
            markGray(g, key);
            markGray(g, val);
            return;
        }
        // An old table in generational mode promotes what it receives,
        // and the next minor collection traces the promoted objects.
        if (s.mode == .generational) {
            promote(g, key);
            promote(g, val);
            return;
        }
    }
    barrierSlow(g, &t.hdr);
}

/// Marks a young value as old and logs it, since its children may be
/// young.
fn promote(g: *Global, v: Value) void {
    if (!v.tag.isCollectable()) return;
    const h = v.header();
    if (!setMark(h) or isLeaf(h.tag)) return;
    pushGray(g, &g.gcs.grayagain, h);
}

/// Appends `h` to a gray list, without a call while the list has room.
inline fn pushGray(g: *Global, list: *GrayList, h: *Header) void {
    if (list.items.len < list.capacity) return list.appendAssumeCapacity(h);
    list.append(gcpar.stack_alloc, h) catch {
        g.gcs.overflow = true;
    };
}

/// Marks a value outside a marker and queues it for tracing.
fn markGray(g: *Global, v: Value) void {
    if (!v.tag.isCollectable()) return;
    const h = v.header();
    if (!setMark(h) or isLeaf(h.tag)) return;
    pushGray(g, &g.gcs.gray, h);
}

fn barrierSlow(g: *Global, h: *Header) void {
    h.flags.barrier = false;
    const s = &g.gcs;
    if (s.phase != .propagate and s.mode != .generational) return;
    if (!isMarked(h)) return;
    // When the list cannot grow, the end of the mark phase traces every
    // marked object again instead.
    s.grayagain.append(gcpar.stack_alloc, h) catch {
        s.overflow = true;
    };
}

// ---------------------------------------------------------------------
// Collector state

pub const Phase = enum(u8) {
    /// No collection is in progress.
    pause,
    /// Marking: gray objects wait to be traced, interleaved with the
    /// program.
    propagate,
    /// Marking finished and pages wait for their sweep.
    sweep,
};

pub const Mode = enum(u8) { incremental, generational };

pub const State = struct {
    phase: Phase = .pause,
    mode: Mode = .generational,
    /// In generational mode: the next collection is a major one, run as
    /// an incremental cycle.
    major_pending: bool = false,
    /// Set when the last mark phase belonged to a major collection.
    last_major: bool = true,
    /// The heap size after the last major collection.
    gen_base: usize = 0,
    /// The heap size when the last mark phase ended.
    heap_at_mark: usize = 0,
    /// Objects marked but not traced yet.
    gray: GrayList = .empty,
    /// Black objects that a store turned gray again. In generational mode
    /// between collections, the old objects stored into since the last
    /// collection (the remembered set).
    grayagain: GrayList = .empty,
    weak: std.ArrayList(*object.Table) = .empty,
    /// Every weak table that the last mark phase found alive. A minor
    /// collection traces the old ones again to clear their young entries.
    all_weak: std.ArrayList(*object.Table) = .empty,
    ephemerons: std.ArrayList(*object.Table) = .empty,
    /// Every thread, so that the atomic phase rescans the stacks and dead
    /// threads close their upvalues before their stacks go away.
    threads: std.ArrayList(*Thread) = .empty,
    /// Set while the gray stack holds what was the gray-again list, which
    /// may name an object twice. A parallel drain would then trace it on
    /// two threads at once, so the stack drains on one thread until it
    /// runs empty.
    gray_repeats: bool = false,
    /// Set when the barrier could not record an object. The atomic phase
    /// then traces every marked object again.
    overflow: bool = false,
    /// Rounds of gray-again tracing done before the atomic phase.
    again_rounds: u8 = 0,
    /// The heap size at which the next collector step runs.
    next_check: usize = 1 << 20,
    /// Bytes traced in the current cycle.
    marked: usize = 0,
    /// Bytes the current cycle expects to trace.
    estimate: usize = 0,
    /// The heap size at which marking should be finished.
    goal: usize = 0,
    /// The bytes that survived the last collection: the heap size when
    /// its mark phase ended, less what its sweep freed.
    live: usize = 0,
    /// Bytes the sweep of the current cycle freed.
    swept: usize = 0,
    /// Set when the last major collection freed less than a sixteenth of
    /// what the program allocated since the collection before it. The
    /// heap is then growing, and the next cycle waits for twice the
    /// usual growth.
    growing: bool = false,
    /// Minor collections since the last major one.
    minors: u32 = 0,
    /// Set when the last minor collection freed less than `majorminor`
    /// percent of what the program allocated before it.
    poor_minor: bool = false,
    /// Major collections still to run without minor collections between
    /// them, and how many the next failed try of minor collections skips.
    skip_minors: u8 = 0,
    backoff: u8 = 0,
    /// Set when minor collections failed right after a major one, until
    /// the major collection that they asked for ends.
    minors_failed: bool = false,
    /// Minor collections in a row, after two that freed little, that
    /// freed little too. Each of them doubles the allocation before the
    /// next one (`probeMinor`).
    probes: u8 = 0,
    stepmul: usize = 200,
    stepsize: usize = 200 * @sizeOf(object.Table),
    minormul: usize = 20,
    minormajor: usize = 70,
    majorminor: usize = 50,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.gray.deinit(gcpar.stack_alloc);
        s.grayagain.deinit(gcpar.stack_alloc);
        s.weak.deinit(gpa);
        s.all_weak.deinit(gpa);
        s.ephemerons.deinit(gpa);
        s.threads.deinit(gpa);
    }
};

/// Registers a new thread. The caller reserves room in the list first.
pub fn addThread(g: *Global, l: *Thread) void {
    g.gcs.threads.appendAssumeCapacity(l);
}

// ---------------------------------------------------------------------
// Pacing
//
// The collector targets a heap size relative to the live data. When a
// cycle ends, the heap holds about `live` bytes, and the next mark phase
// should end before the heap reaches `live * pause / 100`. Marking traces
// about `live` bytes, and every step traces `stepmul / 100` bytes per
// allocated byte, so the cycle starts early enough to finish in time.
// During marking, each step compares the work left with the room left
// before the goal and raises its budget when marking falls behind.

/// Bytes of work in a basic step.
fn baseBudget(s: *const State) usize {
    return @max(s.stepsize *| s.stepmul / 100, 1024);
}

/// The largest step, which bounds the pause of a step that catches up.
fn maxBudget(s: *const State) usize {
    return baseBudget(s) *| 64;
}

fn markBudget(g: *Global) usize {
    const s = &g.gcs;
    const base = baseBudget(s);
    const need = @max(s.estimate -| s.marked, base);
    const runway = s.goal -| g.counter.bytes;
    if (runway <= s.stepsize) return @min(need, maxBudget(s));
    const want: u64 = @as(u64, need) * s.stepsize / runway;
    return @intCast(@min(@max(want, base), maxBudget(s)));
}

fn setThreshold(g: *Global) void {
    setThresholdFrom(g, g.gcs.live);
}

/// Sets the threshold and goal of the next major collection for `live`
/// bytes of live data.
fn setThresholdFrom(g: *Global, live: usize) void {
    const s = &g.gcs;
    // The products are formed in 64 bits, since they overflow a 32-bit
    // usize once the heap passes a few dozen megabytes.
    const pause: u64 = if (s.growing) @as(u64, g.pause) * 2 else g.pause;
    const goal: u64 = @as(u64, live) * pause / 100;
    // An incremental cycle starts early enough to finish marking before
    // the goal. A major collection in generational mode marks in one
    // stop, so it starts at the goal.
    const during: u64 = if (s.mode == .generational) 0 else @as(u64, live) * 100 / @max(s.stepmul, 1);
    const start = @max(goal -| during, @as(u64, live) + s.stepsize);
    const t: u64 = @max(start, 256 * 1024, @as(u64, g.counter.bytes) + s.stepsize);
    g.threshold = @intCast(@min(t, std.math.maxInt(usize)));
    s.goal = @intCast(@min(@max(goal, t + s.stepsize), std.math.maxInt(usize)));
    s.next_check = g.threshold;
}

// ---------------------------------------------------------------------
// Collection

pub const stress = @import("build_options").gc_stress;
const verify = @import("build_options").gc_verify;

pub inline fn maybeCollect(g: *Global) void {
    if (stress != 0) return stressPoint(g);
    if (g.counter.bytes >= g.gcs.next_check) collectSlow(g);
}

/// True when the next collection is a minor one.
inline fn minorNext(s: *const State) bool {
    return s.mode == .generational and !s.major_pending;
}

/// The stress build runs a small step at every allocation point, so
/// marking always overlaps the program, and finishes a mark phase (or
/// runs a minor collection) at every Nth point.
fn stressPoint(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    const s = &g.gcs;
    g.stress_tick +%= 1;
    if (s.mode == .generational and g.stress_tick % (stress *% 8) == 0) return collectFull(g);
    if (g.stress_tick % stress == 0) {
        switch (s.phase) {
            .pause => if (minorNext(s)) minorCollect(g) else {
                startCycle(g);
                finishMarking(g);
            },
            .propagate => finishMarking(g),
            .sweep => completeSweep(g),
        }
        return;
    }
    if (s.phase == .pause and minorNext(s)) return;
    _ = step(g, 512, true);
}

fn collectSlow(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    _ = step(g, 0, false);
}

/// Runs one collector step with `budget` bytes of work, or a paced budget
/// when it is zero. A step in the pause phase starts a collection when the
/// heap reached the threshold, or always when `force` is set. Returns
/// true when the step finished a cycle.
fn step(g: *Global, budget: usize, force: bool) bool {
    const s = &g.gcs;
    switch (s.phase) {
        .pause => {
            if (!force and g.counter.bytes < g.threshold) {
                s.next_check = g.threshold;
                return false;
            }
            if (minorNext(s)) {
                minorCollect(g);
                return false;
            }
            startCycle(g);
            // A major collection in generational mode marks to its end at
            // once, on several threads. Marked as it goes over many steps,
            // it keeps every old object that died during its mark phase,
            // and that floating garbage counts as live: the next major
            // collection then waits for a heap twice as large.
            if (s.mode == .generational) {
                finishMarking(g);
                return false;
            }
            propagate(g, if (budget != 0) budget else markBudget(g));
            return false;
        },
        .propagate => {
            propagate(g, if (budget != 0) budget else markBudget(g));
            return false;
        },
        .sweep => return sweepStep(g, if (budget != 0) budget else 4 * baseBudget(s)),
    }
}

/// Starts the mark phase of a major collection, run incrementally. Every
/// object turns white.
fn startCycle(g: *Global) void {
    const s = &g.gcs;
    inv.assert(s.phase == .pause);
    heap.clearMarks(g);
    s.gray.clearRetainingCapacity();
    s.gray_repeats = false;
    s.grayagain.clearRetainingCapacity();
    s.weak.clearRetainingCapacity();
    s.ephemerons.clearRetainingCapacity();
    s.overflow = false;
    s.again_rounds = 0;
    s.marked = 0;
    s.estimate = if (s.live != 0) s.live else g.counter.bytes;
    if (s.goal <= g.counter.bytes) {
        const goal: u64 = @as(u64, @max(s.estimate, g.counter.bytes)) * @max(g.pause, 100) / 100;
        s.goal = @intCast(@min(goal + s.stepsize, std.math.maxInt(usize)));
    }
    s.phase = .propagate;
    var m = Marker.init(g);
    m.markRoots();
    s.marked += m.work;
}

/// Traces gray objects until `budget` bytes of work are done, and runs
/// the atomic phase when no gray object is left.
fn propagate(g: *Global, budget: usize) void {
    const s = &g.gcs;
    var m = Marker.init(g);
    // A mark phase that runs to its end, as in a full collection, may
    // drain on several threads.
    const whole = budget == std.math.maxInt(usize);
    while (m.work < budget) {
        if (whole) {
            m.drainGray();
        } else if (popGray(&s.gray)) |h| {
            m.visit(h);
            continue;
        }
        s.gray_repeats = false;
        // Objects that stores turned gray again are traced a couple of
        // times while the program runs, so the atomic phase finds few.
        // The atomic phase traces them at once when the mark phase runs
        // to its end.
        if (!whole and s.grayagain.items.len > 0 and s.again_rounds < 2) {
            s.again_rounds += 1;
            std.mem.swap(GrayList, &s.gray, &s.grayagain);
            s.gray_repeats = true;
            continue;
        }
        s.marked += m.work;
        m.work = 0;
        // The atomic phase: the mark phase ends without the program
        // running.
        m.markRoots();
        finishMark(g, &m, true);
        return;
    }
    s.marked += m.work;
    s.next_check = g.counter.bytes + s.stepsize;
}

/// Completes the mark phase of the current cycle.
fn finishMarking(g: *Global) void {
    while (g.gcs.phase == .propagate) propagate(g, std.math.maxInt(usize));
}

/// A minor collection in generational mode, run without interruption.
/// Old objects stay marked, so marking traces only the young objects that
/// the roots, the stacks, the remembered set, and the old weak tables
/// reach. The sweep then visits only pages that received objects since
/// the last collection.
fn minorCollect(g: *Global) void {
    const s = &g.gcs;
    completeSweep(g);
    inv.assert(s.phase == .pause);
    s.gray.clearRetainingCapacity();
    s.weak.clearRetainingCapacity();
    s.ephemerons.clearRetainingCapacity();
    var m = Marker.init(g);
    m.markRoots();
    // The remembered set: old objects stored into since the last
    // collection, and young objects promoted by large tables.
    while (s.grayagain.pop()) |h| m.traverse(@alignCast(h));
    // Old weak tables are traced again, so that their entries that
    // reference young objects are cleared or kept like in any table.
    for (s.all_weak.items) |t| {
        if (isMarked(&t.hdr)) m.traverse(&t.hdr);
    }
    finishMark(g, &m, false);
}

/// The end of every mark phase. Stacks change without barriers, so every
/// live thread is traced again, and a dead thread may still own open
/// upvalues that a live closure captured, so their current values are
/// marked. Then ephemerons converge, finalizable objects are separated,
/// weak tables are cleared, and the sweep starts.
fn finishMark(g: *Global, m: *Marker, major: bool) void {
    const s = &g.gcs;
    for (s.threads.items) |t| {
        if (isMarked(&t.hdr)) {
            m.traverse(&t.hdr);
        } else {
            var u = t.open_upvals;
            while (u) |up| : (u = up.next_open) {
                if (isMarked(&up.hdr)) m.markValue(up.loc.*);
            }
        }
    }
    m.drainAll();
    if (s.overflow) {
        s.overflow = false;
        retraceMarked(g, m);
        m.drainAll();
    }
    m.convergeEphemerons();
    // Separate unreachable objects with finalizers and resurrect them for
    // one more cycle, so their finalizers see valid objects.
    m.separateFinalizable();
    m.drainAll();
    m.convergeEphemerons();
    m.clearWeak();
    // The invariants of a checking build include the end of the mark
    // phase: a marked object references only marked objects.
    if (verify or @import("build_options").invariants) verifyHeap(g);
    if (inv.deep) inv.assert(heap.bytesOk(g));
    inv.assert(s.gray.items.len == 0 and s.grayagain.items.len == 0);
    // The gray stack holds an entry per reference while it drains, so a
    // heap with many references grows it far past what a later cycle
    // needs, and a large one is freed.
    if (s.gray.capacity > gray_keep) s.gray.clearAndFree(gcpar.stack_alloc);
    s.heap_at_mark = g.counter.bytes;
    s.swept = 0;
    s.last_major = major;
    rememberWeak(g);
    s.weak.clearRetainingCapacity();
    s.ephemerons.clearRetainingCapacity();
    s.phase = .sweep;
    closeDeadThreads(g);
    heap.startSweep(g, major);
    sweepLargeLater(g, major);
    s.next_check = g.counter.bytes + s.stepsize;
    g.cycles += 1;
}

/// Records the weak tables found alive, each once.
fn rememberWeak(g: *Global) void {
    const s = &g.gcs;
    s.all_weak.clearRetainingCapacity();
    s.all_weak.appendSlice(g.gpa, s.weak.items) catch {
        // Without the list, the next collection must be a major one.
        s.major_pending = true;
        return;
    };
    const items = s.all_weak.items;
    std.mem.sort(*object.Table, items, {}, struct {
        fn lt(_: void, a: *object.Table, b: *object.Table) bool {
            return @intFromPtr(a) < @intFromPtr(b);
        }
    }.lt);
    var n: usize = 0;
    for (items) |t| {
        if (n > 0 and items[n - 1] == t) continue;
        items[n] = t;
        n += 1;
    }
    s.all_weak.items.len = n;
}

/// Moves the large objects that the sweep examines into the sweep list:
/// all of them after a major collection, the young ones after a minor
/// one. The surviving ones return to `large`, so it keeps room for them.
fn sweepLargeLater(g: *Global, major: bool) void {
    const h = &g.heap;
    const old = if (major) h.large.items.len else 0;
    const total = old + h.large_young.items.len;
    h.large_sweep.ensureTotalCapacity(g.gpa, total) catch return keepLarge(g);
    h.large.ensureTotalCapacity(g.gpa, h.large.items.len - old + total) catch return keepLarge(g);
    if (major) {
        h.large_sweep.appendSliceAssumeCapacity(h.large.items);
        h.large.clearRetainingCapacity();
    }
    h.large_sweep.appendSliceAssumeCapacity(h.large_young.items);
    h.large_young.clearRetainingCapacity();
}

/// Out of memory before a sweep: every large object survives this cycle.
fn keepLarge(g: *Global) void {
    const h = &g.heap;
    h.large.appendSlice(g.gpa, h.large_young.items) catch return;
    h.large_young.clearRetainingCapacity();
}

/// Sweeps a share of the pages that wait for their sweep. Returns true
/// when the sweep, and with it the cycle, finished.
fn sweepStep(g: *Global, budget: usize) bool {
    const s = &g.gcs;
    if (heap.sweepSome(g, budget) and sweepLarge(g)) {
        finishSweep(g);
        return true;
    }
    s.next_check = g.counter.bytes + s.stepsize;
    return false;
}

fn sweepLarge(g: *Global) bool {
    const h = &g.heap;
    const before = g.counter.bytes;
    defer g.gcs.swept += before -| g.counter.bytes;
    for (h.large_sweep.items) |o| {
        if (isMarked(o)) {
            // The list has room, since every object in the sweep list
            // came from the other two lists.
            h.large.appendAssumeCapacity(o);
        } else {
            releaseObject(g, o);
            heap.freeLarge(g, o);
        }
    }
    h.large_sweep.clearRetainingCapacity();
    return true;
}

/// Ends a cycle and sets the heap size of the next collection.
fn finishSweep(g: *Global) void {
    const s = &g.gcs;
    heap.releaseSegments(g);
    g.strings.shrink(g.gpa);
    s.phase = .pause;
    const before = s.live;
    s.live = s.heap_at_mark -| s.swept;
    if (s.mode != .generational or s.last_major) {
        // The bytes allocated since the previous major collection. In
        // generational mode that collection left `gen_base` bytes, and
        // otherwise the previous cycle left `before`.
        const allocated = s.heap_at_mark -| (if (s.mode == .generational) s.gen_base else before);
        const freed = s.heap_at_mark -| s.live;
        s.growing = @as(u64, freed) * 16 < allocated;
    }
    if (s.mode != .generational) return setThreshold(g);
    const live = s.live;
    if (s.last_major) {
        // Generational mode pays off when a major collection frees a
        // good share of what the program allocated since the previous
        // one. Otherwise most new objects live long, and incremental
        // cycles serve better until a major collection frees enough
        // again. The first major collection only sets the base.
        const allocated = s.heap_at_mark -| s.gen_base;
        const freed = s.heap_at_mark -| live;
        s.major_pending = s.gen_base != 0 and @as(u64, freed) * 100 < @as(u64, allocated) * s.majorminor;
        // Minor collections that failed before a major collection that
        // freed a good share traced objects that die old, and the next
        // tries of minor collections wait longer. When the major
        // collection freed little, the program builds its data, and
        // minor collections remain the cheaper way to age it.
        if (s.minors_failed) {
            if (s.major_pending or s.gen_base == 0) {
                s.backoff = 0;
            } else {
                s.backoff = if (s.backoff == 0) 1 else @min(s.backoff * 2, 16);
                s.skip_minors = s.backoff;
            }
            s.minors_failed = false;
        }
        s.gen_base = live;
        s.minors = 0;
        s.poor_minor = false;
        s.probes = 0;
        // A program that built its data a moment ago may now discard
        // most of what it allocates. The minor collection that follows,
        // after the usual young allocation, tells the two apart much
        // sooner than the next major collection would. After minor
        // collections failed right after a major one, they wait for a
        // number of major collections that doubles with each failure.
        if (s.skip_minors > 0) {
            s.skip_minors -= 1;
            s.major_pending = true;
        } else s.major_pending = false;
    } else if (@as(u64, live) * 100 > @as(u64, s.gen_base) * (100 + s.minormajor)) {
        s.poor_minor = false;
        if (s.minors < 2) failedMinors(s);
        // The old generation grew too much since the last major
        // collection. That calls for a major collection even while minor
        // collections probe a program that builds its data, since the
        // growth already says what the probes would find.
        s.major_pending = true;
    } else if (poorMinor(s, live, before) and (s.poor_minor or s.probes > 0)) {
        // Two minor collections in a row that freed less than
        // `majorminor` percent of what the program allocated before each
        // of them traced young objects that live on: the program builds
        // its data. A single such minor collection may only have met a
        // large result that the program keeps, such as text it just
        // joined. The next minor collections wait for twice as much
        // allocation each time, so that they cost little while the
        // program builds, and still find the moment it starts to discard
        // what it allocates. One that still freed a quarter keeps the
        // wait it had. Past the goal of the next major collection, that
        // collection runs instead.
        s.poor_minor = false;
        if (s.probes == 0) failedMinors(s);
        if (s.probes == 0 or !freedQuarter(s, live, before)) s.probes +|= 1;
        s.minors += 1;
        if (probeMinor(g)) return;
        s.probes = 0;
        s.major_pending = true;
        return setThresholdFrom(g, s.gen_base);
    } else {
        s.poor_minor = poorMinor(s, live, before);
        if (!s.poor_minor) s.backoff = 0;
        s.probes = 0;
        // Old objects die only in major collections. A program sees
        // that through finalizers and weak tables, so while it has
        // either, a major collection runs after a bounded number of
        // minor ones even when the old generation stays the same size.
        s.minors += 1;
        if (s.minors >= max_minors and (g.finobj.items.len > 0 or s.all_weak.items.len > 0)) s.major_pending = true;
    }
    if (s.major_pending) {
        // A major collection that minor collections asked for runs at the
        // next step. The heap then holds old objects that died since the
        // last major collection, and a goal set from its size would let
        // that garbage double before anything collects it.
        if (!s.last_major) {
            g.threshold = g.counter.bytes + s.stepsize;
            s.next_check = g.threshold;
            return;
        }
        return setThreshold(g);
    }
    setMinorThreshold(g);
}

/// Records that minor collections that followed a major one asked for
/// the next major collection at once, or after two that freed little:
/// they traced young objects that live on. When that major collection
/// frees a good share, the next major collections run without minor
/// collections between them, twice as many as after the last failure,
/// up to sixteen.
fn failedMinors(s: *State) void {
    if (s.minors < 2) s.minors_failed = true;
}

/// True when the minor collection that just ended freed at least a
/// quarter of what the program allocated since the collection before it.
fn freedQuarter(s: *const State, live: usize, before: usize) bool {
    return @as(u64, s.heap_at_mark -| live) * 4 >= @as(u64, s.heap_at_mark -| before);
}

/// True when the minor collection that just ended freed less than
/// `majorminor` percent of what the program allocated since the
/// collection before it, which left `before` bytes.
fn poorMinor(s: *const State, live: usize, before: usize) bool {
    return @as(u64, s.heap_at_mark -| live) * 100 < @as(u64, s.heap_at_mark -| before) * s.majorminor;
}

/// The next minor collection runs after the program allocates
/// `minormul` percent of the heap that the last major collection left.
fn setMinorThreshold(g: *Global) void {
    const s = &g.gcs;
    const young: u64 = @max(@as(u64, s.gen_base) * s.minormul / 100, min_young);
    const t = @max(@as(u64, s.live) + young, @as(u64, g.counter.bytes) + s.stepsize);
    g.threshold = @intCast(@min(t, std.math.maxInt(usize)));
    s.next_check = g.threshold;
}

/// Sets the threshold of the minor collection after `probes` minor
/// collections that freed little: the usual young allocation, doubled
/// for each of them. Returns false when that threshold would pass the
/// goal of the next major collection.
fn probeMinor(g: *Global) bool {
    const s = &g.gcs;
    const pause: u64 = if (s.growing) @as(u64, g.pause) * 2 else g.pause;
    const goal: u64 = @as(u64, s.gen_base) * pause / 100;
    const young: u64 = @max(@as(u64, s.gen_base) * s.minormul / 100, min_young) << @intCast(@min(s.probes, 16));
    const t = @max(@as(u64, s.live) + young, @as(u64, g.counter.bytes) + s.stepsize);
    if (t >= goal) return false;
    g.threshold = @intCast(t);
    s.next_check = g.threshold;
    return true;
}

/// The most minor collections between two major ones.
const max_minors = 100;

/// The least allocation between two minor collections.
const min_young = 1024 * 1024;

/// Completes the sweep of the previous collection.
fn completeSweep(g: *Global) void {
    if (g.gcs.phase != .sweep) return;
    _ = heap.sweepSome(g, std.math.maxInt(usize));
    _ = sweepLarge(g);
    finishSweep(g);
}

/// Runs a complete collection, including its sweep.
pub fn fullCollect(g: *Global) void {
    if (g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    collectFull(g);
}

/// A full collection. A mark phase in progress is abandoned, since its
/// marks may be stale for objects that died since it started. In
/// generational mode, the survivors are the old generation and minor
/// collections follow.
fn collectFull(g: *Global) void {
    const s = &g.gcs;
    if (s.phase == .propagate) s.phase = .pause;
    completeSweep(g);
    startCycle(g);
    finishMarking(g);
    completeSweep(g);
    if (s.mode == .generational and s.major_pending) {
        s.major_pending = false;
        setMinorThreshold(g);
    }
}

/// Runs collector work for `collectgarbage("step", kb)`. A size of zero
/// runs one basic step. A positive size runs about that many kilobytes of
/// work. In generational mode between major collections, a step is a
/// complete minor collection. Returns true when a cycle finished.
pub fn stepCollect(g: *Global, kb: i64) bool {
    if (g.gc_depth != 0) return false;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    const s = &g.gcs;
    if (s.phase != .propagate and minorNext(s)) {
        minorCollect(g);
        completeSweep(g);
        return true;
    }
    if (kb <= 0) return step(g, baseBudget(s), true);
    var left: usize = std.math.cast(usize, kb) orelse std.math.maxInt(usize);
    left = left *| 1024;
    while (true) {
        const chunk = @min(left, baseBudget(s));
        if (step(g, chunk, true)) return true;
        left -|= chunk;
        if (left == 0) return false;
    }
}

/// Switches between incremental and generational mode and returns the
/// previous mode. Entering generational mode runs a full collection,
/// whose survivors form the old generation.
pub fn setMode(g: *Global, mode: Mode) Mode {
    const s = &g.gcs;
    const old = s.mode;
    if (mode == old) return old;
    s.mode = mode;
    s.major_pending = false;
    if (mode == .generational) {
        if (g.gc_depth == 0) {
            g.gc_depth += 1;
            defer g.gc_depth -= 1;
            collectFull(g);
        } else s.major_pending = true;
    } else if (s.phase == .pause and s.live != 0) {
        setThreshold(g);
    }
    return old;
}

/// Traces every marked object again. Used when the barrier lost track of
/// an object for lack of memory.
fn retraceMarked(g: *Global, m: *Marker) void {
    heap.forEachObject(g, m, struct {
        fn f(mm: *Marker, h: *Header) void {
            if (isMarked(h) and !isLeaf(h.tag)) mm.traverse(h);
        }
    }.f);
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

inline fn isLeaf(tag: Tag) bool {
    return switch (tag) {
        .string, .bigint, .decimal, .vector => true,
        else => false,
    };
}

/// How far below the top of the gray stack `popGray` prefetches.
const prefetch_distance = 8;

/// A gray list. Entries of the gray stack may carry `unmarked_bit`, so
/// they are not aligned.
pub const GrayList = std.ArrayList(*align(1) Header);

/// The gray stack capacity, in entries, that survives the end of a mark
/// phase (2 MB on 64-bit targets).
pub const gray_keep = 256 * 1024;

/// Set in a gray stack entry whose object was not marked when it was
/// pushed (`Marker.markValue`).
const unmarked_bit: usize = 1;

/// Pops the next gray object and prefetches the object that will be
/// popped `prefetch_distance` pops later. Objects reach the gray stack
/// long before they are traced, as when a large table pushes all of its
/// elements, so the object being traced is rarely in the cache. The
/// prefetch covers the first two cache lines, which hold the header and
/// the parts that a small table keeps in its own cell.
pub inline fn popGray(gray: *GrayList) ?*align(1) Header {
    const n = gray.items.len;
    if (n == 0) return null;
    if (n > prefetch_distance) {
        const ahead: [*]const u8 = @ptrFromInt(@intFromPtr(gray.items[n - 1 - prefetch_distance]) & ~unmarked_bit);
        @prefetch(ahead, .{ .rw = .write });
        @prefetch(ahead + 64, .{});
    }
    const h = gray.items[n - 1];
    gray.items.len = n - 1;
    return h;
}

const Marker = MarkerOf(false);

/// The marker of a helper thread in a parallel drain (`gcpar.zig`).
pub const ParMarker = MarkerOf(true);

/// A marker. The sequential one keeps its gray objects on the gray stack
/// of the state. A parallel one keeps them on the stack of its thread,
/// claims objects by setting their marks atomically, and takes a lock to
/// append to the lists of the collector.
fn MarkerOf(comptime par: bool) type {
    return struct {
        const M = @This();

        g: *Global,
        /// Bytes of objects marked and traced by this marker.
        work: usize = 0,
        /// Set while the heap verifier walks the heap. Marking then checks
        /// marks instead of setting them.
        verifying: bool = false,
        /// The object the verifier is checking.
        parent: ?*Header = null,
        /// The gray stack this marker pushes to.
        gray: *GrayList,
        /// The parallel drain of a parallel marker.
        drain: if (par) *gcpar.Drain else void = if (par) undefined else {},

        fn init(g: *Global) M {
            return .{ .g = g, .gray = &g.gcs.gray };
        }

        pub fn initPar(d: *gcpar.Drain, stack: *GrayList) M {
            return .{ .g = d.g, .gray = stack, .drain = d };
        }

        inline fn isMarkedM(h: *const Header) bool {
            return if (par) isMarkedAtomic(h) else isMarked(h);
        }

        /// Sets the mark of an object and returns the bytes it adds to
        /// the work, or zero when it was marked already.
        inline fn claim(h: *Header) usize {
            if (par) {
                const f = flagsOf(h);
                if (@atomicLoad(u8, f, .monotonic) & large_mask != 0) {
                    if (@atomicRmw(u8, f, .Or, mark_mask, .monotonic) & mark_mask != 0) return 0;
                    return objectSize(h);
                }
                if (!heap.setMarkSmallAtomic(h)) return 0;
                return heap.pageOf(h).cell;
            }
            if (h.flags.large) {
                if (h.flags.mark) return 0;
                h.flags.mark = true;
                return objectSize(h);
            }
            if (!heap.setMarkSmall(h)) return 0;
            return heap.pageOf(h).cell;
        }

        inline fn push(m: *M, h: *align(1) Header) bool {
            const gray = m.gray;
            // Runs of references to one object, such as an array filled
            // with the same table, push it once.
            if (gray.items.len > 0 and gray.items[gray.items.len - 1] == h) return true;
            if (gray.items.len < gray.capacity) {
                gray.appendAssumeCapacity(h);
                return true;
            }
            gray.append(gcpar.stack_alloc, h) catch return false;
            return true;
        }

        /// Marks a value. An object that the marker traces goes on the
        /// gray stack unmarked, with the low bit of its address set, so
        /// that its header is read only when it pops, after `popGray`
        /// prefetched it. `visit` marks it then.
        fn markValue(m: *M, v: Value) void {
            if (!v.tag.isCollectable()) return;
            if (m.verifying or isLeaf(v.tag)) return m.markObject(v.header());
            const h: *align(1) Header = @ptrFromInt(@intFromPtr(v.header()) | unmarked_bit);
            if (!m.push(h)) m.markObject(v.header());
        }

        /// Traces an object that popped from the gray stack. An entry
        /// with the low bit set is an object that was not marked when it
        /// was pushed. It is traced only if it is still unmarked, because
        /// whoever marked it meanwhile also queued it, or it is old.
        pub fn visit(m: *M, e: *align(1) Header) void {
            const a = @intFromPtr(e);
            if (a & unmarked_bit == 0) return m.traverse(@alignCast(e));
            const h: *Header = @ptrFromInt(a & ~unmarked_bit);
            const bytes = claim(h);
            if (bytes == 0) return;
            m.work += bytes;
            m.traverse(h);
        }

        fn markObject(m: *M, h: *Header) void {
            if (m.verifying) return m.check(h);
            const bytes = claim(h);
            if (bytes == 0) return;
            m.work += bytes;
            // Leaf objects have no references to trace.
            if (isLeaf(h.tag)) return;
            if (!m.push(h)) m.traverse(h);
        }

        /// Marks the tables of an array part of kind `table`.
        fn markTables(m: *M, words: []const u64) void {
            for (words) |w| {
                if (w != object.Table.hole) m.markValue(Value.make(w, .table));
            }
        }

        /// Marks the strings of an array part of kind `string`. Strings
        /// reference nothing, so none of them goes on the gray stack.
        fn markStrings(m: *M, words: []const u64) void {
            for (words) |w| {
                if (w != object.Table.hole) m.markObject(Value.make(w, .string).header());
            }
        }

        fn markRoots(m: *M) void {
            const g = m.g;
            m.markObject(&g.main_thread.hdr);
            m.markValue(g.registry);
            m.markValue(g.globals);
            for (g.type_metatables) |mt| if (mt) |t| m.markObject(&t.hdr);
            for (g.tm_names) |s| if (s) |p| m.markObject(&p.hdr);
            for (g.fixed.items) |h| m.markObject(h);
            // Objects waiting in the finalizer queue stay alive.
            for (g.tobefnz.items) |h| m.markObject(h);
            // So do the coroutines that the scheduler runs.
            @import("sched.zig").markRoots(g, m);
            @import("context.zig").markRoots(g, m);
        }

        /// Traces the gray stack until it is empty, on several threads
        /// when it holds enough work.
        fn drainGray(m: *M) void {
            const s = &m.g.gcs;
            var n: u32 = 0;
            while (popGray(&s.gray)) |h| {
                m.visit(h);
                n +%= 1;
                if (gcpar.enabled and n % gcpar.check_interval == 0 and s.gray.items.len >= gcpar.min_entries and !s.gray_repeats) {
                    if (gcpar.drain(m.g, &m.work)) return;
                }
            }
            s.gray_repeats = false;
        }

        /// Traces gray objects, including those that stores turned gray
        /// again, until none is left. Objects that stores turned gray
        /// again may appear twice, so they are traced by this thread
        /// alone, while no parallel drain runs.
        fn drainAll(m: *M) void {
            const s = &m.g.gcs;
            while (true) {
                m.drainGray();
                const h = s.grayagain.pop() orelse break;
                m.traverse(@alignCast(h));
            }
        }

        /// Ends a parallel marker: its work counts for the drain.
        pub fn flush(m: *M) void {
            if (par) {
                _ = m.drain.work.fetchAdd(m.work, .monotonic);
                m.work = 0;
            }
        }

        fn traverse(m: *M, h: *Header) void {
            // The object turns black. A later store into it takes the
            // slow path of the barrier.
            if (!m.verifying) {
                if (par) {
                    // Only the thread that claimed the object writes its
                    // flags, and the mark of a large object is already
                    // set, so a plain store loses nothing.
                    const f = flagsOf(h);
                    const old = @atomicLoad(u8, f, .monotonic);
                    if (old & barrier_mask == 0) @atomicStore(u8, f, old | barrier_mask, .monotonic);
                } else h.flags.barrier = true;
            }
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
                .thread => {
                    const t = h.as(Thread);
                    m.work += t.stack.len * @sizeOf(Value);
                    t.traverse(m);
                },
                .enum_root => {
                    const r = h.as(object.EnumRoot);
                    for (r.names) |s| m.markObject(&s.hdr);
                    for (r.values) |ev| if (ev) |e| m.markObject(&e.hdr);
                },
                .enum_value => m.markObject(&h.as(object.EnumValue).root.hdr),
                else => state_mod.traverseExtra(m, h),
            }
        }

        pub fn mark(m: *M, v: Value) void {
            m.markValue(v);
        }
        pub fn markHeader(m: *M, h: *Header) void {
            m.markObject(h);
        }

        /// Appends a weak table to a list of the collector.
        fn remember(m: *M, list: *std.ArrayList(*object.Table), t: *object.Table) void {
            if (par) m.drain.lock.lock();
            defer if (par) m.drain.lock.unlock();
            list.append(m.g.gpa, t) catch {};
        }

        fn traverseTable(m: *M, t: *object.Table) void {
            const s = &m.g.gcs;
            // An unboxed array part holds numbers, which tracing skips,
            // strings, which it marks without tracing, or tables, which
            // are strong unless the values of the table are weak.
            const arr: []const Value = if (t.kind == .boxed) t.values() else &.{};
            m.work += arr.len * @sizeOf(Value) + @as(usize, t.hash_len) * @sizeOf(object.Node);
            if (t.kind == .string) m.markStrings(t.words());
            if (t.metatable) |mt| m.markObject(&mt.hdr);
            const mode = weakModeOf(m.g, t);
            if (!m.verifying) t.setWeakMode(mode);
            if (t.kind == .table) {
                m.work += t.words().len * @sizeOf(u64);
                if (mode == .none or mode == .keys) m.markTables(t.words());
            }
            switch (mode) {
                .none => {
                    for (arr) |v| m.markValue(v);
                    for (0..t.hash_len) |hi| {
                        const n = t.entry(hi);
                        if (n.val.isNil()) {
                            m.markDeadKey(n.key);
                            continue;
                        }
                        m.markValue(n.key);
                        m.markValue(n.val);
                    }
                },
                .values => {
                    // Keys are strong, values are weak.
                    for (arr) |v| m.markIfValueLike(v);
                    for (0..t.hash_len) |hi| {
                        const n = t.entry(hi);
                        if (n.val.isNil()) {
                            m.markDeadKey(n.key);
                            continue;
                        }
                        m.markValue(n.key);
                        m.markIfValueLike(n.val);
                    }
                    if (!m.verifying) m.remember(&s.weak, t);
                },
                .keys => {
                    // Ephemeron: a value is reachable only through its key.
                    for (arr) |v| m.markValue(v);
                    for (0..t.hash_len) |hi| {
                        const n = t.entry(hi);
                        if (n.val.isNil()) {
                            m.markDeadKey(n.key);
                            continue;
                        }
                        m.markIfValueLike(n.key);
                        if (m.verifying and isMarkedOrNotCollectable(n.key)) m.markValue(n.val);
                    }
                    if (!m.verifying) {
                        m.remember(&s.ephemerons, t);
                        m.remember(&s.weak, t);
                    }
                },
                .both => {
                    for (arr) |v| m.markIfValueLike(v);
                    for (0..t.hash_len) |hi| {
                        const n = t.entry(hi);
                        if (n.val.isNil()) {
                            m.markDeadKey(n.key);
                            continue;
                        }
                        m.markIfValueLike(n.key);
                        m.markIfValueLike(n.val);
                    }
                    if (!m.verifying) m.remember(&s.weak, t);
                },
            }
            if (t.isShaped()) m.traverseSlots(t, mode);
        }

        /// Marks the values in the slots of a shaped table. Its keys are
        /// strings, which the state keeps alive and weak modes never
        /// clear, so only weak values make a difference, and the table is
        /// already on the list of weak tables then.
        fn traverseSlots(m: *M, t: *object.Table, mode: object.Table.WeakMode) void {
            const n: usize = table.shapeOf(t).n;
            m.work += n * @sizeOf(u64);
            const weak_values = mode == .values or mode == .both;
            for (0..n) |i| {
                const v = t.slotVal(i);
                if (weak_values) m.markIfValueLike(v) else m.markValue(v);
            }
        }

        /// Marks the key of a dead node, one whose value is nil. The node
        /// keeps its key until the next rehash, so that `next` continues
        /// from a key removed during a traversal, and every lookup that
        /// probes past the node compares its key with the one it looks
        /// for. Strings and arbitrary-precision numbers compare by
        /// content, so such a key stays alive as long as its node. Any
        /// other key compares by address alone and is left to die.
        fn markDeadKey(m: *M, k: Value) void {
            if (isValueLike(k)) m.markValue(k);
        }

        /// Strings and arbitrary-precision numbers are values, not
        /// objects, for weak tables: they are never cleared, so they must
        /// stay alive.
        fn markIfValueLike(m: *M, v: Value) void {
            if (isValueLike(v)) m.markValue(v);
        }

        fn convergeEphemerons(m: *M) void {
            var changed = true;
            while (changed) {
                changed = false;
                for (m.g.gcs.ephemerons.items) |t| {
                    for (0..t.hash_len) |hi| {
                        const n = t.entry(hi);
                        if (n.val.isNil()) continue;
                        if (isMarkedOrNotCollectable(n.key) and n.val.tag.isCollectable() and !isMarked(n.val.header())) {
                            m.markValue(n.val);
                            changed = true;
                        }
                    }
                }
                if (changed) m.drainAll();
            }
        }

        /// Moves unreachable objects with finalizers to the finalizer
        /// queue, keeping registration order. The queue runs from its
        /// end, so the most recently registered object is finalized
        /// first.
        fn separateFinalizable(m: *M) void {
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

        fn clearWeak(m: *M) void {
            for (m.g.gcs.weak.items) |t| {
                if ((t.weakMode() == .values or t.weakMode() == .both) and t.kind == .boxed) {
                    for (t.values()) |*v| {
                        if (!isMarkedOrNotCollectable(v.*) or isFinalizedObject(v.*)) v.* = .nil;
                    }
                }
                if ((t.weakMode() == .values or t.weakMode() == .both) and t.kind == .table) {
                    for (t.words()) |*w| {
                        if (w.* == object.Table.hole) continue;
                        const v = Value.make(w.*, .table);
                        if (!isMarkedOrNotCollectable(v) or isFinalizedObject(v)) w.* = object.Table.hole;
                    }
                }
                if (t.isShaped() and (t.weakMode() == .values or t.weakMode() == .both)) {
                    for (0..table.shapeOf(t).n) |i| {
                        const v = t.slotVal(i);
                        if (!isMarkedOrNotCollectable(v) or isFinalizedObject(v)) t.setSlot(i, .nil);
                    }
                }
                for (0..t.hash_len) |hi| {
                    const n = t.entry(hi);
                    if (n.val.isNil()) continue;
                    const key_dead = (t.weakMode() == .keys or t.weakMode() == .both) and !isMarkedOrNotCollectable(n.key);
                    const val_dead = (t.weakMode() == .values or t.weakMode() == .both) and (!isMarkedOrNotCollectable(n.val) or isFinalizedObject(n.val));
                    if (key_dead or val_dead) t.setVal(hi, .nil);
                }
            }
        }

        /// Verifier: a marked object references an unmarked one.
        fn check(m: *M, h: *Header) void {
            if (isMarkedM(h)) return;
            const p = m.parent.?;
            std.debug.print("gc verify: marked {s} at {*} references unmarked {s} at {*}\n", .{ @tagName(p.tag), p, @tagName(h.tag), h });
            @panic("gc verify: tri-color invariant violated");
        }
    };
}

pub const MarkerApi = Marker;

const flag_bits = struct {
    fn mask(comptime name: []const u8) u8 {
        var f: Header.Flags = .{};
        @field(f, name) = true;
        return @bitCast(f);
    }
};
const barrier_mask = flag_bits.mask("barrier");
const large_mask = flag_bits.mask("large");
const mark_mask = flag_bits.mask("mark");

inline fn flagsOf(h: *Header) *u8 {
    return @ptrCast(&h.flags);
}

/// `isMarked` for parallel markers, whose threads set marks while others
/// read them.
inline fn isMarkedAtomic(h: *const Header) bool {
    const f = @atomicLoad(u8, @as(*const u8, @ptrCast(&h.flags)), .monotonic);
    if (f & large_mask != 0) return f & mark_mask != 0;
    return heap.isMarkedSmallAtomic(h);
}

// ---------------------------------------------------------------------
// Heap verifier, enabled with -Dgc-verify and -Dinvariants. At the end of
// every mark phase, every marked object must reference only marked objects
// through strong references, and with -Dgc-verify it must also be black
// (traced after its last store). A failure means a missing barrier or a
// missing root.

fn verifyHeap(g: *Global) void {
    var m = Marker.init(g);
    m.verifying = true;
    inv.assert(g.gcs.gray.items.len == 0 and g.gcs.grayagain.items.len == 0);
    heap.forEachObject(g, &m, struct {
        fn f(mm: *Marker, h: *Header) void {
            if (!isMarked(h) or isLeaf(h.tag)) return;
            // Only the verifying build tracks which objects were traced
            // after their last store.
            if (verify and !h.flags.barrier) {
                std.debug.print("gc verify: marked {s} at {*} is not black\n", .{ @tagName(h.tag), h });
                @panic("gc verify: barrier coverage violated");
            }
            mm.parent = h;
            mm.traverse(h);
        }
    }.f);
}

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
/// `pause` sets the heap goal relative to the live data, `stepmul` the
/// marking work per allocated byte, and `stepsize` the allocation between
/// steps. `minormul` sets the allocation between minor collections as a
/// percentage of the heap after the last major collection, `minormajor`
/// the growth of the old generation that calls for a major collection,
/// and `majorminor` the share of the heap a major collection must free to
/// return to minor collections.
pub fn getParam(g: *const Global, p: Param) i64 {
    const s = &g.gcs;
    return switch (p) {
        .pause => @intCast(g.pause),
        .minormul => @intCast(s.minormul),
        .majorminor => @intCast(s.majorminor),
        .minormajor => @intCast(s.minormajor),
        .stepmul => @intCast(s.stepmul),
        .stepsize => @intCast(s.stepsize),
    };
}

/// Sets a parameter when `v` is non-negative and returns its previous
/// value.
pub fn setParam(g: *Global, p: Param, v: i64) i64 {
    const old = getParam(g, p);
    if (v < 0) return old;
    const n = std.math.cast(usize, v) orelse std.math.maxInt(usize);
    const s = &g.gcs;
    switch (p) {
        .pause => g.pause = n,
        .stepmul => s.stepmul = @max(n, 1),
        .stepsize => s.stepsize = @max(n, 1024),
        .minormul => s.minormul = @max(n, 1),
        .majorminor => s.majorminor = @min(n, 100),
        .minormajor => s.minormajor = n,
    }
    // A new pace applies from the next threshold.
    if (s.phase == .pause and s.live != 0) {
        if (minorNext(s)) setMinorThreshold(g) else setThreshold(g);
    }
    return old;
}
