//! The 32-bit ARM backend of the JIT assembler, for ARMv7-A in the A32
//! encoding with VFPv3-D16 and the hard-float convention. It offers the
//! interface of `a64.zig`, whose registers hold 64 bits. Here a register
//! of the interface is a pair of machine registers, a machine register
//! and a word of the native frame, two words of the native frame, or one
//! machine register whose high word reads as zero. Every operation keeps
//! its 64-bit meaning, so `emit.zig` and `opt/codegen.zig` describe each
//! opcode once for every target (`spec/design/platforms.md`, "32-bit
//! ARM").

const std = @import("std");
const reloc = @import("reloc.zig");

/// A machine register.
const P = u4;
const r0: P = 0;
const r1: P = 1;
const r2: P = 2;
const r3: P = 3;
/// The base of the frame that the entry sequence opens.
const fp: P = 11;
const ip: P = 12;
const sp_r: P = 13;
const lr: P = 14;
const pc: P = 15;
/// Scratch registers of the assembler itself. A local call keeps its
/// return address in the frame, which frees the link register.
const S0: P = ip;
const S1: P = lr;
const S2: P = 10;

/// A register of the interface. The temporaries share their low words
/// with the argument registers in the order of `s390x.zig`: `t4` is the
/// first argument and the first result, `t3` the second of each, `t2`
/// the third argument, `t1` the fourth, and `t5` the fifth.
pub const Reg = enum(u8) {
    /// r6 and r7.
    t0,
    /// r3 and r8.
    t1,
    /// r2 and r9.
    t2,
    /// r1 and a word of the frame.
    t3,
    /// r0 and a word of the frame.
    t4,
    // Two words of the frame each.
    t5,
    t6,
    /// The scratch registers of the code generator.
    c0,
    c1,
    /// Registers that only the pool of the optimizing tier names.
    v0,
    v1,
    v2,
    v3,
    v4,
    v5,
    /// r4.
    thread,
    /// r5.
    bp,
    // One word of the frame each.
    base,
    stop,
    /// r13.
    sp,
};

pub const FReg = enum(u4) {
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    d10,
    d11,
    d12,
    d13,
    d14,
    d15,

    inline fn n(r: FReg) u32 {
        return @backingInt(r);
    }
};

/// The native stack pointer, as the base of a memory operand.
pub const sp: Reg = .sp;

pub const thread: Reg = .thread;
pub const bp: Reg = .bp;
pub const base: Reg = .base;
pub const stop: Reg = .stop;
pub const t0: Reg = .t0;
pub const t1: Reg = .t1;
pub const t2: Reg = .t2;
pub const t3: Reg = .t3;
pub const t4: Reg = .t4;
pub const t5: Reg = .t5;
pub const t6: Reg = .t6;
pub const args = [_]Reg{ .t4, .t3, .t2, .t1, .t5 };
pub const ret0: Reg = .t4;
pub const ret1: Reg = .t3;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .t2;
pub const f0: FReg = .d0;
pub const f1: FReg = .d1;
/// Float scratch registers of the assembler itself, and the register
/// that `zeroPrepare` clears. The entry sequence saves d8 to d12.
const fs0: FReg = .d10;
const fs1: FReg = .d11;
const fzero: FReg = .d12;

// The frame of the entry sequence, from its base upward.
const slot_base = 0;
const slot_stop = 4;
/// The return address of the local call that runs.
const slot_link = 8;
/// The two words that a routine called by `callPair` returns.
const slot_pair = 16;
const slot_t3_hi = 24;
const slot_t4_hi = 28;
const slot_regs = 32;
const frame_size = slot_regs + 10 * 8;

/// Where one word of a register lives.
const W = union(enum) {
    r: P,
    m: struct { b: P, d: i32 },
    /// A high word that reads as zero. A write to it is dropped.
    zero,

    fn at(d: i32) W {
        return .{ .m = .{ .b = fp, .d = d } };
    }
};

fn lo(r: Reg) W {
    return switch (r) {
        .t0 => .{ .r = 6 },
        .t1 => .{ .r = r3 },
        .t2 => .{ .r = r2 },
        .t3 => .{ .r = r1 },
        .t4 => .{ .r = r0 },
        .thread => .{ .r = 4 },
        .bp => .{ .r = 5 },
        .sp => .{ .r = sp_r },
        .base => W.at(slot_base),
        .stop => W.at(slot_stop),
        .t5, .t6, .c0, .c1, .v0, .v1, .v2, .v3, .v4, .v5 => W.at(home(r)),
    };
}

fn hi(r: Reg) W {
    return switch (r) {
        .t0 => .{ .r = 7 },
        .t1 => .{ .r = 8 },
        .t2 => .{ .r = 9 },
        .t3 => W.at(slot_t3_hi),
        .t4 => W.at(slot_t4_hi),
        .thread, .bp, .sp, .base, .stop => .zero,
        .t5, .t6, .c0, .c1, .v0, .v1, .v2, .v3, .v4, .v5 => W.at(home(r) + 4),
    };
}

/// The offset in the frame of a register that lives there whole.
fn home(r: Reg) i32 {
    return slot_regs + 8 * (@as(i32, @backingInt(r)) - @as(i32, @backingInt(Reg.t5)));
}

/// The register to compute a word in: its own, or `s` when it lives in
/// the frame.
fn target(w: W, s: P) P {
    return switch (w) {
        .r => |p| p,
        else => s,
    };
}

/// The condition codes of A32.
pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    /// Unsigned higher or same.
    hs = 2,
    /// Unsigned lower.
    lo = 3,
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
const cc_eq: u4 = 0;
const cc_ne: u4 = 1;
const cc_mi: u4 = 4;
const cc_pl: u4 = 5;
const cc_hi: u4 = 8;
const cc_ls: u4 = 9;
const cc_ge: u4 = 10;
const cc_lt: u4 = 11;
const al: u4 = 14;

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
};

// Data-processing opcodes.
const op_and: u4 = 0;
const op_eor: u4 = 1;
const op_sub: u4 = 2;
const op_rsb: u4 = 3;
const op_add: u4 = 4;
const op_adc: u4 = 5;
const op_sbc: u4 = 6;
const op_rsc: u4 = 7;
const op_tst: u4 = 8;
const op_cmp: u4 = 10;
const op_orr: u4 = 12;
const op_mov: u4 = 13;
const op_mvn: u4 = 15;

/// The second operand of a data-processing instruction that is the
/// constant `v`, when a rotated byte can hold it.
fn immOp(v: u32) ?u32 {
    var rot: u32 = 0;
    while (rot < 16) : (rot += 1) {
        const x = std.math.rotl(u32, v, 2 * rot);
        if (x < 256) return 1 << 25 | rot << 8 | x;
    }
    return null;
}

/// An operand of a comparison: a word of a register, or a constant.
const Y = union(enum) {
    w: W,
    imm: u32,

    fn isZero(y: Y) bool {
        return switch (y) {
            .w => |w| w == .zero,
            .imm => |v| v == 0,
        };
    }
};

/// The routines that division and float truncation call, since ARMv7-A
/// divides only 32-bit integers and VFP converts only to them.
const rt = struct {
    // The contract of the interface keeps a divisor of zero or minus one
    // away from these routines. They stay total all the same. Each
    // divides once and finds the remainder with a multiplication. Most
    // operands fit 32 bits, where the division is several times shorter.
    fn truncDiv(x: i64, y: i64) i64 {
        if (y == 0) return 0;
        if (y == -1) return 0 -% x;
        const xn: i32 = @truncate(x);
        const yn: i32 = @truncate(y);
        if (xn == x and yn == y) return @divTrunc(xn, yn);
        return @divTrunc(x, y);
    }
    fn divRem(x: i64, y: i64, rem: *i64) callconv(.c) i64 {
        const q = truncDiv(x, y);
        rem.* = x -% q *% y;
        return q;
    }
    // The truncated results are right unless the remainder is not zero
    // and its sign differs from the sign of the divisor.
    fn floorDiv(x: i64, y: i64) callconv(.c) i64 {
        const q = truncDiv(x, y);
        const r = x -% q *% y;
        return if (r != 0 and (r ^ y) < 0) q -% 1 else q;
    }
    fn floorMod(x: i64, y: i64) callconv(.c) i64 {
        const r = x -% truncDiv(x, y) *% y;
        return if (r != 0 and (r ^ y) < 0) r +% y else r;
    }
    /// Truncates toward zero. A value outside the range gives the
    /// nearest integer. NaN gives zero.
    fn floatToInt(bits: u64) callconv(.c) i64 {
        return std.math.lossyCast(i64, @as(f64, @bitCast(bits)));
    }
};

fn addrOf(f: anytype) u32 {
    return @truncate(@intFromPtr(f));
}

/// The routines of this file that native code calls, which the
/// relocations of code compiled ahead of time number after the routines
/// that every target shares (`aot.routineId`).
pub const routines = [_]*const anyopaque{
    @ptrCast(&rt.divRem),
    @ptrCast(&rt.floorDiv),
    @ptrCast(&rt.floorMod),
    @ptrCast(&rt.floatToInt),
};

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Offset of each label, or `unbound`.
    labels: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    oom: bool = false,
    /// Set when the code is compiled ahead of time (`reloc.zig`). The
    /// routines that write addresses record relocations.
    aot: bool = false,
    relocs: std.ArrayList(reloc.Entry) = .empty,
    /// How many candidate immediates the resolver called unknown, or
    /// found no resolver for, while `aot` was set.
    unrelocated: u32 = 0,
    /// Decides what a candidate immediate is.
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

    /// Every constant builds in place with `mov`, `mvn`, or `movw` and
    /// `movt`, so the assembler keeps no pool.
    pub fn flushPool(a: *Assembler) void {
        _ = a;
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            const to = a.labels.items[f.label];
            if (to == unbound) return false;
            // A branch counts from two instructions past itself.
            const delta = @divExact(@as(i64, to) - @as(i64, f.at) - 8, 4);
            if (delta < -(1 << 23) or delta >= (1 << 23)) a.overflow = true;
            const p: *align(1) u32 = @ptrCast(a.buf.items[f.at..].ptr);
            const w = std.mem.littleToNative(u32, p.*);
            p.* = std.mem.nativeToLittle(u32, w | (@as(u32, @truncate(@as(u64, @bitCast(delta)))) & 0x00FF_FFFF));
        }
        return !a.overflow;
    }

    // -----------------------------------------------------------------
    // Machine instructions

    /// A data-processing instruction. `operand` is a register number or the
    /// result of `immOp`.
    fn dp(a: *Assembler, c: u4, op: u4, s: bool, rn: P, rd: P, operand: u32) void {
        a.word(@as(u32, c) << 28 | @as(u32, op) << 21 | @as(u32, @intFromBool(s)) << 20 | @as(u32, rn) << 16 | @as(u32, rd) << 12 | operand);
    }
    fn movP(a: *Assembler, dst: P, src: P) void {
        if (dst != src) a.dp(al, op_mov, false, 0, dst, src);
    }
    fn cmpP(a: *Assembler, c: u4, x: P, operand: u32) void {
        a.dp(c, op_cmp, true, x, 0, operand);
    }
    /// Loads a 32-bit constant.
    fn imm32(a: *Assembler, dst: P, v: u32) void {
        if (immOp(v)) |o| return a.dp(al, op_mov, false, 0, dst, o);
        if (immOp(~v)) |o| return a.dp(al, op_mvn, false, 0, dst, o);
        a.word(0xE3000000 | (v >> 12 & 0xF) << 16 | @as(u32, dst) << 12 | (v & 0xFFF));
        if (v >> 16 != 0) a.word(0xE3400000 | (v >> 28) << 16 | @as(u32, dst) << 12 | (v >> 16 & 0xFFF));
    }
    /// Loads an address in the form whose bytes the loader patches: a
    /// `movw` and a `movt`, whatever the value.
    fn immReloc(a: *Assembler, dst: P, v: u32, r: reloc.Reloc) void {
        a.relocs.append(a.gpa, .{ .at = a.offset(), .form = .arm_pair, .r = r }) catch {
            a.oom = true;
        };
        a.word(0xE3000000 | (v >> 12 & 0xF) << 16 | @as(u32, dst) << 12 | (v & 0xFFF));
        a.word(0xE3400000 | (v >> 28) << 16 | @as(u32, dst) << 12 | (v >> 16 & 0xFFF));
    }
    /// What a constant the size of a pointer is, when the code is
    /// compiled ahead of time: the relocation of an address, or null for
    /// a value that builds in place. Every address of this target is one
    /// word, so the resolver sees each such constant above the first
    /// 64 KB, and one that it cannot name is counted. The constants of
    /// `addImm`, `jumpIfImm`, and `storeImm32` are 32-bit integers on
    /// every target and build in place.
    fn candidate(a: *Assembler, v: u32) ?reloc.Reloc {
        if (!a.aot or !reloc.wide32(v)) return null;
        const res: reloc.Resolution = if (a.resolver) |rs| rs.resolve(rs.ctx, v) else .unknown;
        switch (res) {
            .address => |r| return r,
            .literal => {},
            .unknown => a.unrelocated += 1,
        }
        return null;
    }
    /// Loads a word that may be an address.
    fn immAny(a: *Assembler, dst: P, v: u32) void {
        if (a.candidate(v)) |r| return a.immReloc(dst, v, r);
        a.imm32(dst, v);
    }
    /// Loads a word that `r` names: an address in its patchable form
    /// ahead of time, and a literal in place.
    fn immNamed(a: *Assembler, dst: P, v: u32, r: reloc.Reloc) void {
        if (a.aot and r.kind != .literal) return a.immReloc(dst, v, r);
        a.imm32(dst, v);
    }
    /// dst = src + v, in as many additions as `v` has bytes that a
    /// rotated constant holds.
    fn addP(a: *Assembler, dst: P, src: P, v: i32) void {
        if (v == 0) return a.movP(dst, src);
        var rest: u32 = @abs(v);
        const op: u4 = if (v > 0) op_add else op_sub;
        var from = src;
        while (rest != 0) {
            const shift: u5 = @intCast(@ctz(rest) & ~@as(u32, 1));
            const chunk = rest & (@as(u32, 0xFF) << shift);
            a.dp(al, op, false, from, dst, immOp(chunk).?);
            rest &= ~chunk;
            from = dst;
        }
    }
    /// A load or a store of a word or a byte at an offset below 4096.
    fn ldst(a: *Assembler, load: bool, byte: bool, rt_: P, b: P, d: i32) void {
        const mag: u32 = @abs(d);
        std.debug.assert(mag < 4096);
        a.word(0xE5000000 | @as(u32, @intFromBool(d >= 0)) << 23 | @as(u32, @intFromBool(byte)) << 22 | @as(u32, @intFromBool(load)) << 20 | @as(u32, b) << 16 | @as(u32, rt_) << 12 | mag);
    }
    fn ldr(a: *Assembler, dst: P, b: P, d: i32) void {
        a.ldst(true, false, dst, b, d);
    }
    fn str(a: *Assembler, src: P, b: P, d: i32) void {
        a.ldst(false, false, src, b, d);
    }
    /// A load or a store of 16 bits at an offset below 256.
    fn ldsth(a: *Assembler, load: bool, rt_: P, b: P, d: i32) void {
        const mag: u32 = @abs(d);
        std.debug.assert(mag < 256);
        a.word(0xE14000B0 | @as(u32, @intFromBool(d >= 0)) << 23 | @as(u32, @intFromBool(load)) << 20 | @as(u32, b) << 16 | @as(u32, rt_) << 12 | (mag >> 4) << 8 | (mag & 15));
    }
    /// A load or a store of a double at a multiple of four below 1024.
    fn ldstf(a: *Assembler, load: bool, d_: FReg, b: P, d: i32) void {
        const mag: u32 = @abs(d);
        std.debug.assert(mag < 1024 and mag % 4 == 0);
        a.word(0xED000B00 | @as(u32, @intFromBool(d >= 0)) << 23 | @as(u32, @intFromBool(load)) << 20 | @as(u32, b) << 16 | d_.n() << 12 | mag / 4);
    }
    fn push(a: *Assembler, mask: u32) void {
        a.word(0xE92D0000 | mask);
    }
    fn pop(a: *Assembler, mask: u32) void {
        a.word(0xE8BD0000 | mask);
    }
    fn vpush(a: *Assembler, first: FReg, count: u32) void {
        a.word(0xED2D0B00 | first.n() << 12 | 2 * count);
    }
    fn vpop(a: *Assembler, first: FReg, count: u32) void {
        a.word(0xECBD0B00 | first.n() << 12 | 2 * count);
    }
    fn blx(a: *Assembler, r: P) void {
        a.word(0xE12FFF30 | @as(u32, r));
    }
    fn bx(a: *Assembler, r: P) void {
        a.word(0xE12FFF10 | @as(u32, r));
    }
    fn branch(a: *Assembler, c: u4, l: Label) void {
        a.fixups.append(a.gpa, .{ .at = a.offset(), .label = l }) catch {
            a.oom = true;
        };
        a.word(@as(u32, c) << 28 | 0x0A000000);
    }

    // -----------------------------------------------------------------
    // Words of registers

    /// The machine register that holds the word, which is `s` after a
    /// load when the word lives in the frame.
    fn get(a: *Assembler, w: W, s: P) P {
        switch (w) {
            .r => |p| return p,
            .m => |m| a.ldr(s, m.b, m.d),
            .zero => a.dp(al, op_mov, false, 0, s, immOp(0).?),
        }
        return s;
    }
    /// The word as the second operand of a data-processing instruction.
    fn op2(a: *Assembler, w: W, s: P) u32 {
        if (w == .zero) return immOp(0).?;
        return a.get(w, s);
    }
    /// Writes the word from the machine register `p`.
    fn put(a: *Assembler, w: W, p: P) void {
        switch (w) {
            .r => |q| a.movP(q, p),
            .m => |m| a.str(p, m.b, m.d),
            .zero => {},
        }
    }
    fn movW(a: *Assembler, d: W, s: W) void {
        if (d == .zero) return;
        a.put(d, a.get(s, target(d, S0)));
    }
    fn immW(a: *Assembler, d: W, v: u32) void {
        if (d == .zero) return;
        const t = target(d, S0);
        a.imm32(t, v);
        a.put(d, t);
    }
    /// Clears the high word of a register whose low word was just
    /// written.
    fn zeroHi(a: *Assembler, dst: Reg) void {
        a.immW(hi(dst), 0);
    }

    /// The machine register and the offset that reach the operand and
    /// the `span` bytes after it, with the offset inside `max`. The
    /// address goes through `s` when the base lives in the frame or the
    /// offset is too large.
    fn addr(a: *Assembler, m: Mem, span: i32, max: i32, s: P) struct { b: P, d: i32 } {
        const b = a.get(lo(m.base), s);
        if (m.disp >= -max and m.disp + span <= max and (max != 1020 or @mod(m.disp, 4) == 0)) return .{ .b = b, .d = m.disp };
        // The low bits stay in the offset when they fit with the span.
        var low: i32 = if (max == 1020) 0 else m.disp & max;
        if (low + span > max) low = 0;
        a.addP(s, b, m.disp - low);
        return .{ .b = s, .d = low };
    }

    // -----------------------------------------------------------------
    // Moves and immediates

    pub fn mov(a: *Assembler, dst: Reg, src: Reg) void {
        if (dst == src) return;
        a.movW(lo(dst), lo(src));
        a.movW(hi(dst), hi(src));
    }

    /// Loads a 64-bit constant, one word at a time. Ahead of time, the
    /// resolver decides whether a constant with a zero high word is an
    /// address, which then takes the form of `movImmReloc`.
    pub fn movImm(a: *Assembler, dst: Reg, v: u64) void {
        if (a.candidate64(v)) |r| return a.movImmReloc(dst, v, r);
        a.immW(lo(dst), @truncate(v));
        a.immW(hi(dst), @truncate(v >> 32));
    }
    /// Loads an address, or a value that `r` names as a literal. Ahead of
    /// time the low word of an address takes a form whose bytes the
    /// loader patches. Its high word is zero in every process.
    pub fn movImmReloc(a: *Assembler, dst: Reg, v: u64, r: reloc.Reloc) void {
        if (lo(dst) != .zero) {
            const t = target(lo(dst), S0);
            a.immNamed(t, @truncate(v), r);
            a.put(lo(dst), t);
        }
        a.immW(hi(dst), @truncate(v >> 32));
    }
    /// Stores an address, or a value that `r` names as a literal.
    pub fn storeImm64Reloc(a: *Assembler, m: Mem, v: u64, r: reloc.Reloc) void {
        if (!a.aot or r.kind == .literal) return a.storeImm64Raw(m, v);
        const ad = a.addr(m, 4, 4095, S2);
        a.immReloc(S0, @truncate(v), r);
        a.str(S0, ad.b, ad.d);
        a.imm32(S0, @truncate(v >> 32));
        a.str(S0, ad.b, ad.d + 4);
    }
    fn candidate64(a: *Assembler, v: u64) ?reloc.Reloc {
        return if (v >> 32 == 0) a.candidate(@truncate(v)) else null;
    }

    // -----------------------------------------------------------------
    // Memory

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        const ad = a.addr(m, 4, 4095, S2);
        const tl = target(lo(dst), S0);
        if (tl == ad.b) {
            // The low word of the register is the base, so it loads last.
            const th = target(hi(dst), S1);
            a.ldr(th, ad.b, ad.d + 4);
            a.put(hi(dst), th);
            a.ldr(tl, ad.b, ad.d);
            a.put(lo(dst), tl);
            return;
        }
        a.ldr(tl, ad.b, ad.d);
        a.put(lo(dst), tl);
        if (hi(dst) == .zero) return;
        const th = target(hi(dst), S0);
        a.ldr(th, ad.b, ad.d + 4);
        a.put(hi(dst), th);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        const ad = a.addr(m, 4, 4095, S2);
        a.str(a.get(lo(src), S0), ad.b, ad.d);
        a.str(a.get(hi(src), S0), ad.b, ad.d + 4);
    }

    // Words the size of a pointer, such as a pointer, a count, or a stack
    // index, which are 32 bits on this target (spec/design/platforms.md,
    // "32-bit ARM").
    pub const loadWord = load32;
    pub const storeWord = store32;
    pub const storePairWord = storePair32;
    /// Stores a constant the size of a pointer, which ahead of time may
    /// be an address, as the constant of `movImm` may.
    pub fn storeImmWord(a: *Assembler, m: Mem, v: u64) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.immAny(S0, @truncate(v));
        a.str(S0, ad.b, ad.d);
    }

    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 4095, S2);
        const t = target(lo(dst), S0);
        a.ldr(t, ad.b, ad.d);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.str(a.get(lo(src), S0), ad.b, ad.d);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 4095, S2);
        const t = target(lo(dst), S0);
        a.ldst(true, true, t, ad.b, ad.d);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.ldst(false, true, a.get(lo(src), S0), ad.b, ad.d);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 255, S2);
        const t = target(lo(dst), S0);
        a.ldsth(true, t, ad.b, ad.d);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        const ad = a.addr(m, 0, 255, S2);
        a.ldsth(false, a.get(lo(src), S0), ad.b, ad.d);
    }
    pub fn storeImm16(a: *Assembler, m: Mem, v: u16) void {
        const ad = a.addr(m, 0, 255, S2);
        a.imm32(S0, v);
        a.ldsth(false, S0, ad.b, ad.d);
    }
    /// Stores two 64-bit registers at `m` and `m + 8`.
    pub fn storePair64(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        const ad = a.addr(m, 12, 4095, S2);
        a.str(a.get(lo(first), S0), ad.b, ad.d);
        a.str(a.get(hi(first), S0), ad.b, ad.d + 4);
        a.str(a.get(lo(second), S0), ad.b, ad.d + 8);
        a.str(a.get(hi(second), S0), ad.b, ad.d + 12);
    }
    /// Stores the low halves of two registers at `m` and `m + 4`.
    pub fn storePair32(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        const ad = a.addr(m, 4, 4095, S2);
        a.str(a.get(lo(first), S0), ad.b, ad.d);
        a.str(a.get(lo(second), S0), ad.b, ad.d + 4);
    }
    /// A32 has no register that reads as zero.
    pub const zero_reg: ?Reg = null;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        const ad = a.addr(m, 0, 1020, S2);
        a.ldstf(true, dst, ad.b, ad.d);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        const ad = a.addr(m, 0, 1020, S2);
        a.ldstf(false, src, ad.b, ad.d);
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
    /// Stores a 64-bit constant. Ahead of time, the resolver decides
    /// whether a constant with a zero high word is an address.
    pub fn storeImm64(a: *Assembler, m: Mem, v: u64) void {
        if (a.candidate64(v)) |r| return a.storeImm64Reloc(m, v, r);
        a.storeImm64Raw(m, v);
    }
    fn storeImm64Raw(a: *Assembler, m: Mem, v: u64) void {
        const ad = a.addr(m, 4, 4095, S2);
        const low: u32 = @truncate(v);
        const high: u32 = @truncate(v >> 32);
        a.imm32(S0, low);
        a.str(S0, ad.b, ad.d);
        if (high != low) a.imm32(S0, high);
        a.str(S0, ad.b, ad.d + 4);
    }
    pub fn storeImm32(a: *Assembler, m: Mem, v: u32) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.imm32(S0, v);
        a.str(S0, ad.b, ad.d);
    }
    /// Prepares `zero16`, which may then run any number of times before
    /// the next copy or call.
    pub fn zeroPrepare(a: *Assembler) void {
        a.imm32(S0, 0);
        a.word(0xEC400B10 | @as(u32, S0) << 16 | @as(u32, S0) << 12 | fzero.n()); // vmov d12, ip, ip
    }
    /// Clears 16 bytes with two stores.
    pub fn zero16(a: *Assembler, m: Mem) void {
        const ad = a.addr(m, 8, 1020, S2);
        a.ldstf(false, fzero, ad.b, ad.d);
        a.ldstf(false, fzero, ad.b, ad.d + 8);
    }
    /// Copies 16 bytes a word at a time. A value is often written as
    /// words just before it is copied, so a load of a double would wait
    /// for those stores to leave the store buffer.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        a.copy(dst, src, 4);
    }
    fn copy(a: *Assembler, dst: Mem, src: Mem, words: i32) void {
        const from = a.addr(src, 4 * words - 4, 4095, S1);
        const to = a.addr(dst, 4 * words - 4, 4095, S2);
        var i: i32 = 0;
        while (i < words) : (i += 1) {
            a.ldr(S0, from.b, from.d + 4 * i);
            a.str(S0, to.b, to.d + 4 * i);
        }
    }
    /// dst = base + disp, as an address, whose high word is zero.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        const b = a.get(lo(m.base), S0);
        const t = target(lo(dst), S0);
        a.addP(t, b, m.disp);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }
    /// dst = b + (index << shift), as an address.
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.scaled(op_add, dst, b, index, shift);
    }
    /// dst = b - (index << shift), as an address.
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.scaled(op_sub, dst, b, index, shift);
    }
    fn scaled(a: *Assembler, op: u4, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        const x = a.get(lo(b), S0);
        const y = a.get(lo(index), S1);
        const t = target(lo(dst), S0);
        a.dp(al, op, false, x, t, @as(u32, shift) << 7 | y);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }

    // -----------------------------------------------------------------
    // Integer arithmetic. Each operation computes dst = dst op src.

    /// dst = x op y on both words. `high` is the opcode of the high
    /// word when it takes the carry of the low word.
    fn arith(a: *Assembler, low: u4, high: u4, dst: Reg, x: Reg, y: Reg) void {
        const wide = hi(dst) != .zero;
        {
            const p = a.get(lo(x), S0);
            const o = a.op2(lo(y), S1);
            const t = target(lo(dst), S0);
            a.dp(al, low, wide and low != high, p, t, o);
            a.put(lo(dst), t);
        }
        if (wide) {
            const p = a.get(hi(x), S0);
            const o = a.op2(hi(y), S1);
            const t = target(hi(dst), S0);
            a.dp(al, high, false, p, t, o);
            a.put(hi(dst), t);
        }
    }

    pub fn add(a: *Assembler, dst: Reg, src: Reg) void {
        a.arith(op_add, op_adc, dst, dst, src);
    }
    pub fn sub(a: *Assembler, dst: Reg, src: Reg) void {
        a.arith(op_sub, op_sbc, dst, dst, src);
    }
    pub fn mul(a: *Assembler, dst: Reg, src: Reg) void {
        a.mul3(dst, dst, src);
    }
    pub fn @"and"(a: *Assembler, dst: Reg, src: Reg) void {
        a.arith(op_and, op_and, dst, dst, src);
    }
    pub fn @"or"(a: *Assembler, dst: Reg, src: Reg) void {
        a.arith(op_orr, op_orr, dst, dst, src);
    }
    pub fn xor(a: *Assembler, dst: Reg, src: Reg) void {
        a.arith(op_eor, op_eor, dst, dst, src);
    }
    pub fn neg(a: *Assembler, dst: Reg) void {
        const wide = hi(dst) != .zero;
        const p = a.get(lo(dst), S0);
        a.dp(al, op_rsb, wide, p, p, immOp(0).?);
        a.put(lo(dst), p);
        if (!wide) return;
        const q = a.get(hi(dst), S0);
        a.dp(al, op_rsc, false, q, q, immOp(0).?);
        a.put(hi(dst), q);
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        const p = a.get(lo(dst), S0);
        a.dp(al, op_mvn, false, 0, p, p);
        a.put(lo(dst), p);
        if (hi(dst) == .zero) return;
        const q = a.get(hi(dst), S0);
        a.dp(al, op_mvn, false, 0, q, q);
        a.put(hi(dst), q);
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        if (v == 0) return;
        a.addImm3(dst, dst, v);
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        if (v == 0) return a.mov(dst, x);
        const wide = hi(dst) != .zero;
        const mag: u32 = @abs(v);
        {
            const p = a.get(lo(x), S0);
            const o = immOp(mag) orelse blk: {
                a.imm32(S1, mag);
                break :blk @as(u32, S1);
            };
            const t = target(lo(dst), S0);
            a.dp(al, if (v > 0) op_add else op_sub, wide, p, t, o);
            a.put(lo(dst), t);
        }
        if (wide) {
            const p = a.get(hi(x), S0);
            const t = target(hi(dst), S0);
            a.dp(al, if (v > 0) op_adc else op_sbc, false, p, t, immOp(0).?);
            a.put(hi(dst), t);
        }
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        a.rtEnter();
        // The routine writes the remainder into the two words above the
        // address that it takes as its third argument on the stack.
        a.addP(sp_r, sp_r, -16);
        a.addP(S0, sp_r, 8);
        a.str(S0, sp_r, 0);
        a.rtArg(r0, lo(x), 16);
        a.rtArg(r1, hi(x), 16);
        a.rtArg(r2, lo(y), 16);
        a.rtArg(r3, hi(y), 16);
        a.immAny(S0, addrOf(&rt.divRem));
        a.blx(S0);
        a.rtResult(lo(quot), r0, 16);
        a.rtResult(hi(quot), r1, 16);
        a.ldr(S0, sp_r, 8);
        a.rtResult(lo(rem), S0, 16);
        a.ldr(S0, sp_r, 12);
        a.rtResult(hi(rem), S0, 16);
        a.addP(sp_r, sp_r, 16);
        a.rtLeave();
    }

    // A call of a routine of this file from inside one operation of the
    // interface. Such an operation keeps every register that it does not
    // name, so the call saves the registers that the convention lets a
    // routine clobber: r0 to r3 and d0 to d7. An operand that lives in
    // one of them is read from where it was saved. A result that lives
    // in one of them is written there, so that the restore loads it.

    /// Bytes that `rtEnter` pushes below the saved r0 to r3.
    const rt_floats = 64;

    fn rtEnter(a: *Assembler) void {
        a.push(0x000F);
        a.vpush(.d0, 8);
    }
    fn rtLeave(a: *Assembler) void {
        a.vpop(.d0, 8);
        a.pop(0x000F);
    }
    /// Loads the word `w` into the argument register `to`, with `extra`
    /// bytes pushed since `rtEnter`.
    fn rtArg(a: *Assembler, to: P, w: W, extra: i32) void {
        switch (w) {
            .r => |p| if (p < 4) a.ldr(to, sp_r, rt_floats + extra + 4 * @as(i32, p)) else a.movP(to, p),
            .m => |m| a.ldr(to, m.b, m.d),
            .zero => a.imm32(to, 0),
        }
    }
    /// Writes the word `w` from `p` after the call.
    fn rtResult(a: *Assembler, w: W, p: P, extra: i32) void {
        switch (w) {
            .r => |q| if (q < 4) a.str(p, sp_r, rt_floats + extra + 4 * @as(i32, q)) else a.movP(q, p),
            .m => |m| a.str(p, m.b, m.d),
            .zero => {},
        }
    }

    // -----------------------------------------------------------------
    // Floats

    fn f3(a: *Assembler, opcode: u32, dst: FReg, x: FReg, y: FReg) void {
        a.word(opcode | x.n() << 16 | dst.n() << 12 | y.n());
    }
    fn f2(a: *Assembler, opcode: u32, dst: FReg, src: FReg) void {
        a.word(opcode | dst.n() << 12 | src.n());
    }

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
    /// Converts a signed integer to a float. VFP converts 32-bit
    /// integers, so the result is the unsigned low word plus the signed
    /// high word times 2^32. The low float and the product are exact,
    /// so the one addition rounds as a direct conversion does.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        const low = a.get(lo(src), S0);
        a.word(0xEE000A10 | dst.n() << 16 | @as(u32, low) << 12); // vmov s(2 dst), low
        a.f2(0xEEB80B40, dst, dst); // vcvt.f64.u32 dst, s(2 dst)
        if (hi(src) == .zero) return;
        const high = a.get(hi(src), S0);
        a.word(0xEE000A10 | fs0.n() << 16 | @as(u32, high) << 12);
        a.f2(0xEEB80BC0, fs0, fs0); // vcvt.f64.s32
        a.fmovImm(fs1, 0x41F0_0000_0000_0000);
        a.f3(0xEE000B00, dst, fs0, fs1); // vmla dst, fs0, fs1
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        const low = a.get(lo(src), S0);
        const high = a.get(hi(src), S1);
        a.word(0xEC400B10 | @as(u32, high) << 16 | @as(u32, low) << 12 | dst.n());
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        const low = target(lo(dst), S0);
        const high = target(hi(dst), S1);
        a.word(0xEC500B10 | @as(u32, high) << 16 | @as(u32, low) << 12 | src.n());
        a.put(lo(dst), low);
        a.put(hi(dst), high);
    }

    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.f2(0xEEB00B40, dst, src);
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.f2(0xEEB10B40, dst, src);
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.f2(0xEEB00BC0, dst, src);
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.f2(0xEEB10BC0, dst, src);
    }
    /// VFPv3 rounds only to the nearest integer and toward zero.
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
        a.rtEnter();
        a.word(0xEC500B10 | @as(u32, r1) << 16 | @as(u32, r0) << 12 | src.n()); // vmov r0, r1, src
        a.immAny(S0, addrOf(&rt.floatToInt));
        a.blx(S0);
        a.rtResult(lo(dst), r0, 0);
        a.rtResult(hi(dst), r1, 0);
        a.rtLeave();
    }

    // Three-operand forms: dst = x op y.
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.arith(op_add, op_adc, dst, x, y);
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.arith(op_sub, op_sbc, dst, x, y);
    }
    /// The low word of the product is the low word of `umull`. Its high
    /// word plus the two cross products is the high word.
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        if (hi(dst) == .zero) {
            const p = a.get(lo(x), S0);
            const q = a.get(lo(y), S1);
            const t = target(lo(dst), S0);
            a.word(0xE0000090 | @as(u32, t) << 16 | @as(u32, q) << 8 | p);
            return a.put(lo(dst), t);
        }
        var cross = false;
        if (hi(y) != .zero) {
            const p = a.get(lo(x), S0);
            const q = a.get(hi(y), S1);
            a.word(0xE0000090 | @as(u32, S2) << 16 | @as(u32, q) << 8 | p); // mul S2, p, q
            cross = true;
        }
        if (hi(x) != .zero) {
            const p = a.get(hi(x), S0);
            const q = a.get(lo(y), S1);
            if (cross) {
                a.word(0xE0200090 | @as(u32, S2) << 16 | @as(u32, S2) << 12 | @as(u32, q) << 8 | p); // mla S2, p, q, S2
            } else a.word(0xE0000090 | @as(u32, S2) << 16 | @as(u32, q) << 8 | p);
            cross = true;
        }
        const p = a.get(lo(x), S0);
        const q = a.get(lo(y), S1);
        const tl = target(lo(dst), S0);
        const th = target(hi(dst), S1);
        a.word(0xE0800090 | @as(u32, th) << 16 | @as(u32, tl) << 12 | @as(u32, q) << 8 | p); // umull tl, th, p, q
        if (cross) a.dp(al, op_add, false, th, th, S2);
        a.put(lo(dst), tl);
        a.put(hi(dst), th);
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.arith(op_and, op_and, dst, x, y);
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.arith(op_orr, op_orr, dst, x, y);
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.arith(op_eor, op_eor, dst, x, y);
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.f3(0xEE300B00, dst, x, y);
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.f3(0xEE300B40, dst, x, y);
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.f3(0xEE200B00, dst, x, y);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.f3(0xEE800B00, dst, x, y);
    }
    /// Loads and stores of the 64-bit word at [b + index * 8].
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        const x = a.get(lo(b), S0);
        const y = a.get(lo(index), S1);
        a.dp(al, op_add, false, x, S2, @as(u32, 3) << 7 | y);
        const tl = target(lo(dst), S0);
        a.ldr(tl, S2, 0);
        a.put(lo(dst), tl);
        if (hi(dst) == .zero) return;
        const th = target(hi(dst), S0);
        a.ldr(th, S2, 4);
        a.put(hi(dst), th);
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        const x = a.get(lo(b), S0);
        const y = a.get(lo(index), S1);
        a.dp(al, op_add, false, x, S2, @as(u32, 3) << 7 | y);
        a.str(a.get(lo(src), S0), S2, 0);
        a.str(a.get(hi(src), S0), S2, 4);
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. The routine
    /// that divides needs neither `tmp` nor `tmp2`.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        _ = tmp;
        _ = tmp2;
        a.rtEnter();
        a.rtArg(r0, lo(x), 0);
        a.rtArg(r1, hi(x), 0);
        a.rtArg(r2, lo(y), 0);
        a.rtArg(r3, hi(y), 0);
        a.immAny(S0, if (mod) addrOf(&rt.floorMod) else addrOf(&rt.floorDiv));
        a.blx(S0);
        a.rtResult(lo(dst), r0, 0);
        a.rtResult(hi(dst), r1, 0);
        a.rtLeave();
    }
    /// Copies one 64-bit word.
    pub fn copy8(a: *Assembler, dst: Mem, src: Mem) void {
        a.copy(dst, src, 2);
    }
    /// Loads a float constant from its bits.
    pub fn fmovImm(a: *Assembler, dst: FReg, bits: u64) void {
        const low: u32 = @truncate(bits);
        const high: u32 = @truncate(bits >> 32);
        a.imm32(S0, low);
        if (high != low) a.imm32(S1, high);
        a.word(0xEC400B10 | @as(u32, if (high != low) S1 else S0) << 16 | @as(u32, S0) << 12 | dst.n());
    }
    /// The address of the native stack pointer plus `disp`.
    pub fn leaSp(a: *Assembler, dst: Reg, disp: i32) void {
        a.lea(dst, .{ .base = .sp, .disp = disp });
    }
    /// Moves the native stack pointer by `v` bytes.
    pub fn moveSp(a: *Assembler, v: i32) void {
        if (v != 0) a.addP(sp_r, sp_r, v);
    }

    // -----------------------------------------------------------------
    // Control flow

    pub fn jmp(a: *Assembler, l: Label) void {
        a.branch(al, l);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.bx(a.get(lo(r), S0));
    }

    /// Branches when the words of x compare as `c` with the words of y.
    /// An unsigned comparison or an equality compares the high words,
    /// and the low words when those are equal. A signed comparison
    /// subtracts both words and reads the sign of the difference.
    fn compare(a: *Assembler, c: Cond, xl: W, xh: W, yl: Y, yh: Y, l: Label) void {
        switch (c) {
            .eq, .ne, .hs, .lo, .hi, .ls => {
                const narrow = xh == .zero and yh.isZero();
                if (!narrow) {
                    const p = a.get(xh, S0);
                    a.cmpP(al, p, a.yOp2(yh, S1));
                }
                const p = a.get(xl, S0);
                a.cmpP(if (narrow) al else cc_eq, p, a.yOp2(yl, S1));
            },
            .lt, .ge => {
                if (yl.isZero() and yh.isZero()) {
                    // The sign of the high word decides.
                    a.cmpP(al, a.get(xh, S0), immOp(0).?);
                } else {
                    const p = a.get(xl, S0);
                    a.cmpP(al, p, a.yOp2(yl, S1));
                    const q = a.get(xh, S0);
                    a.dp(al, op_sbc, true, q, S0, a.yOp2(yh, S1));
                }
            },
            .gt, .le => {
                // x > y exactly when y < x.
                const p = a.yGet(yl, S0);
                a.cmpP(al, p, a.op2(xl, S1));
                const q = a.yGet(yh, S0);
                a.dp(al, op_sbc, true, q, S0, a.op2(xh, S1));
                return a.branch(if (c == .gt) cc_lt else cc_ge, l);
            },
        }
        a.branch(@backingInt(c), l);
    }
    fn yOp2(a: *Assembler, y: Y, s: P) u32 {
        switch (y) {
            .w => |w| return a.op2(w, s),
            .imm => |v| {
                if (immOp(v)) |o| return o;
                a.imm32(s, v);
                return s;
            },
        }
    }
    fn yGet(a: *Assembler, y: Y, s: P) P {
        switch (y) {
            .w => |w| return a.get(w, s),
            .imm => |v| {
                a.imm32(s, v);
                return s;
            },
        }
    }

    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        a.compare(c, lo(x), hi(x), .{ .w = lo(y) }, .{ .w = hi(y) }, l);
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (v == 0 and (c == .eq or c == .ne) and hi(x) != .zero) {
            // Both words are zero exactly when their union is.
            const p = a.get(lo(x), S0);
            const q = a.get(hi(x), S1);
            a.dp(al, op_orr, true, p, S0, q);
            return a.branch(@backingInt(c), l);
        }
        a.compare(c, lo(x), hi(x), .{ .imm = @bitCast(v) }, .{ .imm = if (v < 0) 0xFFFF_FFFF else 0 }, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.cmpP(al, a.get(lo(x), S0), immOp(0).?);
        a.branch(if (zero) cc_eq else cc_ne, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.ldst(true, true, S0, ad.b, ad.d);
        a.cmpP(al, S0, immOp(v).?);
        a.branch(@backingInt(c), l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.ldst(true, true, S0, ad.b, ad.d);
        a.dp(al, op_tst, true, S0, 0, immOp(@as(u32, 1) << bit).?);
        a.branch(if (set) cc_ne else cc_eq, l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        a.f2(0xEEB40B40, x, y); // vcmp.f64 x, y
        a.word(0xEEF1FA10); // vmrs APSR_nzcv, fpscr
        a.branch(switch (c) {
            .lt => cc_mi,
            .le => cc_ls,
            .eq => cc_eq,
            .nlt => cc_pl,
            .nle => cc_hi,
            .ne => cc_ne,
        }, l);
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        const ad = a.addr(m, 4, 4095, S2);
        a.compare(c, lo(x), hi(x), .{ .w = .{ .m = .{ .b = ad.b, .d = ad.d } } }, .{ .w = .{ .m = .{ .b = ad.b, .d = ad.d + 4 } } }, l);
    }
    /// Branches when the register compares as `c` with a word in memory
    /// the size of a pointer.
    pub fn jumpIfMemWord(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        const ad = a.addr(m, 0, 4095, S2);
        a.compare(c, lo(x), hi(x), .{ .w = .{ .m = .{ .b = ad.b, .d = ad.d } } }, .{ .w = .zero }, l);
    }

    // Calls of the runtime follow AAPCS. The stack pointer is a multiple
    // of eight at every call: the entry sequence leaves it so, the code
    // generator moves it by multiples of sixteen, and the arguments that
    // travel on the stack take eight or sixteen bytes.

    /// Calls a function at an absolute address whose arguments are
    /// words. The low words of the first four arguments are in r0 to r3
    /// already. The low word of the fifth travels on the stack. The
    /// result is a word in r0.
    pub fn call(a: *Assembler, address: usize) void {
        a.callNamed(address, null);
    }
    /// Loads the address of a routine: the one that `r` names, or one
    /// that the resolver names ahead of time.
    fn routine(a: *Assembler, address: u64, r: ?reloc.Reloc) void {
        if (r) |x| return a.immNamed(S0, @truncate(address), x);
        a.immAny(S0, @truncate(address));
    }
    fn callNamed(a: *Assembler, address: usize, r: ?reloc.Reloc) void {
        const fifth = a.get(lo(args[4]), S0);
        a.word(0xE52D0008 | @as(u32, fifth) << 12); // str fifth, [sp, #-8]!
        a.routine(address, r);
        a.blx(S0);
        a.addP(sp_r, sp_r, 8);
        a.zeroHi(ret0);
    }
    /// Calls a routine whose arguments and result are all 64-bit
    /// integers. The first argument travels in r0 and r1, the second in
    /// r2 and r3, and the third and fourth on the stack. The result
    /// comes back in r0 and r1.
    pub fn callWide(a: *Assembler, address: u64) void {
        a.callWideNamed(address, null);
    }
    fn callWideNamed(a: *Assembler, address: u64, r: ?reloc.Reloc) void {
        a.addP(sp_r, sp_r, -16);
        a.str(a.get(lo(args[2]), S0), sp_r, 0);
        a.str(a.get(hi(args[2]), S0), sp_r, 4);
        a.str(a.get(lo(args[3]), S0), sp_r, 8);
        a.str(a.get(hi(args[3]), S0), sp_r, 12);
        a.movP(r2, a.get(lo(args[1]), r2));
        a.movP(r3, a.get(hi(args[1]), r3));
        a.movP(r1, a.get(hi(args[0]), r1));
        a.routine(address, r);
        a.blx(S0);
        a.addP(sp_r, sp_r, 16);
        a.put(hi(ret0), r1);
    }
    /// Calls a routine that returns two words, such as `jit.Target`.
    /// AAPCS returns them through memory whose address the caller passes
    /// in r0, so the four word arguments move up by one, the last of
    /// them onto the stack, and the two words load into the result
    /// registers afterwards.
    pub fn callPair(a: *Assembler, address: usize) void {
        a.callPairNamed(address, null);
    }
    fn callPairNamed(a: *Assembler, address: usize, r: ?reloc.Reloc) void {
        a.word(0xE52D0008 | @as(u32, r3) << 12); // str r3, [sp, #-8]!
        a.movP(r3, r2);
        a.movP(r2, r1);
        a.movP(r1, r0);
        a.addP(r0, fp, slot_pair);
        a.routine(address, r);
        a.blx(S0);
        a.addP(sp_r, sp_r, 8);
        a.ldr(r0, fp, slot_pair);
        a.ldr(r1, fp, slot_pair + 4);
        a.imm32(S0, 0);
        a.str(S0, fp, slot_t4_hi);
        a.str(S0, fp, slot_t3_hi);
    }
    /// Calls the routine that `r` names, at `address` in this process.
    pub fn callReloc(a: *Assembler, address: usize, r: reloc.Reloc) void {
        a.callNamed(address, r);
    }
    /// `callWide` for the routine that `r` names.
    pub fn callWideReloc(a: *Assembler, address: u64, r: reloc.Reloc) void {
        a.callWideNamed(address, r);
    }
    /// `callPair` for the routine that `r` names.
    pub fn callPairReloc(a: *Assembler, address: usize, r: reloc.Reloc) void {
        a.callPairNamed(address, r);
    }

    // A local call stores its return address in the frame of the entry
    // sequence, where the routine it calls finds it whatever it runs in
    // between.

    /// Stores the address of the instruction after the branch that
    /// follows.
    fn link(a: *Assembler) void {
        a.dp(al, op_add, false, pc, S1, immOp(4).?); // add lr, pc, #4
        a.str(S1, fp, slot_link);
    }
    /// Calls a routine in the same code.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.link();
        a.branch(al, l);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        const p = a.get(lo(r), S0);
        a.link();
        a.bx(p);
    }
    /// Returns from a routine that made no local call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.ldr(pc, fp, slot_link);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        const t = target(lo(dst), S0);
        a.ldr(t, fp, slot_link);
        a.addP(t, t, 4);
        a.put(lo(dst), t);
        a.zeroHi(dst);
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        _ = a;
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.addP(sp_r, sp_r, -size);
        const ad = a.addr(.{ .base = .sp, .disp = size - 8 }, 0, 4095, S2);
        a.ldr(S0, fp, slot_link);
        a.str(S0, ad.b, ad.d);
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        const ad = a.addr(.{ .base = .sp, .disp = size - 8 }, 0, 4095, S2);
        a.ldr(S0, ad.b, ad.d);
        a.str(S0, fp, slot_link);
        a.addP(sp_r, sp_r, size);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        const ad = a.addr(.{ .base = .sp, .disp = size - 8 }, 0, 4095, S2);
        a.ldr(S0, ad.b, ad.d);
        a.addP(sp_r, sp_r, size);
        a.bx(S0);
    }
    /// Sets the native stack pointer.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.movP(sp_r, a.get(lo(src), S0));
    }
    pub fn trap(a: *Assembler) void {
        a.word(0xE7F000F0); // udf #0
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the registers that belong to its caller, opens the frame
    /// that holds the registers without a machine register, and loads
    /// the pinned registers. Ten words and five doubles keep the stack
    /// pointer a multiple of eight.
    pub fn prologue(a: *Assembler) void {
        a.push(0x4FF8); // push {r3-r11, lr}
        a.vpush(.d8, 5); // vpush {d8-d12}
        a.addP(sp_r, sp_r, -frame_size);
        a.movP(fp, sp_r);
        a.movP(4, r0);
        a.str(r1, fp, slot_stop);
        a.str(r3, fp, slot_base);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        a.addP(sp_r, fp, frame_size);
        a.vpop(.d8, 5);
        a.pop(0x8FF8); // pop {r3-r11, pc}
    }
};

comptime {
    std.debug.assert(frame_size % 8 == 0 and home(.v5) + 8 == frame_size);
    // The calls read the arguments from these places.
    std.debug.assert(lo(args[0]).r == r0 and lo(args[1]).r == r1 and lo(args[2]).r == r2 and lo(args[3]).r == r3);
    std.debug.assert(ret0 == args[0] and ret1 == args[1]);
}

fn expectWords(a: *Assembler, expected: []const u32) !void {
    const got = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |w, i| try std.testing.expectEqual(w, std.mem.littleToNative(u32, got[i]));
}

test "arm moves and immediates" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.t0, .t1); // mov r6, r3; mov r7, r8
    a.mov(.t4, .thread); // mov r0, r4; mov ip, #0; str ip, [fp, #28]
    a.mov(.base, .t3); // str r1, [fp]
    a.movImm(.t0, 0x1_0000_1234); // movw r6, #0x1234; mov r7, #1
    a.movImm(.t5, 0xFFFF_FFFF_FFFF_FFFE); // mvn ip, #1; str ip, [fp, #32]; mvn ip, #0; str ip, [fp, #36]
    a.movImm(.t1, 0x12345678); // movw r3, #0x5678; movt r3, #0x1234; mov r8, #0
    try expectWords(&a, &.{
        0xE1A06003, 0xE1A07008, 0xE1A00004, 0xE3A0C000, 0xE58BC01C, 0xE58B1000, 0xE3016234, 0xE3A07001,
        0xE3E0C001, 0xE58BC020, 0xE3E0C000, 0xE58BC024, 0xE3053678, 0xE3413234, 0xE3A08000,
    });
}

test "arm writes an address as a pair that the loader patches" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.aot = true;
    const r: reloc.Reloc = .{ .kind = .routine, .a = 3 };
    a.movImmReloc(.t0, 0xFF00, r); // movw r6, #0xff00; movt r6, #0; mov r7, #0
    a.movImmReloc(.t0, 0x12345678, .literal); // movw r6, #0x5678; movt r6, #0x1234; mov r7, #0
    a.movImmReloc(.t5, 0x12345678, r); // movw ip, #0x5678; movt ip, #0x1234; str ip, [fp, #32]; mov ip, #0; str ip, [fp, #36]
    try expectWords(&a, &.{
        0xE30F6F00, 0xE3406000, 0xE3A07000, 0xE3056678, 0xE3416234, 0xE3A07000,
        0xE305C678, 0xE341C234, 0xE58BC020, 0xE3A0C000, 0xE58BC024,
    });
    try std.testing.expectEqual(@as(usize, 2), a.relocs.items.len);
    try std.testing.expectEqual(@as(u32, 0), a.relocs.items[0].at);
    try std.testing.expectEqual(@as(u32, 24), a.relocs.items[1].at);
    try std.testing.expectEqual(reloc.Form.arm_pair, a.relocs.items[1].form);
    reloc.apply(a.buf.items, a.relocs.items[1], 0xABCD0123);
    const got = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0xE300C123), std.mem.littleToNative(u32, got[6]));
    try std.testing.expectEqual(@as(u32, 0xE34ACBCD), std.mem.littleToNative(u32, got[7]));
}

test "arm asks the resolver about every word that may be an address" {
    const Names = struct {
        /// Names one address, calls one value unknown, and calls every
        /// other value a literal.
        fn resolve(_: *anyopaque, v: u64) reloc.Resolution {
            if (v == 0x20000) return .{ .address = .{ .kind = .global, .a = 8 } };
            if (v == 0x30000) return .unknown;
            return .literal;
        }
    };
    var ctx: u8 = 0;
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.aot = true;
    a.resolver = .{ .ctx = &ctx, .resolve = Names.resolve };
    const l = a.newLabel();
    a.bind(l);
    a.movImm(.t0, 0x20000);
    a.storeImm64(.{ .base = .bp, .disp = 0 }, 0x20000);
    a.storeImmWord(.{ .base = .bp, .disp = 0 }, 0x20000);
    a.call(0x20000);
    a.callWide(0x20000);
    a.callPair(0x20000);
    try std.testing.expectEqual(@as(usize, 6), a.relocs.items.len);
    try std.testing.expectEqual(@as(u32, 0), a.unrelocated);
    for (a.relocs.items) |e| {
        try std.testing.expectEqual(reloc.Form.arm_pair, e.form);
        try std.testing.expectEqual(reloc.Kind.global, e.r.kind);
        const w = std.mem.bytesAsSlice(u32, a.buf.items)[e.at / 4 ..];
        // movw and movt of the same register.
        try std.testing.expectEqual(@as(u32, 0xE3000000), std.mem.littleToNative(u32, w[0]) & 0xFFF00FFF);
        try std.testing.expectEqual(@as(u32, 0xE3400002), std.mem.littleToNative(u32, w[1]) & 0xFFF00FFF);
    }
    // A literal, a value with a high word, a small value, a value that
    // the caller names a literal, and the 32-bit integers of the
    // interface build in place.
    a.movImm(.t0, 0x40000);
    a.movImm(.t0, 0x1_0002_0000);
    a.movImm(.t0, 0xFFFF);
    a.movImmReloc(.t0, 0x30000, .literal);
    a.storeImm64Reloc(.{ .base = .bp, .disp = 0 }, 0x30000, .literal);
    a.storeImm32(.{ .base = .bp, .disp = 0 }, 0x30000);
    a.addImm3(.t0, .t1, 0x30000);
    a.jumpIfImm(.eq, .t0, 0x30000, l);
    try std.testing.expectEqual(@as(usize, 6), a.relocs.items.len);
    try std.testing.expectEqual(@as(u32, 0), a.unrelocated);
    a.movImm(.t0, 0x30000);
    a.storeImm64(.{ .base = .bp, .disp = 0 }, 0x30000);
    try std.testing.expectEqual(@as(u32, 2), a.unrelocated);
    try std.testing.expect(a.finish());
}

test "arm compiles for the running process as before when nothing is ahead of time" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    var b = Assembler.init(std.testing.allocator);
    defer b.deinit();
    const r: reloc.Reloc = .{ .kind = .routine, .a = 3 };
    a.movImm(.t0, 0x20000);
    b.movImmReloc(.t0, 0x20000, r);
    a.storeImm64(.{ .base = .bp, .disp = 8 }, 0x20000);
    b.storeImm64Reloc(.{ .base = .bp, .disp = 8 }, 0x20000, r);
    a.call(0x20000);
    b.callReloc(0x20000, r);
    a.callWide(0x20000);
    b.callWideReloc(0x20000, r);
    a.callPair(0x20000);
    b.callPairReloc(0x20000, r);
    try std.testing.expectEqualSlices(u8, a.buf.items, b.buf.items);
    try std.testing.expectEqual(@as(usize, 0), b.relocs.items.len);
    // mov r6, #0x20000; mov r7, #0
    try std.testing.expectEqual(@as(u32, 0xE3A06802), std.mem.littleToNative(u32, std.mem.bytesAsSlice(u32, a.buf.items)[0]));
}

test "arm memory forms" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load64(.t0, .{ .base = .bp, .disp = 16 }); // ldr r6, [r5, #16]; ldr r7, [r5, #20]
    a.load64(.t0, .{ .base = .t0, .disp = 8 }); // ldr r7, [r6, #12]; ldr r6, [r6, #8]
    a.store64(.t1, .{ .base = .bp, .disp = -16 }); // str r3, [r5, #-16]; str r8, [r5, #-12]
    a.load32(.t3, .{ .base = .thread, .disp = 4 }); // ldr r1, [r4, #4]; mov ip, #0; str ip, [fp, #24]
    a.load8(.t0, .{ .base = .bp, .disp = 8 }); // ldrb r6, [r5, #8]; mov r7, #0
    a.load16(.t1, .{ .base = .t1 }); // ldrh r3, [r3]; mov r8, #0
    a.loadF(.d0, .{ .base = .bp, .disp = 32 }); // vldr d0, [r5, #32]
    a.storeF(.d1, .{ .base = .bp, .disp = 4096 }); // add r10, r5, #4096; vstr d1, [r10]
    a.copy8(.{ .base = .bp, .disp = 32 }, .{ .base = .bp, .disp = 48 }); // ldr ip, [r5, #48]; str ip, [r5, #32]; ldr ip, [r5, #52]; str ip, [r5, #36]
    a.storeImm64(.{ .base = .bp, .disp = 8 }, 3); // mov ip, #3; str ip, [r5, #8]; mov ip, #0; str ip, [r5, #12]
    a.zeroPrepare(); // mov ip, #0; vmov d12, ip, ip
    a.zero16(.{ .base = .bp, .disp = 16 }); // vstr d12, [r5, #16]; vstr d12, [r5, #24]
    try expectWords(&a, &.{
        0xE5956010, 0xE5957014, 0xE596700C, 0xE5966008, 0xE5053010, 0xE505800C, 0xE5941004, 0xE3A0C000,
        0xE58BC018, 0xE5D56008, 0xE3A07000, 0xE1D330B0, 0xE3A08000, 0xED950B08, 0xE285AA01, 0xED8A1B00,
        0xE595C030, 0xE585C020, 0xE595C034, 0xE585C024, 0xE3A0C003, 0xE585C008, 0xE3A0C000, 0xE585C00C,
        0xE3A0C000, 0xEC4CCB1C, 0xED85CB04, 0xED85CB06,
    });
}

test "arm offsets beyond the reach of a load go through a scratch register" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load16(.t0, .{ .base = .bp, .disp = 300 }); // add r10, r5, #256; ldrh r6, [r10, #44]; mov r7, #0
    a.load64(.t1, .{ .base = .thread, .disp = -5000 }); // sub r10, r4, #8192; ldr r3, [r10, #3192]; ldr r8, [r10, #3196]
    a.loadF(.d2, .{ .base = .bp, .disp = 6 }); // add r10, r5, #6; vldr d2, [r10]
    a.moveSp(-4104); // sub sp, sp, #8; sub sp, sp, #4096
    try expectWords(&a, &.{
        0xE285AC01, 0xE1DA62BC, 0xE3A07000, 0xE244AA02, 0xE59A3C78, 0xE59A8C7C, 0xE285A006, 0xED9A2B00,
        0xE24DD008, 0xE24DDA01,
    });
}

test "arm arithmetic on pairs and on words of the frame" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.add(.t0, .t1); // adds r6, r6, r3; adc r7, r7, r8
    a.sub(.t0, .t1); // subs r6, r6, r3; sbc r7, r7, r8
    a.mul(.t0, .t1); // mul r10, r6, r8; mla r10, r7, r3, r10; umull r6, r7, r6, r3; add r7, r7, r10
    a.addImm(.t0, -1); // subs r6, r6, #1; sbc r7, r7, #0
    a.addImm(.t5, 5); // ldr ip, [fp, #32]; adds ip, ip, #5; str ip, [fp, #32]; ldr ip, [fp, #36]; adc ip, ip, #0; str ip, [fp, #36]
    a.neg(.t0); // rsbs r6, r6, #0; rsc r7, r7, #0
    a.not(.t0); // mvn r6, r6; mvn r7, r7
    a.addScaled(.bp, .bp, .base, 4); // ldr lr, [fp]; add r5, r5, lr, lsl #4
    a.lea(.t4, .{ .base = .base, .disp = 3 }); // ldr ip, [fp]; add r0, ip, #3; mov ip, #0; str ip, [fp, #28]
    try expectWords(&a, &.{
        0xE0966003, 0xE0A77008, 0xE0566003, 0xE0C77008, 0xE00A0896, 0xE02AA397, 0xE0876396, 0xE087700A,
        0xE2566001, 0xE2C77000, 0xE59BC020, 0xE29CC005, 0xE58BC020, 0xE59BC024, 0xE2ACC000, 0xE58BC024,
        0xE2766000, 0xE2E77000, 0xE1E06006, 0xE1E07007, 0xE59BE000, 0xE085520E, 0xE59BC000, 0xE28C0003,
        0xE3A0C000, 0xE58BC01C,
    });
}

test "arm floats" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.fadd(.d0, .d1); // vadd.f64 d0, d0, d1
    // vmov s0, r6; vcvt.f64.u32 d0, s0; vmov s20, r7; vcvt.f64.s32 d10, s20
    // mov ip, #0; movw lr, #0; movt lr, #0x41f0; vmov d11, ip, lr; vmla.f64 d0, d10, d11
    a.intToFloat(.d0, .t0);
    a.bitsToFloat(.d1, .t0); // vmov d1, r6, r7
    a.floatToBits(.t0, .d1); // vmov r6, r7, d1
    try expectWords(&a, &.{
        0xEE300B01, 0xEE006A10, 0xEEB80B40, 0xEE0A7A10, 0xEEB8ABCA, 0xE3A0C000, 0xE300E000, 0xE344E1F0,
        0xEC4ECB1B, 0xEE0A0B0B, 0xEC476B11, 0xEC576B11,
    });
}

test "arm comparisons of both words" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l = a.newLabel();
    a.bind(l);
    a.jumpIf(.lt, .t0, .t1, l); // cmp r6, r3; sbcs ip, r7, r8; blt
    a.jumpIf(.hs, .t0, .t1, l); // cmp r7, r8; cmpeq r6, r3; bhs
    a.jumpIf(.gt, .t0, .t1, l); // cmp r3, r6; sbcs ip, r8, r7; blt
    a.jumpIfImm(.eq, .t0, 0, l); // orrs ip, r6, r7; beq
    a.jumpIfImm(.hi, .t4, 2, l); // ldr ip, [fp, #28]; cmp ip, #0; cmpeq r0, #2; bhi
    a.jumpIfImm(.ge, .t0, 0, l); // cmp r7, #0; bge
    a.jumpIfImm(.le, .t0, 7, l); // mov ip, #7; cmp ip, r6; mov ip, #0; sbcs ip, ip, r7; bge
    a.jumpIfByte(.ne, .{ .base = .bp, .disp = 8 }, 3, l); // ldrb ip, [r5, #8]; cmp ip, #3; bne
    a.jumpIfBit(.{ .base = .t0, .disp = 5 }, 2, true, l); // ldrb ip, [r6, #5]; tst ip, #4; bne
    a.jumpIfFloat(.lt, .d0, .d1, l); // vcmp.f64 d0, d1; vmrs APSR_nzcv, fpscr; bmi
    a.jumpIfMemWord(.eq, .t1, .{ .base = .thread, .disp = 8 }, l); // cmp r8, #0; ldr lr, [r4, #8]; cmpeq r3, lr; beq
    a.jmp(l); // b
    try std.testing.expect(a.finish());
    try expectWords(&a, &.{
        0xE1560003, 0xE0D7C008, 0xBAFFFFFC, 0xE1570008, 0x01560003, 0x2AFFFFF9, 0xE1530006, 0xE0D8C007,
        0xBAFFFFF6, 0xE196C007, 0x0AFFFFF4, 0xE59BC01C, 0xE35C0000, 0x03500002, 0x8AFFFFF0, 0xE3570000,
        0xAAFFFFEE, 0xE3A0C007, 0xE15C0006, 0xE3A0C000, 0xE0DCC007, 0xAAFFFFE9, 0xE5D5C008, 0xE35C0003,
        0x1AFFFFE6, 0xE5D6C005, 0xE31C0004, 0x1AFFFFE3, 0xEEB40B41, 0xEEF1FA10, 0x4AFFFFE0, 0xE3580000,
        0xE594E008, 0x0153000E, 0x0AFFFFDC, 0xEAFFFFDB,
    });
}

test "arm calls pass words, 64-bit integers, and a result of two words" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    // ldr ip, [fp, #32]; str ip, [sp, #-8]!; movw ip, #0x5678; movt ip, #0x1234; blx ip
    // add sp, sp, #8; mov ip, #0; str ip, [fp, #28]
    a.call(0x12345678);
    // sub sp, sp, #16; str r2, [sp]; str r9, [sp, #4]; str r3, [sp, #8]; str r8, [sp, #12]
    // mov r2, r1; ldr r3, [fp, #24]; ldr r1, [fp, #28]; movw ip; movt ip; blx ip
    // add sp, sp, #16; str r1, [fp, #28]
    a.callWide(0x12345678);
    // str r3, [sp, #-8]!; mov r3, r2; mov r2, r1; mov r1, r0; add r0, fp, #16; movw ip; movt ip
    // blx ip; add sp, sp, #8; ldr r0, [fp, #16]; ldr r1, [fp, #20]; mov ip, #0
    // str ip, [fp, #28]; str ip, [fp, #24]
    a.callPair(0x12345678);
    try expectWords(&a, &.{
        0xE59BC020, 0xE52DC008, 0xE305C678, 0xE341C234, 0xE12FFF3C, 0xE28DD008, 0xE3A0C000, 0xE58BC01C,
        0xE24DD010, 0xE58D2000, 0xE58D9004, 0xE58D3008, 0xE58D800C, 0xE1A02001, 0xE59B3018, 0xE59B101C,
        0xE305C678, 0xE341C234, 0xE12FFF3C, 0xE28DD010, 0xE58B101C, 0xE52D3008, 0xE1A03002, 0xE1A02001,
        0xE1A01000, 0xE28B0010, 0xE305C678, 0xE341C234, 0xE12FFF3C, 0xE28DD008, 0xE59B0010, 0xE59B1014,
        0xE3A0C000, 0xE58BC01C, 0xE58BC018,
    });
}

test "arm local calls keep the return address in the frame" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l = a.newLabel();
    a.bind(l);
    a.callLocal(l); // add lr, pc, #4; str lr, [fp, #8]; b
    a.callReg(.t2); // add lr, pc, #4; str lr, [fp, #8]; bx r2
    a.retLocal(); // ldr pc, [fp, #8]
    a.linkPastJump(.t3); // ldr r1, [fp, #8]; add r1, r1, #4; mov ip, #0; str ip, [fp, #24]
    a.saveLink(32); // sub sp, sp, #32; ldr ip, [fp, #8]; str ip, [sp, #24]
    a.leaveLink(32); // ldr ip, [sp, #24]; add sp, sp, #32; bx ip
    try std.testing.expect(a.finish());
    try expectWords(&a, &.{
        0xE28FE004, 0xE58BE008, 0xEAFFFFFC, 0xE28FE004, 0xE58BE008, 0xE12FFF12, 0xE59BF008, 0xE59B1008,
        0xE2811004, 0xE3A0C000, 0xE58BC018, 0xE24DD020, 0xE59BC008, 0xE58DC018, 0xE59DC018, 0xE28DD020,
        0xE12FFF1C,
    });
}

test "arm entry sequence" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    // push {r3-r11, lr}; vpush {d8-d12}; sub sp, sp, #112; mov fp, sp; mov r4, r0
    // str r1, [fp, #4]; str r3, [fp]
    a.prologue();
    a.epilogue(); // add sp, fp, #112; vpop {d8-d12}; pop {r3-r11, pc}
    a.trap(); // udf #0
    a.jmpReg(entry_target); // bx r2
    try expectWords(&a, &.{
        0xE92D4FF8, 0xED2D8B0A, 0xE24DD070, 0xE1A0B00D, 0xE1A04000, 0xE58B1004, 0xE58B3000, 0xE28BD070,
        0xECBD8B0A, 0xE8BD8FF8, 0xE7F000F0, 0xE12FFF12,
    });
}

test "arm unbound label fails" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.jmp(a.newLabel());
    try std.testing.expect(!a.finish());
}

test "arm division routines round as the interpreter does" {
    var rem: i64 = 0;
    try std.testing.expectEqual(@as(i64, -2), rt.divRem(-7, 3, &rem));
    try std.testing.expectEqual(@as(i64, -1), rem);
    try std.testing.expectEqual(@as(i64, -3), rt.floorDiv(-7, 3));
    try std.testing.expectEqual(@as(i64, 2), rt.floorMod(-7, 3));
    try std.testing.expectEqual(@as(i64, -2), rt.floorMod(7, -3));
    try std.testing.expectEqual(@as(i64, 2), rt.floorDiv(7, 3));
    // Operands beyond 32 bits take the long division.
    try std.testing.expectEqual(@as(i64, -3_000_000_001), rt.floorDiv(-9_000_000_001, 3));
    try std.testing.expectEqual(@as(i64, 2), rt.floorMod(-9_000_000_001, 3));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i32)), rt.divRem(std.math.minInt(i32), 1, &rem));
    try std.testing.expectEqual(@as(i64, 1 << 31), rt.floorDiv(std.math.minInt(i32), -1));
    try std.testing.expectEqual(@as(i64, -3), rt.floatToInt(@bitCast(@as(f64, -3.9))));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), rt.floatToInt(@bitCast(@as(f64, 1e300))));
    try std.testing.expectEqual(@as(i64, 0), rt.floatToInt(@bitCast(std.math.nan(f64))));
}

test "arm division saves the registers that a routine may clobber" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    // push {r0-r3}; vpush {d0-d7}; ldr r0, [sp, #76]; mov r1, r8; ldr r2, [sp, #64]
    // ldr r3, [fp, #28]; movw ip; movt ip; blx ip; mov r6, r0; mov r7, r1
    // vpop {d0-d7}; pop {r0-r3}
    a.floorDiv(.t0, .t1, .t4, false, .c1, .c1);
    var w: [13]u32 = undefined;
    try std.testing.expectEqual(@sizeOf(@TypeOf(w)), a.buf.items.len);
    @memcpy(std.mem.sliceAsBytes(&w), a.buf.items);
    for (&w) |*x| x.* = std.mem.littleToNative(u32, x.*);
    // The address of the routine fills the seventh and eighth words.
    try std.testing.expectEqualSlices(u32, &.{ 0xE92D000F, 0xED2D0B10, 0xE59D004C, 0xE1A01008, 0xE59D2040, 0xE59B301C }, w[0..6]);
    try std.testing.expectEqualSlices(u32, &.{ 0xE12FFF3C, 0xE1A06000, 0xE1A07001, 0xECBD0B10, 0xE8BD000F }, w[8..]);
}

test "arm indexed words, pairs of words, and words in memory" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const l = a.newLabel();
    a.loadIdx64(.t0, .t1, .t2); // add r10, r3, r2, lsl #3; ldr r6, [r10]; ldr r7, [r10, #4]
    a.storePair32(.t1, .t4, .{ .base = .t2, .disp = 8 }); // str r3, [r2, #8]; str r0, [r2, #12]
    // ldr ip, [fp, #36]; ldr lr, [r6, #12]; cmp ip, lr; ldr ip, [fp, #32]; ldr lr, [r6, #8]
    // cmpeq ip, lr; bne
    a.jumpIfMem(.ne, .t5, .{ .base = .t0, .disp = 8 }, l);
    a.bind(l);
    a.fmovImm(.d1, 0x3FF0_0000_0000_0000); // mov ip, #0; movw lr, #0; movt lr, #0x3ff0; vmov d1, ip, lr
    try std.testing.expect(a.finish());
    try expectWords(&a, &.{
        0xE083A182, 0xE59A6000, 0xE59A7004, 0xE5823008, 0xE582000C, 0xE59BC024, 0xE596E00C, 0xE15C000E,
        0xE59BC020, 0xE596E008, 0x015C000E, 0x1AFFFFFF, 0xE3A0C000, 0xE300E000, 0xE343EFF0, 0xEC4ECB11,
    });
}
