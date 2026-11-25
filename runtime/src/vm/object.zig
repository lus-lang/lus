//! Heap object layouts. Every object begins with `gc.Header`, and the
//! collector dispatches on the header tag to trace and free them.

const std = @import("std");
const inv = @import("inv.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const wtf8 = @import("wtf8.zig");
const Value = value.Value;
const Header = gc.Header;
const Blob = @import("blob.zig").Blob;

// ---------------------------------------------------------------------
// Strings

/// A string takes a 16-byte header on 64-bit targets: the object header,
/// whose spare bytes hold the flags of the string (`spare8`) and its
/// count of characters (`spare32`), then its length in bytes and its
/// hash. The bytes follow, with a terminating zero. A string that may
/// need breadcrumbs keeps a pointer to them in a slot after its bytes
/// (`crumbSlot`).
pub const String = struct {
    hdr: Header,
    len: u32,
    hash: u32,

    pub const Flags = packed struct(u8) {
        ascii: bool = false,
        interned: bool = false,
        /// The cell holds a pointer to a shared blob in place of the
        /// bytes (`blob.zig`).
        shared: bool = false,
        /// The string keeps its own bytes and has a blob in the cache of
        /// its heap, made when it was first sent to a worker.
        cached: bool = false,
        /// The string was sent to a worker once without being cached.
        sent: bool = false,
        /// The cell has a slot for the pointer to breadcrumbs.
        crumb_slot: bool = false,
        /// Some shape holds the string as a key, so the state keeps it
        /// alive (`shape.zig`).
        shape_key: bool = false,
        _pad: u1 = 0,
    };

    /// The flags of the string, in the spare byte of its header.
    pub inline fn flags(s: *const String) *Flags {
        return @ptrCast(@constCast(&s.hdr.spare8));
    }
    /// The byte offset of the count of characters, which native code
    /// reads as 32 bits.
    pub const chars_offset = @offsetOf(String, "hdr") + @offsetOf(Header, "spare32");
    /// The byte offset of the flags, which native code tests bit by bit.
    pub const flags_offset = @offsetOf(String, "hdr") + @offsetOf(Header, "spare8");
    /// The number of characters, in the spare word of the header.
    pub inline fn chars(s: *const String) u32 {
        return s.hdr.spare32;
    }
    pub inline fn setChars(s: *String, n: usize) void {
        s.hdr.spare32 = @intCast(n);
    }
    /// True when a string with these contents may build breadcrumbs,
    /// which only non-ASCII strings of more than `crumb_step` characters
    /// do.
    pub inline fn needsCrumbs(ascii: bool, n: usize) bool {
        return !ascii and n > crumb_step;
    }
    /// The slot for the pointer to the breadcrumbs, after the bytes of
    /// the string, or after the pointer to its blob.
    inline fn crumbSlot(s: *const String) ?*?[*]u32 {
        if (!s.flags().crumb_slot) return null;
        const base: [*]u8 = @ptrCast(@constCast(s));
        const off = if (s.flags().shared) @sizeOf(String) + @sizeOf(*Blob) else std.mem.alignForward(usize, @sizeOf(String) + s.len + 1, @alignOf(usize));
        return @ptrCast(@alignCast(base + off));
    }
    /// The breadcrumbs, when they were built.
    pub inline fn crumbs(s: *const String) ?[*]u32 {
        const slot = s.crumbSlot() orelse return null;
        return slot.*;
    }
    /// Clears the breadcrumb slot of a new string.
    pub inline fn initCrumbs(s: *String) void {
        if (s.crumbSlot()) |slot| slot.* = null;
    }

    comptime {
        std.debug.assert(@sizeOf(usize) != 8 or @sizeOf(String) == 16);
    }

    pub const short_max = 40;
    /// The longest string in bytes, the most that `len` holds.
    pub const max_len: usize = std.math.maxInt(u32);
    pub const crumb_step = 64;
    /// The cell size of a shared string.
    pub const shared_size = @sizeOf(String) + @sizeOf(*Blob);

    pub inline fn bytes(s: *const String) []const u8 {
        if (s.flags().shared) {
            @branchHint(.unlikely);
            return s.blob().bytes();
        }
        const base: [*]const u8 = @ptrCast(s);
        return (base + @sizeOf(String))[0..s.len];
    }
    pub inline fn bytesMut(s: *String) []u8 {
        inv.assert(!s.flags().shared);
        const base: [*]u8 = @ptrCast(s);
        return (base + @sizeOf(String))[0..s.len];
    }
    pub inline fn allocSize(len: usize) usize {
        return @sizeOf(String) + len + 1;
    }
    /// The size of a cell of `len` bytes with a breadcrumb slot when
    /// `slot` is set.
    pub inline fn allocSizeWith(len: usize, slot: bool) usize {
        if (!slot) return allocSize(len);
        return std.mem.alignForward(usize, allocSize(len), @alignOf(usize)) + @sizeOf(usize);
    }
    /// The size of the cell of `s`.
    pub inline fn cellSize(s: *const String) usize {
        const slot: usize = if (s.flags().crumb_slot) @sizeOf(usize) else 0;
        return if (s.flags().shared) shared_size + slot else allocSizeWith(s.len, s.flags().crumb_slot);
    }
    /// The blob of a shared string.
    pub inline fn blob(s: *const String) *Blob {
        const base: [*]const u8 = @ptrCast(s);
        const slot: *const *Blob = @ptrCast(@alignCast(base + @sizeOf(String)));
        return slot.*;
    }
    pub inline fn setBlob(s: *String, b: *Blob) void {
        const base: [*]u8 = @ptrCast(s);
        const slot: **Blob = @ptrCast(@alignCast(base + @sizeOf(String)));
        slot.* = b;
    }

    /// Byte offset of the character at zero-based index `ci`. `ci` may equal
    /// `chars`, which yields `len`. A long non-ASCII string starts from the
    /// nearest breadcrumb at or before `ci`, or from a position an earlier
    /// call found when that lies between the breadcrumb and `ci`, and skips
    /// the remaining characters with the vectorized `wtf8.advance`. The
    /// remembered positions make a scan that moves forward through a
    /// string cost the distance it moves.
    pub inline fn byteOffset(s: *String, gpa: *const std.mem.Allocator, ci: usize) usize {
        if (s.flags().ascii or ci == 0) return ci;
        if (ci >= s.chars()) return s.len;
        if (s.chars() <= crumb_step) return wtf8.advance(s.bytes(), 0, ci);
        const cr = s.crumbs() orelse return s.firstOffset(gpa, ci);
        // A range that starts a few characters after the last one, as
        // every step of a scan through a string does, is found from
        // where that one started, with no look at the breadcrumbs.
        const n = crumbCount(s.chars());
        const ahead = ci -% cr[n];
        if (ahead < near) {
            const off = wtf8.advance(s.bytes(), cr[n + 1], ahead);
            cr[n] = @intCast(ci);
            cr[n + 1] = @intCast(off);
            return off;
        }
        return s.crumbOffset(cr, ci, 0, 0, 0);
    }

    /// How many characters past a remembered position `byteOffset` looks
    /// before it asks the breadcrumbs. `wtf8.advance` scans that far
    /// inline.
    const near = 16;

    /// The byte offset of the character `ci` that ends a range, given
    /// that the character `from_ci` at or before it starts at byte
    /// `from_off`. A range that moves through a string, as a window
    /// `s:sub(i, i + 8)` does, finds its end from where the previous end
    /// was, which `byteOffset` remembers apart from where ranges start.
    pub inline fn endOffset(s: *String, ci: usize, from_ci: usize, from_off: usize) usize {
        if (s.flags().ascii) return ci;
        if (ci >= s.chars()) return s.len;
        const cr = s.crumbs() orelse return wtf8.advance(s.bytes(), from_off, ci - from_ci);
        // The previous end, when it lies between the start and `ci`, is
        // where the scan starts. Choosing it by a branch keeps the scan
        // from waiting for the offset of the start.
        const n = crumbCount(s.chars());
        const last = cr[n + 2];
        if (last >= from_ci and last <= ci) {
            const off = wtf8.advance(s.bytes(), cr[n + 3], ci - last);
            cr[n + 2] = @intCast(ci);
            cr[n + 3] = @intCast(off);
            return off;
        }
        return s.crumbOffset(cr, ci, 1, from_ci, from_off);
    }

    /// The offset of character `ci` through the breadcrumbs `cr`. The
    /// scan starts from the closest known position at or before `ci`:
    /// its breadcrumb, `known` at character `known_ci`, or one of the two
    /// positions found last. Slot 0 remembers where `byteOffset` looked
    /// and slot 1 where `endOffset` looked, and the result goes to `slot`.
    inline fn crumbOffset(s: *String, cr: [*]u32, ci: usize, comptime slot: u1, known_ci: usize, known: usize) usize {
        const n = crumbCount(s.chars());
        const k = ci / crumb_step;
        var at: usize = k * crumb_step;
        var off: usize = cr[k];
        if (known_ci > at) {
            at = known_ci;
            off = known;
        }
        inline for (0..2) |j| {
            const last = cr[n + 2 * j];
            if (last > at and last <= ci) {
                at = last;
                off = cr[n + 2 * j + 1];
            }
        }
        off = wtf8.advance(s.bytes(), off, ci - at);
        cr[n + 2 * @as(usize, slot)] = @intCast(ci);
        cr[n + 2 * @as(usize, slot) + 1] = @intCast(off);
        return off;
    }

    /// `byteOffset` on the first indexed access, which builds the
    /// breadcrumbs.
    noinline fn firstOffset(s: *String, gpa: *const std.mem.Allocator, ci: usize) usize {
        s.buildCrumbs(gpa.*);
        const cr = s.crumbs() orelse return wtf8.advance(s.bytes(), 0, ci);
        return s.crumbOffset(cr, ci, 0, 0, 0);
    }

    /// Number of breadcrumbs of a string with `chars` characters. The
    /// allocation holds four more words, the two positions found last as
    /// a character index and a byte offset each.
    inline fn crumbCount(n_chars: usize) usize {
        return n_chars / crumb_step + 1;
    }

    /// Words of the breadcrumb allocation past the breadcrumbs.
    const crumb_extra = 4;

    noinline fn buildCrumbs(s: *String, gpa: std.mem.Allocator) void {
        const n = crumbCount(s.chars());
        const cr = gpa.alloc(u32, n + crumb_extra) catch return;
        const b = s.bytes();
        var off: usize = 0;
        cr[0] = 0;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            off = wtf8.advance(b, off, crumb_step);
            cr[k] = @intCast(off);
        }
        @memset(cr[n..], 0);
        const slot = s.crumbSlot() orelse return gpa.free(cr);
        slot.* = cr.ptr;
    }

    pub fn freeExtra(s: *String, gpa: std.mem.Allocator) void {
        if (s.crumbs()) |cr| gpa.free(cr[0 .. crumbCount(s.chars()) + crumb_extra]);
    }
};

/// The hash of a string. Strings of up to 32 bytes, which covers most
/// interned strings, hash inline with a few multiplications in the
/// manner of wyhash. Longer strings use `std.hash.Wyhash`.
pub inline fn hashBytes(seed: u64, b: []const u8) u32 {
    const n = b.len;
    if (n > 32) return @truncate(std.hash.Wyhash.hash(seed, b));
    const s0: u64 = 0xa0761d6478bd642f;
    const s1: u64 = 0xe7037ed1a0b428db;
    const s2: u64 = 0x8ebc6af09c88c6e3;
    var x: u64 = 0;
    var y: u64 = 0;
    if (n > 16) {
        x = mum(rd64(b[0..8]) ^ s1, rd64(b[8..16]) ^ seed);
        y = mum(rd64(b[n - 16 ..][0..8]) ^ s2, rd64(b[n - 8 ..][0..8]) ^ seed);
    } else if (n >= 8) {
        x = rd64(b[0..8]);
        y = rd64(b[n - 8 ..][0..8]);
    } else if (n >= 4) {
        x = std.mem.readInt(u32, b[0..4], .little);
        y = std.mem.readInt(u32, b[n - 4 ..][0..4], .little);
    } else if (n > 0) {
        x = (@as(u64, b[0]) << 16) | (@as(u64, b[n / 2]) << 8) | b[n - 1];
    }
    return @truncate(mum(s1 ^ n, mum(x ^ s1, y ^ seed ^ s0)));
}

inline fn rd64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .little);
}

inline fn mum(a: u64, b: u64) u64 {
    const r = @as(u128, a) * b;
    return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
}

// ---------------------------------------------------------------------
// Tables

/// A node of a hash part: the payloads of its key and its value. The tags
/// of the key and the value live apart, in the tag bytes that sit below
/// the first node (`Table.keyTag`), so a node takes 16 bytes instead of
/// the 32 of two full values.
pub const Node = extern struct {
    key: u64 = 0,
    val: u64 = 0,
};

/// A table takes 48 bytes on 64-bit targets: the header, whose spare
/// bytes hold the read-only flag (`spare8`) and the hint of the length
/// (`spare32`), then three pointers and the small fields below.
pub const Table = struct {
    hdr: Header,
    /// Bit k set means metamethod k is known to be absent. Cleared on any
    /// store into the table.
    tm_absent: u16 = 0,
    /// Element kind of the array part. See `ArrayKind`.
    kind: ArrayKind = .none,
    cell: Cell = .{},
    metatable: ?*Table = null,
    /// Array part, indices 1..asize. Holds `asize` words when the kind is
    /// unboxed and `asize` values when it is `boxed`. Use `words` and
    /// `values` to view it.
    array_ptr: [*]u64 = empty_words,
    /// Hash part with open addressing and linear probing, of `hash_len`
    /// nodes, a power of two, or zero. The nodes hold payloads, and the
    /// tags of node i sit at the bytes `2 * (i + 1)` (key) and `2 * i + 1`
    /// (value) below the first node, in the tag area that
    /// `table.tagBytes` sizes. Use `nodes`, `key`, `val`, and their
    /// setters.
    hash_ptr: [*]Node = empty_nodes,
    asize: u32 = 0,
    hash_len: u32 = 0,
    /// Live plus dead slots in the hash part (dead slots keep their key).
    hash_used: u32 = fresh_used,

    /// The size of the storage that trails the table in its own cell, and
    /// the weak mode.
    pub const Cell = packed struct(u8) {
        /// Size in `inline_unit` bytes of the storage that trails the
        /// table in its own cell. A table created with known sizes holds
        /// its first parts there, and parts that outgrow it move to the
        /// backing allocator. At most 504 bytes (`table.max_inline`).
        inline_units: u6 = 0,
        weak_mode: WeakMode = .none,
    };

    /// The unit of the storage that trails a table in its cell, the step
    /// between the small size classes of the heap.
    pub const inline_unit = 8;

    /// The hash part or slots of a table without any. It points into a
    /// static block whose bytes below it are zero, so the count of slots
    /// that native code reads there is zero.
    pub const empty_nodes: [*]Node = @ptrCast(&empty_block[1]);
    var empty_block: [2]Node align(16) = @splat(.{ .key = 0, .val = 0 });

    /// Set in `hash_used` of a shaped table, whose low 16 bits name its
    /// shape. A shaped table has no hash nodes: `hash_len` is zero, and
    /// `hash_ptr` points to its slots, one payload word each. The byte
    /// just below the first slot holds the number of slots, and the tag
    /// of slot i is the byte `i + 2` below the first slot.
    pub const shaped_bit: u32 = 0x8000_0000;
    /// `hash_used` of a new table: shaped, with the root shape, which
    /// every state registers first.
    pub const fresh_used: u32 = shaped_bit;

    pub inline fn isShaped(t: *const Table) bool {
        return t.hash_used & shaped_bit != 0;
    }
    pub inline fn shapeId(t: *const Table) u16 {
        return @truncate(t.hash_used);
    }
    pub inline fn setShapeId(t: *Table, id: u16) void {
        t.hash_used = shaped_bit | id;
    }
    /// The slots of a shaped table.
    pub inline fn slotWords(t: *const Table) [*]u64 {
        return @ptrCast(t.hash_ptr);
    }
    /// The number of slots of a shaped table.
    pub inline fn slotCap(t: *const Table) usize {
        const b: [*]const u8 = @ptrCast(t.hash_ptr);
        return (b - 1)[0];
    }
    pub inline fn slotTag(t: *const Table, i: usize) value.Tag {
        const b: [*]const u8 = @ptrCast(t.hash_ptr);
        return @fromBackingInt(@intCast((b - 2 - i)[0]));
    }
    pub inline fn slotVal(t: *const Table, i: usize) Value {
        return Value.make(t.slotWords()[i], t.slotTag(i));
    }
    pub inline fn setSlot(t: *Table, i: usize, v: Value) void {
        const b: [*]u8 = @ptrCast(t.hash_ptr);
        (b - 2 - i)[0] = @backingInt(v.tag);
        t.slotWords()[i] = v.payload;
    }

    /// The nodes of the hash part.
    pub inline fn nodes(t: *const Table) []Node {
        return t.hash_ptr[0..t.hash_len];
    }
    pub inline fn setNodes(t: *Table, h: []Node) void {
        t.hash_ptr = if (h.len == 0) empty_nodes else h.ptr;
        t.hash_len = @intCast(h.len);
    }
    /// Read-only tables (such as `flags`) reject every store.
    pub inline fn isReadonly(t: *const Table) bool {
        return t.hdr.spare8 != 0;
    }
    pub inline fn setReadonly(t: *Table, ro: bool) void {
        t.hdr.spare8 = @intFromBool(ro);
    }
    /// The border that the length operator last found in the array part.
    /// It is only a starting guess and is checked before every use.
    pub inline fn lenHint(t: *const Table) u32 {
        return t.hdr.spare32;
    }
    pub inline fn setLenHint(t: *Table, n: u32) void {
        t.hdr.spare32 = n;
    }
    pub inline fn weakMode(t: *const Table) WeakMode {
        return t.cell.weak_mode;
    }
    pub inline fn setWeakMode(t: *Table, m: WeakMode) void {
        t.cell.weak_mode = m;
    }

    /// The tag bytes of node `i`: the tag of its key, then the tag of
    /// its value.
    pub inline fn tagPair(t: *const Table, i: usize) *[2]u8 {
        const base: [*]u8 = @ptrCast(t.hash_ptr);
        return @ptrCast(base - 2 * (i + 1));
    }
    pub inline fn keyTag(t: *const Table, i: usize) value.Tag {
        return @fromBackingInt(t.tagPair(i)[0]);
    }
    pub inline fn valTag(t: *const Table, i: usize) value.Tag {
        return @fromBackingInt(t.tagPair(i)[1]);
    }
    /// The key of node `i`, nil for a node that never held one.
    pub inline fn key(t: *const Table, i: usize) Value {
        return Value.make(t.hash_ptr[i].key, t.keyTag(i));
    }
    /// The value of node `i`, nil for an empty node or a dead entry.
    pub inline fn val(t: *const Table, i: usize) Value {
        return Value.make(t.hash_ptr[i].val, t.valTag(i));
    }
    /// The key and the value of node `i`.
    pub inline fn entry(t: *const Table, i: usize) Entry {
        return .{ .key = t.key(i), .val = t.val(i) };
    }
    pub const Entry = struct { key: Value, val: Value };
    pub inline fn setKey(t: *Table, i: usize, k: Value) void {
        t.hash_ptr[i].key = k.payload;
        t.tagPair(i)[0] = @backingInt(k.tag);
    }
    pub inline fn setVal(t: *Table, i: usize, v: Value) void {
        t.hash_ptr[i].val = v.payload;
        t.tagPair(i)[1] = @backingInt(v.tag);
    }
    /// True when node `i` holds the string `s` as its key.
    pub inline fn keyIsStr(t: *const Table, i: usize, s: *const String) bool {
        return t.hash_ptr[i].key == @intFromPtr(s) and t.keyTag(i) == .string;
    }

    pub const WeakMode = enum(u2) { none, keys, values, both };

    /// What the array part stores. An unboxed part (`none`, `int`,
    /// `float`, `string`, or `table`) holds one 64-bit word per slot: the
    /// payload of an integer, a float, a string, or a table, or `hole` for
    /// nil. A `none`
    /// part holds only holes. The kind starts as `none`, takes the kind
    /// of the first number, string, or table stored, and becomes `boxed` on the
    /// first store that does not fit. It never narrows back. The integer
    /// values of the unboxed kinds equal the value tags they hold, so a
    /// load rebuilds a value from the word and the kind alone.
    pub const ArrayKind = enum(u8) {
        none = @backingInt(value.Tag.nil),
        int = @backingInt(value.Tag.integer),
        float = @backingInt(value.Tag.float),
        string = @backingInt(value.Tag.string),
        table = @backingInt(value.Tag.table),
        boxed = 0xFF,
    };

    /// The word an unboxed array part stores for nil. It is a signaling
    /// NaN, which no arithmetic produces. An integer or float whose bits
    /// equal it makes the part boxed.
    pub const hole: u64 = 0x7FF4_0000_0000_0000;

    pub const empty_words: [*]u64 = @ptrFromInt(@alignOf(u64));

    /// The storage that trails the table in its cell.
    pub inline fn inlineBytes(t: *Table) []u8 {
        const base: [*]u8 = @ptrCast(t);
        return (base + @sizeOf(Table))[0 .. @as(usize, t.cell.inline_units) * inline_unit];
    }
    /// True when `p` points into the storage that trails the table.
    pub inline fn ownsInline(t: *Table, p: *const anyopaque) bool {
        const b = t.inlineBytes();
        const a = @intFromPtr(p);
        return a >= @intFromPtr(b.ptr) and a < @intFromPtr(b.ptr) + b.len;
    }

    /// The unboxed array part. Only valid when the kind is not `boxed`.
    pub inline fn words(t: *const Table) []u64 {
        return t.array_ptr[0..t.asize];
    }
    /// The boxed array part. Only valid when the kind is `boxed`.
    pub inline fn values(t: *const Table) []Value {
        const p: [*]Value = @ptrCast(t.array_ptr);
        return p[0..t.asize];
    }
};

// ---------------------------------------------------------------------
// Functions

pub const UpvalDesc = struct {
    /// True if the upvalue captures a register of the enclosing function,
    /// false if it copies an upvalue of the enclosing function.
    in_stack: bool,
    index: u8,
    /// Capture by value: the captured local is never written after the
    /// closure is created, so the value is copied and never boxed.
    by_value: bool = false,
    name: ?*String = null,
};

pub const LocVar = struct {
    name: *String,
    start_pc: u32,
    end_pc: u32,
    reg: u8,
};

/// Entry of a function's exception table. Instructions in
/// [start_pc, end_pc) are protected. On error the unwinder closes upvalues
/// and to-be-closed variables down to `level`, stores the error in `dest`
/// and jumps to `handler_pc`.
pub const Handler = struct {
    start_pc: u32,
    end_pc: u32,
    handler_pc: u32,
    level: u8,
    dest: u8,
};

pub const Proto = struct {
    hdr: Header,
    num_params: u8 = 0,
    is_vararg: bool = false,
    call: CallFlags = .{},
    max_stack: u8 = 2,
    line_defined: u32 = 0,
    last_line_defined: u32 = 0,
    code: []u32 = &.{},
    constants: []Value = &.{},
    protos: []*Proto = &.{},
    upvals: []UpvalDesc = &.{},
    handlers: []Handler = &.{},
    /// Source line of each instruction.
    lines: []u32 = &.{},
    locvars: []LocVar = &.{},
    source: ?*String = null,
    name: ?*String = null,
    /// Inline caches, one entry per instruction, indexed by pc. Only
    /// string-keyed table accesses use them.
    ic: []IcEntry = &.{},
    /// Counts down the calls, loop iterations, and returns the function
    /// sees. At zero the interpreter asks the JIT what to do with the
    /// function. A function with native code keeps the counter at one.
    hot: u32 = 1,
    jit_state: JitState = .fresh,
    /// The native code of the function (a `jit.Code`), or null.
    jit_code: ?*anyopaque = null,
    /// Address that native code calls to enter the function with fixed
    /// parameters, or zero when the function has no native code or takes
    /// variable arguments.
    jit_entry: usize = 0,
    /// Address that native code calls to enter the function by a tail
    /// call, under the same conditions.
    jit_tail: usize = 0,
    /// Counts down the calls and loop iterations that baseline code
    /// runs. At zero the optimizing tier looks at the function.
    opt_hot: u32 = 0,
    /// What the optimizing tier keeps about the function (a
    /// `jit.opt.Info`), or null.
    opt: ?*anyopaque = null,

    pub const JitState = enum(u8) {
        /// Not yet seen by the JIT.
        fresh,
        /// Counting toward the threshold.
        counting,
        compiled,
        /// The function stays in the interpreter.
        declined,
    };

    /// How the interpreter calls the function and returns from it. The
    /// two flags share a word, so that a call reads both at once, and
    /// they sit one byte apart, as the flags `plain` and `closes` of a
    /// frame do. The word shifted left by `frame_shift` is therefore the
    /// flags word of the frame that a plain call pushes, which
    /// `state.Frame` checks against its layout.
    pub const CallFlags = packed struct(u16) {
        /// The function has fixed parameters and no native code, so the
        /// interpreter enters it on its shortest path. The default
        /// sends every call through the general path, which is always
        /// right.
        plain: bool = false,
        _pad: u7 = 0,
        /// A frame of the function can own an open upvalue or a
        /// to-be-closed variable, which its return then has to close.
        closes: bool = true,
        _pad2: u7 = 0,

        pub const frame_shift = 48;

        /// The flags word of the frame of a plain call. The two bytes of
        /// the flags are the last two of the word, which are its high
        /// bytes on a little-endian target and its low bytes, in the
        /// other order, on a big-endian one.
        pub inline fn frameFlags(f: CallFlags) u64 {
            const v: u16 = @bitCast(f);
            if (@import("builtin").cpu.arch.endian() == .little) return @as(u64, v) << frame_shift;
            return @byteSwap(v);
        }
    };

    /// Finds whether a frame of the function can own an open upvalue or
    /// a to-be-closed variable. Only a closure made by the function
    /// opens an upvalue on one of its registers, and only two
    /// instructions mark a variable to be closed. It runs once the code
    /// and the nested functions are in place.
    pub fn noteCloses(p: *Proto) void {
        const opc = @import("../compile/opcodes.zig");
        p.call.closes = false;
        for (p.protos) |child| for (child.upvals) |d| {
            if (d.in_stack and !d.by_value) p.call.closes = true;
        };
        for (p.code) |ins| switch (opc.op(ins)) {
            .tbc, .tforprep => p.call.closes = true,
            else => {},
        };
    }

    /// Allocates the inline caches for the code, all empty.
    pub fn initIc(p: *Proto, gpa: std.mem.Allocator) !void {
        p.ic = try gpa.alloc(IcEntry, p.code.len);
        @memset(p.ic, .{});
        p.link();
    }

    /// What sits in front of the code of a function: the addresses of
    /// its constants and of its inline caches. The interpreter keeps the
    /// code pointer of the running function in a machine register and
    /// reaches both through it, so a call and a return load one pointer.
    pub const CodeLinks = extern struct {
        constants: [*]const Value,
        ic: [*]IcEntry,
    };

    /// Allocates the code of a function with room for its links.
    pub fn allocCode(gpa: std.mem.Allocator, n: usize) ![]u32 {
        if (n == 0) return &.{};
        const raw = try gpa.alignedAlloc(u8, .of(CodeLinks), @sizeOf(CodeLinks) + n * @sizeOf(u32));
        @memset(raw[0..@sizeOf(CodeLinks)], 0);
        const code: [*]u32 = @ptrCast(@alignCast(raw.ptr + @sizeOf(CodeLinks)));
        return code[0..n];
    }

    pub fn freeCode(gpa: std.mem.Allocator, code: []u32) void {
        if (code.len == 0) return;
        const raw: [*]align(@alignOf(CodeLinks)) u8 = @ptrCast(linksOf(code.ptr));
        gpa.free(raw[0 .. @sizeOf(CodeLinks) + code.len * @sizeOf(u32)]);
    }

    pub inline fn linksOf(code: [*]const u32) *CodeLinks {
        const bytes: [*]const u8 = @ptrCast(code);
        return @ptrCast(@alignCast(@constCast(bytes - @sizeOf(CodeLinks))));
    }

    /// Writes the links in front of the code. It runs whenever the
    /// constants or the inline caches of the function are set.
    pub fn link(p: *Proto) void {
        if (p.code.len == 0) return;
        linksOf(p.code.ptr).* = .{ .constants = p.constants.ptr, .ic = p.ic.ptr };
    }
};

/// Slot predictions for a string-keyed table access. Each field is the
/// index of the hash node that held the key the last time, or `none`. An
/// entry holds only indices, never pointers, so it can never keep an
/// object alive or dangle, and every use checks the key in the predicted
/// node before trusting it.
pub const IcEntry = extern struct {
    /// The key in the accessed table itself.
    own: u16 = none,
    /// `__index` in the metatable of the accessed table.
    index: u16 = none,
    /// The key in the table that `__index` names.
    holder: u16 = none,
    /// The id of the shape of the table that `own` predicts a slot of, or
    /// `none` when `own` predicts a hash node (`shape.zig`). With `own`
    /// at `none`, the shape lacks the key. For a `newtable` instruction,
    /// the shape its tables reach, which the next ones start with.
    shape: u16 = none,

    pub const none: u16 = 0xFFFF;

    /// For a `newtable` instruction, `own` records the lists that its
    /// tables held: none seen yet, only lists that fit an unboxed kind,
    /// which the next tables keep in one word per slot, or one that
    /// boxed, after which the site reserves full values for good.
    pub const lists_unknown: u16 = none;
    pub const lists_words: u16 = 1;
    pub const lists_boxed: u16 = 2;
};

pub const Upvalue = struct {
    hdr: Header,
    /// Points either into a thread stack (open) or to `closed`.
    loc: *Value,
    closed: Value = .nil,
    /// Next open upvalue of the owning thread, sorted by stack level
    /// (higher levels first). Null once closed.
    next_open: ?*Upvalue = null,
    level: u32 = 0,
    open: bool = true,
};

pub const Closure = struct {
    hdr: Header,
    proto: *Proto,
    nupvals: u32,

    pub inline fn upvals(c: *Closure) []*Upvalue {
        const base: [*]u8 = @ptrCast(c);
        const p: [*]*Upvalue = @ptrCast(@alignCast(base + @sizeOf(Closure)));
        return p[0..c.nupvals];
    }
    pub inline fn allocSize(n: usize) usize {
        return @sizeOf(Closure) + n * @sizeOf(*Upvalue);
    }
};

// ---------------------------------------------------------------------
// Userdata, vectors, enums

pub const Userdata = struct {
    hdr: Header,
    metatable: ?*Table = null,
    size: usize,
    nuser: u16 = 0,

    pub inline fn userValues(u: *Userdata) []Value {
        const base: [*]u8 = @ptrCast(u);
        const p: [*]Value = @ptrCast(@alignCast(base + @sizeOf(Userdata)));
        return p[0..u.nuser];
    }
    pub inline fn data(u: *Userdata) [*]u8 {
        const base: [*]u8 = @ptrCast(u);
        return base + @sizeOf(Userdata) + @as(usize, u.nuser) * @sizeOf(Value);
    }
    pub inline fn allocSize(size: usize, nuser: usize) usize {
        return @sizeOf(Userdata) + nuser * @sizeOf(Value) + size;
    }
};

pub const Vector = struct {
    hdr: Header,
    bytes: std.ArrayList(u8) = .empty,
    /// Set when the payload was transferred to another worker.
    detached: bool = false,

    /// A read-only vector is a constant of a `<meta>` local. The flag is
    /// the spare byte of the header.
    pub inline fn isReadonly(v: *const Vector) bool {
        return v.hdr.spare8 != 0;
    }
};

pub const EnumRoot = struct {
    hdr: Header,
    names: []*String,
    /// Lazily created values, one per name.
    values: []?*EnumValue,
};

pub const EnumValue = struct {
    hdr: Header,
    root: *EnumRoot,
    index: u32,
};

comptime {
    // Headers come first so a Header pointer converts to the object.
    std.debug.assert(@offsetOf(String, "hdr") == 0);
    std.debug.assert(@offsetOf(Table, "hdr") == 0);
    std.debug.assert(@offsetOf(Closure, "hdr") == 0);
    std.debug.assert(@sizeOf(Closure) % @alignOf(*Upvalue) == 0);
    std.debug.assert(@sizeOf(Userdata) % 16 == 0 or @sizeOf(Userdata) % 8 == 0);
}
