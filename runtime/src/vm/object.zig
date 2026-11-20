//! Heap object layouts. Every object begins with `gc.Header`, and the
//! collector dispatches on the header tag to trace and free them.

const std = @import("std");
const value = @import("value.zig");
const gc = @import("gc.zig");
const wtf8 = @import("wtf8.zig");
const Value = value.Value;
const Header = gc.Header;
const Blob = @import("blob.zig").Blob;

// ---------------------------------------------------------------------
// Strings

pub const String = struct {
    hdr: Header,
    len: u32,
    chars: u32,
    hash: u32,
    flags: Flags,
    /// Byte offset of every 64th character, built on first indexed access
    /// for non-ASCII strings. Entry k is the offset of character 64*k.
    crumbs: ?[*]u32 = null,

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
        _pad: u3 = 0,
    };

    pub const short_max = 40;
    pub const crumb_step = 64;
    /// The cell size of a shared string.
    pub const shared_size = @sizeOf(String) + @sizeOf(*Blob);

    pub inline fn bytes(s: *const String) []const u8 {
        if (s.flags.shared) {
            @branchHint(.unlikely);
            return s.blob().bytes();
        }
        const base: [*]const u8 = @ptrCast(s);
        return (base + @sizeOf(String))[0..s.len];
    }
    pub inline fn bytesMut(s: *String) []u8 {
        std.debug.assert(!s.flags.shared);
        const base: [*]u8 = @ptrCast(s);
        return (base + @sizeOf(String))[0..s.len];
    }
    pub inline fn allocSize(len: usize) usize {
        return @sizeOf(String) + len + 1;
    }
    /// The size of the cell of `s`.
    pub inline fn cellSize(s: *const String) usize {
        return if (s.flags.shared) shared_size else allocSize(s.len);
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
        if (s.flags.ascii or ci == 0) return ci;
        if (ci >= s.chars) return s.len;
        if (s.chars <= crumb_step) return wtf8.advance(s.bytes(), 0, ci);
        const cr = s.crumbs orelse return s.firstOffset(gpa, ci);
        // A range that starts a few characters after the last one, as
        // every step of a scan through a string does, is found from
        // where that one started, with no look at the breadcrumbs.
        const n = crumbCount(s.chars);
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
        if (s.flags.ascii) return ci;
        if (ci >= s.chars) return s.len;
        const cr = s.crumbs orelse return wtf8.advance(s.bytes(), from_off, ci - from_ci);
        // The previous end, when it lies between the start and `ci`, is
        // where the scan starts. Choosing it by a branch keeps the scan
        // from waiting for the offset of the start.
        const n = crumbCount(s.chars);
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
        const n = crumbCount(s.chars);
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
        const cr = s.crumbs orelse return wtf8.advance(s.bytes(), 0, ci);
        return s.crumbOffset(cr, ci, 0, 0, 0);
    }

    /// Number of breadcrumbs of a string with `chars` characters. The
    /// allocation holds four more words, the two positions found last as
    /// a character index and a byte offset each.
    inline fn crumbCount(chars: usize) usize {
        return chars / crumb_step + 1;
    }

    /// Words of the breadcrumb allocation past the breadcrumbs.
    const crumb_extra = 4;

    noinline fn buildCrumbs(s: *String, gpa: std.mem.Allocator) void {
        const n = crumbCount(s.chars);
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
        s.crumbs = cr.ptr;
    }

    pub fn freeExtra(s: *String, gpa: std.mem.Allocator) void {
        if (s.crumbs) |cr| gpa.free(cr[0 .. crumbCount(s.chars) + crumb_extra]);
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

pub const Node = struct {
    key: Value,
    val: Value,
};

pub const Table = struct {
    hdr: Header,
    /// Bit k set means metamethod k is known to be absent. Cleared on any
    /// store into the table.
    tm_absent: u16 = 0,
    log2_hash: u8 = 0,
    /// Element kind of the array part. See `ArrayKind`.
    kind: ArrayKind = .none,
    metatable: ?*Table = null,
    /// Array part, indices 1..asize. Holds `asize` words when the kind is
    /// unboxed and `asize` values when it is `boxed`. Use `words` and
    /// `values` to view it.
    array_ptr: [*]u64 = empty_words,
    asize: usize = 0,
    /// Hash part with open addressing and linear probing. Length is a
    /// power of two, or zero.
    hash: []Node = &.{},
    /// Live plus dead slots in the hash part (dead slots keep their key).
    hash_used: u32 = 0,
    /// Next free search position used by `next` scanning heuristics.
    weak_mode: WeakMode = .none,
    /// Read-only tables (such as `flags`) reject every store.
    readonly: bool = false,
    /// The border that the length operator last found in the array part.
    /// It is only a starting guess and is checked before every use.
    len_hint: u32 = 0,
    /// Size in 16-byte units of the storage that trails the table in its
    /// own cell. A table created with known sizes holds its first parts
    /// there, and parts that outgrow it move to the backing allocator.
    inline_units: u16 = 0,

    pub const WeakMode = enum(u8) { none, keys, values, both };

    /// What the array part stores. An unboxed part (`none`, `int`,
    /// `float`, or `string`) holds one 64-bit word per slot: the payload
    /// of an integer, a float, or a string, or `hole` for nil. A `none`
    /// part holds only holes. The kind starts as `none`, takes the kind
    /// of the first number or string stored, and becomes `boxed` on the
    /// first store that does not fit. It never narrows back. The integer
    /// values of the unboxed kinds equal the value tags they hold, so a
    /// load rebuilds a value from the word and the kind alone.
    pub const ArrayKind = enum(u8) {
        none = @backingInt(value.Tag.nil),
        int = @backingInt(value.Tag.integer),
        float = @backingInt(value.Tag.float),
        string = @backingInt(value.Tag.string),
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
        return (base + @sizeOf(Table))[0 .. @as(usize, t.inline_units) * 16];
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

        /// The flags word of the frame of a plain call.
        pub inline fn frameFlags(f: CallFlags) u64 {
            return @as(u64, @as(u16, @bitCast(f))) << frame_shift;
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
    _pad: u16 = 0,

    pub const none: u16 = 0xFFFF;
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
