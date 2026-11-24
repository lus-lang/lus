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
const Value = value.Value;
const table = @import("../../vm/table.zig");
const gc = @import("../../vm/gc.zig");
const interp = @import("../../vm/interp.zig");
const jit = @import("../jit.zig");
const helpers = @import("../helpers.zig");
const opc = @import("../../compile/opcodes.zig");
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
const is_x64 = builtin.cpu.arch == .x86_64;

/// The registers that hold values. Every one of them belongs to the
/// callee across a call into the runtime.
pub const gpr_pool: []const A.Reg = switch (builtin.cpu.arch) {
    .aarch64 => &.{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9, .x10, .x11, .x12 },
    .x86_64 => &.{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9 },
    // a0 to a5 and t0 to t6. a6 and a7 are the scratch registers of the
    // assembler.
    .riscv64 => &.{ .x10, .x11, .x12, .x13, .x14, .x15, .x5, .x6, .x7, .x28, .x29, .x30, .x31 },
    // a0 to a7 and t0 to t6. t7 and t8 are the scratch registers of the
    // assembler.
    .loongarch64 => &.{ .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15, .r16, .r17, .r18 },
    // r3 to r10 and the temporaries r21 to r27, which the entry sequence
    // saves.
    .powerpc64le => &.{ .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r21, .r22, .r23, .r24, .r25, .r26, .r27 },
    // The temporaries t0 to t6 in order, as on x86-64, so that the pool
    // overlaps the argument registers as it does there.
    .s390x => &.{ .r11, .r5, .r4, .r3, .r2, .r6, .r12 },
    // The temporaries t0 to t6 in order, as on s390x, and six registers
    // that live in the native frame of the entry sequence. The first
    // three are pairs of machine registers.
    .arm => &.{ .t0, .t1, .t2, .t3, .t4, .t5, .t6, .v0, .v1, .v2, .v3, .v4, .v5 },
    else => unreachable,
};
pub const fpr_pool: []const A.FReg = switch (builtin.cpu.arch) {
    .aarch64 => &.{ .v0, .v1, .v2, .v3, .v4, .v5, .v6, .v7, .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23 },
    .x86_64 => &.{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 },
    // fa0 to fa7 and ft0 to ft7.
    .riscv64 => &.{ .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f0, .f1, .f2, .f3, .f4, .f5, .f6, .f7 },
    // fa0 to fa7 and ft0 to ft7.
    .loongarch64 => &.{ .f0, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15 },
    // f1 to f11. f0 is the scratch register of the assembler.
    .powerpc64le => &.{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11 },
    // f0 to f7, which a call may clobber.
    .s390x => &.{ .f0, .f1, .f2, .f3, .f4, .f5, .f6, .f7 },
    // d0 to d7, which a call may clobber.
    .arm => &.{ .d0, .d1, .d2, .d3, .d4, .d5, .d6, .d7 },
    else => unreachable,
};
/// Scratch registers of the code generator. On every target except
/// aarch64 and s390x they are callee-saved registers that the entry
/// sequence saves and baseline code leaves alone. On s390x the second and
/// third are r1, which a call may clobber, as on aarch64. On 32-bit ARM
/// they are two registers that live in the native frame of the entry
/// sequence.
const sc0: A.Reg = switch (builtin.cpu.arch) {
    .aarch64 => .x13,
    .x86_64 => .rbp,
    .riscv64 => .x21,
    .loongarch64 => .r27,
    .powerpc64le => .r18,
    .s390x => .r13,
    .arm => .c0,
    else => unreachable,
};
const sc1: A.Reg = switch (builtin.cpu.arch) {
    .aarch64 => .x14,
    .x86_64 => .r13,
    .riscv64 => .x22,
    .loongarch64 => .r28,
    .powerpc64le => .r19,
    .s390x => .r1,
    .arm => .c1,
    else => unreachable,
};
const sc2: A.Reg = switch (builtin.cpu.arch) {
    .aarch64 => .x15,
    .x86_64 => .r13,
    .riscv64 => .x23,
    .loongarch64 => .r29,
    .powerpc64le => .r20,
    .s390x => .r1,
    .arm => .c1,
    else => unreachable,
};
const fsc0: A.FReg = switch (builtin.cpu.arch) {
    .aarch64 => .v30,
    .x86_64 => .xmm13,
    .riscv64 => .f31,
    .loongarch64 => .f23,
    .powerpc64le => .f13,
    .s390x => .f8,
    .arm => .d8,
    else => unreachable,
};
const fsc1: A.FReg = switch (builtin.cpu.arch) {
    .aarch64 => .v29,
    .x86_64 => .xmm12,
    .riscv64 => .f30,
    .loongarch64 => .f22,
    .powerpc64le => .f12,
    .s390x => .f9,
    .arm => .d9,
    else => unreachable,
};
const fret: A.FReg = switch (builtin.cpu.arch) {
    .aarch64 => .v0,
    .x86_64 => .xmm0,
    .riscv64 => .f10,
    .loongarch64 => .f0,
    .powerpc64le => .f1,
    .s390x => .f0,
    .arm => .d0,
    else => unreachable,
};

comptime {
    // macOS and Windows reserve x18 for the system.
    if (is_a64) for (gpr_pool ++ [_]A.Reg{ sc0, sc1, sc2 }) |r| std.debug.assert(r != .x18);
}

/// The registers of a direct call. The closure travels in the first
/// pool register and the parameters in the ones after it, each as its
/// payload. The callee returns the payload of its result in the first
/// and the tag in the second.
const dret_payload: A.Reg = gpr_pool[0];
const dret_tag: A.Reg = gpr_pool[1];
/// The tag word of a direct return that carries no value.
pub const no_result: u64 = 0x100;
/// The tag word that the entry of a chain returns when the callee did
/// not run, because the stack has too little room left.
pub const no_entry: u64 = 0x200;
/// Slots of the Lus stack that a chain of direct calls leaves free
/// below the limit of the stack. The frames of one more call fit in
/// them, so the call that finds no room is made by the interpreter.
pub const chain_margin: u32 = 1024;
/// Registers that hold no parameter of a direct call.
const spare0: A.Reg = gpr_pool[ir.max_direct_params + 1];
const spare1: A.Reg = gpr_pool[ir.max_direct_params + 2];
/// Bytes of native stack that the entry of a direct call from baseline
/// code holds while the callee runs: the saved pc and the argument
/// count, the base and the wanted count, and the return address.
pub const thunk_bytes: i32 = 32;

comptime {
    std.debug.assert(gpr_pool.len >= ir.max_direct_params + 3);
    std.debug.assert(@backingInt(Tag.nil) == 0);
}

/// Bytes that the exit sequence saves the pool registers in.
pub const save_bytes: i32 = @intCast(std.mem.alignForward(usize, (gpr_pool.len + fpr_pool.len) * 8, 16));

/// A place a move reads or writes.
const Place = union(enum) {
    g: A.Reg,
    f: A.FReg,
    spill: u32,
    /// An integer constant.
    imm: u64,
    /// The bits of a float constant.
    fimm: u64,
    /// A constant address, which code compiled ahead of time relocates.
    ptr: u64,
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
    /// For a function that is entered directly: the native frame of one
    /// activation, which holds the spilled values and, in its top word,
    /// the return address.
    total: i32 = 0,
    l_direct: Label = 0,
    l_root: Label = 0,
    root_off: u32 = 0,
    chain_ratio: u32 = 1,
    /// The exit of the entries that find a frame in place.
    l_deopt_frame: Label = 0,
    /// Offsets of the direct entry and of the instructions after the
    /// two calls of it that the unit makes for its other entries.
    direct_off: u32 = 0,
    ret_a_off: u32 = 0,
    ret_b_off: u32 = 0,
    /// The arguments of the direct call being emitted.
    dargs: [ir.max_direct_params]Ref = @splat(ir.none),

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
            .frame = if (f.direct) 0 else @intCast(std.mem.alignForward(usize, @as(usize, ra.nspill) * 8, 16)),
            .total = @intCast(std.mem.alignForward(usize, @as(usize, ra.nspill) * 8 + 8, 16)),
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
        for (c.exit_labels) |*x| x.* = a.newColdLabel();
        c.l_deopt = a.newLabel();
        c.l_trap = a.newLabel();
        c.l_entry = a.newLabel();
        c.l_direct = a.newLabel();
        c.l_root = a.newLabel();
        c.l_deopt_frame = a.newLabel();
        if (f.direct) c.chainShape();

        // The entries that calls from native code use run into the body.
        if (!c.p.is_vararg and c.unit.entry_pc == 0) {
            c.em.first = c.l_entry;
            c.em.tailEntry();
            if (f.direct) {
                c.callThunk();
            } else {
                c.em.callEntry();
                a.jmp(c.l_entry);
            }
        }
        a.bind(c.l_entry);
        c.entry_off = a.offset();
        if (f.direct) {
            // A frame is in place. The body runs as a direct call from
            // here, and its result returns through the frame.
            c.frameThunk();
            c.rootEntry();
            a.bind(c.l_direct);
            c.direct_off = a.offset();
            a.saveLink(c.total);
            c.paramMoves();
        } else {
            // The body starts with the frame in place and every
            // register in its slot.
            if (f.extent > c.p.max_stack or f.depth > 0 or f.scratch > 0) c.roomCheck();
            if (c.frame != 0) a.moveSp(-c.frame);
        }
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
        const l_continue = a.newLabel();
        a.bind(c.l_deopt);
        c.saveAll();
        a.mov(A.args[0], A.thread);
        a.mov(A.args[2], sc0);
        a.movImm(A.args[1], @intFromPtr(c.unit));
        a.leaSp(A.args[3], 0);
        if (f.direct) {
            // The runtime builds the frame of every direct call that
            // is running, and the native stack returns to where the
            // entry sequence left it.
            a.callPair(@intFromPtr(&opt.rt.deoptDirect));
            a.loadWord(sc0, .{ .base = A.thread, .disp = c.em.lay.global });
            a.loadWord(sc0, .{ .base = sc0, .disp = @intCast(@intFromPtr(&c.l.g.jit.exit_sp) - @intFromPtr(c.l.g)) });
            a.setSp(sc0);
        } else {
            a.callPair(@intFromPtr(&opt.rt.deopt));
            a.moveSp(save_bytes + c.frame);
        }
        a.bind(l_continue);
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
        if (f.direct) {
            // An exit of an entry that found its frame in place.
            a.bind(c.l_deopt_frame);
            c.saveAll();
            a.mov(A.args[0], A.thread);
            a.mov(A.args[2], sc0);
            a.movImm(A.args[1], @intFromPtr(c.unit));
            a.leaSp(A.args[3], 0);
            a.callPair(@intFromPtr(&opt.rt.deopt));
            a.moveSp(save_bytes);
            a.jmp(l_continue);
        }

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
        a.jumpIfMemWord(.hi, sc0, .{ .base = A.thread, .disp = lay.stack_len }, bail);
        a.loadWord(sc0, .{ .base = A.thread, .disp = lay.frames_len });
        a.addImm(sc0, @intCast(c.f.depth + 1));
        a.jumpIfMemWord(.ls, sc0, .{ .base = A.thread, .disp = lay.frames_cap }, ok);
        a.bind(bail);
        a.mov(A.args[0], A.thread);
        a.movImm(A.args[1], c.f.extent + c.f.scratch + 16);
        a.movImm(A.args[2], c.f.depth + 1);
        a.callPair(@intFromPtr(&opt.rt.bail));
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
    // Direct entry

    fn jitField(c: *Codegen, field: *const usize) i32 {
        return @intCast(@intFromPtr(field) - @intFromPtr(c.l.g));
    }

    /// Fits the native frame of an activation to the slots its calls
    /// take, and finds the ratio between the two for every chain of
    /// direct calls that starts in this function. An activation covers
    /// at least as many bytes as its call took slots, so the ratio is
    /// at most sixteen slots per sixteen bytes.
    fn chainShape(c: *Codegen) void {
        var ratio: u32 = 1;
        for (c.f.sites.items) |s| {
            if (s.callee_total == 0) c.total = @max(c.total, @as(i32, @intCast(std.mem.alignForward(u32, s.slot + 1, 16))));
        }
        for (c.f.sites.items) |s| {
            const total: u32 = if (s.callee_total == 0) @intCast(c.total) else s.callee_total;
            const per16 = ((s.slot + 1) * 16 + total - 1) / total;
            ratio = @max(ratio, std.math.ceilPowerOfTwoAssert(u32, per16), s.callee_ratio);
        }
        c.chain_ratio = @min(ratio, 16);
    }

    /// The entry of a call that starts a chain of direct calls: a call
    /// from one of the two entries with a frame protocol, or from a
    /// function that keeps a frame. The caller passes the base that the
    /// frame of the callee would have in `sc0`. The entry sets the
    /// lowest address the chain may take the native stack to, so that
    /// its activations stay inside the Lus stack and above the floor of
    /// the native stack, and runs into the body. It returns `no_entry`
    /// at once when either has no room for the first activation.
    fn rootEntry(c: *Codegen) void {
        const a = &c.em.a;
        const js = &c.l.g.jit;
        const l_no = a.newLabel();
        const l_store = a.newLabel();
        const l_body = a.newLabel();
        a.bind(c.l_root);
        c.root_off = a.offset();
        // sc1 = the bytes of native stack that the slots left allow.
        a.movImmReloc(sc1, Thread.max_stack - chain_margin, .literal);
        a.sub(sc1, sc0);
        a.jumpIfImm(.le, sc1, 0, l_no);
        var mult: u32 = 16 / c.chain_ratio;
        while (mult > 1) : (mult /= 2) a.add(sc1, sc1);
        a.loadWord(spare0, .{ .base = A.thread, .disp = c.em.lay.global });
        a.loadWord(spare1, .{ .base = spare0, .disp = c.jitField(&js.stack_floor) });
        a.leaSp(sc0, 0);
        a.jumpIf(.lo, sc0, spare1, l_no);
        a.sub(sc0, sc1);
        a.jumpIf(.hs, sc0, spare1, l_store);
        a.mov(sc0, spare1);
        a.bind(l_store);
        a.storeWord(sc0, .{ .base = spare0, .disp = c.jitField(&js.chain_limit) });
        a.jmp(l_body);
        a.bind(l_no);
        a.movImm(dret_tag, no_entry);
        a.retLocal();
        a.bind(l_body);
    }

    /// Loads parameter `i` of the function from the value at `m` into
    /// its register, as its payload.
    fn loadParam(c: *Codegen, i: usize, m: Mem) void {
        const a = &c.em.a;
        const r = gpr_pool[1 + i];
        switch (c.f.sig[i]) {
            .nil => {},
            .boolean => {
                a.load8(r, .{ .base = m.base, .disp = m.disp + 8 });
                a.addImm(r, -@as(i32, @backingInt(Tag.false)));
            },
            else => a.load64(r, m),
        }
    }

    /// The entry that a call from baseline code uses. The caller passes
    /// what it passes to every call entry: the closure in t0, the pc to
    /// save in t3, the base of the callee in t4, the wanted result count
    /// in t5, and the argument count in t6. The entry pushes no frame.
    /// It checks the types of the arguments in their slots, calls the
    /// body with them in registers, stores the result into the slot of
    /// the called function, and continues in the caller where a lean
    /// return would. What a frame for the callee needs stays in the
    /// native frame of the entry meanwhile. The entry returns to the
    /// caller, with nothing changed, when the call needs the step
    /// routine.
    fn callThunk(c: *Codegen) void {
        const a = &c.em.a;
        const lay = c.em.lay;
        const np: usize = c.p.num_params;
        const fail = a.newLabel();
        const deep = a.newLabel();
        const zero = a.newLabel();
        const fin = a.newLabel();
        c.em.call_entry = a.offset();
        c.em.call_entry_plain = a.offset();
        a.loadWord(A.t1, .{ .base = A.thread, .disp = lay.global });
        a.loadWord(A.t1, .{ .base = A.t1, .disp = lay.pending });
        a.jumpIfImm(.ne, A.t1, 0, fail);
        if (np > 0) a.jumpIfImm(.lo, A.t6, @intCast(np), fail);
        // t1 = the address of register 0 of the callee.
        a.loadWord(A.t1, .{ .base = A.thread, .disp = lay.stack_ptr });
        a.addScaled(A.t1, A.t1, A.t4, 4);
        for (0..np) |i| {
            const tag_m: Mem = .{ .base = A.t1, .disp = @intCast(i * 16 + 8) };
            if (c.f.sig[i] == .boolean) {
                a.load8(A.t2, tag_m);
                a.addImm(A.t2, -@as(i32, @backingInt(Tag.false)));
                a.jumpIfImm(.hi, A.t2, 1, fail);
            } else {
                a.jumpIfByte(.ne, tag_m, @backingInt(c.f.sig[i]), fail);
            }
        }

        // Nothing fails from here on.
        a.saveLink(thunk_bytes);
        a.store32(A.t3, .{ .base = A.sp, .disp = 0 });
        a.store32(A.t6, .{ .base = A.sp, .disp = 4 });
        a.store32(A.t4, .{ .base = A.sp, .disp = 8 });
        a.store32(A.t5, .{ .base = A.sp, .disp = 12 });
        a.mov(A.t6, A.t1);
        a.mov(sc0, A.t4);
        a.mov(gpr_pool[0], A.t0);
        for (0..np) |i| c.loadParam(i, .{ .base = A.t6, .disp = @intCast(i * 16) });
        a.callLocal(c.l_root);
        c.ret_b_off = a.offset();
        a.jumpIfImm(.eq, dret_tag, @intCast(no_entry), deep);

        // The result goes to the slot of the called function, and the
        // caller gets the count in t6, as after a lean return.
        a.load32(A.t6, .{ .base = A.sp, .disp = 8 });
        a.loadWord(A.t5, .{ .base = A.thread, .disp = lay.stack_ptr });
        a.addScaled(A.t5, A.t5, A.t6, 4);
        a.jumpIfImm(.eq, dret_tag, @intCast(no_result), zero);
        a.store64(dret_payload, .{ .base = A.t5, .disp = -16 });
        a.storeTag(dret_tag, .{ .base = A.t5, .disp = -8 });
        a.movImm(A.t6, 1);
        a.jmp(fin);
        a.bind(zero);
        a.movImm(A.t6, 0);
        a.bind(fin);
        a.unsaveLink(thunk_bytes);
        a.linkPastJump(A.t3);
        a.dropLink();
        a.jmpReg(A.t3);
        a.bind(fail);
        a.retLocal();
        // The stack has too little room left for a chain of direct
        // calls, so the call enters baseline code, which takes the
        // registers the caller passed.
        a.bind(deep);
        a.load32(A.t4, .{ .base = A.sp, .disp = 8 });
        a.loadWord(A.t1, .{ .base = A.thread, .disp = lay.stack_ptr });
        a.addScaled(A.t1, A.t1, A.t4, 4);
        a.load64(A.t0, .{ .base = A.t1, .disp = -16 });
        a.load32(A.t3, .{ .base = A.sp, .disp = 0 });
        a.load32(A.t6, .{ .base = A.sp, .disp = 4 });
        a.load32(A.t5, .{ .base = A.sp, .disp = 12 });
        a.unsaveLink(thunk_bytes);
        const code: *jit.Code = @ptrCast(@alignCast(c.p.jit_code.?));
        a.movImm(A.t1, code.base + code.call_entry_plain);
        a.jmpReg(A.t1);
    }

    /// The entry that finds the frame of the function in place: a frame
    /// that the interpreter or a step routine pushed, or that a tail
    /// call took over. It checks the types of the parameters, calls the
    /// body with them in registers, and returns the result as the
    /// baseline templates of `ret0` and `ret1` do.
    fn frameThunk(c: *Codegen) void {
        const a = &c.em.a;
        const np: usize = c.p.num_params;
        const l_baseline = a.newLabel();
        const l_exit = a.newLabel();
        const zero = a.newLabel();
        const slow0 = a.newLabel();
        const slow1 = a.newLabel();
        for (0..np) |i| c.tagGuard(tagOf(@intCast(i)), c.f.sig[i].guardTag(), true, l_exit);
        a.load64(gpr_pool[0], slot(-1));
        for (0..np) |i| c.loadParam(i, slot(@intCast(i)));
        a.mov(sc0, A.base);
        a.callLocal(c.l_root);
        c.ret_a_off = a.offset();
        a.jumpIfImm(.eq, dret_tag, @intCast(no_entry), l_baseline);

        a.jumpIfImm(.eq, dret_tag, @intCast(no_result), zero);
        a.store64(dret_payload, slot(0));
        a.storeTag(dret_tag, tagOf(0));
        c.em.leanReturnOr(1, 0, slow1);
        a.bind(slow1);
        c.stepReturn(.ret1);
        a.bind(zero);
        c.em.leanReturnOr(0, 0, slow0);
        a.bind(slow0);
        c.stepReturn(.ret0);

        // The stack has too little room left for a chain of direct
        // calls, so the frame runs in baseline code.
        a.bind(l_baseline);
        const code: *jit.Code = @ptrCast(@alignCast(c.p.jit_code.?));
        a.movImm(sc0, code.base + code.offs[0]);
        a.jmpReg(sc0);
        a.bind(l_exit);
        a.movImm(sc0, c.f.entry_snap);
        a.jmp(c.l_deopt_frame);
    }

    /// Returns from the frame in place through the step routine of a
    /// return instruction, with the result in register zero.
    fn stepReturn(c: *Codegen, o: opc.Op) void {
        const a = &c.em.a;
        // The saved pc is that of a return of the function.
        var pc: u32 = 0;
        for (c.p.code, 0..) |ins, i| switch (opc.op(ins)) {
            .ret0, .ret1, .ret => {
                pc = @intCast(i);
                break;
            },
            else => {},
        };
        a.mov(A.args[0], A.thread);
        a.movImm(A.args[1], pc + 1);
        a.mov(A.args[2], A.stop);
        a.movImmReloc(A.args[3], opc.abc(o, 0, 0, 0), .literal);
        a.call(@intFromPtr(helpers.steps[@backingInt(o)]));
        a.jmp(c.em.l_status);
    }

    /// Moves the closure and the parameters from the registers a direct
    /// call passes them in to the places they live in.
    fn paramMoves(c: *Codegen) void {
        var buf: [ir.max_direct_params + 1]Move = undefined;
        var n: usize = 0;
        for (c.f.blocks.items[c.f.entry].insts.items) |r| {
            const i = c.f.at(r);
            if (i.op != .param or c.ra.loc[r] == .none) continue;
            buf[n] = .{ .dst = c.place(r), .src = .{ .g = gpr_pool[@intCast(i.imm)] }, .float = i.ty == .float };
            n += 1;
        }
        c.parallel(buf[0..n]);
    }

    /// A direct call: the closure and the arguments move to the
    /// registers of the convention, and the callee returns to the
    /// instruction after the call.
    fn dcall(c: *Codegen, i: *const ir.Inst) void {
        const a = &c.em.a;
        var buf: [ir.max_direct_params + 1]Move = undefined;
        var n: usize = 1;
        buf[0] = .{ .dst = .{ .g = gpr_pool[0] }, .src = c.place(i.a), .float = false };
        for (c.dargs, 0..) |x, k| {
            if (x == ir.none) continue;
            // A float travels as its bits.
            buf[n] = .{ .dst = .{ .g = gpr_pool[1 + k] }, .src = c.place(x), .float = false };
            n += 1;
        }
        c.dargs = @splat(ir.none);
        c.parallel(buf[0..n]);
        if (i.imm == 0) {
            a.callLocal(c.l_direct);
        } else {
            // A call from a function with a frame starts a chain, and
            // the entry of a chain takes the base of the callee.
            if (!c.f.direct) a.lea(sc0, .{ .base = A.base, .disp = @intCast(c.f.sites.items[@intCast(i.aux)].slot + 1) });
            a.movImm(sc1, @bitCast(i.imm));
            a.callReg(sc1);
        }
        c.f.sites.items[@intCast(i.aux)].ret_off = a.offset();
    }

    /// The result of a direct call, checked against the predicted type.
    fn dres(c: *Codegen, r: Ref, i: *const ir.Inst) void {
        const a = &c.em.a;
        const miss = c.exitOf(i);
        switch (i.ty) {
            .nil => {
                // A callee that returned nothing yields nil as well.
                a.movImm(sc1, 0xFF);
                a.and3(sc0, dret_tag, sc1);
                a.jumpIfImm(.ne, sc0, 0, miss);
            },
            .boolean => {
                a.addImm3(sc0, dret_tag, -@as(i32, @backingInt(Tag.false)));
                a.jumpIfImm(.hi, sc0, 1, miss);
                const d = c.dst(r);
                a.mov(d, sc0);
                c.done(r, d);
            },
            .float => {
                a.jumpIfImm(.ne, dret_tag, @backingInt(Tag.float), miss);
                const d = c.fdst(r);
                a.bitsToFloat(d, dret_payload);
                c.fdone(r, d);
            },
            else => {
                a.jumpIfImm(.ne, dret_tag, @backingInt(i.ty), miss);
                const d = c.dst(r);
                a.mov(d, dret_payload);
                c.done(r, d);
            },
        }
    }

    /// A return to a direct caller: the payload and the tag of the
    /// result in the two registers of the convention.
    fn dret(c: *Codegen, i: *const ir.Inst) void {
        const a = &c.em.a;
        if (i.imm == 0) {
            a.movImm(dret_payload, 0);
            a.movImm(dret_tag, no_result);
        } else switch (c.f.at(i.a).ty) {
            .nil => {
                a.movImm(dret_payload, 0);
                a.movImm(dret_tag, 0);
            },
            .boolean => {
                const x = c.g(i.a, sc0);
                a.addImm3(sc0, x, @backingInt(Tag.false));
                a.movImm(dret_payload, 0);
                a.mov(dret_tag, sc0);
            },
            .float => {
                switch (c.place(i.a)) {
                    .f => |x| a.floatToBits(dret_payload, x),
                    else => a.mov(dret_payload, c.g(i.a, sc0)),
                }
                a.movImm(dret_tag, @backingInt(Tag.float));
            },
            else => |ty| {
                a.mov(dret_payload, c.g(i.a, sc0));
                a.movImm(dret_tag, @backingInt(ty));
            },
        }
        a.leaveLink(c.total);
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
            .kint, .kbool => return .{ .imm = @bitCast(i.imm) },
            .kptr => return .{ .ptr = @bitCast(i.imm) },
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
            .imm, .fimm => |v| a.movImmReloc(scratch, v, .literal),
            .ptr => |v| a.movImm(scratch, v),
            .f => |x| a.floatToBits(scratch, x),
        }
        return scratch;
    }

    fn fl(c: *Codegen, r: Ref, scratch: A.FReg) A.FReg {
        const a = &c.em.a;
        switch (c.place(r)) {
            .f => |x| return x,
            .spill => |k| a.loadF(scratch, spillMem(k)),
            .fimm, .imm, .ptr => |v| a.fmovImm(scratch, v),
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

    /// Whether the constant of a guard or a branch travels as the 32-bit
    /// integer of `jumpIfImm`. An address compiled ahead of time loads
    /// into a register in its patchable form, which matters on a 32-bit
    /// target, where an address fits 32 bits.
    fn shortImm(c: *Codegen, i: *const ir.Inst) bool {
        return fitsImm(i.imm) and !(i.flags.address and c.em.aot != null);
    }
    /// Loads the constant of a guard or a branch.
    fn wideImm(c: *Codegen, to: A.Reg, i: *const ir.Inst) void {
        const a = &c.em.a;
        if (i.flags.address) a.movImm(to, @bitCast(i.imm)) else a.movImmReloc(to, @bitCast(i.imm), .literal);
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
                    .fimm, .imm, .ptr => |v| a.fmovImm(d, v),
                    .g => |s| a.bitsToFloat(d, s),
                },
                .spill => |dk| switch (m.src) {
                    .f => |s| a.storeF(s, spillMem(dk)),
                    .spill => |k| a.copy8(spillMem(dk), spillMem(k)),
                    .fimm, .imm, .ptr => |v| emit.storeLiteral(a, spillMem(dk), v),
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
                .imm, .fimm => |v| a.movImmReloc(d, v, .literal),
                .ptr => |v| a.movImm(d, v),
                .f => |s| a.floatToBits(d, s),
            },
            .spill => |dk| switch (m.src) {
                .g => |s| a.store64(s, spillMem(dk)),
                .spill => |k| a.copy8(spillMem(dk), spillMem(k)),
                .imm, .fimm => |v| emit.storeLiteral(a, spillMem(dk), v),
                .ptr => |v| a.storeImm64(spillMem(dk), v),
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
            .thread => {
                const d = c.dst(r);
                a.mov(d, A.thread);
                c.done(r, d);
            },

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
                    a.movImmReloc(sc1, @bitCast(i.imm), .literal);
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
                    a.movImmReloc(sc1, @bitCast(i.imm), .literal);
                    y = sc1;
                } else y = c.g(i.b, sc1);
                const d = c.dst(r);
                if (!is_x64) {
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
                    // Only the constant of `kptr` is an address, which
                    // is 4 bytes wide on a 32-bit target.
                    switch (i.size) {
                        2 => a.storeImm16(m, @truncate(bits)),
                        4 => if (v.op == .kptr and @sizeOf(usize) == 4) a.storeImmWord(m, bits) else a.storeImm32(m, @truncate(bits)),
                        else => if (v.op == .kptr) a.storeImm64(m, bits) else emit.storeLiteral(a, m, bits),
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
            .copy_s2n => {
                const base = c.g(i.a, sc0);
                const s: i64 = @as(i32, @bitCast(@as(u32, @truncate(i.aux))));
                const tdisp: i32 = @bitCast(@as(u32, @truncate(i.aux >> 32)));
                a.load64(sc1, slot(s));
                a.store64(sc1, .{ .base = base, .disp = @intCast(i.imm) });
                a.load8(sc1, tagOf(s));
                a.store8(sc1, .{ .base = base, .disp = tdisp });
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
                if (c.shortImm(i)) {
                    a.jumpIfImm(cond(i.cond).invert(), x, @intCast(i.imm), c.exitOf(i));
                } else {
                    c.wideImm(sc1, i);
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
                a.loadWord(sc0, .{ .base = A.thread, .disp = c.em.lay.global });
                a.loadWord(sc0, .{ .base = sc0, .disp = c.em.lay.pending });
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
                const s: Stub = .{ .entry = a.newColdLabel(), .back = a.newLabel(), .inst = r };
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
                const s: Stub = .{ .entry = a.newColdLabel(), .back = a.newLabel(), .inst = r };
                c.stubs.append(c.arena, s) catch {
                    c.em.oom = true;
                };
                if (gc_stress) {
                    a.jmp(s.entry);
                } else {
                    a.loadWord(sc0, .{ .base = A.thread, .disp = c.em.lay.global });
                    a.loadWord(sc1, .{ .base = sc0, .disp = c.gc_bytes });
                    a.jumpIfMemWord(.hs, sc1, .{ .base = sc0, .disp = c.gc_next }, s.entry);
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
                if (c.shortImm(i)) {
                    a.jumpIfImm(cond(i.cond), x, @intCast(i.imm), c.labels[i.t]);
                } else {
                    c.wideImm(sc1, i);
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

            .param => {},
            .dlimit => {
                a.loadWord(sc1, .{ .base = A.thread, .disp = c.em.lay.global });
                a.leaSp(sc0, 0);
                a.jumpIfMemWord(.lo, sc0, .{ .base = sc1, .disp = c.jitField(&c.l.g.jit.chain_limit) }, c.exitOf(i));
            },
            .dgate => a.jumpIfImm(.eq, dret_tag, @intCast(no_entry), c.exitOf(i)),
            .darg => c.dargs[@intCast(i.imm)] = i.a,
            .dcall => c.dcall(i),
            .dres => c.dres(r, i),
            .dret => c.dret(i),
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
                a.storeImm64(tag_m, Value.tagWord(.nil));
            },
            .boolean => {
                a.storeImm64(m, 0);
                if (v.op == .kbool) {
                    a.storeImm64(tag_m, Value.tagWordOf(@as(u64, @backingInt(Tag.false)) + @as(u64, @bitCast(v.imm))));
                } else {
                    const x = c.g(r, sc0);
                    a.addImm3(sc1, x, @backingInt(Tag.false));
                    a.storeTag(sc1, tag_m);
                }
            },
            .float => {
                if (v.op == .kflt) {
                    emit.storeLiteral(a, m, @bitCast(v.imm));
                } else switch (c.place(r)) {
                    .f => |x| a.storeF(x, m),
                    else => a.store64(c.g(r, sc0), m),
                }
                a.storeImm64(tag_m, Value.tagWord(.float));
            },
            else => {
                if (v.op == .kptr) {
                    a.storeImm64(m, @bitCast(v.imm));
                } else if (v.isConst()) {
                    emit.storeLiteral(a, m, @bitCast(v.imm));
                } else {
                    a.store64(c.g(r, sc0), m);
                }
                a.storeImm64(tag_m, Value.tagWordOf(@backingInt(v.ty)));
            },
        }
    }

    /// A call into the runtime with up to three arguments, after the
    /// thread when the instruction asks for it. Every argument and the
    /// result are 64-bit integers.
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
        a.callWide(@bitCast(i.imm));
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
                        a.load8(A.args[3], tagOf(sl));
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
