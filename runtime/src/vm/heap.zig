//! The object heap. Small objects live in 16 KB pages carved out of
//! 1 MB aligned segments. Every page holds cells of one size class, and
//! every size class is a multiple of 8 bytes. A page also holds objects
//! of one kind: scanned objects, which the marker traces, or leaf objects
//! (strings, bigints, decimals, vector headers), which it only marks.
//! Objects larger than the biggest class come straight from the backing
//! allocator and are kept in a list.
//!
//! The first page of every segment holds the metadata of the other
//! sixty-three: a mark bitmap with one bit per 16-byte granule, the free
//! list, and the bump limit. A fresh page bump-allocates. A swept page allocates
//! from a free list rebuilt from its mark bitmap. Pages are swept lazily,
//! one at a time, when the allocator reaches them, or by collector steps.
//! Sweeping uses whole bitmap words, so a run of 64 live granules costs
//! one test.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const state_mod = @import("state.zig");
const Header = gc.Header;
const Global = state_mod.Global;
const Allocator = std.mem.Allocator;
const inv = @import("inv.zig");

/// A segment spends its first page on the metadata of the others, a
/// whole 16 KB page on systems with pages of that size, so segments of
/// 1 MB spend 1.6 percent of the heap on it where segments of 256 KB
/// spent 6.25.
pub const segment_size = 1024 * 1024;
pub const page_size = 16 * 1024;
pub const pages_per_segment = segment_size / page_size;
pub const granule = 16;
pub const max_small = 2048;
const granules_per_page = page_size / granule;
pub const bitmap_words = granules_per_page / 64;

/// The step between the small size classes: the alignment of an object
/// header, 8 bytes on 64-bit targets and 16 on 32-bit ones. Cells start
/// on such boundaries, and no cell is smaller than a granule, so the cell
/// that starts in a granule is the only one there.
pub const class_step = @alignOf(Header);

/// Size classes in bytes: every step up to 256, which holds short strings
/// and small records with their hash parts exactly, then classes that
/// grow by a quarter, which bounds internal fragmentation by 20 percent.
pub const class_sizes = blk: {
    const steps = (256 - 16) / class_step + 1;
    var t: [steps + 12]u16 = undefined;
    for (0..steps) |i| t[i] = 16 + class_step * i;
    for (.{ 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048 }, steps..) |b, i| t[i] = b;
    break :blk t;
};

comptime {
    std.debug.assert(class_step == 8 or class_step == granule);
}
pub const class_count = class_sizes.len;

const class_of_steps: [max_small / class_step + 1]u8 = blk: {
    var t: [max_small / class_step + 1]u8 = undefined;
    var c: usize = 0;
    for (0..t.len) |n| {
        while (class_sizes[c] < n * class_step) c += 1;
        t[n] = c;
    }
    break :blk t;
};

pub inline fn classFor(size: usize) u8 {
    return class_of_steps[(size + class_step - 1) / class_step];
}

pub inline fn classBytes(class: u8) u32 {
    return class_sizes[class];
}

/// For each class, the bitmap bits of the granules where cells start.
const start_masks: [class_count][bitmap_words]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [class_count][bitmap_words]u64 = undefined;
    for (class_sizes, 0..) |cb, c| {
        var m: [bitmap_words]u64 = @splat(0);
        const ncells = page_size / cb;
        for (0..ncells) |i| {
            const gi = i * cb / granule;
            m[gi / 64] |= @as(u64, 1) << @intCast(gi % 64);
        }
        t[c] = m;
    }
    break :blk t;
};

/// For each class, the bits of the granules whose cell starts 8 bytes
/// into the granule. Only classes that are not a multiple of the
/// granule have any.
const half_masks: [class_count][bitmap_words]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [class_count][bitmap_words]u64 = undefined;
    for (class_sizes, 0..) |cb, c| {
        var m: [bitmap_words]u64 = @splat(0);
        const ncells = page_size / cb;
        for (0..ncells) |i| {
            const off = i * cb;
            if (off % granule != 0) {
                const gi = off / granule;
                m[gi / 64] |= @as(u64, 1) << @intCast(gi % 64);
            }
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
    /// The start of the block the backing allocator returned, which is
    /// the segment itself unless the segment was carved from a larger
    /// block (`over_allocate`).
    block: [*]u8,
    /// Pages of this segment that hold a size class.
    used: u8,
};

/// Whether segments are carved from a larger block with page alignment
/// instead of requested at segment alignment. On Windows the page
/// allocator of the standard library meets an alignment above the 64 KB
/// allocation granularity of the system only when the system happens to
/// place the block there, and fails with OutOfMemory otherwise. A block
/// of twice the segment size less one page holds an aligned segment
/// wherever it starts, and the heap never touches the pages around it.
const over_allocate = builtin.os.tag == .windows;
const block_align: std.mem.Alignment = if (over_allocate) .fromByteUnits(std.heap.page_size_min) else .fromByteUnits(segment_size);
const block_size = if (over_allocate) 2 * segment_size - std.heap.page_size_min else segment_size;

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
    /// Bytes of the small cells that hold objects, kept only by a checking
    /// build, which compares the count with the pages (`bytesOk`).
    small_bytes: usize = 0,
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

/// `isMarkedSmall` for parallel markers.
pub inline fn isMarkedSmallAtomic(h: *const Header) bool {
    const p = pageOf(h);
    const gi = granuleOf(h);
    const m = markWord(&p.marks[gi / 64], gi % 64);
    return (@atomicLoad(MarkWord, m.word, .monotonic) >> m.shift) & 1 != 0;
}

/// `setMarkSmall` for parallel markers. Exactly one of the threads that
/// mark an object at once gets true.
pub inline fn setMarkSmallAtomic(h: *const Header) bool {
    const p = pageOf(h);
    const gi = granuleOf(h);
    const m = markWord(&p.marks[gi / 64], gi % 64);
    const bit = @as(MarkWord, 1) << m.shift;
    if (@atomicLoad(MarkWord, m.word, .monotonic) & bit != 0) return false;
    return @atomicRmw(MarkWord, m.word, .Or, bit, .monotonic) & bit == 0;
}

/// The word that the parallel markers update atomically: the 64-bit word
/// of the bitmap on a 64-bit target, and the half of it that holds the
/// bit on a 32-bit target, which has no 64-bit atomic operations.
const MarkWord = usize;
const MarkBit = struct { word: *MarkWord, shift: std.math.Log2Int(MarkWord) };
inline fn markWord(w: *u64, bit: usize) MarkBit {
    if (@sizeOf(MarkWord) == 8) return .{ .word = @ptrCast(w), .shift = @intCast(bit) };
    comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    const halves: *[2]MarkWord = @ptrCast(w);
    return .{ .word = &halves[bit / 32], .shift = @intCast(bit % 32) };
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
    if (inv.enabled) g.heap.small_bytes += cell;
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
        if (inv.enabled) g.heap.small_bytes -= cell;
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

/// The most waiting pages a refill sweeps before it takes a fresh page.
/// A fresh page stays in the heap until every object on it dies, so a
/// refill that gave up early grew the heap of a program whose objects
/// die one by one while pages full of free cells waited for a sweep. A
/// page of dead strings sweeps in about 12 microseconds, since each cell
/// frees its body, so the budget keeps a refill under half a millisecond.
const max_refill_sweeps = 32;

fn refill(g: *Global, comptime kind: Kind, class: u8) Allocator.Error![*]u8 {
    const h = &g.heap;
    const a = &h.classes[@backingInt(kind)][class];
    retire(a);
    const cell = classBytes(class);
    // A run of full pages is left to the collector steps once the budget
    // is spent, so one allocation never sweeps a large part of the heap.
    var swept: u32 = 0;
    while (a.cursor) |p| {
        if (p.needs_sweep) {
            if (swept == max_refill_sweeps) break;
            swept += 1;
            a.cursor = p.next;
            sweepPage(g, p);
            if (!p.in_use) continue;
        } else a.cursor = p.next;
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
    if (@import("heapcount.zig").inject.fail()) return error.OutOfMemory;
    const block = g.parent_gpa.rawAlloc(block_size, block_align, @returnAddress()) orelse return error.OutOfMemory;
    const start = std.mem.alignForward(usize, @intFromPtr(block), segment_size);
    const seg: *Segment = @ptrFromInt(start);
    seg.block = block;
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

/// The alignment of large objects, which every object header needs. On
/// 64-bit targets it stays within what `malloc` guarantees, so the C
/// allocator serves large objects with plain `malloc` and can grow a
/// block with `realloc` (`state.StringBuffer`).
pub const large_align: std.mem.Alignment = .of(Header);

/// Allocates a large object from the backing allocator.
pub fn allocLarge(g: *Global, size: usize) Allocator.Error![*]u8 {
    const mem = g.gpa.rawAlloc(size, large_align, @returnAddress()) orelse return error.OutOfMemory;
    g.heap.large_young.append(g.gpa, @ptrCast(@alignCast(mem))) catch {
        g.gpa.rawFree(mem[0..size], large_align, @returnAddress());
        return error.OutOfMemory;
    };
    return mem;
}

/// Records a block of the backing allocator that becomes a large object
/// in place. The caller still owns the block when this fails.
pub fn adoptLarge(g: *Global, mem: [*]u8) Allocator.Error!void {
    try g.heap.large_young.append(g.gpa, @ptrCast(@alignCast(mem)));
}

pub fn freeLarge(g: *Global, h: *Header) void {
    const size = gc.objectSize(h);
    const base: [*]u8 = @ptrCast(h);
    g.gpa.rawFree(base[0..size], large_align, @returnAddress());
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
    const before = g.counter.bytes;
    defer {
        // The steps of the sweep follow what the program allocates. A
        // refill that frees cells lowers the heap count, and the next
        // step comes sooner by as much, so the bytes the sweep has yet
        // to free wait no longer than one step of allocation.
        const freed_bytes = before -| g.counter.bytes;
        g.gcs.swept += freed_bytes;
        g.gcs.next_check -|= freed_bytes;
    }
    const base = p.base();
    const masks = &start_masks[p.class];
    const halves = &half_masks[p.class];
    // The granule after the one where the last allocated cell starts.
    const top_granule = if (p.top == 0) 0 else (p.top - p.cell) / granule + 1;
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
            const half: usize = @intCast((halves[w] >> @intCast(bit)) & 1);
            const cell: *FreeCell = @ptrFromInt(base + (lo + bit) * granule + half * class_step);
            if (!cell.hdr.flags.free) {
                if (gc.needsRelease(&cell.hdr)) gc.releaseObject(g, &cell.hdr);
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
    if (inv.enabled) g.heap.small_bytes -= @as(usize, freed) * p.cell;
    if (live == 0) {
        releasePage(g, p);
    } else {
        p.free = head;
        if (inv.enabled) inv.assert(pageOk(p, p.free, p.top) != null);
    }
}

/// Checks a page that holds a size class: its cell size, its usable bytes
/// and its top agree with the class, marks sit only where cells start,
/// and the free list stays below the top, on cell boundaries, on cells
/// flagged free that are not marked, and without a cycle. Returns the
/// number of free cells, or null when a check fails. `free` and `top` are
/// those of the allocation state while the page allocates.
pub fn pageOk(p: *const Page, free: ?*FreeCell, top: usize) ?usize {
    if (p.class >= class_count or p.cell != classBytes(p.class)) return null;
    if (p.usable != page_size / p.cell * p.cell) return null;
    if (top > p.usable or top % p.cell != 0) return null;
    for (p.marks, start_masks[p.class]) |m, s| if (m & ~s != 0) return null;
    const base = p.base();
    const limit = top / p.cell;
    var n: usize = 0;
    var c = free;
    while (c) |cell| : (c = cell.next) {
        const at = @intFromPtr(cell);
        if (at < base or at >= base + top or (at - base) % p.cell != 0) return null;
        if (!cell.hdr.flags.free or isMarkedSmall(&cell.hdr)) return null;
        n += 1;
        if (n > limit) return null;
    }
    return n;
}

/// Whether the bytes of the cells that hold objects, counted page by page
/// from the tops and the free lists, match the running count.
pub fn bytesOk(g: *Global) bool {
    const h = &g.heap;
    var total: usize = 0;
    var seg = h.segments;
    while (seg) |s| : (seg = s.next) {
        for (s.pages[1..]) |*p| {
            if (!p.in_use) continue;
            var free = p.free;
            var top: usize = p.top;
            if (p.current) {
                const a = &h.classes[@backingInt(p.kind)][p.class];
                free = a.free;
                top = a.bump - p.base();
            }
            const nfree = pageOk(p, free, top) orelse return false;
            total += (top / p.cell - nfree) * p.cell;
        }
    }
    return total == h.small_bytes;
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
            freeSegment(g, s);
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
        freeSegment(g, s);
    }
    h.* = .{};
}

fn freeSegment(g: *Global, s: *Segment) void {
    g.parent_gpa.rawFree(s.block[0..block_size], block_align, @returnAddress());
}

test "size classes cover every small size" {
    var size: usize = 1;
    while (size <= max_small) : (size += 1) {
        const c = classFor(size);
        try std.testing.expect(classBytes(c) >= size);
        if (c > 0) try std.testing.expect(classBytes(c - 1) < size);
    }
}
