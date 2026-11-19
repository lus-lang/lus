//! Analysis of bytecode for the optimizing tier: what each instruction
//! reads and writes, which registers are live at each instruction, and
//! the control flow graph that a compilation starts from.

const std = @import("std");
const object = @import("../../vm/object.zig");
const opc = @import("../../compile/opcodes.zig");
const Proto = object.Proto;
const Op = opc.Op;

/// A set of registers.
pub const RegSet = struct {
    w: [4]u64 = @splat(0),

    pub inline fn set(s: *RegSet, r: u32) void {
        if (r < 256) s.w[r >> 6] |= @as(u64, 1) << @intCast(r & 63);
    }
    pub inline fn unset(s: *RegSet, r: u32) void {
        if (r < 256) s.w[r >> 6] &= ~(@as(u64, 1) << @intCast(r & 63));
    }
    pub inline fn has(s: *const RegSet, r: u32) bool {
        return r < 256 and s.w[r >> 6] & (@as(u64, 1) << @intCast(r & 63)) != 0;
    }
    /// Adds the registers `from` up to `to`, exclusive.
    pub fn setRange(s: *RegSet, from: u32, to: u32) void {
        var r = from;
        while (r < to and r < 256) : (r += 1) s.set(r);
    }
    pub fn merge(s: *RegSet, o: RegSet) bool {
        var changed = false;
        for (&s.w, o.w) |*x, y| {
            if (x.* | y != x.*) changed = true;
            x.* |= y;
        }
        return changed;
    }
    pub fn without(s: RegSet, o: RegSet) RegSet {
        var r = s;
        for (&r.w, o.w) |*x, y| x.* &= ~y;
        return r;
    }
};

pub const Effects = struct {
    /// Registers the instruction reads.
    uses: RegSet = .{},
    /// Registers the instruction always writes before anything reads
    /// them again.
    defs: RegSet = .{},
    /// Registers the instruction may write.
    writes: RegSet = .{},
};

/// What the instruction at `pc` does to the registers. Instructions that
/// work on a run of registers up to the stack top count as reading and
/// writing every register from the start of the run.
pub fn effects(p: *const Proto, pc: u32) Effects {
    const ins = p.code[pc];
    const a: u32 = opc.a(ins);
    const b: u32 = opc.b(ins);
    const c: u32 = opc.c(ins);
    const top: u32 = p.max_stack;
    var e: Effects = .{};
    switch (opc.op(ins)) {
        .move => {
            e.uses.set(b);
            e.defs.set(a);
        },
        .loadk, .loadi, .loadf, .loadfalse, .loadtrue, .getupval, .gettabup, .newtable, .newenum, .varargtab => e.defs.set(a),
        .loadnil => e.defs.setRange(a, a + b + 1),
        .setupval => e.uses.set(a),
        .settabup => e.uses.set(c),
        .gettable => {
            e.uses.set(b);
            e.uses.set(c);
            e.defs.set(a);
        },
        .getfield, .getindex, .unm, .not, .len, .bnot => {
            e.uses.set(b);
            e.defs.set(a);
        },
        .settable => {
            e.uses.set(a);
            e.uses.set(b);
            e.uses.set(c);
        },
        .setfield, .setindex => {
            e.uses.set(a);
            e.uses.set(c);
        },
        .self => {
            e.uses.set(b);
            e.defs.set(a);
            e.defs.set(a + 1);
        },
        .add, .sub, .mul, .div, .mod, .pow, .idiv, .band, .bor, .bxor, .shl, .shr => {
            e.uses.set(b);
            e.uses.set(c);
            e.defs.set(a);
        },
        .addk, .subk, .mulk, .divk, .modk, .powk, .idivk, .addi => {
            e.uses.set(b);
            e.defs.set(a);
        },
        .concat, .interp => {
            e.uses.setRange(a, a + b);
            e.defs.set(a);
        },
        .jmp, .ret0, .varargprep, .extraarg, .settop => {},
        .eq, .lt, .le => {
            e.uses.set(a);
            e.uses.set(b);
        },
        .eqk, .lti, .lei, .gti, .gei, .test_, .testnil, .ret1, .tbc, .catchcheck => e.uses.set(a),
        .testset => {
            e.uses.set(b);
            e.writes.set(a);
        },
        .call => {
            if (b != 0) e.uses.setRange(a, a + b) else e.uses.setRange(a, top);
            if (c != 0) e.defs.setRange(a, a + c - 1);
            // The frame of the callee overwrites everything above.
            e.writes.setRange(a, top);
        },
        .tailcall => {
            if (b != 0) e.uses.setRange(a, a + b) else e.uses.setRange(a, top);
        },
        .ret => {
            if (b != 0) e.uses.setRange(a, a + b - 1) else e.uses.setRange(a, top);
        },
        .forprep => {
            e.uses.setRange(a, a + 3);
            e.writes.setRange(a, a + 4);
        },
        .forloop => {
            e.uses.setRange(a, a + 3);
            e.writes.set(a);
            e.writes.set(a + 1);
            e.writes.set(a + 3);
        },
        .tforprep => e.uses.setRange(a, a + 4),
        .tforcall => {
            e.uses.setRange(a, a + 3);
            e.defs.setRange(a + 4, a + 4 + c);
            e.writes.setRange(a + 4, top);
        },
        .tforloop => {
            e.uses.set(a + 4);
            e.writes.set(a + 2);
        },
        .rangeprep => {
            e.uses.setRange(a, a + 4);
            e.writes.setRange(a, a + 4);
        },
        .setlist => {
            if (b != 0) e.uses.setRange(a, a + b + 1) else e.uses.setRange(a, top);
        },
        .closure => {
            e.defs.set(a);
            const child = p.protos[opc.bx(ins)];
            for (child.upvals) |d| if (d.in_stack) e.uses.set(d.index);
        },
        .vararg => {
            if (c != 0) e.defs.setRange(a, a + c - 1) else e.writes.setRange(a, top);
        },
        .close => e.uses.setRange(a, top),
        .slice => {
            e.uses.setRange(b, b + 3);
            e.defs.set(a);
        },
        .query => {
            e.uses.setRange(a + 1, top);
            e.defs.set(a);
        },
        .globaldef => e.uses.set(c),
        .globaldefr => {
            e.uses.set(a);
            e.uses.set(c);
        },
        .moverange => {
            e.uses.setRange(b, top);
            e.writes.setRange(a, top);
        },
    }
    _ = e.writes.merge(e.defs);
    return e;
}

/// The instructions that can follow the one at `pc`.
pub fn successors(p: *const Proto, pc: u32, out: *[3]u32) []u32 {
    const ins = p.code[pc];
    var n: usize = 0;
    switch (opc.op(ins)) {
        .jmp => {
            out[0] = @intCast(@as(i64, pc) + 1 + opc.sj(ins));
            n = 1;
        },
        .eq, .lt, .le, .eqk, .lti, .lei, .gti, .gei, .test_, .testset, .testnil => {
            out[0] = pc + 1;
            out[1] = pc + 2;
            n = 2;
        },
        .forprep => {
            out[0] = pc + 1;
            out[1] = pc + opc.bx(ins) + 2;
            n = 2;
        },
        .forloop, .tforloop => {
            out[0] = pc + 1;
            out[1] = pc + 1 - opc.bx(ins);
            n = 2;
        },
        .tforprep => {
            out[0] = pc + 1 + opc.bx(ins);
            n = 1;
        },
        .rangeprep => {
            out[0] = pc + 1;
            out[1] = pc + opc.bx(ins) + 2;
            out[2] = pc + 1 + opc.c(ins);
            n = 3;
        },
        .ret, .ret0, .ret1, .tailcall => {},
        .setlist => {
            out[0] = pc + 2;
            n = 1;
        },
        else => {
            out[0] = pc + 1;
            n = 1;
        },
    }
    // A target past the end is never reached.
    var m: usize = 0;
    for (out[0..n]) |t| {
        if (t < p.code.len) {
            out[m] = t;
            m += 1;
        }
    }
    return out[0..m];
}

/// What the tier knows about the bytecode of one function, whatever
/// instruction a compilation starts at.
pub const Flow = struct {
    p: *Proto,
    /// Registers that hold a value some later instruction may read, or
    /// that a visible local variable lives in, before each instruction.
    live: []RegSet,
    /// The same after each instruction.
    live_out: []RegSet,
    /// Registers that a closure captures by reference. They always live
    /// in the frame.
    captured: RegSet = .{},
    /// True for every instruction that starts a block.
    leader: []bool,

    pub fn init(arena: std.mem.Allocator, p: *Proto) !*Flow {
        const n = p.code.len;
        const f = try arena.create(Flow);
        f.* = .{
            .p = p,
            .live = try arena.alloc(RegSet, n + 1),
            .live_out = try arena.alloc(RegSet, n + 1),
            .leader = try arena.alloc(bool, n + 1),
        };
        @memset(f.live, .{});
        @memset(f.live_out, .{});
        @memset(f.leader, false);
        for (p.protos) |child| for (child.upvals) |d| {
            if (d.in_stack and !d.by_value) f.captured.set(d.index);
        };
        // Variables to be closed are read when their block ends.
        for (p.code) |ins| switch (opc.op(ins)) {
            .tbc => f.captured.set(opc.a(ins)),
            .tforprep => f.captured.set(@as(u32, opc.a(ins)) + 3),
            else => {},
        };

        // Leaders.
        f.leader[0] = true;
        var buf: [3]u32 = undefined;
        var pc: u32 = 0;
        while (pc < n) : (pc += 1) {
            const succ = successors(p, pc, &buf);
            // A jump ends its block even when it leads to the next
            // instruction.
            if (succ.len != 1 or succ[0] != pc + 1 or opc.op(p.code[pc]) == .jmp) {
                for (succ) |t| f.leader[t] = true;
                f.leader[pc + 1] = true;
            }
            if (opc.op(p.code[pc]) == .setlist) f.leader[pc + 2] = false;
        }
        for (p.handlers) |h| f.leader[h.handler_pc] = true;

        // Liveness, to a fixed point.
        var changed = true;
        while (changed) {
            changed = false;
            pc = @intCast(n);
            while (pc > 0) {
                pc -= 1;
                var out: RegSet = .{};
                for (successors(p, pc, &buf)) |t| _ = out.merge(f.live[t]);
                // An error in a protected range continues at its handler.
                for (p.handlers) |h| {
                    if (pc >= h.start_pc and pc < h.end_pc) _ = out.merge(f.live[h.handler_pc]);
                }
                const e = effects(p, pc);
                var in = out.without(e.defs);
                _ = in.merge(e.uses);
                if (f.live_out[pc].merge(out)) changed = true;
                if (f.live[pc].merge(in)) changed = true;
            }
        }
        // A local variable that is visible stays readable through the
        // debug library, so its register counts as live.
        for (p.locvars) |lv| {
            const end: u32 = if (lv.end_pc == 0) @intCast(n) else @min(lv.end_pc, @as(u32, @intCast(n)));
            pc = lv.start_pc;
            while (pc < end) : (pc += 1) {
                f.live[pc].set(lv.reg);
                if (pc + 1 < end) f.live_out[pc].set(lv.reg);
            }
        }
        return f;
    }
};

/// A node of the control flow graph: a run of instructions with one
/// entry. Peeling a loop makes two nodes for the same run.
pub const Node = struct {
    start: u32,
    /// The last instruction of the run.
    end: u32,
    succs: [3]u32 = @splat(0),
    nsuccs: u8 = 0,
    preds: std.ArrayList(u32) = .empty,
    /// Position in reverse postorder.
    rpo: u32 = 0,
    idom: u32 = 0,
    /// The node has a predecessor that comes later in the order.
    header: bool = false,
    /// For a header: its loop, as an index into `Cfg.loops`.
    loop: u32 = 0,
};

pub const Loop = struct {
    header: u32,
    /// Membership of every node.
    body: []bool,
    /// Registers that the loop reads and may write.
    uses: RegSet = .{},
    writes: RegSet = .{},
    /// The loop contains another loop.
    nested: bool = false,
    size: u32 = 0,
};

/// The control flow graph of a function as one compilation sees it: the
/// nodes that the entry instruction reaches.
pub const Cfg = struct {
    flow: *Flow,
    nodes: std.ArrayList(Node) = .empty,
    /// Nodes in reverse postorder.
    order: []u32 = &.{},
    loops: std.ArrayList(Loop) = .empty,
    entry: u32 = 0,

    pub const Error = error{ OutOfMemory, Irreducible };

    pub fn init(arena: std.mem.Allocator, flow: *Flow, entry_pc: u32, peel: bool) Error!*Cfg {
        const p = flow.p;
        const n = p.code.len;
        const g = try arena.create(Cfg);
        g.* = .{ .flow = flow };
        // The node that starts at each instruction, if one does.
        const node_at = try arena.alloc(u32, n + 1);
        @memset(node_at, std.math.maxInt(u32));
        var work: std.ArrayList(u32) = .empty;
        try work.append(arena, entry_pc);
        var buf: [3]u32 = undefined;
        while (work.pop()) |start| {
            if (node_at[start] != std.math.maxInt(u32)) continue;
            var end = start;
            while (true) {
                const succ = successors(p, end, &buf);
                if (succ.len != 1 or succ[0] != end + 1 or flow.leader[end + 1] or end + 1 == entry_pc) break;
                end += 1;
            }
            node_at[start] = @intCast(g.nodes.items.len);
            try g.nodes.append(arena, .{ .start = start, .end = end });
            for (successors(p, end, &buf)) |t| try work.append(arena, t);
        }
        for (g.nodes.items) |*nd| {
            for (successors(p, nd.end, &buf)) |t| {
                nd.succs[nd.nsuccs] = node_at[t];
                nd.nsuccs += 1;
            }
        }
        g.entry = node_at[entry_pc];
        try g.analyze(arena);
        if (peel) {
            if (try g.peelLoops(arena)) try g.analyze(arena);
        }
        return g;
    }

    /// Orders the nodes, finds dominators, and finds the loops.
    fn analyze(g: *Cfg, arena: std.mem.Allocator) Error!void {
        const count = g.nodes.items.len;
        for (g.nodes.items) |*nd| {
            nd.preds = .empty;
            nd.header = false;
        }
        // Postorder by an explicit stack.
        const state = try arena.alloc(u8, count);
        @memset(state, 0);
        var post: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(struct { n: u32, i: u8 }) = .empty;
        try stack.append(arena, .{ .n = g.entry, .i = 0 });
        state[g.entry] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const nd = &g.nodes.items[top.n];
            if (top.i < nd.nsuccs) {
                const s = nd.succs[top.i];
                top.i += 1;
                if (state[s] == 0) {
                    state[s] = 1;
                    try stack.append(arena, .{ .n = s, .i = 0 });
                }
            } else {
                try post.append(arena, top.n);
                _ = stack.pop();
            }
        }
        g.order = try arena.alloc(u32, post.items.len);
        for (post.items, 0..) |nid, i| {
            const at = post.items.len - 1 - i;
            g.order[at] = nid;
            g.nodes.items[nid].rpo = @intCast(at);
        }
        for (g.order) |nid| {
            const nd = &g.nodes.items[nid];
            for (nd.succs[0..nd.nsuccs]) |s| try g.nodes.items[s].preds.append(arena, nid);
        }
        // Dominators, by the iterative algorithm over the order.
        const undef = std.math.maxInt(u32);
        for (g.nodes.items) |*nd| nd.idom = undef;
        g.nodes.items[g.entry].idom = g.entry;
        var changed = true;
        while (changed) {
            changed = false;
            for (g.order[1..]) |nid| {
                const nd = &g.nodes.items[nid];
                var new: u32 = undef;
                for (nd.preds.items) |pr| {
                    if (g.nodes.items[pr].idom == undef) continue;
                    new = if (new == undef) pr else g.intersect(pr, new);
                }
                if (new != nd.idom) {
                    nd.idom = new;
                    changed = true;
                }
            }
        }
        // Loops. An edge to a node that comes no later in the order
        // closes a loop, and its target must dominate its source.
        g.loops = .empty;
        for (g.order) |nid| {
            const nd = &g.nodes.items[nid];
            for (nd.succs[0..nd.nsuccs]) |s| {
                if (g.nodes.items[s].rpo > nd.rpo) continue;
                if (!g.dominates(s, nid)) return error.Irreducible;
                const h = &g.nodes.items[s];
                if (!h.header) {
                    h.header = true;
                    h.loop = @intCast(g.loops.items.len);
                    const body = try arena.alloc(bool, count);
                    @memset(body, false);
                    body[s] = true;
                    try g.loops.append(arena, .{ .header = s, .body = body });
                }
                // Everything that reaches the source without passing
                // the header belongs to the loop.
                const body = g.loops.items[h.loop].body;
                var todo: std.ArrayList(u32) = .empty;
                if (!body[nid]) {
                    body[nid] = true;
                    try todo.append(arena, nid);
                }
                while (todo.pop()) |x| {
                    for (g.nodes.items[x].preds.items) |pr| {
                        if (!body[pr]) {
                            body[pr] = true;
                            try todo.append(arena, pr);
                        }
                    }
                }
            }
        }
        for (g.loops.items) |*lp| {
            lp.size = 0;
            lp.uses = .{};
            lp.writes = .{};
            lp.nested = false;
            for (lp.body, 0..) |in, nid| {
                if (!in) continue;
                const nd = &g.nodes.items[nid];
                if (nd.header and nid != lp.header) lp.nested = true;
                var pc = nd.start;
                while (pc <= nd.end) : (pc += 1) {
                    const e = effects(g.flow.p, pc);
                    _ = lp.uses.merge(e.uses);
                    _ = lp.writes.merge(e.writes);
                    lp.size += 1;
                }
            }
        }
    }

    fn intersect(g: *Cfg, a: u32, b: u32) u32 {
        var x = a;
        var y = b;
        while (x != y) {
            while (g.nodes.items[x].rpo > g.nodes.items[y].rpo) x = g.nodes.items[x].idom;
            while (g.nodes.items[y].rpo > g.nodes.items[x].rpo) y = g.nodes.items[y].idom;
        }
        return x;
    }

    /// Whether node `a` dominates node `b`.
    pub fn dominates(g: *Cfg, a: u32, b: u32) bool {
        var x = b;
        while (true) {
            if (x == a) return true;
            const up = g.nodes.items[x].idom;
            if (up == x or up == std.math.maxInt(u32)) return false;
            x = up;
        }
    }

    /// Copies the body of every small innermost loop once, in front of
    /// the loop. The copy runs the first iteration, so what it proves
    /// and what it allocates is known when the loop itself starts.
    /// Returns true when the graph changed.
    fn peelLoops(g: *Cfg, arena: std.mem.Allocator) Error!bool {
        var any = false;
        const nloops = g.loops.items.len;
        var li: usize = 0;
        while (li < nloops) : (li += 1) {
            const lp = g.loops.items[li];
            if (lp.nested or lp.size > peel_limit) continue;
            if (g.nodes.items.len > 400) break;
            const old_count = g.nodes.items.len;
            const copy = try arena.alloc(u32, old_count);
            @memset(copy, std.math.maxInt(u32));
            for (lp.body, 0..) |in, nid| {
                if (!in or nid >= old_count) continue;
                copy[nid] = @intCast(g.nodes.items.len);
                const src = g.nodes.items[nid];
                try g.nodes.append(arena, .{ .start = src.start, .end = src.end, .succs = src.succs, .nsuccs = src.nsuccs });
            }
            // Inside the copy, an edge to the header leaves for the real
            // loop, and every other edge stays in the copy.
            for (lp.body, 0..) |in, nid| {
                if (!in or nid >= old_count) continue;
                const c = &g.nodes.items[copy[nid]];
                for (c.succs[0..c.nsuccs]) |*s| {
                    if (s.* != lp.header and s.* < old_count and lp.body[s.*]) s.* = copy[s.*];
                }
            }
            // Edges from outside the loop to its header enter the copy.
            for (g.nodes.items[0..old_count], 0..) |*nd, nid| {
                if (lp.body[nid]) continue;
                for (nd.succs[0..nd.nsuccs]) |*s| {
                    if (s.* == lp.header) s.* = copy[lp.header];
                }
            }
            if (g.entry == lp.header) g.entry = copy[lp.header];
            any = true;
        }
        return any;
    }

    pub const peel_limit = 48;
};
