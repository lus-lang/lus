//! The intermediate representation of the optimizing tier. A function is
//! a graph of blocks, and a block is a list of instructions in static
//! single assignment form. Every instruction that produces a value has a
//! static type, and the value lives unboxed in a machine register: the
//! payload of an integer, a float, or the address of an object. The design
//! is described in `spec/design/opt.md`.

const std = @import("std");
const value = @import("../../vm/value.zig");
const object = @import("../../vm/object.zig");
const Tag = value.Tag;

/// An instruction, by its index in `Func.insts`. Zero stands for no
/// instruction.
pub const Ref = u32;
pub const none: Ref = 0;
pub const BlockId = u32;
pub const no_block: BlockId = 0xFFFF_FFFF;
pub const no_snap: u32 = 0xFFFF_FFFF;

/// The static type of a value. The codes equal the value tags, so that
/// writing a value back to its register stores the code as the tag. A
/// boolean keeps zero or one as its payload, and its tag is the code of
/// `boolean` plus the payload. `int` also types raw machine words, such
/// as the address of a hash part, which never reach a register.
pub const Ty = enum(u8) {
    nil = @backingInt(Tag.nil),
    boolean = @backingInt(Tag.false),
    int = @backingInt(Tag.integer),
    float = @backingInt(Tag.float),
    light = @backingInt(Tag.light),
    string = @backingInt(Tag.string),
    table = @backingInt(Tag.table),
    closure = @backingInt(Tag.closure),
    native = @backingInt(Tag.native),
    userdata = @backingInt(Tag.userdata),
    thread = @backingInt(Tag.thread),
    bigint = @backingInt(Tag.bigint),
    decimal = @backingInt(Tag.decimal),
    vector = @backingInt(Tag.vector),
    enum_value = @backingInt(Tag.enum_value),
    enum_root = @backingInt(Tag.enum_root),
    query = @backingInt(Tag.query),
    /// The instruction produces no value.
    void = 0xFF,

    pub fn fromTag(t: Tag) Ty {
        return switch (t) {
            .false, .true => .boolean,
            .proto, .upvalue => .void,
            else => @fromBackingInt(@backingInt(t)),
        };
    }
    pub fn isFloat(t: Ty) bool {
        return t == .float;
    }
    pub fn collectable(t: Ty) bool {
        return t != .void and @backingInt(t) >= @backingInt(Tag.string);
    }
    /// The tag byte that a guard compares with. A boolean has two tags,
    /// which the guard instructions name with `bool_tag`.
    pub fn guardTag(t: Ty) u8 {
        return if (t == .boolean) bool_tag else @backingInt(t);
    }
};

/// Stands for "false or true" where a guard names a tag.
pub const bool_tag: u8 = 0xFE;

/// What memory an instruction reads or writes, for the passes that move
/// and merge loads. Two accesses of different classes never touch the
/// same word.
pub const Class = enum(u8) {
    none,
    /// A register of the frame that no closure captures. The low bits
    /// of the instruction name the slot.
    slot,
    /// The value of an upvalue, and every register that a closure
    /// captures, because an open upvalue is such a register.
    upval,
    /// The address an upvalue keeps its value at.
    upval_loc,
    /// Fields of a closure, a proto, a string, or a native, which never
    /// change.
    fixed,
    /// The metatable and the read-only flag.
    tab_meta,
    /// The absence cache of metamethods.
    tab_absent,
    /// The pointer, the length, and the count of the hash part.
    tab_hash,
    /// The pointer, the length, and the kind of the array part.
    tab_array,
    node_key,
    node_val,
    elem,
    /// The header flags of an object, which the collector changes.
    gc,
    /// The count of pending finalizers.
    pending,
};

pub const Cond = enum(u8) { eq, ne, lt, le, gt, ge, lo, ls, hi, hs };

pub fn invert(c: Cond) Cond {
    return switch (c) {
        .eq => .ne,
        .ne => .eq,
        .lt => .ge,
        .ge => .lt,
        .le => .gt,
        .gt => .le,
        .lo => .hs,
        .hs => .lo,
        .ls => .hi,
        .hi => .ls,
    };
}

/// Float comparisons. Each is false when an operand is NaN, except `ne`.
pub const FCond = enum(u8) { lt, le, eq, ne, nlt, nle };

pub const Op = enum(u8) {
    nop,
    // Constants. They take no machine register: the code generator
    // writes them where they are used.
    knil,
    kbool,
    kint,
    kflt,
    kptr,
    // Registers of the frame. `imm` is the slot, counted from register
    // zero of the root function.
    sload,
    gslot,
    sstore,
    scopy,
    // Integers.
    add,
    sub,
    mul,
    band,
    bor,
    bxor,
    addi,
    neg,
    bnot,
    /// a + (b << imm).
    addsh,
    /// Floor modulo and floor division. The divisor is neither zero
    /// nor minus one.
    mod,
    idiv,
    modi,
    idivi,
    // Floats.
    fadd,
    fsub,
    fmul,
    fdiv,
    fneg,
    fabs,
    fsqrt,
    ffloor,
    fceil,
    i2f,
    /// Truncates a float to an integer. The operand is integral and in
    /// range.
    f2i,
    bits2f,
    f2bits,
    // Memory. `a` is the base, `imm` the displacement, `size` the width
    // in bytes. `c` names the guard that makes a load safe, if any.
    load,
    /// [a + (b << aux) + imm], 64 bits wide.
    loadx,
    store,
    storex,
    /// Copies a whole value between memory and a register slot, or
    /// between two places in memory.
    copy_m2s,
    copy_s2m,
    copy_m2m,
    // Guards. Each leaves optimized code through its snapshot when its
    // condition fails.
    guard,
    guardi,
    gfcmp,
    gtag,
    gbit,
    gnokey,
    /// Leaves optimized code when a finalizer is pending.
    gpending,
    // Runtime calls and the collector.
    callc,
    barrier,
    gccheck,
    // Control flow. Every block ends with one of these.
    jmp,
    br,
    bri,
    fbr,
    brtruthy,
    brtag,
    generic,
    exit,
    phi,
};

pub const Inst = struct {
    op: Op = .nop,
    ty: Ty = .void,
    cond: u8 = 0,
    cls: Class = .none,
    /// Width of a memory access in bytes.
    size: u8 = 8,
    /// Set by the passes: the instruction is in a snapshot or used.
    flags: Flags = .{},
    a: Ref = none,
    b: Ref = none,
    c: Ref = none,
    imm: i64 = 0,
    aux: u64 = 0,
    snap: u32 = no_snap,
    /// Targets of a terminator.
    t: BlockId = no_block,
    f: BlockId = no_block,

    pub const Flags = packed struct(u8) {
        live: bool = false,
        /// The base of this store is an object that the same function
        /// allocated, which nothing older can alias.
        fresh: bool = false,
        /// The callee of `callc` reads memory and changes nothing.
        pure: bool = false,
        /// The first argument of `callc` is the thread.
        thread: bool = false,
        _pad: u4 = 0,
    };

    pub fn isConst(i: *const Inst) bool {
        return switch (i.op) {
            .knil, .kbool, .kint, .kflt, .kptr => true,
            else => false,
        };
    }
    pub fn isGuard(i: *const Inst) bool {
        return switch (i.op) {
            .gslot, .guard, .guardi, .gfcmp, .gtag, .gbit, .gnokey, .gpending => true,
            else => false,
        };
    }
    pub fn isTerminator(i: *const Inst) bool {
        return switch (i.op) {
            .jmp, .br, .bri, .fbr, .brtruthy, .brtag, .generic, .exit => true,
            else => false,
        };
    }
};

pub const Block = struct {
    insts: std.ArrayList(Ref) = .empty,
    preds: std.ArrayList(BlockId) = .empty,
    /// The node of the control flow graph that the block belongs to.
    node: u32 = 0,
    /// The block runs whenever its node is entered.
    always: bool = true,
    /// For the block before a loop: the header it leads to.
    preheader_of: BlockId = no_block,
    /// The snapshot that a guard moved into this block uses.
    pre_snap: u32 = no_snap,
    /// For a block on an edge: the block the edge leaves.
    edge_from: BlockId = no_block,
    loop_header: bool = false,
    // Filled by the register allocator.
    order: u32 = 0,
    first_pos: u32 = 0,
    last_pos: u32 = 0,
};

/// One frame of a snapshot. The root frame comes first. Every further
/// frame is a call that was compiled inline, which leaving optimized code
/// turns into a real frame.
pub const SnapFrame = struct {
    proto: *object.Proto,
    /// The closure of an inline frame.
    closure: Ref = none,
    /// Slot of register zero of the frame.
    off: u32 = 0,
    /// The instruction the frame continues at.
    pc: u32 = 0,
    /// Result count that the call of an inline frame wants.
    want: i32 = 0,
    tail: bool = false,
    entries: u32 = 0,
    count: u32 = 0,
};

pub const SnapEntry = struct {
    slot: u32,
    ref: Ref,
};

pub const Snap = struct {
    frames: u32,
    nframes: u32,
};

pub const PhiArg = struct {
    pred: BlockId,
    ref: Ref,
};

pub const GenTarget = struct {
    pc: u32,
    block: BlockId,
};

pub const Func = struct {
    arena: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    snaps: std.ArrayList(Snap) = .empty,
    snap_frames: std.ArrayList(SnapFrame) = .empty,
    snap_entries: std.ArrayList(SnapEntry) = .empty,
    /// Arguments of every phi. A phi names its run with `a` (start) and
    /// `b` (count).
    phi_args: std.ArrayList(PhiArg) = .empty,
    /// Continuations of every `generic` instruction, named by `a`
    /// (start) and `b` (count).
    gen_targets: std.ArrayList(GenTarget) = .empty,
    entry: BlockId = 0,
    /// Slots that the frames of the function cover, counted from
    /// register zero of the root.
    extent: u32 = 0,
    /// Deepest chain of inline frames.
    depth: u32 = 0,

    pub fn init(arena: std.mem.Allocator) !Func {
        var f: Func = .{ .arena = arena };
        // Instruction zero stands for "none".
        try f.insts.append(arena, .{});
        return f;
    }

    pub fn newBlock(f: *Func) !BlockId {
        try f.blocks.append(f.arena, .{});
        return @intCast(f.blocks.items.len - 1);
    }

    pub fn add(f: *Func, b: BlockId, i: Inst) !Ref {
        try f.insts.append(f.arena, i);
        const r: Ref = @intCast(f.insts.items.len - 1);
        try f.blocks.items[b].insts.append(f.arena, r);
        return r;
    }

    pub inline fn at(f: *Func, r: Ref) *Inst {
        return &f.insts.items[r];
    }

    pub fn terminator(f: *Func, b: BlockId) ?*Inst {
        const list = f.blocks.items[b].insts.items;
        if (list.len == 0) return null;
        const i = f.at(list[list.len - 1]);
        return if (i.isTerminator()) i else null;
    }

    /// Calls `visit` with the blocks a terminator can continue in.
    pub fn successors(f: *Func, b: BlockId, out: *[4]BlockId) []BlockId {
        var n: usize = 0;
        const term = f.terminator(b) orelse return out[0..0];
        switch (term.op) {
            .jmp => {
                out[0] = term.t;
                n = 1;
            },
            .br, .bri, .fbr, .brtruthy, .brtag => {
                out[0] = term.t;
                out[1] = term.f;
                n = 2;
            },
            .generic => {
                for (f.gen_targets.items[term.a..][0..term.b]) |g| {
                    out[n] = g.block;
                    n += 1;
                }
            },
            else => {},
        }
        return out[0..n];
    }
};

comptime {
    std.debug.assert(@backingInt(Tag.true) == @backingInt(Tag.false) + 1);
    std.debug.assert(@backingInt(Tag.integer) == 3 and @backingInt(Tag.float) == 4);
}
