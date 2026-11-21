//! Builds the intermediate representation of a function from its
//! bytecode. The builder walks the control flow graph in reverse
//! postorder and keeps, for every register, either a typed value or the
//! knowledge that the frame slot holds the register. Each instruction
//! becomes typed operations with guards when the builder can predict the
//! types of its operands, and a call of the baseline template of the
//! instruction when it cannot.
//!
//! Predictions come from three places: the values the frame holds at the
//! moment of the compilation, which the builder follows through tables
//! and upvalues as samples, the slot predictions that the objects in
//! those samples confirm, and the operand types that earlier exits from
//! optimized code recorded.

const std = @import("std");
const ir = @import("ir.zig");
const flow_mod = @import("flow.zig");
const opt = @import("opt.zig");
const state = @import("../../vm/state.zig");
const object = @import("../../vm/object.zig");
const value = @import("../../vm/value.zig");
const table = @import("../../vm/table.zig");
const interp = @import("../../vm/interp.zig");
const gc = @import("../../vm/gc.zig");
const opc = @import("../../compile/opcodes.zig");
const Thread = state.Thread;
const Proto = object.Proto;
const Closure = object.Closure;
const Table = object.Table;
const String = object.String;
const Value = value.Value;
const Tag = value.Tag;
const Ref = ir.Ref;
const Ty = ir.Ty;
const BlockId = ir.BlockId;
const Inst = ir.Inst;
const Flow = flow_mod.Flow;
const Cfg = flow_mod.Cfg;
const RegSet = flow_mod.RegSet;
const tl = table.layout;
/// The displacement of the tags of node `idx` from the first node of a
/// hash part. The tag of the key is at `tl.tag_key` from there, and the
/// tag of the value at `tl.tag_val`.
fn tagDisp(idx: usize) i32 {
    return -@as(i32, @intCast(idx << tl.tag_shift));
}
const il = interp.layout;

/// `NotDirect` means that the function needs its frame while it runs,
/// so it is built again as a function that keeps one.
pub const Error = error{ OutOfMemory, Unsupported, Rebuild, NotDirect };

/// What the builder expects a value to be: its tag, and the value itself
/// when the builder could read it.
pub const Sample = struct {
    tag: ?Tag = null,
    v: Value = .nil,
    exact: bool = false,

    fn of(v: Value) Sample {
        return .{ .tag = v.tag, .v = v, .exact = true };
    }
    fn tagged(t: Tag) Sample {
        return .{ .tag = t };
    }
    fn ty(s: Sample) ?Ty {
        const t = s.tag orelse return null;
        const r = Ty.fromTag(t);
        return if (r == .void) null else r;
    }
    fn tableOf(s: Sample) ?*Table {
        return if (s.exact and s.v.tag == .table) s.v.as(Table) else null;
    }
};

/// What the builder knows about one register.
const Reg = struct {
    /// The typed value of the register, or none.
    val: Ref = ir.none,
    /// The frame slot holds the register.
    in_slot: bool = true,
    /// Without a value: the type of what the slot holds, when known.
    ty: ?Ty = null,
    sample: Sample = .{},
};

const Incoming = struct {
    from: BlockId,
    regs: []Reg,
    /// The tables that are not allocated on this edge.
    vobjs: []VObj = &.{},
};

const max_vfields = 8;

/// A table that the function made and that no code allocated: the
/// builder keeps its fields as values. `ref` is the `valloc` instruction
/// that registers and snapshots name it by.
const VObj = struct {
    ref: Ref,
    /// Hash slots the constructor asked for, and the mask of the hash
    /// part they give.
    nc: u32,
    mask: u32,
    used: u32 = 0,
    keys: [max_vfields]*String = undefined,
    nodes: [max_vfields]u32 = undefined,
    vals: [max_vfields]Ref = undefined,
    mt: Ref = ir.none,
    mt_sample: ?*Table = null,
};

/// A table that a loop carries unallocated from one iteration to the
/// next: every field is a phi of the loop header.
const HVirt = struct {
    obj: VObj,
    mt_phi: Ref = ir.none,
};

const HeaderState = struct {
    block: BlockId,
    regs: []Reg,
    /// The loop counts with a numeric `for` whose base register this is.
    for_base: ?u32 = null,
    /// The largest index the loop reaches, computed before the loop.
    for_last: Ref = ir.none,
    for_init: Ref = ir.none,
    for_phi: Ref = ir.none,
    virts: []HVirt = &.{},
};

/// One function being built: the root, or a call compiled inline.
const Frame = struct {
    proto: *Proto,
    flow: *Flow,
    cfg: *Cfg,
    info: *opt.Info,
    /// Slot of register zero.
    off: u32,
    regs: []Reg,
    parent: ?*Frame = null,
    /// The closure that runs, as a value and as the builder saw it.
    closure: Ref = ir.none,
    closure_sample: ?*Closure = null,
    // For an inline frame: the call in the parent.
    call_pc: u32 = 0,
    want: i32 = 0,
    tail: bool = false,
    depth: u32 = 0,
    /// Per node: the edges that reach it and are not merged yet.
    incoming: []std.ArrayList(Incoming),
    built: []bool,
    headers: []?HeaderState,
    /// For an inline frame: where its returns are collected. A frame
    /// that replaces another one by a tail call shares the list.
    returns: ?*std.ArrayList(Return) = null,
};

/// A return of an inline frame: the block it leaves, and the result.
const Return = struct {
    from: BlockId,
    res: Reg,
    vobjs: []VObj = &.{},
};

/// Decisions that survive a rebuild of the same function.
pub const Persist = struct {
    /// Per loop header instruction: registers that live in the frame
    /// across the loop.
    demote: std.AutoHashMapUnmanaged(u32, RegSet) = .empty,
    /// Per loop header instruction: registers whose slot type the loop
    /// changes.
    untype: std.AutoHashMapUnmanaged(u32, RegSet) = .empty,
    /// Call instructions of the root that stay calls.
    no_inline: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Loop header instructions whose loop allocates its tables before
    /// it starts.
    no_sink: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The function is built for direct entry (`ir.Func.direct`).
    direct: bool = false,
    /// What a direct call of the function itself returns and writes, as
    /// the last build found it. The first build predicts an integer.
    self_ret: ?Ty = .int,
    self_writes: u32 = 0,
    /// Builds that changed the two predictions.
    self_rounds: u32 = 0,
};

const CseKey = struct {
    op: ir.Op,
    ty: Ty,
    cond: u8,
    size: u8,
    a: Ref,
    b: Ref,
    imm: i64,
    aux: u64,
    ver: u32,
};

/// A table that the function allocated and that nothing else can reach
/// yet. The builder knows which node holds each of its keys.
const Fresh = struct {
    ref: Ref,
    mask: u32,
    used: u32 = 0,
    keys: [12]?*String = @splat(null),
    nodes: [12]u32 = @splat(0),
    metatable: bool = false,
};

const class_count = @typeInfo(ir.Class).@"enum".field_values.len;

pub const Lower = struct {
    arena: std.mem.Allocator,
    l: *Thread,
    /// The base of the running frame of the root function, whose slots
    /// hold what its registers held when the build started.
    root_base: ?u32 = null,
    f: *ir.Func,
    persist: *Persist,
    fr: *Frame,
    root: *Frame,
    cur: BlockId = 0,
    pc: u32 = 0,
    /// The node of the root that the code being built belongs to.
    root_node: u32 = 0,
    /// The node of the current frame that is being built.
    node: u32 = 0,
    always: bool = true,
    /// The instruction after the current one was compiled with it.
    skip_next: bool = false,
    /// Functions compiled inline.
    inlined: std.ArrayList(*Proto) = .empty,
    /// The tables that are not allocated at the current point.
    vobjs: std.ArrayList(VObj) = .empty,
    cse: std.AutoHashMapUnmanaged(CseKey, Ref) = .empty,
    epochs: [class_count]u32 = @splat(1),
    slot_ver: std.ArrayList(u32) = .empty,
    snap_cache: u32 = ir.no_snap,
    fresh: ?Fresh = null,
    rebuild: bool = false,
    hash_ptr: i32,
    hash_len: i32,
    /// Loops of the function, for the passes.
    loops: std.ArrayList(LoopInfo) = .empty,
    /// Number of instructions that became typed operations.
    specialized: u32 = 0,
    /// The function is built for direct entry.
    direct: bool = false,
    /// The function calls itself directly.
    self_calls: bool = false,
    /// The type of every return so far, and whether two returns differ.
    ret_seen: ?Ty = null,
    ret_mixed: bool = false,
    /// The memory classes that the direct callees of the function write.
    callee_writes: u32 = 0,

    pub const LoopInfo = struct {
        header: BlockId,
        preheader: BlockId,
        /// Index of the loop in the graph of the root.
        loop: u32,
    };

    // -----------------------------------------------------------------
    // Entry

    /// Builds the function `p` from the instruction `entry_pc`, with the
    /// running frame of the thread as the sample of its registers.
    pub fn build(arena: std.mem.Allocator, l: *Thread, p: *Proto, entry_pc: u32, persist: *Persist, out_loops: *[]LoopInfo, out_cfg: **Cfg, out_inlined: *[]*Proto) Error!*ir.Func {
        const fl = try Flow.init(arena, p);
        const cfg = Cfg.init(arena, fl, entry_pc, true) catch |e| switch (e) {
            error.Irreducible => return error.Unsupported,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const func = try arena.create(ir.Func);
        func.* = try ir.Func.init(arena);
        const fr = try newFrame(arena, l, p, fl, cfg, 0);
        const live_fr = l.frame();
        fr.closure_sample = live_fr.closure;
        func.extent = p.max_stack;
        var b: Lower = .{
            .arena = arena,
            .l = l,
            .f = func,
            .persist = persist,
            .fr = fr,
            .root = fr,
            .hash_ptr = tl.hashPtr(),
            .hash_len = tl.hashLen(),
        };
        const entry = try func.newBlock();
        func.entry = entry;
        b.cur = entry;
        func.blocks.items[entry].node = cfg.entry;
        if (persist.direct) {
            if (entry_pc != 0 or !directCandidate(p, fl)) return b.notDirect("shape", 0);
            b.direct = true;
            func.direct = true;
            try b.directEntry(live_fr.base);
        } else {
            // Every register starts in its slot, and the frame says what
            // each one holds right now.
            for (fr.regs, 0..) |*r, i| {
                r.* = .{ .sample = Sample.of(l.stack[live_fr.base + i]) };
            }
            b.root_base = live_fr.base;
        }
        try fr.incoming[cfg.entry].append(arena, try b.incomingOf(entry));
        try b.buildFrame();
        if (b.rebuild) return error.Rebuild;
        if (b.direct) try b.finishDirect();
        out_inlined.* = b.inlined.items;
        out_loops.* = b.loops.items;
        out_cfg.* = cfg;
        return func;
    }

    /// Whether the bytecode of `p` allows direct entry at all: a fixed
    /// and small number of parameters, and a frame that nothing refers
    /// to while the function runs.
    fn directCandidate(p: *const Proto, fl: *const Flow) bool {
        if (p.is_vararg or p.num_params > ir.max_direct_params or p.handlers.len != 0) return false;
        for (fl.captured.w) |w| {
            if (w != 0) return false;
        }
        return true;
    }

    /// Starts a function that is entered directly. Its closure and its
    /// parameters arrive in machine registers with the types the running
    /// frame shows, and every other register starts nil. No register
    /// ever lives in its slot.
    fn directEntry(b: *Lower, base: u32) Error!void {
        const fr = b.fr;
        const p = fr.proto;
        // The entries that find a frame in place leave through this
        // snapshot when an argument has another type.
        b.f.entry_snap = try b.snapAt(0);
        fr.closure = try b.emit(.{ .op = .param, .ty = .closure, .imm = 0 });
        for (fr.regs, 0..) |*r, i| {
            if (i >= p.num_params) {
                r.* = .{ .val = try b.knil(), .in_slot = false, .sample = Sample.of(.nil) };
                continue;
            }
            const sample = Sample.of(b.l.stack[base + i]);
            const ty = sample.ty() orelse return b.notDirect("parameter", 0);
            b.f.sig[i] = ty;
            const v = if (ty == .nil) try b.knil() else try b.emit(.{ .op = .param, .ty = ty, .imm = @intCast(i + 1) });
            r.* = .{ .val = v, .in_slot = false, .sample = sample };
        }
        const s = try b.snapAt(0);
        b.f.snaps.items[s].quiet = true;
        _ = try b.emit(.{ .op = .dlimit, .snap = s });
        b.snap_cache = ir.no_snap;
    }

    /// Checks what the build of a directly entered function produced.
    /// Anything that reads or writes a slot of the frame sends the
    /// function back to be built with a frame. The type its returns
    /// yield and the memory it writes are what its own direct calls
    /// assumed, or the function builds again with what was found.
    fn finishDirect(b: *Lower) Error!void {
        const f = b.f;
        var writes: u32 = b.callee_writes;
        for (f.blocks.items) |blk| {
            for (blk.insts.items) |r| {
                const i = f.at(r);
                switch (i.op) {
                    .sload, .gslot, .sstore, .scopy, .copy_m2s, .copy_s2m, .copy_s2n, .brtruthy, .brtag, .generic, .gccheck => return b.notDirect(@tagName(i.op), 0),
                    .barrier => {
                        if (i.aux & 3 == 2) return b.notDirect("barrier", 0);
                        writes |= classBit(.gc);
                    },
                    .store, .storex, .copy_m2m => {
                        if (!i.flags.fresh) writes |= classBit(i.cls);
                    },
                    .callc => {
                        if (!i.flags.pure) writes = all_classes;
                    },
                    else => {},
                }
            }
        }
        const ret: ?Ty = if (b.ret_mixed) null else b.ret_seen;
        f.ret_ty = ret;
        f.writes = writes;
        if (!b.self_calls) return;
        const same_ret = if (ret) |t| (if (b.persist.self_ret) |u| t == u else false) else b.persist.self_ret == null;
        if (same_ret and writes & ~b.persist.self_writes == 0) return;
        b.persist.self_rounds += 1;
        // A type that keeps changing is no prediction.
        b.persist.self_ret = if (b.persist.self_rounds > 2) null else ret;
        b.persist.self_writes |= writes;
        if (b.l.g.jit.opt_dump) std.debug.print("  rebuild: the function returns and writes something else to itself\n", .{});
        return error.Rebuild;
    }

    /// Gives up direct entry, and says why when the tier lists its work.
    fn notDirect(b: *Lower, what: []const u8, pc: u32) Error {
        if (b.l.g.jit.opt_dump) std.debug.print("  the function keeps a frame: {s} at {d}\n", .{ what, pc });
        return error.NotDirect;
    }

    const all_classes: u32 = (1 << class_count) - 1;

    fn classBit(c: ir.Class) u32 {
        return @as(u32, 1) << @intCast(@backingInt(c));
    }

    fn newFrame(arena: std.mem.Allocator, l: *Thread, p: *Proto, fl: *Flow, cfg: *Cfg, off: u32) Error!*Frame {
        const fr = try arena.create(Frame);
        const n = cfg.nodes.items.len;
        fr.* = .{
            .proto = p,
            .flow = fl,
            .cfg = cfg,
            .info = opt.infoOf(l.g, p) orelse return error.OutOfMemory,
            .off = off,
            .regs = try arena.alloc(Reg, p.max_stack),
            .incoming = try arena.alloc(std.ArrayList(Incoming), n),
            .built = try arena.alloc(bool, n),
            .headers = try arena.alloc(?HeaderState, n),
        };
        @memset(fr.regs, .{});
        @memset(fr.incoming, .empty);
        @memset(fr.built, false);
        @memset(fr.headers, null);
        return fr;
    }

    /// Builds every node of the current frame that an edge reaches.
    fn buildFrame(b: *Lower) Error!void {
        const fr = b.fr;
        for (fr.cfg.order) |nid| {
            if (fr.incoming[nid].items.len == 0) continue;
            try b.enterNode(nid);
            fr.built[nid] = true;
            const nd = fr.cfg.nodes.items[nid];
            var pc = nd.start;
            var open = true;
            while (pc <= nd.end and open) : (pc += 1) {
                b.pc = pc;
                b.snap_cache = ir.no_snap;
                b.fr = fr;
                b.node = nid;
                open = try b.instruction(pc, pc == nd.end);
                if (b.rebuild) return;
                if (b.skip_next) {
                    b.skip_next = false;
                    pc += 1;
                }
            }
            // A node that runs into the next one.
            b.node = nid;
            if (open) {
                if (nd.nsuccs == 1) {
                    const e = try b.edgeTo(nd.succs[0]);
                    _ = try b.emit(.{ .op = .jmp, .t = e });
                    try b.finishEdges();
                } else {
                    _ = try b.emit(.{ .op = .exit, .snap = try b.snapAt(nd.end + 1) });
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Emission

    fn emit(b: *Lower, i: Inst) Error!Ref {
        return b.f.add(b.cur, i);
    }

    fn emitIn(b: *Lower, blk: BlockId, i: Inst) Error!Ref {
        return b.f.add(blk, i);
    }

    fn version(b: *Lower, i: *const Inst) u32 {
        return switch (i.cls) {
            .none, .fixed => 0,
            .slot => blk: {
                const s: usize = @intCast(i.imm + 1);
                break :blk if (s < b.slot_ver.items.len) b.slot_ver.items[s] else 0;
            },
            else => b.epochs[@backingInt(i.cls)],
        };
    }

    fn keyOf(b: *Lower, i: *const Inst) CseKey {
        return .{ .op = i.op, .ty = i.ty, .cond = i.cond, .size = i.size, .a = i.a, .b = i.b, .imm = i.imm, .aux = i.aux, .ver = b.version(i) };
    }

    /// Emits an instruction whose result depends only on its operands
    /// and on the memory class it reads, or returns the earlier one of
    /// the same block that still holds.
    fn pure(b: *Lower, i: Inst) Error!Ref {
        const key = b.keyOf(&i);
        if (b.cse.get(key)) |r| return r;
        const r = try b.emit(i);
        try b.cse.put(b.arena, key, r);
        return r;
    }

    fn guard(b: *Lower, i: Inst) Error!Ref {
        var g = i;
        const key = b.keyOf(&g);
        if (b.cse.get(key)) |r| return r;
        g.snap = try b.snap();
        const r = try b.emit(g);
        try b.cse.put(b.arena, key, r);
        return r;
    }

    fn clobber(b: *Lower, cls: ir.Class) void {
        b.epochs[@backingInt(cls)] +%= 1;
    }

    fn clobberSlot(b: *Lower, slot: i64) Error!void {
        const s: usize = @intCast(slot + 1);
        while (b.slot_ver.items.len <= s) try b.slot_ver.append(b.arena, 0);
        b.slot_ver.items[s] += 1;
    }

    /// Forgets everything the block knows about memory.
    fn clobberAll(b: *Lower) void {
        for (&b.epochs) |*e| e.* +%= 1;
        for (b.slot_ver.items) |*v| v.* += 1;
        b.cse.clearRetainingCapacity();
        b.fresh = null;
    }

    fn kint(b: *Lower, v: i64) Error!Ref {
        return b.pure(.{ .op = .kint, .ty = .int, .imm = v });
    }
    fn kflt(b: *Lower, v: f64) Error!Ref {
        return b.pure(.{ .op = .kflt, .ty = .float, .imm = @bitCast(v) });
    }
    fn knil(b: *Lower) Error!Ref {
        return b.pure(.{ .op = .knil, .ty = .nil });
    }
    fn kbool(b: *Lower, v: bool) Error!Ref {
        return b.pure(.{ .op = .kbool, .ty = .boolean, .imm = @intFromBool(v) });
    }
    fn kptr(b: *Lower, ty: Ty, addr: usize) Error!Ref {
        return b.pure(.{ .op = .kptr, .ty = ty, .imm = @bitCast(@as(u64, addr)) });
    }

    /// The constant `v` as a value, or null for a constant the tier keeps
    /// out of registers.
    fn konst(b: *Lower, v: Value) Error!?Ref {
        return switch (v.tag) {
            .nil => try b.knil(),
            .false => try b.kbool(false),
            .true => try b.kbool(true),
            .integer => try b.kint(v.asInt()),
            .float => try b.kflt(v.asFloat()),
            .string => try b.kptr(.string, v.address()),
            else => null,
        };
    }

    inline fn tyOf(b: *Lower, r: Ref) Ty {
        return b.f.at(r).ty;
    }

    fn load(b: *Lower, base: Ref, disp: i32, ty: Ty, size: u8, cls: ir.Class, dep: Ref) Error!Ref {
        return b.pure(.{ .op = .load, .ty = ty, .size = size, .cls = cls, .a = base, .imm = disp, .c = dep });
    }

    fn store(b: *Lower, base: Ref, disp: i32, v: Ref, size: u8, cls: ir.Class, fresh: bool) Error!Ref {
        if (!fresh) b.clobber(cls);
        const st = try b.emit(.{ .op = .store, .size = size, .cls = cls, .a = base, .b = v, .imm = disp, .flags = .{ .fresh = fresh } });
        // A load of the same word yields the stored value.
        if (size == 8) {
            const probe: Inst = .{ .op = .load, .ty = b.tyOf(v), .size = 8, .cls = cls, .a = base, .imm = disp };
            try b.cse.put(b.arena, b.keyOf(&probe), v);
        }
        return st;
    }

    /// Stores the typed value `v` as a whole value at [base + disp].
    fn storeValue(b: *Lower, base: Ref, disp: i32, v: Ref, cls: ir.Class, fresh: bool) Error!void {
        return b.storeValueAt(base, disp, disp + 8, 8, v, cls, fresh);
    }

    /// `storeValue` for a value whose payload goes to `disp` and whose
    /// tag goes to `tdisp`, as a word, or as a byte when `tsize` is 1, as
    /// in a hash node.
    fn storeValueAt(b: *Lower, base: Ref, disp: i32, tdisp: i32, tsize: u8, v: Ref, cls: ir.Class, fresh: bool) Error!void {
        const ty = b.tyOf(v);
        var tag_store: Ref = undefined;
        switch (ty) {
            .nil => {
                _ = try b.store(base, disp, try b.kint(0), 8, cls, fresh);
                tag_store = try b.store(base, tdisp, try b.kint(0), tsize, cls, fresh);
            },
            .boolean => {
                _ = try b.store(base, disp, try b.kint(0), 8, cls, fresh);
                const tag = try b.pure(.{ .op = .addi, .ty = .int, .a = v, .imm = @backingInt(Tag.false) });
                tag_store = try b.store(base, tdisp, tag, tsize, cls, fresh);
                // The payload word is not the boolean.
                const stale: Inst = .{ .op = .load, .ty = .int, .size = 8, .cls = cls, .a = base, .imm = disp };
                _ = b.cse.remove(b.keyOf(&stale));
                return;
            },
            else => {
                // The payload first, so that the tag store leaves its
                // load known.
                tag_store = try b.store(base, tdisp, try b.kint(@backingInt(ty)), tsize, cls, fresh);
                _ = try b.store(base, disp, v, 8, cls, fresh);
            },
        }
        // The tag that was stored is known.
        const probe: Inst = .{ .op = .gtag, .cls = cls, .a = base, .imm = tdisp, .aux = ty.guardTag(), .cond = @backingInt(ir.Cond.eq) };
        try b.cse.put(b.arena, b.keyOf(&probe), tag_store);
    }

    // -----------------------------------------------------------------
    // Snapshots

    fn snap(b: *Lower) Error!u32 {
        if (b.snap_cache != ir.no_snap) return b.snap_cache;
        b.snap_cache = try b.snapAt(b.pc);
        return b.snap_cache;
    }

    /// A snapshot that continues the current frame at `pc`.
    fn snapAt(b: *Lower, pc: u32) Error!u32 {
        return b.snapWith(pc, b.fr.regs, b.vobjs.items);
    }

    /// A snapshot that continues the current frame at `pc` with the
    /// given state of its registers and of the unallocated tables.
    fn snapWith(b: *Lower, pc: u32, inner_regs: []const Reg, vobjs: []const VObj) Error!u32 {
        return b.snapFull(pc, inner_regs, vobjs, null);
    }

    /// The register and the closure of a direct call that a snapshot
    /// describes the caller of.
    const Waiting = struct {
        ra: u32,
        closure: Ref,
    };

    /// A snapshot of the current frame while the direct call at the
    /// current instruction runs. The frame continues after the call,
    /// without what the call writes, and the slot of the called function
    /// holds its closure, as it does in the interpreter.
    fn snapCall(b: *Lower, ra: u32, closure: Ref) Error!u32 {
        return b.snapFull(b.pc + 1, b.fr.regs, b.vobjs.items, .{ .ra = ra, .closure = closure });
    }

    fn snapFull(b: *Lower, pc: u32, inner_regs: []const Reg, vobjs: []const VObj, waiting: ?Waiting) Error!u32 {
        const f = b.f;
        const first_entry: u32 = @intCast(f.snap_entries.items.len);
        // Frames from the root to the current one.
        var chain: [opt.max_inline_depth + 1]*Frame = undefined;
        var n: usize = 0;
        var it: ?*Frame = b.fr;
        while (it) |x| : (it = x.parent) {
            chain[n] = x;
            n += 1;
        }
        const first: u32 = @intCast(f.snap_frames.items.len);
        var i = n;
        while (i > 0) {
            i -= 1;
            const fr = chain[i];
            const inner = i == 0;
            // A frame that waits for a call continues after the call,
            // without what the call writes.
            const at: u32 = if (inner) pc else chain[i - 1].call_pc + 1;
            var live = if (at < fr.flow.live.len) fr.flow.live[at] else RegSet{};
            if (!inner or waiting != null) {
                const e = flow_mod.effects(fr.proto, at - 1);
                live = fr.flow.live_out[at - 1].without(e.writes);
                if (at < fr.flow.live.len) {
                    var scope = fr.flow.live[at];
                    scope = scope.without(e.writes);
                    _ = live.merge(scope);
                }
            }
            const start: u32 = @intCast(f.snap_entries.items.len);
            if (fr.parent != null) try f.snap_entries.append(b.arena, .{ .slot = fr.off - 1, .ref = fr.closure });
            const regs: []const Reg = if (inner) inner_regs else fr.regs;
            for (regs, 0..) |r, ri| {
                if (r.in_slot or !live.has(@intCast(ri))) continue;
                try f.snap_entries.append(b.arena, .{ .slot = fr.off + @as(u32, @intCast(ri)), .ref = r.val });
            }
            if (inner) if (waiting) |w| {
                try f.snap_entries.append(b.arena, .{ .slot = fr.off + w.ra, .ref = w.closure });
            };
            try f.snap_frames.append(b.arena, .{
                .proto = fr.proto,
                // The frame of the root exists, or is built from the
                // call that entered it.
                .closure = if (fr.parent != null) fr.closure else ir.none,
                .off = fr.off,
                .pc = at,
                .want = fr.want,
                .tail = fr.tail,
                .entries = start,
                .count = @as(u32, @intCast(f.snap_entries.items.len)) - start,
            });
        }
        // The tables that the entries name and no code allocated.
        const first_virt: u32 = @intCast(f.snap_virts.items.len);
        var roots: u32 = 0;
        if (vobjs.len != 0) {
            for (f.snap_entries.items[first_entry..]) |e| {
                const v = for (vobjs) |*x| {
                    if (x.ref == e.ref) break x;
                } else continue;
                var known = false;
                for (f.snap_virts.items[first_virt..]) |sv| {
                    if (sv.ref == v.ref) known = true;
                }
                if (known) continue;
                const fields: u32 = @intCast(f.snap_vfields.items.len);
                for (v.keys[0..v.used], v.nodes[0..v.used], v.vals[0..v.used]) |k, nidx, val| {
                    try f.snap_vfields.append(b.arena, .{ .key = @intFromPtr(k), .node = nidx, .val = val });
                    if (b.tyOf(val).collectable()) roots += 1;
                }
                if (v.mt != ir.none) roots += 1;
                try f.snap_virts.append(b.arena, .{ .ref = v.ref, .nc = v.nc, .mt = v.mt, .fields = fields, .count = v.used });
            }
        }
        f.scratch = @max(f.scratch, roots);
        const nvirts = @as(u32, @intCast(f.snap_virts.items.len)) - first_virt;
        if (nvirts > 8) return error.Unsupported;
        try f.snaps.append(b.arena, .{ .frames = first, .nframes = @intCast(n), .virts = first_virt, .nvirts = nvirts });
        return @intCast(f.snaps.items.len - 1);
    }

    // -----------------------------------------------------------------
    // Registers

    inline fn slotOf(b: *Lower, r: u32) i64 {
        return @as(i64, b.fr.off) + r;
    }

    fn captured(b: *Lower, r: u32) bool {
        return b.fr.flow.captured.has(r);
    }

    fn marks(b: *Lower) u8 {
        return b.fr.info.marks[b.pc];
    }

    /// The type the builder expects in register `r`, operand `which` of
    /// the current instruction (0, 1, 2 for A, B, C): the static type,
    /// what an earlier exit saw there, or the sample.
    fn guess(b: *Lower, r: u32, which: u2) ?Ty {
        const reg = &b.fr.regs[r];
        if (reg.val != ir.none) return b.tyOf(reg.val);
        if (reg.ty) |t| return t;
        const fb = b.fr.info.fb[b.pc][which];
        if (fb != opt.no_feedback) {
            const t = Ty.fromTag(@fromBackingInt(fb));
            if (t != .void) return t;
        }
        return reg.sample.ty();
    }

    fn staticTy(b: *Lower, r: u32) ?Ty {
        const reg = &b.fr.regs[r];
        if (reg.val != ir.none) return b.tyOf(reg.val);
        return reg.ty;
    }

    /// Register `r` as a value of type `ty`. A register whose type is
    /// unknown is guarded.
    fn typed(b: *Lower, r: u32, ty: Ty) Error!Ref {
        const reg = &b.fr.regs[r];
        if (reg.val != ir.none) {
            std.debug.assert(b.tyOf(reg.val) == ty);
            // A use that needs the table itself allocates it.
            if (b.virtIndex(reg.val) != null) return b.materialize(reg.val);
            return reg.val;
        }
        const slot = b.slotOf(r);
        const cls: ir.Class = if (b.captured(r)) .upval else .slot;
        var dep: Ref = ir.none;
        if (reg.ty == null or reg.ty.? != ty) {
            dep = try b.guard(.{ .op = .gslot, .cls = cls, .imm = slot, .aux = ty.guardTag() });
        }
        const v = switch (ty) {
            .nil => try b.knil(),
            else => try b.pure(.{ .op = .sload, .ty = ty, .cls = cls, .imm = slot, .c = dep }),
        };
        if (!b.captured(r)) {
            reg.val = v;
            reg.ty = ty;
        }
        return v;
    }

    /// Register `r` as a value when its type is known or can be guessed.
    fn anyTyped(b: *Lower, r: u32, which: u2) Error!?Ref {
        const ty = b.guess(r, which) orelse return null;
        return try b.typed(r, ty);
    }

    fn setReg(b: *Lower, r: u32, value_ref: Ref, sample: Sample) Error!void {
        b.snap_cache = ir.no_snap;
        var v = value_ref;
        if (b.captured(r) and b.virtIndex(v) != null) v = try b.materialize(v);
        const reg = &b.fr.regs[r];
        if (b.captured(r)) {
            // A captured register is written through at once.
            try b.clobberSlot(b.slotOf(r));
            b.clobber(.upval);
            _ = try b.emit(.{ .op = .sstore, .cls = .upval, .a = v, .imm = b.slotOf(r) });
            reg.* = .{ .sample = sample };
            return;
        }
        var s = sample;
        if (s.tag == null) {
            const ty = b.tyOf(v);
            if (ty != .boolean) s = Sample.tagged(@fromBackingInt(@backingInt(ty)));
        }
        reg.* = .{ .val = v, .in_slot = false, .ty = null, .sample = s };
    }

    /// Records that the slot of register `r` was written directly.
    fn setSlot(b: *Lower, r: u32, ty: ?Ty, sample: Sample) Error!void {
        b.snap_cache = ir.no_snap;
        try b.clobberSlot(b.slotOf(r));
        if (b.captured(r)) b.clobber(.upval);
        b.fr.regs[r] = .{ .ty = if (b.captured(r)) null else ty, .sample = sample };
    }

    /// Writes register `r` to its slot if the slot is behind.
    fn flush(b: *Lower, r: u32) Error!void {
        if (b.fr.regs[r].in_slot) return;
        if (b.virtIndex(b.fr.regs[r].val) != null) _ = try b.materialize(b.fr.regs[r].val);
        const reg = &b.fr.regs[r];
        try b.clobberSlot(b.slotOf(r));
        _ = try b.emit(.{ .op = .sstore, .cls = .slot, .a = reg.val, .imm = b.slotOf(r) });
        reg.in_slot = true;
        // The slot now holds the value, so a load of it is the value.
        const probe: Inst = .{ .op = .sload, .ty = b.tyOf(reg.val), .cls = .slot, .imm = b.slotOf(r) };
        try b.cse.put(b.arena, b.keyOf(&probe), reg.val);
    }

    /// Writes every live register to its slot, so that the frame is what
    /// the interpreter would have at `pc`.
    fn sync(b: *Lower, pc: u32) Error!void {
        const live = b.fr.flow.live[pc];
        for (b.fr.regs, 0..) |_, i| {
            if (live.has(@intCast(i))) try b.flush(@intCast(i));
        }
        b.snap_cache = ir.no_snap;
    }

    // -----------------------------------------------------------------
    // Edges and merges

    /// Opens a block on the edge to `target` and records the state of
    /// the registers with it. The caller names the block in its
    /// terminator.
    fn edgeTo(b: *Lower, target: u32) Error!BlockId {
        const e = try b.f.newBlock();
        const blk = &b.f.blocks.items[e];
        blk.node = b.root_node;
        blk.always = false;
        blk.edge_from = b.cur;
        try blk.preds.append(b.arena, b.cur);
        try b.fr.incoming[target].append(b.arena, try b.incomingOf(e));
        return e;
    }

    /// Closes the edges of the node that just ended whose target is a
    /// loop header that was built before.
    fn finishEdges(b: *Lower) Error!void {
        const fr = b.fr;
        for (fr.cfg.nodes.items, 0..) |nd, nid| {
            _ = nd;
            if (!fr.built[nid] or fr.headers[nid] == null) continue;
            const list = &fr.incoming[nid];
            while (list.pop()) |inc| try b.backEdge(@intCast(nid), inc);
        }
    }

    fn jumpFrom(b: *Lower, from: BlockId, to: BlockId) Error!void {
        _ = try b.emitIn(from, .{ .op = .jmp, .t = to });
        try b.f.blocks.items[to].preds.append(b.arena, from);
    }

    fn newPhi(b: *Lower, blk: BlockId, ty: Ty) Error!Ref {
        return b.emitIn(blk, .{ .op = .phi, .ty = ty, .a = @intCast(b.f.phi_args.items.len), .b = 0 });
    }

    /// Appends an argument to a phi. The arguments of one phi are
    /// consecutive while it is the last phi to receive any, and the
    /// passes read them through a per-phi list otherwise.
    fn phiArg(b: *Lower, phi: Ref, pred: BlockId, v: Ref) Error!void {
        const p = b.f.at(phi);
        const end = p.a + p.b;
        if (end != b.f.phi_args.items.len) {
            // Move the run to the end.
            const start: u32 = @intCast(b.f.phi_args.items.len);
            var i: u32 = 0;
            while (i < p.b) : (i += 1) try b.f.phi_args.append(b.arena, b.f.phi_args.items[p.a + i]);
            b.f.at(phi).a = start;
        }
        try b.f.phi_args.append(b.arena, .{ .pred = pred, .ref = v });
        b.f.at(phi).b += 1;
    }

    /// The value of a register on an edge, for a phi of type `ty`. A
    /// register that lives in its slot is loaded in the edge block, with
    /// a guard when its type is only predicted. The guard continues at
    /// `pc`, where the edge leads. Returns null when the register is
    /// something else on this edge.
    fn edgeValue(b: *Lower, inc: Incoming, r: u32, ty: Ty, pc: u32) Error!?Ref {
        const reg = inc.regs[r];
        if (reg.val != ir.none) return if (b.tyOf(reg.val) == ty) reg.val else null;
        var dep: Ref = ir.none;
        if (reg.ty) |t| {
            if (t != ty) return null;
        } else {
            const st = reg.sample.ty() orelse return null;
            if (st != ty) return null;
            dep = try b.emitIn(inc.from, .{ .op = .gslot, .cls = .slot, .imm = b.slotOf(r), .aux = ty.guardTag(), .snap = try b.snapWith(pc, inc.regs, inc.vobjs) });
        }
        if (ty == .nil) return try b.emitIn(inc.from, .{ .op = .knil, .ty = .nil });
        return try b.emitIn(inc.from, .{ .op = .sload, .ty = ty, .cls = .slot, .imm = b.slotOf(r), .c = dep });
    }

    fn regTy(b: *Lower, reg: Reg) ?Ty {
        if (reg.val != ir.none) return b.tyOf(reg.val);
        return reg.ty;
    }

    fn storeOnEdge(b: *Lower, inc: Incoming, r: u32) Error!void {
        const reg = inc.regs[r];
        if (reg.in_slot) return;
        _ = try b.emitIn(inc.from, .{ .op = .sstore, .cls = .slot, .a = reg.val, .imm = b.slotOf(r) });
    }

    /// Merges the register states of several edges into `blk`, which
    /// starts at instruction `pc`.
    fn merge(b: *Lower, blk: BlockId, incs: []Incoming, pc: u32) Error!void {
        const fr = b.fr;
        const live = fr.flow.live[pc];
        var vals: [8]Ref = undefined;
        try b.mergeVirtuals(blk, incs, pc);
        for (fr.regs, 0..) |*out, i| {
            const r: u32 = @intCast(i);
            out.* = .{ .sample = incs[0].regs[i].sample };
            if (!live.has(r) or b.captured(r)) continue;
            var same = true;
            var all_slot = true;
            var some_val: Ref = ir.none;
            var common: ?Ty = b.regTy(incs[0].regs[i]);
            for (incs) |inc| {
                const reg = inc.regs[i];
                if (reg.val != incs[0].regs[i].val) same = false;
                if (reg.val != ir.none and some_val == ir.none) some_val = reg.val;
                if (!reg.in_slot) all_slot = false;
                const t = b.regTy(reg);
                if (common == null or t == null or t.? != common.?) common = null;
            }
            if (same) {
                if (some_val != ir.none) {
                    out.* = .{ .val = some_val, .in_slot = all_slot, .sample = incs[0].regs[i].sample };
                } else {
                    // Every edge keeps the register in its slot.
                    out.ty = common;
                }
                continue;
            }
            // Some edge holds a typed value. The others join it when
            // they hold the same type, known or predicted.
            const ty = b.tyOf(some_val);
            var ok = incs.len <= vals.len;
            if (ok) for (incs, 0..) |inc, k| {
                const t = b.regTy(inc.regs[i]) orelse inc.regs[i].sample.ty();
                if (t == null or t.? != ty) ok = false;
                _ = k;
            };
            if (ok) {
                for (incs, 0..) |inc, k| vals[k] = (try b.edgeValue(inc, r, ty, pc)).?;
                const phi = try b.newPhi(blk, ty);
                for (incs, 0..) |inc, k| try b.phiArg(phi, inc.from, vals[k]);
                out.* = .{ .val = phi, .in_slot = all_slot, .sample = incs[0].regs[i].sample };
            } else {
                for (incs) |inc| try b.storeOnEdge(inc, r);
                try b.clobberSlot(b.slotOf(r));
            }
        }
        for (incs) |inc| try b.jumpFrom(inc.from, blk);
    }

    fn enterNode(b: *Lower, nid: u32) Error!void {
        const fr = b.fr;
        const nd = &fr.cfg.nodes.items[nid];
        const incs = fr.incoming[nid].items;
        b.node = nid;
        b.snap_cache = ir.no_snap;
        // An inline frame starts in the block of its call and belongs
        // to the node of the root that holds the call.
        const inline_entry = fr.parent != null and nid == fr.cfg.entry;
        if (fr.parent == null) {
            b.root_node = nid;
            b.always = true;
        } else if (!inline_entry) {
            b.always = false;
        }
        if (!inline_entry) b.clobberAll();
        if (nd.header) {
            try b.enterHeader(nid);
        } else if (incs.len == 1) {
            // The block on the only edge becomes the block of the node.
            b.cur = incs[0].from;
            @memcpy(fr.regs, incs[0].regs);
            try b.setVobjs(incs[0].vobjs);
            const blk = &b.f.blocks.items[b.cur];
            blk.node = b.root_node;
            blk.always = b.always;
            // Registers that died on the way need no slot.
            const live = fr.flow.live[nd.start];
            for (fr.regs, 0..) |*r, i| {
                if (!live.has(@intCast(i)) and !r.in_slot) r.* = .{ .sample = r.sample };
            }
        } else {
            const blk = try b.f.newBlock();
            b.f.blocks.items[blk].node = b.root_node;
            b.f.blocks.items[blk].always = b.always;
            try b.merge(blk, incs, nd.start);
            b.cur = blk;
        }
        fr.incoming[nid].clearRetainingCapacity();
    }

    /// Enters a loop header. The edges that reach it now come from
    /// outside the loop. They merge into one block in front of the loop,
    /// and every register with a known type gets a phi, which the edges
    /// from inside the loop complete later.
    fn enterHeader(b: *Lower, nid: u32) Error!void {
        const fr = b.fr;
        const nd = &fr.cfg.nodes.items[nid];
        const lp = &fr.cfg.loops.items[nd.loop];
        const incs = fr.incoming[nid].items;
        var pre: Incoming = incs[0];
        if (incs.len > 1) {
            const join = try b.f.newBlock();
            b.f.blocks.items[join].node = b.f.blocks.items[incs[0].from].node;
            b.f.blocks.items[join].always = false;
            try b.merge(join, incs, nd.start);
            const e = try b.f.newBlock();
            b.f.blocks.items[e].node = b.f.blocks.items[join].node;
            b.f.blocks.items[e].always = false;
            _ = try b.emitIn(join, .{ .op = .jmp, .t = e });
            try b.f.blocks.items[e].preds.append(b.arena, join);
            pre = try b.incomingOf(e);
        }
        const pb = pre.from;
        const header = try b.f.newBlock();
        const hb = &b.f.blocks.items[header];
        hb.node = b.root_node;
        hb.loop_header = true;
        @memcpy(fr.regs, pre.regs);
        try b.setVobjs(pre.vobjs);

        const demote = b.persist.demote.get(b.pkey(nd.start)) orelse RegSet{};
        const untype = b.persist.untype.get(b.pkey(nd.start)) orelse RegSet{};
        const live = fr.flow.live[nd.start];
        const eager = fr.info.marks[nd.start] < opt.mark_generic;
        var used = lp.uses;
        _ = used.merge(lp.writes);

        // Guards in front of the loop continue at its first instruction
        // with the state of the edge.
        const save_cur = b.cur;
        const save_pc = b.pc;
        b.cur = pb;
        b.pc = nd.start;
        b.snap_cache = ir.no_snap;
        const pre_snap = try b.snap();
        // A register the loop uses, whose type the sample predicts, is
        // loaded and guarded in front of the loop.
        for (fr.regs, 0..) |*reg, i| {
            const r: u32 = @intCast(i);
            if (!live.has(r) or b.captured(r) or demote.has(r)) continue;
            if (reg.val != ir.none or reg.ty != null) continue;
            if (!eager or !used.has(r)) continue;
            const ty = reg.sample.ty() orelse continue;
            _ = try b.typed(r, ty);
        }
        // The numeric loop that counts with this header, if any.
        var hs: HeaderState = .{ .block = header, .regs = &.{} };
        if (b.forBase(nid)) |base| {
            const ri = fr.regs[base];
            const rc = fr.regs[base + 1];
            const rs = fr.regs[base + 2];
            if (ri.val != ir.none and rc.val != ir.none and rs.val != ir.none and
                b.tyOf(ri.val) == .int and b.tyOf(rc.val) == .int and b.isConstInt(rs.val, 1) and
                !demote.has(base) and !demote.has(base + 3) and !b.captured(base + 3) and live.has(base + 3))
            {
                hs.for_base = base;
                hs.for_init = ri.val;
                hs.for_last = try b.emitIn(pb, .{ .op = .add, .ty = .int, .a = ri.val, .b = rc.val });
            }
        }
        // A table that reaches the loop unallocated stays that way when
        // the loop may: its fields become phis of the header. Any other
        // one is allocated in front of the loop.
        var hvirts: std.ArrayList(HVirt) = .empty;
        const sink = !b.persist.no_sink.contains(b.pkey(nd.start)) and fr.parent == null;
        for (fr.regs, 0..) |reg, i| {
            const r: u32 = @intCast(i);
            if (reg.val == ir.none) continue;
            const vi = b.virtIndex(reg.val) orelse continue;
            if (!live.has(r) or b.captured(r)) continue;
            var known = false;
            for (hvirts.items) |hv| {
                if (hv.obj.ref == reg.val) known = true;
            }
            if (known) continue;
            if (!sink or demote.has(r)) {
                _ = try b.materialize(reg.val);
                continue;
            }
            const old = b.vobjs.items[vi];
            var hv: HVirt = .{ .obj = old };
            hv.obj.ref = try b.f.addDetached(.{ .op = .valloc, .ty = .table, .imm = old.nc });
            for (old.vals[0..old.used], 0..) |val, k| {
                const phi = try b.newPhi(header, b.tyOf(val));
                try b.phiArg(phi, pb, val);
                hv.obj.vals[k] = phi;
            }
            if (old.mt != ir.none) {
                const phi = try b.newPhi(header, .table);
                try b.phiArg(phi, pb, old.mt);
                hv.obj.mt = phi;
                hv.mt_phi = phi;
            }
            // Every register that held the table holds the new one.
            for (fr.regs) |*x| {
                if (x.val == old.ref) x.val = hv.obj.ref;
            }
            b.vobjs.items[vi] = hv.obj;
            try hvirts.append(b.arena, hv);
        }
        hs.virts = hvirts.items;
        b.cur = save_cur;
        b.pc = save_pc;
        b.snap_cache = ir.no_snap;

        for (fr.regs, 0..) |*reg, i| {
            const r: u32 = @intCast(i);
            const src = reg.*;
            if (!live.has(r) or b.captured(r)) {
                reg.* = .{ .sample = src.sample };
                continue;
            }
            // An unallocated table keeps its register.
            if (src.val != ir.none and b.virtIndex(src.val) != null) continue;
            const ty = b.regTy(src);
            if (demote.has(r) or ty == null) {
                if (!src.in_slot) _ = try b.emitIn(pb, .{ .op = .sstore, .cls = .slot, .a = src.val, .imm = b.slotOf(r) });
                reg.* = .{ .sample = src.sample };
                continue;
            }
            if (src.val == ir.none and untype.has(r)) {
                reg.* = .{ .sample = src.sample };
                continue;
            }
            // The control copy of a numeric loop is the index itself.
            if (hs.for_base != null and r == hs.for_base.? + 3 and fr.regs[hs.for_base.?].val != ir.none and
                b.f.at(fr.regs[hs.for_base.?].val).op == .phi and ty.? == .int)
            {
                reg.* = .{ .val = fr.regs[hs.for_base.?].val, .in_slot = src.in_slot and !lp.writes.has(r), .sample = src.sample };
                hs.for_phi = reg.val;
                continue;
            }
            const phi = try b.newPhi(header, ty.?);
            const v = if (src.val != ir.none) src.val else if (ty.? == .nil)
                try b.emitIn(pb, .{ .op = .knil, .ty = .nil })
            else
                try b.emitIn(pb, .{ .op = .sload, .ty = ty.?, .cls = .slot, .imm = b.slotOf(r) });
            try b.phiArg(phi, pb, v);
            reg.* = .{ .val = phi, .in_slot = src.in_slot and !lp.writes.has(r), .sample = src.sample };
        }
        try b.jumpFrom(pb, header);
        b.f.blocks.items[pb].preheader_of = header;
        b.f.blocks.items[pb].pre_snap = pre_snap;
        hs.regs = try b.arena.dupe(Reg, fr.regs);
        fr.headers[nid] = hs;
        if (fr.parent == null) try b.loops.append(b.arena, .{ .header = header, .preheader = pb, .loop = nd.loop });
        b.cur = header;
    }

    fn pkey(b: *Lower, pc: u32) u32 {
        return (b.fr.depth << 24) | pc;
    }

    fn isConstInt(b: *Lower, r: Ref, v: i64) bool {
        const i = b.f.at(r);
        return i.op == .kint and i.imm == v;
    }

    /// The base register of the numeric loop whose body starts at node
    /// `nid`, when a `forloop` instruction of the loop jumps to it.
    fn forBase(b: *Lower, nid: u32) ?u32 {
        const fr = b.fr;
        const nd = &fr.cfg.nodes.items[nid];
        const lp = &fr.cfg.loops.items[nd.loop];
        for (lp.body, 0..) |in, x| {
            if (!in) continue;
            const xn = fr.cfg.nodes.items[x];
            const ins = fr.proto.code[xn.end];
            if (opc.op(ins) == .forloop and xn.end + 1 - opc.bx(ins) == nd.start) return opc.a(ins);
        }
        return null;
    }

    /// Completes the phis of a loop header with the state of an edge
    /// from inside the loop. A register whose type changed in the loop
    /// makes the function build again with that register in its slot.
    fn backEdge(b: *Lower, nid: u32, edge: Incoming) Error!void {
        const fr = b.fr;
        const hs = fr.headers[nid].?;
        const nd = &fr.cfg.nodes.items[nid];
        const live = fr.flow.live[nd.start];
        var inc = edge;
        // A table that the loop carries unallocated must come around
        // unallocated, with the same fields of the same types.
        for (hs.virts) |hv| {
            var back: Ref = ir.none;
            var ok = true;
            for (hs.regs, 0..) |hreg, i| {
                const r: u32 = @intCast(i);
                if (!live.has(r) or b.captured(r)) continue;
                const s = inc.regs[i];
                const here = hreg.val == hv.obj.ref;
                const there = s.val != ir.none and (back == s.val or (back == ir.none and vobjIn(inc.vobjs, s.val) != null));
                if (here and !there) ok = false;
                if (here and there) back = s.val;
            }
            // No other live register may hold it.
            for (hs.regs, 0..) |hreg, i| {
                const r: u32 = @intCast(i);
                if (!live.has(r) or b.captured(r)) continue;
                if (hreg.val != hv.obj.ref and back != ir.none and inc.regs[i].val == back) ok = false;
            }
            const v2 = if (ok and back != ir.none) vobjIn(inc.vobjs, back) else null;
            if (v2 == null or !b.sameShape(&hv.obj, v2.?)) {
                try b.persist.no_sink.put(b.arena, b.pkey(nd.start), {});
                b.rebuild = true;
                if (b.l.g.jit.opt_dump) std.debug.print("  rebuild: the loop at {d} allocates its tables\n", .{nd.start});
                return;
            }
            for (hv.obj.vals[0..hv.obj.used], v2.?.vals[0..hv.obj.used]) |phi, val| try b.phiArg(phi, inc.from, val);
            if (hv.mt_phi != ir.none) try b.phiArg(hv.mt_phi, inc.from, v2.?.mt);
        }
        // Any other unallocated table is allocated on the edge.
        for (hs.regs, 0..) |hreg, i| {
            const r: u32 = @intCast(i);
            if (!live.has(r) or b.captured(r)) continue;
            if (hreg.val != ir.none and b.f.at(hreg.val).op == .valloc) continue;
            const s = inc.regs[i];
            if (s.val != ir.none and vobjIn(inc.vobjs, s.val) != null) try b.materializeOn(&inc, s.val, nd.start);
        }
        var done_for = false;
        for (hs.regs, 0..) |hreg, i| {
            const r: u32 = @intCast(i);
            if (!live.has(r) or b.captured(r)) continue;
            const s = inc.regs[i];
            if (hreg.val != ir.none and b.f.at(hreg.val).op == .valloc) continue;
            if (hreg.val != ir.none) {
                const ty = b.tyOf(hreg.val);
                const st = b.regTy(s) orelse s.sample.ty();
                if (st == null or st.? != ty) {
                    try b.addPersist(&b.persist.demote, nd.start, r);
                    continue;
                }
                if (b.f.at(hreg.val).op == .phi and b.f.blocks.items[hs.block].loop_header and b.phiIn(hs.block, hreg.val)) {
                    // The control copy of a numeric loop shares the
                    // phi of the index, which gets one argument.
                    const shared = hs.for_base != null and (r == hs.for_base.? or r == hs.for_base.? + 3) and hs.for_phi != ir.none;
                    if (shared) {
                        const other = inc.regs[if (r == hs.for_base.?) r + 3 else r - 3];
                        if (other.val != s.val or s.val == ir.none) {
                            try b.addPersist(&b.persist.demote, nd.start, hs.for_base.? + 3);
                            continue;
                        }
                    }
                    if (!shared or !done_for) try b.phiArg(hreg.val, inc.from, (try b.edgeValue(inc, r, ty, nd.start)).?);
                    if (shared) done_for = true;
                } else if (s.val != hreg.val) {
                    try b.addPersist(&b.persist.demote, nd.start, r);
                    continue;
                }
                if (hreg.in_slot) try b.storeOnEdge(inc, r);
            } else {
                try b.storeOnEdge(inc, r);
                if (hreg.ty) |t| {
                    const st = b.regTy(s);
                    if (st == null or st.? != t) try b.addPersist(&b.persist.untype, nd.start, r);
                }
            }
        }
        try b.jumpFrom(inc.from, hs.block);
    }

    fn phiIn(b: *Lower, blk: BlockId, phi: Ref) bool {
        for (b.f.blocks.items[blk].insts.items) |r| {
            if (r == phi) return true;
            if (b.f.at(r).op != .phi) break;
        }
        return false;
    }

    fn addPersist(b: *Lower, map: *std.AutoHashMapUnmanaged(u32, RegSet), pc: u32, r: u32) Error!void {
        const gop = try map.getOrPut(b.arena, b.pkey(pc));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.set(r);
        b.rebuild = true;
        if (b.l.g.jit.opt_dump) std.debug.print("  rebuild: register {d} of the loop at {d} ({s})\n", .{ r, pc, if (map == &b.persist.demote) "slot" else "type" });
    }

    // -----------------------------------------------------------------
    // The baseline template of an instruction

    /// Runs the instruction at `pc` through its baseline template. Every
    /// live register is written to its slot first, and afterwards every
    /// register lives in its slot. Returns false when the node ended.
    fn generic(b: *Lower, pc: u32, last: bool) Error!bool {
        const fr = b.fr;
        if (fr.parent != null) return error.Unsupported;
        // A template works on the frame.
        if (b.direct) return b.notDirect(@tagName(opc.op(fr.proto.code[pc])), pc);
        try b.sync(pc);
        const e = flow_mod.effects(fr.proto, pc);
        // What the template leaves behind.
        var after = try b.arena.dupe(Reg, fr.regs);
        for (after, 0..) |*reg, i| {
            const r: u32 = @intCast(i);
            if (e.writes.has(r) and !b.captured(r)) {
                // What the template writes is predicted by what the
                // register held when the build started, which in a loop
                // is the result of the same instruction on the iteration
                // before. Every use of the prediction is guarded.
                reg.* = .{};
                if (b.root_base) |base| reg.sample = Sample.of(b.l.stack[base + r]);
            } else if (b.captured(r) or !reg.in_slot) {
                reg.* = .{};
            } else {
                // The template may run code that assigns to a local of
                // this frame through the debug library, so a type that
                // was known becomes a prediction.
                var sample = reg.sample;
                if (b.regTy(reg.*)) |t| {
                    if (t != .boolean and (sample.tag == null or Ty.fromTag(sample.tag.?) != t)) sample = Sample.tagged(@fromBackingInt(@backingInt(t)));
                    if (t == .boolean and (sample.tag == null or Ty.fromTag(sample.tag.?) != .boolean)) sample = Sample.tagged(.false);
                }
                reg.* = .{ .sample = sample };
            }
        }
        b.hint(pc, after);
        @memcpy(fr.regs, after);
        after = fr.regs;
        // Every table that is still live was allocated for the template.
        b.vobjs.clearRetainingCapacity();
        const start: u32 = @intCast(b.f.gen_targets.items.len);
        var buf: [3]u32 = undefined;
        const succ = flow_mod.successors(fr.proto, pc, &buf);
        const nd = fr.cfg.nodes.items[b.node];
        const term = try b.emit(.{ .op = .generic, .imm = pc, .a = start, .b = 0 });
        b.clobberAll();
        b.snap_cache = ir.no_snap;
        if (!last) {
            // The node goes on in a new block.
            std.debug.assert(succ.len == 1);
            const cont = try b.f.newBlock();
            const blk = &b.f.blocks.items[cont];
            blk.node = b.root_node;
            blk.always = b.always;
            try blk.preds.append(b.arena, b.cur);
            try b.f.gen_targets.append(b.arena, .{ .pc = succ[0], .block = cont });
            b.f.at(term).b = 1;
            b.cur = cont;
            return true;
        }
        for (succ, 0..) |t, i| {
            const edge = try b.edgeTo(nd.succs[i]);
            try b.f.gen_targets.append(b.arena, .{ .pc = t, .block = edge });
        }
        b.f.at(term).b = @intCast(succ.len);
        try b.finishEdges();
        return false;
    }

    /// Predicts what a template leaves in the registers it writes.
    fn hint(b: *Lower, pc: u32, regs: []Reg) void {
        const ins = b.fr.proto.code[pc];
        const a: u32 = opc.a(ins);
        switch (opc.op(ins)) {
            // A numeric loop that starts with integers counts with
            // integers.
            .forprep, .rangeprep => {
                var i: u32 = 0;
                while (i < 4 and a + i < regs.len) : (i += 1) regs[a + i].sample = Sample.tagged(.integer);
            },
            .forloop => {
                if (a + 3 < regs.len) {
                    regs[a].sample = Sample.tagged(.integer);
                    regs[a + 1].sample = Sample.tagged(.integer);
                    regs[a + 3].sample = Sample.tagged(.integer);
                }
            },
            .newtable => regs[a].sample = Sample.tagged(.table),
            .closure => regs[a].sample = Sample.tagged(.closure),
            .concat, .interp => regs[a].sample = Sample.tagged(.string),
            else => {},
        }
    }

    // -----------------------------------------------------------------
    // Instructions

    /// Lowers the instruction at `pc`. Returns true when the node goes
    /// on with the next instruction.
    fn instruction(b: *Lower, pc: u32, last: bool) Error!bool {
        const fr = b.fr;
        const p = fr.proto;
        const ins = p.code[pc];
        const o = opc.op(ins);
        const ra: u32 = opc.a(ins);
        const rb: u32 = opc.b(ins);
        const rc: u32 = opc.c(ins);
        // An instruction that left optimized code several times runs
        // through its template from then on.
        if (b.marks() >= opt.mark_generic and o != .jmp) return b.generic(pc, last);
        const done = switch (o) {
            .move => try b.move(ra, rb),
            .loadk => blk: {
                const v = p.constants[opc.bx(ins)];
                const c = (try b.konst(v)) orelse break :blk false;
                try b.setReg(ra, c, Sample.of(v));
                break :blk true;
            },
            .loadi => blk: {
                try b.setReg(ra, try b.kint(opc.sbx(ins)), Sample.of(Value.int(opc.sbx(ins))));
                break :blk true;
            },
            .loadf => blk: {
                const v: f64 = @floatFromInt(opc.sbx(ins));
                try b.setReg(ra, try b.kflt(v), Sample.of(Value.float(v)));
                break :blk true;
            },
            .loadnil => blk: {
                var i: u32 = 0;
                while (i <= rb) : (i += 1) try b.setReg(ra + i, try b.knil(), Sample.of(.nil));
                break :blk true;
            },
            .loadfalse => blk: {
                try b.setReg(ra, try b.kbool(false), Sample.of(.false));
                break :blk true;
            },
            .loadtrue => blk: {
                try b.setReg(ra, try b.kbool(true), Sample.of(.true));
                break :blk true;
            },
            .getupval => try b.getUpval(ra, rb),
            .setupval => try b.setUpval(ra, rb),
            .gettabup => try b.getField(ra, .{ .upval = rb }, p.constants[rc]),
            .getfield => try b.getField(ra, .{ .reg = rb }, p.constants[rc]),
            .settabup => try b.setField(.{ .upval = ra }, p.constants[rb], rc),
            .setfield => try b.setField(.{ .reg = ra }, p.constants[rb], rc),
            .self => try b.method(ra, rb, p.constants[rc]),
            .gettable => try b.getTable(ra, rb, .{ .reg = rc }),
            .getindex => try b.getTable(ra, rb, .{ .int = rc }),
            .settable => return b.setTable(ra, rb, rc, last),
            .newtable => try b.newTable(ra, rb, rc),
            .add, .sub, .mul, .div, .mod, .idiv, .band, .bor, .bxor => try b.arith(o, ra, .{ .reg = rb }, .{ .reg = rc }),
            .addk, .subk, .mulk, .divk, .modk, .idivk => blk: {
                const kv = p.constants[rc];
                const base_op: opc.Op = switch (o) {
                    .addk => .add,
                    .subk => .sub,
                    .mulk => .mul,
                    .divk => .div,
                    .modk => .mod,
                    else => .idiv,
                };
                break :blk switch (kv.tag) {
                    .integer => try b.arith(base_op, ra, .{ .reg = rb }, .{ .int = kv.asInt() }),
                    .float => try b.arith(base_op, ra, .{ .reg = rb }, .{ .float = kv.asFloat() }),
                    else => false,
                };
            },
            .addi => try b.arith(.add, ra, .{ .reg = rb }, .{ .int = opc.sc(ins) }),
            .unm => try b.unary(o, ra, rb),
            .bnot => try b.unary(o, ra, rb),
            .not => try b.unary(o, ra, rb),
            .len => try b.length(ra, rb),
            .jmp => {
                const off = opc.sj(ins);
                if (off < 0) _ = try b.guard(.{ .op = .gpending, .cls = .pending });
                const nd = fr.cfg.nodes.items[b.node];
                const e = try b.edgeTo(nd.succs[0]);
                _ = try b.emit(.{ .op = .jmp, .t = e });
                try b.finishEdges();
                return false;
            },
            .lt, .le, .eq => return b.compare(o, .{ .reg = ra }, .{ .reg = rb }, rc != 0, last),
            .lti => return b.compare(.lt, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0, last),
            .lei => return b.compare(.le, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0, last),
            .gti => return b.compare(.lt, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0, last),
            .gei => return b.compare(.le, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0, last),
            .eqk => return b.equalConstant(ra, p.constants[rb], rc != 0, last),
            .test_ => return b.testReg(ra, rc != 0, false, last),
            .testnil => return b.testReg(ra, rc != 0, true, last),
            .forprep => return b.forPrep(ra, last),
            .forloop => return b.forLoop(ra, last),
            .call => return b.call(ra, rb, rc, last),
            .tailcall => return b.tailCall(ra, rb, last),
            .ret0 => {
                if (fr.parent != null) return b.inlineReturn(null);
                if (b.direct) return b.directReturn(null);
                return b.generic(pc, last);
            },
            .ret1 => {
                if (fr.parent != null) return b.inlineReturn(ra);
                if (b.direct) return b.directReturn(ra);
                return b.generic(pc, last);
            },
            .ret => {
                if (fr.parent == null) {
                    if (b.direct and rb == 1) return b.directReturn(null);
                    if (b.direct and rb == 2) return b.directReturn(ra);
                    return b.generic(pc, last);
                }
                if (rb == 1) return b.inlineReturn(null);
                if (rb == 2) return b.inlineReturn(ra);
                return error.Unsupported;
            },
            .varargprep, .extraarg => true,
            else => false,
        };
        if (done) {
            b.specialized += 1;
            return true;
        }
        return b.generic(pc, last);
    }

    const Operand = union(enum) {
        reg: u32,
        int: i64,
        float: f64,
    };

    fn operandTy(b: *Lower, o: Operand, which: u2) ?Ty {
        return switch (o) {
            .reg => |r| b.guess(r, which),
            .int => .int,
            .float => .float,
        };
    }

    fn operand(b: *Lower, o: Operand, ty: Ty) Error!Ref {
        return switch (o) {
            .reg => |r| b.typed(r, ty),
            .int => |v| b.kint(v),
            .float => |v| b.kflt(v),
        };
    }

    fn toFloat(b: *Lower, v: Ref) Error!Ref {
        if (b.tyOf(v) == .float) return v;
        const i = b.f.at(v);
        if (i.op == .kint) return b.kflt(@floatFromInt(i.imm));
        return b.pure(.{ .op = .i2f, .ty = .float, .a = v });
    }

    fn move(b: *Lower, ra: u32, rb: u32) Error!bool {
        const src = &b.fr.regs[rb];
        if (src.val != ir.none and b.virtIndex(src.val) != null) {
            try b.setReg(ra, src.val, src.sample);
            return true;
        }
        if (src.val != ir.none or src.ty != null) {
            const ty = b.staticTy(rb).?;
            const v = try b.typed(rb, ty);
            try b.setReg(ra, v, b.fr.regs[rb].sample);
            return true;
        }
        // A value of unknown type moves from slot to slot.
        const sample = src.sample;
        _ = try b.emit(.{ .op = .scopy, .cls = .slot, .imm = b.slotOf(ra), .aux = @bitCast(b.slotOf(rb)) });
        try b.setSlot(ra, null, sample);
        return true;
    }

    fn arith(b: *Lower, o: opc.Op, ra: u32, x: Operand, y: Operand) Error!bool {
        const tx = b.operandTy(x, 1) orelse return false;
        const ty = b.operandTy(y, 2) orelse return false;
        const ints = tx == .int and ty == .int;
        const nums = (tx == .int or tx == .float) and (ty == .int or ty == .float);
        if (!nums) return false;
        switch (o) {
            .add, .sub, .mul => {
                if (ints) {
                    const vx = try b.operand(x, .int);
                    const vy = try b.operand(y, .int);
                    const yi = b.f.at(vy);
                    const r = if (yi.op == .kint and o != .mul and yi.imm > -(1 << 30) and yi.imm < (1 << 30))
                        try b.pure(.{ .op = .addi, .ty = .int, .a = vx, .imm = if (o == .add) yi.imm else -yi.imm })
                    else
                        try b.pure(.{ .op = switch (o) {
                            .add => .add,
                            .sub => .sub,
                            else => .mul,
                        }, .ty = .int, .a = vx, .b = vy });
                    try b.setReg(ra, r, Sample.tagged(.integer));
                    return true;
                }
                const vx = try b.toFloat(try b.operand(x, tx));
                const vy = try b.toFloat(try b.operand(y, ty));
                const r = try b.pure(.{ .op = switch (o) {
                    .add => .fadd,
                    .sub => .fsub,
                    else => .fmul,
                }, .ty = .float, .a = vx, .b = vy });
                try b.setReg(ra, r, Sample.tagged(.float));
                return true;
            },
            .div => {
                const vx = try b.toFloat(try b.operand(x, tx));
                const vy = try b.toFloat(try b.operand(y, ty));
                const r = try b.pure(.{ .op = .fdiv, .ty = .float, .a = vx, .b = vy });
                try b.setReg(ra, r, Sample.tagged(.float));
                return true;
            },
            .mod, .idiv => {
                if (!ints) return false;
                const vx = try b.operand(x, .int);
                const vy = try b.operand(y, .int);
                const yi = b.f.at(vy);
                var r: Ref = undefined;
                if (yi.op == .kint) {
                    if (yi.imm == 0 or yi.imm == -1) return false;
                    r = try b.pure(.{ .op = if (o == .mod) .modi else .idivi, .ty = .int, .a = vx, .imm = yi.imm });
                } else {
                    // The interpreter raises on zero and avoids the
                    // overflow on minus one.
                    _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = vy, .imm = 0 });
                    const g = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = vy, .imm = -1 });
                    r = try b.pure(.{ .op = if (o == .mod) .mod else .idiv, .ty = .int, .a = vx, .b = vy, .c = g });
                }
                try b.setReg(ra, r, Sample.tagged(.integer));
                return true;
            },
            .band, .bor, .bxor => {
                if (!ints) return false;
                const vx = try b.operand(x, .int);
                const vy = try b.operand(y, .int);
                const r = try b.pure(.{ .op = switch (o) {
                    .band => .band,
                    .bor => .bor,
                    else => .bxor,
                }, .ty = .int, .a = vx, .b = vy });
                try b.setReg(ra, r, Sample.tagged(.integer));
                return true;
            },
            else => return false,
        }
    }

    fn unary(b: *Lower, o: opc.Op, ra: u32, rb: u32) Error!bool {
        const ty = b.guess(rb, 1) orelse return false;
        switch (o) {
            .unm => switch (ty) {
                .int => {
                    const v = try b.typed(rb, .int);
                    try b.setReg(ra, try b.pure(.{ .op = .neg, .ty = .int, .a = v }), Sample.tagged(.integer));
                },
                .float => {
                    const v = try b.typed(rb, .float);
                    try b.setReg(ra, try b.pure(.{ .op = .fneg, .ty = .float, .a = v }), Sample.tagged(.float));
                },
                else => return false,
            },
            .bnot => {
                if (ty != .int) return false;
                const v = try b.typed(rb, .int);
                try b.setReg(ra, try b.pure(.{ .op = .bnot, .ty = .int, .a = v }), Sample.tagged(.integer));
            },
            .not => {
                const v = try b.typed(rb, ty);
                switch (ty) {
                    .nil => try b.setReg(ra, try b.kbool(true), .{}),
                    .boolean => {
                        const one = try b.kint(1);
                        try b.setReg(ra, try b.pure(.{ .op = .bxor, .ty = .boolean, .a = v, .b = one }), .{});
                    },
                    else => try b.setReg(ra, try b.kbool(false), .{}),
                }
            },
            else => return false,
        }
        return true;
    }

    fn length(b: *Lower, ra: u32, rb: u32) Error!bool {
        const ty = b.guess(rb, 1) orelse return false;
        switch (ty) {
            .string => {
                const s = try b.typed(rb, .string);
                const n = try b.load(s, String.chars_offset, .int, 4, .fixed, ir.none);
                try b.setReg(ra, n, Sample.tagged(.integer));
                return true;
            },
            .table => {
                const t = try b.typed(rb, .table);
                const m = try b.load(t, tl.metatable, .int, 8, .tab_meta, ir.none);
                _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = m, .imm = 0 });
                // The border search reads the array part and keeps a
                // hint in the table.
                const n = try b.emit(.{ .op = .callc, .ty = .int, .a = t, .imm = @bitCast(@as(u64, @intFromPtr(&opt.rt.tableLength))), .flags = .{ .pure = true } });
                try b.setReg(ra, n, Sample.tagged(.integer));
                return true;
            },
            else => return false,
        }
    }

    // -----------------------------------------------------------------
    // Upvalues

    /// The closure that the current frame runs.
    fn closureRef(b: *Lower) Error!Ref {
        if (b.fr.closure != ir.none) return b.fr.closure;
        return b.pure(.{ .op = .sload, .ty = .closure, .cls = .fixed, .imm = @as(i64, b.fr.off) - 1 });
    }

    /// The address that upvalue `i` keeps its value at, and the upvalue.
    fn upvalLoc(b: *Lower, i: u32) Error!struct { loc: Ref, uv: Ref } {
        const cl = try b.closureRef();
        const uv = try b.load(cl, @intCast(@sizeOf(Closure) + i * @sizeOf(usize)), .int, 8, .closure_up, ir.none);
        const loc = try b.load(uv, @offsetOf(object.Upvalue, "loc"), .int, 8, .upval_loc, ir.none);
        return .{ .loc = loc, .uv = uv };
    }

    fn upvalSample(b: *Lower, i: u32) Sample {
        const cl = b.fr.closure_sample orelse return .{};
        if (i >= cl.nupvals) return .{};
        return Sample.of(cl.upvals()[i].loc.*);
    }

    /// Loads the value at [base + disp] as the type the sample predicts.
    fn loadValue(b: *Lower, base: Ref, disp: i32, sample: Value, cls: ir.Class, dep: Ref) Error!Ref {
        return b.loadValueAt(base, disp, disp + 8, sample, cls, dep);
    }

    /// `loadValue` for a value whose payload is at `disp` and whose tag
    /// is the byte at `tdisp`, as in a hash node.
    fn loadValueAt(b: *Lower, base: Ref, disp: i32, tdisp: i32, sample: Value, cls: ir.Class, dep: Ref) Error!Ref {
        const ty = Ty.fromTag(sample.tag);
        if (ty == .void) return error.Unsupported;
        const g = try b.guard(.{ .op = .gtag, .cls = cls, .cond = @backingInt(ir.Cond.eq), .a = base, .imm = tdisp, .aux = ty.guardTag(), .c = dep });
        return switch (ty) {
            .nil => try b.knil(),
            .boolean => blk: {
                const tag = try b.load(base, tdisp, .int, 1, cls, g);
                break :blk try b.pure(.{ .op = .addi, .ty = .boolean, .a = tag, .imm = -@as(i64, @backingInt(Tag.false)) });
            },
            else => try b.load(base, disp, ty, 8, cls, g),
        };
    }

    fn getUpval(b: *Lower, ra: u32, i: u32) Error!bool {
        const s = b.upvalSample(i);
        if (!s.exact) return false;
        const u = try b.upvalLoc(i);
        const v = try b.loadValue(u.loc, 0, s.v, .upval, ir.none);
        try b.setReg(ra, v, s);
        return true;
    }

    fn setUpval(b: *Lower, ra: u32, i: u32) Error!bool {
        const v = (try b.anyTyped(ra, 0)) orelse return false;
        const u = try b.upvalLoc(i);
        try b.storeValue(u.loc, 0, v, .upval, false);
        // An open upvalue is a register of some frame.
        for (b.slot_ver.items) |*x| x.* += 1;
        _ = try b.emit(.{ .op = .barrier, .a = u.uv, .aux = 1 });
        return true;
    }

    // -----------------------------------------------------------------
    // Tables

    const TableSrc = union(enum) {
        reg: u32,
        upval: u32,
    };

    const TableRef = struct {
        ref: Ref,
        sample: *Table,
    };

    /// The table an instruction works on, when the sample is a table.
    fn tableOf(b: *Lower, src: TableSrc, which: u2) Error!?TableRef {
        switch (src) {
            .reg => |r| {
                const st = b.fr.regs[r].sample.tableOf() orelse return null;
                if ((b.guess(r, which) orelse return null) != .table) return null;
                return .{ .ref = try b.typed(r, .table), .sample = st };
            },
            .upval => |i| {
                const s = b.upvalSample(i);
                const st = s.tableOf() orelse return null;
                const u = try b.upvalLoc(i);
                return .{ .ref = try b.loadValue(u.loc, 0, s.v, .upval, ir.none), .sample = st };
            },
        }
    }

    const Node = struct {
        hp: Ref,
        /// Displacement of the node from `hp`.
        off: i32,
        /// Displacement of its tags from `hp`.
        tags: i32,
        dep: Ref,

        fn val(n: Node) i32 {
            return n.off + tl.node_val;
        }
        fn valTag(n: Node) i32 {
            return n.tags + tl.tag_val;
        }
    };

    /// The hash node `idx` of table `t`, proven to exist and to hold the
    /// string `key`.
    fn hashNode(b: *Lower, t: Ref, idx: usize, key_str: *String) Error!Node {
        const len = try b.load(t, b.hash_len, .int, 4, .tab_hash, ir.none);
        const g = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.hi), .a = len, .imm = @intCast(idx) });
        const hp = try b.load(t, b.hash_ptr, .int, 8, .tab_hash, ir.none);
        const off: i32 = @intCast(idx << tl.node_shift);
        const k = try b.load(hp, off + tl.node_key, .int, 8, .node_key, g);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = k, .imm = @bitCast(@as(u64, @intFromPtr(key_str))), .c = g });
        const g2 = try b.guard(.{ .op = .gtag, .cls = .node_key, .cond = @backingInt(ir.Cond.eq), .a = hp, .imm = tagDisp(idx) + tl.tag_key, .aux = @backingInt(Tag.string), .c = g });
        return .{ .hp = hp, .off = off, .tags = tagDisp(idx), .dep = g2 };
    }

    const Loaded = struct {
        ref: Ref,
        sample: Sample,
    };

    /// Guards that table `t` lacks the string `key_str`: its hash part
    /// has the size it has in the sample, and the nodes on the probe
    /// sequence of the key hold the keys they hold in the sample, up to
    /// the first empty node. Returns false when the sample does not
    /// prove the absence in a few steps.
    fn absent(b: *Lower, t: Ref, st: *Table, key_str: *String) Error!bool {
        const len = try b.load(t, b.hash_len, .int, 4, .tab_hash, ir.none);
        const g = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = len, .imm = @intCast(st.hash_len) });
        if (st.hash_len == 0) return true;
        const hp = try b.load(t, b.hash_ptr, .int, 8, .tab_hash, ir.none);
        const mask = st.hash_len - 1;
        var i: usize = key_str.hash & mask;
        // A hash part may hold a key in every node, so the walk visits
        // each node at most once. Then every node is proven to hold
        // another key.
        if (st.hash_len > 4 and st.hash_used >= st.hash_len) return false;
        for (0..@min(st.hash_len, 4)) |_| {
            const nk = st.key(i);
            const off: i32 = @intCast(i << tl.node_shift);
            if (nk.tag == .nil) {
                _ = try b.guard(.{ .op = .gtag, .cls = .node_key, .cond = @backingInt(ir.Cond.eq), .a = hp, .imm = tagDisp(i) + tl.tag_key, .aux = @backingInt(Tag.nil), .c = g });
                return true;
            }
            if (nk.tag != .string) return false;
            if (nk.payload == @intFromPtr(key_str)) return false;
            const k = try b.load(hp, off + tl.node_key, .int, 8, .node_key, g);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = k, .imm = @bitCast(nk.payload), .c = g });
            _ = try b.guard(.{ .op = .gtag, .cls = .node_key, .cond = @backingInt(ir.Cond.eq), .a = hp, .imm = tagDisp(i) + tl.tag_key, .aux = @backingInt(Tag.string), .c = g });
            i = (i + 1) & mask;
        }
        // Every node was visited when the part is that small.
        return st.hash_len <= 4;
    }

    /// t[key] for a string key, along the path that the sample takes:
    /// the table itself, or the table that `__index` of its metatable
    /// names. Returns null when the lookup needs the general path.
    fn fieldLoad(b: *Lower, t: Ref, st: *Table, key_str: *String) Error!?Loaded {
        if (!key_str.flags().interned) return null;
        if (table.findStr(st, key_str)) |idx| {
            const v = st.val(idx);
            if (v.isNil()) return null;
            const n = try b.hashNode(t, idx, key_str);
            return .{ .ref = try b.loadValueAt(n.hp, n.val(), n.valTag(), v, .node_val, n.dep), .sample = Sample.of(v) };
        }
        // The key is absent, so the metatable decides.
        const mt = st.metatable orelse {
            if (!try b.absent(t, st, key_str)) return null;
            const m = try b.load(t, tl.metatable, .int, 8, .tab_meta, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = m, .imm = 0 });
            return .{ .ref = try b.knil(), .sample = Sample.of(.nil) };
        };
        if (!b.reachable(mt, key_str)) return null;
        if (!try b.absent(t, st, key_str)) return null;
        const m = try b.load(t, tl.metatable, .table, 8, .tab_meta, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = m, .imm = 0 });
        return b.viaMetatable(m, mt, key_str);
    }

    /// Whether `viaMetatable` finds the key through the sample `mt`.
    fn reachable(b: *Lower, mt: *Table, key_str: *String) bool {
        const index_name = b.l.g.tm_names[@backingInt(state.TM.index)].?;
        const hidx = table.findStr(mt, index_name) orelse return false;
        const h = mt.val(hidx);
        if (h.tag != .table) return false;
        const idx2 = table.findStr(h.as(Table), key_str) orelse return false;
        return !h.as(Table).val(idx2).isNil();
    }

    /// The lookup of a key that a table lacks, through the metatable
    /// `m`, whose sample is `mt`: `__index` names a table, and that
    /// table holds the key.
    fn viaMetatable(b: *Lower, m: Ref, mt: *Table, key_str: *String) Error!?Loaded {
        if (!b.reachable(mt, key_str)) return null;
        const index_name = b.l.g.tm_names[@backingInt(state.TM.index)].?;
        const hidx = table.findStr(mt, index_name).?;
        const h = mt.val(hidx);
        const holder = h.as(Table);
        const idx2 = table.findStr(holder, key_str).?;
        const v2 = holder.val(idx2);
        const n1 = try b.hashNode(m, hidx, index_name);
        const hv = try b.loadValueAt(n1.hp, n1.val(), n1.valTag(), h, .node_val, n1.dep);
        const n2 = try b.hashNode(hv, idx2, key_str);
        return .{ .ref = try b.loadValueAt(n2.hp, n2.val(), n2.valTag(), v2, .node_val, n2.dep), .sample = Sample.of(v2) };
    }

    fn getField(b: *Lower, ra: u32, src: TableSrc, key_v: Value) Error!bool {
        if (key_v.tag != .string) return false;
        if (src == .reg and b.fr.regs[src.reg].val != ir.none and b.virtIndex(b.fr.regs[src.reg].val) != null) {
            const r = (try b.virtGet(b.fr.regs[src.reg].val, key_v.as(String))) orelse return false;
            try b.setReg(ra, r.ref, r.sample);
            return true;
        }
        const t = (try b.tableOf(src, 1)) orelse return false;
        const r = (try b.fieldLoad(t.ref, t.sample, key_v.as(String))) orelse return false;
        try b.setReg(ra, r.ref, r.sample);
        return true;
    }

    fn method(b: *Lower, ra: u32, rb: u32, key_v: Value) Error!bool {
        if (key_v.tag != .string) return false;
        if ((b.guess(rb, 1) orelse return false) == .string) return b.stringMethod(ra, rb, key_v.as(String));
        if (b.fr.regs[rb].val != ir.none and b.virtIndex(b.fr.regs[rb].val) != null) {
            const recv = b.fr.regs[rb];
            const r = (try b.virtGet(recv.val, key_v.as(String))) orelse return false;
            try b.setReg(ra + 1, recv.val, recv.sample);
            try b.setReg(ra, r.ref, r.sample);
            return true;
        }
        const t = (try b.tableOf(.{ .reg = rb }, 1)) orelse return false;
        const r = (try b.fieldLoad(t.ref, t.sample, key_v.as(String))) orelse return false;
        const recv_sample = b.fr.regs[rb].sample;
        try b.setReg(ra + 1, t.ref, recv_sample);
        try b.setReg(ra, r.ref, r.sample);
        return true;
    }

    /// The lookup of a method on a string: the metatable that all
    /// strings share names a table as `__index`, and that table holds
    /// the method.
    fn stringMethod(b: *Lower, ra: u32, rb: u32, key_str: *String) Error!bool {
        const g = b.l.g;
        if (!key_str.flags().interned) return false;
        const slot_ptr = &g.type_metatables[value.typeSlot(.string)];
        const mt = slot_ptr.* orelse return false;
        const index_name = g.tm_names[@backingInt(state.TM.index)].?;
        const hidx = table.findStr(mt, index_name) orelse return false;
        const h = mt.val(hidx);
        if (h.tag != .table) return false;
        const idx2 = table.findStr(h.as(Table), key_str) orelse return false;
        const v2 = h.as(Table).val(idx2);
        if (v2.isNil()) return false;
        const sv = try b.typed(rb, .string);
        const recv_sample = b.fr.regs[rb].sample;
        const m = try b.load(try b.kint(@bitCast(@as(u64, @intFromPtr(slot_ptr)))), 0, .table, 8, .tab_meta, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = m, .imm = 0 });
        const n1 = try b.hashNode(m, hidx, index_name);
        const hv = try b.loadValueAt(n1.hp, n1.val(), n1.valTag(), h, .node_val, n1.dep);
        const n2 = try b.hashNode(hv, idx2, key_str);
        const v = try b.loadValueAt(n2.hp, n2.val(), n2.valTag(), v2, .node_val, n2.dep);
        try b.setReg(ra + 1, sv, recv_sample);
        try b.setReg(ra, v, Sample.of(v2));
        return true;
    }

    /// Guards that a store into `t` is a raw store: the table is
    /// writable and has no metatable, or one whose absence cache says it
    /// lacks `__newindex`. Returns false when the sample is another kind
    /// of table.
    fn rawStore(b: *Lower, t: TableRef) Error!bool {
        const st = t.sample;
        if (st.isReadonly()) return false;
        const bit: u16 = @as(u16, 1) << il.absent_newindex;
        if (st.metatable) |mt| if (mt.tm_absent & bit == 0) return false;
        const ro = try b.load(t.ref, tl.readonly, .int, 1, .tab_meta, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = ro, .imm = 0 });
        if (st.metatable == null) {
            const m = try b.load(t.ref, tl.metatable, .int, 8, .tab_meta, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = m, .imm = 0 });
        } else {
            const m = try b.load(t.ref, tl.metatable, .table, 8, .tab_meta, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = m, .imm = 0 });
            _ = try b.guard(.{ .op = .gbit, .cls = .tab_absent, .a = m, .imm = tl.tm_absent + il.absent_newindex / 8, .aux = @as(u64, il.absent_newindex % 8) | (1 << 8) });
        }
        return true;
    }

    /// Stores register `rv` as a whole value at [base + disp] and runs
    /// the write barrier of `owner`.
    fn storeReg(b: *Lower, base: Ref, disp: i32, rv: u32, cls: ir.Class, owner: Ref, key_ptr: usize, fresh: bool) Error!void {
        if (b.staticTy(rv)) |ty| {
            const v = try b.typed(rv, ty);
            try b.storeValue(base, disp, v, cls, fresh);
            if (ty.collectable() or key_ptr != 0) _ = try b.emit(.{ .op = .barrier, .a = owner, .b = v, .imm = @bitCast(@as(u64, key_ptr)) });
        } else {
            try b.flush(rv);
            b.clobber(cls);
            _ = try b.emit(.{ .op = .copy_s2m, .cls = cls, .a = base, .imm = disp, .aux = @bitCast(b.slotOf(rv)) });
            _ = try b.emit(.{ .op = .barrier, .a = owner, .imm = @bitCast(@as(u64, key_ptr)), .aux = @as(u64, @bitCast(b.slotOf(rv))) << 8 | 2 });
        }
    }

    /// `storeReg` into the value of a hash node, whose payload is at
    /// `disp` from `base` and whose tag is the byte at `tdisp`.
    fn storeRegNode(b: *Lower, base: Ref, disp: i32, tdisp: i32, rv: u32, owner: Ref) Error!void {
        if (b.staticTy(rv)) |ty| {
            const v = try b.typed(rv, ty);
            try b.storeValueAt(base, disp, tdisp, 1, v, .node_val, false);
            if (ty.collectable()) _ = try b.emit(.{ .op = .barrier, .a = owner, .b = v });
        } else {
            try b.flush(rv);
            b.clobber(.node_val);
            const sl: u32 = @bitCast(@as(i32, @intCast(b.slotOf(rv))));
            _ = try b.emit(.{ .op = .copy_s2n, .cls = .node_val, .a = base, .imm = disp, .aux = (@as(u64, @as(u32, @bitCast(tdisp))) << 32) | sl });
            _ = try b.emit(.{ .op = .barrier, .a = owner, .aux = @as(u64, @bitCast(b.slotOf(rv))) << 8 | 2 });
        }
    }

    fn setField(b: *Lower, src: TableSrc, key_v: Value, rv: u32) Error!bool {
        if (key_v.tag != .string) return false;
        const key_str = key_v.as(String);
        if (!key_str.flags().interned) return false;
        if (src == .reg and b.fr.regs[src.reg].val != ir.none and b.virtIndex(b.fr.regs[src.reg].val) != null) {
            if (try b.virtSet(b.fr.regs[src.reg].val, key_str, rv)) return true;
        }
        // A store into a table that this block allocated.
        if (src == .reg) if (b.fresh) |*fz| {
            if (b.fr.regs[src.reg].val == fz.ref) return b.freshStore(fz, key_v, rv);
        };
        const t = (try b.tableOf(src, 0)) orelse return false;
        const idx = table.findStr(t.sample, key_str) orelse return false;
        if (!try b.rawStore(t)) return false;
        const n = try b.hashNode(t.ref, idx, key_str);
        try b.storeRegNode(n.hp, n.val(), n.valTag(), rv, t.ref);
        b.clobber(.tab_absent);
        _ = try b.emit(.{ .op = .store, .size = 2, .cls = .tab_absent, .a = t.ref, .b = try b.kint(0), .imm = tl.tm_absent });
        return true;
    }

    /// Adds a key to a table that the block allocated. The builder knows
    /// every node of the table, so it knows where the key goes.
    fn freshStore(b: *Lower, fz: *Fresh, key_v: Value, rv: u32) Error!bool {
        const key_str = key_v.as(String);
        const ty = b.staticTy(rv) orelse return false;
        if (ty == .nil or fz.metatable) return false;
        // A full hash part sends the store to the general path, as
        // `table.storeStr` does.
        const len = fz.mask + 1;
        if (fz.used >= len or fz.used >= fz.keys.len) return false;
        // The probe sequence of the key, as `table.storeStr` walks it.
        var i: u32 = key_str.hash & fz.mask;
        var at: ?u32 = null;
        while (at == null) : (i = (i + 1) & fz.mask) {
            var taken = false;
            for (fz.keys[0..fz.used], fz.nodes[0..fz.used]) |k, nidx| {
                if (nidx != i) continue;
                taken = true;
                if (k.? == key_str) at = i;
            }
            if (!taken) break;
        }
        if (at == null and !table.hashRoom(fz.used, len)) return false;
        const nodes: i32 = @intCast(@sizeOf(Table) + table.tagBytes(len));
        const node = at orelse i;
        const base: i32 = nodes + @as(i32, @intCast(@as(usize, node) << tl.node_shift));
        const tags: i32 = nodes + tagDisp(node);
        const v = try b.typed(rv, ty);
        if (at == null) {
            _ = try b.store(fz.ref, base + tl.node_key, try b.kptr(.string, @intFromPtr(key_str)), 8, .node_key, true);
            _ = try b.store(fz.ref, tags + tl.tag_key, try b.kint(@backingInt(Tag.string)), 1, .node_key, true);
            fz.keys[fz.used] = key_str;
            fz.nodes[fz.used] = i;
            fz.used += 1;
            _ = try b.emit(.{ .op = .store, .size = 4, .cls = .tab_hash, .a = fz.ref, .b = try b.kint(fz.used), .imm = tl.hash_used, .flags = .{ .fresh = true } });
        }
        try b.storeValueAt(fz.ref, base + tl.node_val, tags + tl.tag_val, 1, v, .node_val, true);
        _ = try b.emit(.{ .op = .barrier, .a = fz.ref, .b = v, .imm = @bitCast(@as(u64, @intFromPtr(key_str))) });
        return true;
    }

    fn newTable(b: *Lower, ra: u32, nb: u32, nc: u32) Error!bool {
        if (b.marks() != 0) return false;
        // A record constructor allocates nothing yet. The table exists
        // as its fields until something needs the table itself.
        if (nb == 0 and nc >= 1 and table.inlineUnits(0, nc) > 0 and b.vobjs.items.len < 6) {
            const hsize: u32 = @intCast(table.hashSizeExact(nc));
            _ = try b.emit(.{ .op = .gdebt, .imm = @intCast(@sizeOf(Table) + table.inlineUnits(0, nc) * Table.inline_unit), .snap = try b.snap() });
            const ref = try b.f.addDetached(.{ .op = .valloc, .ty = .table, .imm = nc });
            try b.vobjs.append(b.arena, .{ .ref = ref, .nc = nc, .mask = hsize - 1 });
            try b.setReg(ra, ref, Sample.tagged(.table));
            return true;
        }
        _ = try b.guard(.{ .op = .gpending, .cls = .pending });
        // The collector may run here. Registers above the target are
        // dead, as they are for the interpreter.
        _ = try b.emit(.{ .op = .gccheck, .snap = try b.snap(), .aux = @intCast(b.slotOf(ra) + 1) });
        b.gcPoint();
        const t = try b.emit(.{
            .op = .callc,
            .ty = .table,
            .a = try b.kint(nb),
            .b = try b.kint(nc),
            // The inline cache entry of the instruction, which says how
            // the lists of the site fit (`ops.learnListKind`).
            .c = try b.kint(@bitCast(@as(u64, @intFromPtr(&b.fr.proto.ic[b.pc])))),
            .imm = @bitCast(@as(u64, @intFromPtr(&opt.rt.newTable))),
            .flags = .{ .thread = true },
        });
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = t, .imm = 0 });
        try b.setReg(ra, t, Sample.tagged(.table));
        b.fresh = null;
        const units = table.inlineUnits(nb, nc);
        if (nb == 0 and nc > 0 and units > 0) {
            const hsize: u32 = @intCast(table.hashSizeExact(nc));
            b.fresh = .{ .ref = t, .mask = hsize - 1 };
        }
        return true;
    }

    /// The collector may have run. It clears entries of weak tables, so
    /// what the block read from memory as an object is read again.
    fn gcPoint(b: *Lower) void {
        b.clobber(.node_val);
        b.clobber(.elem);
        b.clobber(.upval);
        b.clobber(.gc);
        b.clobber(.pending);
    }

    const Key = union(enum) {
        reg: u32,
        int: u32,
    };

    const Elem = struct {
        t: TableRef,
        /// The zero-based index.
        zi: Ref,
        ap: Ref,
        dep: Ref,
        kind: Table.ArrayKind,
        /// The sample of the index, when known.
        at: ?usize,
    };

    /// The array slot that an access with an integer key names, proven
    /// to lie inside the array part, whose kind the sample predicts.
    fn elem(b: *Lower, rt: u32, twhich: u2, k: Key, kwhich: u2, bounds: bool) Error!?Elem {
        const t = (try b.tableOf(.{ .reg = rt }, twhich)) orelse return null;
        const st = t.sample;
        if (st.kind == .none or st.asize == 0) return null;
        var at: ?usize = null;
        var key_ref: Ref = undefined;
        switch (k) {
            .reg => |r| {
                if ((b.guess(r, kwhich) orelse return null) != .int) return null;
                key_ref = try b.typed(r, .int);
                const s = b.fr.regs[r].sample;
                if (s.exact and s.v.tag == .integer and s.v.asInt() >= 1 and @as(u64, @bitCast(s.v.asInt())) <= st.asize) at = @intCast(s.v.asInt() - 1);
            },
            .int => |c| {
                if (c == 0 or c > st.asize) return null;
                key_ref = try b.kint(c);
                at = c - 1;
            },
        }
        const asize = try b.load(t.ref, tl.asize, .int, 4, .tab_array, ir.none);
        const zi = try b.pure(.{ .op = .addi, .ty = .int, .a = key_ref, .imm = -1 });
        var dep: Ref = ir.none;
        if (bounds) {
            dep = try b.boundsGuard(key_ref, zi, asize);
        }
        const kind = try b.load(t.ref, tl.kind, .int, 1, .tab_array, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = kind, .imm = @backingInt(st.kind) });
        const ap = try b.load(t.ref, tl.array_ptr, .int, 8, .tab_array, ir.none);
        return .{ .t = t, .zi = zi, .ap = ap, .dep = dep, .kind = st.kind, .at = at };
    }

    /// Guards that the zero-based index `zi` lies inside an array part
    /// of `asize` slots. The index of a numeric loop that counts up by
    /// one from at least one is covered by a guard on the last index the
    /// loop reaches, which does not change while the loop runs.
    fn boundsGuard(b: *Lower, key_ref: Ref, zi: Ref, asize: Ref) Error!Ref {
        if (b.marks() == 0 and b.fr.parent == null) {
            for (b.fr.headers) |maybe| {
                const hs = maybe orelse continue;
                if (hs.for_phi == ir.none or hs.for_phi != key_ref) continue;
                const init = b.f.at(hs.for_init);
                if (init.op == .kint) {
                    if (init.imm < 1) break;
                } else {
                    _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ge), .a = hs.for_init, .imm = 1 });
                }
                _ = try b.guard(.{ .op = .guard, .cond = @backingInt(ir.Cond.ge), .a = hs.for_last, .b = hs.for_init });
                return b.guard(.{ .op = .guard, .cond = @backingInt(ir.Cond.ls), .a = hs.for_last, .b = asize });
            }
        }
        return b.guard(.{ .op = .guard, .cond = @backingInt(ir.Cond.lo), .a = zi, .b = asize });
    }

    fn getTable(b: *Lower, ra: u32, rt: u32, k: Key) Error!bool {
        const e = (try b.elem(rt, 1, k, 2, true)) orelse return false;
        switch (e.kind) {
            .int, .float => {
                const w = try b.pure(.{ .op = .loadx, .ty = .int, .cls = .elem, .a = e.ap, .b = e.zi, .aux = tl.word_shift, .c = e.dep });
                _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = w, .imm = @bitCast(tl.nil_word) });
                if (e.kind == .int) {
                    try b.setReg(ra, w, Sample.tagged(.integer));
                } else {
                    try b.setReg(ra, try b.pure(.{ .op = .bits2f, .ty = .float, .a = w }), Sample.tagged(.float));
                }
                return true;
            },
            .string, .table => {
                const tag: Tag = if (e.kind == .string) .string else .table;
                const w = try b.pure(.{ .op = .loadx, .ty = Ty.fromTag(tag), .cls = .elem, .a = e.ap, .b = e.zi, .aux = tl.word_shift, .c = e.dep });
                _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = w, .imm = @bitCast(tl.nil_word) });
                try b.setReg(ra, w, Sample.tagged(tag));
                return true;
            },
            .boxed => {
                // The sample of the slot, or of the first slot that
                // holds something, predicts the type.
                const vals = e.t.sample.values();
                var sv: Value = .nil;
                if (e.at) |i| sv = vals[i];
                if (sv.isNil()) for (vals[0..@min(vals.len, 16)]) |x| {
                    if (!x.isNil()) {
                        sv = .{ .tag = x.tag };
                        break;
                    }
                };
                if (sv.isNil()) return false;
                const ea = try b.pure(.{ .op = .addsh, .ty = .int, .a = e.ap, .b = e.zi, .imm = tl.value_shift });
                const v = try b.loadValue(ea, 0, sv, .elem, e.dep);
                try b.setReg(ra, v, if (e.at != null and !vals[e.at.?].isNil()) Sample.of(vals[e.at.?]) else Sample.tagged(sv.tag));
                return true;
            },
            .none => return false,
        }
    }

    /// t[k] = v for an integer key. The store runs inline when the key
    /// lies inside the array part and the value fits its kind. A store
    /// site that left optimized code before keeps the template for every
    /// other case, so that appending to an array stays in optimized code.
    fn setTable(b: *Lower, rt: u32, rk: u32, rv: u32, last: bool) Error!bool {
        const pc = b.pc;
        const m = b.marks();
        if (m >= opt.mark_generic) return b.generic(pc, last);
        const vty = b.guess(rv, 2);
        if (m >= opt.mark_respec) {
            // The inline store and the template, side by side.
            const t = (try b.tableOf(.{ .reg = rt }, 0)) orelse return b.generic(pc, last);
            const st = t.sample;
            if ((b.guess(rk, 1) orelse return b.generic(pc, last)) != .int) return b.generic(pc, last);
            if (vty == null or !fits(st.kind, vty.?)) return b.generic(pc, last);
            if (!try b.rawStore(t)) return b.generic(pc, last);
            const key_ref = try b.typed(rk, .int);
            const v = try b.typed(rv, vty.?);
            const kind = try b.load(t.ref, tl.kind, .int, 1, .tab_array, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = kind, .imm = @backingInt(st.kind) });
            const bits = try b.storeBits(st.kind, v);
            const asize = try b.load(t.ref, tl.asize, .int, 4, .tab_array, ir.none);
            const zi = try b.pure(.{ .op = .addi, .ty = .int, .a = key_ref, .imm = -1 });
            const ap = try b.load(t.ref, tl.array_ptr, .int, 8, .tab_array, ir.none);
            const fast = try b.f.newBlock();
            const slow = try b.f.newBlock();
            for ([_]BlockId{ fast, slow }) |x| {
                const blk = &b.f.blocks.items[x];
                blk.node = b.root_node;
                blk.always = false;
                try blk.preds.append(b.arena, b.cur);
            }
            _ = try b.emit(.{ .op = .br, .cond = @backingInt(ir.Cond.lo), .a = zi, .b = asize, .t = fast, .f = slow });
            const before = try b.arena.dupe(Reg, b.fr.regs);
            const before_vobjs = try b.arena.dupe(VObj, b.vobjs.items);
            const was_always = b.always;
            // The template.
            b.cur = slow;
            b.always = false;
            b.clobberAll();
            _ = try b.generic(pc, false);
            const slow_inc = try b.incomingOf(b.cur);
            // The inline store.
            b.cur = fast;
            @memcpy(b.fr.regs, before);
            try b.setVobjs(before_vobjs);
            b.clobberAll();
            try b.elemStore(st.kind, t.ref, ap, zi, v, bits);
            const fast_inc = try b.incomingOf(b.cur);
            const join = try b.f.newBlock();
            b.f.blocks.items[join].node = b.root_node;
            b.f.blocks.items[join].always = was_always;
            b.always = was_always;
            var both = [_]Incoming{ fast_inc, slow_inc };
            try b.merge(join, &both, pc + 1);
            b.cur = join;
            b.clobberAll();
            b.snap_cache = ir.no_snap;
            b.specialized += 1;
            if (last) return b.fallOut();
            return true;
        }
        const st = b.fr.regs[rt].sample.tableOf() orelse return b.generic(pc, last);
        if (vty == null or !fits(st.kind, vty.?)) return b.generic(pc, last);
        if (b.fr.regs[rk].sample.ty() == null and b.staticTy(rk) == null) return b.generic(pc, last);
        const t = (try b.tableOf(.{ .reg = rt }, 0)) orelse return b.generic(pc, last);
        if (!try b.rawStore(t)) return b.generic(pc, last);
        const e = (try b.elem(rt, 0, .{ .reg = rk }, 1, true)) orelse return b.generic(pc, last);
        const v = try b.typed(rv, vty.?);
        const bits = try b.storeBits(e.kind, v);
        try b.elemStore(e.kind, e.t.ref, e.ap, e.zi, v, bits);
        b.specialized += 1;
        if (last) return b.fallOut();
        return true;
    }

    /// Ends a node whose last instruction runs into the next node.
    fn fallOut(b: *Lower) Error!bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        if (nd.nsuccs == 1) {
            const e = try b.edgeTo(nd.succs[0]);
            _ = try b.emit(.{ .op = .jmp, .t = e });
            try b.finishEdges();
        } else {
            _ = try b.emit(.{ .op = .exit, .snap = try b.snapAt(nd.end + 1) });
        }
        return false;
    }

    /// Whether a value of type `ty` goes into an array part of `kind`
    /// without changing the kind.
    fn fits(kind: Table.ArrayKind, ty: Ty) bool {
        return switch (kind) {
            .int => ty == .int,
            .float => ty == .float,
            .string => ty == .string,
            .table => ty == .table,
            .boxed => ty != .nil or true,
            .none => false,
        };
    }

    /// The word that an unboxed array part stores for `v`, guarded to
    /// differ from the word that stands for nil.
    fn storeBits(b: *Lower, kind: Table.ArrayKind, v: Ref) Error!Ref {
        switch (kind) {
            .int, .float => {
                const w = if (kind == .float) try b.pure(.{ .op = .f2bits, .ty = .int, .a = v }) else v;
                _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = w, .imm = @bitCast(tl.nil_word) });
                return w;
            },
            else => return v,
        }
    }

    fn elemStore(b: *Lower, kind: Table.ArrayKind, t: Ref, ap: Ref, zi: Ref, v: Ref, bits: Ref) Error!void {
        switch (kind) {
            .int, .float => {
                b.clobber(.elem);
                _ = try b.emit(.{ .op = .storex, .cls = .elem, .a = ap, .b = zi, .c = bits, .aux = tl.word_shift });
            },
            // A string or a table is its pointer, which never equals the
            // nil word.
            .string, .table => {
                b.clobber(.elem);
                _ = try b.emit(.{ .op = .storex, .cls = .elem, .a = ap, .b = zi, .c = v, .aux = tl.word_shift });
                _ = try b.emit(.{ .op = .barrier, .a = t, .b = v });
            },
            .boxed => {
                const ea = try b.pure(.{ .op = .addsh, .ty = .int, .a = ap, .b = zi, .imm = tl.value_shift });
                try b.storeValue(ea, 0, v, .elem, false);
                if (b.tyOf(v).collectable()) _ = try b.emit(.{ .op = .barrier, .a = t, .b = v });
            },
            .none => unreachable,
        }
    }

    // -----------------------------------------------------------------
    // Tests and loops

    /// Ends the node with a branch on `cond`. The instruction skips the
    /// jump after it when the comparison differs from `k`.
    fn branch(b: *Lower, i: Inst, k: bool) Error!bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        std.debug.assert(nd.nsuccs == 2);
        // Successor zero is the jump, which runs when the comparison
        // equals k.
        const jump = try b.edgeTo(nd.succs[0]);
        const skip = try b.edgeTo(nd.succs[1]);
        var t = i;
        t.t = if (k) jump else skip;
        t.f = if (k) skip else jump;
        _ = try b.emit(t);
        try b.finishEdges();
        return false;
    }

    /// Ends the node with a jump to the successor that a test with a
    /// known result takes.
    fn fixedBranch(b: *Lower, result: bool, k: bool) Error!bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        const e = try b.edgeTo(nd.succs[if (result == k) 0 else 1]);
        _ = try b.emit(.{ .op = .jmp, .t = e });
        try b.finishEdges();
        return false;
    }

    fn testable(b: *Lower, last: bool) bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        return last and nd.nsuccs == 2;
    }

    fn compare(b: *Lower, o: opc.Op, x: Operand, y: Operand, k: bool, last: bool) Error!bool {
        if (!b.testable(last)) return b.generic(b.pc, last);
        const tx = b.operandTy(x, 0) orelse return b.generic(b.pc, last);
        const ty = b.operandTy(y, 1) orelse return b.generic(b.pc, last);
        if (tx == .int and ty == .int) {
            const vx = try b.operand(x, .int);
            const vy = try b.operand(y, .int);
            const cond: ir.Cond = switch (o) {
                .lt => .lt,
                .le => .le,
                else => .eq,
            };
            b.specialized += 1;
            const yi = b.f.at(vy);
            if (yi.op == .kint) return b.branch(.{ .op = .bri, .cond = @backingInt(cond), .a = vx, .imm = yi.imm }, k);
            return b.branch(.{ .op = .br, .cond = @backingInt(cond), .a = vx, .b = vy }, k);
        }
        if (tx == .float and ty == .float) {
            const vx = try b.operand(x, .float);
            const vy = try b.operand(y, .float);
            const cond: ir.FCond = switch (o) {
                .lt => .lt,
                .le => .le,
                else => .eq,
            };
            b.specialized += 1;
            return b.branch(.{ .op = .fbr, .cond = @backingInt(cond), .a = vx, .b = vy }, k);
        }
        if (o == .eq and tx == ty and (tx == .nil or tx == .boolean)) {
            const vx = try b.operand(x, tx);
            const vy = try b.operand(y, ty);
            b.specialized += 1;
            if (tx == .nil) return b.fixedBranch(true, k);
            return b.branch(.{ .op = .br, .cond = @backingInt(ir.Cond.eq), .a = vx, .b = vy }, k);
        }
        return b.generic(b.pc, last);
    }

    fn equalConstant(b: *Lower, ra: u32, kv: Value, k: bool, last: bool) Error!bool {
        if (!b.testable(last)) return b.generic(b.pc, last);
        const ty = b.guess(ra, 0);
        switch (kv.tag) {
            .integer => {
                if (ty == null or ty.? != .int) {
                    // Another number type compares by value.
                    if (ty == null or ty.? == .float or ty.? == .bigint or ty.? == .decimal) return b.generic(b.pc, last);
                    _ = try b.typed(ra, ty.?);
                    b.specialized += 1;
                    return b.fixedBranch(false, k);
                }
                const v = try b.typed(ra, .int);
                b.specialized += 1;
                return b.branch(.{ .op = .bri, .cond = @backingInt(ir.Cond.eq), .a = v, .imm = kv.asInt() }, k);
            },
            .nil, .false, .true => {
                b.specialized += 1;
                if (b.staticTy(ra)) |t| {
                    const v = try b.typed(ra, t);
                    if (t == .nil) return b.fixedBranch(kv.tag == .nil, k);
                    if (t != .boolean or kv.tag == .nil) return b.fixedBranch(false, k);
                    return b.branch(.{ .op = .bri, .cond = @backingInt(ir.Cond.eq), .a = v, .imm = @intFromBool(kv.tag == .true) }, k);
                }
                try b.flush(ra);
                return b.branch(.{ .op = .brtag, .imm = b.slotOf(ra), .aux = @backingInt(kv.tag) }, k);
            },
            .string => {
                if (!kv.as(String).flags().interned) return b.generic(b.pc, last);
                const t = ty orelse return b.generic(b.pc, last);
                const v = try b.typed(ra, t);
                b.specialized += 1;
                if (t != .string) return b.fixedBranch(false, k);
                // Pointers decide only between interned strings, and the
                // constant is interned. A string becomes interned at most
                // once and never stops being so.
                _ = try b.guard(.{ .op = .gbit, .cls = .fixed, .a = v, .imm = String.flags_offset, .aux = @as(u64, @bitOffsetOf(String.Flags, "interned")) | (1 << 8) });
                return b.branch(.{ .op = .bri, .cond = @backingInt(ir.Cond.eq), .a = v, .imm = @bitCast(@as(u64, kv.address())) }, k);
            },
            else => return b.generic(b.pc, last),
        }
    }

    /// `test` and `testnil`: a branch on the truth of a register, or on
    /// whether it is nil.
    fn testReg(b: *Lower, ra: u32, k: bool, nil_test: bool, last: bool) Error!bool {
        if (!b.testable(last)) return b.generic(b.pc, last);
        b.specialized += 1;
        if (b.staticTy(ra)) |t| {
            const v = try b.typed(ra, t);
            if (nil_test) return b.fixedBranch(t == .nil, k);
            return switch (t) {
                .nil => b.fixedBranch(false, k),
                .boolean => b.branch(.{ .op = .bri, .cond = @backingInt(ir.Cond.ne), .a = v, .imm = 0 }, k),
                else => b.fixedBranch(true, k),
            };
        }
        try b.flush(ra);
        if (nil_test) return b.branch(.{ .op = .brtag, .imm = b.slotOf(ra), .aux = @backingInt(Tag.nil) }, k);
        return b.branch(.{ .op = .brtruthy, .imm = b.slotOf(ra) }, k);
    }

    /// A numeric loop over integers that counts by one, up or down. The
    /// registers hold the index, the count of iterations left, the step,
    /// and the copy of the index that the body sees.
    fn forPrep(b: *Lower, ra: u32, last: bool) Error!bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        if (!last or nd.nsuccs != 2) return b.generic(b.pc, last);
        const step_ref = b.fr.regs[ra + 2].val;
        if (step_ref == ir.none) return b.generic(b.pc, last);
        // The step is read now, because the instruction list may move.
        const step = b.f.at(step_ref).*;
        if (step.op != .kint or (step.imm != 1 and step.imm != -1)) return b.generic(b.pc, last);
        const ti = b.guess(ra, 0) orelse return b.generic(b.pc, last);
        const tlim = b.guess(ra + 1, 0) orelse return b.generic(b.pc, last);
        if (ti != .int or tlim != .int) return b.generic(b.pc, last);
        if (b.captured(ra) or b.captured(ra + 1) or b.captured(ra + 2) or b.captured(ra + 3)) return b.generic(b.pc, last);
        const init = try b.typed(ra, .int);
        const limit = try b.typed(ra + 1, .int);
        b.specialized += 1;
        const skip = try b.edgeTo(nd.succs[1]);
        const up = step.imm == 1;
        const save = b.cur;
        const run = try b.f.newBlock();
        {
            const blk = &b.f.blocks.items[run];
            blk.node = b.root_node;
            blk.always = false;
            blk.edge_from = save;
            try blk.preds.append(b.arena, save);
        }
        b.cur = run;
        b.cse.clearRetainingCapacity();
        const count = try b.emit(.{ .op = .sub, .ty = .int, .a = if (up) limit else init, .b = if (up) init else limit });
        try b.setReg(ra, init, Sample.tagged(.integer));
        try b.setReg(ra + 1, count, Sample.tagged(.integer));
        try b.setReg(ra + 3, init, Sample.tagged(.integer));
        try b.fr.incoming[nd.succs[0]].append(b.arena, try b.incomingOf(run));
        b.cur = save;
        _ = try b.emit(.{ .op = .br, .cond = @backingInt(if (up) ir.Cond.gt else ir.Cond.lt), .a = init, .b = limit, .t = skip, .f = run });
        try b.finishEdges();
        return false;
    }

    fn forLoop(b: *Lower, ra: u32, last: bool) Error!bool {
        const nd = b.fr.cfg.nodes.items[b.node];
        if (!last or nd.nsuccs != 2) return b.generic(b.pc, last);
        for ([_]u32{ ra, ra + 1, ra + 2 }) |r| {
            if ((b.guess(r, 0) orelse return b.generic(b.pc, last)) != .int) return b.generic(b.pc, last);
            if (b.captured(r)) return b.generic(b.pc, last);
        }
        if (b.captured(ra + 3)) return b.generic(b.pc, last);
        const idx = try b.typed(ra, .int);
        const count = try b.typed(ra + 1, .int);
        const step = try b.typed(ra + 2, .int);
        b.specialized += 1;
        const done = try b.edgeTo(nd.succs[0]);
        const save = b.cur;
        const again = try b.f.newBlock();
        {
            const blk = &b.f.blocks.items[again];
            blk.node = b.root_node;
            blk.always = false;
            blk.edge_from = save;
            try blk.preds.append(b.arena, save);
        }
        b.cur = again;
        b.cse.clearRetainingCapacity();
        const si = b.f.at(step);
        const next = if (si.op == .kint)
            try b.emit(.{ .op = .addi, .ty = .int, .a = idx, .imm = si.imm })
        else
            try b.emit(.{ .op = .add, .ty = .int, .a = idx, .b = step });
        const left = try b.emit(.{ .op = .addi, .ty = .int, .a = count, .imm = -1 });
        try b.setReg(ra, next, Sample.tagged(.integer));
        try b.setReg(ra + 1, left, Sample.tagged(.integer));
        try b.setReg(ra + 3, next, Sample.tagged(.integer));
        try b.fr.incoming[nd.succs[1]].append(b.arena, try b.incomingOf(again));
        b.cur = save;
        _ = try b.emit(.{ .op = .bri, .cond = @backingInt(ir.Cond.ne), .a = count, .imm = 0, .t = again, .f = done });
        try b.finishEdges();
        return false;
    }

    // -----------------------------------------------------------------
    // Tables that are not allocated
    //
    // A record constructor makes a `valloc`, which stands for a table
    // whose fields the builder keeps as values. Reads of its fields are
    // those values, a method lookup goes through its metatable, and
    // snapshots describe it field by field, so that leaving optimized
    // code allocates it. A use that needs the table itself allocates it
    // on the spot. A table that nothing needs is never allocated.

    fn virtIndex(b: *Lower, ref: Ref) ?usize {
        if (ref == ir.none) return null;
        for (b.vobjs.items, 0..) |v, i| {
            if (v.ref == ref) return i;
        }
        return null;
    }

    fn vobjIn(list: []const VObj, ref: Ref) ?*const VObj {
        for (list) |*v| {
            if (v.ref == ref) return v;
        }
        return null;
    }

    fn setVobjs(b: *Lower, list: []const VObj) Error!void {
        b.vobjs.clearRetainingCapacity();
        try b.vobjs.appendSlice(b.arena, list);
    }

    /// The state of the current point, for an edge that leaves `from`.
    fn incomingOf(b: *Lower, from: BlockId) Error!Incoming {
        return .{ .from = from, .regs = try b.arena.dupe(Reg, b.fr.regs), .vobjs = try b.arena.dupe(VObj, b.vobjs.items) };
    }

    fn sameShape(b: *Lower, x: *const VObj, y: *const VObj) bool {
        if (x.nc != y.nc or x.used != y.used) return false;
        if ((x.mt == ir.none) != (y.mt == ir.none) or x.mt_sample != y.mt_sample) return false;
        for (0..x.used) |k| {
            if (x.keys[k] != y.keys[k] or x.nodes[k] != y.nodes[k]) return false;
            if (b.tyOf(x.vals[k]) != b.tyOf(y.vals[k])) return false;
        }
        return true;
    }

    /// t[key] for a table that is not allocated: the field, or what its
    /// metatable finds.
    fn virtGet(b: *Lower, ref: Ref, key_str: *String) Error!?Loaded {
        const v = b.vobjs.items[b.virtIndex(ref).?];
        for (v.keys[0..v.used], v.vals[0..v.used]) |k, val| {
            if (k != key_str) continue;
            const ty = b.tyOf(val);
            return .{ .ref = val, .sample = if (ty == .boolean) Sample{} else Sample.tagged(@fromBackingInt(@backingInt(ty))) };
        }
        if (!key_str.flags().interned) return null;
        if (v.mt == ir.none) return .{ .ref = try b.knil(), .sample = Sample.of(.nil) };
        return b.viaMetatable(v.mt, v.mt_sample.?, key_str);
    }

    /// t[key] = R[rv] for a table that is not allocated. Returns false
    /// when the store needs the table itself.
    fn virtSet(b: *Lower, ref: Ref, key_str: *String, rv: u32) Error!bool {
        const vi = b.virtIndex(ref).?;
        // A metatable may see the store.
        if (b.vobjs.items[vi].mt != ir.none) return false;
        const ty = b.staticTy(rv) orelse return false;
        if (ty == .nil) return false;
        if (b.virtIndex(b.fr.regs[rv].val) != null) return false;
        const val = try b.typed(rv, ty);
        const v = &b.vobjs.items[vi];
        b.snap_cache = ir.no_snap;
        for (v.keys[0..v.used], 0..) |k, i| {
            if (k == key_str) {
                v.vals[i] = val;
                return true;
            }
        }
        const len = v.mask + 1;
        if (v.used >= len or !table.hashRoom(v.used, len) or v.used >= max_vfields) return false;
        // The node the key goes to, as `table.storeStr` finds it.
        var i: u32 = key_str.hash & v.mask;
        while (true) : (i = (i + 1) & v.mask) {
            var taken = false;
            for (v.nodes[0..v.used]) |nidx| {
                if (nidx == i) taken = true;
            }
            if (!taken) break;
        }
        v.keys[v.used] = key_str;
        v.nodes[v.used] = i;
        v.vals[v.used] = val;
        v.used += 1;
        return true;
    }

    /// The metatable phi of a table that an enclosing loop carries
    /// unallocated, when its sample is `mts`.
    fn loopMetatable(b: *Lower, mts: *Table) ?Ref {
        const root_fr = b.root;
        var found: ?Ref = null;
        for (root_fr.headers, 0..) |maybe, nid| {
            const hs = maybe orelse continue;
            const nd = root_fr.cfg.nodes.items[nid];
            if (!root_fr.cfg.loops.items[nd.loop].body[b.root_node]) continue;
            for (hs.virts) |hv| {
                if (hv.mt_phi != ir.none and hv.obj.mt_sample == mts) found = hv.mt_phi;
            }
        }
        return found;
    }

    /// Allocates the table that `ref` stands for, at the current point,
    /// and stores its fields. Every register that held `ref` holds the
    /// table afterwards.
    fn materialize(b: *Lower, ref: Ref) Error!Ref {
        const vi = b.virtIndex(ref).?;
        const v = b.vobjs.items[vi];
        const snap_id = try b.snapAt(b.pc);
        // The collector sees the registers up to the last live one.
        var live_top: u32 = 0;
        if (b.pc < b.fr.flow.live.len) {
            for (b.fr.regs, 0..) |_, i| {
                if (b.fr.flow.live[b.pc].has(@intCast(i))) live_top = @intCast(i + 1);
            }
        } else live_top = b.fr.proto.max_stack;
        // The allocation counts as one and may run the collector, so the
        // finalizers it queued run in baseline code, as after a plain
        // constructor.
        _ = try b.emit(.{ .op = .gpending, .cls = .pending, .snap = snap_id });
        _ = try b.emit(.{ .op = .gccheck, .snap = snap_id, .aux = b.fr.off + live_top });
        b.gcPoint();
        const t = try b.emit(.{
            .op = .callc,
            .ty = .table,
            .a = try b.kint(0),
            .b = try b.kint(v.nc),
            .imm = @bitCast(@as(u64, @intFromPtr(&opt.rt.newVirtualTable))),
            .flags = .{ .thread = true },
        });
        _ = try b.emit(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = t, .imm = 0, .snap = snap_id });
        _ = b.vobjs.swapRemove(vi);
        var fz: Fresh = .{ .ref = t, .mask = v.mask, .used = v.used, .metatable = v.mt != ir.none };
        const nodes: i32 = @intCast(@sizeOf(Table) + table.tagBytes(v.mask + 1));
        for (v.keys[0..v.used], v.nodes[0..v.used], v.vals[0..v.used], 0..) |k, nidx, val, i| {
            const base: i32 = nodes + @as(i32, @intCast(@as(usize, nidx) << tl.node_shift));
            const tags: i32 = nodes + tagDisp(nidx);
            _ = try b.store(t, base + tl.node_key, try b.kptr(.string, @intFromPtr(k)), 8, .node_key, true);
            _ = try b.store(t, tags + tl.tag_key, try b.kint(@backingInt(Tag.string)), 1, .node_key, true);
            try b.storeValueAt(t, base + tl.node_val, tags + tl.tag_val, 1, val, .node_val, true);
            _ = try b.emit(.{ .op = .barrier, .a = t, .b = val, .imm = @bitCast(@as(u64, @intFromPtr(k))) });
            fz.keys[i] = k;
            fz.nodes[i] = nidx;
        }
        if (v.used != 0) _ = try b.emit(.{ .op = .store, .size = 4, .cls = .tab_hash, .a = t, .b = try b.kint(v.used), .imm = tl.hash_used, .flags = .{ .fresh = true } });
        if (v.mt != ir.none) {
            _ = try b.store(t, tl.metatable, v.mt, 8, .tab_meta, true);
            _ = try b.emit(.{ .op = .barrier, .a = t, .aux = 1 });
        }
        var it: ?*Frame = b.fr;
        while (it) |x| : (it = x.parent) {
            for (x.regs) |*reg| {
                if (reg.val == ref) reg.val = t;
            }
        }
        b.fresh = fz;
        b.snap_cache = ir.no_snap;
        return t;
    }

    /// Allocates every table that a register of some frame holds.
    fn materializeAll(b: *Lower) Error!void {
        while (b.vobjs.items.len > 0) {
            const ref = b.vobjs.items[b.vobjs.items.len - 1].ref;
            var held = false;
            var it: ?*Frame = b.fr;
            while (it) |x| : (it = x.parent) {
                for (x.regs) |reg| {
                    if (reg.val == ref) held = true;
                }
            }
            if (held) {
                _ = try b.materialize(ref);
            } else {
                _ = b.vobjs.pop();
            }
        }
    }

    /// Allocates a table on an edge, in the block and with the state of
    /// that edge, which leads to the instruction `pc`.
    fn materializeOn(b: *Lower, inc: *Incoming, ref: Ref, pc: u32) Error!void {
        const fr = b.fr;
        const save_cur = b.cur;
        const save_pc = b.pc;
        const save_cse = b.cse;
        const save_fresh = b.fresh;
        const save_regs = try b.arena.dupe(Reg, fr.regs);
        const save_vobjs = try b.arena.dupe(VObj, b.vobjs.items);
        b.cur = inc.from;
        b.pc = pc;
        b.cse = .empty;
        b.fresh = null;
        @memcpy(fr.regs, inc.regs);
        try b.setVobjs(inc.vobjs);
        _ = try b.materialize(ref);
        @memcpy(inc.regs, fr.regs);
        inc.vobjs = try b.arena.dupe(VObj, b.vobjs.items);
        b.cur = save_cur;
        b.pc = save_pc;
        b.cse = save_cse;
        b.fresh = save_fresh;
        @memcpy(fr.regs, save_regs);
        try b.setVobjs(save_vobjs);
        b.snap_cache = ir.no_snap;
    }

    /// Brings the unallocated tables of several edges together. A
    /// register that holds one on every edge, with the same fields of
    /// the same types, holds one afterwards, whose fields are phis.
    /// Any other unallocated table is allocated on its edge.
    fn mergeVirtuals(b: *Lower, blk: BlockId, incs: []Incoming, pc: u32) Error!void {
        const fr = b.fr;
        const live = fr.flow.live[pc];
        var any = false;
        for (incs) |inc| {
            if (inc.vobjs.len != 0) any = true;
        }
        b.vobjs.clearRetainingCapacity();
        if (!any) return;
        const Group = struct { refs: [8]Ref, ok: bool };
        var groups: std.ArrayList(Group) = .empty;
        if (incs.len <= 8) {
            for (fr.regs, 0..) |_, i| {
                const r: u32 = @intCast(i);
                if (!live.has(r) or b.captured(r)) continue;
                var tuple: [8]Ref = @splat(ir.none);
                var all = true;
                for (incs, 0..) |inc, k| {
                    const val = inc.regs[i].val;
                    if (val != ir.none and vobjIn(inc.vobjs, val) != null) tuple[k] = val else all = false;
                }
                if (!all) continue;
                var known = false;
                for (groups.items) |gr| {
                    if (std.mem.eql(Ref, &gr.refs, &tuple)) known = true;
                }
                if (!known) try groups.append(b.arena, .{ .refs = tuple, .ok = true });
            }
        }
        // A table belongs to one group, and the tables of a group have
        // one shape.
        for (groups.items, 0..) |*gr, gi| {
            const first = vobjIn(incs[0].vobjs, gr.refs[0]).?;
            for (incs, 0..) |inc, k| {
                if (!b.sameShape(first, vobjIn(inc.vobjs, gr.refs[k]).?)) gr.ok = false;
            }
            for (groups.items, 0..) |*other, oi| {
                if (oi == gi) continue;
                for (0..incs.len) |k| {
                    if (other.refs[k] == gr.refs[k]) {
                        gr.ok = false;
                        other.ok = false;
                    }
                }
            }
        }
        // Whatever stays outside a group is allocated on its edge.
        for (incs, 0..) |*inc, k| {
            var again = true;
            while (again) {
                again = false;
                for (inc.regs, 0..) |reg, i| {
                    const r: u32 = @intCast(i);
                    if (!live.has(r) or b.captured(r) or reg.val == ir.none) continue;
                    if (vobjIn(inc.vobjs, reg.val) == null) continue;
                    var grouped = false;
                    for (groups.items) |gr| {
                        if (gr.ok and gr.refs[k] == reg.val) grouped = true;
                    }
                    if (grouped) continue;
                    try b.materializeOn(inc, reg.val, pc);
                    again = true;
                    break;
                }
            }
        }
        for (groups.items) |gr| {
            if (!gr.ok) continue;
            var out = vobjIn(incs[0].vobjs, gr.refs[0]).?.*;
            var one = true;
            for (0..incs.len) |k| {
                if (gr.refs[k] != gr.refs[0]) one = false;
            }
            if (!one) out.ref = try b.f.addDetached(.{ .op = .valloc, .ty = .table, .imm = out.nc });
            for (0..out.used) |fi| {
                var same = true;
                for (incs, 0..) |inc, k| {
                    if (vobjIn(inc.vobjs, gr.refs[k]).?.vals[fi] != out.vals[fi]) same = false;
                }
                if (same) continue;
                const phi = try b.newPhi(blk, b.tyOf(out.vals[fi]));
                for (incs, 0..) |inc, k| try b.phiArg(phi, inc.from, vobjIn(inc.vobjs, gr.refs[k]).?.vals[fi]);
                out.vals[fi] = phi;
            }
            if (out.mt != ir.none) {
                var same = true;
                for (incs, 0..) |inc, k| {
                    if (vobjIn(inc.vobjs, gr.refs[k]).?.mt != out.mt) same = false;
                }
                if (!same) {
                    const phi = try b.newPhi(blk, .table);
                    for (incs, 0..) |inc, k| try b.phiArg(phi, inc.from, vobjIn(inc.vobjs, gr.refs[k]).?.mt);
                    out.mt = phi;
                }
            }
            // The registers of every edge name the merged table.
            if (!one) {
                for (incs, 0..) |*inc, k| {
                    for (inc.regs) |*reg| {
                        if (reg.val == gr.refs[k]) reg.val = out.ref;
                    }
                }
            }
            try b.vobjs.append(b.arena, out);
        }
    }

    // -----------------------------------------------------------------
    // Calls

    /// The type of an argument register: its static type, or what the
    /// sample predicts.
    fn argTy(b: *Lower, r: u32) ?Ty {
        return b.staticTy(r) orelse b.fr.regs[r].sample.ty();
    }

    /// Stores the results of a call compiled inline into the registers
    /// of the caller: `want` results from register `ra`, the first of
    /// which is `v`.
    fn setResults(b: *Lower, ra: u32, want: i32, v: Ref, sample: Sample) Error!void {
        if (want >= 1) try b.setReg(ra, v, sample);
        var k: u32 = 1;
        while (k < want) : (k += 1) try b.setReg(ra + k, try b.knil(), Sample.of(.nil));
    }

    fn call(b: *Lower, ra: u32, nb: u32, nc: u32, last: bool) Error!bool {
        const pc = b.pc;
        if (nb == 0 or nc == 0 or b.marks() >= opt.mark_respec) return b.generic(pc, last);
        const nargs = nb - 1;
        const want: i32 = @as(i32, @intCast(nc)) - 1;
        const s = b.fr.regs[ra].sample;
        if (!s.exact) return b.generic(pc, last);
        switch (s.v.tag) {
            .native => {
                if (try b.intrinsic(ra, nargs, want, s.v.as(state.Native))) |res| {
                    if (!b.skip_next) try b.setResults(ra, want, res.ref, res.sample);
                    b.specialized += 1;
                    return true;
                }
            },
            .closure => {
                const cl = s.v.as(Closure);
                if (b.canInline(cl.proto, ra)) {
                    try b.inlineCall(ra, nargs, want, cl);
                    b.specialized += 1;
                    return true;
                }
                if (try b.directCall(ra, nargs, want, cl)) {
                    b.specialized += 1;
                    return true;
                }
            },
            else => {},
        }
        return b.generic(pc, last);
    }

    /// A call of the closure `cl` at the direct entry of its optimized
    /// code, when it has one whose parameter types the arguments have.
    /// The callee is the function being built itself, or a function that
    /// was compiled for direct entry before. The caller passes the
    /// closure and the arguments in machine registers, and its own
    /// values wait in its native frame, where the snapshot of the call
    /// finds them when optimized code is left inside the callee.
    fn directCall(b: *Lower, ra: u32, nargs: u32, want: i32, cl: *Closure) Error!bool {
        const fr = b.fr;
        const p = cl.proto;
        const g = b.l.g;
        if (!g.jit.direct or want > 1) return false;
        const self = b.direct and p == b.root.proto;
        var sig: [ir.max_direct_params]Ty = undefined;
        var ret: ?Ty = null;
        var writes: u32 = 0;
        var unit: ?*opt.Unit = null;
        if (self) {
            sig = b.f.sig;
            ret = b.persist.self_ret;
            writes = b.persist.self_writes;
        } else if (opt.directUnit(p)) |u| {
            sig = u.sig;
            ret = u.ret_ty;
            writes = u.writes;
            unit = u;
        } else return false;
        if (want == 1 and ret == null) return false;
        // A chain of direct calls keeps to the stack through the native
        // frames of its activations, each of which covers at least as
        // many bytes as its call takes slots.
        if (unit) |u| {
            if (fr.off + ra + 1 > u.total) return false;
        }
        const np: u32 = p.num_params;
        var i: u32 = 0;
        while (i < np) : (i += 1) {
            const have: ?Ty = if (i < nargs) b.argTy(ra + 1 + i) else .nil;
            if (have == null or have.? != sig[i]) return false;
        }
        if (fr.off + ra + 1 + p.max_stack > 240) return false;

        // Every guard comes before the call.
        const cv = try b.typed(ra, .closure);
        if (self and b.root.closure_sample == cl) {
            _ = try b.guard(.{ .op = .guard, .cond = @backingInt(ir.Cond.eq), .a = cv, .b = b.root.closure });
        } else {
            const pr = try b.load(cv, @offsetOf(Closure, "proto"), .int, 8, .fixed, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = pr, .imm = @bitCast(@as(u64, @intFromPtr(p))) });
        }
        if (unit) |u| {
            // Code that was retired takes no new calls.
            const cell = try b.kptr(.int, @intFromPtr(&u.cell));
            const live = try b.load(cell, 0, .int, 8, .code, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ne), .a = live, .imm = 0 });
        }
        var args: [ir.max_direct_params]Ref = @splat(ir.none);
        i = 0;
        while (i < np and i < nargs) : (i += 1) {
            // The callee was built with a nil parameter as a constant, so
            // an argument whose type was only sampled is guarded too.
            const v = try b.typed(ra + 1 + i, sig[i]);
            if (sig[i] != .nil) args[i] = v;
        }
        // The snapshot of the call names values, so every table a
        // register holds is allocated first.
        try b.materializeAll();

        // A call from a function with a frame starts a chain. The
        // callee then checks the stack before it runs, and when it
        // declines, the frame continues before the call.
        var before: u32 = ir.no_snap;
        if (!b.direct) {
            before = try b.snapAt(b.pc);
            b.f.snaps.items[before].quiet = true;
        }
        const site: u32 = @intCast(b.f.sites.items.len);
        const snap_id = try b.snapCall(ra, cv);
        try b.f.sites.append(b.arena, .{
            .snap = snap_id,
            .slot = fr.off + ra,
            .nargs = nargs,
            .want = want,
            .callee_total = if (unit) |u| @intCast(u.total) else 0,
            .callee_ratio = if (unit) |u| u.chain_ratio else 0,
        });
        for (args, 0..) |x, k| {
            if (x != ir.none) _ = try b.emit(.{ .op = .darg, .a = x, .imm = @intCast(k) });
        }
        const addr: usize = if (unit) |u| (if (b.direct) u.direct_entry else u.root_entry) else 0;
        const call_ref = try b.emit(.{ .op = .dcall, .a = cv, .imm = @bitCast(@as(u64, addr)), .aux = site, .snap = snap_id });
        if (!b.direct) _ = try b.emit(.{ .op = .dgate, .a = call_ref, .snap = before });
        if (unit) |u| {
            try b.inlined.append(b.arena, u.proto);
        } else b.self_calls = true;
        b.callee_writes |= writes;

        // The callee wrote what its code writes, and nothing else ran.
        if (writes == all_classes) {
            b.clobberAll();
        } else {
            for (&b.epochs, 0..) |*e, c| {
                if (writes & (@as(u32, 1) << @intCast(c)) != 0) e.* +%= 1;
            }
            b.fresh = null;
        }
        b.snap_cache = ir.no_snap;
        // The registers from the callee up are dead, except the result.
        var r: u32 = ra;
        while (r < fr.regs.len) : (r += 1) {
            if (b.captured(r)) continue;
            fr.regs[r] = if (b.direct) .{ .val = try b.knil(), .in_slot = false, .sample = Sample.of(.nil) } else .{};
            if (!b.direct) try b.clobberSlot(b.slotOf(r));
        }
        if (want == 1) {
            const ty = ret.?;
            // A result of another type leaves optimized code after the
            // call, with the result in its register.
            const after = try b.arena.dupe(Reg, fr.regs);
            after[ra] = .{ .val = call_ref, .in_slot = false };
            const s = try b.snapWith(b.pc + 1, after, b.vobjs.items);
            b.f.snaps.items[s].after_call = true;
            const v = try b.emit(.{ .op = .dres, .ty = ty, .a = call_ref, .snap = s });
            const sample: Sample = if (ty == .boolean) Sample.tagged(.false) else Sample.tagged(@fromBackingInt(@backingInt(ty)));
            try b.setReg(ra, v, sample);
        }
        return true;
    }

    /// A return from a function that was entered directly. The result
    /// travels in machine registers as its payload and its tag.
    fn directReturn(b: *Lower, r: ?u32) Error!bool {
        var v: Ref = ir.none;
        var ty: Ty = .nil;
        if (r) |x| {
            ty = b.staticTy(x) orelse return b.notDirect("return", b.pc);
            v = try b.typed(x, ty);
        }
        // A return that passes on what the function returned to itself
        // says nothing new about the type.
        const src = b.f.at(v);
        const passes_on = v != ir.none and src.op == .dres and b.f.at(src.a).imm == 0;
        if (!passes_on) {
            if (b.ret_seen) |t| {
                if (t != ty) b.ret_mixed = true;
            } else b.ret_seen = ty;
        }
        _ = try b.emit(.{ .op = .dret, .a = v, .imm = @intFromBool(r != null) });
        try b.finishEdges();
        return false;
    }

    /// A tail call. In the root it runs through the template. In an
    /// inline frame, the callee replaces the frame, as it does in the
    /// interpreter.
    fn tailCall(b: *Lower, ra: u32, nb: u32, last: bool) Error!bool {
        const fr = b.fr;
        if (fr.parent == null) return b.generic(b.pc, last);
        if (nb == 0 or b.marks() >= opt.mark_respec) return error.Unsupported;
        const nargs = nb - 1;
        const s = fr.regs[ra].sample;
        if (!s.exact) return error.Unsupported;
        switch (s.v.tag) {
            .native => {
                const res = (try b.intrinsic(ra, nargs, 1, s.v.as(state.Native))) orelse return error.Unsupported;
                if (b.skip_next) return error.Unsupported;
                try fr.returns.?.append(b.arena, .{ .from = b.cur, .res = .{ .val = res.ref, .in_slot = false, .sample = res.sample }, .vobjs = try b.arena.dupe(VObj, b.vobjs.items) });
                return false;
            },
            .closure => {
                const cl = s.v.as(Closure);
                const p = cl.proto;
                if (!b.inlinable(p)) return error.Unsupported;
                const cv = try b.typed(ra, .closure);
                const pr = try b.load(cv, @offsetOf(Closure, "proto"), .int, 8, .fixed, ir.none);
                _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = pr, .imm = @bitCast(@as(u64, @intFromPtr(p))) });
                const fl = try Flow.init(b.arena, p);
                const cfg = Cfg.init(b.arena, fl, 0, false) catch return error.Unsupported;
                if (cfg.loops.items.len != 0) return error.Unsupported;
                const k = try newFrame(b.arena, b.l, p, fl, cfg, fr.off);
                k.parent = fr.parent;
                k.closure = cv;
                k.closure_sample = cl;
                k.call_pc = fr.call_pc;
                k.want = fr.want;
                k.tail = true;
                k.depth = fr.depth;
                k.returns = fr.returns;
                // The arguments move down to the registers of the
                // callee.
                for (k.regs, 0..) |*reg, i| {
                    if (i < p.num_params and i < nargs) {
                        const src = fr.regs[ra + 1 + i];
                        if (src.val != ir.none) {
                            reg.* = .{ .val = src.val, .in_slot = false, .sample = src.sample };
                        } else {
                            _ = try b.emit(.{ .op = .scopy, .cls = .slot, .imm = @as(i64, k.off) + @as(i64, @intCast(i)), .aux = @bitCast(b.slotOf(ra + 1 + @as(u32, @intCast(i)))) });
                            try b.clobberSlot(@as(i64, k.off) + @as(i64, @intCast(i)));
                            reg.* = .{ .ty = src.ty, .sample = src.sample };
                        }
                    } else {
                        reg.* = .{ .val = try b.knil(), .in_slot = false, .sample = Sample.of(.nil) };
                    }
                }
                b.f.extent = @max(b.f.extent, k.off + p.max_stack);
                try b.inlined.append(b.arena, p);
                if (cfg.nodes.items.len > 1) try b.materializeAll();
                try k.incoming[cfg.entry].append(b.arena, .{ .from = b.cur, .regs = try b.arena.dupe(Reg, k.regs), .vobjs = try b.arena.dupe(VObj, b.vobjs.items) });
                b.fr = k;
                b.snap_cache = ir.no_snap;
                try b.buildFrame();
                b.fr = fr;
                return false;
            },
            else => return error.Unsupported,
        }
    }

    /// A return from an inline frame. The result goes where the
    /// interpreter would put it: the slot of the called function, which
    /// is the register of the caller that receives it.
    fn inlineReturn(b: *Lower, r: ?u32) Error!bool {
        const fr = b.fr;
        var res: Reg = .{ .val = try b.knil(), .in_slot = false, .sample = Sample.of(.nil) };
        if (r) |x| {
            const reg = fr.regs[x];
            if (reg.val != ir.none and b.virtIndex(reg.val) != null) {
                res = .{ .val = reg.val, .in_slot = false, .sample = reg.sample };
            } else if (b.staticTy(x)) |t| {
                res = .{ .val = try b.typed(x, t), .in_slot = false, .sample = reg.sample };
            } else {
                _ = try b.emit(.{ .op = .scopy, .cls = .slot, .imm = @as(i64, fr.off) - 1, .aux = @bitCast(b.slotOf(x)) });
                try b.clobberSlot(@as(i64, fr.off) - 1);
                res = .{ .sample = reg.sample };
            }
        }
        try fr.returns.?.append(b.arena, .{ .from = b.cur, .res = res, .vobjs = try b.arena.dupe(VObj, b.vobjs.items) });
        return false;
    }

    /// Whether the bytecode of `p` can be compiled inline at all.
    fn inlinable(b: *Lower, p: *Proto) bool {
        if (p.is_vararg or p.code.len > 48 or p.handlers.len != 0) return false;
        var it: ?*Frame = b.fr;
        while (it) |x| : (it = x.parent) {
            if (x.proto == p) return false;
        }
        for (p.code, 0..) |ins, pc| {
            switch (opc.op(ins)) {
                .move, .loadk, .loadi, .loadf, .loadnil, .loadfalse, .loadtrue, .getupval, .setupval, .gettabup, .settabup, .gettable, .getfield, .getindex, .settable, .setfield, .newtable, .self, .add, .sub, .mul, .div, .mod, .idiv, .band, .bor, .bxor, .addk, .subk, .mulk, .divk, .modk, .idivk, .addi, .unm, .not, .len, .bnot, .eq, .lt, .le, .eqk, .lti, .lei, .gti, .gei, .test_, .testnil, .call, .tailcall, .ret, .ret0, .ret1, .extraarg => {},
                .jmp => {
                    if (opc.sj(ins) < 0) return false;
                },
                else => return false,
            }
            _ = pc;
        }
        return true;
    }

    fn canInline(b: *Lower, p: *Proto, ra: u32) bool {
        const fr = b.fr;
        if (fr.depth >= opt.max_inline_depth) return false;
        if (fr.off + ra + 1 + p.max_stack > 240) return false;
        // The root decides for every call that is compiled inline
        // inside one of its calls.
        var root_fr = fr;
        var root_pc = b.pc;
        while (root_fr.parent) |up| {
            root_pc = root_fr.call_pc;
            root_fr = up;
        }
        if (b.persist.no_inline.contains(root_pc)) return false;
        return b.inlinable(p);
    }

    /// Compiles a call of the closure `cl` inline. The frame of the
    /// callee exists only in the snapshots: leaving optimized code
    /// inside the callee builds it. A callee that needs something the
    /// tier cannot compile inline makes the function build again with
    /// this call as a plain call.
    fn inlineCall(b: *Lower, ra: u32, nargs: u32, want: i32, cl: *Closure) Error!void {
        const parent = b.fr;
        const p = cl.proto;
        const call_pc = b.pc;
        const outer = parent.parent == null;
        const cv = try b.typed(ra, .closure);
        const pr = try b.load(cv, @offsetOf(Closure, "proto"), .int, 8, .fixed, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = pr, .imm = @bitCast(@as(u64, @intFromPtr(p))) });
        b.inlineBody(ra, nargs, want, cl, cv) catch |e| switch (e) {
            error.Unsupported => {
                if (!outer) return e;
                try b.persist.no_inline.put(b.arena, call_pc, {});
                b.rebuild = true;
                if (b.l.g.jit.opt_dump) std.debug.print("  rebuild: the call at {d} stays a call\n", .{call_pc});
                return error.Rebuild;
            },
            else => return e,
        };
    }

    fn inlineBody(b: *Lower, ra: u32, nargs: u32, want: i32, cl: *Closure, cv: Ref) Error!void {
        const parent = b.fr;
        const p = cl.proto;
        const call_pc = b.pc;
        const saved_node = b.node;
        const saved_always = b.always;
        const fl = try Flow.init(b.arena, p);
        const cfg = Cfg.init(b.arena, fl, 0, false) catch return error.Unsupported;
        if (cfg.loops.items.len != 0) return error.Unsupported;
        // A callee with branches merges only its own registers, so the
        // registers of its callers hold allocated tables meanwhile.
        if (cfg.nodes.items.len > 1) try b.materializeAll();
        const child = try newFrame(b.arena, b.l, p, fl, cfg, parent.off + ra + 1);
        var returns: std.ArrayList(Return) = .empty;
        child.parent = parent;
        child.closure = cv;
        child.closure_sample = cl;
        child.call_pc = call_pc;
        child.want = want;
        child.depth = parent.depth + 1;
        child.returns = &returns;
        // The arguments are the first registers of the callee, in the
        // same slots.
        for (child.regs, 0..) |*reg, i| {
            if (i < p.num_params and i < nargs) {
                reg.* = parent.regs[ra + 1 + i];
            } else {
                reg.* = .{ .val = try b.knil(), .in_slot = false, .sample = Sample.of(.nil) };
            }
        }
        b.f.extent = @max(b.f.extent, child.off + p.max_stack);
        b.f.depth = @max(b.f.depth, child.depth);
        try b.inlined.append(b.arena, p);
        try child.incoming[cfg.entry].append(b.arena, .{ .from = b.cur, .regs = try b.arena.dupe(Reg, child.regs), .vobjs = try b.arena.dupe(VObj, b.vobjs.items) });
        b.fr = child;
        b.snap_cache = ir.no_snap;
        try b.buildFrame();
        b.fr = parent;
        b.pc = call_pc;
        b.node = saved_node;
        b.snap_cache = ir.no_snap;
        if (b.rebuild) return;
        if (returns.items.len == 0) return error.Unsupported;

        // The callee is done. Every return continues after the call
        // with its result in the registers of the caller.
        var incs = try b.arena.alloc(Incoming, returns.items.len);
        for (returns.items, 0..) |ret, i| {
            const regs = try b.arena.dupe(Reg, parent.regs);
            var r: u32 = ra;
            while (r < regs.len) : (r += 1) regs[r] = .{};
            if (want >= 1) {
                regs[ra] = ret.res;
                var k: u32 = 1;
                while (k < want) : (k += 1) {
                    regs[ra + k] = .{ .val = try b.emitIn(ret.from, .{ .op = .knil, .ty = .nil }), .in_slot = false, .sample = Sample.of(.nil) };
                }
                // A captured register lives in its slot, so a result
                // that lands in one is stored on the way back.
                k = 0;
                while (k < want and ra + k < regs.len) : (k += 1) {
                    const cr = ra + k;
                    // A result of unknown type is in the slot already.
                    if (!b.captured(cr) or regs[cr].val == ir.none) continue;
                    if (vobjIn(ret.vobjs, regs[cr].val) != null) return error.Unsupported;
                    _ = try b.emitIn(ret.from, .{ .op = .sstore, .cls = .upval, .a = regs[cr].val, .imm = b.slotOf(cr) });
                    try b.clobberSlot(b.slotOf(cr));
                    b.clobber(.upval);
                    regs[cr] = .{ .sample = regs[cr].sample };
                }
            }
            incs[i] = .{ .from = ret.from, .regs = regs, .vobjs = ret.vobjs };
        }
        if (incs.len == 1) {
            b.cur = incs[0].from;
            @memcpy(parent.regs, incs[0].regs);
            try b.setVobjs(incs[0].vobjs);
            b.always = saved_always;
            return;
        }
        const join = try b.f.newBlock();
        b.f.blocks.items[join].node = b.root_node;
        b.f.blocks.items[join].always = saved_always;
        b.always = saved_always;
        try b.merge(join, incs, call_pc + 1);
        b.cur = join;
        b.clobberAll();
    }

    const natives = struct {
        const aux = @import("../../lib/auxlib.zig");
        fn find(comptime funcs: []const aux.Reg, comptime name: []const u8) state.NativeFn {
            inline for (funcs) |r| {
                if (comptime std.mem.eql(u8, r.name, name)) return r.func;
            }
            @compileError("no such library function: " ++ name);
        }
        const mathlib = @import("../../lib/math.zig");
        const stringlib = @import("../../lib/string.zig");
        const baselib = @import("../../lib/base.zig");
        const sqrt = find(&mathlib.funcs, "sqrt");
        const abs = find(&mathlib.funcs, "abs");
        const floor = find(&mathlib.funcs, "floor");
        const ceil = find(&mathlib.funcs, "ceil");
        const sub = find(&stringlib.funcs, "sub");
        const byte = find(&stringlib.funcs, "byte");
        const setmetatable = find(&baselib.funcs, "setmetatable");
    };

    /// Guards that register `ra` holds the native function `f`.
    fn guardNative(b: *Lower, ra: u32, f: state.NativeFn) Error!void {
        const nv = try b.typed(ra, .native);
        const fp = try b.load(nv, @offsetOf(state.Native, "func"), .int, 8, .fixed, ir.none);
        _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = fp, .imm = @bitCast(@as(u64, @intFromPtr(f))) });
    }

    /// Compiles a call of a library function that the tier knows as
    /// typed operations. Returns the first result, or null when the
    /// arguments are not the ones the tier handles.
    fn intrinsic(b: *Lower, ra: u32, nargs: u32, want: i32, nat: *state.Native) Error!?Loaded {
        const f = nat.func;
        if (b.argTy(ra) == null or b.argTy(ra).? != .native) return null;
        const a1 = ra + 1;
        const t1: ?Ty = if (nargs >= 1) b.argTy(a1) else null;
        const t2: ?Ty = if (nargs >= 2) b.argTy(a1 + 1) else null;
        const t3: ?Ty = if (nargs >= 3) b.argTy(a1 + 2) else null;
        if (f == natives.sqrt and nargs == 1 and t1 != null and (t1.? == .int or t1.? == .float)) {
            try b.guardNative(ra, f);
            const x = try b.toFloat(try b.typed(a1, t1.?));
            return .{ .ref = try b.pure(.{ .op = .fsqrt, .ty = .float, .a = x }), .sample = Sample.tagged(.float) };
        }
        if (f == natives.abs and nargs == 1 and t1 != null and t1.? == .float) {
            try b.guardNative(ra, f);
            const x = try b.typed(a1, .float);
            return .{ .ref = try b.pure(.{ .op = .fabs, .ty = .float, .a = x }), .sample = Sample.tagged(.float) };
        }
        if ((f == natives.floor or f == natives.ceil) and nargs == 1 and t1 != null and t1.? == .int) {
            try b.guardNative(ra, f);
            return .{ .ref = try b.typed(a1, .int), .sample = b.fr.regs[a1].sample };
        }
        if (f == natives.setmetatable and nargs == 2 and t1 != null and t1.? == .table and t2 != null and t2.? == .table) {
            // The sample of the metatable must already answer, through
            // its absence cache, that it has no finalizer.
            const mts = b.fr.regs[a1 + 1].sample.tableOf() orelse return null;
            const gc_bit: u16 = @as(u16, 1) << @backingInt(state.TM.gc);
            if (mts.tm_absent & gc_bit == 0) return null;
            const bit0: u8 = @backingInt(state.TM.gc);
            if (b.fr.regs[a1].val != ir.none) if (b.virtIndex(b.fr.regs[a1].val)) |vi0| {
                // An unallocated table: the metatable becomes one of
                // its fields. It has none yet, or the call stays.
                if (b.vobjs.items[vi0].mt != ir.none) return null;
                try b.guardNative(ra, f);
                var mt = try b.typed(a1 + 1, .table);
                _ = try b.guard(.{ .op = .gbit, .cls = .tab_absent, .a = mt, .imm = tl.tm_absent + bit0 / 8, .aux = @as(u64, bit0 % 8) | (1 << 8) });
                // In a loop that carries such a table, the metatable is
                // most often the one from the last iteration. Proving
                // that makes it one value for the whole loop.
                if (b.loopMetatable(mts)) |prev| {
                    _ = try b.guard(.{ .op = .guard, .cond = @backingInt(ir.Cond.eq), .a = mt, .b = prev });
                    mt = prev;
                }
                const vi = b.virtIndex(b.fr.regs[a1].val).?;
                b.vobjs.items[vi].mt = mt;
                b.vobjs.items[vi].mt_sample = mts;
                b.snap_cache = ir.no_snap;
                return .{ .ref = b.fr.regs[a1].val, .sample = b.fr.regs[a1].sample };
            };
            try b.guardNative(ra, f);
            const t = try b.typed(a1, .table);
            const mt = try b.typed(a1 + 1, .table);
            // A table with a metatable may protect it.
            const old = try b.load(t, tl.metatable, .int, 8, .tab_meta, ir.none);
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.eq), .a = old, .imm = 0 });
            const bit: u8 = @backingInt(state.TM.gc);
            _ = try b.guard(.{ .op = .gbit, .cls = .tab_absent, .a = mt, .imm = tl.tm_absent + bit / 8, .aux = @as(u64, bit % 8) | (1 << 8) });
            const is_fresh = if (b.fresh) |fz| fz.ref == t else false;
            _ = try b.store(t, tl.metatable, mt, 8, .tab_meta, is_fresh);
            _ = try b.emit(.{ .op = .barrier, .a = t, .aux = 1 });
            if (b.fresh) |*fz| {
                if (fz.ref == t) fz.metatable = true;
            }
            return .{ .ref = t, .sample = b.fr.regs[a1].sample };
        }
        if (f == natives.sub and (nargs == 2 or nargs == 3) and want == 1 and
            t1 != null and t1.? == .string and t2 != null and t2.? == .int and (nargs == 2 or (t3 != null and t3.? == .int)))
        {
            // Only the length of the result is wanted: the instruction
            // after the call takes it and nothing else reads the
            // string. The length follows from the character count and
            // the positions, so no string is made.
            const fr = b.fr;
            const nd = fr.cfg.nodes.items[b.node];
            if (b.pc + 1 > nd.end) return null;
            const next = fr.proto.code[b.pc + 1];
            if (opc.op(next) != .len or opc.b(next) != ra) return null;
            const dst: u32 = opc.a(next);
            if (dst != ra and fr.flow.live_out[b.pc + 1].has(ra)) return null;
            if (fr.info.marks[b.pc + 1] != 0) return null;
            try b.guardNative(ra, f);
            const sv = try b.typed(a1, .string);
            const i = try b.typed(a1 + 1, .int);
            const j = if (nargs == 3) try b.typed(a1 + 2, .int) else try b.kint(-1);
            const chars = try b.load(sv, String.chars_offset, .int, 4, .fixed, ir.none);
            const n = try b.emit(.{ .op = .callc, .ty = .int, .a = chars, .b = i, .c = j, .imm = @bitCast(@as(u64, @intFromPtr(&opt.rt.subLength))), .flags = .{ .pure = true } });
            try b.setReg(dst, n, Sample.tagged(.integer));
            b.skip_next = true;
            return .{ .ref = n, .sample = Sample.tagged(.integer) };
        }
        if (f == natives.byte and (nargs == 1 or nargs == 2) and t1 != null and t1.? == .string and (nargs == 1 or (t2 != null and t2.? == .int))) {
            try b.guardNative(ra, f);
            const sv = try b.typed(a1, .string);
            const i = if (nargs == 2) try b.typed(a1 + 1, .int) else try b.kint(1);
            const n = try b.emit(.{ .op = .callc, .ty = .int, .a = sv, .b = i, .imm = @bitCast(@as(u64, @intFromPtr(&opt.rt.stringByte))), .flags = .{ .pure = true, .thread = true } });
            // A position outside the string yields no value at all.
            _ = try b.guard(.{ .op = .guardi, .cond = @backingInt(ir.Cond.ge), .a = n, .imm = 0 });
            return .{ .ref = n, .sample = Sample.tagged(.integer) };
        }
        return null;
    }
};
