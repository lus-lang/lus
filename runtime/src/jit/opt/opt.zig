//! The optimizing tier. A function or a loop that stays hot in baseline
//! code is compiled again from its bytecode, this time with the types of
//! its values known or guarded, and with those values in machine
//! registers. A guard that fails writes the values back to the frame and
//! continues in baseline code at the instruction that failed. The design
//! is described in `spec/design/opt.md`.
//!
//! This file holds what is independent of the compilation itself: what
//! the tier remembers about a function, when it compiles, how optimized
//! code is entered and left, and the routines that optimized code calls.

const std = @import("std");
const state = @import("../../vm/state.zig");
const object = @import("../../vm/object.zig");
const value = @import("../../vm/value.zig");
const table = @import("../../vm/table.zig");
const gc = @import("../../vm/gc.zig");
const interp = @import("../../vm/interp.zig");
const opc = @import("../../compile/opcodes.zig");
const jit = @import("../jit.zig");
const mem = @import("../mem.zig");
const ir = @import("ir.zig");
const lower = @import("lower.zig");
const passes = @import("passes.zig");
const regalloc = @import("regalloc.zig");
const codegen = @import("codegen.zig");
const flow_mod = @import("flow.zig");
const Thread = state.Thread;
const Global = state.Global;
const Proto = object.Proto;
const Closure = object.Closure;
const Table = object.Table;
const Value = value.Value;
const Tag = value.Tag;

/// Calls compiled inline nest at most this deep.
pub const max_inline_depth = 3;
/// Functions with more instructions than this stay in baseline code.
const max_instructions = 1500;
/// Pieces of optimized code that one function gets over its life.
const max_compiles = 12;
/// Exits after which a piece of optimized code is given up.
const max_exits = 48;
pub const no_feedback: u8 = 0xFF;
/// Exits from one instruction after which the function compiles again
/// with fresh predictions, and after which the instruction runs through
/// its baseline template.
pub const mark_respec: u8 = 2;
pub const mark_generic: u8 = 4;

pub const default_threshold = 120;
/// Bytes of unallocated tables after which optimized code asks for a
/// collection, at least.
pub const sunk_step: u64 = 4 << 20;

pub const Setting = enum { off, on, eager };

/// What the tier remembers about one function across compilations.
pub const Info = struct {
    /// Per instruction: how often optimized code left through a guard
    /// of that instruction.
    marks: []u8,
    /// Per instruction: the tags its register operands A, B, and C held
    /// when optimized code last left through it.
    fb: [][3]u8,
    units: std.ArrayList(*Unit) = .empty,
    /// Entry instructions that the tier will not compile again.
    declined: std.ArrayList(u32) = .empty,
    compiles: u32 = 0,
};

/// Where an exit finds a value.
pub const Val = extern struct {
    kind: Kind,
    ty: ir.Ty,
    bits: u64 align(8),

    /// `virt` names a table of the snapshot that is not allocated yet,
    /// by its index among those tables.
    pub const Kind = enum(u8) { reg, freg, spill, imm, virt };
};

/// A table that an exit allocates.
pub const VirtMeta = struct {
    nc: u32,
    mt: Val,
    fields: u32,
    count: u32,
};

pub const VFieldMeta = struct {
    key: usize,
    node: u32,
    val: Val,
};

pub const FrameMeta = struct {
    proto: *Proto,
    closure: Val,
    off: u32,
    pc: u32,
    want: i32,
    tail: bool,
    entries: u32,
    count: u32,
};

pub const Entry = struct {
    slot: u32,
    val: Val,
};

/// One piece of optimized code: a function from its first instruction,
/// or from the first instruction of one of its loops.
pub const Unit = struct {
    proto: *Proto,
    entry_pc: u32,
    code: []u8 = &.{},
    /// Address of the body, which expects the frame in place.
    entry: usize = 0,
    /// Addresses that a native call and a native tail call enter at.
    call_entry: usize = 0,
    tail_entry: usize = 0,
    snaps: []ir.Snap = &.{},
    frames: []FrameMeta = &.{},
    entries: []Entry = &.{},
    virts: []VirtMeta = &.{},
    vfields: []VFieldMeta = &.{},
    /// Slots that the frames of the unit cover, from register zero of
    /// the root.
    extent: u32 = 0,
    /// Functions compiled inline, which the unit keeps alive.
    protos: []*Proto = &.{},
    exits: u32 = 0,
    retired: bool = false,
};

pub fn counts(g: *Global) bool {
    return g.jit.opt != .off;
}

pub fn infoOf(g: *Global, p: *Proto) ?*Info {
    if (p.opt) |x| return @ptrCast(@alignCast(x));
    const gpa = g.gpa;
    const info = gpa.create(Info) catch return null;
    const marks = gpa.alloc(u8, p.code.len + 1) catch {
        gpa.destroy(info);
        return null;
    };
    const fb = gpa.alloc([3]u8, p.code.len + 1) catch {
        gpa.free(marks);
        gpa.destroy(info);
        return null;
    };
    @memset(marks, 0);
    @memset(fb, @splat(no_feedback));
    info.* = .{ .marks = marks, .fb = fb };
    p.opt = info;
    return info;
}

fn existing(p: *Proto) ?*Info {
    return if (p.opt) |x| @ptrCast(@alignCast(x)) else null;
}

/// The optimized code of `p` that starts at `pc` and is in use.
fn unitAt(p: *Proto, pc: u32) ?*Unit {
    const info = existing(p) orelse return null;
    for (info.units.items) |u| {
        if (!u.retired and u.entry_pc == pc) return u;
    }
    return null;
}

/// Whether the function has optimized code in use, for `debug.jit`.
pub fn isOptimized(p: *Proto) bool {
    const info = existing(p) orelse return false;
    for (info.units.items) |u| {
        if (!u.retired) return true;
    }
    return false;
}

fn isDeclined(info: *Info, pc: u32) bool {
    for (info.declined.items) |x| {
        if (x == pc) return true;
    }
    return false;
}

/// The top frame is about to run `p` from its first instruction in
/// baseline code. Returns the address of optimized code to run instead,
/// or zero.
pub fn entry(l: *Thread, p: *Proto) usize {
    const g = l.g;
    if (unitAt(p, 0)) |u| return u.entry;
    if (p.opt_hot > 1) {
        p.opt_hot -= 1;
        return 0;
    }
    const u = tryCompile(l, p, 0) orelse {
        // The calls of the function stop counting.
        const code: *jit.Code = @ptrCast(@alignCast(p.jit_code.?));
        if (p.jit_entry != 0) p.jit_entry = code.base + code.call_entry_plain;
        p.opt_hot = g.jit.opt_threshold *| 64;
        return 0;
    };
    p.opt_hot = g.jit.opt_threshold;
    return u.entry;
}

/// A loop of the top frame became hot in baseline code. `pc` is the
/// first instruction of its body, which runs next. Returns the address
/// of optimized code that continues the frame there, or zero.
pub fn loopEntry(l: *Thread, pc: u32) callconv(.c) usize {
    const fr = l.frame();
    const p = fr.closure.?.proto;
    const g = l.g;
    fr.pc = pc;
    p.opt_hot = g.jit.opt_threshold;
    if (g.jit.opt == .off or l.hook_mask != 0) return 0;
    if (unitAt(p, pc)) |u| return u.entry;
    const u = tryCompile(l, p, pc) orelse {
        p.opt_hot = g.jit.opt_threshold *| 64;
        return 0;
    };
    return u.entry;
}

fn tryCompile(l: *Thread, p: *Proto, pc: u32) ?*Unit {
    const g = l.g;
    const info = infoOf(g, p) orelse return null;
    if (isDeclined(info, pc)) return null;
    if (info.compiles >= max_compiles or p.code.len > max_instructions) {
        info.declined.append(g.gpa, pc) catch {};
        return null;
    }
    info.compiles += 1;
    const u = compile(l, p, pc, info) orelse {
        info.declined.append(g.gpa, pc) catch {};
        return null;
    };
    if (pc == 0) {
        if (u.call_entry != 0) p.jit_entry = u.call_entry;
        if (u.tail_entry != 0) p.jit_tail = u.tail_entry;
    }
    return u;
}

fn compile(l: *Thread, p: *Proto, pc: u32, info: *Info) ?*Unit {
    const g = l.g;
    const gpa = g.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var persist: lower.Persist = .{};
    var loops: []lower.Lower.LoopInfo = &.{};
    var inlined: []*Proto = &.{};
    var cfg: *flow_mod.Cfg = undefined;
    var func: *ir.Func = undefined;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries > 8) return null;
        func = lower.Lower.build(arena, l, p, pc, &persist, &loops, &cfg, &inlined) catch |e| switch (e) {
            error.Rebuild => continue,
            else => return null,
        };
        break;
    }
    passes.simplifyPhis(func) catch return null;
    passes.foldImmediates(func);
    passes.hoist(func, cfg, loops, info.marks, mark_generic) catch return null;
    passes.eliminateDead(func) catch return null;
    const ra = regalloc.run(func, @intCast(codegen.gpr_pool.len), @intCast(codegen.fpr_pool.len)) catch return null;
    if (ra.nspill > 400) return null;
    if (g.jit.opt_dump) dump(func, p, pc, ra);

    const unit = gpa.create(Unit) catch return null;
    unit.* = .{ .proto = p, .entry_pc = pc };
    var ok = false;
    defer if (!ok) freeUnit(g, unit);
    var cg = codegen.Codegen.init(arena, gpa, l, p, func, ra, unit) catch return null;
    defer cg.deinit();
    if (!cg.run()) return null;
    const bytes = cg.em.bytes();
    unit.code = g.jit.arena.alloc(gpa, bytes.len) orelse return null;
    mem.install(unit.code, bytes);
    const base = @intFromPtr(unit.code.ptr);
    unit.entry = base + cg.entry_off;
    if (!p.is_vararg and pc == 0) {
        unit.call_entry = base + cg.em.call_entry;
        unit.tail_entry = base + cg.em.tail_entry;
    }

    // What the exits need, in a form that outlives the compilation.
    unit.snaps = gpa.dupe(ir.Snap, func.snaps.items) catch return null;
    unit.frames = gpa.alloc(FrameMeta, func.snap_frames.items.len) catch return null;
    unit.entries = gpa.alloc(Entry, func.snap_entries.items.len) catch return null;
    for (func.snap_frames.items, unit.frames) |f, *m| {
        m.* = .{
            .proto = f.proto,
            .closure = if (f.closure != ir.none) valOf(func, ra, f.closure) else .{ .kind = .imm, .ty = .nil, .bits = 0 },
            .off = f.off,
            .pc = f.pc,
            .want = f.want,
            .tail = f.tail,
            .entries = f.entries,
            .count = f.count,
        };
    }
    unit.virts = gpa.alloc(VirtMeta, func.snap_virts.items.len) catch return null;
    unit.vfields = gpa.alloc(VFieldMeta, func.snap_vfields.items.len) catch return null;
    unit.extent = func.extent;
    for (func.snap_virts.items, unit.virts) |v, *m| {
        m.* = .{ .nc = v.nc, .mt = if (v.mt != ir.none) valOf(func, ra, v.mt) else .{ .kind = .imm, .ty = .nil, .bits = 0 }, .fields = v.fields, .count = v.count };
    }
    for (func.snap_vfields.items, unit.vfields) |x, *m| m.* = .{ .key = x.key, .node = x.node, .val = valOf(func, ra, x.val) };
    for (func.snap_entries.items, unit.entries) |e, *m| m.* = .{ .slot = e.slot, .val = valOf(func, ra, e.ref) };
    // An entry that holds a table of its snapshot names it by index.
    for (func.snaps.items) |s| {
        for (func.snap_frames.items[s.frames..][0..s.nframes]) |fm| {
            for (func.snap_entries.items[fm.entries..][0..fm.count], unit.entries[fm.entries..][0..fm.count]) |e, *m| {
                if (func.at(e.ref).op != .valloc) continue;
                for (func.snap_virts.items[s.virts..][0..s.nvirts], 0..) |v, vi| {
                    if (v.ref == e.ref) m.val = .{ .kind = .virt, .ty = .table, .bits = vi };
                }
            }
        }
    }
    unit.protos = gpa.dupe(*Proto, inlined) catch return null;
    info.units.append(gpa, unit) catch return null;
    // The function now refers to the functions compiled inline.
    if (inlined.len != 0) gc.barrierBack(g, &p.hdr);
    ok = true;
    g.jit.optimized += 1;
    return unit;
}

fn valOf(f: *ir.Func, ra: regalloc.Result, r: ir.Ref) Val {
    const i = f.at(r);
    if (i.isConst()) return .{ .kind = .imm, .ty = i.ty, .bits = @bitCast(i.imm) };
    return switch (ra.loc[r]) {
        .reg => |x| .{ .kind = .reg, .ty = i.ty, .bits = x },
        .freg => |x| .{ .kind = .freg, .ty = i.ty, .bits = x },
        .spill => |k| .{ .kind = .spill, .ty = i.ty, .bits = k },
        .none => .{ .kind = .imm, .ty = i.ty, .bits = 0 },
    };
}

fn freeUnit(g: *Global, u: *Unit) void {
    const gpa = g.gpa;
    if (u.code.len != 0) g.jit.arena.release(gpa, u.code);
    gpa.free(u.snaps);
    gpa.free(u.frames);
    gpa.free(u.entries);
    gpa.free(u.virts);
    gpa.free(u.vfields);
    gpa.free(u.protos);
    gpa.destroy(u);
}

/// Stops new entries into a piece of optimized code. Frames that wait
/// in it for a call to return still continue there, so its memory stays
/// until the function is collected.
fn retire(g: *Global, u: *Unit) void {
    if (u.retired) return;
    u.retired = true;
    const p = u.proto;
    if (u.entry_pc == 0) if (p.jit_code) |c| {
        const code: *jit.Code = @ptrCast(@alignCast(c));
        if (p.jit_entry == u.call_entry and u.call_entry != 0) p.jit_entry = code.base + code.call_entry;
        if (p.jit_tail == u.tail_entry and u.tail_entry != 0) p.jit_tail = code.base + code.tail_entry;
    };
    p.opt_hot = g.jit.opt_threshold;
}

/// Frees what the tier keeps for a function that is being collected.
pub fn freeProto(g: *Global, p: *Proto) void {
    const info = existing(p) orelse return;
    const gpa = g.gpa;
    for (info.units.items) |u| freeUnit(g, u);
    info.units.deinit(gpa);
    info.declined.deinit(gpa);
    gpa.free(info.marks);
    gpa.free(info.fb);
    gpa.destroy(info);
    p.opt = null;
}

/// Marks the functions that the optimized code of `p` was compiled
/// with.
pub fn traverse(m: *gc.MarkerApi, p: *Proto) void {
    const info = existing(p) orelse return;
    for (info.units.items) |u| {
        for (u.protos) |q| m.markHeader(&q.hdr);
    }
}

const save_words: usize = @intCast(@divExact(codegen.save_bytes, 8));

fn valueOf(v: Val, regs: [*]const u64) Value {
    const bits: u64 = switch (v.kind) {
        .reg => regs[v.bits],
        .freg => regs[codegen.gpr_pool.len + v.bits],
        .spill => regs[save_words + v.bits],
        .imm => v.bits,
        .virt => unreachable,
    };
    return switch (v.ty) {
        .nil, .void => .nil,
        .boolean => Value.boolean(bits != 0),
        else => Value.make(bits, @fromBackingInt(@backingInt(v.ty))),
    };
}

/// Writes every value of a snapshot to its slot. `tables` holds the
/// tables that the exit allocated, or is null while the collector runs,
/// when a slot that will hold such a table is left alone.
fn writeBack(l: *Thread, u: *Unit, snap: u32, regs: [*]const u64, tables: ?[]const *Table) []FrameMeta {
    const s = u.snaps[snap];
    const frames = u.frames[s.frames..][0..s.nframes];
    const base = l.frame().base;
    for (frames) |fm| {
        for (u.entries[fm.entries..][0..fm.count]) |e| {
            if (e.val.kind == .virt) {
                // Without the tables, the slot holds nil rather than what
                // it held before, which the program may have dropped and
                // which the collector must then be free to collect.
                l.stack[base + e.slot] = if (tables) |t| Value.obj(.table, t[e.val.bits]) else .nil;
                continue;
            }
            l.stack[base + e.slot] = valueOf(e.val, regs);
        }
    }
    return frames;
}

/// Most tables that one snapshot holds unallocated.
const max_virts = 8;

/// Allocates the tables that a snapshot describes field by field.
/// Returns null when memory ran out.
fn materialize(l: *Thread, u: *Unit, snap: u32, regs: [*]const u64, out: *[max_virts]*Table) ?[]const *Table {
    const g = l.g;
    const s = u.snaps[snap];
    for (u.virts[s.virts..][0..s.nvirts], 0..) |v, i| {
        const t = rt.newVirtualTable(l, 0, v.nc) orelse return null;
        for (u.vfields[v.fields..][0..v.count]) |x| {
            t.hash[x.node] = .{ .key = Value.make(x.key, .string), .val = valueOf(x.val, regs) };
        }
        t.hash_used = v.count;
        // The metatable was checked for a finalizer when the program
        // set it.
        if (v.mt.ty == .table) t.metatable = valueOf(v.mt, regs).as(Table);
        gc.barrierBack(g, &t.hdr);
        out[i] = t;
    }
    return out[0..s.nvirts];
}

/// The baseline code that continues the top frame at its saved pc. A
/// zero address sends the frame to the interpreter.
fn baseline(l: *Thread) jit.Target {
    const fr = l.frame();
    const p = fr.closure.?.proto;
    const code: *jit.Code = @ptrCast(@alignCast(p.jit_code orelse return .{ .addr = 0, .base = 0 }));
    return .{ .addr = code.base + code.offs[fr.pc], .base = fr.base };
}

fn bump(x: *u8) u8 {
    if (x.* < 255) x.* += 1;
    return x.*;
}

/// The address that `rt.deopt` returns when the exit itself failed and
/// the thread holds an error.
pub const failed: usize = 1;

/// The routines that optimized code calls.
pub const rt = struct {
    /// A guard failed. The values of the snapshot go back to their
    /// slots, calls that were compiled inline get their frames, and the
    /// frame continues in baseline code at the instruction that the
    /// guard belongs to. The exit is recorded, so that the next
    /// compilation of the function predicts better.
    pub fn deopt(l: *Thread, u: *Unit, snap: usize, regs: [*]const u64) callconv(.c) jit.Target {
        const g = l.g;
        if (g.jit.opt_dump) std.debug.print("  exit: snapshot {d} of the unit at {d}, pc {d}\n", .{ snap, u.entry_pc, u.frames[u.snaps[snap].frames + u.snaps[snap].nframes - 1].pc });
        // Read before the tables of the snapshot are allocated, which
        // gives their share of the count back.
        const sunk_exit = g.jit.sunk >= g.jit.sunk_limit;
        var tbuf: [max_virts]*Table = undefined;
        const tables = materialize(l, u, @intCast(snap), regs, &tbuf) orelse {
            // Memory ran out. The root frame raises the error at the
            // instruction it was at.
            const fs = writeBack(l, u, @intCast(snap), regs, null);
            l.frame().pc = fs[0].pc;
            _ = l.raiseMem() catch {};
            return .{ .addr = failed, .base = 0 };
        };
        const frames = writeBack(l, u, @intCast(snap), regs, tables);
        const root = l.frame();
        const base0 = root.base;
        root.pc = frames[0].pc;
        for (frames[1..]) |fm| {
            const cl = valueOf(fm.closure, regs).as(Closure);
            const func = base0 + fm.off - 1;
            l.frames.appendAssumeCapacity(.{
                .closure = cl,
                .func = func,
                .base = func + 1,
                .ret = func,
                .want = fm.want,
                .pc = fm.pc,
                .tail = fm.tail,
            });
        }
        const top = l.frame();
        const inner = frames[frames.len - 1];
        l.top = top.base + inner.proto.max_stack;

        // Tables that were never allocated put no pressure on the
        // collector. When enough of them went by, the exit runs a
        // collection, as the allocations would have, and counts as no
        // failure of the code.
        if (sunk_exit) {
            g.jit.sunk = 0;
            // The instruction is a table constructor, and the registers
            // above its target are dead, as they are when the
            // interpreter collects there.
            const saved_top = l.top;
            const ins = inner.proto.code[inner.pc];
            if (opc.op(ins) == .newtable) l.top = top.base + opc.a(ins) + 1;
            gc.fullCollect(g);
            l.top = saved_top;
            g.jit.sunk_limit = @max(sunk_step, g.counter.bytes);
            return baseline(l);
        }
        // Record the exit: against the instruction, and against every
        // call that was compiled inline around it.
        var retire_now = false;
        if (infoOf(g, inner.proto)) |info| {
            const pc = inner.pc;
            const m = bump(&info.marks[pc]);
            if (m == mark_respec or m == mark_generic) retire_now = true;
            if (pc < inner.proto.code.len) {
                const ins = inner.proto.code[pc];
                const ops = [3]u32{ opc.a(ins), opc.b(ins), opc.c(ins) };
                for (ops, 0..) |r, i| {
                    info.fb[pc][i] = if (r < inner.proto.max_stack) @backingInt(l.stack[top.base + r].tag) else no_feedback;
                }
            }
        }
        for (frames[0 .. frames.len - 1]) |fm| {
            if (infoOf(g, fm.proto)) |info| {
                const m = bump(&info.marks[fm.pc - 1]);
                if (m == mark_respec or m == mark_generic) retire_now = true;
            }
        }
        u.exits += 1;
        if (retire_now or u.exits >= max_exits) retire(g, u);
        g.jit.exits += 1;
        return baseline(l);
    }

    /// Optimized code found too little room for its inline frames and
    /// gives the frame back before it ran anything.
    pub fn bail(l: *Thread) callconv(.c) jit.Target {
        return baseline(l);
    }

    /// The collector check of an allocation. The live values go to
    /// their slots first, where the collector finds them, and the stack
    /// top covers `top_slots` registers of the root frame meanwhile.
    pub fn collect(l: *Thread, u: *Unit, snap: usize, regs: [*]const u64, top_slots: usize) callconv(.c) void {
        _ = writeBack(l, u, @intCast(snap), regs, null);
        const saved = l.top;
        const base = l.frame().base;
        var top: u32 = base + @as(u32, @intCast(top_slots));
        // What the unallocated tables of the snapshot refer to lives
        // only in machine registers, so it goes into the slots above
        // the live registers while the collector runs.
        const s = u.snaps[snap];
        for (u.virts[s.virts..][0..s.nvirts]) |v| {
            if (v.mt.ty == .table) {
                l.stack[top] = valueOf(v.mt, regs);
                top += 1;
            }
            for (u.vfields[v.fields..][0..v.count]) |x| {
                if (!x.val.ty.collectable()) continue;
                l.stack[top] = valueOf(x.val, regs);
                top += 1;
            }
        }
        l.top = top;
        gc.maybeCollect(l.g);
        l.top = saved;
    }

    pub fn barrierTable(l: *Thread, tab: *Table, payload: u64, tag: u64, key: usize) callconv(.c) void {
        const v = Value.make(payload, @fromBackingInt(@as(u8, @truncate(tag))));
        const k: Value = if (key != 0) Value.make(key, .string) else .nil;
        gc.barrierTable(l.g, tab, k, v);
    }

    pub fn barrierBack(l: *Thread, h: *gc.Header) callconv(.c) void {
        gc.barrierBack(l.g, h);
    }

    /// A new table, as `state.newTableIn` makes it, without the
    /// collector check, which optimized code makes first. Returns null
    /// when memory ran out.
    pub fn newTable(l: *Thread, narr: usize, nhash: usize) callconv(.c) ?*Table {
        const g = l.g;
        const units = table.inlineUnits(narr, nhash);
        const t = gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * 16) catch return null;
        t.* = .{ .hdr = t.hdr, .inline_units = @intCast(units) };
        if (units > 0) {
            table.initInline(t, narr, nhash);
        } else if (narr > 0 or nhash > 0) {
            // The table is already in the heap, so it stays there empty
            // and the instruction runs again in the interpreter.
            table.resize(g.gpa, t, narr, nhash) catch return null;
        }
        return t;
    }

    /// `newTable` for a record that optimized code kept unallocated
    /// until now. Its constructor already counted the table as sunk, so
    /// the count gives that back, and the allocation is charged once.
    pub fn newVirtualTable(l: *Thread, narr: usize, nhash: usize) callconv(.c) ?*Table {
        const g = l.g;
        g.jit.sunk -|= @sizeOf(Table) + table.inlineUnits(narr, nhash) * 16;
        return newTable(l, narr, nhash);
    }

    pub fn tableLength(t: *Table) callconv(.c) i64 {
        return table.length(t);
    }

    /// The character count of `string.sub(s, i, j)` for a string of
    /// `chars` characters, with the clipping of the library function.
    pub fn subLength(chars: i64, i: i64, j: i64) callconv(.c) i64 {
        const start: i64 = if (i > 0) i else if (i == 0 or i < -chars) 1 else chars + i + 1;
        const end: i64 = if (j > chars) chars else if (j >= 0) j else if (j < -chars) 0 else chars + j + 1;
        return if (start > end) 0 else end - start + 1;
    }

    /// The code point of character `i` of `s`, as `string.byte(s, i)`
    /// returns it, or minus one for a position outside the string.
    pub fn stringByte(l: *Thread, s: *object.String, i: i64) callconv(.c) i64 {
        const n: i64 = s.chars;
        const pos: i64 = if (i > 0) i else if (i == 0 or i < -n) 1 else n + i + 1;
        // The end position is the start position, clipped like the
        // library function clips it.
        const end: i64 = if (i > n) n else if (i >= 0) i else if (i < -n) 0 else n + i + 1;
        if (pos > end or pos < 1 or pos > n) return -1;
        const src = s.bytes();
        if (s.flags.ascii) return src[@intCast(pos - 1)];
        const off = s.byteOffset(l.g.gpa, @intCast(pos - 1));
        return @import("../../vm/wtf8.zig").decodeValid(src, off).cp;
    }
};

// ---------------------------------------------------------------------
// A listing of the intermediate representation, for work on the tier.

fn dump(f: *ir.Func, p: *Proto, pc: u32, ra: regalloc.Result) void {
    const print = std.debug.print;
    print("== opt {s}:{d} from pc {d}\n", .{ if (p.source) |s| s.bytes() else "?", p.line_defined, pc });
    for (ra.order) |b| {
        const blk = &f.blocks.items[b];
        print("b{d} (node {d}{s}{s}):", .{ b, blk.node, if (blk.loop_header) " loop" else "", if (blk.always) "" else " cond" });
        for (blk.preds.items) |x| print(" <b{d}", .{x});
        print("\n", .{});
        for (blk.insts.items) |r| {
            const i = f.at(r);
            print("  %{d} ", .{r});
            switch (ra.loc[r]) {
                .reg => |x| print("[r{d}] ", .{x}),
                .freg => |x| print("[f{d}] ", .{x}),
                .spill => |k| print("[s{d}] ", .{k}),
                .none => {},
            }
            print("{s}:{s}", .{ @tagName(i.op), @tagName(i.ty) });
            if (i.op == .phi) {
                for (f.phi_args.items[i.a..][0..i.b]) |arg| print(" b{d}:%{d}", .{ arg.pred, arg.ref });
            } else if (i.op == .generic) {
                print(" pc={d}", .{i.imm});
                for (f.gen_targets.items[i.a..][0..i.b]) |t| print(" {d}->b{d}", .{ t.pc, t.block });
            } else {
                if (i.a != ir.none) print(" %{d}", .{i.a});
                if (i.b != ir.none) print(" %{d}", .{i.b});
                if (i.c != ir.none) print(" c%{d}", .{i.c});
                print(" imm={d}", .{i.imm});
                if (i.aux != 0) print(" aux={d}", .{i.aux});
                if (i.cond != 0) print(" cond={d}", .{i.cond});
                if (i.cls != .none) print(" {s}", .{@tagName(i.cls)});
                if (i.t != ir.no_block) print(" t=b{d}", .{i.t});
                if (i.f != ir.no_block) print(" f=b{d}", .{i.f});
            }
            if (i.snap != ir.no_snap) {
                const s = f.snaps.items[i.snap];
                print(" snap{d}{{", .{i.snap});
                for (f.snap_frames.items[s.frames..][0..s.nframes]) |fr| {
                    print("pc={d}:", .{fr.pc});
                    for (f.snap_entries.items[fr.entries..][0..fr.count]) |e| print(" {d}=%{d}", .{ e.slot, e.ref });
                    print(";", .{});
                }
                print("}}", .{});
            }
            print("\n", .{});
        }
    }
}
