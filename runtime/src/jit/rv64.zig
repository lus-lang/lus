//! The riscv64 backend of the JIT assembler, for RV64GC and the LP64D
//! calling convention. It offers the same interface as `a64.zig`, whose
//! model it shares: three-operand instructions, a link register, and
//! constants in a pool. Every instruction is 32 bits wide.
//!
//! A conditional branch reaches 4 KB. A branch to a label that is bound
//! and in reach takes one instruction. Any other conditional branch is
//! the inverted branch over a `jal`, which reaches 1 MB, as far as the
//! conditional branches of aarch64. Every `flushPool` also writes a jump
//! island for each `jal` that may not reach its label: an `auipc` and a
//! `jalr` that reach 2 GB. The `jal` then jumps to its island, so every
//! jump stays one instruction long.

const std = @import("std");

pub const Reg = enum(u5) {
    zero,
    ra,
    sp,
    gp,
    tp,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    x31,

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
// s1 to s4, so they survive calls into the runtime. The temporaries are
// t0 to t6, which no argument uses.
pub const thread: Reg = .x9;
pub const bp: Reg = .x18;
pub const base: Reg = .x19;
pub const stop: Reg = .x20;
pub const t0: Reg = .x5;
pub const t1: Reg = .x6;
pub const t2: Reg = .x7;
pub const t3: Reg = .x28;
pub const t4: Reg = .x29;
pub const t5: Reg = .x30;
pub const t6: Reg = .x31;
pub const args = [_]Reg{ .x10, .x11, .x12, .x13, .x14, .x15 };
pub const ret0: Reg = .x10;
pub const ret1: Reg = .x11;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .x12;
pub const f0: FReg = .f10;
pub const f1: FReg = .f11;
/// Scratch registers of the assembler itself: a6 and a7, which no
/// argument of a runtime routine uses.
const s0: Reg = .x16;
const s1: Reg = .x17;

/// Bytes of native stack the entry sequence reserves: the return address,
/// s1 to s7, and the slot of `enterLocal`.
const frame_size = 80;
/// Offset of the slot where a shared routine keeps its return address.
const link_slot = 64;
const ra_slot = 72;
/// The callee-saved registers that the entry sequence saves: the four
/// pinned registers and s5 to s7, which the optimizing tier uses as its
/// scratch registers.
const saved = [_]Reg{ .x9, .x18, .x19, .x20, .x21, .x22, .x23 };

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
    kind: enum { jal, branch, literal, far, done },
};

// Opcodes.
const op_load = 0x03;
const op_fload = 0x07;
const op_imm = 0x13;
const op_auipc = 0x17;
const op_imm32 = 0x1B;
const op_store = 0x23;
const op_fstore = 0x27;
const op_reg = 0x33;
const op_lui = 0x37;
const op_fp = 0x53;
const op_branch = 0x63;
const op_jalr = 0x67;
const op_jal = 0x6F;
const ebreak: u32 = 0x00100073;

fn rtype(f7: u32, rs2: u32, rs1: u32, f3: u32, rd: u32, opcode: u32) u32 {
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opcode;
}
fn itype(imm: i32, rs1: u32, f3: u32, rd: u32, opcode: u32) u32 {
    return (@as(u32, @bitCast(imm)) & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opcode;
}
fn stype(imm: i32, rs2: u32, rs1: u32, f3: u32, opcode: u32) u32 {
    const u: u32 = @bitCast(imm);
    return (u >> 5 & 0x7F) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (u & 0x1F) << 7 | opcode;
}
/// The offset bits of a conditional branch, a multiple of 2 within 4 KB.
fn btypeImm(delta: i32) u32 {
    const u: u32 = @bitCast(delta);
    return (u >> 12 & 1) << 31 | (u >> 5 & 0x3F) << 25 | (u >> 1 & 0xF) << 8 | (u >> 11 & 1) << 7;
}
/// The offset bits of `jal`, a multiple of 2 within 1 MB.
fn jtypeImm(delta: i32) u32 {
    const u: u32 = @bitCast(delta);
    return (u >> 20 & 1) << 31 | (u >> 1 & 0x3FF) << 21 | (u >> 11 & 1) << 20 | (u >> 12 & 0xFF) << 12;
}
fn fitsI12(v: i64) bool {
    return v >= -2048 and v < 2048;
}

/// A conditional branch: which instruction, and whether the operands
/// swap. `mi` and `pl` test the sign of a difference and have none.
const Branch = struct { f3: u32, swap: bool };
fn branchOf(c: Cond) Branch {
    return switch (c) {
        .eq => .{ .f3 = 0, .swap = false },
        .ne => .{ .f3 = 1, .swap = false },
        .lt => .{ .f3 = 4, .swap = false },
        .ge => .{ .f3 = 5, .swap = false },
        .gt => .{ .f3 = 4, .swap = true },
        .le => .{ .f3 = 5, .swap = true },
        .lo => .{ .f3 = 6, .swap = false },
        .hs => .{ .f3 = 7, .swap = false },
        .hi => .{ .f3 = 6, .swap = true },
        .ls => .{ .f3 = 7, .swap = true },
        .mi, .pl => unreachable,
    };
}

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Offset of each label, or `unbound`.
    labels: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    /// Constants that take more than two instructions to build. They wait
    /// here for the next `flushPool`, and an `auipc` and `ld` pair reads
    /// them. For a literal fixup, `label` is an index into this pool.
    pool: std.ArrayList(u64) = .empty,
    /// The first fixup that the next `flushPool` looks at.
    pool_fixups: usize = 0,
    /// The first fixup that the next `flushPool` may give an island.
    island_fixups: usize = 0,
    oom: bool = false,
    /// Set when a branch cannot reach its label.
    overflow: bool = false,

    const unbound: u32 = 0xFFFF_FFFF;

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Assembler) void {
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
        a.islands();
        if (a.pool.items.len > 0) {
            // The pool is aligned for 64-bit loads.
            while (a.buf.items.len % 8 != 0) a.word(ebreak);
            const pool_at = a.offset();
            for (a.pool.items) |v| a.buf.appendSlice(a.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, v))) catch {
                a.oom = true;
                return;
            };
            for (a.fixups.items[a.pool_fixups..]) |f| {
                if (f.kind == .literal) a.patch(f, pool_at + f.label * 8);
            }
            a.pool.clearRetainingCapacity();
        }
        a.pool_fixups = a.fixups.items.len;
    }

    /// Writes an island for every `jal` since the last flush whose label
    /// is unbound, or bound out of reach, and points the `jal` at it. The
    /// islands sit where execution never reaches, as the pool does, and
    /// the next flush comes within reach of every `jal` before it.
    fn islands(a: *Assembler) void {
        const end = a.fixups.items.len;
        var i = a.island_fixups;
        while (i < end) : (i += 1) {
            const f = a.fixups.items[i];
            if (f.kind != .jal) continue;
            const target = a.labels.items[f.label];
            if (target != unbound) {
                const delta = @as(i64, target) - @as(i64, f.at);
                if (delta >= -(1 << 20) and delta < (1 << 20)) continue;
            }
            const island = a.offset();
            a.fix(f.label, .far);
            a.word(s0.n() << 7 | op_auipc);
            a.word(itype(0, s0.n(), 0, 0, op_jalr));
            if (a.oom) return;
            a.patch(f, island);
            a.fixups.items[i].kind = .done;
        }
        a.island_fixups = a.fixups.items.len;
    }

    fn patchWord(a: *Assembler, at: u32, bits: u32) void {
        const p: *align(1) u32 = @ptrCast(a.buf.items[at..].ptr);
        p.* = std.mem.nativeToLittle(u32, std.mem.littleToNative(u32, p.*) | bits);
    }

    fn patch(a: *Assembler, f: Fixup, target: u32) void {
        const delta: i64 = @as(i64, target) - @as(i64, f.at);
        switch (f.kind) {
            .jal => {
                if (delta < -(1 << 20) or delta >= (1 << 20)) a.overflow = true;
                a.patchWord(f.at, jtypeImm(@truncate(delta)));
            },
            .branch => {
                if (delta < -(1 << 12) or delta >= (1 << 12)) a.overflow = true;
                a.patchWord(f.at, btypeImm(@truncate(delta)));
            },
            .literal, .far => {
                // auipc takes the upper 20 bits, rounded so that the
                // signed low 12 bits of the load or the jump complete
                // the offset.
                if (delta < -(1 << 31) or delta >= (1 << 31) - 0x800) a.overflow = true;
                const hi: i64 = (delta + 0x800) >> 12;
                const lo: i64 = delta - (hi << 12);
                a.patchWord(f.at, @as(u32, @truncate(@as(u64, @bitCast(hi)))) << 12);
                a.patchWord(f.at + 4, (@as(u32, @truncate(@as(u64, @bitCast(lo)))) & 0xFFF) << 20);
            },
            .done => {},
        }
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        a.flushPool();
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            if (f.kind == .literal or f.kind == .done) continue;
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
        a.word(itype(0, src.n(), 0, dst.n(), op_imm));
    }

    /// Loads a 64-bit constant with the shortest sequence: one `addi`, a
    /// `lui` and an `addiw` for a value that fits 32 signed bits, and a
    /// load from the pool otherwise.
    pub fn movImm(a: *Assembler, dst: Reg, v: u64) void {
        const sv: i64 = @bitCast(v);
        if (fitsI12(sv)) return a.word(itype(@intCast(sv), 0, 0, dst.n(), op_imm));
        if (sv >= std.math.minInt(i32) and sv <= std.math.maxInt(i32)) {
            const lo: i64 = @as(i64, @as(i12, @truncate(sv)));
            // addiw wraps the sum to 32 bits and sign-extends it, which
            // also covers an upper part of 0x80000.
            const hi: u32 = @as(u32, @truncate(@as(u64, @bitCast(sv - lo)) >> 12)) & 0xFFFFF;
            a.word(hi << 12 | dst.n() << 7 | op_lui);
            if (lo != 0) a.word(itype(@intCast(lo), dst.n(), 0, dst.n(), op_imm32));
            return;
        }
        var index: usize = 0;
        while (index < a.pool.items.len and a.pool.items[index] != v) index += 1;
        if (index == a.pool.items.len) a.pool.append(a.gpa, v) catch {
            a.oom = true;
        };
        a.fix(@intCast(index), .literal);
        a.word(dst.n() << 7 | op_auipc);
        a.word(itype(0, dst.n(), 3, dst.n(), op_load));
    }

    // -----------------------------------------------------------------
    // Memory

    /// Returns a memory operand whose displacement fits 12 signed bits,
    /// computing a far address into the scratch register `s1`.
    fn near(a: *Assembler, m: Mem) Mem {
        if (fitsI12(m.disp)) return m;
        a.movImm(s1, @bitCast(@as(i64, m.disp)));
        a.word(rtype(0, m.base.n(), s1.n(), 0, s1.n(), op_reg));
        return .{ .base = s1 };
    }
    fn load(a: *Assembler, f3: u32, rd: u32, m: Mem, opcode: u32) void {
        const q = a.near(m);
        a.word(itype(q.disp, q.base.n(), f3, rd, opcode));
    }
    fn store(a: *Assembler, f3: u32, rs: u32, m: Mem, opcode: u32) void {
        const q = a.near(m);
        a.word(stype(q.disp, rs, q.base.n(), f3, opcode));
    }

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.load(3, dst.n(), m, op_load);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.store(3, src.n(), m, op_store);
    }
    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        a.load(6, dst.n(), m, op_load);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.store(2, src.n(), m, op_store);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.load(4, dst.n(), m, op_load);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        a.store(0, src.n(), m, op_store);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.load(5, dst.n(), m, op_load);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.store(1, src.n(), m, op_store);
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
        a.load(3, dst.n(), m, op_fload);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.store(3, src.n(), m, op_fstore);
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
            return a.word(itype(m.disp, m.base.n(), 0, dst.n(), op_imm));
        }
        a.movImm(s1, @bitCast(@as(i64, m.disp)));
        a.word(rtype(0, s1.n(), m.base.n(), 0, dst.n(), op_reg));
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        if (shift == 0) return a.word(rtype(0, index.n(), b.n(), 0, dst.n(), op_reg));
        a.word(itype(shift, index.n(), 1, s0.n(), op_imm));
        a.word(rtype(0, s0.n(), b.n(), 0, dst.n(), op_reg));
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.word(itype(shift, index.n(), 1, s0.n(), op_imm));
        a.word(rtype(0x20, s0.n(), b.n(), 0, dst.n(), op_reg));
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
        a.word(rtype(0x20, dst.n(), 0, 0, dst.n(), op_reg));
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.word(itype(-1, dst.n(), 4, dst.n(), op_imm));
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        a.addImm3(dst, dst, v);
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        a.word(rtype(1, y.n(), x.n(), 4, s0.n(), op_reg)); // div s0, x, y
        a.word(rtype(1, y.n(), x.n(), 6, s1.n(), op_reg)); // rem s1, x, y
        a.mov(quot, s0);
        a.mov(rem, s1);
    }

    // -----------------------------------------------------------------
    // Floats. Arithmetic rounds with the dynamic mode, which is to
    // nearest even.

    fn fop(a: *Assembler, f7: u32, dst: FReg, x: FReg, y: FReg) void {
        a.word(rtype(f7, y.n(), x.n(), 7, dst.n(), op_fp));
    }
    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(0x01, dst, dst, src);
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(0x05, dst, dst, src);
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(0x09, dst, dst, src);
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.fop(0x0D, dst, dst, src);
    }
    /// Converts a signed integer to a float.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(rtype(0x69, 2, src.n(), 7, dst.n(), op_fp)); // fcvt.d.l
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(rtype(0x79, 0, src.n(), 0, dst.n(), op_fp)); // fmv.d.x
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(rtype(0x71, 0, src.n(), 0, dst.n(), op_fp)); // fmv.x.d
    }
    fn fsgnj(a: *Assembler, f3: u32, dst: FReg, src: FReg) void {
        a.word(rtype(0x11, src.n(), src.n(), f3, dst.n(), op_fp));
    }
    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.fsgnj(0, dst, src);
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.fsgnj(1, dst, src);
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.fsgnj(2, dst, src);
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(rtype(0x2D, 0, src.n(), 7, dst.n(), op_fp));
    }
    /// RV64GC has no instruction that rounds to an integral float, so the
    /// emitter takes the path of a target without one.
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
        a.word(rtype(0x61, 2, src.n(), 1, dst.n(), op_fp)); // fcvt.l.d, rtz
    }

    // Three-operand forms: dst = x op y.
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(0, y.n(), x.n(), 0, dst.n(), op_reg));
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(0x20, y.n(), x.n(), 0, dst.n(), op_reg));
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(1, y.n(), x.n(), 0, dst.n(), op_reg));
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(0, y.n(), x.n(), 7, dst.n(), op_reg));
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(0, y.n(), x.n(), 6, dst.n(), op_reg));
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(rtype(0, y.n(), x.n(), 4, dst.n(), op_reg));
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0x01, dst, x, y);
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0x05, dst, x, y);
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0x09, dst, x, y);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fop(0x0D, dst, x, y);
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        if (v == 0) return a.mov(dst, x);
        if (fitsI12(v)) return a.word(itype(v, x.n(), 0, dst.n(), op_imm));
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
        a.word(rtype(1, y.n(), x.n(), 4, s0.n(), op_reg)); // div s0, x, y
        a.word(rtype(1, y.n(), x.n(), 6, s1.n(), op_reg)); // rem s1, x, y
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.word(btypeImm(16) | rtype(0, 0, s1.n(), 0, 0, op_branch)); // beqz s1, +16
        a.xor3(tmp, s1, y);
        a.word(btypeImm(8) | rtype(0, 0, tmp.n(), 5, 0, op_branch)); // bgez tmp, +8
        if (mod) a.add3(s1, s1, y) else a.word(itype(-1, s0.n(), 0, s0.n(), op_imm));
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
        a.fix(l, .jal);
        a.word(op_jal);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.word(itype(0, r.n(), 0, 0, op_jalr));
    }
    /// A conditional branch on two registers. A label that is bound and in
    /// reach gets one instruction. Any other gets the inverted branch over
    /// a `jal`.
    fn branch(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        const b = branchOf(c);
        const rs1 = if (b.swap) y else x;
        const rs2 = if (b.swap) x else y;
        if (l < a.labels.items.len and a.labels.items[l] != unbound) {
            const delta = @as(i64, a.labels.items[l]) - @as(i64, a.offset());
            if (delta >= -(1 << 12)) {
                a.fix(l, .branch);
                return a.word(rtype(0, rs2.n(), rs1.n(), b.f3, 0, op_branch));
            }
        }
        a.word(btypeImm(8) | rtype(0, rs2.n(), rs1.n(), b.f3 ^ 1, 0, op_branch));
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
        if (v == 0) return a.jumpIf(c, x, .zero, l);
        a.movImm(s1, @bitCast(@as(i64, v)));
        a.jumpIf(c, x, s1, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.word(itype(0, x.n(), 0, s0.n(), op_imm32)); // sext.w s0, x
        a.branch(if (zero) .eq else .ne, s0, .zero, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.load8(s0, m);
        if (v == 0) return a.jumpIf(c, s0, .zero, l);
        a.movImm(s1, v);
        a.jumpIf(c, s0, s1, l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        a.load8(s0, m);
        a.word(itype(@as(i32, 1) << bit, s0.n(), 7, s0.n(), op_imm)); // andi
        a.branch(if (set) .ne else .eq, s0, .zero, l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        // flt.d, fle.d, and feq.d write 1 when the comparison holds and 0
        // when it fails or an operand is NaN.
        const f3: u32 = switch (c) {
            .lt, .nlt => 1,
            .le, .nle => 0,
            .eq, .ne => 2,
        };
        a.word(rtype(0x51, y.n(), x.n(), f3, s0.n(), op_fp));
        const holds = switch (c) {
            .lt, .le, .eq => true,
            .nlt, .nle, .ne => false,
        };
        a.branch(if (holds) .ne else .eq, s0, .zero, l);
    }

    /// Calls a function at an absolute address.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(s0, addr);
        a.callReg(s0);
    }
    /// Calls a routine in the same code, which ends with `leave`.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.fix(l, .jal);
        a.word(Reg.ra.n() << 7 | op_jal);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.word(itype(0, r.n(), 0, Reg.ra.n(), op_jalr));
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.jmpReg(.ra);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry. That
    /// jump is always one `jal`.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.word(itype(4, Reg.ra.n(), 0, dst.n(), op_imm));
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
        a.word(ebreak);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the callee-saved registers it uses and loads the pinned ones.
    pub fn prologue(a: *Assembler) void {
        a.addImm(.sp, -frame_size);
        a.store64(.ra, .{ .base = .sp, .disp = ra_slot });
        for (saved, 0..) |r, i| a.store64(r, .{ .base = .sp, .disp = @intCast(i * 8) });
        a.mov(thread, .x10);
        a.mov(stop, .x11);
        a.mov(base, .x13);
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
// each call, assembled for RV64GC without compressed instructions.

test "riscv64 moves, memory, and arithmetic" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.x10, .x9); // mv a0, s1
    a.movImm(.x11, 0); // li a1, 0
    a.movImm(.x5, 0x123); // li t0, 0x123
    a.movImm(.x5, 0x12345678); // lui t0, 0x12345; addiw t0, t0, 0x678
    a.movImm(.x5, @bitCast(@as(i64, -2))); // li t0, -2
    a.load64(.x5, .{ .base = .x18, .disp = 16 }); // ld t0, 16(s2)
    a.store64(.x5, .{ .base = .x18, .disp = 24 }); // sd t0, 24(s2)
    a.load64(.x5, .{ .base = .x18, .disp = -16 }); // ld t0, -16(s2)
    a.load8(.x6, .{ .base = .x18, .disp = 8 }); // lbu t1, 8(s2)
    a.load32(.x6, .{ .base = .x9, .disp = 4 }); // lwu t1, 4(s1)
    a.load16(.x5, .{ .base = .x18, .disp = 2 }); // lhu t0, 2(s2)
    a.store16(.x5, .{ .base = .x18, .disp = 2 }); // sh t0, 2(s2)
    a.storeImm16(.{ .base = .x5, .disp = 2 }, 0); // sh zero, 2(t0)
    a.store32(.x5, .{ .base = .x18, .disp = 16 }); // sw t0, 16(s2)
    a.loadF(.f10, .{ .base = .x18 }); // fld fa0, 0(s2)
    a.storeF(.f11, .{ .base = .x18, .disp = 8 }); // fsd fa1, 8(s2)
    a.add(.x5, .x6); // add t0, t0, t1
    a.sub(.x5, .x6); // sub t0, t0, t1
    a.mul(.x5, .x6); // mul t0, t0, t1
    a.addImm(.x5, 5); // addi t0, t0, 5
    a.addImm(.x5, -5); // addi t0, t0, -5
    a.neg(.x5); // neg t0, t0
    a.not(.x5); // not t0, t0
    a.fadd(.f10, .f11); // fadd.d fa0, fa0, fa1, dyn
    a.intToFloat(.f10, .x5); // fcvt.d.l fa0, t0, dyn
    a.floatToInt(.x5, .f10); // fcvt.l.d t0, fa0, rtz
    a.bitsToFloat(.f10, .x5); // fmv.d.x fa0, t0
    a.floatToBits(.x5, .f10); // fmv.x.d t0, fa0
    a.fmov(.f10, .f11); // fsgnj.d fa0, fa1, fa1
    a.fneg(.f10, .f11); // fsgnjn.d fa0, fa1, fa1
    a.fabs(.f10, .f11); // fsgnjx.d fa0, fa1, fa1
    a.fsqrt(.f10, .f11); // fsqrt.d fa0, fa1, dyn
    a.addScaled(.x18, .x5, .x19, 4); // slli a6, s3, 4; add s2, t0, a6
    try expectWords(&a, &.{
        0x00048513, 0x00000593, 0x12300293, 0x123452B7, 0x6782829B, 0xFFE00293, 0x01093283, 0x00593C23,
        0xFF093283, 0x00894303, 0x0044E303, 0x00295283, 0x00591123, 0x00029123, 0x00592823, 0x00093507,
        0x00B93427, 0x006282B3, 0x406282B3, 0x026282B3, 0x00528293, 0xFFB28293, 0x405002B3, 0xFFF2C293,
        0x02B57553, 0xD222F553, 0xC22512D3, 0xF2028553, 0xE20502D3, 0x22B58553, 0x22B59553, 0x22B5A553,
        0x5A05F553, 0x00499813, 0x01028933,
    });
}

test "riscv64 three-operand forms, tests, and calls" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.divRem(.x5, .x6, .x28, .x29); // div a6, t3, t4; rem a7, t3, t4; mv t0, a6; mv t1, a7
    a.and3(.x5, .x6, .x7); // and t0, t1, t2
    a.or3(.x5, .x6, .x7); // or t0, t1, t2
    a.xor3(.x5, .x6, .x7); // xor t0, t1, t2
    a.callReg(.x16); // jalr ra, a6, 0
    a.retLocal(); // jalr zero, ra, 0
    a.linkPastJump(.x5); // addi t0, ra, 4
    a.trap(); // ebreak
    try expectWords(&a, &.{
        0x03DE4833, 0x03DE68B3, 0x00080293, 0x00088313, 0x007372B3, 0x007362B3, 0x007342B3,
        0x000800E7, 0x00008067, 0x00408293, 0x00100073,
    });
}

test "riscv64 floor division and modulo" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.floorDiv(.x5, .x28, .x29, true, .x23, .x23);
    a.floorDiv(.x5, .x28, .x29, false, .x23, .x23);
    try expectWords(&a, &.{
        // div a6, t3, t4; rem a7, t3, t4; beqz a7, .+16; xor s7, a7, t4;
        // bgez s7, .+8; add a7, a7, t4; mv t0, a7
        0x03DE4833, 0x03DE68B3, 0x00088863, 0x01D8CBB3, 0x000BD463, 0x01D888B3, 0x00088293,
        // the same with addi a6, a6, -1 and mv t0, a6
        0x03DE4833, 0x03DE68B3, 0x00088863, 0x01D8CBB3, 0x000BD463, 0xFFF80813, 0x00080293,
    });
}

test "riscv64 tests of bytes, bits, and floats" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l = a.newLabel();
    a.jumpIfZero32(.x5, true, l); // sext.w a6, t0; bne a6, zero, .+8; j l
    a.jumpIfBit(.{ .base = .x5 }, 3, true, l); // lbu a6, 0(t0); andi a6, a6, 8; beq a6, zero, .+8; j l
    a.jumpIfFloat(.lt, .f10, .f11, l); // flt.d a6, fa0, fa1; beq a6, zero, .+8; j l
    a.jumpIfFloat(.nle, .f10, .f11, l); // fle.d a6, fa0, fa1; bne a6, zero, .+8; j l
    a.jumpIfFloat(.eq, .f10, .f11, l); // feq.d a6, fa0, fa1; beq a6, zero, .+8; j l
    a.jumpIf(.mi, .x5, .x6, l); // sub a6, t0, t1; bge a6, zero, .+8; j l
    a.bind(l);
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x0002881B), w[0]);
    try std.testing.expectEqual(@as(u32, 0x00887813), w[4]);
    try std.testing.expectEqual(@as(u32, 0xA2B51853), w[7]);
    try std.testing.expectEqual(@as(u32, 0xA2B50853), w[10]);
    try std.testing.expectEqual(@as(u32, 0xA2B52853), w[13]);
    try std.testing.expectEqual(@as(u32, 0x40628833), w[16]);
    // The inverted branches skip their jumps.
    try std.testing.expectEqual(@as(u32, 0x00081463), w[1]); // bne a6, zero, .+8
    try std.testing.expectEqual(@as(u32, 0x00080463), w[5]); // beq a6, zero, .+8
    try std.testing.expectEqual(@as(u32, 0x00081463), w[11]); // bne a6, zero, .+8
    try std.testing.expectEqual(@as(u32, 0x00085463), w[17]); // bge a6, zero, .+8
}

test "riscv64 branches resolve in both directions" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const top = a.newLabel();
    const end = a.newLabel();
    a.bind(top);
    a.jumpIf(.lt, .x5, .x6, end); // bge t0, t1, .+8; jal zero, end
    a.jumpIfImm(.eq, .x5, 0, top); // beq t0, zero, top
    a.jmp(top); // jal zero, top
    a.bind(end);
    a.jumpIf(.gt, .x5, .x6, end); // blt t1, t0, end
    a.jumpIf(.hi, .x5, .x6, top); // bltu t1, t0, top
    a.jumpIf(.ls, .x5, .x6, top); // bgeu t1, t0, top
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x0062D463), w[0]);
    try std.testing.expectEqual(@as(u32, 0x00C0006F), w[1]);
    try std.testing.expectEqual(@as(u32, 0xFE028CE3), w[2]);
    try std.testing.expectEqual(@as(u32, 0xFF5FF06F), w[3]);
    try std.testing.expectEqual(@as(u32, 0x00534063), w[4]); // blt t1, t0, .+0
    try std.testing.expectEqual(@as(u32, 0xFE5366E3), w[5]); // bltu t1, t0, .-20
    try std.testing.expectEqual(@as(u32, 0xFE5374E3), w[6]); // bgeu t1, t0, .-24
}

test "riscv64 far branches and unbound labels" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const top = a.newLabel();
    a.bind(top);
    for (0..1100) |_| a.trap();
    // 4400 bytes back is beyond a conditional branch, so the branch takes
    // the long form.
    a.jumpIf(.eq, .x5, .x6, top);
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0x00629463), w[1100]); // bne t0, t1, .+8
    try std.testing.expectEqual(@as(u32, 0x0006F) | jtypeImm(-4404), w[1101]);

    var b = Assembler.init(std.testing.allocator);
    defer b.deinit();
    b.jmp(b.newLabel());
    try std.testing.expect(!b.finish());
}

test "riscv64 wide constants load from the pool" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.movImm(.x5, 0x1122334455667788); // auipc t0, 0; ld t0, pool[0](t0)
    a.movImm(.x6, 0x1122334455667788); // auipc t1, 0; ld t1, pool[0](t1)
    a.movImm(.x7, 0x0000123456789ABC); // auipc t2, 0; ld t2, pool[1](t2)
    a.epilogue();
    try std.testing.expect(a.finish());
    const bytes = a.buf.items;
    const w = std.mem.bytesAsSlice(u32, bytes);
    const want = [_]u64{ 0x1122334455667788, 0x1122334455667788, 0x0000123456789ABC };
    for (want, 0..) |v, i| {
        const at = i * 8;
        const auipc = std.mem.littleToNative(u32, w[at / 4]);
        const ld = std.mem.littleToNative(u32, w[at / 4 + 1]);
        try std.testing.expectEqual(@as(u32, 0x17), auipc & 0x7F);
        try std.testing.expectEqual(@as(u32, 0x3003), ld & 0x707F);
        const hi: i64 = @as(i32, @bitCast(auipc & 0xFFFFF000));
        const lo: i64 = @as(i32, @bitCast(ld)) >> 20;
        const target: usize = @intCast(@as(i64, @intCast(at)) + hi + lo);
        try std.testing.expectEqual(v, std.mem.readInt(u64, bytes[target..][0..8], .little));
    }
}

test "riscv64 far jumps go through islands" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const far = a.newLabel();
    const over = a.newLabel();
    a.jmp(far); // jal zero, island
    a.jmp(over); // jal zero, island
    a.flushPool(); // two islands
    a.bind(over);
    for (0..300_000) |_| a.trap();
    a.bind(far);
    a.trap();
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, op_jal) | jtypeImm(8), w[0]);
    try std.testing.expectEqual(@as(u32, op_jal) | jtypeImm(12), w[1]);
    // Each island adds the upper and lower parts of its offset to its pc.
    for ([_]usize{ 2, 4 }, [_]u32{ 1_200_024, 24 }) |at, want| {
        const auipc = w[at];
        const jalr = w[at + 1];
        try std.testing.expectEqual(@as(u32, 0x17 | 16 << 7), auipc & 0xFFF);
        try std.testing.expectEqual(@as(u32, 0x67 | 16 << 15), jalr & 0xFFFFF);
        const hi: i64 = @as(i32, @bitCast(auipc & 0xFFFFF000));
        const lo: i64 = @as(i32, @bitCast(jalr)) >> 20;
        try std.testing.expectEqual(@as(i64, want), @as(i64, @intCast(at * 4)) + hi + lo);
    }
}
