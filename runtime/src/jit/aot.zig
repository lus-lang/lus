//! The resolver of addresses for code compiled ahead of time
//! (`spec/design/aot.md`). An assembler that compiles ahead of time asks
//! it what each wide immediate is: an address that the loader of an
//! executable can find again, a literal, or an address of something the
//! loader cannot find.
//!
//! `LUS_JIT_AOT=check:PATH` compiles every function of a state in the form
//! of code compiled ahead of time, with real addresses in its relocated
//! words, and runs it. Each address that the resolver cannot name appends
//! a line to the file at PATH. The conformance suite under that setting
//! checks both that the patchable forms run and that every address the
//! code generators write has a relocation.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const gc = @import("../vm/gc.zig");
const heap = @import("../vm/heap.zig");
const value = @import("../vm/value.zig");
const reloc = @import("reloc.zig");
const helpers = @import("helpers.zig");
const jit = @import("jit.zig");
const opt = @import("opt/opt.zig");

const Thread = state.Thread;
const Global = state.Global;
const Proto = object.Proto;

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
};

/// The number of the routine at `addr`, or null.
pub fn routineId(addr: usize) ?u32 {
    for (routines, 0..) |r, i| if (@intFromPtr(r) == addr) return @intCast(i);
    for (helpers.steps, 0..) |s, i| if (@intFromPtr(s) == addr) return @intCast(routines.len + i);
    return null;
}

/// What the resolver knows about one function: where it is, its
/// constants, and its inline cache entries.
const ProtoRange = struct {
    p: *Proto,
    id: u32,
};

const StringRef = struct { proto: u32, index: u32 };

/// The state of one compilation ahead of time. The index of the heap is
/// built when the first wide immediate needs it.
pub const Context = struct {
    gpa: std.mem.Allocator,
    g: *Global,
    p: *Proto,
    /// The unit that the optimizing tier compiles, when it does.
    unit: ?*opt.Unit = null,
    unit_id: u32 = 0,
    built: bool = false,
    protos: std.ArrayList(ProtoRange) = .empty,
    strings: std.AutoHashMapUnmanaged(usize, StringRef) = .empty,
    natives: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    native_count: u32 = 0,
    /// The interned strings that the code names by their characters.
    interned: std.ArrayList(*object.String) = .empty,
    /// The first addresses that the resolver could not name, for the
    /// report.
    unknown: [4]usize = @splat(0),
    unknown_len: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, g: *Global, p: *Proto) Context {
        return .{ .gpa = gpa, .g = g, .p = p };
    }

    pub fn deinit(c: *Context) void {
        c.protos.deinit(c.gpa);
        c.strings.deinit(c.gpa);
        c.natives.deinit(c.gpa);
        c.interned.deinit(c.gpa);
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
                switch (h.tag) {
                    .proto => {
                        const p: *Proto = @ptrCast(@alignCast(h));
                        const id: u32 = @intCast(cc.protos.items.len);
                        cc.protos.append(cc.gpa, .{ .p = p, .id = id }) catch return;
                        for (p.constants, 0..) |k, i| {
                            if (!k.tag.isCollectable()) continue;
                            cc.strings.put(cc.gpa, @intCast(k.payload), .{ .proto = id, .index = @intCast(i) }) catch return;
                        }
                    },
                    .native => {
                        const n: *state.Native = @ptrCast(@alignCast(h));
                        cc.natives.put(cc.gpa, @intFromPtr(n.func), cc.native_count) catch return;
                        cc.native_count += 1;
                    },
                    else => {},
                }
            }
        }.f);
    }

    /// Decides what the wide immediate `v` is.
    pub fn resolve(c: *Context, v: usize) reloc.Resolution {
        if (routineId(v)) |id| return .{ .address = .{ .kind = .routine, .a = id } };
        const g = @intFromPtr(c.g);
        if (v >= g and v < g + @sizeOf(Global)) return .{ .address = .{ .kind = .global, .a = @intCast(v - g) } };
        if (c.unit) |u| {
            const lo = @intFromPtr(u);
            if (v >= lo and v < lo + @sizeOf(opt.Unit)) return .{ .address = .{ .kind = .unit, .a = c.idOf(c.p), .b = c.unit_id, .c = @intCast(v - lo) } };
        }
        if (!c.built) c.build();
        for (c.protos.items) |r| {
            const p = r.p;
            const lo = @intFromPtr(p);
            if (v >= lo and v < lo + @sizeOf(Proto)) return .{ .address = .{ .kind = .proto_field, .a = r.id, .b = @intCast(v - lo) } };
            if (p.constants.len > 0) {
                const k0 = @intFromPtr(p.constants.ptr);
                if (v >= k0 and v < k0 + p.constants.len * @sizeOf(value.Value) and (v - k0) % @sizeOf(value.Value) == 0)
                    return .{ .address = .{ .kind = .proto_const, .a = r.id, .b = @intCast((v - k0) / @sizeOf(value.Value)) } };
            }
            if (p.ic.len > 0) {
                const c0 = @intFromPtr(p.ic.ptr);
                const size = @sizeOf(@TypeOf(p.ic[0]));
                if (v >= c0 and v < c0 + p.ic.len * size)
                    return .{ .address = .{ .kind = .ic, .a = r.id, .b = @intCast((v - c0) / size), .c = @intCast((v - c0) % size) } };
            }
        }
        if (c.strings.get(v)) |s| return .{ .address = .{ .kind = .const_obj, .a = s.proto, .b = s.index } };
        // A word of the global state that holds the address.
        const words: [*]const usize = @ptrCast(@alignCast(c.g));
        for (words[0 .. @sizeOf(Global) / @sizeOf(usize)], 0..) |w, i| {
            if (w == v) return .{ .address = .{ .kind = .global_value, .a = @intCast(i * @sizeOf(usize)) } };
        }
        if (c.natives.get(v)) |n| return .{ .address = .{ .kind = .native, .a = n } };
        if (inHeap(c.g, v)) if (c.internedString(v)) |i| return .{ .address = .{ .kind = .interned, .a = i } };
        if (inHeap(c.g, v) or inImage(v)) {
            if (c.unknown_len < c.unknown.len) c.unknown[c.unknown_len] = v;
            c.unknown_len += 1;
            return .unknown;
        }
        return .literal;
    }

    /// The index in the string table of the interned string at `v`, which
    /// is added when it is new, or null when `v` holds no string. The
    /// check reads the object only after the heap walk finds it there.
    fn internedString(c: *Context, v: usize) ?u32 {
        const h = heapObjectOf(c.g, v) orelse return null;
        if (h.tag != .string or @intFromPtr(h) != v) return null;
        const str: *object.String = @ptrCast(@alignCast(h));
        for (c.interned.items, 0..) |x, i| if (x == str) return @intCast(i);
        c.interned.append(c.gpa, str) catch return null;
        return @intCast(c.interned.items.len - 1);
    }

    fn idOf(c: *Context, p: *Proto) u32 {
        if (!c.built) c.build();
        for (c.protos.items) |r| if (r.p == p) return r.id;
        return 0;
    }
};

/// Whether `v` points into a page of the collected heap.
fn inHeap(g: *Global, v: usize) bool {
    var seg = g.heap.segments;
    while (seg) |s| : (seg = s.next) {
        const lo = @intFromPtr(s);
        if (v >= lo and v < lo + heap.segment_size) return true;
    }
    return false;
}

extern "c" fn dladdr(addr: *const anyopaque, info: *DlInfo) c_int;
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
    if (comptime !has_dladdr) return false;
    // Every address of a user process lies below 2^48.
    if (v < 4096 or v >> 48 != 0) return false;
    var own: DlInfo = undefined;
    if (dladdr(routines[0], &own) == 0) return false;
    var info: DlInfo = undefined;
    return dladdr(@ptrFromInt(v), &info) != 0 and info.fbase == own.fbase;
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fputs(s: [*:0]const u8, f: *anyopaque) c_int;
extern "c" fn fclose(f: *anyopaque) c_int;

/// Where `LUS_JIT_AOT=check:PATH` writes the addresses that the resolver
/// could not name, one line each, with what each points into.
pub fn report(c: *Context, unresolved: u32) void {
    if (!builtin.link_libc) return;
    const path = c.g.jit.aot_log orelse return;
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
            if (h.tag == .string) {
                const str: *object.String = @ptrCast(@alignCast(h));
                const b = str.bytes();
                w.print("\"{s}\"", .{b[0..@min(b.len, 24)]}) catch return;
            }
        } else {
            var name: []const u8 = "?";
            if (comptime has_dladdr) {
                var info: DlInfo = undefined;
                if (dladdr(@ptrFromInt(v), &info) != 0 and info.sname != null) name = std.mem.span(info.sname.?);
            }
            w.print(" image {s}", .{name}) catch return;
        }
    }
    w.writeAll("\n\x00") catch return;
    const f = fopen(path, "a") orelse return;
    _ = fputs(@ptrCast(w.buffered().ptr), f);
    _ = fclose(f);
}

/// The object of the collected heap whose cell holds `v`, found by a
/// walk of the heap, which only the report pays for.
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
