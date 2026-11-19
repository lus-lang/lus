//! The object heap. Small objects live in 16 KB pages carved out of
//! 256 KB aligned segments. Every page holds cells of one size class, and
//! every size class is a multiple of the 16-byte granule. A page also
//! holds objects of one kind: scanned objects, which the marker traces,
//! or leaf objects (strings, bigints, decimals, vector headers), which it
//! only marks. Objects larger than the biggest class come straight from
//! the backing allocator and are kept in a list.
//!
//! The first page of every segment holds the metadata of the other
//! fifteen: a mark bitmap with one bit per granule, the free list, and
//! the bump limit. A fresh page bump-allocates. A swept page allocates
//! from a free list rebuilt from its mark bitmap. Pages are swept lazily,
//! one at a time, when the allocator reaches them, or by collector steps.
//! Sweeping uses whole bitmap words, so a run of 64 live granules costs
//! one test.

const std = @import("std");
const gc = @import("gc.zig");
const state_mod = @import("state.zig");
const Header = gc.Header;
const Global = state_mod.Global;
const Allocator = std.mem.Allocator;

pub const segment_size = 256 * 1024;
pub const page_size = 16 * 1024;
pub const pages_per_segment = segment_size / page_size;
pub const granule = 16;
pub const max_small = 2048;
const granules_per_page = page_size / granule;
pub const bitmap_words = granules_per_page / 64;

/// Size classes in granules. Classes grow by a quarter past 128 bytes,
/// which bounds internal fragmentation by 20 percent.
pub const class_granules = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128 };
pub const class_count = class_granules.len;

const class_of_granules: [max_small / granule + 1]u8 = blk: {
    var t: [max_small / granule + 1]u8 = undefined;
    var c: usize = 0;
    for (0..t.len) |n| {
        while (class_granules[c] < n) c += 1;
        t[n] = c;
    }
    break :blk t;
};

pub inline fn classFor(size: usize) u8 {
    return class_of_granules[(size + granule - 1) / granule];
}

pub inline fn classBytes(class: u8) u32 {
    return @as(u32, class_granules[class]) * granule;
}

/// For each class, the bitmap bits of the granules where cells start.
const start_masks: [class_count][bitmap_words]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [class_count][bitmap_words]u64 = undefined;
    for (class_granules, 0..) |cg, c| {
        var m: [bitmap_words]u64 = @splat(0);
        const ncells = page_size / (cg * granule);
        for (0..ncells) |i| {
            const gi = i * cg;
            m[gi / 64] |= @as(u64, 1) << @intCast(gi % 64);
        }
        t[c] = m;
    }
    break :blk t;
};

pub const Kind = enum(u1) { scan, leaf };

/// A free cell. Its header carries the `free` flag, so a sweep tells it
/// apart from a dead object.
pub const FreeCell = struct {
    hdr: Header,
    next: ?*FreeCell,
};

pub const Page = struct {
    /// One bit per granule. Only bits where cells start are ever set.
    marks: [bitmap_words]u64 = @splat(0),
    free: ?*FreeCell = null,
    prev: ?*Page = null,
    next: ?*Page = null,
    /// Offset of the first cell that was never allocated.
    top: u32 = 0,
    cell: u32 = 0,
    /// Bytes of the page that whole cells cover.
    usable: u32 = 0,
    class: u8 = 0,
    index: u8 = 0,
    kind: Kind = .scan,
    in_use: bool = false,
    /// Set when a collection finished marking and this page still holds
    /// the results of that mark.
    needs_sweep: bool = false,
    /// Set when objects were allocated here since the last collection.
    young: bool = false,
    /// Set while the page is the allocation page of its class.
    current: bool = false,

    pub inline fn base(p: *const Page) usize {
        return (@intFromPtr(p) & ~@as(usize, segment_size - 1)) + @as(usize, p.index) * page_size;
    }
};

pub const Segment = struct {
    pages: [pages_per_segment]Page,
    next: ?*Segment,
    /// Pages of this segment that hold a size class.
    used: u8,
};

comptime {
    std.debug.assert(@sizeOf(Segment) <= page_size);
}

/// The allocation state of one size class of one kind.
pub const ClassAlloc = struct {
    free: ?*FreeCell = null,
    bump: usize = 0,
    end: usize = 0,
    page: ?*Page = null,
    /// Every page of the class, in a doubly linked list.
    head: ?*Page = null,
    /// The next page to try when the current one is full.
    cursor: ?*Page = null,
};

pub const Heap = struct {
    classes: [2][class_count]ClassAlloc = @splat(@splat(.{})),
    segments: ?*Segment = null,
    nsegments: usize = 0,
    /// Pages that hold no class, linked through `next`.
    free_pages: ?*Page = null,
    /// Large objects that survived a collection.
    large: std.ArrayList(*Header) = .empty,
    /// Large objects allocated since the last collection finished marking.
    large_young: std.ArrayList(*Header) = .empty,
    /// Large objects waiting for the sweep of the current collection.
    large_sweep: std.ArrayList(*Header) = .empty,
    /// Pages with `needs_sweep` set.
    pending_pages: usize = 0,
    /// The sweep step position.
    sweep_seg: ?*Segment = null,
    sweep_index: u8 = 1,
};

/// The page that holds a small object.
pub inline fn pageOf(h: *const Header) *Page {
    const a = @intFromPtr(h);
    const seg: *Segment = @ptrFromInt(a & ~@as(usize, segment_size - 1));
    return &seg.pages[(a / page_size) % pages_per_segment];
}

inline fn granuleOf(h: *const Header) u32 {
    return @intCast((@intFromPtr(h) % page_size) / granule);
}

pub inline fn isMarkedSmall(h: *const Header) bool {
    const p = pageOf(h);
    const gi = granuleOf(h);
    return (p.marks[gi / 64] >> @intCast(gi % 64)) & 1 != 0;
}

/// Sets the mark bit of a small object and returns true when it was
/// clear.
pub inline fn setMarkSmall(h: *const Header) bool {
    const p = pageOf(h);
    const gi = granuleOf(h);
    const bit = @as(u64, 1) << @intCast(gi % 64);
    const w = &p.marks[gi / 64];
    if (w.* & bit != 0) return false;
    w.* |= bit;
    return true;
}

// ---------------------------------------------------------------------
// Allocation

/// Returns an uninitialized cell for an object of `size` bytes, which is
/// at most `max_small`.
pub inline fn allocSmall(g: *Global, comptime kind: Kind, size: usize) Allocator.Error![*]u8 {
    const class = classFor(@max(size, @sizeOf(FreeCell)));
    const a = &g.heap.classes[@backingInt(kind)][class];
    const cell = classBytes(class);
    g.counter.bytes += cell;
    if (a.free) |c| {
        a.free = c.next;
        return @ptrCast(c);
    }
    if (a.bump + cell <= a.end) {
        const p = a.bump;
        a.bump = p + cell;
        return @ptrFromInt(p);
    }
    return refill(g, kind, class) catch |e| {
        g.counter.bytes -= cell;
        return e;
    };
}

/// Hands the remaining free cells of the allocation page back to it.
fn retire(a: *ClassAlloc) void {
    const p = a.page orelse return;
    p.free = a.free;
    p.top = @intCast(a.bump - p.base());
    p.current = false;
    a.page = null;
    a.free = null;
    a.bump = 0;
    a.end = 0;
}

fn install(a: *ClassAlloc, p: *Page) void {
    a.page = p;
    a.free = p.free;
    p.free = null;
    a.bump = p.base() + p.top;
    a.end = p.base() + p.usable;
    p.current = true;
    p.young = true;
}

fn refill(g: *Global, comptime kind: Kind, class: u8) Allocator.Error![*]u8 {
    const h = &g.heap;
    const a = &h.classes[@backingInt(kind)][class];
    retire(a);
    const cell = classBytes(class);
    while (a.cursor) |p| {
        a.cursor = p.next;
        if (p.needs_sweep) {
            sweepPage(g, p);
            if (!p.in_use) continue;
        }
        if (p.free != null or p.top + cell <= p.usable) {
            install(a, p);
            return take(a, cell);
        }
    }
    const p = try freshPage(g, kind, class);
    install(a, p);
    return take(a, cell);
}

inline fn take(a: *ClassAlloc, cell: u32) [*]u8 {
    if (a.free) |c| {
        a.free = c.next;
        return @ptrCast(c);
    }
    const p = a.bump;
    a.bump = p + cell;
    return @ptrFromInt(p);
}

fn freshPage(g: *Global, kind: Kind, class: u8) Allocator.Error!*Page {
    const h = &g.heap;
    if (h.free_pages == null) try newSegment(g);
    const p = h.free_pages.?;
    h.free_pages = p.next;
    const cell = classBytes(class);
    const index = p.index;
    p.* = .{
        .cell = cell,
        .usable = (page_size / cell) * cell,
        .class = class,
        .index = index,
        .kind = kind,
        .in_use = true,
        .young = true,
    };
    segmentOf(p).used += 1;
    const a = &h.classes[@backingInt(kind)][class];
    p.next = a.head;
    if (a.head) |n| n.prev = p;
    a.head = p;
    return p;
}

inline fn segmentOf(p: *Page) *Segment {
    return @ptrFromInt(@intFromPtr(p) & ~@as(usize, segment_size - 1));
}

fn newSegment(g: *Global) Allocator.Error!void {
    const h = &g.heap;
    const mem = g.parent_gpa.rawAlloc(segment_size, .fromByteUnits(segment_size), @returnAddress()) orelse return error.OutOfMemory;
    const seg: *Segment = @ptrCast(@alignCast(mem));
    seg.next = h.segments;
    seg.used = 0;
    h.segments = seg;
    h.nsegments += 1;
    var i: usize = pages_per_segment - 1;
    while (i >= 1) : (i -= 1) {
        seg.pages[i] = .{ .index = @intCast(i), .next = h.free_pages };
        h.free_pages = &seg.pages[i];
    }
    seg.pages[0] = .{};
}

/// Takes a page that holds no live object out of its class.
fn releasePage(g: *Global, p: *Page) void {
    const h = &g.heap;
    const a = &h.classes[@backingInt(p.kind)][p.class];
    if (a.cursor == p) a.cursor = p.next;
    if (p.prev) |q| q.next = p.next else a.head = p.next;
    if (p.next) |n| n.prev = p.prev;
    const index = p.index;
    p.* = .{ .index = index, .next = h.free_pages };
    h.free_pages = p;
    segmentOf(p).used -= 1;
}

/// Allocates a large object from the backing allocator.
pub fn allocLarge(g: *Global, size: usize) Allocator.Error![*]u8 {
    const mem = g.gpa.rawAlloc(size, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    g.heap.large_young.append(g.gpa, @ptrCast(@alignCast(mem))) catch {
        g.gpa.rawFree(mem[0..size], .@"16", @returnAddress());
        return error.OutOfMemory;
    };
    return mem;
}

pub fn freeLarge(g: *Global, h: *Header) void {
    const size = gc.objectSize(h);
    const base: [*]u8 = @ptrCast(h);
    g.gpa.rawFree(base[0..size], .@"16", @returnAddress());
}

/// Returns the remaining free cells of every allocation page to their
/// pages, so that a sweep sees every page complete.
pub fn retireAll(g: *Global) void {
    for (&g.heap.classes) |*kind| {
        for (kind) |*a| retire(a);
    }
}

// ---------------------------------------------------------------------
// Sweeping

/// Frees the unmarked objects of a page and rebuilds its free list in
/// address order. A page left without live objects goes back to the
/// pool of free pages.
pub fn sweepPage(g: *Global, p: *Page) void {
    std.debug.assert(p.needs_sweep and !p.current);
    p.needs_sweep = false;
    g.heap.pending_pages -= 1;
    const base = p.base();
    const masks = &start_masks[p.class];
    const top_granule = p.top / granule;
    var head: ?*FreeCell = null;
    var tail: *?*FreeCell = &head;
    var live: u32 = 0;
    var freed: u32 = 0;
    for (0..bitmap_words) |w| {
        const lo = w * 64;
        if (lo >= top_granule) break;
        const below: u64 = if (top_granule >= lo + 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(top_granule - lo)) - 1;
        const starts = masks[w] & below;
        live += @popCount(p.marks[w] & starts);
        var dead = starts & ~p.marks[w];
        while (dead != 0) {
            const bit = @ctz(dead);
            dead &= dead - 1;
            const cell: *FreeCell = @ptrFromInt(base + (lo + bit) * granule);
            if (!cell.hdr.flags.free) {
                gc.releaseObject(g, &cell.hdr);
                // Safe builds poison dead cells, so a use after free shows
                // up as garbage instead of a plausible object.
                if (std.debug.runtime_safety) {
                    const bytes: [*]u8 = @ptrCast(cell);
                    @memset(bytes[@sizeOf(FreeCell)..p.cell], 0xAA);
                }
                cell.hdr.flags = .{ .free = true };
                freed += 1;
            }
            tail.* = cell;
            tail = &cell.next;
        }
    }
    tail.* = null;
    g.counter.bytes -|= @as(usize, freed) * p.cell;
    if (live == 0) {
        releasePage(g, p);
    } else {
        p.free = head;
    }
}

/// Marks pages for sweeping after a collection finished marking. A major
/// collection sweeps every page. A minor collection sweeps the pages that
/// received objects since the previous collection, since every other
/// page holds only old objects.
pub fn startSweep(g: *Global, major: bool) void {
    const h = &g.heap;
    retireAll(g);
    var seg = h.segments;
    while (seg) |s| : (seg = s.next) {
        for (s.pages[1..]) |*p| {
            if (!p.in_use) continue;
            if (major or p.young) {
                if (!p.needs_sweep) h.pending_pages += 1;
                p.needs_sweep = true;
            }
            p.young = false;
        }
    }
    for (&h.classes) |*kind| {
        for (kind) |*a| a.cursor = a.head;
    }
    h.sweep_seg = h.segments;
    h.sweep_index = 1;
}

/// Sweeps pages until `budget` bytes of pages were swept. Returns true
/// when no page waits for a sweep.
pub fn sweepSome(g: *Global, budget: usize) bool {
    const h = &g.heap;
    var done: usize = 0;
    while (h.pending_pages > 0) {
        const s = h.sweep_seg orelse break;
        if (h.sweep_index >= pages_per_segment) {
            h.sweep_seg = s.next;
            h.sweep_index = 1;
            continue;
        }
        const p = &s.pages[h.sweep_index];
        h.sweep_index += 1;
        if (!p.needs_sweep) continue;
        sweepPage(g, p);
        done += page_size;
        if (done >= budget) return h.pending_pages == 0;
    }
    std.debug.assert(h.pending_pages == 0);
    return true;
}

/// Clears every mark bit, so a major collection starts with every object
/// white.
pub fn clearMarks(g: *Global) void {
    var seg = g.heap.segments;
    while (seg) |s| : (seg = s.next) {
        for (s.pages[1..]) |*p| {
            if (p.in_use) p.marks = @splat(0);
        }
    }
    for (g.heap.large.items) |o| o.flags.mark = false;
    for (g.heap.large_young.items) |o| o.flags.mark = false;
}

/// Frees segments whose pages are all free, keeping one in reserve, and
/// rebuilds the pool of free pages from the segments that remain.
pub fn releaseSegments(g: *Global) void {
    const h = &g.heap;
    var kept_empty = false;
    var link: *?*Segment = &h.segments;
    h.free_pages = null;
    while (link.*) |s| {
        if (s.used == 0 and kept_empty) {
            link.* = s.next;
            h.nsegments -= 1;
            const mem: [*]u8 = @ptrCast(s);
            g.parent_gpa.rawFree(mem[0..segment_size], .fromByteUnits(segment_size), @returnAddress());
            continue;
        }
        if (s.used == 0) kept_empty = true;
        var i: usize = pages_per_segment - 1;
        while (i >= 1) : (i -= 1) {
            const p = &s.pages[i];
            if (!p.in_use) {
                p.next = h.free_pages;
                h.free_pages = p;
            }
        }
        link = &s.next;
    }
    h.sweep_seg = null;
}

// ---------------------------------------------------------------------
// Iteration

/// Calls `f(ctx, h)` for every allocated object, small and large.
pub fn forEachObject(g: *Global, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Header) void) void {
    retireAll(g);
    var seg = g.heap.segments;
    while (seg) |s| : (seg = s.next) {
        for (s.pages[1..]) |*p| {
            if (!p.in_use) continue;
            var off: usize = 0;
            while (off + p.cell <= p.top) : (off += p.cell) {
                const h: *Header = @ptrFromInt(p.base() + off);
                if (!h.flags.free) f(ctx, h);
            }
        }
    }
    for (g.heap.large.items) |o| f(ctx, o);
    for (g.heap.large_young.items) |o| f(ctx, o);
    for (g.heap.large_sweep.items) |o| f(ctx, o);
}

/// Frees every object and every segment. Used when a state closes.
pub fn freeAll(g: *Global) void {
    const h = &g.heap;
    forEachObject(g, g, struct {
        fn f(gg: *Global, o: *Header) void {
            gc.releaseObject(gg, o);
        }
    }.f);
    for (h.large.items) |o| freeLarge(g, o);
    for (h.large_young.items) |o| freeLarge(g, o);
    for (h.large_sweep.items) |o| freeLarge(g, o);
    h.large.deinit(g.gpa);
    h.large_young.deinit(g.gpa);
    h.large_sweep.deinit(g.gpa);
    var seg = h.segments;
    while (seg) |s| {
        seg = s.next;
        const mem: [*]u8 = @ptrCast(s);
        g.parent_gpa.rawFree(mem[0..segment_size], .fromByteUnits(segment_size), @returnAddress());
    }
    h.* = .{};
}

test "size classes cover every small size" {
    var size: usize = 1;
    while (size <= max_small) : (size += 1) {
        const c = classFor(size);
        try std.testing.expect(classBytes(c) >= size);
        if (c > 0) try std.testing.expect(classBytes(c - 1) < size);
    }
}
