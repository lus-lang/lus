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
// object, after the store. The barrier is backward: a store into a black
// object turns the object gray again, and the collector traces it once
// more before the mark phase ends. The fast path is a single test of the
// barrier bit, which only black objects carry.

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
    if (s.phase == .propagate and t.weak_mode == .none and t.array.len + t.hash.len >= big_table and isMarked(&t.hdr)) {
        markGray(g, key);
        markGray(g, val);
        return;
    }
    barrierSlow(g, &t.hdr);
}

/// Marks a value outside a marker and queues it for tracing.
fn markGray(g: *Global, v: Value) void {
    if (!v.tag.isCollectable()) return;
    const h = v.header();
    if (!setMark(h) or isLeaf(h.tag)) return;
    g.gcs.gray.append(g.gpa, h) catch {
        g.gcs.overflow = true;
    };
}

fn barrierSlow(g: *Global, h: *Header) void {
    h.flags.barrier = false;
    const s = &g.gcs;
    if (s.phase != .propagate) return;
    if (!isMarked(h)) return;
    // When the list cannot grow, the atomic phase traces every marked
    // object again instead.
    s.grayagain.append(g.gpa, h) catch {
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

pub const State = struct {
    phase: Phase = .pause,
    /// Objects marked but not traced yet.
    gray: std.ArrayList(*Header) = .empty,
    /// Black objects that a store turned gray again.
    grayagain: std.ArrayList(*Header) = .empty,
    weak: std.ArrayList(*object.Table) = .empty,
    ephemerons: std.ArrayList(*object.Table) = .empty,
    /// Every thread, so that the atomic phase rescans the stacks and dead
    /// threads close their upvalues before their stacks go away.
    threads: std.ArrayList(*Thread) = .empty,
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
    /// The heap size after the last sweep finished.
    live: usize = 0,
    stepmul: usize = 200,
    stepsize: usize = 200 * @sizeOf(object.Table),

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.gray.deinit(gpa);
        s.grayagain.deinit(gpa);
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
    const s = &g.gcs;
    s.live = g.counter.bytes;
    // The products are formed in 64 bits, since they overflow a 32-bit
    // usize once the heap passes a few dozen megabytes.
    const goal: u64 = @as(u64, s.live) * g.pause / 100;
    const during: u64 = @as(u64, s.live) * 100 / @max(s.stepmul, 1);
    const start = @max(goal -| during, @as(u64, s.live) + s.stepsize);
    const t: u64 = @max(start, 256 * 1024);
    g.threshold = @intCast(@min(t, std.math.maxInt(usize)));
    s.goal = @intCast(@min(@max(goal, t + s.stepsize), std.math.maxInt(usize)));
    s.next_check = g.threshold;
}

// ---------------------------------------------------------------------
// Collection

const stress = @import("build_options").gc_stress;
const verify = @import("build_options").gc_verify;

pub inline fn maybeCollect(g: *Global) void {
    if (stress != 0) return stressPoint(g);
    if (g.counter.bytes >= g.gcs.next_check) collectSlow(g);
}

/// The stress build runs a small step at every allocation point, so
/// marking always overlaps the program, and finishes a mark phase at
/// every Nth point.
fn stressPoint(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    g.stress_tick +%= 1;
    if (g.stress_tick % stress == 0) {
        switch (g.gcs.phase) {
            .pause => {
                startCycle(g);
                finishMarking(g);
            },
            .propagate => finishMarking(g),
            .sweep => completeSweep(g),
        }
        return;
    }
    _ = step(g, 512, true);
}

fn collectSlow(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    _ = step(g, 0, false);
}

/// Runs one collector step with `budget` bytes of work, or a paced budget
/// when it is zero. A step in the pause phase starts a cycle when the
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
            startCycle(g);
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

fn startCycle(g: *Global) void {
    const s = &g.gcs;
    std.debug.assert(s.phase == .pause);
    heap.clearMarks(g);
    s.gray.clearRetainingCapacity();
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
    var m = Marker{ .g = g };
    m.markRoots();
    s.marked += m.work;
}

/// Traces gray objects until `budget` bytes of work are done, and runs
/// the atomic phase when no gray object is left.
fn propagate(g: *Global, budget: usize) void {
    const s = &g.gcs;
    var m = Marker{ .g = g };
    while (m.work < budget) {
        if (s.gray.pop()) |h| {
            m.traverse(h);
            continue;
        }
        // Objects that stores turned gray again are traced a couple of
        // times while the program runs, so the atomic phase finds few.
        if (s.grayagain.items.len > 0 and s.again_rounds < 2) {
            s.again_rounds += 1;
            std.mem.swap(std.ArrayList(*Header), &s.gray, &s.grayagain);
            continue;
        }
        s.marked += m.work;
        atomic(g);
        return;
    }
    s.marked += m.work;
    s.next_check = g.counter.bytes + s.stepsize;
}

/// Completes the mark phase of the current cycle.
fn finishMarking(g: *Global) void {
    while (g.gcs.phase == .propagate) propagate(g, std.math.maxInt(usize));
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

fn finishSweep(g: *Global) void {
    heap.releaseSegments(g);
    g.gcs.phase = .pause;
    setThreshold(g);
}

/// Completes the sweep of the previous collection.
fn completeSweep(g: *Global) void {
    if (g.gcs.phase != .sweep) return;
    _ = heap.sweepSome(g, std.math.maxInt(usize));
    _ = sweepLarge(g);
    finishSweep(g);
}

/// Runs a complete collection, including its sweep. A mark phase in
/// progress is abandoned, since its marks may be stale for objects that
/// died since it started.
pub fn fullCollect(g: *Global) void {
    if (g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    const s = &g.gcs;
    if (s.phase == .propagate) s.phase = .pause;
    completeSweep(g);
    startCycle(g);
    finishMarking(g);
    completeSweep(g);
}

/// Runs collector work for `collectgarbage("step", kb)`. A size of zero
/// runs one basic step. A positive size runs about that many kilobytes of
/// work. Returns true when a cycle finished.
pub fn stepCollect(g: *Global, kb: i64) bool {
    if (g.gc_depth != 0) return false;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    if (kb <= 0) return step(g, baseBudget(&g.gcs), true);
    var left: usize = std.math.cast(usize, kb) orelse std.math.maxInt(usize);
    left = left *| 1024;
    while (true) {
        const chunk = @min(left, baseBudget(&g.gcs));
        if (step(g, chunk, true)) return true;
        left -|= chunk;
        if (left == 0) return false;
    }
}

/// The atomic phase: the mark phase ends without the program running.
/// Roots and stacks are traced again, objects that stores turned gray are
/// traced, ephemerons converge, finalizable objects are separated, and
/// weak tables are cleared.
fn atomic(g: *Global) void {
    const s = &g.gcs;
    var m = Marker{ .g = g };
    m.markRoots();
    // Stacks change without barriers, so every live thread is traced
    // again. A dead thread may still own open upvalues that a live
    // closure captured, so their current values are marked.
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
        retraceMarked(g, &m);
        m.drainAll();
    }
    m.convergeEphemerons();
    // Separate unreachable objects with finalizers and resurrect them for
    // one more cycle, so their finalizers see valid objects.
    m.separateFinalizable();
    m.drainAll();
    m.convergeEphemerons();
    m.clearWeak();
    if (verify) verifyHeap(g);
    s.phase = .sweep;
    closeDeadThreads(g);
    const h = &g.heap;
    heap.startSweep(g, true);
    // Every large object joins the sweep. The surviving ones return to
    // `large`, so it keeps room for all of them.
    const total = h.large.items.len + h.large_young.items.len;
    if (h.large_sweep.ensureTotalCapacity(g.gpa, total)) |_| {
        if (h.large.ensureTotalCapacity(g.gpa, total)) |_| {
            h.large_sweep.appendSliceAssumeCapacity(h.large.items);
            h.large_sweep.appendSliceAssumeCapacity(h.large_young.items);
            h.large.clearRetainingCapacity();
            h.large_young.clearRetainingCapacity();
        } else |_| keepLarge(g);
    } else |_| keepLarge(g);
    s.weak.clearRetainingCapacity();
    s.ephemerons.clearRetainingCapacity();
    s.grayagain.clearRetainingCapacity();
    s.next_check = g.counter.bytes + s.stepsize;
    g.cycles += 1;
}

/// Out of memory before a sweep: every large object survives this cycle.
fn keepLarge(g: *Global) void {
    const h = &g.heap;
    h.large.appendSlice(g.gpa, h.large_young.items) catch return;
    h.large_young.clearRetainingCapacity();
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

const Marker = struct {
    g: *Global,
    /// Bytes of objects marked and traced by this marker.
    work: usize = 0,
    /// Set while the heap verifier walks the heap. Marking then checks
    /// marks instead of setting them.
    verifying: bool = false,
    /// The object the verifier is checking.
    parent: ?*Header = null,

    fn markValue(m: *Marker, v: Value) void {
        if (v.tag.isCollectable()) m.markObject(v.header());
    }

    fn markObject(m: *Marker, h: *Header) void {
        if (m.verifying) return m.check(h);
        if (h.flags.large) {
            if (h.flags.mark) return;
            h.flags.mark = true;
            m.work += objectSize(h);
        } else {
            const p = heap.pageOf(h);
            if (!heap.setMarkSmall(h)) return;
            m.work += p.cell;
        }
        // Leaf objects have no references to trace.
        if (isLeaf(h.tag)) return;
        m.g.gcs.gray.append(m.g.gpa, h) catch m.traverse(h);
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

    /// Traces gray objects, including those that stores turned gray
    /// again, until none is left.
    fn drainAll(m: *Marker) void {
        const s = &m.g.gcs;
        while (true) {
            if (s.gray.pop()) |h| {
                m.traverse(h);
            } else if (s.grayagain.pop()) |h| {
                m.traverse(h);
            } else break;
        }
    }

    fn traverse(m: *Marker, h: *Header) void {
        // The object turns black. A later store into it takes the slow
        // path of the barrier.
        if (!m.verifying) h.flags.barrier = true;
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

    pub fn mark(m: *Marker, v: Value) void {
        m.markValue(v);
    }
    pub fn markHeader(m: *Marker, h: *Header) void {
        m.markObject(h);
    }

    fn traverseTable(m: *Marker, t: *object.Table) void {
        const gpa = m.g.gpa;
        const s = &m.g.gcs;
        m.work += t.array.len * @sizeOf(Value) + t.hash.len * @sizeOf(object.Node);
        if (t.metatable) |mt| m.markObject(&mt.hdr);
        const mode = weakModeOf(m.g, t);
        if (!m.verifying) t.weak_mode = mode;
        switch (mode) {
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
                if (!m.verifying) s.weak.append(gpa, t) catch {};
            },
            .keys => {
                // Ephemeron: a value is reachable only through its key.
                for (t.array) |v| m.markValue(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markIfValueLike(n.key);
                    if (m.verifying and isMarkedOrNotCollectable(n.key)) m.markValue(n.val);
                }
                if (!m.verifying) {
                    s.ephemerons.append(gpa, t) catch {};
                    s.weak.append(gpa, t) catch {};
                }
            },
            .both => {
                for (t.array) |v| m.markIfValueLike(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markIfValueLike(n.key);
                    m.markIfValueLike(n.val);
                }
                if (!m.verifying) s.weak.append(gpa, t) catch {};
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
            if (changed) m.drainAll();
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

    /// Verifier: a marked object references an unmarked one.
    fn check(m: *Marker, h: *Header) void {
        if (isMarked(h)) return;
        const p = m.parent.?;
        std.debug.print("gc verify: marked {s} at {*} references unmarked {s} at {*}\n", .{ @tagName(p.tag), p, @tagName(h.tag), h });
        @panic("gc verify: tri-color invariant violated");
    }
};

pub const MarkerApi = Marker;

// ---------------------------------------------------------------------
// Heap verifier, enabled with -Dgc-verify. At the end of every mark
// phase, every marked object must be black (traced after its last store)
// and must reference only marked objects through strong references. A
// failure means a missing barrier or a missing root.

fn verifyHeap(g: *Global) void {
    var m = Marker{ .g = g, .verifying = true };
    std.debug.assert(g.gcs.gray.items.len == 0 and g.gcs.grayagain.items.len == 0);
    heap.forEachObject(g, &m, struct {
        fn f(mm: *Marker, h: *Header) void {
            if (!isMarked(h) or isLeaf(h.tag)) return;
            if (!h.flags.barrier) {
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
/// steps. The generational parameters report fixed default values.
pub fn getParam(g: *const Global, p: Param) i64 {
    const s = &g.gcs;
    return switch (p) {
        .pause => @intCast(g.pause),
        .minormul => 20,
        .majorminor => 50,
        .minormajor => 70,
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
        else => {},
    }
    // A new pace applies from the next threshold.
    if (s.phase == .pause and s.live != 0) setThreshold(g);
    return old;
}
