//! Passes over the intermediate representation: phis that merge one
//! value disappear, guards and loads that a loop repeats move in front of
//! the loop, and instructions whose result nothing reads are dropped.

const std = @import("std");
const ir = @import("ir.zig");
const flow_mod = @import("flow.zig");
const lower = @import("lower.zig");
const Ref = ir.Ref;
const BlockId = ir.BlockId;
const Cfg = flow_mod.Cfg;

/// The operands of an instruction that name values. The arguments of a
/// phi and the entries of a snapshot are separate.
fn operands(i: *const ir.Inst) [3]Ref {
    return .{
        if (usesA(i)) i.a else ir.none,
        if (usesB(i)) i.b else ir.none,
        if (i.op == .phi or i.op == .generic) ir.none else i.c,
    };
}

/// Replaces every phi whose arguments are one value, or that value and
/// the phi itself, by the value.
pub fn simplifyPhis(f: *ir.Func) !void {
    const n = f.insts.items.len;
    const fwd = try f.arena.alloc(Ref, n);
    for (fwd, 0..) |*x, i| x.* = @intCast(i);
    var changed = true;
    var any = false;
    while (changed) {
        changed = false;
        for (f.insts.items, 0..) |*inst, idx| {
            if (inst.op != .phi or fwd[idx] != idx) continue;
            var only: Ref = ir.none;
            var trivial = true;
            for (f.phi_args.items[inst.a..][0..inst.b]) |arg| {
                const v = resolve(fwd, arg.ref);
                if (v == idx) continue;
                if (only == ir.none) {
                    only = v;
                } else if (only != v) {
                    trivial = false;
                    break;
                }
            }
            if (trivial and only != ir.none) {
                fwd[idx] = only;
                changed = true;
                any = true;
            }
        }
    }
    if (!any) return;
    try rewrite(f, fwd);
    for (f.insts.items, 0..) |*inst, idx| {
        if (inst.op == .phi and fwd[idx] != idx) inst.* = .{};
    }
}

/// Turns an addition, a comparison, or a guard with a small constant
/// operand into its immediate form.
pub fn foldImmediates(f: *ir.Func) void {
    for (f.insts.items) |*inst| {
        switch (inst.op) {
            .add, .sub => {
                if (smallInt(f, inst.b)) |v| {
                    inst.imm = if (inst.op == .add) v else -v;
                    inst.op = .addi;
                    inst.b = ir.none;
                } else if (inst.op == .add) if (smallInt(f, inst.a)) |v| {
                    inst.imm = v;
                    inst.op = .addi;
                    inst.a = inst.b;
                    inst.b = ir.none;
                };
            },
            .guard, .br => {
                if (smallInt(f, inst.b) == null and smallInt(f, inst.a) != null) {
                    // The constant moves to the right.
                    const t = inst.a;
                    inst.a = inst.b;
                    inst.b = t;
                    const c: ir.Cond = @fromBackingInt(inst.cond);
                    inst.cond = @backingInt(switch (c) {
                        .lt => ir.Cond.gt,
                        .gt => ir.Cond.lt,
                        .le => ir.Cond.ge,
                        .ge => ir.Cond.le,
                        .lo => ir.Cond.hi,
                        .hi => ir.Cond.lo,
                        .ls => ir.Cond.hs,
                        .hs => ir.Cond.ls,
                        else => c,
                    });
                }
                if (smallInt(f, inst.b)) |v| {
                    if (f.at(inst.a).isConst()) continue;
                    inst.imm = v;
                    inst.op = if (inst.op == .guard) .guardi else .bri;
                    inst.b = ir.none;
                }
            },
            else => {},
        }
    }
}

fn smallInt(f: *ir.Func, r: Ref) ?i64 {
    if (r == ir.none) return null;
    const i = f.at(r);
    if (i.op != .kint or i.imm <= -(1 << 30) or i.imm >= (1 << 30)) return null;
    return i.imm;
}

fn resolve(fwd: []Ref, r: Ref) Ref {
    var x = r;
    while (fwd[x] != x) x = fwd[x];
    return x;
}

/// Rewrites every use of a value through the forwarding table.
fn rewrite(f: *ir.Func, fwd: []Ref) !void {
    for (f.insts.items) |*inst| {
        switch (inst.op) {
            .phi, .generic => {},
            else => {
                if (inst.a != ir.none and usesA(inst)) inst.a = resolve(fwd, inst.a);
                if (inst.b != ir.none and usesB(inst)) inst.b = resolve(fwd, inst.b);
                if (inst.c != ir.none) inst.c = resolve(fwd, inst.c);
            },
        }
    }
    for (f.phi_args.items) |*arg| arg.ref = resolve(fwd, arg.ref);
    for (f.snap_entries.items) |*e| e.ref = resolve(fwd, e.ref);
    for (f.snap_frames.items) |*fr| {
        if (fr.closure != ir.none) fr.closure = resolve(fwd, fr.closure);
    }
    for (f.snap_virts.items) |*v| {
        if (v.mt != ir.none) v.mt = resolve(fwd, v.mt);
    }
    for (f.snap_vfields.items) |*x| x.val = resolve(fwd, x.val);
}

pub fn usesA(i: *const ir.Inst) bool {
    return switch (i.op) {
        .nop, .knil, .kbool, .kint, .kflt, .kptr, .sload, .gslot, .scopy, .gpending, .gdebt, .gccheck, .jmp, .brtruthy, .brtag, .generic, .exit, .phi, .valloc, .param, .dlimit => false,
        else => true,
    };
}

pub fn usesB(i: *const ir.Inst) bool {
    return switch (i.op) {
        .add, .sub, .mul, .band, .bor, .bxor, .addsh, .mod, .idiv, .fadd, .fsub, .fmul, .fdiv, .loadx, .store, .storex, .copy_m2m, .guard, .gfcmp, .callc, .barrier, .br, .fbr => true,
        else => false,
    };
}

// ---------------------------------------------------------------------
// Loop-invariant code motion

/// What a loop writes.
const Writes = struct {
    classes: [@typeInfo(ir.Class).@"enum".field_values.len]bool = @splat(false),
    slots: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// The loop runs a template, which may do anything.
    generic: bool = false,
    /// The collector may run in the loop.
    collects: bool = false,
};

/// Moves guards, loads, and arithmetic that compute the same thing on
/// every iteration in front of their loop. A guard that moves leaves
/// optimized code at the first instruction of the loop, before anything
/// in the loop ran, so the interpreter then runs the whole loop.
pub fn hoist(f: *ir.Func, cfg: *Cfg, loops: []const lower.Lower.LoopInfo, marks: []const u8, mark_limit: u8) !void {
    const arena = f.arena;
    // Inner loops come later in the list, and they go first.
    var li = loops.len;
    while (li > 0) {
        li -= 1;
        const info = loops[li];
        const lp = &cfg.loops.items[info.loop];
        const hnode = cfg.nodes.items[lp.header];
        if (marks[hnode.start] >= mark_limit) continue;
        const pre = info.preheader;
        const pre_snap = f.blocks.items[pre].pre_snap;
        if (pre_snap == ir.no_snap) continue;

        // The blocks of the loop, and what they write.
        const in_loop = try arena.alloc(bool, f.blocks.items.len);
        @memset(in_loop, false);
        var w: Writes = .{};
        for (f.blocks.items, 0..) |*blk, bi| {
            if (bi == pre or blk.node >= lp.body.len or !lp.body[blk.node]) continue;
            in_loop[bi] = true;
        }
        const defined_in = try arena.alloc(bool, f.insts.items.len);
        @memset(defined_in, false);
        for (f.blocks.items, 0..) |*blk, bi| {
            if (!in_loop[bi]) continue;
            for (blk.insts.items) |r| {
                defined_in[r] = true;
                const inst = f.at(r);
                switch (inst.op) {
                    .store, .storex, .copy_s2m, .copy_s2n, .copy_m2m => {
                        if (!inst.flags.fresh) w.classes[@backingInt(inst.cls)] = true;
                    },
                    .sstore, .scopy, .copy_m2s => {
                        try w.slots.put(arena, inst.imm, {});
                        if (inst.cls == .upval) w.classes[@backingInt(ir.Class.upval)] = true;
                    },
                    // A callee may write anything.
                    .generic, .dcall => w.generic = true,
                    .gccheck => w.collects = true,
                    .callc => {
                        if (!inst.flags.pure) w.collects = true;
                    },
                    else => {},
                }
            }
        }
        if (w.generic) continue;
        if (w.collects) {
            // The collector clears entries of weak tables and queues
            // finalizers.
            for ([_]ir.Class{ .node_val, .elem, .upval, .gc, .pending }) |c| w.classes[@backingInt(c)] = true;
        }

        // The nodes that close the loop.
        var latches: std.ArrayList(u32) = .empty;
        for (lp.body, 0..) |in, nid| {
            if (!in) continue;
            const nd = cfg.nodes.items[nid];
            for (nd.succs[0..nd.nsuccs]) |s| {
                if (s == lp.header) try latches.append(arena, @intCast(nid));
            }
        }

        // Blocks in the order of the graph, so that an instruction is
        // seen after the ones it depends on.
        for (cfg.order) |nid| {
            if (nid >= lp.body.len or !lp.body[nid]) continue;
            var every = true;
            for (latches.items) |x| {
                if (!cfg.dominates(nid, x)) every = false;
            }
            if (!every) continue;
            for (f.blocks.items, 0..) |*blk, bi| {
                if (!in_loop[bi] or blk.node != nid or !blk.always) continue;
                var keep: std.ArrayList(Ref) = .empty;
                for (blk.insts.items) |r| {
                    const inst = f.at(r);
                    if (movable(inst, &w, defined_in)) {
                        defined_in[r] = false;
                        if (inst.isGuard()) inst.snap = pre_snap;
                        try insertBeforeTerminator(f, pre, r);
                    } else {
                        try keep.append(arena, r);
                    }
                }
                blk.insts = keep;
            }
        }
        try dedupe(f, pre);
    }
}

fn movable(inst: *const ir.Inst, w: *const Writes, defined_in: []const bool) bool {
    const reads_memory = switch (inst.op) {
        .load, .loadx, .gtag, .gbit, .gnokey, .gpending => true,
        .sload, .gslot => blk: {
            if (inst.cls == .fixed) break :blk false;
            if (w.slots.contains(inst.imm)) return false;
            break :blk inst.cls == .upval;
        },
        .add, .sub, .mul, .band, .bor, .bxor, .addi, .neg, .bnot, .addsh, .modi, .idivi => false,
        .fadd, .fsub, .fmul, .fdiv, .fneg, .fabs, .fsqrt, .ffloor, .fceil, .i2f, .f2i, .bits2f, .f2bits => false,
        .guard, .guardi, .gfcmp => false,
        // A division by a register depends on the guards of its
        // divisor.
        .mod, .idiv => false,
        else => return false,
    };
    if (reads_memory and inst.cls != .fixed and inst.cls != .none and w.classes[@backingInt(inst.cls)]) return false;
    const ops = operands(inst);
    for (ops) |o| {
        if (o != ir.none and defined_in[o]) return false;
    }
    return true;
}

fn insertBeforeTerminator(f: *ir.Func, blk: BlockId, r: Ref) !void {
    const list = &f.blocks.items[blk].insts;
    const at = list.items.len - 1;
    try list.insert(f.arena, at, r);
}

const DedupeKey = struct {
    op: ir.Op,
    ty: ir.Ty,
    cond: u8,
    size: u8,
    cls: ir.Class,
    a: Ref,
    b: Ref,
    imm: i64,
    aux: u64,
};

/// Merges equal instructions of a block that writes no memory after its
/// first load, which holds for the code that moved in front of a loop.
fn dedupe(f: *ir.Func, blk: BlockId) !void {
    const arena = f.arena;
    var seen: std.AutoHashMapUnmanaged(DedupeKey, Ref) = .empty;
    const fwd = try arena.alloc(Ref, f.insts.items.len);
    for (fwd, 0..) |*x, i| x.* = @intCast(i);
    var keep: std.ArrayList(Ref) = .empty;
    var any = false;
    for (f.blocks.items[blk].insts.items) |r| {
        const inst = f.at(r);
        switch (inst.op) {
            // Writes end what the earlier loads of the block know.
            .sstore, .scopy, .store, .storex, .copy_m2s, .copy_s2m, .copy_s2n, .copy_m2m, .callc, .gccheck, .generic, .barrier, .dcall, .darg, .dres, .dgate, .dlimit, .param => {
                seen.clearRetainingCapacity();
                try keep.append(arena, r);
                continue;
            },
            .phi, .jmp, .br, .bri, .fbr, .brtruthy, .brtag, .exit, .nop, .dret => {
                try keep.append(arena, r);
                continue;
            },
            else => {},
        }
        if (usesA(inst) and inst.a != ir.none) inst.a = resolve(fwd, inst.a);
        if (usesB(inst) and inst.b != ir.none) inst.b = resolve(fwd, inst.b);
        if (inst.c != ir.none) inst.c = resolve(fwd, inst.c);
        const key: DedupeKey = .{ .op = inst.op, .ty = inst.ty, .cond = inst.cond, .size = inst.size, .cls = inst.cls, .a = inst.a, .b = inst.b, .imm = inst.imm, .aux = inst.aux };
        if (seen.get(key)) |first| {
            fwd[r] = first;
            any = true;
            continue;
        }
        try seen.put(arena, key, r);
        try keep.append(arena, r);
    }
    if (!any) return;
    f.blocks.items[blk].insts = keep;
    try rewrite(f, fwd);
}

// ---------------------------------------------------------------------
// Dead code

fn hasEffect(i: *const ir.Inst) bool {
    return switch (i.op) {
        .sstore, .scopy, .store, .storex, .copy_m2s, .copy_s2m, .copy_s2n, .copy_m2m, .barrier, .gccheck, .darg, .dcall => true,
        .callc => !i.flags.pure,
        .phi => false,
        else => i.isGuard() or i.isTerminator(),
    };
}

/// Marks every instruction that something needs and empties the rest.
pub fn eliminateDead(f: *ir.Func) !void {
    const arena = f.arena;
    var work: std.ArrayList(Ref) = .empty;
    for (f.insts.items) |*inst| inst.flags.live = false;
    for (f.blocks.items) |*blk| {
        for (blk.insts.items) |r| {
            const inst = f.at(r);
            if (hasEffect(inst)) {
                inst.flags.live = true;
                try work.append(arena, r);
            }
        }
    }
    while (work.pop()) |r| {
        const inst = f.at(r).*;
        var refs: std.ArrayList(Ref) = .empty;
        if (inst.op == .phi) {
            for (f.phi_args.items[inst.a..][0..inst.b]) |arg| try refs.append(arena, arg.ref);
        } else if (inst.op != .generic) {
            if (usesA(&inst) and inst.a != ir.none) try refs.append(arena, inst.a);
            if (usesB(&inst) and inst.b != ir.none) try refs.append(arena, inst.b);
            if (inst.c != ir.none) try refs.append(arena, inst.c);
        }
        if (inst.snap != ir.no_snap) {
            const s = f.snaps.items[inst.snap];
            for (f.snap_frames.items[s.frames..][0..s.nframes]) |fr| {
                if (fr.closure != ir.none) try refs.append(arena, fr.closure);
                for (f.snap_entries.items[fr.entries..][0..fr.count]) |e| try refs.append(arena, e.ref);
            }
            for (f.snap_virts.items[s.virts..][0..s.nvirts]) |v| {
                if (v.mt != ir.none) try refs.append(arena, v.mt);
                for (f.snap_vfields.items[v.fields..][0..v.count]) |x| try refs.append(arena, x.val);
            }
        }
        for (refs.items) |x| {
            const t = f.at(x);
            if (!t.flags.live) {
                t.flags.live = true;
                try work.append(arena, x);
            }
        }
    }
    for (f.blocks.items) |*blk| {
        var keep: std.ArrayList(Ref) = .empty;
        for (blk.insts.items) |r| {
            if (f.at(r).flags.live) try keep.append(arena, r);
        }
        blk.insts = keep;
    }
}
