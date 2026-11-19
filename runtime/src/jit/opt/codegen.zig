//! Turns the intermediate representation into machine code. One code
//! generator serves both targets: it is written against the assembler
//! interface that `a64.zig` and `x64.zig` share.
//!
//! Optimized code keeps the four pinned registers of the baseline code,
//! so the two kinds of code jump to each other freely. On top of that it
//! owns a block of the native stack for values that found no register,
//! which it leaves before every transfer to other code. An instruction
//! that the builder left to its baseline template is emitted through the
//! baseline emitter itself.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const regalloc = @import("regalloc.zig");
const opt = @import("opt.zig");
const emit = @import("../emit.zig");
const state = @import("../../vm/state.zig");
const object = @import("../../vm/object.zig");
const value = @import("../../vm/value.zig");
const table = @import("../../vm/table.zig");
const gc = @import("../../vm/gc.zig");
const interp = @import("../../vm/interp.zig");
const Thread = state.Thread;
const Proto = object.Proto;
const Tag = value.Tag;
const Ref = ir.Ref;
const BlockId = ir.BlockId;
const A = emit.A;
const Mem = A.Mem;
const Label = A.Label;
const Loc = regalloc.Loc;
const tl = table.layout;

const is_a64 = builtin.cpu.arch == .aarch64;

/// The registers that hold values. Every one of them belongs to the
/// callee across a call into the runtime.
pub const gpr_pool: []const A.Reg = if (is_a64)
    &.{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9, .x10, .x11, .x12 }
else
    &.{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9 };
pub const fpr_pool: []const A.FReg = if (is_a64)
    &.{ .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7, .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23 }
else
    &.{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };
/// Scratch registers of the code generator. On x86-64 they are the two
/// callee-saved registers that the entry sequence saves and baseline code
/// leaves alone.
const sc0: A.Reg = if (is_a64) .x13 else .rbp;
const sc1: A.Reg = if (is_a64) .x14 else .r13;
const sc2: A.Reg = if (is_a64) .x15 else .r13;
const fsc0: A.FReg = if (is_a64) .v30 else .xmm13;
const fsc1: A.FReg = if (is_a64) .v29 else .xmm12;
const fret: A.FReg = if (is_a64) .v0 else .xmm0;

/// Bytes that the exit sequence saves the pool registers in.
pub const save_bytes: i32 = @intCast(std.mem.alignForward(usize, (gpr_pool.len + fpr_pool.len) * 8, 16));

/// A place a move reads or writes.
const Place = union(enum) {
    g: A.Reg,
    f: A.FReg,
    spill: u32,
    imm: u64,
    fimm: u64,
};

const Move = struct {
    dst: Place,
    src: Place,
    float: bool,
};

const Stub = struct {
    entry: Label,
    back: Label,
    inst: Ref,
};

pub const Codegen = struct {
    em: emit.Emitter,
    f: *ir.Func,
    ra: regalloc.Result,
    arena: std.mem.Allocator,
    p: *Proto,
    l: *Thread,
    unit: *opt.Unit,
    labels: []Label,
    /// Native stack bytes of the spilled values.
    frame: i32,
    /// One exit stub per snapshot.
    exit_labels: []Label,
    stubs: std.ArrayList(Stub) = .empty,
    l_deopt: Label = 0,
    l_trap: Label = 0,
    l_entry: Label = 0,
    /// Where the templates of the instruction being emitted continue.
    gen_targets: []const ir.GenTarget = &.{},
    gen_labels: [4]Label = @splat(0),
    redirect: emit.Emitter.Redirect = undefined,
    /// Offsets in the global state that the collector check reads.
    gc_bytes: i32,
    gc_next: i32,
    entry_off: u32 = 0,

    pub fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, l: *Thread, p: *Proto, f: *ir.Func, ra: regalloc.Result, unit: *opt.Unit) !Codegen {
        const gs = l.g;
        return .{
            .em = emit.Emitter.init(gpa, l, p),
            .f = f,
            .ra = ra,
            .arena = arena,
            .p = p,
            .l = l,
            .unit = unit,
            .labels = try arena.alloc(Label, f.blocks.items.len),
            .frame = @intCast(std.mem.alignForward(usize, @as(usize, ra.nspill) * 8, 16)),
            .exit_labels = try arena.alloc(Label, f.snaps.items.len),
            .gc_bytes = @intCast(@intFromPtr(&gs.counter.bytes) - @intFromPtr(gs)),
            .gc_next = @intCast(@intFromPtr(&gs.gcs.next_check) - @intFromPtr(gs)),
        };
    }

    pub fn deinit(c: *Codegen) void {
        c.em.deinit();
    }

    fn redirectTarget(ctx: *anyopaque, from: u32, to: u32) Label {
        const c: *Codegen = @ptrCast(@alignCast(ctx));
        _ = from;
        for (c.gen_targets, 0..) |t, i| {
            if (t.pc == to) return c.gen_labels[i];
        }
        return c.l_trap;
    }

    /// Emits the whole function. Returns false when the code is
    /// unusable.
    pub fn run(c: *Codegen) bool {
        const a = &c.em.a;
        const f = c.f;
        c.redirect = .{ .ctx = c, .target = &redirectTarget };
        c.em.redirect = &c.redirect;
        c.em.count = false;
        c.em.statusTail();
        c.em.scan();
        for (c.labels) |*x| x.* = a.newLabel();
        for (c.exit_labels) |*x| x.* = a.newLabel();
        c.l_deopt = a.newLabel();
        c.l_trap = a.newLabel();
        c.l_entry = a.newLabel();

        // The entries that calls from native code use run into the body.
        if (!c.p.is_vararg and c.unit.entry_pc == 0) {
            c.em.first = c.l_entry;
            c.em.tailEntry();
            c.em.callEntry();
            a.jmp(c.l_entry);
        }
        // The body starts with the frame in place and every register in
        // its slot.
        a.bind(c.l_entry);
        c.entry_off = a.offset();
        if (f.extent > c.p.max_stack or f.depth > 0 or f.scratch > 0) c.roomCheck();
        if (c.frame != 0) a.moveSp(-c.frame);
        a.jmp(c.labels[f.entry]);

        for (c.ra.order, 0..) |b, oi| {
            a.bind(c.labels[b]);
            const next: ?BlockId = if (oi + 1 < c.ra.order.len) c.ra.order[oi + 1] else null;
            for (f.blocks.items[b].insts.items) |r| c.inst(b, r, next);
            if (a.offset() > 512 * 1024) return false;
        }
        // Blocks that nothing reaches still own labels.
        const reached = c.arena.alloc(bool, c.labels.len) catch return false;
        @memset(reached, false);
        for (c.ra.order) |b| reached[b] = true;
        a.bind(c.l_trap);
        for (reached, 0..) |r, b| {
            if (!r) a.bind(c.labels[b]);
        }
        a.trap();

        for (c.stubs.items) |s| c.stub(s);
        // Exits. Each names its snapshot and joins the common sequence.
        for (c.exit_labels, 0..) |lab, sid| {
            a.bind(lab);
            a.movImm(sc0, sid);
            a.jmp(c.l_deopt);
        }
        a.bind(c.l_deopt);
        c.saveAll();
        a.mov(A.args[0], A.thread);
        a.mov(A.args[2], sc0);
        a.movImm(A.args[1], @intFromPtr(c.unit));
        a.leaSp(A.args[3], 0);
        a.call(@intFromPtr(&opt.rt.deopt));
        a.moveSp(save_bytes + c.frame);
        const l_interp = a.newLabel();
        const l_failed = a.newLabel();
        a.jumpIfImm(.eq, A.ret0, 0, l_interp);
        a.jumpIfImm(.eq, A.ret0, @intCast(opt.failed), l_failed);
        a.mov(A.base, A.ret1);
        c.em.reloadBp();
        a.jmpReg(A.ret0);
        a.bind(l_interp);
        a.movImm(A.ret0, interp.Step.interpret);
        a.jmp(c.em.l_exit);
        a.bind(l_failed);
        a.movImm(A.ret0, interp.Step.failed);
        a.jmp(c.em.l_exit);

        c.em.flushCold();
        if (c.em.oom) return false;
        return a.finish();
    }

    /// Leaves for baseline code at once when the stack or the frame
    /// list lacks room for the frames of the calls compiled inline.
    fn roomCheck(c: *Codegen) void {
        const a = &c.em.a;
        const lay = c.em.lay;
        const bail = a.newLabel();
        const ok = a.newLabel();
        a.lea(sc0, .{ .base = A.base, .disp = @intCast(c.f.extent + c.f.scratch + 16) });
        a.jumpIfMem(.hi, sc0, .{ .base = A.thread, .disp = lay.stack_len }, bail);
        a.load64(sc0, .{ .base = A.thread, .disp = lay.frames_len });
        a.addImm(sc0, @intCast(c.f.depth + 1));
        a.jumpIfMem(.ls, sc0, .{ .base = A.thread, .disp = lay.frames_cap }, ok);
        a.bind(bail);
        a.mov(A.args[0], A.thread);
        a.call(@intFromPtr(&opt.rt.bail));
        const l_interp = a.newLabel();
        a.jumpIfImm(.eq, A.ret0, 0, l_interp);
        a.mov(A.base, A.ret1);
        c.em.reloadBp();
        a.jmpReg(A.ret0);
        a.bind(l_interp);
        a.movImm(A.ret0, interp.Step.interpret);
        a.jmp(c.em.l_exit);
        a.bind(ok);
    }

    // -----------------------------------------------------------------
    // Places

    fn slot(s: i64) Mem {
        return .{ .base = A.bp, .disp = @intCast(s * 16) };
    }
    fn tagOf(s: i64) Mem {
        return .{ .base = A.bp, .disp = @intCast(s * 16 + 8) };
    }
    fn spillMem(k: u32) Mem {
        return .{ .base = A.sp, .disp = @intCast(k * 8) };
    }

    fn place(c: *Codegen, r: Ref) Place {
        const i = c.f.at(r);
        switch (i.op) {
            .kint, .kptr, .kbool => return .{ .imm = @bitCast(i.imm) },
            .kflt => return .{ .fimm = @bitCast(i.imm) },
            .knil => return .{ .imm = 0 },
            else => {},
        }
        return switch (c.ra.loc[r]) {
            .reg => |x| .{ .g = gpr_pool[x] },
            .freg => |x| .{ .f = fpr_pool[x] },
            .spill => |k| .{ .spill = k },
            .none => .{ .imm = 0 },
        };
    }

    /// The register that holds the integer or pointer `r`, which is
    /// `scratch` when the value is a constant or lives on the stack.
    fn g(c: *Codegen, r: Ref, scratch: A.Reg) A.Reg {
        const a = &c.em.a;
        switch (c.place(r)) {
            .g => |x| return x,
            .spill => |k| a.load64(scratch, spillMem(k)),
            .imm => |v| a.movImm(scratch, v),
            .fimm => |v| a.movImm(scratch, v),
            .f => |x| a.floatToBits(scratch, x),
        }
        return scratch;
    }

    fn fl(c: *Codegen, r: Ref, scratch: A.FReg) A.FReg {
        const a = &c.em.a;
        switch (c.place(r)) {
            .f => |x| return x,
            .spill => |k| a.loadF(scratch, spillMem(k)),
            .fimm, .imm => |v| a.fmovImm(scratch, v),
            .g => |x| a.bitsToFloat(scratch, x),
        }
        return scratch;
    }

    /// The register to compute the integer result of `r` in.
    fn dst(c: *Codegen, r: Ref) A.Reg {
        return switch (c.ra.loc[r]) {
            .reg => |x| gpr_pool[x],
            else => sc0,
        };
    }
    fn fdst(c: *Codegen, r: Ref) A.FReg {
        return switch (c.ra.loc[r]) {
            .freg => |x| fpr_pool[x],
            else => fsc0,
        };
    }
    /// Stores a result that lives on the stack.
    fn done(c: *Codegen, r: Ref, reg: A.Reg) void {
        switch (c.ra.loc[r]) {
            .spill => |k| c.em.a.store64(reg, spillMem(k)),
            else => {},
        }
    }
    fn fdone(c: *Codegen, r: Ref, reg: A.FReg) void {
        switch (c.ra.loc[r]) {
            .spill => |k| c.em.a.storeF(reg, spillMem(k)),
            else => {},
        }
    }

    fn cond(x: u8) A.Cond {
        const cc: ir.Cond = @fromBackingInt(x);
        return switch (cc) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .lo => .lo,
            .ls => .ls,
            .hi => .hi,
            .hs => .hs,
        };
    }

    fn fitsImm(v: i64) bool {
        return v >= std.math.minInt(i32) and v <= std.math.maxInt(i32);
    }

    fn exitOf(c: *Codegen, i: *const ir.Inst) Label {
        return c.exit_labels[i.snap];
    }

    // -----------------------------------------------------------------
    // Moves

    fn samePlace(x: Place, y: Place) bool {
        return switch (x) {
            .g => |r| y == .g and y.g == r,
            .f => |r| y == .f and y.f == r,
            .spill => |k| y == .spill and y.spill == k,
            else => false,
        };
    }

    fn move(c: *Codegen, m: Move) void {
        const a = &c.em.a;
        if (m.float) {
            switch (m.dst) {
                .f => |d| switch (m.src) {
                    .f => |s| a.fmov(d, s),
                    .spill => |k| a.loadF(d, spillMem(k)),
                    .fimm, .imm => |v| a.fmovImm(d, v),
                    .g => |s| a.bitsToFloat(d, s),
                },
                .spill => |dk| switch (m.src) {
                    .f => |s| a.storeF(s, spillMem(dk)),
                    .spill => |k| a.copy8(spillMem(dk), spillMem(k)),
                    .fimm, .imm => |v| a.storeImm64(spillMem(dk), v),
                    .g => |s| a.store64(s, spillMem(dk)),
                },
                else => unreachable,
            }
            return;
        }
        switch (m.dst) {
            .g => |d| switch (m.src) {
                .g => |s| a.mov(d, s),
                .spill => |k| a.load64(d, spillMem(k)),
                .imm, .fimm => |v| a.movImm(d, v),
                .f => |s| a.floatToBits(d, s),
            },
            .spill => |dk| switch (m.src) {
                .g => |s| a.store64(s, spillMem(dk)),
                .spill => |k| a.copy8(spillMem(dk), spillMem(k)),
                .imm, .fimm => |v| a.storeImm64(spillMem(dk), v),
                .f => |s| a.storeF(s, spillMem(dk)),
            },
            else => unreachable,
        }
    }

    /// Performs the moves as if all of them happened at once.
    fn parallel(c: *Codegen, moves: []Move) void {
        var n = moves.len;
        // Moves from a place to itself are done.
        var i: usize = 0;
        while (i < n) {
            if (samePlace(moves[i].dst, moves[i].src)) {
                moves[i] = moves[n - 1];
                n -= 1;
            } else i += 1;
        }
        while (n > 0) {
            var progress = false;
            i = 0;
            while (i < n) {
                var blocked = false;
                for (moves[0..n], 0..) |o, j| {
                    if (j != i and samePlace(o.src, moves[i].dst)) blocked = true;
                }
                if (blocked) {
                    i += 1;
                    continue;
                }
                c.move(moves[i]);
                moves[i] = moves[n - 1];
                n -= 1;
                progress = true;
            }
            if (!progress) {
                // A cycle. One destination moves aside, and its readers
                // read the copy.
                const m = moves[0];
                const aside: Place = if (m.float) .{ .f = fsc1 } else .{ .g = sc1 };
                c.move(.{ .dst = aside, .src = m.dst, .float = m.float });
                for (moves[0..n]) |*o| {
                    if (samePlace(o.src, m.dst)) o.src = aside;
                }
            }
        }
    }

    /// The moves that fill the phis of `to` on the edge from `from`.
    fn phiMoves(c: *Codegen, from: BlockId, to: BlockId) void {
        var buf: [64]Move = undefined;
        var n: usize = 0;
        for (c.f.blocks.items[to].insts.items) |r| {
            const p = c.f.at(r);
            if (p.op != .phi) break;
            if (c.ra.loc[r] == .none) continue;
            for (c.f.phi_args.items[p.a..][0..p.b]) |arg| {
                if (arg.pred != from) continue;
                if (n == buf.len) {
                    c.parallel(buf[0..n]);
                    n = 0;
                }
                buf[n] = .{ .dst = c.place(r), .src = c.place(arg.ref), .float = p.ty == .float };
                n += 1;
                break;
            }
        }
        c.parallel(buf[0..n]);
    }

    fn saveAll(c: *Codegen) void {
        const a = &c.em.a;
        a.moveSp(-save_bytes);
        for (gpr_pool, 0..) |r, i| a.store64(r, .{ .base = A.sp, .disp = @intCast(i * 8) });
        for (fpr_pool, 0..) |r, i| a.storeF(r, .{ .base = A.sp, .disp = @intCast((gpr_pool.len + i) * 8) });
    }

    fn restoreAll(c: *Codegen) void {
        const a = &c.em.a;
        for (gpr_pool, 0..) |r, i| a.load64(r, .{ .base = A.sp, .disp = @intCast(i * 8) });
        for (fpr_pool, 0..) |r, i| a.loadF(r, .{ .base = A.sp, .disp = @intCast((gpr_pool.len + i) * 8) });
        a.moveSp(save_bytes);
    }

    /// A value as an argument, read after `saveAll` moved the stack.
    fn argPlace(c: *Codegen, r: Ref, saved: bool) Place {
        const p = c.place(r);
        if (saved and p == .spill) return .{ .spill = p.spill + @as(u32, @intCast(@divExact(save_bytes, 8))) };
        return p;
    }

    // -----------------------------------------------------------------
    // Instructions

    fn inst(c: *Codegen, blk: BlockId, r: Ref, next: ?BlockId) void {
        const a = &c.em.a;
        const i = c.f.at(r);
        switch (i.op) {
            .nop, .knil, .kbool, .kint, .kflt, .kptr, .phi, .valloc => {},

            .sload => switch (i.ty) {
                .float => {
                    const d = c.fdst(r);
                    a.loadF(d, slot(i.imm));
                    c.fdone(r, d);
                },
                .boolean => {
                    const d = c.dst(r);
                    a.load8(d, tagOf(i.imm));
                    a.addImm(d, -@as(i32, @backingInt(Tag.false)));
                    c.done(r, d);
                },
                else => {
                    const d = c.dst(r);
                    a.load64(d, slot(i.imm));
                    c.done(r, d);
                },
            },
            .gslot => c.tagGuard(tagOf(i.imm), @intCast(i.aux), true, c.exitOf(i)),
            .sstore => c.storeTyped(.{ .base = A.bp, .disp = @intCast(i.imm * 16) }, i.a),
            .scopy => a.copy16(slot(i.imm), slot(@bitCast(i.aux))),

            .add, .sub, .mul, .band, .bor, .bxor => {
                const x = c.g(i.a, sc0);
                const y = c.g(i.b, sc1);
                const d = c.dst(r);
                switch (i.op) {
                    .add => a.add3(d, x, y),
                    .sub => a.sub3(d, x, y),
                    .mul => a.mul3(d, x, y),
                    .band => a.and3(d, x, y),
                    .bor => a.or3(d, x, y),
                    else => a.xor3(d, x, y),
                }
                c.done(r, d);
            },
            .addi => {
                const x = c.g(i.a, sc0);
                const d = c.dst(r);
                if (fitsImm(i.imm)) {
                    a.addImm3(d, x, @intCast(i.imm));
                } else {
                    a.movImm(sc1, @bitCast(i.imm));
                    a.add3(d, x, sc1);
                }
                c.done(r, d);
            },
            .neg, .bnot => {
                const x = c.g(i.a, sc0);
                const d = c.dst(r);
                a.mov(d, x);
                if (i.op == .neg) a.neg(d) else a.not(d);
                c.done(r, d);
            },
            .addsh => {
                const x = c.g(i.a, sc0);
                const y = c.g(i.b, sc1);
                const d = c.dst(r);
                a.addScaled(d, x, y, @intCast(i.imm));
                c.done(r, d);
            },
            .mod, .idiv, .modi, .idivi => {
                const x = c.g(i.a, sc0);
                var y: A.Reg = undefined;
                if (i.op == .modi or i.op == .idivi) {
                    a.movImm(sc1, @bitCast(i.imm));
                    y = sc1;
                } else y = c.g(i.b, sc1);
                const d = c.dst(r);
                if (is_a64) {
                    a.floorDiv(d, x, y, i.op == .mod or i.op == .modi, sc2, sc2);
                } else {
                    a.floorDiv(d, x, y, i.op == .mod or i.op == .modi, sc0, sc1);
                }
                c.done(r, d);
            },

            .fadd, .fsub, .fmul, .fdiv => {
                const x = c.fl(i.a, fsc0);
                const y = c.fl(i.b, fsc1);
                const d = c.fdst(r);
                switch (i.op) {
                    .fadd => a.fadd3(d, x, y),
                    .fsub => a.fsub3(d, x, y),
                    .fmul => a.fmul3(d, x, y),
                    else => a.fdiv3(d, x, y),
                }
                c.fdone(r, d);
            },
            .fneg, .fabs, .fsqrt, .ffloor, .fceil => {
                const x = c.fl(i.a, fsc0);
                const d = c.fdst(r);
                switch (i.op) {
                    .fneg => a.fneg(d, x),
                    .fabs => a.fabs(d, x),
                    .fsqrt => a.fsqrt(d, x),
                    .ffloor => a.fround(d, x, false),
                    else => a.fround(d, x, true),
                }
                c.fdone(r, d);
            },
            .i2f => {
                const x = c.g(i.a, sc0);
                const d = c.fdst(r);
                a.intToFloat(d, x);
                c.fdone(r, d);
            },
            .f2i => {
                const x = c.fl(i.a, fsc0);
                const d = c.dst(r);
                a.floatToInt(d, x);
                c.done(r, d);
            },
            .bits2f => {
                const x = c.g(i.a, sc0);
                const d = c.fdst(r);
                a.bitsToFloat(d, x);
                c.fdone(r, d);
            },
            .f2bits => {
                const x = c.fl(i.a, fsc0);
                const d = c.dst(r);
                a.floatToBits(d, x);
                c.done(r, d);
            },

            .load => {
                const base = c.g(i.a, sc0);
                const m: Mem = .{ .base = base, .disp = @intCast(i.imm) };
                if (i.ty == .float) {
                    const d = c.fdst(r);
                    a.loadF(d, m);
                    c.fdone(r, d);
                } else {
                    const d = c.dst(r);
                    switch (i.size) {
                        1 => a.load8(d, m),
                        2 => a.load16(d, m),
                        4 => a.load32(d, m),
                        else => a.load64(d, m),
                    }
                    c.done(r, d);
                }
            },
            .loadx => {
                const base = c.g(i.a, sc0);
                const idx = c.g(i.b, sc1);
                const d = c.dst(r);
                if (i.aux == 3 and i.imm == 0) {
                    a.loadIdx64(d, base, idx);
                } else {
                    a.addScaled(sc0, base, idx, @intCast(i.aux));
                    a.load64(d, .{ .base = sc0, .disp = @intCast(i.imm) });
                }
                c.done(r, d);
            },
            .store => {
                const base = c.g(i.a, sc0);
                const m: Mem = .{ .base = base, .disp = @intCast(i.imm) };
                const v = c.f.at(i.b);
                if (v.ty == .float and !v.isConst()) {
                    a.storeF(c.fl(i.b, fsc0), m);
                } else if (v.isConst() and i.size != 1) {
                    const bits: u64 = @bitCast(v.imm);
                    switch (i.size) {
                        2 => a.storeImm16(m, @truncate(bits)),
                        4 => a.storeImm32(m, @truncate(bits)),
                        else => a.storeImm64(m, bits),
                    }
                } else {
                    const x = c.g(i.b, sc1);
                    switch (i.size) {
                        1 => a.store8(x, m),
                        2 => a.store16(x, m),
                        4 => a.store32(x, m),
                        else => a.store64(x, m),
                    }
                }
            },
            .storex => {
                const base = c.g(i.a, sc0);
                const idx = c.g(i.b, sc1);
                if (i.aux == 3 and i.imm == 0 and is_a64) {
                    a.storeIdx64(c.g(i.c, sc2), base, idx);
                } else {
                    a.addScaled(sc0, base, idx, @intCast(i.aux));
                    a.store64(c.g(i.c, sc1), .{ .base = sc0, .disp = @intCast(i.imm) });
                }
            },
            .copy_m2s => {
                const base = c.g(i.a, sc0);
                a.copy16(slot(@bitCast(i.aux)), .{ .base = base, .disp = @intCast(i.imm) });
            },
            .copy_s2m => {
                const base = c.g(i.a, sc0);
                a.copy16(.{ .base = base, .disp = @intCast(i.imm) }, slot(@bitCast(i.aux)));
            },
            .copy_m2m => {
                const d = c.g(i.a, sc0);
                const s = c.g(i.b, sc1);
                a.copy16(.{ .base = d, .disp = @intCast(i.imm) }, .{ .base = s, .disp = @intCast(@as(i64, @bitCast(i.aux))) });
            },

            .guard => {
                const x = c.g(i.a, sc0);
                const y = c.g(i.b, sc1);
                a.jumpIf(cond(i.cond).invert(), x, y, c.exitOf(i));
            },
            .guardi => {
                const x = c.g(i.a, sc0);
                if (fitsImm(i.imm)) {
                    a.jumpIfImm(cond(i.cond).invert(), x, @intCast(i.imm), c.exitOf(i));
                } else {
                    a.movImm(sc1, @bitCast(i.imm));
                    a.jumpIf(cond(i.cond).invert(), x, sc1, c.exitOf(i));
                }
            },
            .gfcmp => {
                const x = c.fl(i.a, fsc0);
                const y = c.fl(i.b, fsc1);
                a.jumpIfFloat(fcond(i.cond, true), x, y, c.exitOf(i));
            },
            .gtag => {
                const base = c.g(i.a, sc0);
                c.tagGuard(.{ .base = base, .disp = @intCast(i.imm) }, @intCast(i.aux), i.cond == @backingInt(ir.Cond.eq), c.exitOf(i));
            },
            .gbit => {
                const base = c.g(i.a, sc0);
                const expect_set = (i.aux >> 8) & 1 != 0;
                a.jumpIfBit(.{ .base = base, .disp = @intCast(i.imm) }, @intCast(i.aux & 7), !expect_set, c.exitOf(i));
            },
            .gnokey => unreachable,
            .gpending => {
                a.load64(sc0, .{ .base = A.thread, .disp = c.em.lay.global });
                a.load64(sc0, .{ .base = sc0, .disp = c.em.lay.pending });
                a.jumpIfImm(.ne, sc0, 0, c.exitOf(i));
            },

            .gdebt => {
                const js = &c.l.g.jit;
                a.movImm(sc0, @intFromPtr(&js.sunk));
                a.load64(sc1, .{ .base = sc0 });
                a.addImm(sc1, @intCast(i.imm));
                a.store64(sc1, .{ .base = sc0 });
                a.jumpIfMem(.hs, sc1, .{ .base = sc0, .disp = @intCast(@as(isize, @bitCast(@intFromPtr(&js.sunk_limit) -% @intFromPtr(&js.sunk)))) }, c.exitOf(i));
            },
            .callc => c.callc(r, i),
            .barrier => {
                const s: Stub = .{ .entry = a.newLabel(), .back = a.newLabel(), .inst = r };
                c.stubs.append(c.arena, s) catch {
                    c.em.oom = true;
                };
                const obj = c.g(i.a, sc0);
                if (i.aux & 3 == 2) {
                    // A value in a slot needs the barrier when it is
                    // an object.
                    a.load8(sc1, tagOf(@intCast(i.aux >> 8)));
                    a.jumpIfImm(.lo, sc1, @backingInt(Tag.string), s.back);
                }
                a.jumpIfBit(.{ .base = obj, .disp = tl.flags }, tl.barrier_bit, true, s.entry);
                a.bind(s.back);
            },
            .gccheck => {
                const s: Stub = .{ .entry = a.newLabel(), .back = a.newLabel(), .inst = r };
                c.stubs.append(c.arena, s) catch {
                    c.em.oom = true;
                };
                if (gc_stress) {
                    a.jmp(s.entry);
                } else {
                    a.load64(sc0, .{ .base = A.thread, .disp = c.em.lay.global });
                    a.load64(sc1, .{ .base = sc0, .disp = c.gc_bytes });
                    a.jumpIfMem(.hs, sc1, .{ .base = sc0, .disp = c.gc_next }, s.entry);
                }
                a.bind(s.back);
            },

            .jmp => {
                c.phiMoves(blk, i.t);
                if (next == null or next.? != i.t) a.jmp(c.labels[i.t]);
            },
            .br => {
                const x = c.g(i.a, sc0);
                const y = c.g(i.b, sc1);
                a.jumpIf(cond(i.cond), x, y, c.labels[i.t]);
                if (next == null or next.? != i.f) a.jmp(c.labels[i.f]);
            },
            .bri => {
                const x = c.g(i.a, sc0);
                if (fitsImm(i.imm)) {
                    a.jumpIfImm(cond(i.cond), x, @intCast(i.imm), c.labels[i.t]);
                } else {
                    a.movImm(sc1, @bitCast(i.imm));
                    a.jumpIf(cond(i.cond), x, sc1, c.labels[i.t]);
                }
                if (next == null or next.? != i.f) a.jmp(c.labels[i.f]);
            },
            .fbr => {
                const x = c.fl(i.a, fsc0);
                const y = c.fl(i.b, fsc1);
                a.jumpIfFloat(fcond(i.cond, false), x, y, c.labels[i.t]);
                if (next == null or next.? != i.f) a.jmp(c.labels[i.f]);
            },
            .brtruthy => {
                a.load8(sc0, tagOf(i.imm));
                a.jumpIfImm(.hi, sc0, @backingInt(Tag.false), c.labels[i.t]);
                if (next == null or next.? != i.f) a.jmp(c.labels[i.f]);
            },
            .brtag => {
                a.jumpIfByte(.eq, tagOf(i.imm), @intCast(i.aux), c.labels[i.t]);
                if (next == null or next.? != i.f) a.jmp(c.labels[i.f]);
            },
            .generic => c.generic(i),
            .exit => a.jmp(c.exitOf(i)),
        }
    }

    const gc_stress = @import("build_options").gc_stress != 0;

    /// The float comparison that branches when `x` holds, or when it
    /// fails.
    fn fcond(x: u8, negate: bool) A.FCond {
        const fc: ir.FCond = @fromBackingInt(x);
        return switch (fc) {
            .lt => if (negate) .nlt else .lt,
            .le => if (negate) .nle else .le,
            .eq => if (negate) .ne else .eq,
            .ne => if (negate) .eq else .ne,
            .nlt => if (negate) .lt else .nlt,
            .nle => if (negate) .le else .nle,
        };
    }

    /// Branches to `miss` unless the tag byte at `m` is `tag`, or, with
    /// `equal` false, when it is.
    fn tagGuard(c: *Codegen, m: Mem, tag: u8, equal: bool, miss: Label) void {
        const a = &c.em.a;
        if (tag == ir.bool_tag) {
            a.load8(sc1, m);
            a.addImm(sc1, -@as(i32, @backingInt(Tag.false)));
            a.jumpIfImm(if (equal) .hi else .ls, sc1, 1, miss);
        } else {
            a.jumpIfByte(if (equal) .ne else .eq, m, tag, miss);
        }
    }

    /// Stores the typed value `r` as a whole value at `m`.
    fn storeTyped(c: *Codegen, m: Mem, r: Ref) void {
        const a = &c.em.a;
        const v = c.f.at(r);
        const tag_m: Mem = .{ .base = m.base, .disp = m.disp + 8 };
        switch (v.ty) {
            .nil => {
                a.storeImm64(m, 0);
                a.storeImm64(tag_m, @backingInt(Tag.nil));
            },
            .boolean => {
                a.storeImm64(m, 0);
                if (v.op == .kbool) {
                    a.storeImm64(tag_m, @as(u64, @backingInt(Tag.false)) + @as(u64, @bitCast(v.imm)));
                } else {
                    const x = c.g(r, sc0);
                    a.addImm3(sc1, x, @backingInt(Tag.false));
                    a.store64(sc1, tag_m);
                }
            },
            .float => {
                if (v.op == .kflt) {
                    a.storeImm64(m, @bitCast(v.imm));
                } else switch (c.place(r)) {
                    .f => |x| a.storeF(x, m),
                    else => a.store64(c.g(r, sc0), m),
                }
                a.storeImm64(tag_m, @backingInt(Tag.float));
            },
            else => {
                if (v.isConst()) {
                    a.storeImm64(m, @bitCast(v.imm));
                } else {
                    a.store64(c.g(r, sc0), m);
                }
                a.storeImm64(tag_m, @backingInt(v.ty));
            },
        }
    }

    /// A call into the runtime with up to three arguments, after the
    /// thread when the instruction asks for it.
    fn callc(c: *Codegen, r: Ref, i: *const ir.Inst) void {
        const a = &c.em.a;
        var buf: [4]Move = undefined;
        var n: usize = 0;
        var arg: usize = 0;
        if (i.flags.thread) arg = 1;
        for ([_]Ref{ i.a, i.b, i.c }) |x| {
            if (x == ir.none) continue;
            buf[n] = .{ .dst = .{ .g = A.args[arg] }, .src = c.place(x), .float = false };
            // A float argument travels as its bits.
            n += 1;
            arg += 1;
        }
        c.parallel(buf[0..n]);
        if (i.flags.thread) a.mov(A.args[0], A.thread);
        a.call(@bitCast(i.imm));
        if (i.ty == .void) return;
        if (i.ty == .float) {
            const d = c.fdst(r);
            a.bitsToFloat(d, A.ret0);
            c.fdone(r, d);
        } else {
            const d = c.dst(r);
            a.mov(d, A.ret0);
            c.done(r, d);
        }
    }

    /// The baseline template of one instruction. The native frame is
    /// left before it and entered again where the template continues.
    fn generic(c: *Codegen, i: *const ir.Inst) void {
        const a = &c.em.a;
        const pc: u32 = @intCast(i.imm);
        c.gen_targets = c.f.gen_targets.items[i.a..][0..i.b];
        for (c.gen_targets, 0..) |t, k| {
            c.gen_labels[k] = if (c.frame == 0) c.labels[t.block] else a.newLabel();
        }
        if (c.frame != 0) a.moveSp(c.frame);
        c.em.instruction(pc, c.p.code[pc]);
        if (c.gen_targets.len > 0) a.jmp(c.gen_labels[0]) else a.trap();
        if (c.frame != 0) {
            for (c.gen_targets, 0..) |t, k| {
                a.bind(c.gen_labels[k]);
                a.moveSp(-c.frame);
                a.jmp(c.labels[t.block]);
            }
        }
        // The out-of-line code of the template uses the same targets.
        c.em.flushCold();
        c.em.step_pc = std.math.maxInt(u32);
    }

    /// The out-of-line part of a barrier or of a collector check. The
    /// pool registers keep their values across it.
    fn stub(c: *Codegen, s: Stub) void {
        const a = &c.em.a;
        const i = c.f.at(s.inst);
        a.bind(s.entry);
        c.saveAll();
        switch (i.op) {
            .gccheck => {
                a.mov(A.args[0], A.thread);
                a.movImm(A.args[1], @intFromPtr(c.unit));
                a.movImm(A.args[2], i.snap);
                a.leaSp(A.args[3], 0);
                a.movImm(A.args[4], i.aux);
                a.call(@intFromPtr(&opt.rt.collect));
            },
            .barrier => {
                var buf: [3]Move = undefined;
                var n: usize = 0;
                buf[n] = .{ .dst = .{ .g = A.args[1] }, .src = c.argPlace(i.a, true), .float = false };
                n += 1;
                switch (i.aux & 3) {
                    0 => {
                        const v = c.f.at(i.b);
                        if (v.ty == .nil) {
                            buf[n] = .{ .dst = .{ .g = A.args[2] }, .src = .{ .imm = 0 }, .float = false };
                        } else {
                            buf[n] = .{ .dst = .{ .g = A.args[2] }, .src = c.argPlace(i.b, true), .float = false };
                        }
                        n += 1;
                        c.parallel(buf[0..n]);
                        if (v.ty == .boolean) {
                            a.addImm3(A.args[3], A.args[2], @backingInt(Tag.false));
                            a.movImm(A.args[2], 0);
                        } else {
                            a.movImm(A.args[3], @backingInt(v.ty));
                        }
                        a.movImm(A.args[4], @bitCast(i.imm));
                        a.mov(A.args[0], A.thread);
                        a.call(@intFromPtr(&opt.rt.barrierTable));
                    },
                    1 => {
                        c.parallel(buf[0..n]);
                        a.mov(A.args[0], A.thread);
                        a.call(@intFromPtr(&opt.rt.barrierBack));
                    },
                    else => {
                        c.parallel(buf[0..n]);
                        const sl: i64 = @intCast(i.aux >> 8);
                        a.load64(A.args[2], slot(sl));
                        a.load64(A.args[3], tagOf(sl));
                        a.movImm(A.args[4], @bitCast(i.imm));
                        a.mov(A.args[0], A.thread);
                        a.call(@intFromPtr(&opt.rt.barrierTable));
                    },
                }
            },
            else => unreachable,
        }
        c.restoreAll();
        a.jmp(s.back);
    }
};
