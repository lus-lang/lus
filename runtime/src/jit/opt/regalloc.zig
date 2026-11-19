//! Register allocation for the optimizing tier: a linear scan over the
//! live intervals of the values. A value gets one place for its whole
//! life: a machine register, or a slot of the native stack frame. Values
//! that are live across a call into the runtime take a stack slot, since
//! every register the tier allocates belongs to the callee there.
//! Constants take no place at all.

const std = @import("std");
const ir = @import("ir.zig");
const passes = @import("passes.zig");
const Ref = ir.Ref;
const BlockId = ir.BlockId;

pub const Loc = union(enum) {
    none,
    reg: u8,
    freg: u8,
    spill: u32,
};

pub const Result = struct {
    loc: []Loc,
    /// Blocks in the order the positions follow. Blocks that nothing
    /// reaches are left out.
    order: []BlockId,
    nspill: u32,
};

const Interval = struct {
    ref: Ref,
    start: u32,
    end: u32,
    float: bool,
};

fn needsPlace(i: *const ir.Inst) bool {
    if (i.isConst() or i.op == .valloc) return false;
    return i.ty != .void and i.ty != .nil;
}

pub fn run(f: *ir.Func, ngpr: u8, nfpr: u8) !Result {
    const arena = f.arena;
    const nb = f.blocks.items.len;
    const ni = f.insts.items.len;

    // Reverse postorder of the blocks.
    const seen = try arena.alloc(bool, nb);
    @memset(seen, false);
    var post: std.ArrayList(BlockId) = .empty;
    var stack: std.ArrayList(struct { b: BlockId, i: u8 }) = .empty;
    try stack.append(arena, .{ .b = f.entry, .i = 0 });
    seen[f.entry] = true;
    var sbuf: [4]BlockId = undefined;
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const succ = f.successors(top.b, &sbuf);
        if (top.i < succ.len) {
            const s = succ[top.i];
            top.i += 1;
            if (!seen[s]) {
                seen[s] = true;
                try stack.append(arena, .{ .b = s, .i = 0 });
            }
        } else {
            try post.append(arena, top.b);
            _ = stack.pop();
        }
    }
    const order = try arena.alloc(BlockId, post.items.len);
    for (post.items, 0..) |b, i| order[post.items.len - 1 - i] = b;

    // Positions.
    const pos = try arena.alloc(u32, ni);
    @memset(pos, 0);
    var next: u32 = 2;
    for (order, 0..) |b, oi| {
        const blk = &f.blocks.items[b];
        blk.order = @intCast(oi);
        blk.first_pos = next;
        for (blk.insts.items) |r| {
            // Every phi of a block is defined where the block starts.
            pos[r] = if (f.at(r).op == .phi) blk.first_pos else next;
            next += 2;
        }
        blk.last_pos = next;
        next += 2;
    }

    // Liveness of the values across blocks.
    const words = (ni + 63) / 64;
    const live_in = try arena.alloc(u64, nb * words);
    const live_out = try arena.alloc(u64, nb * words);
    @memset(live_in, 0);
    @memset(live_out, 0);
    const tmp = try arena.alloc(u64, words);
    var used: std.ArrayList(Ref) = .empty;
    var changed = true;
    while (changed) {
        changed = false;
        var oi = order.len;
        while (oi > 0) {
            oi -= 1;
            const b = order[oi];
            const out = live_out[b * words ..][0..words];
            // What the successors need, and what their phis take from
            // this block.
            @memset(tmp, 0);
            for (f.successors(b, &sbuf)) |s| {
                for (tmp, live_in[s * words ..][0..words]) |*x, y| x.* |= y;
                for (f.blocks.items[s].insts.items) |r| {
                    const inst = f.at(r);
                    if (inst.op != .phi) break;
                    // A phi is defined in its block, so it is not live
                    // into it.
                    tmp[r / 64] &= ~(@as(u64, 1) << @intCast(r % 64));
                }
                for (f.blocks.items[s].insts.items) |r| {
                    const inst = f.at(r);
                    if (inst.op != .phi) break;
                    for (f.phi_args.items[inst.a..][0..inst.b]) |arg| {
                        if (arg.pred == b) setBit(tmp, arg.ref);
                    }
                }
            }
            for (out, tmp) |*x, y| {
                if (x.* | y != x.*) changed = true;
                x.* |= y;
            }
            // Backward through the block.
            @memcpy(tmp, out);
            const list = f.blocks.items[b].insts.items;
            var k = list.len;
            while (k > 0) {
                k -= 1;
                const r = list[k];
                const inst = f.at(r);
                tmp[r / 64] &= ~(@as(u64, 1) << @intCast(r % 64));
                if (inst.op == .phi) continue;
                used.clearRetainingCapacity();
                try uses(f, inst, &used);
                for (used.items) |u| setBit(tmp, u);
            }
            const in = live_in[b * words ..][0..words];
            for (in, tmp) |*x, y| {
                if (x.* | y != x.*) changed = true;
                x.* |= y;
            }
        }
    }

    // Intervals.
    const start = try arena.alloc(u32, ni);
    const end = try arena.alloc(u32, ni);
    @memset(start, std.math.maxInt(u32));
    @memset(end, 0);
    for (order) |b| {
        const blk = &f.blocks.items[b];
        const in = live_in[b * words ..][0..words];
        const out = live_out[b * words ..][0..words];
        var r: usize = 0;
        while (r < ni) : (r += 1) {
            if (in[r / 64] & (@as(u64, 1) << @intCast(r % 64)) != 0) start[r] = @min(start[r], blk.first_pos);
            if (out[r / 64] & (@as(u64, 1) << @intCast(r % 64)) != 0) end[r] = @max(end[r], blk.last_pos);
            if (in[r / 64] & (@as(u64, 1) << @intCast(r % 64)) != 0) end[r] = @max(end[r], blk.first_pos);
        }
        for (blk.insts.items) |r2| {
            const inst = f.at(r2);
            start[r2] = @min(start[r2], pos[r2]);
            end[r2] = @max(end[r2], pos[r2]);
            if (inst.op == .phi) continue;
            used.clearRetainingCapacity();
            try uses(f, inst, &used);
            for (used.items) |u| end[u] = @max(end[u], pos[r2]);
        }
    }

    // The values that are live across a call into the runtime, which
    // takes every register. A walk backward through each block that
    // calls finds exactly them.
    const crossing = try arena.alloc(bool, ni);
    @memset(crossing, false);
    for (order) |b| {
        const list = f.blocks.items[b].insts.items;
        var has_call = false;
        for (list) |r| {
            if (f.at(r).op == .callc) has_call = true;
        }
        if (!has_call) continue;
        @memcpy(tmp, live_out[b * words ..][0..words]);
        var k = list.len;
        while (k > 0) {
            k -= 1;
            const r = list[k];
            const inst = f.at(r);
            tmp[r / 64] &= ~(@as(u64, 1) << @intCast(r % 64));
            if (inst.op == .callc) {
                for (tmp, 0..) |w, wi| {
                    var bits = w;
                    while (bits != 0) {
                        const bit: usize = @ctz(bits);
                        crossing[wi * 64 + bit] = true;
                        bits &= bits - 1;
                    }
                }
            }
            if (inst.op == .phi) continue;
            used.clearRetainingCapacity();
            try uses(f, inst, &used);
            for (used.items) |u| setBit(tmp, u);
        }
    }

    var ivs: std.ArrayList(Interval) = .empty;
    for (order) |b| {
        for (f.blocks.items[b].insts.items) |r| {
            const inst = f.at(r);
            if (!needsPlace(inst) or start[r] == std.math.maxInt(u32)) continue;
            try ivs.append(arena, .{ .ref = r, .start = start[r], .end = end[r], .float = inst.ty == .float });
        }
    }
    std.mem.sort(Interval, ivs.items, {}, struct {
        fn lt(_: void, a: Interval, b: Interval) bool {
            return a.start < b.start;
        }
    }.lt);

    // A phi and its arguments like to share a register.
    const hint = try arena.alloc(Ref, ni);
    @memset(hint, ir.none);
    for (f.insts.items, 0..) |inst, idx| {
        if (inst.op != .phi) continue;
        for (f.phi_args.items[inst.a..][0..inst.b]) |arg| {
            if (hint[arg.ref] == ir.none) hint[arg.ref] = @intCast(idx);
            if (hint[idx] == ir.none) hint[idx] = arg.ref;
        }
    }

    const loc = try arena.alloc(Loc, ni);
    @memset(loc, .none);
    var nspill: u32 = 0;
    var active: std.ArrayList(Interval) = .empty;
    var free_g: u64 = (@as(u64, 1) << @intCast(ngpr)) - 1;
    var free_f: u64 = (@as(u64, 1) << @intCast(nfpr)) - 1;
    for (ivs.items) |iv| {
        // Expire what ended. A value that an instruction reads for the
        // last time frees its register for the result.
        var k: usize = 0;
        while (k < active.items.len) {
            const a = active.items[k];
            if (a.end <= iv.start) {
                switch (loc[a.ref]) {
                    .reg => |x| free_g |= @as(u64, 1) << @intCast(x),
                    .freg => |x| free_f |= @as(u64, 1) << @intCast(x),
                    else => {},
                }
                _ = active.swapRemove(k);
            } else k += 1;
        }
        if (crossing[iv.ref]) {
            loc[iv.ref] = .{ .spill = nspill };
            nspill += 1;
            continue;
        }
        const free = if (iv.float) &free_f else &free_g;
        if (free.* == 0) {
            // Spill whichever of the candidates lives longest.
            var victim: ?usize = null;
            var far = iv.end;
            for (active.items, 0..) |a, ai| {
                if (a.float == iv.float and a.end > far) {
                    far = a.end;
                    victim = ai;
                }
            }
            if (victim) |ai| {
                const a = active.items[ai];
                loc[iv.ref] = loc[a.ref];
                loc[a.ref] = .{ .spill = nspill };
                nspill += 1;
                active.items[ai] = iv;
            } else {
                loc[iv.ref] = .{ .spill = nspill };
                nspill += 1;
            }
            continue;
        }
        var pick: u8 = @intCast(@ctz(free.*));
        const h = hint[iv.ref];
        if (h != ir.none) {
            switch (loc[h]) {
                .reg => |x| if (!iv.float and free.* & (@as(u64, 1) << @intCast(x)) != 0) {
                    pick = x;
                },
                .freg => |x| if (iv.float and free.* & (@as(u64, 1) << @intCast(x)) != 0) {
                    pick = x;
                },
                else => {},
            }
        }
        free.* &= ~(@as(u64, 1) << @intCast(pick));
        loc[iv.ref] = if (iv.float) .{ .freg = pick } else .{ .reg = pick };
        try active.append(arena, iv);
    }
    return .{ .loc = loc, .order = order, .nspill = nspill };
}

inline fn setBit(set: []u64, r: Ref) void {
    set[r / 64] |= @as(u64, 1) << @intCast(r % 64);
}

/// Collects the values an instruction needs: its operands, and
/// everything its snapshot writes back.
pub fn uses(f: *ir.Func, inst: *const ir.Inst, out: *std.ArrayList(Ref)) !void {
    if (inst.op != .generic and inst.op != .phi) {
        if (passes.usesA(inst) and inst.a != ir.none) try add(f, out, inst.a);
        if (passes.usesB(inst) and inst.b != ir.none) try add(f, out, inst.b);
        // The third operand is a value only for a few instructions.
        // Elsewhere it names a guard, which has no place.
        if (inst.c != ir.none and (inst.op == .storex or inst.op == .callc)) try add(f, out, inst.c);
    }
    if (inst.snap != ir.no_snap) {
        const s = f.snaps.items[inst.snap];
        for (f.snap_frames.items[s.frames..][0..s.nframes]) |fr| {
            if (fr.closure != ir.none) try add(f, out, fr.closure);
            for (f.snap_entries.items[fr.entries..][0..fr.count]) |e| try add(f, out, e.ref);
        }
        for (f.snap_virts.items[s.virts..][0..s.nvirts]) |v| {
            if (v.mt != ir.none) try add(f, out, v.mt);
            for (f.snap_vfields.items[v.fields..][0..v.count]) |x| try add(f, out, x.val);
        }
    }
}

inline fn add(f: *ir.Func, out: *std.ArrayList(Ref), r: Ref) !void {
    if (needsPlace(f.at(r))) try out.append(f.arena, r);
}
