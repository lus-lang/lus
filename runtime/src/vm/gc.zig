//! Garbage collector. Stage one of the plan: a precise, non-moving,
//! stop-the-world mark and sweep with full weak table, ephemeron, and
//! finalizer semantics. Allocation and barrier entry points are the ones
//! the incremental and generational stages keep, so the interpreter never
//! has to change when the collector does.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const state_mod = @import("state.zig");
const Value = value.Value;
const Tag = value.Tag;
const Global = state_mod.Global;
const Thread = state_mod.Thread;

pub const Header = struct {
    next: ?*Header = null,
    tag: Tag,
    marked: bool = false,
    /// Set on objects that wait for (or already ran) their finalizer.
    finalize: Finalize = .none,
    /// The barrier bit of the plan. Set while an object is marked, so
    /// stores into marked objects take the slow path during a cycle.
    barrier: bool = false,

    pub const Finalize = enum(u8) { none, pending, done };

    pub inline fn as(h: *Header, comptime T: type) *T {
        return @ptrCast(@alignCast(h));
    }
};

/// Allocates a zeroed object of type `T` with `extra` trailing bytes and
/// links it into the heap. The caller initializes the fields.
pub fn alloc(g: *Global, comptime T: type, tag: Tag, size: usize) !*T {
    const mem = try g.gpa.alignedAlloc(u8, .of(T), size);
    @memset(mem, 0);
    const obj: *T = @ptrCast(@alignCast(mem.ptr));
    obj.hdr = .{ .tag = tag, .next = g.all_objects };
    g.all_objects = &obj.hdr;
    g.object_count += 1;
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

fn freeObject(g: *Global, h: *Header) void {
    const gpa = g.gpa;
    const size = objectSize(h);
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
    const base: [*]u8 = @ptrCast(h);
    g.object_count -|= 1;
    // Every object was allocated with the alignment of its own type, which
    // is at most 16, so freeing with a 16-aligned slice of the same length
    // is valid for the general purpose allocator.
    gpa.rawFree(base[0..size], alignOf(h.tag), @returnAddress());
}

fn alignOf(tag: Tag) std.mem.Alignment {
    return switch (tag) {
        .string => .of(object.String),
        .table => .of(object.Table),
        .closure => .of(object.Closure),
        .native => .of(state_mod.Native),
        .userdata => .of(object.Userdata),
        .thread => .of(Thread),
        .vector => .of(object.Vector),
        .enum_root => .of(object.EnumRoot),
        .enum_value => .of(object.EnumValue),
        else => state_mod.extraAlign(tag),
    };
}

// ---------------------------------------------------------------------
// Barriers. Called on every store of a collectable value into a heap
// object. With the stop-the-world collector they only matter while a
// cycle is in progress, which never overlaps the mutator, so the fast
// path is a single flag test that is never taken.

pub inline fn barrierBack(g: *Global, h: *Header) void {
    if (h.barrier) barrierSlow(g, h);
}

fn barrierSlow(g: *Global, h: *Header) void {
    _ = g;
    h.barrier = false;
}

// ---------------------------------------------------------------------
// Collection

const stress = @import("build_options").gc_stress;

pub fn maybeCollect(g: *Global) void {
    if (g.gc_stopped or g.gc_depth != 0) return;
    if (stress != 0) {
        g.stress_tick +%= 1;
        if (g.stress_tick % stress == 0) return fullCollect(g);
    }
    if (g.counter.bytes >= g.threshold) fullCollect(g);
}

pub fn fullCollect(g: *Global) void {
    if (g.gc_depth != 0) return;
    g.gc_depth += 1;
    defer g.gc_depth -= 1;
    var m = Marker{ .g = g };
    defer m.gray.deinit(g.gpa);
    defer m.weak.deinit(g.gpa);
    defer m.ephemerons.deinit(g.gpa);
    m.markRoots();
    m.drain();
    m.convergeEphemerons();
    // Separate unreachable objects with finalizers and resurrect them for
    // one more cycle, so their finalizers see valid objects.
    m.separateFinalizable();
    m.drain();
    m.convergeEphemerons();
    m.clearWeak();
    sweep(g);
    g.threshold = @max(g.counter.bytes * g.pause / 100, 256 * 1024);
    g.cycles += 1;
}

const Marker = struct {
    g: *Global,
    gray: std.ArrayList(*Header) = .empty,
    weak: std.ArrayList(*object.Table) = .empty,
    ephemerons: std.ArrayList(*object.Table) = .empty,

    fn markValue(m: *Marker, v: Value) void {
        if (v.tag.isCollectable()) m.markObject(v.header());
    }

    fn markObject(m: *Marker, h: *Header) void {
        if (h.marked) return;
        h.marked = true;
        switch (h.tag) {
            // Leaf objects have no references to trace.
            .string, .bigint, .decimal, .vector => {},
            else => m.gray.append(m.g.gpa, h) catch m.traverse(h),
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
        while (m.gray.pop()) |h| m.traverse(h);
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
                m.weak.append(m.g.gpa, t) catch {};
            },
            .keys => {
                // Ephemeron: a value is reachable only through its key.
                for (t.array) |v| m.markValue(v);
                for (t.hash) |n| {
                    if (!n.val.isNil()) m.markIfValueLike(n.key);
                }
                m.ephemerons.append(m.g.gpa, t) catch {};
                m.weak.append(m.g.gpa, t) catch {};
            },
            .both => {
                for (t.array) |v| m.markIfValueLike(v);
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    m.markIfValueLike(n.key);
                    m.markIfValueLike(n.val);
                }
                m.weak.append(m.g.gpa, t) catch {};
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
            for (m.ephemerons.items) |t| {
                for (t.hash) |n| {
                    if (n.val.isNil()) continue;
                    if (isMarkedOrNotCollectable(n.key) and n.val.tag.isCollectable() and !n.val.header().marked) {
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
            if (!h.marked) {
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
        for (m.weak.items) |t| {
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
    return v.header().marked;
}

fn isValueLike(v: Value) bool {
    return v.tag == .string or v.tag == .bigint or v.tag == .decimal;
}

fn isFinalizedObject(v: Value) bool {
    return v.tag.isCollectable() and v.header().finalize == .pending;
}

fn weakModeOf(g: *Global, t: *object.Table) object.Table.WeakMode {
    const mt = t.metatable orelse return .none;
    const mode = state_mod.rawGetStr(mt, g.tm_names[@intFromEnum(state_mod.TM.mode)].?) orelse return .none;
    if (mode.tag != .string) return .none;
    const b = mode.as(object.String).bytes();
    const k = std.mem.indexOfScalar(u8, b, 'k') != null;
    const v = std.mem.indexOfScalar(u8, b, 'v') != null;
    if (k and v) return .both;
    if (k) return .keys;
    if (v) return .values;
    return .none;
}

fn sweep(g: *Global) void {
    // Dead threads close their open upvalues first, so closures that
    // survive keep the captured values instead of pointing into a freed
    // stack. This runs before any object is freed.
    var it = g.all_objects;
    while (it) |h| : (it = h.next) {
        if (!h.marked and h.tag == .thread) @import("interp.zig").closeUpvals(h.as(Thread), 0);
    }
    var link: *?*Header = &g.all_objects;
    while (link.*) |h| {
        if (h.marked) {
            h.marked = false;
            link = &h.next;
        } else {
            link.* = h.next;
            freeObject(g, h);
        }
    }
}

/// Frees every object. Used when a state closes.
pub fn freeAll(g: *Global) void {
    var it = g.all_objects;
    while (it) |h| {
        it = h.next;
        freeObject(g, h);
    }
    g.all_objects = null;
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
    if (v >= 0 and p == .pause) g.pause = @intCast(v);
    return old;
}
