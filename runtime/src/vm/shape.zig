//! Shapes: the shared key lists of tables whose hash parts hold only
//! short string keys (`spec/design/tables.md`, Shapes).
//!
//! A shape is an ordered list of interned strings. A shaped table keeps
//! the value of key i of its shape in its slot i, so tables with the same
//! keys share one key list. Shapes form a tree: the root has no keys, and
//! each child adds one key to its parent. Shapes are never freed while
//! their state lives. Their ids come from a registry that every state of
//! the process shares, so that a table names its shape with 16 bits and
//! finds it without its state, and a state that closes returns its ids.

const std = @import("std");
const inv = @import("inv.zig");
const object = @import("object.zig");
const String = object.String;
const Allocator = std.mem.Allocator;

/// The bit of `Table.hash_used` that marks a shaped table, which the word
/// of the root is, its id being zero.
pub const shaped_word: u32 = 1 << 31;

/// The most keys a shape holds.
pub const max_keys = 32;
/// The most children a shape has.
pub const max_children = 32;
/// The most shapes in the registry. Ids run below it, and 0xFFFF stays
/// free for the inline caches, which use it for no prediction.
pub const max_shapes = 0xFFFE;
/// Shapes of up to this many keys find a key by scanning them.
const scan_max = 8;

/// Whether a new shape extends its parent by one key, holds distinct keys,
/// and finds each key in its own slot.
fn wellFormed(s: *const Shape) bool {
    const p = s.parent orelse return s.n == 0;
    if (s.n != p.n + 1) return false;
    for (0..p.n) |i| if (s.keys[i] != p.keys[i]) return false;
    for (0..s.n) |i| if (s.findText(s.keys[i]) != i) return false;
    return true;
}

pub const Shape = struct {
    id: u16,
    /// What `Table.hash_used` holds for a table of this shape: the bit
    /// that marks a shaped table, with the id. Code compiled ahead of
    /// time reads it from here, since an id belongs to one process.
    word: u32 = shaped_word,
    /// Number of keys.
    n: u8,
    nchildren: u8 = 0,
    /// One less than the number of entries of `index`, or zero for a
    /// shape that scans its keys.
    index_mask: u16 = 0,
    parent: ?*Shape,
    first_child: ?*Shape = null,
    next_sibling: ?*Shape = null,
    /// The keys, in slot order.
    keys: [*]*String,
    /// Open addressing over the keys by hash: each entry is a slot plus
    /// one, or zero for an empty entry.
    index: [*]u8,

    /// The slot of the interned string `key`, or null.
    pub inline fn find(s: *const Shape, key: *const String) ?usize {
        if (s.index_mask == 0) {
            for (s.keys[0..s.n], 0..) |k, i| if (k == key) return i;
            return null;
        }
        var h: usize = key.hash & s.index_mask;
        while (true) : (h = (h + 1) & s.index_mask) {
            const e = s.index[h];
            if (e == 0) return null;
            if (s.keys[e - 1] == key) return e - 1;
        }
    }

    /// The slot of a string with the text of `key`, interned or not.
    pub fn findText(s: *const Shape, key: *const String) ?usize {
        if (key.flags().interned) return s.find(key);
        for (s.keys[0..s.n], 0..) |k, i| {
            if (k.hash == key.hash and k.len == key.len and std.mem.eql(u8, k.bytes(), key.bytes())) return i;
        }
        return null;
    }

    pub fn keyAt(s: *const Shape, i: usize) *String {
        return s.keys[i];
    }
};

// ---------------------------------------------------------------------
// Registry

/// The shape without keys, id 0, which every new table of every state
/// starts with. It holds no key of any heap, so the states share it, and
/// each state keeps the children of the root in its own `Shapes`.
pub var root: Shape = .{ .id = 0, .n = 0, .parent = null, .keys = undefined, .index = undefined };

/// Every live shape by id. The table starts zeroed, so it costs no space
/// in the executable, and `prepare` enters the root.
var registry: [max_shapes]?*Shape = @splat(null);
var registry_lock: std.atomic.Mutex = .unlocked;
/// The lowest id that was never handed out.
var next_fresh: u32 = 1;
/// Ids that closed states returned, linked through `free_next`.
var free_head: u32 = no_id;
var free_next: [max_shapes]u16 = undefined;
const no_id: u32 = 0xFFFF_FFFF;

/// The shape with id `id`.
pub inline fn get(id: u16) *Shape {
    return registry[id].?;
}

/// Whether the root is in the registry.
var prepared: std.atomic.Value(bool) = .init(false);

/// Enters the root in the registry, once for the process. Every state
/// calls it when it is created, before it makes a table. A state made
/// later on another thread finds the root entered and writes nothing, so
/// it never races with a thread that reads the registry.
pub fn prepare() void {
    if (prepared.load(.acquire)) return;
    lock();
    defer registry_lock.unlock();
    if (prepared.load(.monotonic)) return;
    registry[0] = &root;
    prepared.store(true, .release);
}

fn lock() void {
    while (!registry_lock.tryLock()) std.atomic.spinLoopHint();
}

fn takeId(s: *Shape) ?u16 {
    lock();
    defer registry_lock.unlock();
    var id: u32 = undefined;
    if (free_head != no_id) {
        id = free_head;
        const n = free_next[id];
        free_head = if (n == 0xFFFF) no_id else n;
    } else if (next_fresh < max_shapes) {
        id = next_fresh;
        next_fresh += 1;
    } else return null;
    registry[id] = s;
    return @intCast(id);
}

fn releaseId(id: u16) void {
    lock();
    defer registry_lock.unlock();
    registry[id] = null;
    free_next[id] = if (free_head == no_id) 0xFFFF else @intCast(free_head);
    free_head = id;
}

// ---------------------------------------------------------------------
// The shapes of a state

pub const Shapes = struct {
    /// The children of the root in this state.
    root_first: ?*Shape = null,
    root_children: u16 = 0,
    /// Every shape of the state, for `deinit`.
    all: std.ArrayList(*Shape) = .empty,
    /// Set by `deinit`, the only place that gives an id back.
    closing: bool = false,

    /// The most children of the root in one state, one for each first key
    /// of the records of a program.
    const max_root_children = 256;

    pub fn deinit(sh: *Shapes, gpa: Allocator) void {
        // Native code and inline caches compare a table with a shape by
        // its id alone, which holds because a state gives no id back
        // while it lives.
        sh.closing = true;
        for (sh.all.items) |s| {
            inv.assert(sh.closing);
            releaseId(s.id);
            freeShape(gpa, s);
        }
        sh.all.deinit(gpa);
        sh.root_first = null;
        sh.root_children = 0;
    }

    /// The child of `s` that adds the interned string `key`, made when it
    /// does not exist yet. Returns null when a limit forbids it, and the
    /// table that asked becomes a dictionary. `state.pinKey` keeps a new key
    /// alive for as long as the state lives.
    pub fn transition(sh: *Shapes, gpa: Allocator, s: *Shape, key: *String, pin: anytype) Allocator.Error!?*Shape {
        const is_root = s == &root;
        var c = if (is_root) sh.root_first else s.first_child;
        while (c) |ch| : (c = ch.next_sibling) {
            if (ch.keys[ch.n - 1] == key) return ch;
        }
        if (s.n >= max_keys) return null;
        if (if (is_root) sh.root_children >= max_root_children else s.nchildren >= max_children) return null;
        if (!key.flags().shape_key) {
            try @import("state.zig").pinKey(pin, key);
            key.flags().shape_key = true;
        }
        const n = (try sh.newShape(gpa, s, key)) orelse return null;
        if (is_root) {
            n.next_sibling = sh.root_first;
            sh.root_first = n;
            sh.root_children += 1;
        } else {
            n.next_sibling = s.first_child;
            s.first_child = n;
            s.nchildren += 1;
        }
        return n;
    }

    fn newShape(sh: *Shapes, gpa: Allocator, parent: *Shape, key: *String) Allocator.Error!?*Shape {
        const n: usize = parent.n + 1;
        const isize_: usize = if (n > scan_max) std.math.ceilPowerOfTwoAssert(usize, 2 * n) else 0;
        const keys = try gpa.alloc(*String, n);
        errdefer gpa.free(keys);
        const index = try gpa.alloc(u8, isize_);
        errdefer gpa.free(index);
        const s = try gpa.create(Shape);
        errdefer gpa.destroy(s);
        try sh.all.ensureUnusedCapacity(gpa, 1);
        @memcpy(keys[0 .. n - 1], parent.keys[0 .. n - 1]);
        keys[n - 1] = key;
        @memset(index, 0);
        s.* = .{
            .id = 0,
            .n = @intCast(n),
            .index_mask = if (isize_ > 0) @intCast(isize_ - 1) else 0,
            .parent = parent,
            .keys = keys.ptr,
            .index = index.ptr,
        };
        if (isize_ > 0) {
            for (keys, 0..) |k, i| {
                var h: usize = k.hash & s.index_mask;
                while (index[h] != 0) h = (h + 1) & s.index_mask;
                index[h] = @intCast(i + 1);
            }
        }
        s.id = takeId(s) orelse {
            gpa.destroy(s);
            gpa.free(index);
            gpa.free(keys);
            return null;
        };
        s.word = shaped_word | @as(u32, s.id);
        sh.all.appendAssumeCapacity(s);
        if (inv.deep) inv.assert(wellFormed(s));
        return s;
    }

    fn freeShape(gpa: Allocator, s: *Shape) void {
        gpa.free(s.keys[0..s.n]);
        gpa.free(s.index[0..if (s.index_mask == 0) 0 else @as(usize, s.index_mask) + 1]);
        gpa.destroy(s);
    }
};
