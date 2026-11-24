//! The aarch64 backend of the JIT assembler. It encodes the small set of
//! instructions the template emitter needs and resolves branches between
//! labels. `x64.zig` offers the same interface, so `emit.zig` describes
//! each opcode once for both architectures.

const std = @import("std");
const reloc = @import("reloc.zig");
const builtin = @import("builtin");

pub const Reg = enum(u5) {
    x0,
    x1,
    x2,
    x3,
    x4,
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
    /// Register 31 is the stack pointer or the zero register, depending on
    /// the instruction.
    sp,

    inline fn n(r: Reg) u32 {
        return @backingInt(r);
    }
};

pub const FReg = enum(u5) {
    v0,
    v1,
    v2,
    v3,
    v4,
    v5,
    v6,
    v7,
    v8,
    v9,
    v10,
    v11,
    v12,
    v13,
    v14,
    v15,
    v16,
    v17,
    v18,
    v19,
    v20,
    v21,
    v22,
    v23,
    v24,
    v25,
    v26,
    v27,
    v28,
    v29,
    v30,
    v31,

    inline fn n(r: FReg) u32 {
        return @backingInt(r);
    }
};

/// The native stack pointer, as the base of a memory operand.
pub const sp: Reg = .sp;

// The registers the emitter uses. Pinned registers are callee-saved, so
// they survive calls into the runtime.
pub const thread: Reg = .x19;
pub const bp: Reg = .x20;
pub const base: Reg = .x21;
pub const stop: Reg = .x22;
pub const t0: Reg = .x9;
pub const t1: Reg = .x10;
pub const t2: Reg = .x11;
pub const t3: Reg = .x12;
pub const t4: Reg = .x13;
pub const t5: Reg = .x14;
pub const t6: Reg = .x15;
pub const args = [_]Reg{ .x0, .x1, .x2, .x3, .x4, .x5 };
pub const ret0: Reg = .x0;
pub const ret1: Reg = .x1;
/// Holds the address to continue at after the entry sequence.
pub const entry_target: Reg = .x2;
pub const f0: FReg = .v0;
pub const f1: FReg = .v1;
/// Scratch registers of the assembler itself.
const s0: Reg = .x16;
const s1: Reg = .x17;
const zr: Reg = .sp;

/// Bytes of native stack the entry sequence reserves.
const frame_size = 64;
/// Offset of the slot where a shared routine keeps its return address.
const link_slot = 48;

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
    kind: enum { b26, b19, literal, adr },
};

/// A pool word that holds an address, before `flushPool` places it.
const PoolReloc = struct { index: u32, r: reloc.Reloc };

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Offset of each label, or `unbound`.
    labels: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    /// Constants that take more than two move instructions. They wait
    /// here for the next `flushPool`, and a load relative to the pc reads
    /// them. For a literal fixup, `label` is an index into this pool.
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
    /// Set ahead of time for a target without executable memory: an
    /// address loads through `adr` and `ldr` from its pool word, a pair
    /// that the linker can point at a slot outside the code
    /// (`reloc.Form.slot`).
    static: bool = false,
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
    /// at them. A load reaches one megabyte, so a long function flushes
    /// its pool at intervals.
    pub fn flushPool(a: *Assembler) void {
        if (a.pool.items.len > 0) {
            // The pool is aligned for 64-bit loads.
            while (a.buf.items.len % 8 != 0) a.word(0xD4200000);
            const pool_at = a.offset();
            for (a.pool.items) |v| a.buf.appendSlice(a.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, v))) catch {
                a.oom = true;
                return;
            };
            for (a.fixups.items[a.pool_fixups..]) |f| {
                if (f.kind == .literal or f.kind == .adr) a.patch(f, pool_at + f.label * 8);
            }
            for (a.pool_relocs.items) |p| a.record(pool_at + p.index * 8, .word, p.r);
            a.pool_relocs.clearRetainingCapacity();
            a.pool.clearRetainingCapacity();
        }
        a.pool_fixups = a.fixups.items.len;
    }

    fn patch(a: *Assembler, f: Fixup, target: u32) void {
        const delta = @divExact(@as(i64, target) - @as(i64, f.at), 4);
        const p: *align(1) u32 = @ptrCast(a.buf.items[f.at..].ptr);
        var w = std.mem.littleToNative(u32, p.*);
        switch (f.kind) {
            .b26 => {
                if (delta < -(1 << 25) or delta >= (1 << 25)) a.overflow = true;
                w |= @as(u32, @truncate(@as(u64, @bitCast(delta)))) & 0x03FF_FFFF;
            },
            .b19, .literal => {
                if (delta < -(1 << 18) or delta >= (1 << 18)) a.overflow = true;
                w |= (@as(u32, @truncate(@as(u64, @bitCast(delta)))) & 0x7FFFF) << 5;
            },
            .adr => {
                // The offset in bytes, its low two bits apart.
                const bytes = @as(i64, target) - @as(i64, f.at);
                if (bytes < -(1 << 20) or bytes >= (1 << 20)) a.overflow = true;
                const imm: u32 = @truncate(@as(u64, @bitCast(bytes)));
                w |= (imm & 3) << 29 | ((imm >> 2) & 0x7FFFF) << 5;
            },
        }
        p.* = std.mem.nativeToLittle(u32, w);
    }

    /// Resolves every branch. Returns false when the code is unusable.
    pub fn finish(a: *Assembler) bool {
        a.flushPool();
        if (a.oom) return false;
        for (a.fixups.items) |f| {
            if (f.kind == .literal or f.kind == .adr) continue;
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
        a.word(0xAA0003E0 | src.n() << 16 | dst.n());
    }

    /// Loads a 64-bit constant with the shortest move sequence.
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
        if (a.static) {
            // adr dst, word; ldr dst, [dst]
            a.record(a.offset(), .slot, r);
            a.fix(@intCast(index), .adr);
            a.word(0x10000000 | dst.n());
            a.word(0xF9400000 | dst.n() << 5 | dst.n());
            return;
        }
        a.pool_relocs.append(a.gpa, .{ .index = @intCast(index), .r = r }) catch {
            a.oom = true;
        };
        a.fix(@intCast(index), .literal);
        a.word(0x58000000 | dst.n());
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
        if (v == 0) return a.word(0xD2800000 | dst.n());
        // A value with mostly set halves starts from an inverted move.
        var ones: u32 = 0;
        var zeros: u32 = 0;
        for (0..4) |i| {
            const h: u16 = @truncate(v >> @intCast(16 * i));
            if (h == 0xFFFF) ones += 1;
            if (h == 0) zeros += 1;
        }
        if (@max(ones, zeros) < 2) {
            // Three or four moves cost more than one load from the pool.
            var index: usize = 0;
            while (index < a.pool.items.len and a.pool.items[index] != v) index += 1;
            if (index == a.pool.items.len) a.pool.append(a.gpa, v) catch {
                a.oom = true;
            };
            a.fix(@intCast(index), .literal);
            return a.word(0x58000000 | dst.n());
        }
        if (ones > zeros) {
            var first = true;
            for (0..4) |i| {
                const h: u16 = @truncate(v >> @intCast(16 * i));
                if (h == 0xFFFF) continue;
                const hw: u32 = @intCast(i);
                if (first) {
                    a.word(0x92800000 | hw << 21 | @as(u32, ~h) << 5 | dst.n());
                    first = false;
                } else a.word(0xF2800000 | hw << 21 | @as(u32, h) << 5 | dst.n());
            }
            if (first) a.word(0x92800000 | dst.n());
            return;
        }
        var first = true;
        for (0..4) |i| {
            const h: u16 = @truncate(v >> @intCast(16 * i));
            if (h == 0) continue;
            const hw: u32 = @intCast(i);
            if (first) {
                a.word(0xD2800000 | hw << 21 | @as(u32, h) << 5 | dst.n());
                first = false;
            } else a.word(0xF2800000 | hw << 21 | @as(u32, h) << 5 | dst.n());
        }
    }

    // -----------------------------------------------------------------
    // Memory

    /// Encodes a load or store. `size_log2` is the access size, `opc_u`
    /// the opcode with a scaled unsigned offset, and `opc_s` the opcode
    /// with an unscaled signed offset.
    fn mem(a: *Assembler, rt: u32, m: Mem, size_log2: u5, opc_u: u32, opc_s: u32) void {
        const scale = @as(i32, 1) << size_log2;
        if (m.disp >= 0 and @mod(m.disp, scale) == 0 and @divExact(m.disp, scale) < 4096) {
            a.word(opc_u | @as(u32, @intCast(@divExact(m.disp, scale))) << 10 | m.base.n() << 5 | rt);
        } else if (m.disp >= -256 and m.disp < 256) {
            a.word(opc_s | (@as(u32, @bitCast(m.disp)) & 0x1FF) << 12 | m.base.n() << 5 | rt);
        } else {
            // The address does not fit an offset form.
            a.movImm(s1, @bitCast(@as(i64, m.disp)));
            a.word(0x8B000000 | s1.n() << 16 | m.base.n() << 5 | s1.n());
            a.word(opc_u | s1.n() << 5 | rt);
        }
    }

    pub fn load64(a: *Assembler, dst: Reg, m: Mem) void {
        a.mem(dst.n(), m, 3, 0xF9400000, 0xF8400000);
    }
    pub fn store64(a: *Assembler, src: Reg, m: Mem) void {
        a.mem(src.n(), m, 3, 0xF9000000, 0xF8000000);
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
        a.mem(dst.n(), m, 2, 0xB9400000, 0xB8400000);
    }
    pub fn store32(a: *Assembler, src: Reg, m: Mem) void {
        a.mem(src.n(), m, 2, 0xB9000000, 0xB8000000);
    }
    /// Loads one byte, zero-extended.
    pub fn load8(a: *Assembler, dst: Reg, m: Mem) void {
        a.mem(dst.n(), m, 0, 0x39400000, 0x38400000);
    }
    pub fn store8(a: *Assembler, src: Reg, m: Mem) void {
        a.mem(src.n(), m, 0, 0x39000000, 0x38000000);
    }
    /// Loads 16 bits, zero-extended.
    pub fn load16(a: *Assembler, dst: Reg, m: Mem) void {
        a.mem(dst.n(), m, 1, 0x79400000, 0x78400000);
    }
    pub fn store16(a: *Assembler, src: Reg, m: Mem) void {
        a.mem(src.n(), m, 1, 0x79000000, 0x78000000);
    }
    pub fn storeImm16(a: *Assembler, m: Mem, v: u16) void {
        if (v == 0) return a.store16(zr, m);
        a.movImm(s0, v);
        a.store16(s0, m);
    }
    /// Stores two 64-bit registers at `m` and `m + 8`.
    pub fn storePair64(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        if (pairable(m.disp)) {
            a.word(0xA9000000 | pairOffset(m.disp) | second.n() << 10 | m.base.n() << 5 | first.n());
        } else {
            a.store64(first, m);
            a.store64(second, .{ .base = m.base, .disp = m.disp + 8 });
        }
    }
    /// Stores the low halves of two registers at `m` and `m + 4`.
    pub fn storePair32(a: *Assembler, first: Reg, second: Reg, m: Mem) void {
        if (m.disp >= -256 and m.disp <= 252 and @mod(m.disp, 4) == 0) {
            const off = (@as(u32, @bitCast(@divExact(m.disp, 4))) & 0x7F) << 15;
            a.word(0x29000000 | off | second.n() << 10 | m.base.n() << 5 | first.n());
        } else {
            a.store32(first, m);
            a.store32(second, .{ .base = m.base, .disp = m.disp + 4 });
        }
    }
    /// The register that reads as zero in `storePair64` and `storePair32`.
    pub const zero_reg: ?Reg = zr;
    pub fn loadF(a: *Assembler, dst: FReg, m: Mem) void {
        a.mem(dst.n(), m, 3, 0xFD400000, 0xFC400000);
    }
    pub fn storeF(a: *Assembler, src: FReg, m: Mem) void {
        a.mem(src.n(), m, 3, 0xFD000000, 0xFC000000);
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
        if (v == 0) return a.store64(zr, m);
        a.movImm(s0, v);
        a.store64(s0, m);
    }
    pub fn storeImm32(a: *Assembler, m: Mem, v: u32) void {
        if (v == 0) return a.store32(zr, m);
        a.movImm(s0, v);
        a.store32(s0, m);
    }
    /// Prepares `zero16`, which may then run any number of times before
    /// the next copy or call.
    pub fn zeroPrepare(a: *Assembler) void {
        a.word(0x6F00E400 | 31); // movi v31.2d, #0
    }
    /// Clears 16 bytes with one store.
    pub fn zero16(a: *Assembler, m: Mem) void {
        a.mem(31, m, 4, 0x3D800000, 0x3C800000);
    }
    /// Copies 16 bytes as two 64-bit words. A value is often written as
    /// two words just before it is copied, and a 16-byte load would wait
    /// for both of those stores to leave the store buffer.
    pub fn copy16(a: *Assembler, dst: Mem, src: Mem) void {
        if (pairable(src.disp)) {
            a.word(0xA9400000 | pairOffset(src.disp) | s1.n() << 10 | src.base.n() << 5 | s0.n());
        } else {
            a.load64(s0, src);
            a.load64(s1, .{ .base = src.base, .disp = src.disp + 8 });
        }
        if (pairable(dst.disp)) {
            a.word(0xA9000000 | pairOffset(dst.disp) | s1.n() << 10 | dst.base.n() << 5 | s0.n());
        } else {
            a.store64(s0, dst);
            a.store64(s1, .{ .base = dst.base, .disp = dst.disp + 8 });
        }
    }
    fn pairable(disp: i32) bool {
        return disp >= -512 and disp <= 504 and @mod(disp, 8) == 0;
    }
    fn pairOffset(disp: i32) u32 {
        return (@as(u32, @bitCast(@divExact(disp, 8))) & 0x7F) << 15;
    }
    /// dst = base + disp.
    pub fn lea(a: *Assembler, dst: Reg, m: Mem) void {
        if (m.disp >= 0 and m.disp < 4096) {
            a.word(0x91000000 | @as(u32, @intCast(m.disp)) << 10 | m.base.n() << 5 | dst.n());
        } else if (m.disp < 0 and m.disp > -4096) {
            a.word(0xD1000000 | @as(u32, @intCast(-m.disp)) << 10 | m.base.n() << 5 | dst.n());
        } else {
            a.movImm(s1, @bitCast(@as(i64, m.disp)));
            a.word(0x8B000000 | s1.n() << 16 | m.base.n() << 5 | dst.n());
        }
    }
    /// dst = b + (index << shift).
    pub fn addScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.word(0x8B000000 | index.n() << 16 | @as(u32, shift) << 10 | b.n() << 5 | dst.n());
    }
    /// dst = b - (index << shift).
    pub fn subScaled(a: *Assembler, dst: Reg, b: Reg, index: Reg, shift: u6) void {
        a.word(0xCB000000 | index.n() << 16 | @as(u32, shift) << 10 | b.n() << 5 | dst.n());
    }

    // -----------------------------------------------------------------
    // Integer arithmetic. Each operation computes dst = dst op src.

    pub fn add(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0x8B000000 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn sub(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0xCB000000 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn mul(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0x9B007C00 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn @"and"(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0x8A000000 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn @"or"(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0xAA000000 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn xor(a: *Assembler, dst: Reg, src: Reg) void {
        a.word(0xCA000000 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn neg(a: *Assembler, dst: Reg) void {
        a.word(0xCB0003E0 | dst.n() << 16 | dst.n());
    }
    pub fn not(a: *Assembler, dst: Reg) void {
        a.word(0xAA2003E0 | dst.n() << 16 | dst.n());
    }
    pub fn addImm(a: *Assembler, dst: Reg, v: i32) void {
        if (v == 0) return;
        const m: u32 = @abs(v);
        if (m < 4096) {
            a.word((if (v > 0) @as(u32, 0x91000000) else 0xD1000000) | m << 10 | dst.n() << 5 | dst.n());
        } else {
            a.movImm(s1, @bitCast(@as(i64, v)));
            a.add(dst, s1);
        }
    }
    /// Signed division and remainder that truncate toward zero. The
    /// divisor is neither zero nor minus one.
    pub fn divRem(a: *Assembler, quot: Reg, rem: Reg, x: Reg, y: Reg) void {
        a.word(0x9AC00C00 | y.n() << 16 | x.n() << 5 | s0.n());
        // rem = x - quot * y
        a.word(0x9B008000 | y.n() << 16 | x.n() << 10 | s0.n() << 5 | rem.n());
        a.mov(quot, s0);
    }

    // -----------------------------------------------------------------
    // Floats

    pub fn fadd(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E602800 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn fsub(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E603800 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn fmul(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E600800 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    pub fn fdiv(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E601800 | src.n() << 16 | dst.n() << 5 | dst.n());
    }
    /// Converts a signed integer to a float.
    pub fn intToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(0x9E620000 | src.n() << 5 | dst.n());
    }
    /// Moves the bits of an integer register into a float register.
    pub fn bitsToFloat(a: *Assembler, dst: FReg, src: Reg) void {
        a.word(0x9E670000 | src.n() << 5 | dst.n());
    }
    pub fn floatToBits(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(0x9E660000 | src.n() << 5 | dst.n());
    }

    pub fn fmov(a: *Assembler, dst: FReg, src: FReg) void {
        if (dst == src) return;
        a.word(0x1E604000 | src.n() << 5 | dst.n());
    }
    pub fn fneg(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E614000 | src.n() << 5 | dst.n());
    }
    pub fn fabs(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E60C000 | src.n() << 5 | dst.n());
    }
    pub fn fsqrt(a: *Assembler, dst: FReg, src: FReg) void {
        a.word(0x1E61C000 | src.n() << 5 | dst.n());
    }
    /// Rounds toward minus infinity, or toward plus infinity.
    pub fn fround(a: *Assembler, dst: FReg, src: FReg, up: bool) void {
        a.word((if (up) @as(u32, 0x1E64C000) else 0x1E654000) | src.n() << 5 | dst.n());
    }
    pub const has_fround = true;
    /// Converts a float to a signed integer, truncating.
    pub fn floatToInt(a: *Assembler, dst: Reg, src: FReg) void {
        a.word(0x9E780000 | src.n() << 5 | dst.n());
    }

    // Three-operand forms: dst = x op y.
    pub fn add3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0x8B000000 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn sub3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0xCB000000 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn mul3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0x9B007C00 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn and3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0x8A000000 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn or3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0xAA000000 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn xor3(a: *Assembler, dst: Reg, x: Reg, y: Reg) void {
        a.word(0xCA000000 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn fadd3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(0x1E602800 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn fsub3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(0x1E603800 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn fmul3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(0x1E600800 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    pub fn fdiv3(a: *Assembler, dst: FReg, x: FReg, y: FReg) void {
        a.word(0x1E601800 | y.n() << 16 | x.n() << 5 | dst.n());
    }
    /// dst = x + v.
    pub fn addImm3(a: *Assembler, dst: Reg, x: Reg, v: i32) void {
        a.lea(dst, .{ .base = x, .disp = v });
    }
    /// Loads and stores of the word at [b + index * 8].
    pub fn loadIdx64(a: *Assembler, dst: Reg, b: Reg, index: Reg) void {
        a.word(0xF8607800 | index.n() << 16 | b.n() << 5 | dst.n());
    }
    pub fn storeIdx64(a: *Assembler, src: Reg, b: Reg, index: Reg) void {
        a.word(0xF8207800 | index.n() << 16 | b.n() << 5 | src.n());
    }
    /// dst = x mod y or the floor of x / y, rounded toward minus
    /// infinity. The divisor is neither zero nor minus one. `tmp` is a
    /// free register other than the operands.
    pub fn floorDiv(a: *Assembler, dst: Reg, x: Reg, y: Reg, mod: bool, tmp: Reg, tmp2: Reg) void {
        _ = tmp2;
        a.word(0x9AC00C00 | y.n() << 16 | x.n() << 5 | s0.n());
        a.word(0x9B008000 | y.n() << 16 | x.n() << 10 | s0.n() << 5 | s1.n());
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.word(0xB4000000 | 4 << 5 | s1.n()); // cbz s1, +4
        a.word(0xCA000000 | y.n() << 16 | s1.n() << 5 | tmp.n()); // eor tmp, s1, y
        a.word(0xB6F80000 | 2 << 5 | tmp.n()); // tbz tmp, #63, +2
        if (mod) {
            a.word(0x8B000000 | y.n() << 16 | s1.n() << 5 | s1.n());
        } else {
            a.word(0xD1000400 | s0.n() << 5 | s0.n()); // sub s0, s0, #1
        }
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
        if (v < 0) a.probe(-v);
        a.addImm(.sp, v);
    }
    /// Touches each page of the `size` bytes below the stack pointer in
    /// order, on Windows, where the system commits the stack of a thread
    /// one guard page at a time.
    fn probe(a: *Assembler, size: i32) void {
        if (builtin.os.tag != .windows) return;
        var off: i32 = 4096;
        while (off <= size) : (off += 4096) a.load64(s0, .{ .base = .sp, .disp = -off });
    }

    // -----------------------------------------------------------------
    // Control flow

    pub fn jmp(a: *Assembler, l: Label) void {
        a.fix(l, .b26);
        a.word(0x14000000);
    }
    pub fn jmpReg(a: *Assembler, r: Reg) void {
        a.word(0xD61F0000 | r.n() << 5);
    }
    fn bcond(a: *Assembler, c: Cond, l: Label) void {
        a.fix(l, .b19);
        a.word(0x54000000 | @as(u32, @backingInt(c)));
    }
    /// Branches when the two registers compare as `c`.
    pub fn jumpIf(a: *Assembler, c: Cond, x: Reg, y: Reg, l: Label) void {
        a.word(0xEB00001F | y.n() << 16 | x.n() << 5);
        a.bcond(c, l);
    }
    /// Branches when the register compares as `c` with a constant.
    pub fn jumpIfImm(a: *Assembler, c: Cond, x: Reg, v: i32, l: Label) void {
        if (v == 0 and (c == .eq or c == .ne)) {
            a.fix(l, .b19);
            return a.word((if (c == .eq) @as(u32, 0xB4000000) else 0xB5000000) | x.n());
        }
        if (v >= 0 and v < 4096) {
            a.word(0xF100001F | @as(u32, @intCast(v)) << 10 | x.n() << 5);
        } else if (v < 0 and v > -4096) {
            a.word(0xB100001F | @as(u32, @intCast(-v)) << 10 | x.n() << 5);
        } else {
            a.movImm(s1, @bitCast(@as(i64, v)));
            a.word(0xEB00001F | s1.n() << 16 | x.n() << 5);
        }
        a.bcond(c, l);
    }
    /// Branches when the low 32 bits of the register are zero or not.
    pub fn jumpIfZero32(a: *Assembler, x: Reg, zero: bool, l: Label) void {
        a.fix(l, .b19);
        a.word((if (zero) @as(u32, 0x34000000) else 0x35000000) | x.n());
    }
    /// Branches when the byte in memory compares as `c` with a constant.
    pub fn jumpIfByte(a: *Assembler, c: Cond, m: Mem, v: u8, l: Label) void {
        a.load8(s0, m);
        if (v == 0 and (c == .eq or c == .ne)) return a.jumpIfZero32(s0, c == .eq, l);
        a.word(0x7100001F | @as(u32, v) << 10 | s0.n() << 5);
        a.bcond(c, l);
    }
    /// Branches when bit `bit` of the byte in memory is set or clear.
    pub fn jumpIfBit(a: *Assembler, m: Mem, bit: u3, set: bool, l: Label) void {
        a.load8(s0, m);
        // A bit test reaches only 32 KB, so it skips over a plain jump.
        a.word((if (set) @as(u32, 0x36000000) else 0x37000000) | @as(u32, bit) << 19 | 2 << 5 | s0.n());
        a.jmp(l);
    }
    /// Branches when the floats compare as `c`.
    pub fn jumpIfFloat(a: *Assembler, c: FCond, x: FReg, y: FReg, l: Label) void {
        a.word(0x1E602000 | y.n() << 16 | x.n() << 5);
        a.bcond(switch (c) {
            .lt => .mi,
            .le => .ls,
            .eq => .eq,
            .nlt => .pl,
            .nle => .hi,
            .ne => .ne,
        }, l);
    }

    /// Calls a function at an absolute address.
    pub fn call(a: *Assembler, addr: usize) void {
        a.movImm(s0, addr);
        a.word(0xD63F0000 | s0.n() << 5);
    }
    /// Calls a function that takes five words. Every argument travels
    /// in a register on this target, as for `call`.
    pub const call5 = call;
    /// Declares that a register holds no value that later code reads.
    /// Every register of this target is whole, so nothing follows.
    pub inline fn dead(a: *Assembler, r: Reg) void {
        _ = a;
        _ = r;
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
        a.word(0x94000000);
    }
    /// Calls the routine whose address is in a register.
    pub fn callReg(a: *Assembler, r: Reg) void {
        a.word(0xD63F0000 | r.n() << 5);
    }
    /// Returns from a routine that made no call of its own.
    pub fn retLocal(a: *Assembler) void {
        a.word(0xD65F03C0);
    }
    /// dst = the address the running routine would return to, plus the
    /// length of the jump that follows every call of a call entry.
    pub fn linkPastJump(a: *Assembler, dst: Reg) void {
        a.word(0x91000000 | 4 << 10 | @as(u32, 30) << 5 | dst.n());
    }
    /// Forgets the return address of the running routine, which then
    /// leaves by a jump.
    pub fn dropLink(a: *Assembler) void {
        _ = a;
    }
    /// Opens a native frame of `size` bytes whose top word holds the
    /// return address of the running routine.
    pub fn saveLink(a: *Assembler, size: i32) void {
        a.probe(size);
        a.addImm(.sp, -size);
        a.store64(.x30, .{ .base = .sp, .disp = size - 8 });
    }
    /// Closes a frame that `saveLink` opened. The return address is
    /// where a call left it.
    pub fn unsaveLink(a: *Assembler, size: i32) void {
        a.load64(.x30, .{ .base = .sp, .disp = size - 8 });
        a.addImm(.sp, size);
    }
    /// Closes a frame that `saveLink` opened and returns.
    pub fn leaveLink(a: *Assembler, size: i32) void {
        a.unsaveLink(size);
        a.word(0xD65F03C0);
    }
    /// Sets the native stack pointer.
    pub fn setSp(a: *Assembler, src: Reg) void {
        a.word(0x9100001F | src.n() << 5);
    }
    /// Branches when the register compares as `c` with a 64-bit word in
    /// memory.
    pub fn jumpIfMem(a: *Assembler, c: Cond, x: Reg, m: Mem, l: Label) void {
        a.load64(s0, m);
        a.jumpIf(c, x, s0, l);
    }
    /// Opens a routine entered by `callLocal` that calls other functions.
    pub fn enterLocal(a: *Assembler) void {
        a.store64(.x30, .{ .base = .sp, .disp = link_slot });
    }
    /// Returns from a routine opened by `enterLocal`.
    pub fn leaveLocal(a: *Assembler) void {
        a.load64(.x30, .{ .base = .sp, .disp = link_slot });
        a.word(0xD65F03C0);
    }
    pub fn trap(a: *Assembler) void {
        a.word(0xD4200000);
    }

    /// The entry sequence, called as a C function with the thread, the
    /// stop depth, the address to continue at, and the frame base. It
    /// saves the pinned registers and loads them.
    pub fn prologue(a: *Assembler) void {
        a.word(0xA9BC7BFD); // stp x29, x30, [sp, #-64]!
        a.word(0x910003FD); // mov x29, sp
        a.word(0xA90153F3); // stp x19, x20, [sp, #16]
        a.word(0xA9025BF5); // stp x21, x22, [sp, #32]
        a.mov(thread, .x0);
        a.mov(stop, .x1);
        a.mov(base, .x3);
    }
    /// Returns to the caller of the entry sequence with the status in the
    /// first result register.
    pub fn epilogue(a: *Assembler) void {
        a.word(0xA94153F3); // ldp x19, x20, [sp, #16]
        a.word(0xA9425BF5); // ldp x21, x22, [sp, #32]
        a.word(0xA8C47BFD); // ldp x29, x30, [sp], #64
        a.word(0xD65F03C0); // ret
    }
};

comptime {
    std.debug.assert(frame_size == 64);
    // macOS and Windows reserve x18 for the system.
    for ([_]Reg{ thread, bp, base, stop, t0, t1, t2, t3, t4, t5, t6, s0, s1, entry_target } ++ args) |r| std.debug.assert(r != .x18);
}

fn expectWords(a: *Assembler, expected: []const u32) !void {
    const got = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |w, i| try std.testing.expectEqual(w, std.mem.littleToNative(u32, got[i]));
}

test "aarch64 moves and immediates" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.mov(.x0, .x19); // mov x0, x19
    a.movImm(.x1, 0); // mov x1, #0
    a.movImm(.x9, 0x1234); // mov x9, #0x1234
    a.movImm(.x9, 0x1_0000_0001); // movz x9, #1; movk x9, #1, lsl #32
    a.movImm(.x9, @bitCast(@as(i64, -2))); // movn x9, #1
    try expectWords(&a, &.{ 0xAA1303E0, 0xD2800001, 0xD2824689, 0xD2800029, 0xF2C00029, 0x92800029 });
}

test "aarch64 memory forms" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load64(.x9, .{ .base = .x20, .disp = 16 }); // ldr x9, [x20, #16]
    a.store64(.x9, .{ .base = .x20, .disp = 24 }); // str x9, [x20, #24]
    a.load64(.x9, .{ .base = .x20, .disp = -16 }); // ldur x9, [x20, #-16]
    a.load8(.x10, .{ .base = .x20, .disp = 8 }); // ldrb w10, [x20, #8]
    a.load32(.x10, .{ .base = .x19, .disp = 4 }); // ldr w10, [x19, #4]
    a.copy16(.{ .base = .x20, .disp = 32 }, .{ .base = .x20, .disp = 48 }); // ldp x16, x17, [x20, #48]; stp x16, x17, [x20, #32]
    a.loadF(.v0, .{ .base = .x20, .disp = 0 }); // ldr d0, [x20]
    try expectWords(&a, &.{ 0xF9400A89, 0xF9000E89, 0xF85F0289, 0x3940228A, 0xB940066A, 0xA9434690, 0xA9024690, 0xFD400280 });
}

test "aarch64 sixteen-bit forms and pairs" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.load16(.x9, .{ .base = .x20, .disp = 2 }); // ldrh w9, [x20, #2]
    a.store16(.x9, .{ .base = .x20, .disp = 2 }); // strh w9, [x20, #2]
    a.storeImm16(.{ .base = .x9, .disp = 2 }, 0); // strh wzr, [x9, #2]
    a.storePair64(.x9, .x10, .{ .base = .x20, .disp = 16 }); // stp x9, x10, [x20, #16]
    a.storePair64(.x9, Assembler.zero_reg.?, .{ .base = .x20, .disp = 16 }); // stp x9, xzr, [x20, #16]
    a.storePair32(.x9, .x10, .{ .base = .x20, .disp = 16 }); // stp w9, w10, [x20, #16]
    try expectWords(&a, &.{ 0x79400689, 0x79000689, 0x7900053F, 0xA9012A89, 0xA9017E89, 0x29022A89 });
}

test "aarch64 arithmetic" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.add(.x9, .x10); // add x9, x9, x10
    a.sub(.x9, .x10); // sub x9, x9, x10
    a.mul(.x9, .x10); // mul x9, x9, x10
    a.addImm(.x9, 5); // add x9, x9, #5
    a.addImm(.x9, -5); // sub x9, x9, #5
    a.neg(.x9); // neg x9, x9
    a.fadd(.v0, .v1); // fadd d0, d0, d1
    a.intToFloat(.v0, .x9); // scvtf d0, x9
    a.addScaled(.x20, .x9, .x21, 4); // add x20, x9, x21, lsl #4
    try expectWords(&a, &.{ 0x8B0A0129, 0xCB0A0129, 0x9B0A7D29, 0x91001529, 0xD1001529, 0xCB0903E9, 0x1E612800, 0x9E620120, 0x8B151134 });
}

test "aarch64 branches resolve in both directions" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const top = a.newLabel();
    const end = a.newLabel();
    a.bind(top);
    a.jumpIf(.lt, .x9, .x10, end); // cmp x9, x10; b.lt end
    a.jumpIfImm(.eq, .x9, 0, top); // cbz x9, top
    a.jmp(top); // b top
    a.bind(end);
    a.epilogue();
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    try std.testing.expectEqual(@as(u32, 0xEB0A013F), w[0]);
    try std.testing.expectEqual(@as(u32, 0x5400006B), w[1]); // b.lt +3
    try std.testing.expectEqual(@as(u32, 0xB4FFFFC9), w[2]); // cbz x9, -2
    try std.testing.expectEqual(@as(u32, 0x17FFFFFD), w[3]); // b -3
}

test "aarch64 unbound label fails" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.jmp(a.newLabel());
    try std.testing.expect(!a.finish());
}

test "aarch64 wide constants load from the pool" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.movImm(.x9, 0x1122334455667788); // ldr x9, pool[0]
    a.movImm(.x10, 0x1122334455667788); // ldr x10, pool[0]
    a.movImm(.x11, 0x0000123456789ABC); // ldr x11, pool[1]
    a.epilogue();
    try std.testing.expect(a.finish());
    const w = std.mem.bytesAsSlice(u32, a.buf.items);
    // Seven instructions, one word of padding, then the pool at byte 32.
    try std.testing.expectEqual(@as(u32, 0x58000109), w[0]);
    try std.testing.expectEqual(@as(u32, 0x580000EA), w[1]);
    try std.testing.expectEqual(@as(u32, 0x5800010B), w[2]);
    try std.testing.expectEqual(@as(u32, 0x55667788), w[8]);
    try std.testing.expectEqual(@as(u32, 0x11223344), w[9]);
    try std.testing.expectEqual(@as(u32, 0x56789ABC), w[10]);
}

test "aarch64 loads an address through a slot in the static form" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.aot = true;
    a.static = true;
    a.movImmReloc(.x9, 0x1122334455667788, .{ .kind = .routine, .a = 3 });
    a.trap();
    try std.testing.expect(a.finish());
    try std.testing.expectEqual(@as(usize, 1), a.relocs.items.len);
    const e = a.relocs.items[0];
    try std.testing.expectEqual(reloc.Form.slot, e.form);
    // adr x9 points at the pool word, and ldr x9, [x9] follows.
    const t = reloc.slotTarget(a.buf.items, e.at).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), std.mem.readInt(u64, a.buf.items[t..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0xF9400129), std.mem.readInt(u32, a.buf.items[e.at + 4 ..][0..4], .little));
    reloc.apply(a.buf.items, e, 0xAABB);
    try std.testing.expectEqual(@as(u64, 0xAABB), std.mem.readInt(u64, a.buf.items[t..][0..8], .little));
}
