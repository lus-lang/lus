//! Code compiled ahead of time (`spec/design/aot.md`): the resolver of
//! addresses, the training run that keeps the code of a program with its
//! relocations, and the loader that installs that code in an executable.
//!
//! An assembler that compiles ahead of time asks the resolver what each
//! wide immediate is: an address that the loader can find again, a
//! literal, or an address of something the loader cannot find.
//!
//! `LUS_JIT_AOT=check:PATH` compiles every function in the form of code
//! compiled ahead of time, with real addresses in its relocated words, and
//! runs it. Each address that the resolver cannot name appends a line to
//! the file at PATH.
//!
//! `LUS_JIT_AOT=train:PATH` does the same in a bundle made by `lus build`,
//! and keeps the baseline code and the optimized units of every bundled
//! function with their relocations. When the state closes, it writes them
//! to PATH as the code section that `lus build --aot` appends to the
//! executable. The loader installs the code of each function of the
//! section when its module loads.
//!
//! `LUS_JIT_AOT=reload:PATH` runs every function that either tier compiles
//! from what the loader makes of its code and its metadata.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const gc = @import("../vm/gc.zig");
const heap = @import("../vm/heap.zig");
const table = @import("../vm/table.zig");
const value = @import("../vm/value.zig");
const reloc = @import("reloc.zig");
const helpers = @import("helpers.zig");
const mem = @import("mem.zig");
const jit = @import("jit.zig");
const opt = @import("opt/opt.zig");

const Thread = state.Thread;
const Global = state.Global;
const Proto = object.Proto;
const Value = value.Value;

/// Every routine that native code calls, in the order that numbers them
/// for `reloc.Kind.routine`. The step routines follow, by opcode. The
/// runtime of an executable compiled ahead of time has the same table.
pub const routines = [_]*const anyopaque{
    @ptrCast(&jit.dispatch),
    @ptrCast(&opt.loopEntry),
    @ptrCast(&opt.rt.deopt),
    @ptrCast(&opt.rt.deoptDirect),
    @ptrCast(&opt.rt.bail),
    @ptrCast(&opt.rt.collect),
    @ptrCast(&opt.rt.barrierTable),
    @ptrCast(&opt.rt.barrierBack),
    @ptrCast(&opt.rt.newTable),
    @ptrCast(&opt.rt.newShapedTable),
    @ptrCast(&opt.rt.newVirtualTable),
    @ptrCast(&opt.rt.tableLength),
    @ptrCast(&opt.rt.intKeyAbsent),
    @ptrCast(&opt.rt.tableAppend),
    @ptrCast(&opt.rt.subLength),
    @ptrCast(&opt.rt.stringByte),
    @ptrCast(&helpers.concatShort),
    @ptrCast(&helpers.tforStep),
    @ptrCast(&helpers.getStr),
    @ptrCast(&helpers.setStr),
    @ptrCast(&helpers.getArray),
    @ptrCast(&helpers.setArray),
    @ptrCast(&helpers.getIndex),
    @ptrCast(&helpers.length),
    @ptrCast(&helpers.barrier),
    @ptrCast(&helpers.barrierTable),
    @ptrCast(&helpers.tailcall),
    @ptrCast(&helpers.callNative),
    @ptrCast(&helpers.tailNative),
    @ptrCast(&helpers.returnAll),
    @ptrCast(&helpers.ctxGet),
    @ptrCast(&helpers.ctxSet),
    @ptrCast(&helpers.closeUpvals),
};

/// The routines that the assembler of the target calls on its own, which
/// take the numbers after the step routines. 32-bit ARM divides 64-bit
/// integers and truncates floats in routines of `a32.zig`.
const target_routines: []const *const anyopaque = if (builtin.cpu.arch == .arm) &@import("a32.zig").routines else &.{};

/// The number of the routine at `addr`, or null.
pub fn routineId(addr: usize) ?u32 {
    for (routines, 0..) |r, i| if (@intFromPtr(r) == addr) return @intCast(i);
    for (helpers.steps, 0..) |s, i| if (@intFromPtr(s) == addr) return @intCast(routines.len + i);
    for (target_routines, 0..) |r, i| if (@intFromPtr(r) == addr) return @intCast(routines.len + helpers.steps.len + i);
    return null;
}

/// The address of routine `id` in this process.
fn routineAddr(id: u32) ?usize {
    if (id < routines.len) return @intFromPtr(routines[id]);
    const s = id - routines.len;
    if (s < helpers.steps.len) return @intFromPtr(helpers.steps[s]);
    const t = s - helpers.steps.len;
    if (t < target_routines.len) return @intFromPtr(target_routines[t]);
    return null;
}

// ---------------------------------------------------------------------
// The state of a run that compiles ahead of time

pub const Mode = enum { check, train, reload };

/// What a state that compiles ahead of time keeps across compilations:
/// the strings that relocations name by their characters, the paths of
/// the natives, and in a training run the relocations of every function.
pub const State = struct {
    gpa: std.mem.Allocator,
    mode: Mode,
    path: [:0]u8,
    strings: std.ArrayList([]u8) = .empty,
    string_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The path in the global tables of each native function, by the
    /// address of its function. A path enters `strings` only when code
    /// names its native, since the linker keeps every builtin that the
    /// strings of the code section name.
    natives: std.AutoHashMapUnmanaged(usize, []u8) = .empty,
    natives_built: bool = false,
    /// The relocations of the baseline code of every bundled function.
    records: std.AutoHashMapUnmanaged(*Proto, []reloc.Entry) = .empty,
    /// The relocations of every optimized unit of a bundled function.
    unit_records: std.AutoHashMapUnmanaged(*opt.Unit, []reloc.Entry) = .empty,
    /// The last number that a reload run gave a function.
    last_id: u32 = 0,
    /// Whether the code takes the static form, for a target without
    /// executable memory (`reloc.Form.slot`).
    static: bool = false,

    /// Reads `LUS_JIT_AOT`, which is `check:PATH` or `train:PATH`, with
    /// `+static` after the mode for the static form.
    pub fn fromEnv(gpa: std.mem.Allocator, v: []const u8) ?*State {
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse return null;
        const plus = std.mem.indexOfScalar(u8, v[0..colon], '+');
        const static = if (plus) |k| std.mem.eql(u8, v[k..colon], "+static") else false;
        if (plus != null and !static) return null;
        const mode = std.meta.stringToEnum(Mode, v[0 .. plus orelse colon]) orelse return null;
        const s = gpa.create(State) catch return null;
        const path = gpa.dupeSentinel(u8, v[colon + 1 ..], 0) catch {
            gpa.destroy(s);
            return null;
        };
        s.* = .{ .gpa = gpa, .mode = mode, .path = path, .static = static };
        return s;
    }

    pub fn destroy(s: *State) void {
        for (s.strings.items) |x| s.gpa.free(x);
        s.strings.deinit(s.gpa);
        s.string_index.deinit(s.gpa);
        var nit = s.natives.valueIterator();
        while (nit.next()) |p| s.gpa.free(p.*);
        s.natives.deinit(s.gpa);
        var it = s.records.valueIterator();
        while (it.next()) |r| s.gpa.free(r.*);
        s.records.deinit(s.gpa);
        var ut = s.unit_records.valueIterator();
        while (ut.next()) |r| s.gpa.free(r.*);
        s.unit_records.deinit(s.gpa);
        s.gpa.free(s.path);
        s.gpa.destroy(s);
    }

    /// The index of `bytes` in the string table, which is added when new.
    fn intern(s: *State, bytes: []const u8) ?u32 {
        if (s.string_index.get(bytes)) |i| return i;
        const copy = s.gpa.dupe(u8, bytes) catch return null;
        const i: u32 = @intCast(s.strings.items.len);
        s.strings.append(s.gpa, copy) catch {
            s.gpa.free(copy);
            return null;
        };
        s.string_index.put(s.gpa, copy, i) catch return null;
        return i;
    }

    /// Records the paths of the natives that the global tables hold: a
    /// global function by its name, and a function of a library by the
    /// name of the library, a dot, and its own name.
    fn buildNatives(s: *State, g: *Global) void {
        s.natives_built = true;
        if (g.globals.tag != .table) return;
        walkNatives(s, g.globals.as(object.Table), "");
    }

    fn walkNatives(s: *State, t: *object.Table, prefix: []const u8) void {
        var key: Value = .nil;
        while (table.next(t, key) catch null) |kv| : (key = kv.key) {
            if (kv.key.tag != .string) continue;
            const name = kv.key.as(object.String).bytes();
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch continue;
            switch (kv.val.tag) {
                .native => {
                    const n = kv.val.as(state.Native);
                    if (s.natives.contains(@intFromPtr(n.func))) continue;
                    const copy = s.gpa.dupe(u8, path) catch continue;
                    s.natives.put(s.gpa, @intFromPtr(n.func), copy) catch s.gpa.free(copy);
                },
                .table => if (prefix.len == 0) {
                    var pbuf: [256]u8 = undefined;
                    const p2 = std.fmt.bufPrint(&pbuf, "{s}.", .{name}) catch continue;
                    walkNatives(s, kv.val.as(object.Table), p2);
                },
                else => {},
            }
        }
    }

    /// Keeps the relocations of the baseline code of `p` in a training run.
    pub fn keep(s: *State, g: *Global, p: *Proto, entries: []const reloc.Entry) void {
        if (s.mode != .train or idOf(g, p) == 0) return;
        const copy = s.gpa.dupe(reloc.Entry, entries) catch return;
        if (s.records.fetchPut(s.gpa, p, copy) catch null) |old| s.gpa.free(old.value);
    }

    /// Forgets a function that the collector frees.
    pub fn forget(s: *State, p: *Proto) void {
        if (s.records.fetchRemove(p)) |kv| s.gpa.free(kv.value);
    }

    /// Keeps the relocations of an optimized unit in a training run.
    pub fn keepUnit(s: *State, g: *Global, u: *opt.Unit, entries: []const reloc.Entry) void {
        if (s.mode != .train or idOf(g, u.proto) == 0) return;
        const copy = s.gpa.dupe(reloc.Entry, entries) catch return;
        if (s.unit_records.fetchPut(s.gpa, u, copy) catch null) |old| s.gpa.free(old.value);
    }

    /// Forgets a unit that the tier frees.
    pub fn forgetUnit(s: *State, u: *opt.Unit) void {
        if (s.unit_records.fetchRemove(u)) |kv| s.gpa.free(kv.value);
    }
};

// ---------------------------------------------------------------------
// The resolver

/// The state of one compilation ahead of time. The index of the heap is
/// built when the first wide immediate needs it.
pub const Context = struct {
    gpa: std.mem.Allocator,
    g: *Global,
    st: *State,
    p: *Proto,
    /// The unit that the optimizing tier compiles, when it does.
    unit: ?*opt.Unit = null,
    built: bool = false,
    protos: std.ArrayList(*Proto) = .empty,
    /// The function and the constant that hold each constant object.
    objects: std.AutoHashMapUnmanaged(usize, ObjRef) = .empty,
    /// The first addresses that the resolver could not name, for the
    /// report.
    unknown: [4]usize = @splat(0),
    unknown_len: u32 = 0,

    const ObjRef = struct { proto: u32, index: u32 };

    pub fn init(gpa: std.mem.Allocator, g: *Global, st: *State, p: *Proto) Context {
        return .{ .gpa = gpa, .g = g, .st = st, .p = p };
    }

    pub fn deinit(c: *Context) void {
        c.protos.deinit(c.gpa);
        c.objects.deinit(c.gpa);
    }

    pub fn resolver(c: *Context) reloc.Resolver {
        return .{ .ctx = c, .resolve = resolveThunk };
    }

    fn resolveThunk(ctx: *anyopaque, v: u64) reloc.Resolution {
        const c: *Context = @ptrCast(@alignCast(ctx));
        return c.resolve(@intCast(v));
    }

    fn build(c: *Context) void {
        c.built = true;
        heap.forEachObject(c.g, c, struct {
            fn f(cc: *Context, h: *gc.Header) void {
                if (h.tag != .proto) return;
                const p: *Proto = @ptrCast(@alignCast(h));
                cc.protos.append(cc.gpa, p) catch return;
                const id = idOf(cc.g, p);
                if (id == 0) return;
                for (p.constants, 0..) |k, i| {
                    if (!k.tag.isCollectable()) continue;
                    cc.objects.put(cc.gpa, @intCast(k.payload), .{ .proto = id, .index = @intCast(i) }) catch return;
                }
            }
        }.f);
    }

    fn unknownAt(c: *Context, v: usize) reloc.Resolution {
        if (c.unknown_len < c.unknown.len) c.unknown[c.unknown_len] = v;
        c.unknown_len += 1;
        return .unknown;
    }

    /// Decides what the wide immediate `v` is.
    pub fn resolve(c: *Context, v: usize) reloc.Resolution {
        if (routineId(v)) |id| return .{ .address = .{ .kind = .routine, .a = id } };
        const g = @intFromPtr(c.g);
        if (v >= g and v < g + @sizeOf(Global)) return .{ .address = .{ .kind = .global, .a = @intCast(v - g) } };
        if (c.unit) |u| {
            const lo = @intFromPtr(u);
            if (v >= lo and v < lo + @sizeOf(opt.Unit)) {
                const id = idOf(c.g, c.p);
                if (id == 0) return c.unknownAt(v);
                return .{ .address = .{ .kind = .unit, .a = id, .b = u.entry_pc, .c = @intCast(v - lo) } };
            }
        }
        if (!c.built) c.build();
        for (c.protos.items) |p| {
            const lo = @intFromPtr(p);
            const pid = idOf(c.g, p);
            var hit: ?reloc.Reloc = null;
            if (v >= lo and v < lo + @sizeOf(Proto)) hit = .{ .kind = .proto_field, .a = pid, .b = @intCast(v - lo) };
            if (hit == null and p.constants.len > 0) {
                const k0 = @intFromPtr(p.constants.ptr);
                if (v >= k0 and v < k0 + p.constants.len * @sizeOf(Value) and (v - k0) % @sizeOf(Value) == 0)
                    hit = .{ .kind = .proto_const, .a = pid, .b = @intCast((v - k0) / @sizeOf(Value)) };
            }
            if (hit == null and p.ic.len > 0) {
                const c0 = @intFromPtr(p.ic.ptr);
                const size = @sizeOf(@TypeOf(p.ic[0]));
                if (v >= c0 and v < c0 + p.ic.len * size)
                    hit = .{ .kind = .ic, .a = pid, .b = @intCast((v - c0) / size), .c = @intCast((v - c0) % size) };
            }
            if (hit == null) hit = codeHit(p, pid, v);
            if (hit) |h| {
                // A function outside the bundle has no number to name it by.
                if (pid == 0) return c.unknownAt(v);
                return .{ .address = h };
            }
        }
        if (c.objects.get(v)) |o| return .{ .address = .{ .kind = .const_obj, .a = o.proto, .b = o.index } };
        // A word of the global state that holds the address.
        const words: [*]const usize = @ptrCast(@alignCast(c.g));
        for (words[0 .. @sizeOf(Global) / @sizeOf(usize)], 0..) |w, i| {
            if (w == v) return .{ .address = .{ .kind = .global_value, .a = @intCast(i * @sizeOf(usize)) } };
        }
        if (!c.st.natives_built) c.st.buildNatives(c.g);
        if (c.st.natives.get(v)) |path| if (c.st.intern(path)) |n| return .{ .address = .{ .kind = .native, .a = n } };
        if (inHeap(c.g, v)) {
            // Only an interned string is the same object when the loader
            // makes it again from its characters.
            if (heapObjectOf(c.g, v)) |h| if (h.tag == .string and @intFromPtr(h) == v) {
                const str: *object.String = @ptrCast(@alignCast(h));
                if (str.flags().interned) if (c.st.intern(str.bytes())) |i| return .{ .address = .{ .kind = .interned, .a = i } };
            };
            return c.unknownAt(v);
        }
        if (inArena(c.g, v) or inImage(v)) return c.unknownAt(v);
        return .literal;
    }
};

/// The entry pc that names the baseline code of a function in a `code`
/// relocation, where the optimized units name their own entry pc.
pub const baseline_pc = std.math.maxInt(u32);

/// What `v` points into among the native code of `p`: its baseline code,
/// one of its optimized units, or the record of a unit.
fn codeHit(p: *Proto, pid: u32, v: usize) ?reloc.Reloc {
    if (p.jit_code) |cp| {
        const code: *jit.Code = @ptrCast(@alignCast(cp));
        if (v >= code.base and v < code.base + code.size) return .{ .kind = .code, .a = pid, .b = baseline_pc, .c = @intCast(v - code.base) };
    }
    const info = opt.existing(p) orelse return null;
    for (info.units.items) |u| {
        if (u.retired) continue;
        const lo = @intFromPtr(u);
        if (v >= lo and v < lo + @sizeOf(opt.Unit)) return .{ .kind = .unit, .a = pid, .b = u.entry_pc, .c = @intCast(v - lo) };
        const c0 = @intFromPtr(u.code.ptr);
        if (u.code.len != 0 and v >= c0 and v < c0 + u.code.len) return .{ .kind = .code, .a = pid, .b = u.entry_pc, .c = @intCast(v - c0) };
    }
    return null;
}

/// Whether `v` points into a page of the collected heap.
fn inHeap(g: *Global, v: usize) bool {
    var seg = g.heap.segments;
    while (seg) |s| : (seg = s.next) {
        const lo = @intFromPtr(s);
        if (v >= lo and v < lo + heap.segment_size) return true;
    }
    return false;
}

/// Whether `v` points into the executable memory of the JIT, which other
/// code compiled ahead of time cannot name.
fn inArena(g: *Global, v: usize) bool {
    for (g.jit.arena.chunks.items) |c| if (v >= c.start and v < c.start + c.len) return true;
    return false;
}

extern "c" fn dladdr(addr: *const anyopaque, info: *DlInfo) c_int;

/// Records the range of the executable image for `reloc.wide`, so that
/// an address of a static executable loaded below 4 GB is relocated.
pub fn noteImage() void {
    if (comptime builtin.object_format == .elf and builtin.link_libc) {
        reloc.image = .{ .lo = @intFromPtr(&elf_bounds.__ehdr_start), .hi = @intFromPtr(&elf_bounds._end) };
    }
}

const elf_bounds = struct {
    extern const __ehdr_start: u8;
    extern const _end: u8;
};
/// Whether the C library can name the image and the symbol of an address.
const has_dladdr = builtin.link_libc and builtin.os.tag != .windows;
const DlInfo = extern struct {
    fname: ?[*:0]const u8,
    fbase: ?*anyopaque,
    sname: ?[*:0]const u8,
    saddr: ?*anyopaque,
};

/// Whether `v` points into the image of the running executable, where
/// only the routines and the natives have names. Native code calls
/// nothing in other images, so an immediate that lands in one is a
/// literal.
fn inImage(v: usize) bool {
    // Every address of a user process lies below 2^48.
    if (v < 4096 or @as(u64, v) >> 48 != 0) return false;
    // An ELF executable lies between the symbols that every linker
    // defines at its first and its last byte. `dladdr` of a static
    // executable finds nothing.
    if (comptime builtin.object_format == .elf and builtin.link_libc) {
        const start = @intFromPtr(&elf_bounds.__ehdr_start);
        return v >= start and v < @intFromPtr(&elf_bounds._end);
    }
    if (comptime !has_dladdr) return false;
    var own: DlInfo = undefined;
    if (dladdr(routines[0], &own) == 0) return false;
    var info: DlInfo = undefined;
    return dladdr(@ptrFromInt(v), &info) != 0 and info.fbase == own.fbase;
}

/// The object of the collected heap whose cell holds `v`, found by a
/// walk of the heap.
fn heapObjectOf(g: *Global, v: usize) ?*gc.Header {
    const Find = struct { v: usize, found: ?*gc.Header = null };
    var f: Find = .{ .v = v };
    heap.forEachObject(g, &f, struct {
        fn each(ff: *Find, h: *gc.Header) void {
            const lo = @intFromPtr(h);
            if (ff.v >= lo and ff.v < lo + 64 and (ff.found == null or lo > @intFromPtr(ff.found.?))) ff.found = h;
        }
    }.each);
    return f.found;
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fputs(s: [*:0]const u8, f: *anyopaque) c_int;
extern "c" fn fwrite(p: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;

/// Where `LUS_JIT_AOT=check:PATH` and `reload:PATH` write the addresses that the resolver
/// could not name, one line each, with what each points into.
pub fn report(c: *Context, unresolved: u32) void {
    if (!builtin.link_libc or c.st.mode == .train) return;
    const p = c.p;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const src: []const u8 = if (p.source) |sv| sv.bytes() else "?";
    w.print("{s}:{d}: {d} address(es) without a relocation:", .{ src[0..@min(src.len, 80)], p.line_defined, unresolved }) catch return;
    for (c.unknown[0..@min(c.unknown_len, c.unknown.len)]) |v| {
        if (inHeap(c.g, v)) {
            const h: *gc.Header = heapObjectOf(c.g, v) orelse {
                w.print(" heap 0x{x}", .{v}) catch return;
                continue;
            };
            w.print(" heap {s}+{d}", .{ @tagName(h.tag), v - @intFromPtr(h) }) catch return;
        } else if (inArena(c.g, v)) {
            w.writeAll(" code") catch return;
        } else {
            var name: []const u8 = "?";
            if (comptime has_dladdr) {
                var info: DlInfo = undefined;
                if (dladdr(@ptrFromInt(v), &info) != 0 and info.sname != null) name = std.mem.span(info.sname.?);
            }
            w.print(" image {s}@0x{x}", .{ name, v }) catch return;
        }
    }
    w.writeAll("\n\x00") catch return;
    const f = fopen(c.st.path, "a") orelse return;
    _ = fputs(@ptrCast(w.buffered().ptr), f);
    _ = fclose(f);
}

/// Appends a line to the file of a check or reload run.
fn appendLine(st: *State, comptime fmt: []const u8, args: anytype) void {
    if (!builtin.link_libc) return;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrintSentinel(&buf, fmt ++ "\n", args, 0) catch return;
    const f = fopen(st.path, "a") orelse return;
    _ = fputs(line.ptr, f);
    _ = fclose(f);
}

// ---------------------------------------------------------------------
// The reload run
//
// `LUS_JIT_AOT=reload:PATH` checks the loader on every function that
// either tier compiles. It compiles as check mode does, then overwrites
// every relocated word of the code and writes it again from the address
// that the loader of an executable finds for the relocation. The
// metadata of every optimized unit goes through the writer and the
// reader of the code section. The code then runs from what the loader
// produced. Each relocation that the loader cannot resolve appends a
// line to PATH.

/// The section that a reload run resolves its relocations against: one
/// with no records, whose string table follows the strings of the run.
pub fn reloadSection(g: *Global) ?*Section {
    const st = g.jit.aot orelse return null;
    if (st.mode != .reload) return null;
    const s = g.jit.aot_section orelse return null;
    while (s.strings.items.len < st.strings.items.len)
        s.strings.append(s.gpa, st.strings.items[s.strings.items.len]) catch return null;
    return s;
}

/// The number that a reload run gives a function it has not seen.
fn reloadId(g: *Global, p: *Proto) u32 {
    const st = g.jit.aot orelse return 0;
    if (st.mode != .reload) return 0;
    const s = g.jit.aot_section orelse return 0;
    st.last_id += 1;
    const id = st.last_id;
    g.jit.aot_ids.put(g.gpa, p, id) catch return 0;
    s.ids.put(s.gpa, id, p) catch {};
    return id;
}

/// Overwrites the relocated words of `buf` and writes them again from
/// the addresses that the loader finds.
fn relocateAgain(g: *Global, l: *Thread, s: *Section, buf: []u8, entries: []const reloc.Entry) void {
    const st = g.jit.aot.?;
    for (entries) |e| {
        if (e.at + e.form.size() > buf.len) {
            appendLine(st, "reload: relocation past the code at {d}", .{e.at});
            continue;
        }
        reloc.apply(buf, e, 0xDEAD_BEEF_0BAD_F00D);
        const addr = s.addressOf(l, e.r) orelse {
            appendLine(st, "reload: no address for {s} {d} {d} {d}", .{ @tagName(e.r.kind), e.r.a, e.r.b, e.r.c });
            continue;
        };
        reloc.apply(buf, e, addr);
    }
}

/// Relocates the baseline code of a function again in a reload run,
/// before it is installed.
pub fn reloadBaseline(l: *Thread, buf: []u8, entries: []const reloc.Entry) void {
    const s = reloadSection(l.g) orelse return;
    relocateAgain(l.g, l, s, buf, entries);
}

/// Relocates the code of an optimized unit again in a reload run, before
/// it is installed. The unit is reserved first, as the loader reserves
/// it, so that its code finds its record.
pub fn reloadUnitCode(l: *Thread, u: *opt.Unit, buf: []u8, entries: []const reloc.Entry) void {
    const s = reloadSection(l.g) orelse return;
    s.units.put(s.gpa, .{ .p = u.proto, .pc = u.entry_pc }, u) catch return;
    relocateAgain(l.g, l, s, buf, entries);
}

/// Passes the metadata of an optimized unit through the writer and the
/// reader of the code section, and gives the unit what the reader read.
pub fn reloadUnitMeta(l: *Thread, u: *opt.Unit) void {
    const g = l.g;
    const st = g.jit.aot orelse return;
    const s = reloadSection(g) orelse return;
    const gpa = g.gpa;
    var ctx = Context.init(gpa, g, st, u.proto);
    defer ctx.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var w: UnitWriter = .{ .g = g, .c = &ctx, .out = &body, .gpa = gpa };
    const ok = w.meta(u) catch return;
    if (!ok) {
        appendLine(st, "reload: metadata without a name in a unit at {d}", .{u.entry_pc});
        return;
    }
    // A reload section has no strings beyond those of the run.
    _ = reloadSection(g);
    var r: Reader = .{ .b = body.items, .at = 0 };
    var rd: UnitReader = .{ .s = s, .l = l, .r = &r };
    var m: opt.Unit = .{ .proto = u.proto, .entry_pc = u.entry_pc };
    rd.meta(&m) catch |e| {
        appendLine(st, "reload: the reader rejected a unit at {d} ({s})", .{ u.entry_pc, @errorName(e) });
        return;
    };
    freeMeta(gpa, u);
    u.frame_bytes = m.frame_bytes;
    u.direct = m.direct;
    u.total = m.total;
    u.chain_ratio = m.chain_ratio;
    u.sig = m.sig;
    u.ret_ty = m.ret_ty;
    u.writes = m.writes;
    u.extent = m.extent;
    u.sites = m.sites;
    u.snaps = m.snaps;
    u.frames = m.frames;
    u.entries = m.entries;
    u.virts = m.virts;
    u.vfields = m.vfields;
    u.protos = m.protos;
}

// ---------------------------------------------------------------------
// The code section

/// The version byte changes with the numbering of `routines`, which the
/// step routines follow.
const magic = "LUSAOT\x06\x00";

/// The flag of a section whose code takes the static form.
const flag_static: u32 = 1;

/// The magic, the hash seed, and the flags.
const header_len = magic.len + 12;

fn put32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn put64(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

/// The hash seed that a code section records, which the state of the
/// executable takes so that the node predictions of its code hold.
pub fn sectionSeed(bytes: []const u8) ?u64 {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    return std.mem.readInt(u64, bytes[magic.len..][0..8], .little);
}

/// Whether the code of the section `bytes` takes the static form.
pub fn sectionStatic(bytes: []const u8) bool {
    if (sectionSeed(bytes) == null) return false;
    return std.mem.readInt(u32, bytes[magic.len + 8 ..][0..4], .little) & flag_static != 0;
}

/// Where the linker put the code of a static section in the executable
/// (`spec/design/aot.md`, "The linker"). The runtime defines it zeroed,
/// and the linker gives it the addresses of the code and of the slots
/// when it links a static section into the image.
pub const Image = extern struct {
    code: usize = 0,
    slots: usize = 0,
};

export var lus_aot_image: Image = .{};

/// The image of the static section, or null when the executable holds
/// none. The load goes through a volatile pointer, since the linker
/// writes the variable after the compiler sees it.
pub fn image() ?Image {
    const img = @as(*const volatile Image, &lus_aot_image).*;
    return if (img.code == 0) null else img;
}

/// A function or a unit of a static section, as the linker lays the code
/// and the slots out: each code at a multiple of 16 bytes in one atom,
/// and one slot for each relocation in the order of the section.
pub const StaticItem = struct {
    /// The number of the function, or of the function of the unit.
    id: u32,
    /// The entry instruction of a unit, or `baseline_pc` for baseline
    /// code.
    pc: u32,
    code: []const u8,
    /// The relocations, 20 bytes each.
    relocs: []const u8,
    code_off: u64,
    slot_base: u32,
};

/// Walks the functions, then the units, of a static section.
pub const StaticIter = struct {
    r: Reader,
    funcs: u32,
    units: ?u32 = null,
    code_off: u64 = 0,
    slots: u32 = 0,

    pub fn init(bytes: []const u8) ?StaticIter {
        if (!sectionStatic(bytes)) return null;
        var r: Reader = .{ .b = bytes, .at = header_len };
        const nstr = r.u32_() orelse return null;
        for (0..nstr) |_| {
            const len = r.u32_() orelse return null;
            _ = r.take(len) orelse return null;
        }
        const n = r.u32_() orelse return null;
        return .{ .r = r, .funcs = n };
    }

    pub fn next(it: *StaticIter) ?StaticItem {
        var r = &it.r;
        var code: []const u8 = undefined;
        if (it.funcs > 0) {
            it.funcs -= 1;
            const id = r.u32_() orelse return null;
            const len = r.u32_() orelse return null;
            code = r.take(len) orelse return null;
            const count = r.u32_() orelse return null;
            _ = r.take(count * 4 + 12) orelse return null;
            const nrel = r.u32_() orelse return null;
            const relocs = r.take(nrel * 20) orelse return null;
            return it.item(id, baseline_pc, code, relocs, nrel);
        } else {
            if (it.units == null) it.units = r.u32_() orelse return null;
            if (it.units.? == 0) return null;
            it.units.? -= 1;
            const pid = r.u32_() orelse return null;
            const pc = r.u32_() orelse return null;
            const body_len = r.u32_() orelse return null;
            const end = r.at + body_len;
            const len = r.u32_() orelse return null;
            code = r.take(len) orelse return null;
            _ = r.take(7 * 4) orelse return null;
            const nrel = r.u32_() orelse return null;
            const relocs = r.take(nrel * 20) orelse return null;
            if (end > r.b.len) return null;
            r.at = end;
            return it.item(pid, pc, code, relocs, nrel);
        }
    }

    fn item(it: *StaticIter, id: u32, pc: u32, code: []const u8, relocs: []const u8, nrel: u32) StaticItem {
        it.code_off = std.mem.alignForward(u64, it.code_off, 16);
        const x: StaticItem = .{ .id = id, .pc = pc, .code = code, .relocs = relocs, .code_off = it.code_off, .slot_base = it.slots };
        it.code_off += code.len;
        it.slots += nrel;
        return x;
    }
};

/// Calls `f` with each string of the code section `bytes`: the paths of
/// the natives that its code calls and the characters of the strings it
/// interns. The linker keeps every builtin that such a path names.
pub fn sectionStrings(bytes: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) void) void {
    if (sectionSeed(bytes) == null) return;
    var pos: usize = header_len;
    if (pos + 4 > bytes.len) return;
    const n = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;
    for (0..n) |_| {
        if (pos + 4 > bytes.len) return;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (len > bytes.len - pos) return;
        f(ctx, bytes[pos..][0..len]);
        pos += len;
    }
}

/// Writes the code section of a training run to the path of its state:
/// the string table, then for every bundled function that has baseline
/// code with relocations, its number, its code, the offsets of its
/// instructions and entries, and its relocations.
pub fn writeTraining(g: *Global) void {
    const s = g.jit.aot orelse return;
    if (s.mode != .train) return;
    const gpa = s.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    writeSection(g, s, &out) catch return;
    const f = fopen(s.path, "wb") orelse return;
    _ = fwrite(out.items.ptr, 1, out.items.len, f);
    _ = fclose(f);
}

fn writeSection(g: *Global, s: *State, out: *std.ArrayList(u8)) !void {
    const gpa = s.gpa;
    try out.appendSlice(gpa, magic);
    try put64(out, gpa, g.seed);
    try put32(out, gpa, if (s.static) flag_static else 0);
    // The units come after the string table in the file, and add to it
    // while they are written, so they are written first.
    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(gpa);
    try writeUnits(g, s, &units);
    try put32(out, gpa, @intCast(s.strings.items.len));
    for (s.strings.items) |x| {
        try put32(out, gpa, @intCast(x.len));
        try out.appendSlice(gpa, x);
    }
    var n: u32 = 0;
    var it = s.records.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.*.jit_code != null) n += 1;
    }
    try put32(out, gpa, n);
    it = s.records.iterator();
    while (it.next()) |kv| {
        const p = kv.key_ptr.*;
        const code: *jit.Code = @ptrCast(@alignCast(p.jit_code orelse continue));
        const bytes = @as([*]const u8, @ptrFromInt(code.base))[0..code.size];
        try put32(out, gpa, idOf(g, p));
        try put32(out, gpa, @intCast(bytes.len));
        try out.appendSlice(gpa, bytes);
        try put32(out, gpa, @intCast(code.count));
        for (code.offs[0..code.count]) |o| try put32(out, gpa, o);
        try put32(out, gpa, @intCast(code.call_entry));
        try put32(out, gpa, @intCast(code.call_entry_plain));
        try put32(out, gpa, @intCast(code.tail_entry));
        try putRelocs(out, gpa, kv.value_ptr.*);
    }
    try out.appendSlice(gpa, units.items);
}

fn putRelocs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, entries: []const reloc.Entry) !void {
    try put32(out, gpa, @intCast(entries.len));
    for (entries) |e| {
        try put32(out, gpa, e.at);
        try out.appendSlice(gpa, &.{ @backingInt(e.form), @backingInt(e.r.kind), 0, 0 });
        try put32(out, gpa, e.r.a);
        try put32(out, gpa, e.r.b);
        try put32(out, gpa, e.r.c);
    }
}

/// Writes the optimized units of the training run: their count, then for
/// each the number of its function, its entry instruction, the length of
/// its record, and the record. A unit whose metadata names an object that
/// the loader cannot find again is left out, and its function keeps its
/// baseline code.
fn writeUnits(g: *Global, s: *State, out: *std.ArrayList(u8)) !void {
    const gpa = s.gpa;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var n: u32 = 0;
    const count_at = out.items.len;
    try put32(out, gpa, 0);
    var it = s.unit_records.iterator();
    var ctx: ?Context = null;
    defer if (ctx) |*c| c.deinit();
    while (it.next()) |kv| {
        const u = kv.key_ptr.*;
        if (u.retired or u.code.len == 0) continue;
        const pid = idOf(g, u.proto);
        if (pid == 0) continue;
        if (ctx == null) ctx = Context.init(gpa, g, s, u.proto);
        const c = &ctx.?;
        c.p = u.proto;
        body.clearRetainingCapacity();
        var w: UnitWriter = .{ .g = g, .c = c, .out = &body, .gpa = gpa };
        if (!try w.unit(u, kv.value_ptr.*)) continue;
        try put32(out, gpa, pid);
        try put32(out, gpa, u.entry_pc);
        try put32(out, gpa, @intCast(body.items.len));
        try out.appendSlice(gpa, body.items);
        n += 1;
    }
    std.mem.writeInt(u32, out.items[count_at..][0..4], n, .little);
}

/// Writes the record of one optimized unit, in the order that
/// `Section.finish` reads it.
const UnitWriter = struct {
    g: *Global,
    c: *Context,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn int(w: *UnitWriter, v: anytype) !void {
        const signed = @typeInfo(@TypeOf(v)).int.signedness == .signed;
        try put32(w.out, w.gpa, if (signed) @bitCast(@as(i32, @intCast(v))) else @intCast(v));
    }
    fn word(w: *UnitWriter, v: u32) !void {
        try put32(w.out, w.gpa, v);
    }
    fn byte(w: *UnitWriter, v: u8) !void {
        try w.out.append(w.gpa, v);
    }
    /// An offset into the code, or the largest word for an address that
    /// is not set.
    fn off(w: *UnitWriter, base: usize, addr: usize) !void {
        try w.word(if (addr == 0) std.math.maxInt(u32) else @intCast(addr - base));
    }
    /// A word that may hold the address of an object: a literal, or a
    /// relocation. False when the address has no name.
    fn ptr(w: *UnitWriter, v: u64, is_address: bool) !bool {
        if (!is_address) {
            try w.byte(0);
            try put64(w.out, w.gpa, v);
            return true;
        }
        switch (w.c.resolve(@intCast(v))) {
            .address => |r| {
                try w.byte(1);
                try w.byte(@backingInt(r.kind));
                try w.word(r.a);
                try w.word(r.b);
                try w.word(r.c);
                return true;
            },
            .literal, .unknown => return false,
        }
    }
    fn val(w: *UnitWriter, v: opt.Val) !bool {
        try w.byte(@backingInt(v.kind));
        try w.byte(@backingInt(v.ty));
        return w.ptr(v.bits, v.kind == .imm and v.ty.collectable());
    }
    fn proto(w: *UnitWriter, p: *Proto) !bool {
        const id = idOf(w.g, p);
        if (id == 0) return false;
        try w.word(id);
        return true;
    }

    fn unit(w: *UnitWriter, u: *opt.Unit, relocs: []const reloc.Entry) !bool {
        const base = @intFromPtr(u.code.ptr);
        try w.word(@intCast(u.code.len));
        try w.out.appendSlice(w.gpa, u.code);
        for ([_]usize{ u.entry, u.call_entry, u.tail_entry, u.direct_entry, u.root_entry, u.ret_a, u.ret_b }) |a| try w.off(base, a);
        // The relocations come before the metadata, so the linker finds
        // them without reading the metadata.
        try putRelocs(w.out, w.gpa, relocs);
        return try w.meta(u);
    }

    /// The metadata of a unit, which its exits read.
    fn meta(w: *UnitWriter, u: *opt.Unit) !bool {
        try w.int(u.frame_bytes);
        try w.byte(@intFromBool(u.direct));
        try w.int(u.total);
        try w.int(u.chain_ratio);
        for (u.sig) |t| try w.byte(@backingInt(t));
        try w.byte(@intFromBool(u.ret_ty != null));
        try w.byte(if (u.ret_ty) |t| @backingInt(t) else 0);
        try w.int(u.writes);
        try w.int(u.extent);
        try w.int(u.sites.len);
        for (u.sites) |x| {
            try w.int(x.snap);
            try w.int(x.slot);
            try w.int(x.nargs);
            try w.int(x.want);
            try w.int(x.ret_off);
            try w.int(x.callee_total);
            try w.int(x.callee_ratio);
        }
        try w.int(u.snaps.len);
        for (u.snaps) |x| {
            try w.int(x.frames);
            try w.int(x.nframes);
            try w.int(x.virts);
            try w.int(x.nvirts);
            try w.byte(@intFromBool(x.quiet));
            try w.byte(@intFromBool(x.after_call));
        }
        try w.int(u.frames.len);
        for (u.frames) |x| {
            if (!try w.proto(x.proto)) return false;
            if (!try w.val(x.closure)) return false;
            try w.int(x.off);
            try w.int(x.pc);
            try w.int(x.want);
            try w.byte(@intFromBool(x.tail));
            try w.int(x.entries);
            try w.int(x.count);
        }
        try w.int(u.entries.len);
        for (u.entries) |x| {
            try w.int(x.slot);
            if (!try w.val(x.val)) return false;
        }
        try w.int(u.virts.len);
        for (u.virts) |x| {
            try w.int(x.nc);
            if (!try w.val(x.mt)) return false;
            try w.int(x.fields);
            try w.int(x.count);
        }
        try w.int(u.vfields.len);
        for (u.vfields) |x| {
            if (!try w.ptr(x.key, true)) return false;
            try w.int(x.node);
            if (!try w.val(x.val)) return false;
        }
        try w.int(u.protos.len);
        for (u.protos) |x| if (!try w.proto(x)) return false;
        return true;
    }
};

/// A code section that an executable carries, read where it lies in the
/// bundle, and the functions numbered so far.
pub const Section = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    strings: std.ArrayList([]const u8) = .empty,
    /// The offset in `bytes` of the record of each function.
    records: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    ids: std.AutoHashMapUnmanaged(u32, *Proto) = .empty,
    /// The natives of this state by their paths in the global tables.
    natives: std.StringHashMapUnmanaged(usize) = .empty,
    natives_built: bool = false,
    installed: u32 = 0,
    /// The interned strings that relocations named so far, by their index
    /// in `strings`.
    interned: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    /// The optimized units of the section, in its order.
    unit_recs: std.ArrayList(UnitRec) = .empty,
    /// The units that are reserved, by their function and entry
    /// instruction. A reserved unit has its record and its block of code,
    /// and takes no calls until its code is installed.
    units: std.AutoHashMapUnmanaged(UnitKey, *opt.Unit) = .empty,
    /// For a static section that the linker put into the executable, the
    /// address of the code and of the first slot of each function and
    /// unit, by its function number and entry instruction. The runtime
    /// runs that code in place and writes the slots where the relocated
    /// form patches code.
    placed: std.AutoHashMapUnmanaged(PlaceKey, Placed) = .empty,

    const PlaceKey = struct { id: u32, pc: u32 };
    const Placed = struct { code: usize, slots: usize };

    const UnitRec = struct {
        pid: u32,
        pc: u32,
        at: usize,
        state: enum { waiting, reserved, done, dropped } = .waiting,
    };
    const UnitKey = struct { p: *Proto, pc: u32 };

    /// A section with no records, which a reload run resolves against.
    pub fn empty(gpa: std.mem.Allocator) ?*Section {
        const s = gpa.create(Section) catch return null;
        s.* = .{ .gpa = gpa, .bytes = &.{} };
        return s;
    }

    /// Forgets a unit that the tier frees.
    pub fn forgetUnit(s: *Section, u: *opt.Unit) void {
        const key: UnitKey = .{ .p = u.proto, .pc = u.entry_pc };
        if (s.units.get(key)) |x| if (x == u) {
            _ = s.units.remove(key);
        };
    }

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ?*Section {
        if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
        const s = gpa.create(Section) catch return null;
        s.* = .{ .gpa = gpa, .bytes = bytes };
        if (sectionStatic(bytes)) if (image()) |img| {
            var it = StaticIter.init(bytes) orelse return s.fail();
            while (it.next()) |x| s.placed.put(gpa, .{ .id = x.id, .pc = x.pc }, .{ .code = img.code + @as(usize, @intCast(x.code_off)), .slots = img.slots + 8 * @as(usize, x.slot_base) }) catch return s.fail();
        };
        var r: Reader = .{ .b = bytes, .at = header_len };
        const nstr = r.u32_() orelse return s.fail();
        for (0..nstr) |_| {
            const len = r.u32_() orelse return s.fail();
            const x = r.take(len) orelse return s.fail();
            s.strings.append(gpa, x) catch return s.fail();
        }
        const n = r.u32_() orelse return s.fail();
        for (0..n) |_| {
            const start = r.at;
            const id = r.u32_() orelse return s.fail();
            const len = r.u32_() orelse return s.fail();
            _ = r.take(len) orelse return s.fail();
            const count = r.u32_() orelse return s.fail();
            _ = r.take(count * 4 + 12) orelse return s.fail();
            const nrel = r.u32_() orelse return s.fail();
            _ = r.take(nrel * 20) orelse return s.fail();
            s.records.put(gpa, id, start) catch return s.fail();
        }
        const nu = r.u32_() orelse return s.fail();
        for (0..nu) |_| {
            const pid = r.u32_() orelse return s.fail();
            const pc = r.u32_() orelse return s.fail();
            const len = r.u32_() orelse return s.fail();
            const at = r.at;
            _ = r.take(len) orelse return s.fail();
            s.unit_recs.append(gpa, .{ .pid = pid, .pc = pc, .at = at }) catch return s.fail();
        }
        return s;
    }

    fn fail(s: *Section) ?*Section {
        s.destroy();
        return null;
    }

    /// Prints how many functions and units the section installed, and
    /// how many of them run in place from the executable.
    pub fn report(s: *const Section) void {
        var units: u32 = 0;
        for (s.unit_recs.items) |rec| units += @intFromBool(rec.state == .done);
        // The units of loops that a hot loop entered. A unit at the first
        // instruction takes its calls straight from native code.
        var loops: u32 = 0;
        var entered: u32 = 0;
        var it = s.units.valueIterator();
        while (it.next()) |u| if (u.*.entry_pc != 0 and u.*.entry != 0) {
            loops += 1;
            entered += @intFromBool(u.*.entered);
        };
        std.debug.print("aot: {d} functions and {d} units installed, {d} placed in the executable, {d} of {d} loop units entered\n", .{ s.installed, units, s.placed.count(), entered, loops });
    }

    /// Frees the section. The units it installed belong to their
    /// functions, and the executable memory to the arena, so only the
    /// records of units that never installed are freed here.
    pub fn destroy(s: *Section) void {
        var it_u = s.units.valueIterator();
        while (it_u.next()) |u| if (u.*.entry == 0) s.gpa.destroy(u.*);
        s.units.deinit(s.gpa);
        s.unit_recs.deinit(s.gpa);
        s.interned.deinit(s.gpa);
        s.strings.deinit(s.gpa);
        s.records.deinit(s.gpa);
        s.ids.deinit(s.gpa);
        s.placed.deinit(s.gpa);
        var it = s.natives.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.natives.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn buildNatives(s: *Section, g: *Global) void {
        s.natives_built = true;
        if (g.globals.tag != .table) return;
        s.walk(g.globals.as(object.Table), "");
    }

    fn walk(s: *Section, t: *object.Table, prefix: []const u8) void {
        var key: Value = .nil;
        while (table.next(t, key) catch null) |kv| : (key = kv.key) {
            if (kv.key.tag != .string) continue;
            const name = kv.key.as(object.String).bytes();
            switch (kv.val.tag) {
                .native => {
                    const path = std.fmt.allocPrint(s.gpa, "{s}{s}", .{ prefix, name }) catch continue;
                    if (s.natives.contains(path)) {
                        s.gpa.free(path);
                        continue;
                    }
                    s.natives.put(s.gpa, path, @intFromPtr(kv.val.as(state.Native).func)) catch s.gpa.free(path);
                },
                .table => if (prefix.len == 0) {
                    var pbuf: [256]u8 = undefined;
                    const p2 = std.fmt.bufPrint(&pbuf, "{s}.", .{name}) catch continue;
                    s.walk(kv.val.as(object.Table), p2);
                },
                else => {},
            }
        }
    }

    /// The address in this process that a relocation names, or null when
    /// the object it names is not here.
    fn addressOf(s: *Section, l: *Thread, r: reloc.Reloc) ?usize {
        const g = l.g;
        return switch (r.kind) {
            .literal => null,
            .routine => routineAddr(r.a),
            .global => @intFromPtr(g) + r.a,
            .global_value => @as(*const usize, @ptrFromInt(@intFromPtr(g) + r.a)).*,
            .proto => @intFromPtr(s.ids.get(r.a) orelse return null),
            .proto_field => @intFromPtr(s.ids.get(r.a) orelse return null) + r.b,
            .proto_const => blk: {
                const p = s.ids.get(r.a) orelse return null;
                if (r.b >= p.constants.len) return null;
                break :blk @intFromPtr(&p.constants[r.b]);
            },
            .ic => blk: {
                const p = s.ids.get(r.a) orelse return null;
                if (r.b >= p.ic.len) return null;
                break :blk @intFromPtr(&p.ic[r.b]) + r.c;
            },
            .const_obj => blk: {
                const p = s.ids.get(r.a) orelse return null;
                if (r.b >= p.constants.len or !p.constants[r.b].tag.isCollectable()) return null;
                break :blk @intCast(p.constants[r.b].payload);
            },
            .native => blk: {
                if (!s.natives_built) s.buildNatives(g);
                if (r.a >= s.strings.items.len) return null;
                break :blk s.natives.get(s.strings.items[r.a]);
            },
            .interned => blk: {
                if (s.interned.get(r.a)) |a| break :blk a;
                if (r.a >= s.strings.items.len) return null;
                const str = state.newStringIn(g, s.strings.items[r.a]) catch return null;
                g.fixed.append(g.gpa, &str.hdr) catch return null;
                s.interned.put(s.gpa, r.a, @intFromPtr(str)) catch {};
                break :blk @intFromPtr(str);
            },
            .unit => blk: {
                const p = s.ids.get(r.a) orelse return null;
                const u = s.units.get(.{ .p = p, .pc = r.b }) orelse return null;
                break :blk @intFromPtr(u) + r.c;
            },
            .code => blk: {
                const p = s.ids.get(r.a) orelse return null;
                if (r.b == baseline_pc) {
                    const code: *jit.Code = @ptrCast(@alignCast(p.jit_code orelse return null));
                    if (r.c >= code.size) return null;
                    break :blk code.base + r.c;
                }
                const u = s.units.get(.{ .p = p, .pc = r.b }) orelse return null;
                if (r.c >= u.code.len) return null;
                break :blk @intFromPtr(u.code.ptr) + r.c;
            },
        };
    }

    const Outcome = enum { done, wait, drop };

    /// Applies the relocations that `r` reads to `buf`, or for code in
    /// place writes the slots from `slots` on.
    fn applyRelocs(s: *Section, l: *Thread, r: *Reader, buf: []u8, slots: ?usize) Outcome {
        const nrel = r.u32_() orelse return .drop;
        for (0..nrel) |k| {
            const e_at = r.u32_() orelse return .drop;
            const head = r.take(4) orelse return .drop;
            if (head[0] >= std.enums.values(reloc.Form).len or head[1] >= std.enums.values(reloc.Kind).len) return .drop;
            const rr: reloc.Reloc = .{ .kind = @fromBackingInt(@intCast(head[1])), .a = r.u32_() orelse return .drop, .b = r.u32_() orelse return .drop, .c = r.u32_() orelse return .drop };
            const form: reloc.Form = @fromBackingInt(@intCast(head[0]));
            if (slots) |base| {
                if (form != .slot) {
                    // The static form records only slots, so another form
                    // means an emitter left the static path.
                    if (l.g.jit.aot_report) std.debug.print("aot: code in place dropped for a relocation of form {s}\n", .{@tagName(form)});
                    return .drop;
                }
                const addr = s.addressOf(l, rr) orelse return .wait;
                @as(*usize, @ptrFromInt(base + 8 * k)).* = addr;
                continue;
            }
            if (e_at + form.size() > buf.len) return .drop;
            if (form == .slot and reloc.slotTarget(buf, e_at) == null) return .drop;
            const addr = s.addressOf(l, rr) orelse return .wait;
            reloc.apply(buf, .{ .at = e_at, .form = form, .r = rr }, addr);
        }
        return .done;
    }

    /// Forgets a function that the collector frees, with the units the
    /// section reserved for it.
    pub fn forgetProto(s: *Section, g: *Global, p: *Proto, id: u32) void {
        if (id != 0) if (s.ids.get(id)) |q| if (q == p) {
            _ = s.ids.remove(id);
        };
        var again = true;
        while (again) {
            again = false;
            var it = s.units.iterator();
            while (it.next()) |kv| {
                if (kv.key_ptr.p != p) continue;
                const u = kv.value_ptr.*;
                // An installed unit belongs to the function, which frees it.
                if (u.entry == 0) {
                    if (u.code.len != 0) g.jit.arena.release(g.gpa, u.code);
                    s.gpa.destroy(u);
                }
                _ = s.units.remove(kv.key_ptr.*);
                again = true;
                break;
            }
        }
    }

    /// Reserves and installs the optimized units of the functions
    /// numbered so far. A unit is reserved first, so that units which
    /// call each other find each other, and installed when every object
    /// that its relocations and its metadata name is here.
    fn installUnits(s: *Section, l: *Thread) void {
        const g = l.g;
        for (s.unit_recs.items) |*rec| {
            if (rec.state != .waiting) continue;
            const p = s.ids.get(rec.pid) orelse continue;
            if (p.jit_code == null or s.units.contains(.{ .p = p, .pc = rec.pc })) {
                rec.state = .dropped;
                continue;
            }
            var r: Reader = .{ .b = s.bytes, .at = rec.at };
            const len = r.u32_() orelse {
                rec.state = .dropped;
                continue;
            };
            const u = s.gpa.create(opt.Unit) catch continue;
            u.* = .{ .proto = p, .entry_pc = rec.pc };
            if (s.placed.get(.{ .id = rec.pid, .pc = rec.pc })) |pl| {
                u.code = @as([*]u8, @ptrFromInt(pl.code))[0..len];
            } else u.code = g.jit.arena.alloc(g.gpa, len) orelse {
                s.gpa.destroy(u);
                continue;
            };
            s.units.put(s.gpa, .{ .p = p, .pc = rec.pc }, u) catch {
                g.jit.arena.release(g.gpa, u.code);
                s.gpa.destroy(u);
                continue;
            };
            rec.state = .reserved;
        }
        for (s.unit_recs.items) |*rec| {
            if (rec.state != .reserved) continue;
            const p = s.ids.get(rec.pid) orelse continue;
            const u = s.units.get(.{ .p = p, .pc = rec.pc }) orelse continue;
            switch (s.finish(l, rec, u)) {
                .done => rec.state = .done,
                .wait => {},
                .drop => rec.state = .dropped,
            }
        }
    }

    /// Reads the record of a reserved unit, installs its code, and gives
    /// it to its function.
    fn finish(s: *Section, l: *Thread, rec: *UnitRec, u: *opt.Unit) Outcome {
        const g = l.g;
        const gpa = g.gpa;
        const p = u.proto;
        var r: Reader = .{ .b = s.bytes, .at = rec.at };
        var rd: UnitReader = .{ .s = s, .l = l, .r = &r };
        const len = r.u32_() orelse return .drop;
        const src = r.take(len) orelse return .drop;
        var offs: [7]u32 = undefined;
        for (&offs) |*o| o.* = r.u32_() orelse return .drop;
        for (offs) |o| if (o != std.math.maxInt(u32) and o >= len) return .drop;
        // The relocations, which the metadata follows.
        var rr: Reader = .{ .b = s.bytes, .at = r.at };
        const nrel = r.u32_() orelse return .drop;
        _ = r.take(nrel * 20) orelse return .drop;
        var m: opt.Unit = .{ .proto = p, .entry_pc = rec.pc };
        rd.meta(&m) catch |e| return switch (e) {
            error.Wait => .wait,
            error.Drop => .drop,
        };
        if (s.placed.get(.{ .id = rec.pid, .pc = rec.pc })) |pl| {
            var none: [0]u8 = .{};
            switch (s.applyRelocs(l, &rr, &none, pl.slots)) {
                .done => {},
                else => |o| {
                    freeMeta(gpa, &m);
                    return o;
                },
            }
        } else {
            const buf = gpa.dupe(u8, src) catch return .wait;
            defer gpa.free(buf);
            switch (s.applyRelocs(l, &rr, buf, null)) {
                .done => {},
                else => |o| {
                    freeMeta(gpa, &m);
                    return o;
                },
            }
            mem.install(u.code, buf);
        }
        const base = @intFromPtr(u.code.ptr);
        const at = struct {
            fn f(b: usize, o: u32) usize {
                return if (o == std.math.maxInt(u32)) 0 else b + o;
            }
        }.f;
        m.code = u.code;
        m.entry = at(base, offs[0]);
        m.call_entry = at(base, offs[1]);
        m.tail_entry = at(base, offs[2]);
        m.direct_entry = at(base, offs[3]);
        m.root_entry = at(base, offs[4]);
        m.ret_a = at(base, offs[5]);
        m.ret_b = at(base, offs[6]);
        if (m.entry == 0) {
            freeMeta(gpa, &m);
            return .drop;
        }
        const info = opt.infoOf(g, p) orelse {
            freeMeta(gpa, &m);
            return .wait;
        };
        u.* = m;
        if (u.sites.len != 0) g.jit.callers.append(gpa, u) catch {};
        info.units.append(gpa, u) catch {
            u.entry = 0;
            freeMeta(gpa, u);
            return .drop;
        };
        info.compiles += 1;
        u.cell = 1;
        if (rec.pc == 0) {
            if (u.call_entry != 0) p.jit_entry = u.call_entry;
            if (u.tail_entry != 0) p.jit_tail = u.tail_entry;
        }
        g.jit.optimized += 1;
        return .done;
    }

    /// Installs the code of `p` from the section, when the section has it
    /// and every object its relocations name is here.
    fn install(s: *Section, l: *Thread, p: *Proto) void {
        const at = s.records.get(idOf(l.g, p)) orelse return;
        const g = l.g;
        const gpa = g.gpa;
        var r: Reader = .{ .b = s.bytes, .at = at + 4 };
        const len = r.u32_().?;
        const src = r.take(len).?;
        const count = r.u32_().?;
        if (count != p.code.len + 1) return;
        const offs_bytes = r.take(count * 4).?;
        const call_entry = r.u32_().?;
        const call_entry_plain = r.u32_().?;
        const tail_entry = r.u32_().?;
        for ([_]u32{ call_entry, call_entry_plain, tail_entry }) |o| if (o > len) return;
        for (0..count) |i| if (std.mem.readInt(u32, offs_bytes[i * 4 ..][0..4], .little) > len) return;
        const placed = s.placed.get(.{ .id = idOf(g, p), .pc = baseline_pc });
        const buf = gpa.dupe(u8, src) catch return;
        defer gpa.free(buf);
        if (s.applyRelocs(l, &r, buf, if (placed) |pl| pl.slots else null) != .done) return;
        const offs = gpa.alloc(u32, count) catch return;
        for (offs, 0..) |*o, i| o.* = std.mem.readInt(u32, offs_bytes[i * 4 ..][0..4], .little);
        const code = gpa.create(jit.Code) catch {
            gpa.free(offs);
            return;
        };
        // Code in place runs from the executable. Other code goes to the
        // arena.
        const block = if (placed) |pl| @as([*]u8, @ptrFromInt(pl.code))[0..buf.len] else blk: {
            const b = g.jit.arena.alloc(gpa, buf.len) orelse {
                gpa.destroy(code);
                gpa.free(offs);
                return;
            };
            mem.install(b, buf);
            break :blk b;
        };
        code.* = .{
            .base = @intFromPtr(block.ptr),
            .offs = offs.ptr,
            .size = block.len,
            .count = offs.len,
            .call_entry = call_entry,
            .call_entry_plain = call_entry_plain,
            .tail_entry = tail_entry,
        };
        // The calls and the loops of the baseline code count down to the
        // optimizing tier from here, as they do for code compiled at run
        // time. A counter left at zero would wrap, and no installed unit
        // would ever be entered.
        p.opt_hot = g.jit.opt_threshold;
        p.jit_code = code;
        p.jit_entry = if (call_entry != 0) code.base + call_entry else 0;
        p.jit_tail = if (tail_entry != 0) code.base + tail_entry else 0;
        p.call.plain = false;
        p.jit_state = .compiled;
        p.hot = 1;
        g.jit.live += 1;
        s.installed += 1;
    }
};

const Reader = struct {
    b: []const u8,
    at: usize,

    fn u32_(r: *Reader) ?u32 {
        if (r.at + 4 > r.b.len) return null;
        const v = std.mem.readInt(u32, r.b[r.at..][0..4], .little);
        r.at += 4;
        return v;
    }
    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.at + n > r.b.len) return null;
        const x = r.b[r.at .. r.at + n];
        r.at += n;
        return x;
    }
};

fn freeMeta(gpa: std.mem.Allocator, u: *opt.Unit) void {
    gpa.free(u.snaps);
    gpa.free(u.frames);
    gpa.free(u.entries);
    gpa.free(u.virts);
    gpa.free(u.vfields);
    gpa.free(u.protos);
    gpa.free(u.sites);
    u.snaps = &.{};
    u.frames = &.{};
    u.entries = &.{};
    u.virts = &.{};
    u.vfields = &.{};
    u.protos = &.{};
    u.sites = &.{};
}

/// Reads the record of a unit that `UnitWriter` wrote, after its code and
/// its entry offsets.
const UnitReader = struct {
    s: *Section,
    l: *Thread,
    r: *Reader,

    const Error = error{ Wait, Drop };

    fn word(rd: *UnitReader) Error!u32 {
        return rd.r.u32_() orelse error.Drop;
    }
    fn int(rd: *UnitReader) Error!i32 {
        return @bitCast(try rd.word());
    }
    fn byte(rd: *UnitReader) Error!u8 {
        const b = rd.r.take(1) orelse return error.Drop;
        return b[0];
    }
    fn flag(rd: *UnitReader) Error!bool {
        return try rd.byte() != 0;
    }
    fn count(rd: *UnitReader) Error!usize {
        const n = try rd.word();
        // Every element takes at least four bytes.
        if (rd.r.at + @as(usize, n) * 4 > rd.r.b.len) return error.Drop;
        return n;
    }
    fn ty(rd: *UnitReader) Error!@import("opt/ir.zig").Ty {
        const b = try rd.byte();
        return std.enums.fromInt(@import("opt/ir.zig").Ty, b) orelse error.Drop;
    }
    fn ptr(rd: *UnitReader) Error!u64 {
        switch (try rd.byte()) {
            0 => {
                const b = rd.r.take(8) orelse return error.Drop;
                return std.mem.readInt(u64, b[0..8], .little);
            },
            1 => {
                const k = try rd.byte();
                if (k >= std.enums.values(reloc.Kind).len) return error.Drop;
                const rr: reloc.Reloc = .{ .kind = @fromBackingInt(k), .a = try rd.word(), .b = try rd.word(), .c = try rd.word() };
                return rd.s.addressOf(rd.l, rr) orelse error.Wait;
            },
            else => return error.Drop,
        }
    }
    fn val(rd: *UnitReader) Error!opt.Val {
        const k = try rd.byte();
        const kind = std.enums.fromInt(opt.Val.Kind, k) orelse return error.Drop;
        const t = try rd.ty();
        return .{ .kind = kind, .ty = t, .bits = try rd.ptr() };
    }
    fn proto(rd: *UnitReader) Error!*Proto {
        return rd.s.ids.get(try rd.word()) orelse error.Wait;
    }

    fn meta(rd: *UnitReader, m: *opt.Unit) Error!void {
        const gpa = rd.l.g.gpa;
        errdefer freeMeta(gpa, m);
        m.frame_bytes = try rd.word();
        m.direct = try rd.flag();
        m.total = try rd.word();
        m.chain_ratio = try rd.word();
        for (&m.sig) |*t| t.* = try rd.ty();
        const has_ret = try rd.flag();
        const ret = try rd.byte();
        m.ret_ty = if (has_ret) std.enums.fromInt(@import("opt/ir.zig").Ty, ret) orelse return error.Drop else null;
        m.writes = try rd.word();
        m.extent = try rd.word();
        m.sites = gpa.alloc(@import("opt/ir.zig").Site, try rd.count()) catch return error.Wait;
        for (m.sites) |*x| x.* = .{ .snap = try rd.word(), .slot = try rd.word(), .nargs = try rd.word(), .want = try rd.int(), .ret_off = try rd.word(), .callee_total = try rd.word(), .callee_ratio = try rd.word() };
        m.snaps = gpa.alloc(@import("opt/ir.zig").Snap, try rd.count()) catch return error.Wait;
        for (m.snaps) |*x| x.* = .{ .frames = try rd.word(), .nframes = try rd.word(), .virts = try rd.word(), .nvirts = try rd.word(), .quiet = try rd.flag(), .after_call = try rd.flag() };
        m.frames = gpa.alloc(opt.FrameMeta, try rd.count()) catch return error.Wait;
        for (m.frames) |*x| x.* = .{ .proto = try rd.proto(), .closure = try rd.val(), .off = try rd.word(), .pc = try rd.word(), .want = try rd.int(), .tail = try rd.flag(), .entries = try rd.word(), .count = try rd.word() };
        m.entries = gpa.alloc(opt.Entry, try rd.count()) catch return error.Wait;
        for (m.entries) |*x| x.* = .{ .slot = try rd.word(), .val = try rd.val() };
        m.virts = gpa.alloc(opt.VirtMeta, try rd.count()) catch return error.Wait;
        for (m.virts) |*x| x.* = .{ .nc = try rd.word(), .mt = try rd.val(), .fields = try rd.word(), .count = try rd.word() };
        m.vfields = gpa.alloc(opt.VFieldMeta, try rd.count()) catch return error.Wait;
        for (m.vfields) |*x| x.* = .{ .key = @intCast(try rd.ptr()), .node = try rd.word(), .val = try rd.val() };
        m.protos = gpa.alloc(*Proto, try rd.count()) catch return error.Wait;
        for (m.protos) |*x| x.* = try rd.proto();
        try rd.check(m);
    }

    /// Checks that every index of the metadata stays inside the arrays
    /// it indexes, as the exits assume.
    fn check(rd: *UnitReader, m: *const opt.Unit) Error!void {
        _ = rd;
        for (m.sites) |x| if (x.snap >= m.snaps.len) return error.Drop;
        for (m.snaps) |x| {
            if (@as(u64, x.frames) + x.nframes > m.frames.len) return error.Drop;
            if (@as(u64, x.virts) + x.nvirts > m.virts.len) return error.Drop;
        }
        for (m.frames) |x| if (@as(u64, x.entries) + x.count > m.entries.len) return error.Drop;
        for (m.virts) |x| if (@as(u64, x.fields) + x.count > m.vfields.len) return error.Drop;
    }
};

// ---------------------------------------------------------------------
// Bundled modules

/// The number of a bundled function: the bundled module, plus one, in the
/// high 12 bits, and the place of the function in a preorder walk of the
/// functions of the module in the low 20. Zero for a function outside the
/// bundle.
pub fn idOf(g: *Global, p: *Proto) u32 {
    return g.jit.aot_ids.get(p) orelse reloadId(g, p);
}

/// Numbers the functions of a bundled module, which is module `index` of
/// the bundle, in a preorder walk from its main function, and installs
/// their code when the executable carries a code section.
pub fn moduleLoaded(l: *Thread, main: *Proto, index: usize) void {
    var k: u32 = 0;
    number(l, main, @intCast(index + 1), &k);
    // Every function of the module has its number before any installs,
    // since the code of one may name another.
    if (l.g.jit.aot_section) |s| if (jit.enabled and !jit.is_wasm) {
        // The settings of the environment, such as a refusal of
        // executable memory, hold before any code installs.
        jit.ensureSetup(l.g);
        installTree(l, s, main);
        if (comptime jit.has_opt) s.installUnits(l);
    };
}

fn number(l: *Thread, p: *Proto, module: u32, k: *u32) void {
    const id = module << 20 | k.*;
    k.* += 1;
    l.g.jit.aot_ids.put(l.g.gpa, p, id) catch return;
    if (l.g.jit.aot_section) |s| {
        const old = s.ids.fetchPut(s.gpa, id, p) catch null;
        // A module that loads again installs its units again.
        if (old) |kv| if (kv.value != p) for (s.unit_recs.items) |*rec| {
            if (rec.pid == id) rec.state = .waiting;
        };
    }
    for (p.protos) |child| number(l, child, module, k);
}

fn installTree(l: *Thread, s: *Section, p: *Proto) void {
    if (p.jit_code == null) s.install(l, p);
    for (p.protos) |child| installTree(l, s, child);
}

test "every routine of the optimizing tier has a number" {
    inline for (comptime std.meta.declarations(opt.rt)) |name| {
        const f = @field(opt.rt, name);
        if (@typeInfo(@TypeOf(f)) == .@"fn") {
            if (routineId(@intFromPtr(&f)) == null) {
                std.debug.print("opt.rt.{s} is missing from aot.routines\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "every helper that the emitters call by address has a number" {
    const sources = [_][]const u8{ @embedFile("emit.zig"), @embedFile("opt/codegen.zig") };
    inline for (comptime std.meta.declarations(helpers)) |name| {
        const f = @field(helpers, name);
        if (@typeInfo(@TypeOf(f)) == .@"fn") {
            for (sources) |src| {
                if (namesHelper(src, name) and routineId(@intFromPtr(&f)) == null) {
                    std.debug.print("helpers.{s} is missing from aot.routines\n", .{name});
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

/// Whether `src` takes the address of `helpers.name`.
fn namesHelper(src: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, "&helpers.")) |i| {
        const rest = src[i + "&helpers.".len ..];
        pos = i + 1;
        if (!std.mem.startsWith(u8, rest, name)) continue;
        if (rest.len == name.len) return true;
        const c = rest[name.len];
        if (!std.ascii.isAlphanumeric(c) and c != '_') return true;
    }
    return false;
}
