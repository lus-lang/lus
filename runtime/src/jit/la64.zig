//! The loong64 backend of the JIT assembler, for LoongArch64 and the
//! LP64D calling convention. It offers the same interface as `a64.zig`
//! and follows `rv64.zig`, whose model it shares: three-operand
//! instructions, compare-and-branch instructions, a link register, and
//! constants in a pool. Every instruction is 32 bits wide.
//!
//! A branch on two registers reaches 128 KB and `b` reaches 128 MB. A
//! conditional branch to a label that is bound and in reach takes one
//! instruction. Any other is the inverted branch over a `b`, so every
//! jump is one instruction long.

const std = @import("std");
const reloc = @import("reloc.zig");

pub const Reg = enum(u5) {
    zero,
    ra,
    tp,
    sp,
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

/// The native stack pointer, as the base of a memory operand.
pub const sp: Reg = .sp;

// The registers the emitter uses. Pinned registers are the callee-saved
// s0 to s3, so they survive calls into the runtime. The temporaries are
// t0 to t6, which no argument uses.
pub const thread: Reg = .r23;
pub const bp: Reg = .r24;
pub const base: Reg = .r25;
pub const stop: Reg = .r26;
pub const t0: Reg = .r12;
pub const t1: Reg = .r13;
pub const t2: Reg = .r14;
pub const t3: Reg = .r15;
pub const t4: Reg = .r16;
pub const t5: Reg = .r17;
pub const t6: Reg = .r18;
pub const args = [_]Reg{ .r4, .r5, .r6, .r7, .r8, .r9 };
pub const ret0: Reg = .r4;
pub const ret1: Reg = .r5;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .r6;
pub const f0: FReg = .f0;
pub const f1: FReg = .f1;
/// Scratch registers of the assembler itself: t7 and t8.
const s0: Reg = .r19;
const s1: Reg = .r20;
/// The float scratch register of the assembler: ft13.
const fs0: FReg = .f21;

/// Bytes of native stack the entry sequence reserves: the return address,
/// s0 to s6, and the slot of `enterLocal`.
const frame_size = 80;
/// Offset of the slot where a shared routine keeps its return address.
const link_slot = 64;
const ra_slot = 72;
/// The callee-saved registers that the entry sequence saves: the four
/// pinned registers and s4 to s6, which the optimizing tier uses as its
/// scratch registers.
const saved = [_]Reg{ .r23, .r24, .r25, .r26, .r27, .r28, .r29 };

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
    kind: enum { b26, b16, b21, literal },
};

const op_b: u32 = 0x50000000;
const op_bl: u32 = 0x54000000;
const op_jirl: u32 = 0x4C000000;
const op_beqz: u32 = 0x40000000;
const op_bnez: u32 = 0x44000000;
const op_bceqz: u32 = 0x48000000;
const op_bcnez: u32 = 0x48000100;
const op_pcaddu12i: u32 = 0x1C000000;
const op_lu12i: u32 = 0x14000000;
const brk: u32 = 0x002A0000;

fn r3(op: u32, rd: u32, rj: u32, rk: u32) u32 {
    return op | rk << 10 | rj << 5 | rd;
}
fn ri12(op: u32, rd: u32, rj: u32, imm: i32) u32 {
    return op | (@as(u32, @bitCast(imm)) & 0xFFF) << 10 | rj << 5 | rd;
}
fn r2(op: u32, rd: u32, rj: u32) u32 {
    return op | rj << 5 | rd;
}
fn fitsI12(v: i64) bool {
    return v >= -2048 and v < 2048;
}

// Opcodes of the three-register, the 12-bit immediate, and the
// two-register forms.
const add_d = 0x00108000;
const sub_d = 0x00118000;
const mul_d = 0x001D8000;
const div_d = 0x00220000;
const mod_d = 0x00228000;
const and_ = 0x00148000;
const or_ = 0x00150000;
const xor_ = 0x00158000;
const nor_ = 0x00140000;
const addi_d = 0x02C00000;
const addi_w = 0x02800000;
const andi = 0x03400000;
const ori = 0x03800000;
const slli_d = 0x00410000;
const ld_d = 0x28C00000;
const st_d = 0x29C00000;
const ld_wu = 0x2A800000;
const st_w = 0x29800000;
const ld_hu = 0x2A400000;
const st_h = 0x29400000;
const ld_bu = 0x2A000000;
const st_b = 0x29000000;
const fld_d = 0x2B800000;
const fst_d = 0x2BC00000;
const fadd_d = 0x01010000;
const fsub_d = 0x01030000;
const fmul_d = 0x01050000;
const fdiv_d = 0x01070000;
const fmov_d = 0x01149800;
const fneg_d = 0x01141800;
const fabs_d = 0x01140800;
const fsqrt_d = 0x01144800;
const movgr2fr_d = 0x0114A800;
const movfr2gr_d = 0x0114B800;
const ffint_d_l = 0x011D2800;
const ftintrz_l_d = 0x011AA800;
const fcmp_d = 0x0C200000;

/// A conditional branch on two registers: the opcode, and whether the
/// operands swap. `mi` and `pl` test the sign of a difference and have
/// none.
const Branch = struct { op: u32, swap: bool };
fn branchOf(c: Cond) Branch {
    return switch (c) {
        .eq => .{ .op = 0x58000000, .swap = false },
        .ne => .{ .op = 0x5C000000, .swap = false },
        .lt => .{ .op = 0x60000000, .swap = false },
        .ge => .{ .op = 0x64000000, .swap = false },
        .gt => .{ .op = 0x60000000, .swap = true },
        .le => .{ .op = 0x64000000, .swap = true },
        .lo => .{ .op = 0x68000000, .swap = false },
        .hs => .{ .op = 0x6C000000, .swap = false },
        .hi => .{ .op = 0x68000000, .swap = true },
        .ls => .{ .op = 0x6C000000, .swap = true },
        .mi, .pl => unreachable,
    };
}
/// The opcode of the inverted branch: beq and bne, blt and bge, and bltu
/// and bgeu differ in bit 26.
fn invertBranch(op: u32) u32 {
    return op ^ 0x04000000;
}

/// A pool word that holds an address, before `flushPool` places it.
const PoolReloc = struct { index: u32, r: reloc.Reloc };

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Offset of each label, or `unbound`.
    labels: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    /// Constants that take more than two instructions to build. They wait
    /// here for the next `flushPool`, and a `pcaddu12i` and `ld.d` pair
    /// reads them. For a literal fixup, `label` is an index into this
    /// pool.
    pool: std.ArrayList(u64) = .empty,
    /// The first fixup that the next `flushPool` looks at.
    pool_fixups: usize = 0,
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
    /// Relocated pool words that the next `flushPool` places.
    pool_relocs: std.ArrayList(PoolReloc) = .empty,
    /// Set when a branch cannot reach its label.
    overflow: bool = false,

    const unbound: u32 = 0xFFFF_FFFF;

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Assembler) void {
        a.relocs.deinit(a.gpa);
        a.pool_relocs.deinit(a.gpa);
        a.buf.deinit(a.gpa);
        a.labels.deinit(a.gpa);
        a.fixups.deinit(a.gpa);
        a.pool.deinit(a.gpa);
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

    /// Writes the pending constants at the current position, which
    /// execution never reaches, and points the loads that wait for them
    /// at them.
    pub fn flushPool(a: *Assembler) void {
        if (a.pool.items.len > 0) {
            // The pool is aligned for 64-bit loads.
            while (a.buf.items.len % 8 != 0) a.word(brk);
            const pool_at = a.offset();
            for (a.pool.items) |v| a.buf.appendSlice(a.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, v))) catch {
                a.oom = true;
                return;
            };
            for (a.fixups.items[a.pool_fixups..]) |f| {
                if (f.kind == .literal) a.patch(f, pool_at + f.label * 8);
            }
            for (a.pool_relocs.items) |p| a.record(pool_at + p.index * 8, .word, p.r);
            a.pool_relocs.clearRetainingCapacity();
            a.pool.clearRetainingCapacity();
        }
        a.pool_fixups = a.fixups.items.len;
    }

    fn patchWord(a: *Assembler, at: u32, bits: u32) void {
        const p: *align(1) u32 = @ptrCast(a.buf.items[at..].ptr);
        p.* = std.mem.nativeToLittle(u32, std.mem.littleToNative(u32, p.*) | bits);
    }

    fn patch(a: *Assembler, f: Fixup, target: u32) void {
        const delta: i64 = @as(i64, target) - @as(i64, f.at);
        const words: i64 = @divExact(delta, 4);
        const u: u32 = @truncate(@as(u64, @bitCast(words)));
        switch (f.kind) {
            .b26 => {
                if (words < -(1 << 25) or words >= (1 << 25)) a.overflow = true;
                a.patchWord(f.at, (u & 0xFFFF) << 10 | (u >> 16 & 0x3FF));
            },
            .b21 => {
                if (words < -(1 << 20) or words >= (1 << 20)) a.overflow = true;
                a.patchWord(f.at, (u & 0xFFFF) << 10 | (u >> 16 & 0x1F));
            },
            .b16 => {
                if (words < -(1 << 15) or words >= (1 << 15)) a.overflow = true;
                a.patchWord(f.at, (u & 0xFFFF) << 10);
            },
            .literal => {
                // pcaddu12i takes the upper 20 bits, rounded so that the
                // signed low 12 bits of the load complete the offset.
                const hi: i64 = (delta + 0x800) >> 12;
                const lo: i64 = delta - (hi << 12);
                a.patchWord(f.at, (@as(u32, @truncate(@as(u64, @bitCast(hi)))) & 0xFFFFF) << 5);
                a.patchWord(f.at + 4, (@as(u32, @truncate(@as(u64, @bitCast(lo)))) & 0xFFF) << 10);
            },
        }
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        a.flushPool();
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            if (f.kind == .literal) continue;
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
        a.word(r3(or_, dst.n(), src.n(), 0));
    }

    /// Loads a 64-bit constant with the shortest sequence: one `addi.d` or
    /// `ori`, a `lu12i.w` and an `ori` for a value that fits 32 signed
    /// bits, and a load from the pool otherwise.
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
        const index = a.pool.items.len;
        a.pool.append(a.gpa, v) catch {
            a.oom = true;
        };
        a.pool_relocs.append(a.gpa, .{ .index = @intCast(index), .r = r }) catch {
            a.oom = true;
        };
        a.fix(@intCast(index), .literal);
        a.word(op_pcaddu12i | dst.n());
        a.word(ri12(ld_d, dst.n(), dst.n(), 0));
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
        if (fitsI12(sv)) return a.word(ri12(addi_d, dst.n(), 0, @intCast(sv)));
        if (sv >= 0 and sv < 4096) return a.word(ri12(ori, dst.n(), 0, @intCast(sv)));
        if (sv >= std.math.minInt(i32) and sv <= std.math.maxInt(i32)) {
            // lu12i.w sign-extends bits 12 to 31, and ori fills in the low
            // twelve bits without extending them.
            const hi: u32 = @as(u32, @truncate(@as(u64, @bitCast(sv)) >> 12)) & 0xFFFFF;
            const lo: u32 = @as(u32, @truncate(v)) & 0xFFF;
            a.word(op_lu12i | hi << 5 | dst.n());
            if (lo != 0) a.word(ri12(ori, dst.n(), dst.n(), @intCast(lo)));
            return;
        }
        var index: usize = 0;
        while (index < a.pool.items.len and a.pool.items[index] != v) index += 1;
        if (index == a.pool.items.len) a.pool.append(a.gpa, v) catch {
            a.oom = true;
        };
        a.fix(@intCast(index), .literal);
        a.word(op_pcaddu12i | dst.n());
        a.word(ri12(ld_d, dst.n(), dst.n(), 0));
    }

    // -----------------------------------------------------------------
    // Memory

    /// Returns a memory operand whose displacement fits 12 signed bits,
    /// computing a far address into the scratch register `s1`.
    fn near(a: *Assembler, m: Mem) Mem {
        if (fitsI12(m.disp)) return m;
        a.movImm(s1, @bitCast(@as(i64, m.disp)));
        a.word(r3(add_d, s1.n(), s1.n(), m.base.n()));
        return .{ .base = s1 };
    }
    fn access(a: *Assembler, op: u32, rd: u32, m: Mem) void {
        const q = a.near(m);
        a.word(ri12(op, rd, q.base.n(), q.disp));
    }

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(ld_d, dst.n(), m);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.access(st_d, src.n(), m);
    }
    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(ld_wu, dst.n(), m);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.access(st_w, src.n(), m);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(ld_bu, dst.n(), m);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        a.access(st_b, src.n(), m);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.access(ld_hu, dst.n(), m);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.access(st_h, src.n(), m);
    }
    pub fn storeImm16(a: *Assembler, m: Mem, v: u16) void {
        if (v == 0) return a.store16(.zero, m);
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
    /// The register that reads as zero in `storePair64` and `storePair32`.
    pub const zero_reg: ?Reg = .zero;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        a.access(fld_d, dst.n(), m);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.access(fst_d, src.n(), m);
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
        if (v == 0) return a.store64(.zero, m);
        a.movImm(s0, v);
        a.store64(s0, m);
    }
    pub fn storeImm32(a: *Assembler, m: Mem, v: u32) void {
        if (v == 0) return a.store32(.zero, m);
        a.movImm(s0, v);
        a.store32(s0, m);
    }
    /// Prepares `zero16`. The zero register needs no preparation.
    pub fn zeroPrepare(a: *Assembler) void {
        _ = a;
    }
    /// Clears 16 bytes with two stores of the zero register.
    pub fn zero16(a: *Assembler, m: Mem) void {
        a.storePair64(.zero, .zero, m);
    }
    /// Copies 16 bytes as two 64-bit words.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        const second_src: Mem = .{ .base = src.base, .disp = src.disp + 8 };
        const second_dst: Mem = .{ .base = dst.base, .disp = dst.disp + 8 };
        if (fitsI12(second_src.disp) and fitsI12(second_dst.disp) and fitsI12(src.disp) and fitsI12(dst.disp)) {
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
    /// dst = base + disp.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        if (fitsI12(m.disp)) {
            if (m.disp == 0) return a.mov(dst, m.base);
            return a.word(ri12(addi_d, dst.n(), m.base.n(), m.disp));
        }
        a.movImm(s1, @bitCast(@as(i64, m.disp)));
        a.word(r3(add_d, dst.n(), m.base.n(), s1.n()));
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        if (shift == 0) return a.word(r3(add_d, dst.n(), b.n(), index.n()));
        a.word(slli_d | @as(u32, shift) << 10 | index.n() << 5 | s0.n());
        a.word(r3(add_d, dst.n(), b.n(), s0.n()));
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.word(slli_d | @as(u32, shift) << 10 | index.n() << 5 | s0.n());
        a.word(r3(sub_d, dst.n(), b.n(), s0.n()));
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
        a.word(r3(sub_d, dst.n(), 0, dst.n()));
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.word(r3(nor_, dst.n(), dst.n(), 0));
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        a.addImm3(dst, dst, v);
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        a.word(r3(div_d, s0.n(), x.n(), y.n()));
        a.word(r3(mod_d, s1.n(), x.n(), y.n()));
        a.mov(quot, s0);
        a.mov(rem, s1);
    }

    // -----------------------------------------------------------------
    // Floats

    fn fop(a: *Assembler, op: u32, dst: FReg, x: FReg, y: FReg) void {
        a.word(r3(op, dst.n(), x.n(), y.n()));
    }
    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(fadd_d, dst, dst, src);
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(fsub_d, dst, dst, src);
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(fmul_d, dst, dst, src);
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(fdiv_d, dst, dst, src);
    }
    /// Converts a signed integer to a float. The conversion runs inside
    /// the float register.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(r2(movgr2fr_d, dst.n(), src.n()));
        a.word(r2(ffint_d_l, dst.n(), dst.n()));
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(r2(movgr2fr_d, dst.n(), src.n()));
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(r2(movfr2gr_d, dst.n(), src.n()));
    }
    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.word(r2(fmov_d, dst.n(), src.n()));
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(r2(fneg_d, dst.n(), src.n()));
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(r2(fabs_d, dst.n(), src.n()));
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(r2(fsqrt_d, dst.n(), src.n()));
    }
    /// LoongArch64 rounds to an integral float only in the mode of the
    /// float control register, so the emitter takes the path of a target
    /// without such an instruction.
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
        a.word(r2(ftintrz_l_d, fs0.n(), src.n()));
        a.word(r2(movfr2gr_d, dst.n(), fs0.n()));
    }

    // Three-operand forms: dst = x op y.
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(add_d, dst.n(), x.n(), y.n()));
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(sub_d, dst.n(), x.n(), y.n()));
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(mul_d, dst.n(), x.n(), y.n()));
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(and_, dst.n(), x.n(), y.n()));
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(or_, dst.n(), x.n(), y.n()));
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(r3(xor_, dst.n(), x.n(), y.n()));
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(fadd_d, dst, x, y);
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(fsub_d, dst, x, y);
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(fmul_d, dst, x, y);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(fdiv_d, dst, x, y);
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        if (v == 0) return a.mov(dst, x);
        if (fitsI12(v)) return a.word(ri12(addi_d, dst.n(), x.n(), v));
        a.movImm(s1, @bitCast(@as(i64, v)));
        a.add3(dst, x, s1);
    }
    /// Loads and stores of the word at [b + index * 8].
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        a.addScaled(s0, b, index, 3);
        a.load64(dst, .{ .base = s0 });
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        a.addScaled(s0, b, index, 3);
        a.store64(src, .{ .base = s0 });
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. `tmp` is a
    /// free register other than the operands.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        _ = tmp2;
        a.word(r3(div_d, s0.n(), x.n(), y.n()));
        a.word(r3(mod_d, s1.n(), x.n(), y.n()));
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.word(op_beqz | 4 << 10 | s1.n() << 5); // beqz s1, +4 words
        a.xor3(tmp, s1, y);
        a.word(branchOf(.ge).op | 2 << 10 | tmp.n() << 5); // bge tmp, zero, +2 words
        if (mod) a.add3(s1, s1, y) else a.word(ri12(addi_d, s0.n(), s0.n(), -1));
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
        a.lea(dst, .{ .base = .sp, .disp = disp });
    }
    /// Moves the native stack pointer by `v` bytes.
    pub fn moveSp(a: *Assembler, v: i32) void {
        a.addImm(.sp, v);
    }

    // -----------------------------------------------------------------
    // Control flow

    pub fn jmp(a: *Assembler, l: Label) void {
        a.fix(l, .b26);
        a.word(op_b);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.word(op_jirl | r.n() << 5);
    }
    /// Whether a branch from here reaches the label in one instruction.
    fn reaches(a: *Assembler, l: Label, bits: u5) bool {
        if (l >= a.labels.items.len or a.labels.items[l] == unbound) return false;
        const words = @divExact(@as(i64, a.labels.items[l]) - @as(i64, a.offset()), 4);
        return words >= -(@as(i64, 1) << (bits - 1));
    }
    /// A conditional branch on two registers. A label that is bound and in
    /// reach gets one instruction. Any other gets the inverted branch over
    /// a `b`.
    fn branch(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        const b = branchOf(c);
        const rj = if (b.swap) y else x;
        const rd = if (b.swap) x else y;
        if (a.reaches(l, 16)) {
            a.fix(l, .b16);
            return a.word(b.op | rj.n() << 5 | rd.n());
        }
        a.word(invertBranch(b.op) | 2 << 10 | rj.n() << 5 | rd.n());
        a.jmp(l);
    }
    /// A branch on a register being zero or not, which reaches 4 MB.
    fn branchZero(a: *Assembler, zero: bool, x: Reg, l: Label) void {
        if (a.reaches(l, 21)) {
            a.fix(l, .b21);
            return a.word((if (zero) op_beqz else op_bnez) | x.n() << 5);
        }
        a.word((if (zero) op_bnez else op_beqz) | 2 << 10 | x.n() << 5);
        a.jmp(l);
    }
    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        switch (c) {
            .mi, .pl => {
                a.sub3(s0, x, y);
                a.branch(if (c == .mi) .lt else .ge, s0, .zero, l);
            },
            else => a.branch(c, x, y, l),
        }
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (v == 0) {
            if (c == .eq or c == .ne) return a.branchZero(c == .eq, x, l);
            return a.jumpIf(c, x, .zero, l);
        }
        a.movImm(s1, @bitCast(@as(i64, v)));
        a.jumpIf(c, x, s1, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.word(ri12(addi_w, s0.n(), x.n(), 0)); // sign-extends the low word
        a.branchZero(zero, s0, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.load8(s0, m);
        if (v == 0) return a.jumpIfImm(c, s0, 0, l);
        a.movImm(s1, v);
        a.jumpIf(c, s0, s1, l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        a.load8(s0, m);
        a.word(ri12(andi, s0.n(), s0.n(), @as(i32, 1) << bit));
        a.branchZero(!set, s0, l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        // The quiet comparisons clt, cle, and ceq set fcc0 when they hold
        // and clear it when they fail or an operand is NaN.
        const cond: u32 = switch (c) {
            .lt, .nlt => 0x2,
            .le, .nle => 0x6,
            .eq, .ne => 0x4,
        };
        a.word(fcmp_d | cond << 15 | y.n() << 10 | x.n() << 5);
        const holds = switch (c) {
            .lt, .le, .eq => true,
            .nlt, .nle, .ne => false,
        };
        if (a.reaches(l, 21)) {
            a.fix(l, .b21);
            return a.word(if (holds) op_bcnez else op_bceqz);
        }
        a.word((if (holds) op_bceqz else op_bcnez) | 2 << 10);
        a.jmp(l);
    }

    /// Calls a function at an absolute address.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(s0, addr);
        a.callReg(s0);
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
        a.callReg(s0);
    }
    /// `callPair` for the routine that `r` names.
    pub fn callPairReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        a.callReloc(addr, r);
    }
    /// Calls a routine in the same code, which ends with `leave`.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.fix(l, .b26);
        a.word(op_bl);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.word(op_jirl | r.n() << 5 | Reg.ra.n());
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.jmpReg(.ra);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry. That
    /// jump is always one `b`.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.word(ri12(addi_d, dst.n(), Reg.ra.n(), 4));
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        _ = a;
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.addImm(.sp, -size);
        a.store64(.ra, .{ .base = .sp, .disp = size - 8 });
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        a.load64(.ra, .{ .base = .sp, .disp = size - 8 });
        a.addImm(.sp, size);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        a.unsaveLink(size);
        a.retLocal();
    }
    /// Sets the native stack pointer.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.mov(.sp, src);
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        a.load64(s0, m);
        a.jumpIf(c, x, s0, l);
    }
    /// Opens a routine entered by `callLocal` that calls other functions.
    pub fn enterLocal(a: *Assembler) void {
        a.store64(.ra, .{ .base = .sp, .disp = link_slot });
    }
    /// Returns from a routine opened by `enterLocal`.
    pub fn leaveLocal(a: *Assembler) void {
        a.load64(.ra, .{ .base = .sp, .disp = link_slot });
        a.retLocal();
    }
    pub fn trap(a: *Assembler) void {
        a.word(brk);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the callee-saved registers it uses and loads the pinned ones.
    pub fn prologue(a: *Assembler) void {
        a.addImm(.sp, -frame_size);
        a.store64(.ra, .{ .base = .sp, .disp = ra_slot });
        for (saved, 0..) |r, i| a.store64(r, .{ .base = .sp, .disp = @intCast(i * 8) });
        a.mov(thread, .r4);
        a.mov(stop, .r5);
        a.mov(base, .r7);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        for (saved, 0..) |r, i| a.load64(r, .{ .base = .sp, .disp = @intCast(i * 8) });
        a.load64(.ra, .{ .base = .sp, .disp = ra_slot });
        a.addImm(.sp, frame_size);
        a.retLocal();
    }
};

comptime {
    std.debug.assert(frame_size % 16 == 0);
    std.debug.assert(saved.len * 8 <= link_slot);
    std.debug.assert(link_slot < ra_slot and ra_slot + 8 == frame_size);
}

fn expectWords(a: *Assembler, expected: []const u32) !void {
    const got = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |w, i| try std.testing.expectEqual(w, std.mem.littleToNative(u32, got[i]));
}

// The expected words come from the GNU assembler syntax shown next to
// each call, assembled for LoongArch64.

test "loong64 moves, memory, and arithmetic" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.r4, .r23); // or $a0, $s0, $zero
    a.movImm(.r5, 0); // addi.d $a1, $zero, 0
    a.movImm(.r12, 0x123); // addi.d $t0, $zero, 0x123
    a.movImm(.r12, 0x12345678); // lu12i.w $t0, 0x12345; ori $t0, $t0, 0x678
    a.movImm(.r12, @bitCast(@as(i64, -2))); // addi.d $t0, $zero, -2
    a.load64(.r12, .{ .base = .r24, .disp = 16 }); // ld.d $t0, $s1, 16
    a.store64(.r12, .{ .base = .r24, .disp = 24 }); // st.d $t0, $s1, 24
    a.load64(.r12, .{ .base = .r24, .disp = -16 }); // ld.d $t0, $s1, -16
    a.load8(.r13, .{ .base = .r24, .disp = 8 }); // ld.bu $t1, $s1, 8
    a.load32(.r13, .{ .base = .r23, .disp = 4 }); // ld.wu $t1, $s0, 4
    a.load16(.r12, .{ .base = .r24, .disp = 2 }); // ld.hu $t0, $s1, 2
    a.store16(.r12, .{ .base = .r24, .disp = 2 }); // st.h $t0, $s1, 2
    a.storeImm16(.{ .base = .r12, .disp = 2 }, 0); // st.h $zero, $t0, 2
    a.store32(.r12, .{ .base = .r24, .disp = 16 }); // st.w $t0, $s1, 16
    a.store8(.r12, .{ .base = .r24, .disp = 1 }); // st.b $t0, $s1, 1
    a.loadF(.f0, .{ .base = .r24 }); // fld.d $fa0, $s1, 0
    a.storeF(.f1, .{ .base = .r24, .disp = 8 }); // fst.d $fa1, $s1, 8
    a.add(.r12, .r13); // add.d $t0, $t0, $t1
    a.sub(.r12, .r13); // sub.d $t0, $t0, $t1
    a.mul(.r12, .r13); // mul.d $t0, $t0, $t1
    a.addImm(.r12, 5); // addi.d $t0, $t0, 5
    a.addImm(.r12, -5); // addi.d $t0, $t0, -5
    a.neg(.r12); // sub.d $t0, $zero, $t0
    a.not(.r12); // nor $t0, $t0, $zero
    a.fadd(.f0, .f1); // fadd.d $fa0, $fa0, $fa1
    a.fsub(.f0, .f1); // fsub.d $fa0, $fa0, $fa1
    a.fmul(.f0, .f1); // fmul.d $fa0, $fa0, $fa1
    a.fdiv(.f0, .f1); // fdiv.d $fa0, $fa0, $fa1
    a.intToFloat(.f0, .r12); // movgr2fr.d $fa0, $t0; ffint.d.l $fa0, $fa0
    a.floatToInt(.r12, .f0); // ftintrz.l.d $ft13, $fa0; movfr2gr.d $t0, $ft13
    a.floatToBits(.r12, .f0); // movfr2gr.d $t0, $fa0
    a.fmov(.f0, .f1); // fmov.d $fa0, $fa1
    a.fneg(.f0, .f1); // fneg.d $fa0, $fa1
    a.fabs(.f0, .f1); // fabs.d $fa0, $fa1
    a.fsqrt(.f0, .f1); // fsqrt.d $fa0, $fa1
    a.addScaled(.r24, .r12, .r25, 4); // slli.d $t7, $s2, 4; add.d $s1, $t0, $t7
    try expectWords(&a, &.{
        0x001502E4, 0x02C00005, 0x02C48C0C, 0x142468AC, 0x0399E18C, 0x02FFF80C, 0x28C0430C, 0x29C0630C,
        0x28FFC30C, 0x2A00230D, 0x2A8012ED, 0x2A400B0C, 0x29400B0C, 0x29400980, 0x2980430C, 0x2900070C,
        0x2B800300, 0x2BC02301, 0x0010B58C, 0x0011B58C, 0x001DB58C, 0x02C0158C, 0x02FFED8C, 0x0011B00C,
        0x0014018C, 0x01010400, 0x01030400, 0x01050400, 0x01070400, 0x0114A980, 0x011D2800, 0x011AA815,
        0x0114BAAC, 0x0114B80C, 0x01149820, 0x01141820, 0x01140820, 0x01144820, 0x00411333, 0x0010CD98,
    });
}

test "loong64 three-operand forms, tests, and calls" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.divRem(.r12, .r13, .r16, .r17); // div.d $t7, $t4, $t5; mod.d $t8, $t4, $t5; or $t0, $t7, $zero; or $t1, $t8, $zero
    a.and3(.r12, .r13, .r14); // and $t0, $t1, $t2
    a.or3(.r12, .r13, .r14); // or $t0, $t1, $t2
    a.xor3(.r12, .r13, .r14); // xor $t0, $t1, $t2
    a.callReg(.r19); // jirl $ra, $t7, 0
    a.retLocal(); // jirl $zero, $ra, 0
    a.linkPastJump(.r12); // addi.d $t0, $ra, 4
    a.trap(); // break 0
    try expectWords(&a, &.{
        0x00224613, 0x0022C614, r3(or_, 12, 19, 0), r3(or_, 13, 20, 0), 0x0014B9AC, 0x001539AC, 0x0015B9AC,
        0x4C000261, 0x4C000020, 0x02C0102C,         0x002A0000,
    });
}

test "loong64 floor division and modulo" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.floorDiv(.r12, .r16, .r17, true, .r29, .r29);
    // div.d $t7, $t4, $t5; mod.d $t8, $t4, $t5; beqz $t8, l5;
    // xor $s6, $t8, $t5; bge $s6, $zero, l5; add.d $t8, $t8, $t5;
    // l5: or $t0, $t8, $zero
    try expectWords(&a, &.{ 0x00224613, 0x0022C614, 0x40001280, 0x0015C69D, 0x64000BA0, 0x0010C694, 0x0015028C });
}

test "loong64 tests of bytes, bits, and floats" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l = a.newLabel();
    a.jumpIfZero32(.r12, true, l); // addi.w $t7, $t0, 0; bnez $t7, .+8; b l
    a.jumpIfBit(.{ .base = .r12 }, 3, true, l); // ld.bu $t7, $t0, 0; andi $t7, $t7, 8; beqz $t7, .+8; b l
    a.jumpIfFloat(.lt, .f0, .f1, l); // fcmp.clt.d $fcc0, $fa0, $fa1; bceqz $fcc0, .+8; b l
    a.jumpIfFloat(.nle, .f0, .f1, l); // fcmp.cle.d $fcc0, $fa0, $fa1; bcnez $fcc0, .+8; b l
    a.jumpIfFloat(.eq, .f0, .f1, l); // fcmp.ceq.d $fcc0, $fa0, $fa1; bceqz $fcc0, .+8; b l
    a.bind(l);
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x02800193), w[0]);
    try std.testing.expectEqual(@as(u32, 0x03402273), w[4]);
    try std.testing.expectEqual(@as(u32, 0x0C210400), w[7]);
    try std.testing.expectEqual(@as(u32, 0x0C230400), w[10]);
    try std.testing.expectEqual(@as(u32, 0x0C220400), w[13]);
    try std.testing.expectEqual(op_bnez | 2 << 10 | 19 << 5, w[1]);
    try std.testing.expectEqual(op_beqz | 2 << 10 | 19 << 5, w[5]);
    try std.testing.expectEqual(op_bceqz | 2 << 10, w[8]);
    try std.testing.expectEqual(op_bcnez | 2 << 10, w[11]);
}

test "loong64 branches resolve in both directions" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l0 = a.newLabel();
    const l3 = a.newLabel();
    const l4 = a.newLabel();
    a.bind(l0);
    a.jumpIf(.lt, .r12, .r13, l3); // bge $t0, $t1, l2; b l3
    a.jumpIfImm(.eq, .r12, 0, l0); // beqz $t0, l0
    a.jmp(l0); // b l0
    a.bind(l3);
    a.jumpIf(.gt, .r12, .r13, l3); // blt $t1, $t0, l3
    a.jumpIf(.hi, .r12, .r13, l0); // bltu $t1, $t0, l0
    a.jumpIf(.ls, .r12, .r13, l0); // bgeu $t1, $t0, l0
    a.callLocal(l0); // bl l0
    a.bind(l4);
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x6400098D), w[0]);
    try std.testing.expectEqual(@as(u32, 0x50000C00), w[1]);
    try std.testing.expectEqual(op_beqz | 0xFFFE << 10 | 12 << 5 | 0x1F, w[2]); // beqz $t0, .-8
    try std.testing.expectEqual(@as(u32, 0x53FFF7FF), w[3]);
    try std.testing.expectEqual(@as(u32, 0x600001AC), w[4]);
    try std.testing.expectEqual(@as(u32, 0x6BFFEDAC), w[5]);
    try std.testing.expectEqual(@as(u32, 0x6FFFE9AC), w[6]);
    try std.testing.expectEqual(op_bl | 0xFFF9 << 10 | 0x3FF, w[7]); // bl .-28
}

test "loong64 unbound labels fail and constants load from the pool" {
    var b = Assembler.init(std.testing.allocator);
    defer b.deinit();
    b.jmp(b.newLabel());
    try std.testing.expect(!b.finish());

    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.movImm(.r12, 0x1122334455667788); // pcaddu12i $t0, 0; ld.d $t0, $t0, pool[0]
    a.movImm(.r13, 0x1122334455667788);
    a.movImm(.r14, 0x0000123456789ABC);
    a.epilogue();
    try std.testing.expect(a.finish());
    const bytes = a.buf.items;
    const w = std.mem.bytesAsSlice(u32, bytes);
    const want = [_]u64{ 0x1122334455667788, 0x1122334455667788, 0x0000123456789ABC };
    for (want, 0..) |v, i| {
        const at = i * 8;
        const pc = std.mem.littleToNative(u32, w[at / 4]);
        const ld = std.mem.littleToNative(u32, w[at / 4 + 1]);
        try std.testing.expectEqual(op_pcaddu12i, pc & 0xFE000000);
        try std.testing.expectEqual(@as(u32, ld_d), ld & 0xFFC00000);
        const hi: i64 = @as(i20, @bitCast(@as(u20, @truncate(pc >> 5))));
        const lo: i64 = @as(i12, @bitCast(@as(u12, @truncate(ld >> 10))));
        const target: usize = @intCast(@as(i64, @intCast(at)) + (hi << 12) + lo);
        try std.testing.expectEqual(v, std.mem.readInt(u64, bytes[target..][0..8], .little));
    }
}
