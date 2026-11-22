//! The ppc64le backend of the JIT assembler, for Power ISA 2.07 (POWER8)
//! and the ELFv2 calling convention. It offers the same interface as
//! `a64.zig`. Every instruction is 32 bits wide.
//!
//! Three properties of the target shape it.
//!
//! - A routine of the runtime expects its own address in r12, from which
//!   its global entry computes the table of contents in r2. Every call
//!   goes through r12 and the count register. Native code never changes
//!   r2, which holds the table of contents of the runtime.
//! - A called routine stores the link register and may store the
//!   condition register into the 32-byte header at the bottom of the
//!   frame of its caller. The stack pointer that native code sees through
//!   this interface therefore sits 32 bytes above r1, so the header of
//!   every frame stays free for the routines it calls.
//! - A conditional branch reaches 32 KB and `b` reaches 32 MB. A
//!   conditional branch to a label that is bound and in reach takes one
//!   instruction, and any other is the inverted branch over a `b`.
//!
//! Constants build in at most five instructions, so there is no pool.

const std = @import("std");
const reloc = @import("reloc.zig");

pub const Reg = enum(u5) {
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
    r16,
    r17,
    r18,
    r19,
    r20,
    r21,
    r22,
    r23,
    r24,
    r25,
    r26,
    r27,
    r28,
    r29,
    r30,
    r31,

    inline fn n(r: Reg) u32 {
        return @backingInt(r);
    }
};

pub const FReg = enum(u5) {
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
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    f26,
    f27,
    f28,
    f29,
    f30,
    f31,

    inline fn n(r: FReg) u32 {
        return @backingInt(r);
    }
};

/// The native stack pointer, as the base of a memory operand. The
/// assembler adds `bias` to every displacement from it.
pub const sp: Reg = .r1;
/// Bytes between r1 and the stack pointer that native code sees: the
/// header that the routines it calls may write.
const bias = 32;

// The registers the emitter uses. Pinned registers are the callee-saved
// r14 to r17. The temporaries are r21 to r27, which are callee-saved as
// well, so the entry sequence saves them, because the convention leaves
// too few volatile registers outside the arguments.
pub const thread: Reg = .r14;
pub const bp: Reg = .r15;
pub const base: Reg = .r16;
pub const stop: Reg = .r17;
pub const t0: Reg = .r21;
pub const t1: Reg = .r22;
pub const t2: Reg = .r23;
pub const t3: Reg = .r24;
pub const t4: Reg = .r25;
pub const t5: Reg = .r26;
pub const t6: Reg = .r27;
pub const args = [_]Reg{ .r3, .r4, .r5, .r6, .r7, .r8 };
pub const ret0: Reg = .r3;
pub const ret1: Reg = .r4;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .r5;
pub const f0: FReg = .f1;
pub const f1: FReg = .f2;
/// Scratch registers of the assembler itself. r12 also carries the
/// address of every call, and r0, which reads as zero as a base, serves
/// the link register moves and the multiplication of a remainder.
const s0: Reg = .r12;
const s1: Reg = .r11;
/// The float scratch register of the assembler.
const fs0: FReg = .f0;

/// Bytes of native stack the entry sequence reserves above the header:
/// r14 to r27 and the slot of `enterLocal`.
const frame_size = 128;
/// Offset of the slot where a shared routine keeps its return address.
const link_slot = 112;
/// The callee-saved registers that the entry sequence saves: the pinned
/// registers, r18 to r20, which the optimizing tier uses as its scratch
/// registers, and the temporaries.
const saved = [_]Reg{ .r14, .r15, .r16, .r17, .r18, .r19, .r20, .r21, .r22, .r23, .r24, .r25, .r26, .r27 };

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
    at: u32,
    label: Label,
    kind: enum { b24, b14 },
};

fn dform(op: u32, rt: u32, ra: u32, imm: i32) u32 {
    return op << 26 | rt << 21 | ra << 16 | (@as(u32, @bitCast(imm)) & 0xFFFF);
}
fn xform(rt: u32, ra: u32, rb: u32, xo: u32) u32 {
    return 31 << 26 | rt << 21 | ra << 16 | rb << 11 | xo << 1;
}
fn aform(frt: u32, fra: u32, frb: u32, xo: u32) u32 {
    return 63 << 26 | frt << 21 | fra << 16 | frb << 11 | xo << 1;
}
fn fitsI16(v: i64) bool {
    return v >= -32768 and v < 32768;
}

// Primary opcodes of the D-form instructions.
const op_addi = 14;
const op_addis = 15;
const op_ori = 24;
const op_oris = 25;
const op_andi_dot = 28;
const op_cmpli = 10;
const op_cmpi = 11;
const op_lbz = 34;
const op_lhz = 40;
const op_lwz = 32;
const op_stb = 38;
const op_sth = 44;
const op_stw = 36;
const op_lfd = 50;
const op_stfd = 54;
const op_ld = 58;
const op_std = 62;
// Extended opcodes of the X-form instructions under primary opcode 31.
const xo_add = 266;
const xo_subf = 40;
const xo_mulld = 233;
const xo_divd = 489;
const xo_neg = 104;
const xo_and = 28;
const xo_or = 444;
const xo_xor = 316;
const xo_nor = 124;
const xo_extsw = 986;
const xo_cmp = 0;
const xo_cmpl = 32;
const xo_mtvsrd = 179;
const xo_mfvsrd = 51;

/// A load or a store: its D-form opcode, its X-form extended opcode, and
/// whether its displacement must be a multiple of 4 (DS-form).
const Access = struct { d: u32, x: u32, ds: bool = false };
const acc_ld: Access = .{ .d = op_ld, .x = 21, .ds = true };
const acc_std: Access = .{ .d = op_std, .x = 149, .ds = true };
const acc_lwz: Access = .{ .d = op_lwz, .x = 23 };
const acc_stw: Access = .{ .d = op_stw, .x = 151 };
const acc_lhz: Access = .{ .d = op_lhz, .x = 279 };
const acc_sth: Access = .{ .d = op_sth, .x = 407 };
const acc_lbz: Access = .{ .d = op_lbz, .x = 87 };
const acc_stb: Access = .{ .d = op_stb, .x = 215 };
const acc_lfd: Access = .{ .d = op_lfd, .x = 599 };
const acc_stfd: Access = .{ .d = op_stfd, .x = 727 };

const mtctr_r12: u32 = 0x7D8903A6;
const bctrl: u32 = 0x4E800421;
const bctr: u32 = 0x4E800420;
const blr: u32 = 0x4E800020;
const trap_word: u32 = 0x7FE00008;
fn mflr(rt: Reg) u32 {
    return 0x7C0802A6 | rt.n() << 21;
}
fn mtlr(rs: Reg) u32 {
    return 0x7C0803A6 | rs.n() << 21;
}
fn mtctr(rs: Reg) u32 {
    return 0x7C0903A6 | rs.n() << 21;
}

/// The comparison and the branch of a condition: whether it compares
/// unsigned, the BO field that branches when the bit is set (12) or
/// clear (4), and the bit of condition field 0 it tests.
const Test = struct { unsigned: bool, bo: u32, bi: u32 };
fn testOf(c: Cond) Test {
    return switch (c) {
        .eq => .{ .unsigned = false, .bo = 12, .bi = 2 },
        .ne => .{ .unsigned = false, .bo = 4, .bi = 2 },
        .lt => .{ .unsigned = false, .bo = 12, .bi = 0 },
        .ge => .{ .unsigned = false, .bo = 4, .bi = 0 },
        .gt => .{ .unsigned = false, .bo = 12, .bi = 1 },
        .le => .{ .unsigned = false, .bo = 4, .bi = 1 },
        .lo => .{ .unsigned = true, .bo = 12, .bi = 0 },
        .hs => .{ .unsigned = true, .bo = 4, .bi = 0 },
        .hi => .{ .unsigned = true, .bo = 12, .bi = 1 },
        .ls => .{ .unsigned = true, .bo = 4, .bi = 1 },
        .mi, .pl => unreachable,
    };
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
    /// Set when a branch cannot reach its label.
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

    fn word(a: *Assembler, w: u32) void {
        a.buf.appendSlice(a.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, w))) catch {
            a.oom = true;
        };
    }

    fn fix(a: *Assembler, l: Label, kind: @FieldType(Fixup, "kind")) void {
        a.fixups.append(a.gpa, .{ .at = a.offset(), .label = l, .kind = kind }) catch {
            a.oom = true;
        };
    }

    /// Constants build in place, so there is no pool to write.
    pub fn flushPool(a: *Assembler) void {
        _ = a;
    }

    fn patch(a: *Assembler, f: Fixup, target: u32) void {
        const delta: i64 = @as(i64, target) - @as(i64, f.at);
        const u: u32 = @truncate(@as(u64, @bitCast(delta)));
        const p: *align(1) u32 = @ptrCast(a.buf.items[f.at..].ptr);
        var w = std.mem.littleToNative(u32, p.*);
        switch (f.kind) {
            .b24 => {
                if (delta < -(1 << 25) or delta >= (1 << 25)) a.overflow = true;
                w |= u & 0x03FF_FFFC;
            },
            .b14 => {
                if (delta < -(1 << 15) or delta >= (1 << 15)) a.overflow = true;
                w |= u & 0xFFFC;
            },
        }
        p.* = std.mem.nativeToLittle(u32, w);
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
    // Moves and immediates

    pub fn mov(a: *Assembler, dst: Reg, src: Reg) void {
        if (dst == src) return;
        a.word(xform(src.n(), dst.n(), src.n(), xo_or));
    }

    /// Builds the low 32 bits of `v` in `dst`, sign-extended.
    fn mov32(a: *Assembler, dst: Reg, v: u32) void {
        const sv: i32 = @bitCast(v);
        if (fitsI16(sv)) return a.word(dform(op_addi, dst.n(), 0, sv));
        a.word(dform(op_addis, dst.n(), 0, @as(i16, @bitCast(@as(u16, @truncate(v >> 16))))));
        if (v & 0xFFFF != 0) a.word(dform(op_ori, dst.n(), dst.n(), @intCast(v & 0xFFFF)));
    }

    /// Loads a 64-bit constant in at most five instructions.
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
        a.record(a.offset(), .ppc_seq, r);
        a.word(dform(op_addis, dst.n(), 0, @as(i16, @bitCast(@as(u16, @truncate(v >> 48))))));
        a.word(dform(op_ori, dst.n(), dst.n(), @intCast((v >> 32) & 0xFFFF)));
        a.sldi(dst, dst, 32);
        a.word(dform(op_oris, dst.n(), dst.n(), @intCast((v >> 16) & 0xFFFF)));
        a.word(dform(op_ori, dst.n(), dst.n(), @intCast(v & 0xFFFF)));
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
        if (sv >= std.math.minInt(i32) and sv <= std.math.maxInt(i32)) return a.mov32(dst, @truncate(v));
        // The upper word goes in first, shifted into place, and the two
        // halves of the lower word follow.
        const hi: u32 = @truncate(v >> 32);
        if (hi != 0) {
            a.mov32(dst, hi);
            a.sldi(dst, dst, 32);
        } else a.word(dform(op_addi, dst.n(), 0, 0));
        if ((v >> 16) & 0xFFFF != 0) a.word(dform(op_oris, dst.n(), dst.n(), @intCast((v >> 16) & 0xFFFF)));
        if (v & 0xFFFF != 0) a.word(dform(op_ori, dst.n(), dst.n(), @intCast(v & 0xFFFF)));
    }

    /// dst = src << n, as rldicr dst, src, n, 63 - n.
    fn sldi(a: *Assembler, dst: Reg, src: Reg, n: u6) void {
        const me: u32 = 63 - @as(u32, n);
        a.word(30 << 26 | src.n() << 21 | dst.n() << 16 | (@as(u32, n) & 0x1F) << 11 | (me & 0x1F) << 6 | (me >> 5) << 5 | 1 << 2 | (@as(u32, n) >> 5) << 1);
    }

    // -----------------------------------------------------------------
    // Memory

    /// Encodes a load or store. A displacement from the stack pointer
    /// moves up by `bias`. A displacement out of the reach of the D form,
    /// or not a multiple of 4 for a DS form, goes into s1 for the X form.
    fn access(a: *Assembler, acc: Access, rt: u32, m: Mem) void {
        const disp: i32 = if (m.base == .r1) m.disp + bias else m.disp;
        if (fitsI16(disp) and (!acc.ds or @mod(disp, 4) == 0)) return a.word(dform(acc.d, rt, m.base.n(), disp));
        a.movImm(s1, @bitCast(@as(i64, disp)));
        a.word(xform(rt, m.base.n(), s1.n(), acc.x));
    }

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(acc_ld, dst.n(), m);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.access(acc_std, src.n(), m);
    }
    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(acc_lwz, dst.n(), m);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.access(acc_stw, src.n(), m);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(acc_lbz, dst.n(), m);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        a.access(acc_stb, src.n(), m);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(acc_lhz, dst.n(), m);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.access(acc_sth, src.n(), m);
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
    /// The Power ISA has no register that reads as zero in a store.
    pub const zero_reg: ?Reg = null;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        a.access(acc_lfd, dst.n(), m);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.access(acc_stfd, src.n(), m);
    }
    /// Stores a tag held as a small integer as the whole tag word at `m`.
    /// The tag is the low byte of its word on this little-endian target.
    pub fn storeTag(a: *Assembler, tag: Reg, m: Mem) void {
        a.store64(tag, m);
    }
    /// Stores a payload and a tag held as a small integer as a value.
    pub fn storeValue(a: *Assembler, payload: Reg, tag: Reg, m: Mem) void {
        a.storePair64(payload, tag, m);
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
    /// Clears 16 bytes with two stores of a zeroed scratch register.
    pub fn zero16(a: *Assembler, m: Mem) void {
        a.word(dform(op_addi, s0.n(), 0, 0));
        a.storePair64(s0, s0, m);
    }
    /// Copies 16 bytes as two 64-bit words.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        const second_src: Mem = .{ .base = src.base, .disp = src.disp + 8 };
        const second_dst: Mem = .{ .base = dst.base, .disp = dst.disp + 8 };
        if (a.direct(src) and a.direct(second_src) and a.direct(dst) and a.direct(second_dst)) {
            a.load64(s0, src);
            a.load64(s1, second_src);
            a.store64(s0, dst);
            a.store64(s1, second_dst);
            return;
        }
        // A far address takes s1, so each word goes through s0 alone.
        a.copy8(dst, src);
        a.copy8(second_dst, second_src);
    }
    /// Whether a 64-bit access at `m` takes the DS form, which leaves s1
    /// free.
    fn direct(a: *Assembler, m: Mem) bool {
        _ = a;
        const disp: i32 = if (m.base == .r1) m.disp + bias else m.disp;
        return fitsI16(disp) and @mod(disp, 4) == 0;
    }
    /// dst = base + disp.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        const disp: i32 = if (m.base == .r1) m.disp + bias else m.disp;
        if (disp == 0) return a.mov(dst, m.base);
        if (fitsI16(disp)) return a.word(dform(op_addi, dst.n(), m.base.n(), disp));
        a.movImm(s1, @bitCast(@as(i64, disp)));
        a.add3(dst, m.base, s1);
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        if (shift == 0) return a.add3(dst, b, index);
        a.sldi(s0, index, shift);
        a.add3(dst, b, s0);
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.sldi(s0, index, shift);
        a.sub3(dst, b, s0);
    }

    // -----------------------------------------------------------------
    // Integer arithmetic. Each operation computes dst = dst op src.

    pub fn add(a: *Assembler, dst: Reg, src: Reg) void {
        a.add3(dst, dst, src);
    }
    pub fn sub(a: *Assembler, dst: Reg, src: Reg) void {
        a.sub3(dst, dst, src);
    }
    pub fn mul(a: *Assembler, dst: Reg, src: Reg) void {
        a.mul3(dst, dst, src);
    }
    pub fn @"and"(a: *Assembler, dst: Reg, src: Reg) void {
        a.and3(dst, dst, src);
    }
    pub fn @"or"(a: *Assembler, dst: Reg, src: Reg) void {
        a.or3(dst, dst, src);
    }
    pub fn xor(a: *Assembler, dst: Reg, src: Reg) void {
        a.xor3(dst, dst, src);
    }
    pub fn neg(a: *Assembler, dst: Reg) void {
        a.word(xform(dst.n(), dst.n(), 0, xo_neg));
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.word(xform(dst.n(), dst.n(), dst.n(), xo_nor));
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        a.addImm3(dst, dst, v);
    }
    /// s0 = x / y truncated, and s1 = x - s0 * y. POWER8 has no
    /// remainder instruction.
    fn divide(a: *Assembler, x: Reg, y: Reg) void {
        a.word(xform(s0.n(), x.n(), y.n(), xo_divd));
        a.word(xform(0, s0.n(), y.n(), xo_mulld)); // mulld r0, s0, y
        a.word(xform(s1.n(), 0, x.n(), xo_subf)); // subf s1, r0, x
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        a.divide(x, y);
        a.mov(quot, s0);
        a.mov(rem, s1);
    }

    // -----------------------------------------------------------------
    // Floats

    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.fadd3(dst, dst, src);
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.fsub3(dst, dst, src);
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.fmul3(dst, dst, src);
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.fdiv3(dst, dst, src);
    }
    /// Converts a signed integer to a float. The conversion runs inside
    /// the float register.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.bitsToFloat(dst, src);
        a.word(aform(dst.n(), 0, dst.n(), 846)); // fcfid
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(xform(dst.n(), src.n(), 0, xo_mtvsrd));
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(xform(src.n(), dst.n(), 0, xo_mfvsrd));
    }
    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.word(aform(dst.n(), 0, src.n(), 72));
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(aform(dst.n(), 0, src.n(), 40));
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(aform(dst.n(), 0, src.n(), 264));
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(aform(dst.n(), 0, src.n(), 22));
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
    /// Converts a float to a signed integer, truncating.
    pub fn floatToInt(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(aform(fs0.n(), 0, src.n(), 815)); // fctidz
        a.floatToBits(dst, fs0);
    }

    // Three-operand forms: dst = x op y.
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(dst.n(), x.n(), y.n(), xo_add));
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(dst.n(), y.n(), x.n(), xo_subf));
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(dst.n(), x.n(), y.n(), xo_mulld));
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(x.n(), dst.n(), y.n(), xo_and));
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(x.n(), dst.n(), y.n(), xo_or));
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(xform(x.n(), dst.n(), y.n(), xo_xor));
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(aform(dst.n(), x.n(), y.n(), 21));
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(aform(dst.n(), x.n(), y.n(), 20));
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        // fmul takes its second operand in the FRC field.
        a.word(63 << 26 | dst.n() << 21 | x.n() << 16 | y.n() << 6 | 25 << 1);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(aform(dst.n(), x.n(), y.n(), 18));
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        if (v == 0) return a.mov(dst, x);
        if (fitsI16(v)) return a.word(dform(op_addi, dst.n(), x.n(), v));
        a.movImm(s1, @bitCast(@as(i64, v)));
        a.add3(dst, x, s1);
    }
    /// Loads and stores of the word at [b + index * 8].
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        a.sldi(s0, index, 3);
        a.word(xform(dst.n(), b.n(), s0.n(), acc_ld.x));
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        a.sldi(s0, index, 3);
        a.word(xform(src.n(), b.n(), s0.n(), acc_std.x));
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. `tmp` is a
    /// free register other than the operands.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        _ = tmp2;
        a.divide(x, y);
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.word(dform(op_cmpi, 1 << 0, s1.n(), 0)); // cmpdi s1, 0
        a.word(16 << 26 | 12 << 21 | 2 << 16 | 20); // beq +20
        a.xor3(tmp, s1, y);
        a.word(dform(op_cmpi, 1 << 0, tmp.n(), 0)); // cmpdi tmp, 0
        a.word(16 << 26 | 4 << 21 | 0 << 16 | 8); // bge +8
        if (mod) a.add3(s1, s1, y) else a.word(dform(op_addi, s0.n(), s0.n(), -1));
        a.mov(dst, if (mod) s1 else s0);
    }
    /// Copies one 64-bit word.
    pub fn copy8(a: *Assembler, dst: Mem, src: Mem) void {
        a.load64(s0, src);
        a.store64(s0, dst);
    }
    /// Loads a float constant from its bits.
    pub fn fmovImm(a: *Assembler, dst: FReg, bits: u64) void {
        a.movImm(s0, bits);
        a.bitsToFloat(dst, s0);
    }
    /// The address of the native stack pointer plus `disp`.
    pub fn leaSp(a: *Assembler, dst: Reg, disp: i32) void {
        a.lea(dst, .{ .base = .r1, .disp = disp });
    }
    /// Moves the native stack pointer by `v` bytes.
    pub fn moveSp(a: *Assembler, v: i32) void {
        if (v == 0) return;
        a.word(dform(op_addi, 1, 1, v));
    }

    // -----------------------------------------------------------------
    // Control flow

    pub fn jmp(a: *Assembler, l: Label) void {
        a.fix(l, .b24);
        a.word(18 << 26);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.word(mtctr(r));
        a.word(bctr);
    }
    /// A conditional branch on a bit of condition field 0. A label that
    /// is bound and in reach gets one instruction. Any other gets the
    /// inverted branch over a `b`.
    fn bc(a: *Assembler, bo: u32, bi: u32, l: Label) void {
        if (l < a.labels.items.len and a.labels.items[l] != unbound) {
            const delta = @as(i64, a.labels.items[l]) - @as(i64, a.offset());
            if (delta >= -(1 << 15)) {
                a.fix(l, .b14);
                return a.word(16 << 26 | bo << 21 | bi << 16);
            }
        }
        a.word(16 << 26 | (bo ^ 8) << 21 | bi << 16 | 8);
        a.jmp(l);
    }
    fn cmpReg(a: *Assembler, unsigned: bool, x: Reg, y: Reg) void {
        a.word(31 << 26 | 1 << 21 | x.n() << 16 | y.n() << 11 | (if (unsigned) @as(u32, xo_cmpl) else xo_cmp) << 1);
    }
    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        switch (c) {
            .mi, .pl => {
                a.sub3(s0, x, y);
                a.word(dform(op_cmpi, 1, s0.n(), 0));
                a.bc(if (c == .mi) 12 else 4, 0, l);
            },
            else => {
                const t = testOf(c);
                a.cmpReg(t.unsigned, x, y);
                a.bc(t.bo, t.bi, l);
            },
        }
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (c != .mi and c != .pl) {
            const t = testOf(c);
            if (!t.unsigned and fitsI16(v)) {
                a.word(dform(op_cmpi, 1, x.n(), v));
                return a.bc(t.bo, t.bi, l);
            }
            if (t.unsigned and v >= 0 and v < 65536) {
                a.word(dform(op_cmpli, 1, x.n(), v));
                return a.bc(t.bo, t.bi, l);
            }
        }
        a.movImm(s1, @bitCast(@as(i64, v)));
        a.jumpIf(c, x, s1, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.word(xform(x.n(), s0.n(), 0, xo_extsw));
        a.word(dform(op_cmpi, 1, s0.n(), 0));
        a.bc(if (zero) 12 else 4, 2, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.load8(s0, m);
        a.jumpIfImm(c, s0, v, l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        a.load8(s0, m);
        // andi. sets the equal bit of condition field 0 when the result
        // is zero.
        a.word(dform(op_andi_dot, s0.n(), s0.n(), @as(i32, 1) << bit));
        a.bc(if (set) 4 else 12, 2, l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        // fcmpu sets exactly one of less, greater, equal, and unordered,
        // so a NaN operand clears the first three.
        a.word(63 << 26 | x.n() << 16 | y.n() << 11);
        switch (c) {
            .lt => a.bc(12, 0, l),
            .nlt => a.bc(4, 0, l),
            .eq => a.bc(12, 2, l),
            .ne => a.bc(4, 2, l),
            .le, .nle => {
                a.word(0x4C601382); // cror 3, 0, 2
                a.bc(if (c == .le) 12 else 4, 3, l);
            },
        }
    }

    /// Calls a function at an absolute address through r12, where its
    /// global entry expects it.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(s0, addr);
        a.word(mtctr_r12);
        a.word(bctrl);
    }
    /// Calls a routine that returns two words in the two result
    /// registers, such as `jit.Target`.
    pub fn callPair(a: *Assembler, addr: usize) void {
        a.call(addr);
    }
    /// Calls the routine that `r` names, at `addr` in this process.
    pub fn callReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        if (!a.aot) return a.call(addr);
        a.movImmReloc(s0, addr, r);
        a.word(mtctr_r12);
        a.word(bctrl);
    }
    /// `callPair` for the routine that `r` names.
    pub fn callPairReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        a.callReloc(addr, r);
    }
    /// Calls a routine in the same code, which ends with `leave`.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.fix(l, .b24);
        a.word(18 << 26 | 1);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.mov(s0, r);
        a.word(mtctr_r12);
        a.word(bctrl);
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.word(blr);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry. That
    /// jump is always one `b`.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.word(mflr(dst));
        a.word(dform(op_addi, dst.n(), dst.n(), 4));
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        _ = a;
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.word(mflr(.r0));
        a.moveSp(-size);
        a.store64(.r0, .{ .base = .r1, .disp = size - 8 });
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        a.load64(.r0, .{ .base = .r1, .disp = size - 8 });
        a.word(mtlr(.r0));
        a.moveSp(size);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        a.unsaveLink(size);
        a.retLocal();
    }
    /// Sets the native stack pointer from a value that `leaSp` produced.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.word(dform(op_addi, 1, src.n(), -bias));
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        a.load64(s0, m);
        a.jumpIf(c, x, s0, l);
    }
    /// Opens a routine entered by `callLocal` that calls other functions.
    pub fn enterLocal(a: *Assembler) void {
        a.word(mflr(.r0));
        a.store64(.r0, .{ .base = .r1, .disp = link_slot });
    }
    /// Returns from a routine opened by `enterLocal`.
    pub fn leaveLocal(a: *Assembler) void {
        a.load64(.r0, .{ .base = .r1, .disp = link_slot });
        a.word(mtlr(.r0));
        a.word(blr);
    }
    pub fn trap(a: *Assembler) void {
        a.word(trap_word);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the link register in the frame of its caller, opens a frame
    /// whose first word links to that frame, saves the callee-saved
    /// registers it uses, and loads the pinned ones.
    pub fn prologue(a: *Assembler) void {
        a.word(mflr(.r0));
        a.word(dform(op_std, 0, 1, 16)); // std r0, 16(r1)
        a.word(dform(op_std, 1, 1, -(bias + frame_size)) | 1); // stdu r1, -(bias + frame_size)(r1)
        for (saved, 0..) |r, i| a.store64(r, .{ .base = .r1, .disp = @intCast(i * 8) });
        a.mov(thread, .r3);
        a.mov(stop, .r4);
        a.mov(base, .r6);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        for (saved, 0..) |r, i| a.load64(r, .{ .base = .r1, .disp = @intCast(i * 8) });
        a.word(dform(op_addi, 1, 1, bias + frame_size));
        a.word(dform(op_ld, 0, 1, 16)); // ld r0, 16(r1)
        a.word(mtlr(.r0));
        a.word(blr);
    }
};

comptime {
    std.debug.assert((bias + frame_size) % 16 == 0);
    std.debug.assert(saved.len * 8 <= link_slot and link_slot + 8 <= frame_size);
}

fn expectWords(a: *Assembler, expected: []const u32) !void {
    const got = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |w, i| try std.testing.expectEqual(w, std.mem.littleToNative(u32, got[i]));
}

// The expected words come from the GNU assembler syntax shown next to
// each call, assembled for POWER8 in little-endian mode.

test "ppc64le moves, memory, and arithmetic" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.r3, .r14); // mr 3, 14
    a.movImm(.r4, 0); // li 4, 0
    a.movImm(.r21, 0x123); // li 21, 0x123
    a.movImm(.r21, 0x12345678); // lis 21, 0x1234; ori 21, 21, 0x5678
    a.movImm(.r21, @bitCast(@as(i64, -2))); // li 21, -2
    a.load64(.r21, .{ .base = .r15, .disp = 16 }); // ld 21, 16(15)
    a.store64(.r21, .{ .base = .r15, .disp = 24 }); // std 21, 24(15)
    a.load64(.r21, .{ .base = .r15, .disp = -16 }); // ld 21, -16(15)
    a.load8(.r22, .{ .base = .r15, .disp = 8 }); // lbz 22, 8(15)
    a.load32(.r22, .{ .base = .r14, .disp = 4 }); // lwz 22, 4(14)
    a.load16(.r21, .{ .base = .r15, .disp = 2 }); // lhz 21, 2(15)
    a.store16(.r21, .{ .base = .r15, .disp = 2 }); // sth 21, 2(15)
    a.store32(.r21, .{ .base = .r15, .disp = 16 }); // stw 21, 16(15)
    a.store8(.r21, .{ .base = .r15, .disp = 1 }); // stb 21, 1(15)
    a.loadF(.f1, .{ .base = .r15 }); // lfd 1, 0(15)
    a.storeF(.f2, .{ .base = .r15, .disp = 8 }); // stfd 2, 8(15)
    a.add(.r21, .r22); // add 21, 21, 22
    a.sub(.r21, .r22); // subf 21, 22, 21
    a.mul(.r21, .r22); // mulld 21, 21, 22
    a.addImm(.r21, 5); // addi 21, 21, 5
    a.neg(.r21); // neg 21, 21
    a.not(.r21); // nor 21, 21, 21
    a.fadd(.f1, .f2); // fadd 1, 1, 2
    a.fsub(.f1, .f2); // fsub 1, 1, 2
    a.fmul(.f1, .f2); // fmul 1, 1, 2
    a.fdiv(.f1, .f2); // fdiv 1, 1, 2
    a.intToFloat(.f1, .r21); // mtvsrd 1, 21; fcfid 1, 1
    a.fmov(.f1, .f2); // fmr 1, 2
    a.fneg(.f1, .f2); // fneg 1, 2
    a.fabs(.f1, .f2); // fabs 1, 2
    a.fsqrt(.f1, .f2); // fsqrt 1, 2
    a.addScaled(.r21, .r22, .r16, 4); // sldi 12, 16, 4; add 21, 22, 12
    a.and3(.r21, .r22, .r23); // and 21, 22, 23
    a.or3(.r21, .r22, .r23); // or 21, 22, 23
    a.xor3(.r21, .r22, .r23); // xor 21, 22, 23
    try expectWords(&a, &.{
        0x7DC37378, 0x38800000, 0x3AA00123,                0x3EA01234, 0x62B55678, 0x3AA0FFFE, 0xEAAF0010, 0xFAAF0018,
        0xEAAFFFF0, 0x8ACF0008, 0x82CE0004,                0xA2AF0002, 0xB2AF0002, 0x92AF0010, 0x9AAF0001, 0xC82F0000,
        0xD84F0008, 0x7EB5B214, 0x7EB6A850,                0x7EB5B1D2, 0x3AB50005, 0x7EB500D0, 0x7EB5A8F8, 0xFC21102A,
        0xFC211028, 0xFC2100B2, 0xFC211024,                0x7C350166, 0xFC200E9C, 0xFC201090, 0xFC201050, 0xFC201210,
        0xFC20102C, 0x7A0C26E4, xform(21, 22, 12, xo_add), 0x7ED5B838, 0x7ED5BB78, 0x7ED5BA78,
    });
}

test "ppc64le wide constants, far displacements, and conversions" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.movImm(.r21, 0x0000123456789ABC); // li 21, 0x1234; sldi 21, 21, 32; oris 21, 21, 0x5678; ori 21, 21, 0x9abc
    a.load64(.r21, .{ .base = .r15, .disp = 6 }); // li 11, 6; ldx 21, 15, 11
    a.floatToInt(.r21, .f1); // fctidz 0, 1; mfvsrd 21, 0
    a.load64(.r21, .{ .base = .r1, .disp = 8 }); // ld 21, 40(1)
    a.leaSp(.r21, 0); // addi 21, 1, 32
    a.setSp(.r21); // addi 1, 21, -32
    try expectWords(&a, &.{
        dform(op_addi, 21, 0, 0x1234), 0x7AB507C6,                dform(op_oris, 21, 21, 0x5678), dform(op_ori, 21, 21, 0x9ABC),
        dform(op_addi, 11, 0, 6),      0x7EAF582A,                aform(0, 0, 1, 815),            xform(0, 21, 0, xo_mfvsrd),
        dform(op_ld, 21, 1, 40),       dform(op_addi, 21, 1, 32), dform(op_addi, 1, 21, -32),
    });
}

test "ppc64le floor modulo" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.floorDiv(.r21, .r16, .r17, true, .r20, .r20);
    // divd 12, 16, 17; mulld 0, 12, 17; subf 11, 0, 16; cmpdi 0, 11, 0;
    // beq 0, l5; xor 20, 11, 17; cmpdi 0, 20, 0; bge 0, l5;
    // add 11, 11, 17; l5: mr 21, 11
    try expectWords(&a, &.{ 0x7D908BD2, 0x7C0C89D2, 0x7D608050, 0x2C2B0000, 0x41820014, 0x7D748A78, 0x2C340000, 0x40800008, 0x7D6B8A14, 0x7D755B78 });
}

test "ppc64le comparisons and calls" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l0 = a.newLabel();
    const l3 = a.newLabel();
    a.bind(l0);
    a.jumpIf(.lt, .r21, .r22, l3); // cmpd 0, 21, 22; bc 4, 0, .+8; b l3
    a.jumpIf(.eq, .r21, .r22, l0); // cmpd 0, 21, 22; bc 12, 2, l0
    a.jmp(l0); // b l0
    a.bind(l3);
    a.jumpIfImm(.lt, .r21, 5, l3); // cmpdi 0, 21, 5; bc 12, 0, l3
    a.jumpIfImm(.lo, .r21, 5, l3); // cmpldi 0, 21, 5; bc 12, 0, l3
    a.jumpIf(.hi, .r21, .r22, l3); // cmpld 0, 21, 22; bc 12, 1, l3
    a.jumpIfFloat(.le, .f1, .f2, l3); // fcmpu 0, 1, 2; cror 3, 0, 2; bc 12, 3, l3
    a.callLocal(l0); // bl l0
    a.callReg(.r21); // mr 12, 21; mtctr 12; bctrl
    a.retLocal(); // blr
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x7C35B000), w[0]);
    try std.testing.expectEqual(@as(u32, 0x40800008), w[1]);
    try std.testing.expectEqual(@as(u32, 0x48000010), w[2]); // b .+16
    try std.testing.expectEqual(@as(u32, 0x7C35B000), w[3]);
    try std.testing.expectEqual(@as(u32, 0x4182FFF0), w[4]); // beq .-16
    try std.testing.expectEqual(@as(u32, 0x4BFFFFEC), w[5]); // b .-20
    try std.testing.expectEqual(@as(u32, 0x2C350005), w[6]);
    try std.testing.expectEqual(@as(u32, 0x4180FFFC), w[7]); // blt .-4
    try std.testing.expectEqual(@as(u32, 0x28350005), w[8]);
    try std.testing.expectEqual(@as(u32, 0x4180FFF4), w[9]); // blt .-12
    try std.testing.expectEqual(@as(u32, 0x7C35B040), w[10]);
    try std.testing.expectEqual(@as(u32, 0x4181FFEC), w[11]); // bgt .-20
    try std.testing.expectEqual(@as(u32, 0xFC011000), w[12]);
    try std.testing.expectEqual(@as(u32, 0x4C601382), w[13]);
    try std.testing.expectEqual(@as(u32, 0x4183FFE0), w[14]); // bc 12, 3, .-32
    try std.testing.expectEqual(@as(u32, 0x4BFFFFC5), w[15]); // bl .-60
    try std.testing.expectEqual(xform(21, 12, 21, xo_or), w[16]);
    try std.testing.expectEqual(@as(u32, 0x7D8903A6), w[17]);
    try std.testing.expectEqual(@as(u32, 0x4E800421), w[18]);
    try std.testing.expectEqual(@as(u32, 0x4E800020), w[19]);

    var b = Assembler.init(std.testing.allocator);
    defer b.deinit();
    b.jmp(b.newLabel());
    try std.testing.expect(!b.finish());
}

test "ppc64le entry sequence" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.prologue();
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x7C0802A6), w[0]); // mflr 0
    try std.testing.expectEqual(@as(u32, 0xF8010010), w[1]); // std 0, 16(1)
    try std.testing.expectEqual(@as(u32, 0xF821FF61), w[2]); // stdu 1, -160(1)
    try std.testing.expectEqual(dform(op_std, 14, 1, 32), w[3]); // std 14, 32(1)
}
