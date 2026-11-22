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
const shape = @import("../../vm/shape.zig");
const gc = @import("../../vm/gc.zig");
const interp = @import("../../vm/interp.zig");
const opc = @import("../../compile/opcodes.zig");
const jit = @import("../jit.zig");
const mem = @import("../mem.zig");
const aot = @import("../aot.zig");
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
    /// by its index among those tables. `pair` is the result of a direct
    /// call as the callee returned it, the payload and the tag in the
    /// two registers of the convention.
    pub const Kind = enum(u8) { reg, freg, spill, imm, virt, pair };
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
    /// Functions compiled inline or called directly, which the unit
    /// keeps alive.
    protos: []*Proto = &.{},
    exits: u32 = 0,
    retired: bool = false,
    /// The direct calls the unit makes.
    sites: []ir.Site = &.{},
    /// Bytes of native stack the unit holds while it runs: for a unit
    /// that keeps a frame, its spilled values.
    frame_bytes: usize = 0,
    /// The unit is entered directly (`ir.Func.direct`). `total` is the
    /// native frame of one activation, with the return address in its
    /// top word. `ret_a` and `ret_b` are the return addresses of the
    /// calls that the two entries with a frame protocol make.
    direct: bool = false,
    total: usize = 0,
    direct_entry: usize = 0,
    /// The entry of a call that starts a chain of direct calls. It
    /// sets how far the chain may take the native stack, from the room
    /// the Lus stack has left and from `chain_ratio`: the most slots
    /// that the chain covers per sixteen bytes of native stack.
    root_entry: usize = 0,
    chain_ratio: u32 = 1,
    ret_a: usize = 0,
    ret_b: usize = 0,
    /// Nonzero while the unit takes new direct calls. Callers in other
    /// units test this word before they call.
    cell: usize = 0,
    sig: [ir.max_direct_params]ir.Ty = @splat(.nil),
    ret_ty: ?ir.Ty = null,
    writes: u32 = 0,
};

/// Bytes at the low end of the native stack of a thread that chains of
/// direct calls leave to the runtime, which builds their frames there
/// when optimized code is left.
pub const direct_stack_reserve: usize = 128 * 1024;
/// Bytes of native stack below the outermost entry into Lus code that
/// chains of direct calls may use on a stack whose bounds are unknown.
pub const direct_stack_budget: usize = 160 * 1024;

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

pub fn existing(p: *Proto) ?*Info {
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

/// The optimized code of `p` that takes direct calls, if it has some.
pub fn directUnit(p: *Proto) ?*Unit {
    const u = unitAt(p, 0) orelse return null;
    return if (u.direct and u.cell != 0) u else null;
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
pub fn loopEntry(l: *Thread, pc_word: usize) callconv(jit.cc) usize {
    const pc: u32 = @truncate(pc_word);
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
    if (comptime !jit.can_compile) return null;
    const g = l.g;
    const gpa = g.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A function that is compiled from its first instruction is built
    // for direct entry first, and with a frame when that fails.
    var persist: lower.Persist = .{ .direct = pc == 0 and g.jit.direct };
    var loops: []lower.Lower.LoopInfo = &.{};
    var inlined: []*Proto = &.{};
    var cfg: *flow_mod.Cfg = undefined;
    var func: *ir.Func = undefined;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries > 8) {
            if (!persist.direct) return null;
            persist = .{};
            tries = 0;
        }
        func = lower.Lower.build(arena, l, p, pc, &persist, &loops, &cfg, &inlined) catch |e| switch (e) {
            error.Rebuild => continue,
            error.NotDirect => {
                if (!persist.direct) return null;
                if (g.jit.opt_dump) std.debug.print("  rebuild: the function keeps a frame\n", .{});
                persist = .{};
                tries = 0;
                continue;
            },
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
    if (cg.em.aot) |c| c.unit = unit;
    if (!cg.run()) return null;
    cg.em.reportAot();
    const bytes = cg.em.bytes();
    unit.code = g.jit.arena.alloc(gpa, bytes.len) orelse return null;
    if (g.jit.aot != null and cg.em.a.unrelocated == 0) aot.reloadUnitCode(l, unit, cg.em.a.buf.items, cg.em.a.relocs.items);
    mem.install(unit.code, bytes);
    const base = @intFromPtr(unit.code.ptr);
    unit.entry = base + cg.entry_off;
    if (!p.is_vararg and pc == 0) {
        unit.call_entry = base + cg.em.call_entry;
        unit.tail_entry = base + cg.em.tail_entry;
    }
    unit.frame_bytes = @intCast(cg.frame);
    if (func.direct) {
        unit.direct = true;
        unit.total = @intCast(cg.total);
        unit.direct_entry = base + cg.direct_off;
        unit.root_entry = base + cg.root_off;
        unit.chain_ratio = cg.chain_ratio;
        unit.ret_a = base + cg.ret_a_off;
        unit.ret_b = base + cg.ret_b_off;
        unit.sig = func.sig;
        unit.ret_ty = func.ret_ty;
        unit.writes = func.writes;
    }
    unit.sites = gpa.dupe(ir.Site, func.sites.items) catch return null;

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
    // Leaving optimized code inside a direct call finds the unit of
    // every caller by its return address.
    if (unit.sites.len != 0) g.jit.callers.append(gpa, unit) catch return null;
    info.units.append(gpa, unit) catch {
        if (unit.sites.len != 0) _ = g.jit.callers.pop();
        return null;
    };
    unit.cell = 1;
    // The function now refers to the functions compiled inline.
    if (inlined.len != 0) gc.barrierBack(g, &p.hdr);
    if (g.jit.aot) |st| if (cg.em.a.unrelocated == 0) {
        st.keepUnit(g, unit, cg.em.a.relocs.items);
        aot.reloadUnitMeta(l, unit);
    };
    ok = true;
    g.jit.optimized += 1;
    return unit;
}

fn valOf(f: *ir.Func, ra: regalloc.Result, r: ir.Ref) Val {
    const i = f.at(r);
    if (i.op == .dcall) return .{ .kind = .pair, .ty = .nil, .bits = 0 };
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
    if (g.jit.aot) |st| st.forgetUnit(u);
    if (g.jit.aot_section) |s| s.forgetUnit(u);
    if (u.code.len != 0) g.jit.arena.release(gpa, u.code);
    gpa.free(u.snaps);
    gpa.free(u.frames);
    gpa.free(u.entries);
    gpa.free(u.virts);
    gpa.free(u.vfields);
    gpa.free(u.protos);
    gpa.free(u.sites);
    for (g.jit.callers.items, 0..) |x, i| {
        if (x == u) {
            _ = g.jit.callers.swapRemove(i);
            break;
        }
    }
    gpa.destroy(u);
}

/// Stops new entries into a piece of optimized code. Frames that wait
/// in it for a call to return still continue there, so its memory stays
/// until the function is collected.
fn retire(g: *Global, u: *Unit) void {
    if (u.retired) return;
    u.retired = true;
    u.cell = 0;
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
pub fn traverse(m: anytype, p: *Proto) void {
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
        // A callee that returned nothing leaves nil.
        .pair => return if (regs[1] == codegen.no_result) .nil else Value.make(regs[0], @fromBackingInt(@as(u8, @truncate(regs[1])))),
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
    return writeBackAt(l, u, snap, regs, tables, l.frame().base);
}

/// The same for a root frame whose first register is the slot `base`.
fn writeBackAt(l: *Thread, u: *Unit, snap: u32, regs: [*]const u64, tables: ?[]const *Table, base: u32) []FrameMeta {
    const s = u.snaps[snap];
    const frames = u.frames[s.frames..][0..s.nframes];
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
        // The keys in the order they arrived give the shape of the table,
        // when shapes may hold them.
        const fields = u.vfields[v.fields..][0..v.count];
        var sh: ?*shape.Shape = &shape.root;
        for (fields) |x| {
            const cur = sh orelse break;
            sh = g.shapes.transition(g.gpa, cur, @ptrFromInt(@as(usize, @intCast(x.key))), g) catch null;
        }
        const t = if (sh) |shp| blk: {
            const t = rt.newShapedTable(l, @max(v.count, @min(v.nc, shape.max_keys)), shp.id) orelse return null;
            for (fields) |x| {
                const slot = shp.find(@ptrFromInt(@as(usize, @intCast(x.key)))).?;
                t.setSlot(slot, valueOf(x.val, regs));
            }
            break :blk t;
        } else blk: {
            const t = rt.newVirtualTable(l, 0, v.nc) orelse return null;
            for (fields) |x| {
                t.setKey(x.node, Value.make(x.key, .string));
                t.setVal(x.node, valueOf(x.val, regs));
            }
            t.hash_used = v.count;
            break :blk t;
        };
        // The metatable was checked for a finalizer when the program
        // set it.
        if (v.mt.ty == .table) t.metatable = valueOf(v.mt, regs).as(Table);
        gc.barrierBack(g, &t.hdr);
        out[i] = t;
    }
    return out[0..s.nvirts];
}

// ---------------------------------------------------------------------
// Frames of direct calls
//
// A direct call pushes no frame. While a chain of direct calls runs, the
// native stack holds one frame per activation: the spilled values of the
// caller and the address its call returns to. That address names a call
// site, and the site names a snapshot of the caller. Leaving optimized
// code inside the chain walks the native frames from the innermost
// activation outward and builds, for every activation, the frame the
// interpreter would have pushed, with the registers the snapshot lists.
// Nothing can look at the frames of a thread while a chain runs, because
// directly entered code calls nothing but itself and its like, so the
// frames exist whenever anything reads them.

const Hit = struct {
    u: *Unit,
    site: *const ir.Site,
};

fn siteIn(u: *Unit, ra: usize) ?*const ir.Site {
    const start = @intFromPtr(u.code.ptr);
    if (ra < start or ra >= start + u.code.len) return null;
    const off: u32 = @intCast(ra - start);
    for (u.sites) |*s| {
        if (s.ret_off == off) return s;
    }
    return null;
}

/// The call site that returns to `ra`. A recursive function calls from
/// its own unit, which is `hint`.
fn findSite(g: *Global, ra: usize, hint: *Unit) Hit {
    if (siteIn(hint, ra)) |s| return .{ .u = hint, .site = s };
    for (g.jit.callers.items) |u| {
        if (siteIn(u, ra)) |s| return .{ .u = u, .site = s };
    }
    @panic("a direct call returns to no call site");
}

inline fn word(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

inline fn half(addr: usize) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}

/// What ends a chain of direct calls on its outer side.
const Root = union(enum) {
    /// The entry that found the frame of the outermost activation in
    /// place.
    frame,
    /// The entry that baseline code called, which holds what the frame
    /// of the outermost activation needs.
    thunk: struct { pc: u32, nargs: u32, base: u32, want: i32 },
    /// A unit that keeps a frame and called from the native frame at
    /// `sp`.
    unit: struct { u: *Unit, site: *const ir.Site, sp: usize },
};

/// Builds the frame of every activation of the chain of direct calls
/// whose innermost activation runs `first` with its native frame at `sp0`
/// and leaves through `snap0`. Afterwards the top frame is the frame of
/// that activation, with its registers still to be written, and every
/// frame below is complete.
///
/// The entry of a chain keeps its activations inside the Lus stack
/// (`codegen.rootEntry`), so every one of them fits. The walk checks the
/// room all the same, as the interpreter does when it enters a function.
/// Should an activation lack room, the ones that fit get their frames,
/// and the error that the interpreter raises at the call that found no
/// room is raised from the innermost one of them.
fn unwind(l: *Thread, first: *Unit, snap0: u32, sp0: usize) state.Error!void {
    const g = l.g;
    const top_i = l.frames.items.len - 1;
    const regs_off: usize = @intCast(codegen.save_bytes);

    // The first walk finds where the chain ends, how many activations
    // wait in it, and how many slots and frames they cover.
    var links: usize = 0;
    var slots: u32 = 0;
    var nframes: usize = 0;
    var cur = first;
    var sp = sp0;
    var root: Root = undefined;
    var outer_pc: u32 = first.frames[first.snaps[snap0].frames].pc;
    while (true) {
        const up = sp + cur.total;
        const ra = word(up - 8);
        if (ra == cur.ret_a) {
            root = .frame;
            g.jit.exit_sp = up;
            break;
        }
        if (ra == cur.ret_b) {
            root = .{ .thunk = .{ .pc = half(up), .nargs = half(up + 4), .base = half(up + 8), .want = @bitCast(half(up + 12)) } };
            g.jit.exit_sp = up + @as(usize, @intCast(codegen.thunk_bytes));
            break;
        }
        const hit = findSite(g, ra, cur);
        if (!hit.u.direct) {
            root = .{ .unit = .{ .u = hit.u, .site = hit.site, .sp = up } };
            g.jit.exit_sp = up + hit.u.frame_bytes;
            break;
        }
        const s = hit.u.snaps[hit.site.snap];
        slots += hit.site.slot + 1;
        nframes += s.nframes;
        links += 1;
        outer_pc = hit.u.frames[s.frames].pc;
        cur = hit.u;
        sp = up;
    }

    // The frame below the chain continues where its call returns.
    var base_n: u32 = undefined;
    var fi_n: usize = undefined;
    switch (root) {
        .frame => {
            const fr = &l.frames.items[top_i];
            fr.pc = outer_pc;
            base_n = fr.base;
            fi_n = top_i;
        },
        .thunk => |t| {
            l.frames.items[top_i].pc = t.pc;
            base_n = t.base;
            fi_n = top_i + 1;
        },
        .unit => |c| {
            const fr = &l.frames.items[top_i];
            const s = c.u.snaps[c.site.snap];
            fr.pc = c.u.frames[s.frames].pc;
            base_n = fr.base + c.site.slot + 1;
            fi_n = top_i + s.nframes;
        },
    }
    const fi0 = fi_n + nframes;
    l.frames.ensureTotalCapacity(g.gpa, fi0 + max_inline_depth + 2) catch return l.raiseMem();

    // The second walk builds the frames, from the innermost activation
    // outward. `below` is the site an activation waits at.
    cur = first;
    sp = sp0;
    var base: u32 = base_n + slots;
    var fi: usize = fi0;
    var below: ?Hit = null;
    var kept_len: usize = 0;
    var callee_kept = false;
    var callee_fi: usize = 0;
    var callee_base: u32 = 0;
    var callee_stack: u32 = 0;
    var raise: ?struct { func: u32, nargs: u32, max_stack: u32 } = null;
    var k: usize = 0;
    while (true) : (k += 1) {
        const up = sp + cur.total;
        const outermost = k == links;
        var above: ?Hit = null;
        var nargs: u32 = 0;
        var want: i32 = 0;
        if (!outermost) {
            above = findSite(g, word(up - 8), cur);
            nargs = above.?.site.nargs;
            want = above.?.site.want;
        } else switch (root) {
            .frame => {},
            .thunk => |t| {
                nargs = t.nargs;
                want = t.want;
            },
            .unit => |c| {
                nargs = c.site.nargs;
                want = c.site.want;
            },
        }
        const in_place = outermost and root == .frame;
        const p = cur.proto;
        // The room the interpreter asks for when it enters the function.
        var fits = in_place or @as(u64, base) + p.max_stack + 2 * @as(u64, nargs) + 8 <= Thread.max_stack;
        if (k == 0 and @as(u64, base) + cur.extent + 16 > Thread.max_stack) fits = in_place;
        if (fits) {
            const end: u32 = if (below) |b| base + b.site.slot else base + @max(cur.extent, p.max_stack);
            if (kept_len == 0) {
                // The innermost activation that fits. The stack grows
                // once, to hold it.
                const need = end + 16;
                if (need > l.stack.len) {
                    if (l.top > need) l.top = need;
                    try l.ensure(need - l.top);
                }
                if (below) |b| {
                    kept_len = fi + cur.snaps[b.site.snap].nframes;
                    raise = .{ .func = base + b.site.slot, .nargs = b.site.nargs, .max_stack = callee_stack };
                } else kept_len = fi + 1;
            }
            const frames = l.frames.items.ptr;
            if (!in_place) frames[fi] = .{ .func = base - 1, .base = base, .ret = base - 1, .want = want };
            // Registers that the snapshot leaves out are dead.
            for (l.stack[base..end]) |*v| v.* = .nil;
            if (below) |b| {
                const regs: [*]const u64 = @ptrFromInt(sp - regs_off);
                const fms = writeBackAt(l, cur, b.site.snap, regs, null, base);
                frames[fi].pc = fms[0].pc;
                for (fms[1..], 1..) |fm, j| {
                    const func = base + fm.off - 1;
                    frames[fi + j] = .{
                        .closure = valueOf(fm.closure, regs).as(Closure),
                        .func = func,
                        .base = func + 1,
                        .ret = func,
                        .want = fm.want,
                        .pc = fm.pc,
                        .tail = fm.tail,
                    };
                }
                if (callee_kept) frames[callee_fi].closure = l.stack[callee_base - 1].as(Closure);
            }
        }
        callee_kept = fits;
        callee_fi = fi;
        callee_base = base;
        callee_stack = p.max_stack;
        if (outermost) break;
        const hit = above.?;
        base -= hit.site.slot + 1;
        fi -= hit.u.snaps[hit.site.snap].nframes;
        below = hit;
        cur = hit.u;
        sp = up;
    }

    // What ends the chain supplies the closure of the outermost
    // activation, and a unit with a frame writes its own values back.
    const frames = l.frames.items.ptr;
    switch (root) {
        .frame => {},
        .thunk => |t| {
            if (callee_kept) {
                frames[fi_n].closure = l.stack[base_n - 1].as(Closure);
            } else {
                kept_len = top_i + 1;
                raise = .{ .func = t.base - 1, .nargs = t.nargs, .max_stack = callee_stack };
            }
        },
        .unit => |c| {
            const regs: [*]const u64 = @ptrFromInt(c.sp - regs_off);
            const root_base = frames[top_i].base;
            const fms = writeBackAt(l, c.u, c.site.snap, regs, null, root_base);
            for (fms[1..], 1..) |fm, j| {
                const func = root_base + fm.off - 1;
                frames[top_i + j] = .{
                    .closure = valueOf(fm.closure, regs).as(Closure),
                    .func = func,
                    .base = func + 1,
                    .ret = func,
                    .want = fm.want,
                    .pc = fm.pc,
                    .tail = fm.tail,
                };
            }
            if (callee_kept) {
                frames[fi_n].closure = l.stack[base_n - 1].as(Closure);
            } else {
                kept_len = top_i + fms.len;
                raise = .{ .func = root_base + c.site.slot, .nargs = c.site.nargs, .max_stack = callee_stack };
            }
        },
    }
    l.frames.items.len = kept_len;
    if (raise) |r| {
        // The call that found no room raises as it does in the
        // interpreter, with its arguments below the stack top.
        l.top = r.func + 1 + r.nargs;
        try l.ensure(@as(usize, r.max_stack) + r.nargs + 8);
        return l.raiseMsg("stack overflow");
    }
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
    pub fn deopt(l: *Thread, u: *Unit, snap: usize, regs: [*]const u64) callconv(jit.cc) jit.Target {
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
        // An exit that says nothing about the predictions of the code
        // is left out of the records.
        const flags = u.snaps[snap];
        if (flags.quiet) return baseline(l);
        // Record the exit: against the instruction, and against every
        // call that was compiled inline around it. An exit after a
        // direct call counts against the call.
        var retire_now = false;
        if (infoOf(g, inner.proto)) |info| {
            const pc = if (flags.after_call) inner.pc - 1 else inner.pc;
            const m = bump(&info.marks[pc]);
            if (m == mark_respec or m == mark_generic) retire_now = true;
            if (!flags.after_call and pc < inner.proto.code.len) {
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

    /// A guard failed in a function that was entered directly. Every
    /// direct call that is running gets its frame first, from the
    /// native frames of the callers, and then the exit proceeds as any
    /// other. The native stack pointer that the entry sequence expects
    /// is left in the state for the code that called.
    pub fn deoptDirect(l: *Thread, u: *Unit, snap: usize, regs: [*]const u64) callconv(jit.cc) jit.Target {
        const sp = @intFromPtr(regs) + @as(usize, @intCast(codegen.save_bytes));
        unwind(l, u, @intCast(snap), sp) catch return .{ .addr = failed, .base = 0 };
        return deopt(l, u, snap, regs);
    }

    /// Optimized code found too little room for its inline frames and
    /// gives the frame back before it ran anything.
    pub fn bail(l: *Thread) callconv(jit.cc) jit.Target {
        return baseline(l);
    }

    /// The collector check of an allocation. The live values go to
    /// their slots first, where the collector finds them, and the stack
    /// top covers `top_slots` registers of the root frame meanwhile.
    pub fn collect(l: *Thread, u: *Unit, snap: usize, regs: [*]const u64, top_slots: usize) callconv(jit.cc) void {
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

    pub fn barrierTable(l: *Thread, tab: *Table, payload: u64, tag: u64, key: usize) callconv(jit.cc) void {
        const v = Value.make(payload, @fromBackingInt(@as(u8, @truncate(tag))));
        const k: Value = if (key != 0) Value.make(key, .string) else .nil;
        gc.barrierTable(l.g, tab, k, v);
    }

    pub fn barrierBack(l: *Thread, h: *gc.Header) callconv(jit.cc) void {
        gc.barrierBack(l.g, h);
    }

    /// A new table, as `state.newTableIn` makes it, without the
    /// collector check, which optimized code makes first. Returns null
    /// when memory ran out.
    pub fn newTable(l: *Thread, narr: usize, nhash: usize, ic: ?*const object.IcEntry) callconv(jit.cc) ?*Table {
        const g = l.g;
        // A site whose lists fit an unboxed kind keeps them in one word
        // per slot (`state.newTableAt`).
        const words = narr > 0 and ic != null and ic.?.own == object.IcEntry.lists_words;
        const units = table.inlineUnitsSlots(narr, nhash, if (words) @sizeOf(u64) else @sizeOf(Value));
        const t = gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit) catch return null;
        t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) } };
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
    /// A record that optimized code kept unallocated until now, with the
    /// shape `id` and `cap` empty slots in its cell, which the code then
    /// fills. Its constructor already counted the table as sunk.
    pub fn newShapedTable(l: *Thread, cap: usize, id: usize) callconv(jit.cc) ?*Table {
        const g = l.g;
        const units = table.inlineUnitsSlots(0, cap, @sizeOf(Value));
        g.jit.sunk -|= @sizeOf(Table) + units * Table.inline_unit;
        const t = gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit) catch return null;
        t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) } };
        table.initInline(t, 0, cap);
        t.setShapeId(@intCast(id));
        return t;
    }

    pub fn newVirtualTable(l: *Thread, narr: usize, nhash: usize) callconv(jit.cc) ?*Table {
        const g = l.g;
        g.jit.sunk -|= @sizeOf(Table) + table.inlineUnits(narr, nhash) * Table.inline_unit;
        // Optimized code writes the fields of the record into hash nodes
        // laid out as `table.hashSizeExact` sizes them, so the table is a
        // dictionary.
        const units = table.inlineUnitsDict(narr, nhash, @sizeOf(Value));
        const t = gc.allocUninit(g, Table, .table, @sizeOf(Table) + units * Table.inline_unit) catch return null;
        t.* = .{ .hdr = t.hdr, .cell = .{ .inline_units = @intCast(units) }, .hash_used = 0 };
        if (units > 0) {
            table.initInline(t, narr, nhash);
        } else if (narr > 0 or nhash > 0) {
            table.resize(g.gpa, t, narr, nhash) catch return null;
        }
        return t;
    }

    pub fn tableLength(t: *Table) callconv(jit.cc) i64 {
        return table.length(t);
    }

    /// The character count of `string.sub(s, i, j)` for a string of
    /// `chars` characters, with the clipping of the library function.
    pub fn subLength(chars: i64, i: i64, j: i64) callconv(jit.cc) i64 {
        const start: i64 = if (i > 0) i else if (i == 0 or i < -chars) 1 else chars + i + 1;
        const end: i64 = if (j > chars) chars else if (j >= 0) j else if (j < -chars) 0 else chars + j + 1;
        return if (start > end) 0 else end - start + 1;
    }

    /// The code point of character `i` of `s`, as `string.byte(s, i)`
    /// returns it, or minus one for a position outside the string.
    pub fn stringByte(l: *Thread, s: *object.String, i: i64) callconv(jit.cc) i64 {
        const n: i64 = s.chars();
        const pos: i64 = if (i > 0) i else if (i == 0 or i < -n) 1 else n + i + 1;
        // The end position is the start position, clipped like the
        // library function clips it.
        const end: i64 = if (i > n) n else if (i >= 0) i else if (i < -n) 0 else n + i + 1;
        if (pos > end or pos < 1 or pos > n) return -1;
        const src = s.bytes();
        if (s.flags().ascii) return src[@intCast(pos - 1)];
        const off = s.byteOffset(&l.g.gpa, @intCast(pos - 1));
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
