//! The s390x backend of the JIT assembler, for z/Architecture and the
//! s390x ELF calling convention. It offers the same interface as
//! `x64.zig`, whose register roles it follows: the temporaries share the
//! argument registers. Instructions are 2, 4, or 6 bytes long.
//!
//! Four properties of the target shape it.
//!
//! - The convention gives every call a register save area of 160 bytes
//!   at the bottom of the frame of its caller. The stack pointer that
//!   native code sees through this interface sits 160 bytes above r15,
//!   so the save area of every frame stays free for the routines it
//!   calls.
//! - A routine that returns a structure of more than 8 bytes, such as
//!   `jit.Target`, returns it through memory that its caller passes in
//!   r2. `callPair` passes 16 bytes of the frame and loads the two words
//!   back into the result registers.
//! - r0 reads as zero as a base or an index, so it serves only as data.
//!   A call loads its target into r14, the link register, and calls
//!   through it. A division uses the even and odd pair r0 and r1.
//! - Compare-and-branch instructions reach 64 KB. A comparison followed
//!   by `brcl` reaches 4 GB, which every branch of a function falls
//!   within, so no branch needs an island.
//!
//! The instruction fetch of z/Architecture follows stores, so installed
//! code needs no cache maintenance, and immediates of 32 bits fit in one
//! instruction, so there is no pool.

const std = @import("std");
const reloc = @import("reloc.zig");

pub const Reg = enum(u4) {
    r0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,

    inline fn n(r: Reg) u8 {
        return @backingInt(r);
    }
};

pub const FReg = enum(u4) {
    f0,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,

    inline fn n(r: FReg) u8 {
        return @backingInt(r);
    }
};

/// The native stack pointer, as the base of a memory operand. The
/// assembler adds `bias` to every displacement from it.
pub const sp: Reg = .r15;
/// Bytes between r15 and the stack pointer that native code sees: the
/// register save area of the routines it calls.
const bias = 160;

// The registers the emitter uses. Pinned registers are the callee-saved
// r7 to r10. As on x86-64, the temporaries t1 to t5 are argument
// registers, and t0 and t6 are r11 and r12, which the entry sequence
// saves.
pub const thread: Reg = .r7;
pub const bp: Reg = .r8;
pub const base: Reg = .r9;
pub const stop: Reg = .r10;
pub const t0: Reg = .r11;
pub const t1: Reg = .r5;
pub const t2: Reg = .r4;
pub const t3: Reg = .r3;
pub const t4: Reg = .r2;
pub const t5: Reg = .r6;
pub const t6: Reg = .r12;
pub const args = [_]Reg{ .r2, .r3, .r4, .r5, .r6 };
pub const ret0: Reg = .r2;
pub const ret1: Reg = .r3;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .r4;
pub const f0: FReg = .f0;
pub const f1: FReg = .f2;
/// The data scratch register of the assembler. It is never a base.
const s0: Reg = .r0;
/// The float scratch register of the assembler, which the entry sequence
/// saves.
const fs0: FReg = .f10;

/// Bytes of native stack the entry sequence reserves above the save area:
/// the slot of `enterLocal`, f8 to f10, and padding.
const frame_size = 32;
/// Offset of the slot where a shared routine keeps its return address.
const link_slot = 0;

pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    /// Unsigned higher or same.
    hs = 2,
    /// Unsigned lower.
    lo = 3,
    mi = 4,
    pl = 5,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,

    pub fn invert(c: Cond) Cond {
        return @fromBackingInt(@backingInt(c) ^ 1);
    }
};

/// A float comparison that is false when either operand is NaN, or the
/// negation of one, which is then true for NaN.
pub const FCond = enum { lt, le, eq, nlt, nle, ne };

pub const Mem = struct {
    base: Reg,
    disp: i32 = 0,
};

pub const Label = u32;

const Fixup = struct {
    /// Offset of the instruction. The relative offset sits at byte 2.
    at: u32,
    label: Label,
    kind: enum { rel16, rel32 },
};

/// The mask of the condition codes that a condition holds for after a
/// comparison: 8 for equal, 4 for low, 2 for high. An unsigned
/// condition compares logically.
const Mask = struct { mask: u4, logical: bool };
fn maskOf(c: Cond) Mask {
    return switch (c) {
        .eq => .{ .mask = 8, .logical = false },
        .ne => .{ .mask = 6, .logical = false },
        .lt => .{ .mask = 4, .logical = false },
        .ge => .{ .mask = 10, .logical = false },
        .gt => .{ .mask = 2, .logical = false },
        .le => .{ .mask = 12, .logical = false },
        .lo => .{ .mask = 4, .logical = true },
        .hs => .{ .mask = 10, .logical = true },
        .hi => .{ .mask = 2, .logical = true },
        .ls => .{ .mask = 12, .logical = true },
        .mi, .pl => unreachable,
    };
}

fn fitsI16(v: i64) bool {
    return v >= -32768 and v < 32768;
}
fn fitsI20(v: i64) bool {
    return v >= -(1 << 19) and v < (1 << 19);
}
fn fitsU12(v: i64) bool {
    return v >= 0 and v < 4096;
}

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Offset of each label, or `unbound`.
    labels: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    oom: bool = false,
    /// Set when the assembler compiles ahead of time, which makes the
    /// routines that write addresses record relocations.
    aot: bool = false,
    relocs: std.ArrayList(reloc.Entry) = .empty,
    /// Wide immediates written ahead of time that name something the
    /// loader cannot find. Code with any is unusable ahead of time.
    unrelocated: u32 = 0,
    /// Decides ahead of time what a wide immediate of `movImm` is.
    resolver: ?reloc.Resolver = null,
    /// Set when a branch cannot reach its label, or a displacement does
    /// not fit 20 bits.
    overflow: bool = false,

    const unbound: u32 = 0xFFFF_FFFF;

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Assembler) void {
        a.relocs.deinit(a.gpa);
        a.buf.deinit(a.gpa);
        a.labels.deinit(a.gpa);
        a.fixups.deinit(a.gpa);
    }

    pub fn offset(a: *const Assembler) u32 {
        return @intCast(a.buf.items.len);
    }

    pub fn newLabel(a: *Assembler) Label {
        a.labels.append(a.gpa, unbound) catch {
            a.oom = true;
            return 0;
        };
        return @intCast(a.labels.items.len - 1);
    }
    /// A label of out-of-line code, which this target treats as any
    /// other.
    pub const newColdLabel = newLabel;

    pub fn newLabels(a: *Assembler, count: usize) Label {
        const first: Label = @intCast(a.labels.items.len);
        a.labels.appendNTimes(a.gpa, unbound, count) catch {
            a.oom = true;
        };
        return first;
    }

    pub fn bind(a: *Assembler, l: Label) void {
        if (l < a.labels.items.len) a.labels.items[l] = a.offset();
    }

    pub fn labelOffset(a: *const Assembler, l: Label) u32 {
        return a.labels.items[l];
    }

    fn bytes(a: *Assembler, b: []const u8) void {
        a.buf.appendSlice(a.gpa, b) catch {
            a.oom = true;
        };
    }
    fn h2(a: *Assembler, w: u16) void {
        a.bytes(&std.mem.toBytes(std.mem.nativeToBig(u16, w)));
    }
    fn h4(a: *Assembler, w: u32) void {
        a.bytes(&std.mem.toBytes(std.mem.nativeToBig(u32, w)));
    }
    fn h6(a: *Assembler, w: u48) void {
        a.h2(@truncate(w >> 32));
        a.h4(@truncate(w));
    }

    fn fix(a: *Assembler, l: Label, kind: @FieldType(Fixup, "kind")) void {
        a.fixups.append(a.gpa, .{ .at = a.offset(), .label = l, .kind = kind }) catch {
            a.oom = true;
        };
    }

    /// Immediates build in place, so there is no pool to write.
    pub fn flushPool(a: *Assembler) void {
        _ = a;
    }

    fn patch(a: *Assembler, f: Fixup, target: u32) void {
        const delta: i64 = @divExact(@as(i64, target) - @as(i64, f.at), 2);
        const at = f.at + 2;
        switch (f.kind) {
            .rel16 => {
                if (!fitsI16(delta)) a.overflow = true;
                std.mem.writeInt(u16, a.buf.items[at..][0..2], @truncate(@as(u64, @bitCast(delta))), .big);
            },
            .rel32 => {
                if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) a.overflow = true;
                std.mem.writeInt(u32, a.buf.items[at..][0..4], @truncate(@as(u64, @bitCast(delta))), .big);
            },
        }
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            const target = a.labels.items[f.label];
            if (target == unbound) return false;
            a.patch(f, target);
        }
        return !a.overflow;
    }

    // -----------------------------------------------------------------
    // Encodings

    /// RRE: a 16-bit opcode and two registers.
    fn rre(a: *Assembler, op: u16, r1: u8, r2: u8) void {
        a.h4(@as(u32, op) << 16 | @as(u32, r1) << 4 | r2);
    }
    /// RIL: an 8-bit opcode, a register, a 4-bit opcode, and 32 bits.
    fn ril(a: *Assembler, op: u8, r1: u8, op2: u4, imm: u32) void {
        a.h6(@as(u48, op) << 40 | @as(u48, r1) << 36 | @as(u48, op2) << 32 | imm);
    }
    /// RI: an 8-bit opcode, a register, a 4-bit opcode, and 16 bits.
    fn ri(a: *Assembler, op: u8, r1: u8, op2: u4, imm: u16) void {
        a.h4(@as(u32, op) << 24 | @as(u32, r1) << 20 | @as(u32, op2) << 16 | imm);
    }
    /// The displacement of a memory operand, moved up by `bias` from the
    /// stack pointer.
    fn dispOf(m: Mem) i32 {
        return if (m.base == .r15) m.disp + bias else m.disp;
    }
    /// RXY: an 8-bit opcode, a register, an index, a base, a signed 20-bit
    /// displacement, and an 8-bit opcode.
    fn rxy(a: *Assembler, op: u8, r1: u8, x2: u8, m: Mem, op2: u8) void {
        const d = dispOf(m);
        if (!fitsI20(d)) a.overflow = true;
        const u: u32 = @bitCast(d);
        a.h6(@as(u48, op) << 40 | @as(u48, r1) << 36 | @as(u48, x2) << 32 | @as(u48, m.base.n()) << 28 |
            @as(u48, u & 0xFFF) << 16 | @as(u48, (u >> 12) & 0xFF) << 8 | op2);
    }
    /// RX: an 8-bit opcode, a register, an index, a base, and an unsigned
    /// 12-bit displacement.
    fn rx(a: *Assembler, op: u8, r1: u8, x2: u8, b2: u8, d: u12) void {
        a.h4(@as(u32, op) << 24 | @as(u32, r1) << 20 | @as(u32, x2) << 16 | @as(u32, b2) << 12 | d);
    }

    // -----------------------------------------------------------------
    // Moves and immediates

    pub fn mov(a: *Assembler, dst: Reg, src: Reg) void {
        if (dst == src) return;
        a.rre(0xB904, dst.n(), src.n()); // lgr
    }

    /// Loads a 64-bit constant in one instruction, or two for a value
    /// that needs more than 32 bits.
    /// Loads a 64-bit constant. Ahead of time, the resolver decides
    /// whether a wide constant is an address, which then takes the form
    /// of `movImmReloc`.
    pub fn movImm(a: *Assembler, dst: Reg, v: u64) void {
        if (a.aot and reloc.wide(v)) {
            const res: reloc.Resolution = if (a.resolver) |rs| rs.resolve(rs.ctx, v) else .unknown;
            switch (res) {
                .address => |r| return a.movImmReloc(dst, v, r),
                .literal => {},
                .unknown => a.unrelocated += 1,
            }
        }
        a.movImmRaw(dst, v);
    }
    /// Loads an address, or a value that `r` names as a literal. Ahead of
    /// time an address takes a form whose bytes the loader patches.
    pub fn movImmReloc(a: *Assembler, dst: Reg, v: u64, r: reloc.Reloc) void {
        if (!a.aot or r.kind == .literal) return a.movImmRaw(dst, v);
        a.record(a.offset(), .s390_pair, r);
        a.ril(0xC0, dst.n(), 0xE, @truncate(v >> 32)); // llihf
        a.ril(0xC0, dst.n(), 0x9, @truncate(v)); // iilf
    }
    fn record(a: *Assembler, at: u32, form: reloc.Form, r: reloc.Reloc) void {
        a.relocs.append(a.gpa, .{ .at = at, .form = form, .r = r }) catch {
            a.oom = true;
        };
    }
    /// Stores an address, or a value that `r` names as a literal.
    pub fn storeImm64Reloc(a: *Assembler, m: Mem, v: u64, r: reloc.Reloc) void {
        if (!a.aot) return a.storeImm64(m, v);
        a.movImmReloc(s0, v, r);
        a.store64(s0, m);
    }
    fn movImmRaw(a: *Assembler, dst: Reg, v: u64) void {
        const sv: i64 = @bitCast(v);
        if (fitsI16(sv)) return a.ri(0xA7, dst.n(), 0x9, @truncate(v)); // lghi
        if (sv >= std.math.minInt(i32) and sv <= std.math.maxInt(i32)) return a.ril(0xC0, dst.n(), 0x1, @truncate(v)); // lgfi
        if (v >> 32 == 0) return a.ril(0xC0, dst.n(), 0xF, @truncate(v)); // llilf
        a.ril(0xC0, dst.n(), 0xE, @truncate(v >> 32)); // llihf
        if (v & 0xFFFF_FFFF != 0) a.ril(0xC0, dst.n(), 0x9, @truncate(v)); // iilf
    }

    // -----------------------------------------------------------------
    // Memory

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.rxy(0xE3, dst.n(), 0, m, 0x04); // lg
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.rxy(0xE3, src.n(), 0, m, 0x24); // stg
    }

    // Words the size of a pointer, such as a pointer, a count, or a stack
    // index, which are 64 bits on this target (spec/design/platforms.md,
    // "32-bit ARM").
    pub const loadWord = load64;
    pub const storeWord = store64;
    pub const storePairWord = storePair64;
    pub const storeImmWord = storeImm64;
    pub const jumpIfMemWord = jumpIfMem;
    /// A call of a routine whose arguments and result are all 64-bit
    /// integers, which on a 64-bit target is a plain call.
    pub const callWide = call;
    pub const callWideReloc = callReloc;

    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        a.rxy(0xE3, dst.n(), 0, m, 0x16); // llgf
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.rxy(0xE3, src.n(), 0, m, 0x50); // sty
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.rxy(0xE3, dst.n(), 0, m, 0x90); // llgc
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        a.rxy(0xE3, src.n(), 0, m, 0x72); // stcy
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.rxy(0xE3, dst.n(), 0, m, 0x91); // llgh
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.rxy(0xE3, src.n(), 0, m, 0x70); // sthy
    }
    pub fn storeImm16(a: *Assembler, m: Mem, v: u16) void {
        a.movImm(s0, v);
        a.store16(s0, m);
    }
    /// Stores two 64-bit registers at `m` and `m + 8`.
    pub fn storePair64(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        a.store64(first, m);
        a.store64(second, .{ .base = m.base, .disp = m.disp + 8 });
    }
    /// Stores the low halves of two registers at `m` and `m + 4`.
    pub fn storePair32(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        a.store32(first, m);
        a.store32(second, .{ .base = m.base, .disp = m.disp + 4 });
    }
    /// z/Architecture has no register that reads as zero in a store.
    pub const zero_reg: ?Reg = null;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        a.rxy(0xED, dst.n(), 0, m, 0x65); // ldy
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.rxy(0xED, src.n(), 0, m, 0x67); // stdy
    }
    /// Stores a tag held as a small integer as the whole tag word at `m`.
    /// The tag is the high byte of its word on this big-endian target.
    pub fn storeTag(a: *Assembler, tag: Reg, m: Mem) void {
        a.sllg(s0, tag, 56);
        a.store64(s0, m);
    }
    /// Stores a payload and a tag held as a small integer as a value.
    pub fn storeValue(a: *Assembler, payload: Reg, tag: Reg, m: Mem) void {
        a.store64(payload, m);
        a.storeTag(tag, .{ .base = m.base, .disp = m.disp + 8 });
    }
    /// Stores a 64-bit constant.
    pub fn storeImm64(a: *Assembler, m: Mem, v: u64) void {
        a.movImm(s0, v);
        a.store64(s0, m);
    }
    pub fn storeImm32(a: *Assembler, m: Mem, v: u32) void {
        a.movImm(s0, v);
        a.store32(s0, m);
    }
    /// Prepares `zero16`, which needs no preparation here.
    pub fn zeroPrepare(a: *Assembler) void {
        _ = a;
    }
    /// Clears 16 bytes with xc, or with two stores of a zeroed register
    /// when the displacement does not fit 12 bits.
    pub fn zero16(a: *Assembler, m: Mem) void {
        const d = dispOf(m);
        if (fitsU12(d)) {
            const u: u48 = @intCast(d);
            return a.h6(0xD7 << 40 | 15 << 32 | @as(u48, m.base.n()) << 28 | u << 16 | @as(u48, m.base.n()) << 12 | u);
        }
        a.movImm(s0, 0);
        a.storePair64(s0, s0, m);
    }
    /// Copies 16 bytes with mvc, or through s0 when a displacement does
    /// not fit 12 bits.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        a.copyBytes(dst, src, 16);
    }
    fn copyBytes(a: *Assembler, dst: Mem, src: Mem, n: u8) void {
        const dd = dispOf(dst);
        const ds = dispOf(src);
        if (fitsU12(dd) and fitsU12(ds)) {
            return a.h6(0xD2 << 40 | @as(u48, n - 1) << 32 | @as(u48, dst.base.n()) << 28 | @as(u48, @intCast(dd)) << 16 |
                @as(u48, src.base.n()) << 12 | @as(u48, @intCast(ds)));
        }
        var i: i32 = 0;
        while (i < n) : (i += 8) {
            a.load64(s0, .{ .base = src.base, .disp = src.disp + i });
            a.store64(s0, .{ .base = dst.base, .disp = dst.disp + i });
        }
    }
    /// dst = base + disp.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        if (dispOf(m) == 0) return a.mov(dst, m.base);
        a.rxy(0xE3, dst.n(), 0, m, 0x71); // lay
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.sllg(s0, index, shift);
        a.mov(dst, b);
        a.rre(0xB908, dst.n(), s0.n()); // agr
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.sllg(s0, index, shift);
        a.mov(dst, b);
        a.rre(0xB909, dst.n(), s0.n()); // sgr
    }
    /// dst = src << n.
    fn sllg(a: *Assembler, dst: Reg, src: Reg, n: u6) void {
        a.h6(0xEB << 40 | @as(u48, dst.n()) << 36 | @as(u48, src.n()) << 32 | @as(u48, n) << 16 | 0x0D);
    }

    // -----------------------------------------------------------------
    // Integer arithmetic. Each operation computes dst = dst op src.

    pub fn add(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB908, dst.n(), src.n());
    }
    pub fn sub(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB909, dst.n(), src.n());
    }
    pub fn mul(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB90C, dst.n(), src.n());
    }
    pub fn @"and"(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB980, dst.n(), src.n());
    }
    pub fn @"or"(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB981, dst.n(), src.n());
    }
    pub fn xor(a: *Assembler, dst: Reg, src: Reg) void {
        a.rre(0xB982, dst.n(), src.n());
    }
    pub fn neg(a: *Assembler, dst: Reg) void {
        a.rre(0xB903, dst.n(), dst.n()); // lcgr
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.movImm(s0, @bitCast(@as(i64, -1)));
        a.xor(dst, s0);
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        a.addImm3(dst, dst, v);
    }
    /// Divides x by y into the pair r0 and r1: the remainder in r0, the
    /// quotient in r1. A divisor in r1 moves to r14 first.
    fn divide(a: *Assembler, x: Reg, y: Reg) Reg {
        var d = y;
        if (y == .r1) {
            a.mov(.r14, y);
            d = .r14;
        }
        a.mov(.r1, x);
        a.rre(0xB90D, 0, d.n()); // dsgr r0, d
        return d;
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        _ = a.divide(x, y);
        a.mov(quot, .r1);
        a.mov(rem, .r0);
    }

    // -----------------------------------------------------------------
    // Floats

    fn fop(a: *Assembler, op: u16, dst: FReg, x: FReg, y: FReg, commutes: bool) void {
        if (dst == x) return a.rre(op, dst.n(), y.n());
        if (dst == y and commutes) return a.rre(op, dst.n(), x.n());
        if (dst == y) {
            a.fmov(fs0, y);
            a.fmov(dst, x);
            return a.rre(op, dst.n(), fs0.n());
        }
        a.fmov(dst, x);
        a.rre(op, dst.n(), y.n());
    }
    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB31A, dst.n(), src.n());
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB31B, dst.n(), src.n());
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB31C, dst.n(), src.n());
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB31D, dst.n(), src.n());
    }
    /// Converts a signed integer to a float.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.rre(0xB3A5, dst.n(), src.n()); // cdgbr
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.rre(0xB3C1, dst.n(), src.n()); // ldgr
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.rre(0xB3CD, dst.n(), src.n()); // lgdr
    }
    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.h2(0x2800 | @as(u16, dst.n()) << 4 | src.n()); // ldr
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB313, dst.n(), src.n()); // lcdbr
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB310, dst.n(), src.n()); // lpdbr
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.rre(0xB315, dst.n(), src.n()); // sqdbr
    }
    /// The emitter takes the path of a target without an instruction that
    /// rounds to an integral float.
    pub fn fround(a: *Assembler, dst: FReg, src: FReg, up: bool) void {
        _ = a;
        _ = dst;
        _ = src;
        _ = up;
        unreachable;
    }
    pub const has_fround = false;
    /// Converts a float to a signed integer, truncating (rounding mode 5).
    pub fn floatToInt(a: *Assembler, dst: Reg, src: FReg) void {
        a.h4(0xB3A9_5000 | @as(u32, dst.n()) << 4 | src.n()); // cgdbr dst, 5, src
    }

    // Three-operand forms: dst = x op y.
    fn op3(a: *Assembler, op: u16, dst: Reg, x: Reg, y: Reg, commutes: bool) void {
        if (dst == x) return a.rre(op, dst.n(), y.n());
        if (dst == y and commutes) return a.rre(op, dst.n(), x.n());
        if (dst == y) {
            a.mov(s0, y);
            a.mov(dst, x);
            return a.rre(op, dst.n(), s0.n());
        }
        a.mov(dst, x);
        a.rre(op, dst.n(), y.n());
    }
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB908, dst, x, y, true);
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB909, dst, x, y, false);
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB90C, dst, x, y, true);
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB980, dst, x, y, true);
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB981, dst, x, y, true);
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.op3(0xB982, dst, x, y, true);
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0xB31A, dst, x, y, true);
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0xB31B, dst, x, y, false);
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0xB31C, dst, x, y, true);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0xB31D, dst, x, y, false);
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        if (v == 0) return a.mov(dst, x);
        if (x != .r0 and fitsI20(v)) return a.rxy(0xE3, dst.n(), 0, .{ .base = x, .disp = v }, 0x71); // lay
        a.mov(dst, x);
        a.ril(0xC2, dst.n(), 0x8, @bitCast(v)); // agfi
    }
    /// Loads and stores of the word at [b + index * 8]. r0 cannot index,
    /// so the scaled index goes into the destination when that is free,
    /// and is otherwise added to the base and taken off again.
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        if (dst != b) {
            a.sllg(dst, index, 3);
            return a.rxy(0xE3, dst.n(), dst.n(), .{ .base = b }, 0x04); // lg dst, 0(dst, b)
        }
        a.sllg(s0, index, 3);
        a.add(dst, s0);
        a.load64(dst, .{ .base = dst });
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        a.sllg(s0, index, 3);
        a.add(b, s0);
        a.store64(src, .{ .base = b });
        a.sub(b, s0);
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. The signs are
    /// tested with branches, so no free register is needed.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        _ = tmp;
        _ = tmp2;
        const d = a.divide(x, y);
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        const done = a.newLabel();
        const negative = a.newLabel();
        const adjust = a.newLabel();
        a.rre(0xB902, 0, 0); // ltgr r0, r0
        a.brc(8, done);
        a.brc(4, negative);
        a.rre(0xB902, d.n(), d.n()); // ltgr d, d
        a.brc(10, done);
        a.jmp(adjust);
        a.bind(negative);
        a.rre(0xB902, d.n(), d.n());
        a.brc(4, done);
        a.bind(adjust);
        if (mod) a.rre(0xB908, 0, d.n()) else a.ri(0xA7, 1, 0xB, @bitCast(@as(i16, -1))); // agr r0, d / aghi r1, -1
        a.bind(done);
        a.mov(dst, if (mod) .r0 else .r1);
    }
    /// Copies one 64-bit word.
    pub fn copy8(a: *Assembler, dst: Mem, src: Mem) void {
        a.copyBytes(dst, src, 8);
    }
    /// Loads a float constant from its bits.
    pub fn fmovImm(a: *Assembler, dst: FReg, bits: u64) void {
        a.movImm(s0, bits);
        a.bitsToFloat(dst, s0);
    }
    /// The address of the native stack pointer plus `disp`.
    pub fn leaSp(a: *Assembler, dst: Reg, disp: i32) void {
        a.lea(dst, .{ .base = .r15, .disp = disp });
    }
    /// Moves the native stack pointer by `v` bytes.
    pub fn moveSp(a: *Assembler, v: i32) void {
        if (v == 0) return;
        a.rxy(0xE3, 15, 0, .{ .base = .r15, .disp = v - bias }, 0x71); // lay r15, v(r15)
    }

    // -----------------------------------------------------------------
    // Control flow

    /// A branch on the condition code. A label that is bound and in reach
    /// gets brc, and any other brcl.
    fn brc(a: *Assembler, mask: u4, l: Label) void {
        if (a.reaches(l)) {
            a.fix(l, .rel16);
            return a.ri(0xA7, mask, 0x4, 0);
        }
        a.fix(l, .rel32);
        a.ril(0xC0, mask, 0x4, 0);
    }
    fn reaches(a: *Assembler, l: Label) bool {
        if (l >= a.labels.items.len or a.labels.items[l] == unbound) return false;
        return @as(i64, a.labels.items[l]) - @as(i64, a.offset()) >= -65536;
    }
    pub fn jmp(a: *Assembler, l: Label) void {
        // Always brcl, so that every jump has the length linkPastJump
        // counts.
        a.fix(l, .rel32);
        a.ril(0xC0, 15, 0x4, 0);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.h2(0x07F0 | @as(u16, r.n())); // br
    }
    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        switch (c) {
            .mi, .pl => {
                a.mov(s0, x);
                a.sub(s0, y);
                a.rre(0xB902, 0, 0); // ltgr r0, r0
                a.brc(if (c == .mi) 4 else 10, l);
            },
            else => {
                const m = maskOf(c);
                if (a.reaches(l)) {
                    a.fix(l, .rel16);
                    // cgrj or clgrj
                    return a.h6(0xEC << 40 | @as(u48, x.n()) << 36 | @as(u48, y.n()) << 32 | @as(u48, m.mask) << 12 | (if (m.logical) @as(u48, 0x65) else 0x64));
                }
                a.rre(if (m.logical) 0xB921 else 0xB920, x.n(), y.n()); // clgr or cgr
                a.brc(m.mask, l);
            },
        }
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (c == .mi or c == .pl) {
            a.movImm(s0, @bitCast(@as(i64, v)));
            return a.jumpIf(c, x, s0, l);
        }
        const m = maskOf(c);
        const short = if (m.logical) v >= 0 and v < 256 else v >= -128 and v < 128;
        if (short and a.reaches(l)) {
            a.fix(l, .rel16);
            // cgij or clgij
            return a.h6(0xEC << 40 | @as(u48, x.n()) << 36 | @as(u48, m.mask) << 32 | @as(u48, @as(u8, @truncate(@as(u32, @bitCast(v))))) << 8 | (if (m.logical) @as(u48, 0x7D) else 0x7C));
        }
        if (m.logical and v < 0) {
            a.movImm(s0, @bitCast(@as(i64, v)));
            a.rre(0xB921, x.n(), s0.n());
        } else a.ril(0xC2, x.n(), if (m.logical) 0xE else 0xC, @bitCast(v)); // clgfi or cgfi
        a.brc(m.mask, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.rre(0xB912, 0, x.n()); // ltgfr r0, x
        a.brc(if (zero) 8 else 6, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.h6(0xEB << 40 | @as(u48, v) << 32 | memBits(m) | 0x55); // cliy
        if (!fitsI20(dispOf(m))) a.overflow = true;
        const mk = maskOf(switch (c) {
            .lt => .lo,
            .ge => .hs,
            .gt => .hi,
            .le => .ls,
            else => c,
        });
        a.brc(mk.mask, l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        a.h6(0xEB << 40 | @as(u48, @as(u8, 1) << bit) << 32 | memBits(m) | 0x51); // tmy
        if (!fitsI20(dispOf(m))) a.overflow = true;
        // tm sets condition code 0 when the bit is clear and 3 when it is
        // set.
        a.brc(if (set) 1 else 8, l);
    }
    /// The base and the 20-bit displacement of an SIY or RSY operand.
    fn memBits(m: Mem) u48 {
        const u: u32 = @bitCast(dispOf(m));
        return @as(u48, m.base.n()) << 28 | @as(u48, u & 0xFFF) << 16 | @as(u48, (u >> 12) & 0xFF) << 8;
    }
    /// Branches when the floats compare as `c`. cdbr sets condition code
    /// 0 for equal, 1 for low, 2 for high, and 3 for unordered.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        a.rre(0xB319, x.n(), y.n());
        a.brc(switch (c) {
            .lt => 4,
            .le => 12,
            .eq => 8,
            .nlt => 11,
            .nle => 3,
            .ne => 7,
        }, l);
    }

    /// Calls a function at an absolute address through r14, which the
    /// call then sets to the return address.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(.r14, addr);
        a.h2(0x0DEE); // basr r14, r14
    }
    /// Calls a function that takes five words. Every argument travels
    /// in a register on this target, as for `call`.
    pub const call5 = call;
    /// Arithmetic on words the size of a pointer, such as a stack index
    /// or a count, which a register of this target holds whole.
    pub const addWord = add;
    pub const subWord = sub;
    pub const addImmWord = addImm;
    /// Declares that a register holds no value that later code reads.
    /// Every register of this target is whole, so nothing follows.
    pub inline fn dead(a: *Assembler, r: Reg) void {
        _ = a;
        _ = r;
    }
    /// Calls a routine that returns two words, such as `jit.Target`. The
    /// convention returns them through memory whose address goes in r2,
    /// so the arguments move up a register, 16 bytes of new frame receive
    /// the result, and the result moves into the two result registers.
    /// The routine takes at most four arguments.
    pub fn callPair(a: *Assembler, addr: usize) void {
        a.mov(.r6, .r5);
        a.mov(.r5, .r4);
        a.mov(.r4, .r3);
        a.mov(.r3, .r2);
        a.moveSp(-16);
        a.leaSp(.r2, 0);
        a.call(addr);
        a.load64(.r3, .{ .base = .r15, .disp = 8 });
        a.load64(.r2, .{ .base = .r15 });
        a.moveSp(16);
    }
    /// Calls the routine that `r` names, at `addr` in this process.
    pub fn callReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        if (!a.aot) return a.call(addr);
        a.movImmReloc(.r14, addr, r);
        a.h2(0x0DEE); // basr r14, r14
    }
    /// `callPair` for the routine that `r` names.
    pub fn callPairReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        if (!a.aot) return a.callPair(addr);
        a.mov(.r6, .r5);
        a.mov(.r5, .r4);
        a.mov(.r4, .r3);
        a.mov(.r3, .r2);
        a.moveSp(-16);
        a.leaSp(.r2, 0);
        a.callReloc(addr, r);
        a.load64(.r3, .{ .base = .r15, .disp = 8 });
        a.load64(.r2, .{ .base = .r15 });
        a.moveSp(16);
    }
    /// Calls a routine in the same code, which ends with `leave`.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.fix(l, .rel32);
        a.ril(0xC0, 14, 0x5, 0); // brasl r14
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.h2(0x0DE0 | @as(u16, r.n())); // basr r14, r
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.jmpReg(.r14);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry. That
    /// jump is always one brcl.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.rx(0x41, dst.n(), 0, 14, 6); // la dst, 6(r14)
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        _ = a;
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.moveSp(-size);
        a.store64(.r14, .{ .base = .r15, .disp = size - 8 });
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        a.load64(.r14, .{ .base = .r15, .disp = size - 8 });
        a.moveSp(size);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        a.unsaveLink(size);
        a.retLocal();
    }
    /// Sets the native stack pointer from a value that `leaSp` produced.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.rxy(0xE3, 15, 0, .{ .base = src, .disp = -bias }, 0x71); // lay r15, -160(src)
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        if (c == .mi or c == .pl) {
            a.load64(s0, m);
            a.mov(.r14, s0);
            return a.jumpIf(c, x, .r14, l);
        }
        const mk = maskOf(c);
        a.rxy(0xE3, x.n(), 0, m, if (mk.logical) 0x21 else 0x20); // clg or cg
        a.brc(mk.mask, l);
    }
    /// Opens a routine entered by `callLocal` that calls other functions.
    pub fn enterLocal(a: *Assembler) void {
        a.store64(.r14, .{ .base = .r15, .disp = link_slot });
    }
    /// Returns from a routine opened by `enterLocal`.
    pub fn leaveLocal(a: *Assembler) void {
        a.load64(.r14, .{ .base = .r15, .disp = link_slot });
        a.retLocal();
    }
    pub fn trap(a: *Assembler) void {
        a.h2(0x0000);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves r6 to r14 in the save area of its caller, opens its frame,
    /// saves the float registers it uses, and loads the pinned registers.
    pub fn prologue(a: *Assembler) void {
        a.h6(0xEB6EF0300024); // stmg r6, r14, 48(r15)
        a.rxy(0xE3, 15, 0, .{ .base = .r15, .disp = -(bias + frame_size) - bias }, 0x71); // lay r15, -(bias + frame_size)(r15)
        for ([_]FReg{ .f8, .f9, .f10 }, 0..) |f, i| a.storeF(f, .{ .base = .r15, .disp = @intCast(8 + i * 8) });
        a.mov(thread, .r2);
        a.mov(stop, .r3);
        a.mov(base, .r5);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        for ([_]FReg{ .f8, .f9, .f10 }, 0..) |f, i| a.loadF(f, .{ .base = .r15, .disp = @intCast(8 + i * 8) });
        a.rxy(0xE3, 15, 0, .{ .base = .r15, .disp = frame_size }, 0x71); // lay r15, (bias + frame_size)(r15)
        a.h6(0xEB6EF0300004); // lmg r6, r14, 48(r15)
        a.retLocal();
    }
};

comptime {
    std.debug.assert((bias + frame_size) % 8 == 0);
    std.debug.assert(link_slot + 8 <= 8 and 8 + 3 * 8 <= frame_size);
}

fn expectBytes(a: *Assembler, hex: []const u8) !void {
    var want: [256]u8 = undefined;
    const w = try std.fmt.hexToBytes(&want, hex);
    try std.testing.expectEqualSlices(u8, w, a.buf.items);
}

// The expected bytes come from the GNU assembler syntax shown next to
// each call, assembled for z/Architecture.

test "s390x moves, memory, and arithmetic" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.r2, .r7); // lgr %r2,%r7
    a.movImm(.r3, 0); // lghi %r3,0
    a.movImm(.r11, 291); // lghi %r11,291
    a.movImm(.r11, 305419896); // lgfi %r11,305419896
    a.movImm(.r11, 4294967295); // llilf %r11,4294967295
    a.load64(.r11, .{ .base = .r8, .disp = 16 }); // lg %r11,16(%r8)
    a.store64(.r11, .{ .base = .r8, .disp = 24 }); // stg %r11,24(%r8)
    a.load64(.r11, .{ .base = .r8, .disp = -16 }); // lg %r11,-16(%r8)
    a.load8(.r12, .{ .base = .r8, .disp = 8 }); // llgc %r12,8(%r8)
    a.load32(.r12, .{ .base = .r7, .disp = 4 }); // llgf %r12,4(%r7)
    a.load16(.r11, .{ .base = .r8, .disp = 2 }); // llgh %r11,2(%r8)
    a.store16(.r11, .{ .base = .r8, .disp = 2 }); // sthy %r11,2(%r8)
    a.store32(.r11, .{ .base = .r8, .disp = 16 }); // sty %r11,16(%r8)
    a.store8(.r11, .{ .base = .r8, .disp = 1 }); // stcy %r11,1(%r8)
    a.loadF(.f0, .{ .base = .r8 }); // ldy %f0,0(%r8)
    a.storeF(.f2, .{ .base = .r8, .disp = 8 }); // stdy %f2,8(%r8)
    a.load64(.r11, .{ .base = .r8, .disp = 500000 }); // lg %r11,500000(%r8)
    a.add(.r11, .r12); // agr %r11,%r12
    a.sub(.r11, .r12); // sgr %r11,%r12
    a.mul(.r11, .r12); // msgr %r11,%r12
    a.@"and"(.r11, .r12); // ngr %r11,%r12
    a.@"or"(.r11, .r12); // ogr %r11,%r12
    a.xor(.r11, .r12); // xgr %r11,%r12
    a.neg(.r11); // lcgr %r11,%r11
    a.addImm(.r11, 5); // lay %r11,5(%r11)
    a.addImm(.r11, -5); // lay %r11,-5(%r11)
    try expectBytes(&a, "B9040027" ++ "A7390000" ++ "A7B90123" ++ "C0B112345678" ++ "C0BFFFFFFFFF" ++
        "E3B080100004" ++ "E3B080180024" ++ "E3B08FF0FF04" ++ "E3C080080090" ++ "E3C070040016" ++
        "E3B080020091" ++ "E3B080020070" ++ "E3B080100050" ++ "E3B080010072" ++ "ED0080000065" ++
        "ED2080080067" ++ "E3B081207A04" ++ "B90800BC" ++ "B90900BC" ++ "B90C00BC" ++ "B98000BC" ++
        "B98100BC" ++ "B98200BC" ++ "B90300BB" ++ "E3B0B0050071" ++ "E3B0BFFBFF71");
}

test "s390x floats, shifts, and wide constants" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.movImm(.r11, 0x0000123456789ABC); // llihf %r11,0x1234; iilf %r11,0x56789abc
    a.sllg(.r1, .r9, 4); // sllg %r1,%r9,4
    a.fadd(.f0, .f2); // adbr %f0,%f2
    a.fsub(.f0, .f2); // sdbr %f0,%f2
    a.fmul(.f0, .f2); // mdbr %f0,%f2
    a.fdiv(.f0, .f2); // ddbr %f0,%f2
    a.fmov(.f0, .f2); // ldr %f0,%f2
    a.fneg(.f0, .f2); // lcdbr %f0,%f2
    a.fabs(.f0, .f2); // lpdbr %f0,%f2
    a.fsqrt(.f0, .f2); // sqdbr %f0,%f2
    a.intToFloat(.f0, .r11); // cdgbr %f0,%r11
    a.floatToInt(.r11, .f0); // cgdbr %r11,5,%f0
    a.bitsToFloat(.f0, .r11); // ldgr %f0,%r11
    a.floatToBits(.r11, .f0); // lgdr %r11,%f0
    a.copy16(.{ .base = .r8, .disp = 32 }, .{ .base = .r8, .disp = 48 }); // mvc 32(16,%r8),48(%r8)
    a.zero16(.{ .base = .r8, .disp = 32 }); // xc 32(16,%r8),32(%r8)
    a.callReg(.r1); // basr %r14,%r1
    a.retLocal(); // br %r14
    a.linkPastJump(.r11); // la %r11,6(%r14)
    try expectBytes(&a, "C0BE00001234" ++ "C0B956789ABC" ++ "EB190004000D" ++ "B31A0002" ++ "B31B0002" ++
        "B31C0002" ++ "B31D0002" ++ "2802" ++ "B3130002" ++ "B3100002" ++ "B3150002" ++ "B3A5000B" ++
        "B3A950B0" ++ "B3C1000B" ++ "B3CD00B0" ++ "D20F80208030" ++ "D70F80208020" ++ "0DE1" ++ "07FE" ++ "41B0E006");
}

test "s390x comparisons and branches" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l0 = a.newLabel();
    const l1 = a.newLabel();
    a.bind(l0);
    a.jumpIf(.lt, .r11, .r12, l0); // cgrj %r11,%r12,4,l0
    a.jumpIf(.hi, .r11, .r12, l1); // clgr %r11,%r12; brcl 2,l1
    a.jumpIfImm(.eq, .r11, -5, l0); // cgij %r11,-5,8,l0
    a.jumpIfImm(.hs, .r11, 200, l0); // clgij %r11,200,10,l0
    a.jumpIfImm(.lt, .r11, 100000, l1); // cgfi %r11,100000; brcl 4,l1
    a.jumpIfByte(.eq, .{ .base = .r8, .disp = -8 }, 5, l1); // cliy -8(%r8),5; brcl 8,l1
    a.jumpIfFloat(.le, .f0, .f2, l0); // cdbr %f0,%f2; brc 12,l0
    a.jmp(l1); // brcl 15,l1
    a.callLocal(l0); // brasl %r14,l0
    a.bind(l1);
    try std.testing.expect(a.finish());
    try expectBytes(&a, "ECBC00004064" ++ "B92100BC" ++ "C0240000001F" ++ "ECB8FFF8FB7C" ++ "ECBAFFF5C87D" ++
        "C2BC000186A0" ++ "C04400000013" ++ "EB058FF8FF55" ++ "C0840000000D" ++ "B3190002" ++ "A7C4FFE4" ++
        "C0F400000006" ++ "C0E5FFFFFFDF");

    var b = Assembler.init(std.testing.allocator);
    defer b.deinit();
    b.jmp(b.newLabel());
    try std.testing.expect(!b.finish());
}

test "s390x entry sequence and frame" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.prologue();
    a.saveLink(16);
    try std.testing.expectEqualSlices(u8, &.{ 0xEB, 0x6E, 0xF0, 0x30, 0x00, 0x24 }, a.buf.items[0..6]); // stmg %r6,%r14,48(%r15)
    // lay %r15,-192(%r15)
    try std.testing.expectEqualSlices(u8, &.{ 0xE3, 0xF0, 0xFF, 0x40, 0xFF, 0x71 }, a.buf.items[6..12]);
}
