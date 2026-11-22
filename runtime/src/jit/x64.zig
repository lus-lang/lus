//! The x86-64 backend of the JIT assembler, for the System V calling
//! convention. It offers the same interface as `a64.zig`.

const std = @import("std");
const reloc = @import("reloc.zig");
const builtin = @import("builtin");

pub const Reg = enum(u4) {
    rax,
    rcx,
    rdx,
    rbx,
    rsp,
    rbp,
    rsi,
    rdi,
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
    inline fn lo(r: Reg) u8 {
        return @backingInt(r) & 7;
    }
    inline fn hi(r: Reg) u8 {
        return @backingInt(r) >> 3;
    }
};

pub const FReg = enum(u4) {
    xmm0,
    xmm1,
    xmm2,
    xmm3,
    xmm4,
    xmm5,
    xmm6,
    xmm7,
    xmm8,
    xmm9,
    xmm10,
    xmm11,
    xmm12,
    xmm13,
    xmm14,
    xmm15,

    inline fn n(r: FReg) u8 {
        return @backingInt(r);
    }
};

/// The native stack pointer, as the base of a memory operand.
pub const sp: Reg = .rsp;

// The registers the emitter uses. Pinned registers are callee-saved, so
// they survive calls into the runtime.
pub const thread: Reg = .rbx;
pub const bp: Reg = .r14;
pub const base: Reg = .r15;
pub const stop: Reg = .r12;
pub const t0: Reg = .rax;
pub const t1: Reg = .rcx;
pub const t2: Reg = .rdx;
pub const t3: Reg = .rsi;
pub const t4: Reg = .rdi;
pub const t5: Reg = .r8;
pub const t6: Reg = .r9;
pub const args = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
pub const ret0: Reg = .rax;
pub const ret1: Reg = .rdx;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .rax;
pub const f0: FReg = .xmm0;
pub const f1: FReg = .xmm1;
/// Scratch registers of the assembler itself.
const s0: Reg = .r11;
const s1: Reg = .r10;

pub const Cond = enum(u4) {
    eq = 0x4,
    ne = 0x5,
    /// Unsigned higher or same.
    hs = 0x3,
    /// Unsigned lower.
    lo = 0x2,
    mi = 0x8,
    pl = 0x9,
    hi = 0x7,
    ls = 0x6,
    ge = 0xD,
    lt = 0xC,
    gt = 0xF,
    le = 0xE,

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
    /// Offset of the 32-bit displacement, which is relative to its end.
    at: u32,
    label: Label,
};

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

    fn byte(a: *Assembler, b: u8) void {
        a.buf.append(a.gpa, b) catch {
            a.oom = true;
        };
    }
    fn bytes(a: *Assembler, b: []const u8) void {
        a.buf.appendSlice(a.gpa, b) catch {
            a.oom = true;
        };
    }
    fn imm32(a: *Assembler, v: u32) void {
        a.bytes(std.mem.asBytes(&std.mem.nativeToLittle(u32, v)));
    }
    fn imm64(a: *Assembler, v: u64) void {
        a.bytes(std.mem.asBytes(&std.mem.nativeToLittle(u64, v)));
    }
    fn rel32(a: *Assembler, l: Label) void {
        a.fixups.append(a.gpa, .{ .at = a.offset(), .label = l }) catch {
            a.oom = true;
        };
        a.imm32(0);
    }

    /// This target keeps its constants in the instructions.
    pub fn flushPool(a: *Assembler) void {
        _ = a;
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            const target = a.labels.items[f.label];
            if (target == unbound) return false;
            const delta = @as(i64, target) - (@as(i64, f.at) + 4);
            if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) {
                a.overflow = true;
                continue;
            }
            const v: u32 = @bitCast(@as(i32, @intCast(delta)));
            @memcpy(a.buf.items[f.at..][0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, v)));
        }
        return !a.overflow;
    }

    /// The REX prefix for a register operand `reg` and a base or second
    /// register `rm`.
    fn rex(a: *Assembler, w: bool, reg: u8, rm: u8) void {
        const b: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | ((reg >> 3) << 2) | (rm >> 3);
        if (b != 0x40) a.byte(b);
    }
    /// ModRM for two registers.
    fn modrr(a: *Assembler, reg: u8, rm: u8) void {
        a.byte(0xC0 | (reg & 7) << 3 | (rm & 7));
    }
    /// ModRM, SIB, and displacement for a memory operand.
    fn modrm(a: *Assembler, reg: u8, m: Mem) void {
        const b = m.base.lo();
        const r = (reg & 7) << 3;
        const small = m.disp >= -128 and m.disp <= 127;
        // A base of rbp or r13 always takes a displacement.
        if (m.disp == 0 and b != 5) {
            a.byte(r | b);
            if (b == 4) a.byte(0x24);
        } else if (small) {
            a.byte(0x40 | r | b);
            if (b == 4) a.byte(0x24);
            a.byte(@bitCast(@as(i8, @intCast(m.disp))));
        } else {
            a.byte(0x80 | r | b);
            if (b == 4) a.byte(0x24);
            a.imm32(@bitCast(m.disp));
        }
    }
    fn opRR(a: *Assembler, op: u8, reg: Reg, rm: Reg) void {
        a.rex(true, reg.n(), rm.n());
        a.byte(op);
        a.modrr(reg.n(), rm.n());
    }
    fn opRM(a: *Assembler, w: bool, op: []const u8, reg: u8, m: Mem) void {
        a.rex(w, reg, m.base.n());
        a.bytes(op);
        a.modrm(reg, m);
    }

    // -----------------------------------------------------------------
    // Moves and immediates

    pub fn mov(a: *Assembler, dst: Reg, src: Reg) void {
        if (dst == src) return;
        a.opRR(0x89, src, dst);
    }

    /// Loads a 64-bit constant with the shortest encoding.
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
        a.rex(true, 0, dst.n());
        a.byte(0xB8 | dst.lo());
        a.record(a.offset(), .word, r);
        a.imm64(v);
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
        if (v == 0) {
            // xor r32, r32
            a.rex(false, dst.n(), dst.n());
            a.byte(0x31);
            a.modrr(dst.n(), dst.n());
        } else if (v <= 0xFFFF_FFFF) {
            a.rex(false, 0, dst.n());
            a.byte(0xB8 | dst.lo());
            a.imm32(@intCast(v));
        } else if (@as(i64, @bitCast(v)) >= std.math.minInt(i32) and @as(i64, @bitCast(v)) < 0) {
            a.rex(true, 0, dst.n());
            a.byte(0xC7);
            a.modrr(0, dst.n());
            a.imm32(@truncate(v));
        } else {
            a.rex(true, 0, dst.n());
            a.byte(0xB8 | dst.lo());
            a.imm64(v);
        }
    }

    // -----------------------------------------------------------------
    // Memory

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.opRM(true, &.{0x8B}, dst.n(), m);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.opRM(true, &.{0x89}, src.n(), m);
    }
    /// Loads 32 bits, zero-extended.
    pub fn load32(a: *Assembler, dst: Reg, m: Mem) void {
        a.opRM(false, &.{0x8B}, dst.n(), m);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.opRM(false, &.{0x89}, src.n(), m);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.opRM(false, &.{ 0x0F, 0xB6 }, dst.n(), m);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        // The prefix is always present so that sil and dil are addressable.
        a.byte(0x40 | (src.hi() << 2) | m.base.hi());
        a.byte(0x88);
        a.modrm(src.n(), m);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.opRM(false, &.{ 0x0F, 0xB7 }, dst.n(), m);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.byte(0x66);
        a.opRM(false, &.{0x89}, src.n(), m);
    }
    pub fn storeImm16(a: *Assembler, m: Mem, v: u16) void {
        a.byte(0x66);
        a.opRM(false, &.{0xC7}, 0, m);
        a.bytes(std.mem.asBytes(&std.mem.nativeToLittle(u16, v)));
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
    /// This target has no register that reads as zero.
    pub const zero_reg: ?Reg = null;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        a.byte(0xF2);
        a.opRM(false, &.{ 0x0F, 0x10 }, dst.n(), m);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.byte(0xF2);
        a.opRM(false, &.{ 0x0F, 0x11 }, src.n(), m);
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
        const sv: i64 = @bitCast(v);
        if (sv >= std.math.minInt(i32) and sv <= std.math.maxInt(i32)) {
            a.opRM(true, &.{0xC7}, 0, m);
            a.imm32(@truncate(v));
        } else {
            a.movImm(s0, v);
            a.store64(s0, m);
        }
    }
    pub fn storeImm32(a: *Assembler, m: Mem, v: u32) void {
        a.opRM(false, &.{0xC7}, 0, m);
        a.imm32(v);
    }
    /// Prepares `zero16`, which may then run any number of times before
    /// the next copy or call.
    pub fn zeroPrepare(a: *Assembler) void {
        a.bytes(&.{ 0x45, 0x0F, 0x57, 0xFF }); // xorps xmm15, xmm15
    }
    /// Clears 16 bytes with one store.
    pub fn zero16(a: *Assembler, m: Mem) void {
        a.opRM(false, &.{ 0x0F, 0x11 }, 15, m);
    }
    /// Copies 16 bytes as two 64-bit words. A value is often written as
    /// two words just before it is copied, and a 16-byte load would wait
    /// for both of those stores to leave the store buffer.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        a.load64(s0, src);
        a.load64(s1, .{ .base = src.base, .disp = src.disp + 8 });
        a.store64(s0, dst);
        a.store64(s1, .{ .base = dst.base, .disp = dst.disp + 8 });
    }
    /// dst = base + disp.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        a.opRM(true, &.{0x8D}, dst.n(), m);
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.mov(s0, index);
        a.rex(true, 0, s0.n());
        a.byte(0xC1);
        a.modrr(4, s0.n());
        a.byte(shift);
        a.add(s0, b);
        a.mov(dst, s0);
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.mov(s0, index);
        a.rex(true, 0, s0.n());
        a.byte(0xC1);
        a.modrr(4, s0.n());
        a.byte(shift);
        a.neg(s0);
        a.add(s0, b);
        a.mov(dst, s0);
    }

    // -----------------------------------------------------------------
    // Integer arithmetic. Each operation computes dst = dst op src.

    pub fn add(a: *Assembler, dst: Reg, src: Reg) void {
        a.opRR(0x01, src, dst);
    }
    pub fn sub(a: *Assembler, dst: Reg, src: Reg) void {
        a.opRR(0x29, src, dst);
    }
    pub fn mul(a: *Assembler, dst: Reg, src: Reg) void {
        a.rex(true, dst.n(), src.n());
        a.bytes(&.{ 0x0F, 0xAF });
        a.modrr(dst.n(), src.n());
    }
    pub fn @"and"(a: *Assembler, dst: Reg, src: Reg) void {
        a.opRR(0x21, src, dst);
    }
    pub fn @"or"(a: *Assembler, dst: Reg, src: Reg) void {
        a.opRR(0x09, src, dst);
    }
    pub fn xor(a: *Assembler, dst: Reg, src: Reg) void {
        a.opRR(0x31, src, dst);
    }
    pub fn neg(a: *Assembler, dst: Reg) void {
        a.rex(true, 0, dst.n());
        a.byte(0xF7);
        a.modrr(3, dst.n());
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.rex(true, 0, dst.n());
        a.byte(0xF7);
        a.modrr(2, dst.n());
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        if (v == 0) return;
        a.rex(true, 0, dst.n());
        if (v >= -128 and v <= 127) {
            a.byte(0x83);
            a.modrr(0, dst.n());
            a.byte(@bitCast(@as(i8, @intCast(v))));
        } else {
            a.byte(0x81);
            a.modrr(0, dst.n());
            a.imm32(@bitCast(v));
        }
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one. The operands and results
    /// are emitter temporaries.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        // The division uses rax and rdx, which are temporaries too.
        a.mov(s0, y);
        a.mov(s1, x);
        a.mov(.rax, s1);
        a.bytes(&.{ 0x48, 0x99 }); // cqo
        a.rex(true, 0, s0.n());
        a.byte(0xF7);
        a.modrr(7, s0.n());
        a.mov(s0, .rax);
        a.mov(s1, .rdx);
        a.mov(rem, s1);
        a.mov(quot, s0);
    }

    // -----------------------------------------------------------------
    // Floats

    fn sse(a: *Assembler, prefix: u8, op: u8, dst: u8, src: u8) void {
        a.byte(prefix);
        a.rex(false, dst, src);
        a.bytes(&.{ 0x0F, op });
        a.modrr(dst, src);
    }
    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.sse(0xF2, 0x58, dst.n(), src.n());
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.sse(0xF2, 0x5C, dst.n(), src.n());
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.sse(0xF2, 0x59, dst.n(), src.n());
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.sse(0xF2, 0x5E, dst.n(), src.n());
    }
    /// Converts a signed integer to a float.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.byte(0xF2);
        a.rex(true, dst.n(), src.n());
        a.bytes(&.{ 0x0F, 0x2A });
        a.modrr(dst.n(), src.n());
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.byte(0x66);
        a.rex(true, dst.n(), src.n());
        a.bytes(&.{ 0x0F, 0x6E });
        a.modrr(dst.n(), src.n());
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.byte(0x66);
        a.rex(true, src.n(), dst.n());
        a.bytes(&.{ 0x0F, 0x7E });
        a.modrr(src.n(), dst.n());
    }

    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        // movaps
        a.rex(false, dst.n(), src.n());
        a.bytes(&.{ 0x0F, 0x28 });
        a.modrr(dst.n(), src.n());
    }
    /// The float scratch register of the assembler.
    const fs0: FReg = .xmm14;
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.movImm(s0, 0x8000_0000_0000_0000);
        a.bitsToFloat(fs0, s0);
        a.fmov(dst, src);
        a.sse(0x66, 0x57, dst.n(), fs0.n()); // xorpd
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.movImm(s0, 0x7FFF_FFFF_FFFF_FFFF);
        a.bitsToFloat(fs0, s0);
        a.fmov(dst, src);
        a.sse(0x66, 0x54, dst.n(), fs0.n()); // andpd
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.sse(0xF2, 0x51, dst.n(), src.n());
    }
    /// This target rounds through the runtime.
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
        a.byte(0xF2);
        a.rex(true, dst.n(), src.n());
        a.bytes(&.{ 0x0F, 0x2C });
        a.modrr(dst.n(), src.n());
    }

    // Three-operand forms: dst = x op y.
    fn bin3(a: *Assembler, dst: Reg, x: Reg, y: Reg, comptime op: fn (*Assembler, Reg, Reg) void, commutes: bool) void {
        if (dst == x) {
            op(a, dst, y);
        } else if (dst == y) {
            if (commutes) {
                op(a, dst, x);
            } else {
                a.mov(s0, y);
                a.mov(dst, x);
                op(a, dst, s0);
            }
        } else {
            a.mov(dst, x);
            op(a, dst, y);
        }
    }
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, add, true);
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, sub, false);
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, mul, true);
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, @"and", true);
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, @"or", true);
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.bin3(dst, x, y, xor, true);
    }
    fn fbin3(a: *Assembler, dst: FReg, x: FReg, y: FReg, comptime op: fn (*Assembler, FReg, FReg) void, commutes: bool) void {
        if (dst == x) {
            op(a, dst, y);
        } else if (dst == y) {
            if (commutes) {
                op(a, dst, x);
            } else {
                a.fmov(fs0, y);
                a.fmov(dst, x);
                op(a, dst, fs0);
            }
        } else {
            a.fmov(dst, x);
            op(a, dst, y);
        }
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fbin3(dst, x, y, fadd, true);
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fbin3(dst, x, y, fsub, false);
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fbin3(dst, x, y, fmul, true);
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.fbin3(dst, x, y, fdiv, false);
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        a.lea(dst, .{ .base = x, .disp = v });
    }
    /// Loads and stores of the word at [b + index * 8].
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        a.addScaled(s1, b, index, 3);
        a.load64(dst, .{ .base = s1 });
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        a.addScaled(s1, b, index, 3);
        a.store64(src, .{ .base = s1 });
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. `tmp` and
    /// `tmp2` are free registers other than rax and rdx, which the
    /// division uses and which come back unchanged.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        const done = a.newLabel();
        a.mov(s0, y);
        a.mov(s1, x);
        a.mov(tmp, .rax);
        a.mov(tmp2, .rdx);
        a.mov(.rax, s1);
        a.bytes(&.{ 0x48, 0x99 }); // cqo
        a.rex(true, 0, s0.n());
        a.byte(0xF7);
        a.modrr(7, s0.n());
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.mov(s1, .rdx);
        a.opRR(0x85, s1, s1);
        a.jcc(0x4, done);
        a.xor(s1, s0);
        a.jcc(0x9, done);
        if (mod) a.add(.rdx, s0) else a.addImm(.rax, -1);
        a.bind(done);
        a.mov(s1, if (mod) .rdx else .rax);
        a.mov(.rax, tmp);
        a.mov(.rdx, tmp2);
        a.mov(dst, s1);
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
        a.lea(dst, .{ .base = .rsp, .disp = disp });
    }
    /// Moves the native stack pointer by `v` bytes.
    pub fn moveSp(a: *Assembler, v: i32) void {
        if (v < 0) a.probe(-v);
        a.addImm(.rsp, v);
    }
    /// Touches each page of the `size` bytes below the stack pointer in
    /// order, on Windows, where the system commits the stack of a thread
    /// one guard page at a time, as the `__chkstk` of its compilers does.
    fn probe(a: *Assembler, size: i32) void {
        if (builtin.os.tag != .windows) return;
        var off: i32 = 4096;
        while (off <= size) : (off += 4096) a.load64(s0, .{ .base = .rsp, .disp = -off });
    }

    // -----------------------------------------------------------------
    // Control flow

    pub fn jmp(a: *Assembler, l: Label) void {
        a.byte(0xE9);
        a.rel32(l);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.rex(false, 0, r.n());
        a.byte(0xFF);
        a.modrr(4, r.n());
    }
    fn jcc(a: *Assembler, c: u8, l: Label) void {
        a.bytes(&.{ 0x0F, 0x80 | c });
        a.rel32(l);
    }
    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        a.opRR(0x39, y, x);
        a.jcc(@backingInt(c), l);
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (v == 0 and (c == .eq or c == .ne)) {
            a.opRR(0x85, x, x);
        } else {
            a.rex(true, 0, x.n());
            if (v >= -128 and v <= 127) {
                a.byte(0x83);
                a.modrr(7, x.n());
                a.byte(@bitCast(@as(i8, @intCast(v))));
            } else {
                a.byte(0x81);
                a.modrr(7, x.n());
                a.imm32(@bitCast(v));
            }
        }
        a.jcc(@backingInt(c), l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.rex(false, x.n(), x.n());
        a.byte(0x85);
        a.modrr(x.n(), x.n());
        a.jcc(if (zero) 0x4 else 0x5, l);
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.opRM(false, &.{0x80}, 7, m);
        a.byte(v);
        a.jcc(@backingInt(c), l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        // test byte [m], mask
        a.opRM(false, &.{0xF6}, 0, m);
        a.byte(@as(u8, 1) << bit);
        a.jcc(if (set) 0x5 else 0x4, l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        switch (c) {
            // The operands are swapped so that an unordered result, which
            // sets the carry flag, reads as false.
            .lt, .le, .nlt, .nle => {
                a.sse(0x66, 0x2E, y.n(), x.n());
                a.jcc(switch (c) {
                    .lt => 0x7,
                    .le => 0x3,
                    .nlt => 0x6,
                    .nle => 0x2,
                    else => unreachable,
                }, l);
            },
            .eq => {
                const skip = a.newLabel();
                a.sse(0x66, 0x2E, x.n(), y.n());
                a.jcc(0xA, skip);
                a.jcc(0x4, l);
                a.bind(skip);
            },
            .ne => {
                a.sse(0x66, 0x2E, x.n(), y.n());
                a.jcc(0x5, l);
                a.jcc(0xA, l);
            },
        }
    }

    /// Calls a function at an absolute address.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(.rax, addr);
        a.bytes(&.{ 0xFF, 0xD0 });
    }
    /// Calls a routine that returns two words in the two result
    /// registers, such as `jit.Target`.
    pub fn callPair(a: *Assembler, addr: usize) void {
        a.call(addr);
    }
    /// Calls the routine that `r` names, at `addr` in this process.
    pub fn callReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        if (!a.aot) return a.call(addr);
        a.movImmReloc(.rax, addr, r);
        a.bytes(&.{ 0xFF, 0xD0 });
    }
    /// `callPair` for the routine that `r` names.
    pub fn callPairReloc(a: *Assembler, addr: usize, r: reloc.Reloc) void {
        a.callReloc(addr, r);
    }
    /// Calls a routine in the same code, which ends with `leaveLocal`.
    pub fn callLocal(a: *Assembler, l: Label) void {
        a.byte(0xE8);
        a.rel32(l);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.rex(false, 0, r.n());
        a.byte(0xFF);
        a.modrr(2, r.n());
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.byte(0xC3);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.load64(dst, .{ .base = .rsp });
        a.addImm(dst, 5);
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        a.bytes(&.{ 0x48, 0x83, 0xC4, 0x08 }); // add rsp, 8
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine, which the call pushed.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.probe(size - 8);
        a.addImm(.rsp, -(size - 8));
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        a.addImm(.rsp, size - 8);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        a.unsaveLink(size);
        a.byte(0xC3);
    }
    /// Sets the native stack pointer.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.mov(.rsp, src);
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        a.opRM(true, &.{0x3B}, x.n(), m);
        a.jcc(@backingInt(c), l);
    }
    /// Opens a routine entered by `callLocal` that calls other functions.
    /// The return address unbalanced the stack by eight bytes.
    pub fn enterLocal(a: *Assembler) void {
        a.bytes(&.{ 0x48, 0x83, 0xEC, 0x08 }); // sub rsp, 8
    }
    /// Returns from a routine opened by `enterLocal`.
    pub fn leaveLocal(a: *Assembler) void {
        a.bytes(&.{ 0x48, 0x83, 0xC4, 0x08 }); // add rsp, 8
        a.byte(0xC3);
    }
    pub fn trap(a: *Assembler) void {
        a.byte(0xCC);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the pinned registers and loads them.
    pub fn prologue(a: *Assembler) void {
        a.byte(0x53); // push rbx
        a.byte(0x55); // push rbp
        a.bytes(&.{ 0x41, 0x54 }); // push r12
        a.bytes(&.{ 0x41, 0x55 }); // push r13
        a.bytes(&.{ 0x41, 0x56 }); // push r14
        a.bytes(&.{ 0x41, 0x57 }); // push r15
        a.bytes(&.{ 0x48, 0x83, 0xEC, 0x08 }); // sub rsp, 8
        a.mov(thread, .rdi);
        a.mov(stop, .rsi);
        a.mov(base, .rcx);
        // The address to continue at moves to the register the emitter
        // expects it in.
        a.mov(.rax, .rdx);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        a.bytes(&.{ 0x48, 0x83, 0xC4, 0x08 }); // add rsp, 8
        a.bytes(&.{ 0x41, 0x5F }); // pop r15
        a.bytes(&.{ 0x41, 0x5E }); // pop r14
        a.bytes(&.{ 0x41, 0x5D }); // pop r13
        a.bytes(&.{ 0x41, 0x5C }); // pop r12
        a.byte(0x5D); // pop rbp
        a.byte(0x5B); // pop rbx
        a.byte(0xC3); // ret
    }
};

fn expectBytes(a: *Assembler, expected: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected, a.buf.items);
}

test "x86-64 moves and immediates" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.rdi, .rbx); // mov rdi, rbx
    a.mov(.r14, .rax); // mov r14, rax
    a.movImm(.rsi, 0); // xor esi, esi
    a.movImm(.rsi, 7); // mov esi, 7
    a.movImm(.r8, 0x1122334455667788); // movabs r8, imm
    a.movImm(.rax, @bitCast(@as(i64, -1))); // mov rax, -1
    try expectBytes(&a, &.{
        0x48, 0x89, 0xDF,
        0x49, 0x89, 0xC6,
        0x31, 0xF6, 0xBE,
        0x07, 0x00, 0x00,
        0x00, 0x49, 0xB8,
        0x88, 0x77, 0x66,
        0x55, 0x44, 0x33,
        0x22, 0x11, 0x48,
        0xC7, 0xC0, 0xFF,
        0xFF, 0xFF, 0xFF,
    });
}

test "x86-64 memory forms" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load64(.rax, .{ .base = .r14, .disp = 16 }); // mov rax, [r14+16]
    a.store64(.rcx, .{ .base = .r14, .disp = 0x200 }); // mov [r14+0x200], rcx
    a.load8(.rax, .{ .base = .r14, .disp = 8 }); // movzx eax, byte [r14+8]
    a.load64(.rax, .{ .base = .rbx }); // mov rax, [rbx]
    a.load64(.rax, .{ .base = .r12 }); // mov rax, [r12]
    a.load64(.rax, .{ .base = .r13 }); // mov rax, [r13+0]
    a.load64(.rax, .{ .base = .rsp, .disp = 8 }); // mov rax, [rsp+8]
    a.copy16(.{ .base = .r14, .disp = 32 }, .{ .base = .r14, .disp = 48 }); // mov r11, [r14+48]; mov r10, [r14+56]; mov [r14+32], r11; mov [r14+40], r10
    a.storeImm64(.{ .base = .r14, .disp = 8 }, 3); // mov qword [r14+8], 3
    try expectBytes(&a, &.{
        0x49, 0x8B, 0x46, 0x10,
        0x49, 0x89, 0x8E, 0x00,
        0x02, 0x00, 0x00, 0x41,
        0x0F, 0xB6, 0x46, 0x08,
        0x48, 0x8B, 0x03, 0x49,
        0x8B, 0x04, 0x24, 0x49,
        0x8B, 0x45, 0x00, 0x48,
        0x8B, 0x44, 0x24, 0x08,
        0x4D, 0x8B, 0x5E, 0x30,
        0x4D, 0x8B, 0x56, 0x38,
        0x4D, 0x89, 0x5E, 0x20,
        0x4D, 0x89, 0x56, 0x28,
        0x49, 0xC7, 0x46, 0x08,
        0x03, 0x00, 0x00, 0x00,
    });
}

test "x86-64 sixteen-bit forms" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load16(.rax, .{ .base = .rbx, .disp = 2 }); // movzx eax, word [rbx+2]
    a.store16(.rax, .{ .base = .rbx, .disp = 2 }); // mov [rbx+2], ax
    a.storeImm16(.{ .base = .rax, .disp = 4 }, 0); // mov word [rax+4], 0
    a.load16(.r9, .{ .base = .r14, .disp = 2 }); // movzx r9d, word [r14+2]
    a.store16(.r9, .{ .base = .r14, .disp = 2 }); // mov [r14+2], r9w
    try expectBytes(&a, &.{
        0x0F, 0xB7, 0x43, 0x02,
        0x66, 0x89, 0x43, 0x02,
        0x66, 0xC7, 0x40, 0x04,
        0x00, 0x00, 0x45, 0x0F,
        0xB7, 0x4E, 0x02, 0x66,
        0x45, 0x89, 0x4E, 0x02,
    });
}

test "x86-64 arithmetic and floats" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.add(.rax, .rcx); // add rax, rcx
    a.sub(.rax, .rcx); // sub rax, rcx
    a.mul(.rax, .rcx); // imul rax, rcx
    a.addImm(.rax, 5); // add rax, 5
    a.neg(.rax); // neg rax
    a.fadd(.xmm0, .xmm1); // addsd xmm0, xmm1
    a.intToFloat(.xmm0, .rax); // cvtsi2sd xmm0, rax
    a.loadF(.xmm0, .{ .base = .r14, .disp = 16 }); // movsd xmm0, [r14+16]
    try expectBytes(&a, &.{
        0x48, 0x01, 0xC8,
        0x48, 0x29, 0xC8,
        0x48, 0x0F, 0xAF,
        0xC1, 0x48, 0x83,
        0xC0, 0x05, 0x48,
        0xF7, 0xD8, 0xF2,
        0x0F, 0x58, 0xC1,
        0xF2, 0x48, 0x0F,
        0x2A, 0xC0, 0xF2,
        0x41, 0x0F, 0x10,
        0x46, 0x10,
    });
}

test "x86-64 branches resolve in both directions" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const top = a.newLabel();
    const end = a.newLabel();
    a.bind(top);
    a.jumpIf(.lt, .rax, .rcx, end); // cmp rax, rcx; jl end
    a.jmp(top); // jmp top
    a.bind(end);
    a.trap();
    try std.testing.expect(a.finish());
    try expectBytes(&a, &.{
        0x48, 0x39, 0xC8,
        0x0F, 0x8C, 0x05,
        0x00, 0x00, 0x00,
        0xE9, 0xF2, 0xFF,
        0xFF, 0xFF, 0xCC,
    });
}
