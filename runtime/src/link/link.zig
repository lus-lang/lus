//! The linker of `lus build --aot` (`spec/design/aot.md`, "The linker").
//! It keeps the atoms of a link object that the entry, the initializers,
//! and the roots reach, following a relocation of a registered builtin
//! only when the program reaches that builtin. It lays the kept atoms out,
//! applies their relocations, and writes the executable.
//!
//! Linux gets a static ELF executable at a fixed address, which needs no
//! loader: the kernel maps its three segments and starts the startup code
//! of musl, which finds the thread-local template through the program
//! headers.

const std = @import("std");
const lobj = @import("lobj.zig");
const Allocator = std.mem.Allocator;
const elf = std.elf;

/// A program header of ELF64.
const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};
const PT_LOAD = 1;
const PT_PHDR = 6;
const PT_TLS = 7;
const PT_GNU_STACK = 0x6474e551;

/// Decides whether the linker keeps the entry `name` of a registration.
pub const Keep = struct {
    ctx: *const anyopaque,
    keeps: *const fn (ctx: *const anyopaque, kind: lobj.GuardKind, path: []const u8, name: []const u8) bool,

    /// Keeps every builtin.
    pub const all: Keep = .{ .ctx = undefined, .keeps = struct {
        fn f(_: *const anyopaque, _: lobj.GuardKind, _: []const u8, _: []const u8) bool {
            return true;
        }
    }.f };
};

pub const Result = struct {
    /// The executable, without the payload of `lus build`.
    bytes: []u8,
    /// The size of the code and the data that were kept.
    kept: u64,
    /// The size of every atom of the link object.
    total: u64,
};

pub const Error = error{ OutOfMemory, UnsupportedRelocation, RelocationOverflow, UnsupportedTarget };

/// Links `o`. When `map` is given, it receives a line for each kept atom,
/// largest first: its size, its name, and the atom that first reached it.
pub fn link(gpa: Allocator, o: *const lobj.Object, keep: Keep, map: ?*std.Io.Writer) Error!Result {
    if (o.os != .linux) return error.UnsupportedTarget;
    var l: Linker = .{ .gpa = gpa, .o = o };
    defer l.deinit();
    try l.drop(keep);
    try l.mark();
    try l.layout();
    const bytes = try l.write();
    errdefer gpa.free(bytes);
    if (map) |w| l.writeMap(w) catch {};
    var kept: u64 = 0;
    var total: u64 = 0;
    for (o.atoms, l.live) |a, live| {
        total += a.size;
        if (live) kept += a.size;
    }
    return .{ .bytes = bytes, .kept = kept, .total = total };
}

const no_addr = std.math.maxInt(u64);

const Linker = struct {
    gpa: Allocator,
    o: *const lobj.Object,
    /// The slots of registered builtins that the program never reaches,
    /// by atom and offset.
    dropped: std.AutoHashMapUnmanaged(u64, void) = .empty,
    live: []bool = &.{},
    /// The atom that first reached each kept atom, or itself for a root.
    parent: []u32 = &.{},
    /// The address of each kept atom, and for thread-local atoms the
    /// offset in the thread-local block.
    addr: []u64 = &.{},
    /// The slots of the global offset table, by target.
    got: std.AutoArrayHashMapUnmanaged(GotKey, void) = .empty,
    linker_addr: []u64 = &.{},

    base: u64 = 0x200000,
    page: u64 = 0x10000,
    seg: [3]Seg = undefined,
    got_addr: u64 = 0,
    dso_handle: u64 = 0,
    tls: struct { addr: u64 = 0, filesz: u64 = 0, memsz: u64 = 0, align_: u64 = 1 } = .{},
    init_start: u64 = 0,
    init_end: u64 = 0,
    fini_start: u64 = 0,
    fini_end: u64 = 0,
    bss_start: u64 = 0,
    end: u64 = 0,
    phnum: u16 = 0,

    const Seg = struct { addr: u64, filesz: u64, memsz: u64, flags: u32 };
    const GotKey = struct { target: lobj.Target, sym: u32, tls: bool };

    fn deinit(l: *Linker) void {
        l.dropped.deinit(l.gpa);
        l.got.deinit(l.gpa);
        l.gpa.free(l.live);
        l.gpa.free(l.parent);
        l.gpa.free(l.addr);
        l.gpa.free(l.linker_addr);
    }

    fn drop(l: *Linker, keep: Keep) Error!void {
        const o = l.o;
        const stride, const func_off, const leaf_off = o.reg_layout;
        for (o.guards) |g| {
            const kind: lobj.GuardKind = @fromBackingInt(@intCast(g.kind));
            const path = o.string(g.path);
            var it = std.mem.splitScalar(u8, o.string(g.names), ',');
            var i: u64 = 0;
            while (it.next()) |name| : (i += 1) {
                if (keep.keeps(keep.ctx, kind, path, name)) continue;
                const at = g.offset + i * stride;
                try l.dropped.put(l.gpa, @as(u64, g.atom) << 32 | (at + func_off), {});
                try l.dropped.put(l.gpa, @as(u64, g.atom) << 32 | (at + leaf_off), {});
            }
        }
    }

    fn isDropped(l: *const Linker, atom: usize, offset: u32) bool {
        return l.dropped.contains(@as(u64, @intCast(atom)) << 32 | offset);
    }

    fn mark(l: *Linker) Error!void {
        const o = l.o;
        l.live = try l.gpa.alloc(bool, o.atoms.len);
        @memset(l.live, false);
        l.parent = try l.gpa.alloc(u32, o.atoms.len);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(l.gpa);
        try work.append(l.gpa, o.entry.atom);
        try work.appendSlice(l.gpa, o.roots);
        for (work.items) |a| l.parent[a] = a;
        while (work.pop()) |a| {
            if (l.live[a]) continue;
            l.live[a] = true;
            for (o.atomRelocs(o.atoms[a])) |r| {
                if (r.target.space != .atom or l.live[r.target.index]) continue;
                if (l.isDropped(a, r.offset)) continue;
                l.parent[r.target.index] = a;
                try work.append(l.gpa, r.target.index);
            }
        }
    }

    fn writeMap(l: *const Linker, w: *std.Io.Writer) !void {
        const o = l.o;
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(l.gpa);
        for (l.live, 0..) |live, i| if (live) try order.append(l.gpa, @intCast(i));
        std.mem.sort(u32, order.items, o, struct {
            fn lt(ob: *const lobj.Object, a: u32, b: u32) bool {
                return ob.atoms[a].size > ob.atoms[b].size;
            }
        }.lt);
        for (order.items) |i| {
            const a = o.atoms[i];
            try w.print("{d}\t{s}\t{s}\t<- {s}\t0x{x}\n", .{ a.size, @tagName(a.kind), o.string(a.name), o.string(o.atoms[l.parent[i]].name), l.addr[i] });
        }
        try w.flush();
    }

    fn usesGot(l: *const Linker, ty: u32) ?bool {
        return switch (l.o.arch) {
            .x86_64 => switch (ty) {
                9, 41, 42 => false, // GOTPCREL, GOTPCRELX, REX_GOTPCRELX
                22 => true, // GOTTPOFF
                else => null,
            },
            .aarch64 => switch (ty) {
                311, 312 => false, // ADR_GOT_PAGE, LD64_GOT_LO12_NC
                541, 542 => true, // TLSIE_ADR_GOTTPREL_PAGE21, TLSIE_LD64_GOTTPREL_LO12_NC
                else => null,
            },
        };
    }

    fn place(l: *Linker, pos: *u64, kinds: []const lobj.Kind) void {
        for (kinds) |k| {
            for (l.o.atoms, 0..) |a, i| {
                if (!l.live[i] or a.kind != k) continue;
                pos.* = std.mem.alignForward(u64, pos.*, @as(u64, 1) << @intCast(a.align_log2));
                l.addr[i] = pos.*;
                pos.* += a.size;
            }
        }
    }

    fn layout(l: *Linker) Error!void {
        const o = l.o;
        if (o.arch == .x86_64) l.page = 0x1000;
        l.addr = try l.gpa.alloc(u64, o.atoms.len);
        @memset(l.addr, no_addr);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i]) continue;
            for (o.atomRelocs(a)) |r| {
                const tls = l.usesGot(r.type) orelse continue;
                try l.got.put(l.gpa, .{ .target = r.target, .sym = r.sym, .tls = tls }, {});
            }
        }
        l.phnum = 6;
        const header_size = @sizeOf(elf.Elf64_Ehdr) + @as(u64, l.phnum) * @sizeOf(Phdr);
        // The first segment, read only: the headers and the constants.
        var pos = l.base + header_size;
        l.place(&pos, &.{.rodata});
        l.seg[0] = .{ .addr = l.base, .filesz = pos - l.base, .memsz = pos - l.base, .flags = elf.PF_R };
        // The code.
        pos = std.mem.alignForward(u64, pos, l.page);
        const text = pos;
        l.place(&pos, &.{.text});
        l.seg[1] = .{ .addr = text, .filesz = pos - text, .memsz = pos - text, .flags = elf.PF_R | elf.PF_X };
        // The data: the arrays of initializers, the data, the global
        // offset table, the thread-local template, then the zeroed data.
        pos = std.mem.alignForward(u64, pos, l.page);
        const data = pos;
        pos = std.mem.alignForward(u64, pos, 8);
        l.init_start = pos;
        l.place(&pos, &.{.init_array});
        l.init_end = pos;
        l.fini_start = pos;
        l.place(&pos, &.{.fini_array});
        l.fini_end = pos;
        l.place(&pos, &.{.data});
        pos = std.mem.alignForward(u64, pos, 8);
        l.dso_handle = pos;
        pos += 8;
        l.got_addr = pos;
        pos += 8 * @as(u64, l.got.count());
        // Thread-local atoms get offsets in the block, which starts at
        // its alignment in memory.
        var tls_align: u64 = 1;
        for (o.atoms, 0..) |a, i| if (l.live[i] and (a.kind == .tdata or a.kind == .tbss)) {
            tls_align = @max(tls_align, @as(u64, 1) << @intCast(a.align_log2));
        };
        pos = std.mem.alignForward(u64, pos, tls_align);
        const tls_start = pos;
        var tpos: u64 = 0;
        l.place(&tpos, &.{.tdata});
        const tdata_size = tpos;
        l.place(&tpos, &.{.tbss});
        l.tls = .{ .addr = tls_start, .filesz = tdata_size, .memsz = std.mem.alignForward(u64, tpos, tls_align), .align_ = tls_align };
        pos += tdata_size;
        const filesz = pos - data;
        l.bss_start = pos;
        l.place(&pos, &.{.bss});
        l.end = pos;
        l.seg[2] = .{ .addr = data, .filesz = filesz, .memsz = pos - data, .flags = elf.PF_R | elf.PF_W };
        l.linker_addr = try l.gpa.alloc(u64, o.linker_names.len);
        for (o.linker_names, l.linker_addr) |n, *a| a.* = l.linkerSymbol(o.string(n));
    }

    fn linkerSymbol(l: *const Linker, name: []const u8) u64 {
        const table = .{
            .{ "__init_array_start", l.init_start },       .{ "__init_array_end", l.init_end },
            .{ "__preinit_array_start", l.init_start },    .{ "__preinit_array_end", l.init_start },
            .{ "__fini_array_start", l.fini_start },       .{ "__fini_array_end", l.fini_end },
            .{ "_GLOBAL_OFFSET_TABLE_", l.got_addr },      .{ "__ehdr_start", l.base },
            .{ "__dso_handle", l.dso_handle },             .{ "_end", l.end },
            .{ "end", l.end },                             .{ "__bss_start", l.bss_start },
            .{ "_etext", l.seg[1].addr + l.seg[1].memsz }, .{ "etext", l.seg[1].addr + l.seg[1].memsz },
            .{ "_edata", l.bss_start },                    .{ "edata", l.bss_start },
        };
        inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
        // `_DYNAMIC` is null in a static executable.
        return 0;
    }

    /// The address that the target of a relocation names, or for a
    /// thread-local atom its offset in the block.
    fn symbol(l: *const Linker, t: lobj.Target, sym: u32) u64 {
        return switch (t.space) {
            .atom => l.addr[t.index] + sym,
            .linker => l.linker_addr[t.index] + sym,
            else => sym,
        };
    }

    fn isTls(l: *const Linker, t: lobj.Target) bool {
        if (t.space != .atom) return false;
        const k = l.o.atoms[t.index].kind;
        return k == .tdata or k == .tbss;
    }

    /// The offset from the thread pointer of the thread-local offset
    /// `off`: below the pointer on x86-64, after a header of 16 bytes on
    /// aarch64.
    fn tpOffset(l: *const Linker, off: u64) i64 {
        return switch (l.o.arch) {
            .x86_64 => @as(i64, @intCast(off)) - @as(i64, @intCast(l.tls.memsz)),
            .aarch64 => @intCast(off + std.mem.alignForward(u64, 16, l.tls.align_)),
        };
    }

    fn gotSlot(l: *const Linker, r: lobj.Reloc, tls: bool) u64 {
        const i = l.got.getIndex(.{ .target = r.target, .sym = r.sym, .tls = tls }).?;
        return l.got_addr + 8 * i;
    }

    fn write(l: *Linker) Error![]u8 {
        const o = l.o;
        const size = l.seg[2].addr + l.seg[2].filesz - l.base;
        const out = try l.gpa.alloc(u8, std.math.cast(usize, size) orelse return error.OutOfMemory);
        errdefer l.gpa.free(out);
        @memset(out, 0);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const at = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            @memcpy(out[index(at - l.base)..][0..index(a.size)], o.bytes(a));
        }
        for (l.got.keys(), 0..) |k, i| {
            const v: u64 = if (k.tls) @bitCast(l.tpOffset(l.symbol(k.target, k.sym))) else l.symbol(k.target, k.sym);
            std.mem.writeInt(u64, out[index(l.got_addr - l.base) + 8 * i ..][0..8], v, .little);
        }
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const at = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            for (o.atomRelocs(a)) |r| {
                const loc = out[index(at - l.base + r.offset)..];
                if (l.isDropped(i, r.offset)) {
                    @memset(loc[0..8], 0);
                    continue;
                }
                try l.apply(r, loc, at + r.offset);
            }
        }
        l.headers(out);
        return out;
    }

    fn apply(l: *const Linker, r: lobj.Reloc, loc: []u8, p: u64) Error!void {
        const s = l.symbol(r.target, r.sym);
        const a = r.addend;
        const sa: i64 = @as(i64, @bitCast(s)) +% a;
        const pi: i64 = @bitCast(p);
        switch (l.o.arch) {
            .x86_64 => switch (r.type) {
                1 => put(u64, loc, @bitCast(sa)), // 64
                2, 4 => try putI32(loc, sa - pi), // PC32, PLT32
                24 => put(u64, loc, @bitCast(sa - pi)), // PC64
                10 => put(u32, loc, std.math.cast(u32, sa) orelse return error.RelocationOverflow), // 32
                11 => try putI32(loc, sa), // 32S
                9, 41, 42 => try putI32(loc, @as(i64, @intCast(l.gotSlot(r, false))) + a - pi), // GOTPCREL
                22 => try putI32(loc, @as(i64, @intCast(l.gotSlot(r, true))) + a - pi), // GOTTPOFF
                23 => try putI32(loc, l.tpOffset(s) + a), // TPOFF32
                25 => put(u64, loc, @bitCast(sa - @as(i64, @intCast(l.got_addr)))), // GOTOFF64
                26 => try putI32(loc, @as(i64, @intCast(l.got_addr)) + a - pi), // GOTPC32
                else => return unsupported(l, r),
            },
            .aarch64 => switch (r.type) {
                257 => put(u64, loc, @bitCast(sa)), // ABS64
                258 => put(u32, loc, std.math.cast(u32, sa) orelse return error.RelocationOverflow), // ABS32
                260 => put(u64, loc, @bitCast(sa - pi)), // PREL64
                261 => try putI32(loc, sa - pi), // PREL32
                275 => try adrp(loc, sa, pi), // ADR_PREL_PG_HI21
                274 => try adr(loc, sa - pi), // ADR_PREL_LO21
                277 => imm12(loc, @intCast(sa & 0xfff)), // ADD_ABS_LO12_NC
                278 => imm12(loc, @intCast(sa & 0xfff)), // LDST8_ABS_LO12_NC
                284 => imm12(loc, @intCast((sa & 0xfff) >> 1)), // LDST16_ABS_LO12_NC
                285 => imm12(loc, @intCast((sa & 0xfff) >> 2)), // LDST32_ABS_LO12_NC
                286 => imm12(loc, @intCast((sa & 0xfff) >> 3)), // LDST64_ABS_LO12_NC
                299 => imm12(loc, @intCast((sa & 0xfff) >> 4)), // LDST128_ABS_LO12_NC
                282, 283 => try branch(loc, sa - pi, 26, 0), // JUMP26, CALL26
                280, 273 => try branch(loc, sa - pi, 19, 5), // CONDBR19, LD_PREL_LO19
                279 => try branch(loc, sa - pi, 14, 5), // TSTBR14
                311 => try adrp(loc, @as(i64, @intCast(l.gotSlot(r, false))) + a, pi), // ADR_GOT_PAGE
                312 => imm12(loc, @intCast(((l.gotSlot(r, false) +% @as(u64, @bitCast(a))) & 0xfff) >> 3)), // LD64_GOT_LO12_NC
                541 => try adrp(loc, @as(i64, @intCast(l.gotSlot(r, true))) + a, pi), // TLSIE_ADR_GOTTPREL_PAGE21
                542 => imm12(loc, @intCast(((l.gotSlot(r, true) +% @as(u64, @bitCast(a))) & 0xfff) >> 3)), // TLSIE_LD64_GOTTPREL_LO12_NC
                549 => imm12(loc, @intCast(((l.tpOffset(s) + a) >> 12) & 0xfff)), // TLSLE_ADD_TPREL_HI12
                550, 551 => imm12(loc, @intCast((l.tpOffset(s) + a) & 0xfff)), // TLSLE_ADD_TPREL_LO12(_NC)
                else => return unsupported(l, r),
            },
        }
    }

    fn unsupported(l: *const Linker, r: lobj.Reloc) Error {
        std.log.err("relocation type {d} of {s} is not supported", .{ r.type, @tagName(l.o.arch) });
        return error.UnsupportedRelocation;
    }

    fn headers(l: *const Linker, out: []u8) void {
        const o = l.o;
        var eh: elf.Elf64_Ehdr = .{
            .e_ident = undefined,
            .e_type = .EXEC,
            .e_machine = switch (o.arch) {
                .x86_64 => .X86_64,
                .aarch64 => .AARCH64,
            },
            .e_version = 1,
            .e_entry = l.addr[o.entry.atom] + o.entry.offset,
            .e_phoff = @sizeOf(elf.Elf64_Ehdr),
            .e_shoff = 0,
            .e_flags = 0,
            .e_ehsize = @sizeOf(elf.Elf64_Ehdr),
            .e_phentsize = @sizeOf(Phdr),
            .e_phnum = l.phnum,
            .e_shentsize = @sizeOf(elf.Elf64_Shdr),
            .e_shnum = 0,
            .e_shstrndx = 0,
        };
        @memset(&eh.e_ident, 0);
        @memcpy(eh.e_ident[0..4], elf.MAGIC);
        eh.e_ident[elf.EI.CLASS] = elf.ELFCLASS64;
        eh.e_ident[elf.EI.DATA] = elf.ELFDATA2LSB;
        eh.e_ident[elf.EI.VERSION] = 1;
        @memcpy(out[0..@sizeOf(elf.Elf64_Ehdr)], std.mem.asBytes(&eh));
        const phdr_size = @as(usize, l.phnum) * @sizeOf(Phdr);
        var ph: [6]Phdr = undefined;
        ph[0] = .{ .p_type = PT_PHDR, .p_flags = elf.PF_R, .p_offset = @sizeOf(elf.Elf64_Ehdr), .p_vaddr = l.base + @sizeOf(elf.Elf64_Ehdr), .p_paddr = l.base + @sizeOf(elf.Elf64_Ehdr), .p_filesz = phdr_size, .p_memsz = phdr_size, .p_align = 8 };
        for (l.seg, 1..) |s, k| ph[k] = .{ .p_type = PT_LOAD, .p_flags = s.flags, .p_offset = s.addr - l.base, .p_vaddr = s.addr, .p_paddr = s.addr, .p_filesz = s.filesz, .p_memsz = s.memsz, .p_align = l.page };
        ph[4] = .{ .p_type = PT_TLS, .p_flags = elf.PF_R, .p_offset = l.tls.addr - l.base, .p_vaddr = l.tls.addr, .p_paddr = l.tls.addr, .p_filesz = l.tls.filesz, .p_memsz = l.tls.memsz, .p_align = l.tls.align_ };
        ph[5] = .{ .p_type = PT_GNU_STACK, .p_flags = elf.PF_R | elf.PF_W, .p_offset = 0, .p_vaddr = 0, .p_paddr = 0, .p_filesz = 0, .p_memsz = 0, .p_align = 16 };
        @memcpy(out[@sizeOf(elf.Elf64_Ehdr)..][0..phdr_size], std.mem.sliceAsBytes(&ph));
    }
};

/// The index into the output of an offset in it. The output fits in
/// memory, which `write` checks when it allocates it, so every offset in
/// it fits a `usize` on a 32-bit host too.
fn index(off: u64) usize {
    return @intCast(off);
}

fn put(comptime T: type, loc: []u8, v: T) void {
    std.mem.writeInt(T, loc[0..@sizeOf(T)], v, .little);
}

fn putI32(loc: []u8, v: i64) Error!void {
    put(i32, loc, std.math.cast(i32, v) orelse return error.RelocationOverflow);
}

fn insn(loc: []u8) u32 {
    return std.mem.readInt(u32, loc[0..4], .little);
}

fn adrp(loc: []u8, target: i64, p: i64) Error!void {
    const delta = (target & ~@as(i64, 0xfff)) - (p & ~@as(i64, 0xfff));
    try adrImm(loc, delta >> 12);
}

fn adr(loc: []u8, delta: i64) Error!void {
    try adrImm(loc, delta);
}

fn adrImm(loc: []u8, v: i64) Error!void {
    if (v < -(1 << 20) or v >= (1 << 20)) return error.RelocationOverflow;
    const imm: u32 = @truncate(@as(u64, @bitCast(v)));
    const i = insn(loc) & ~@as(u32, (0x3 << 29) | (0x7ffff << 5));
    put(u32, loc, i | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5));
}

fn imm12(loc: []u8, v: u32) void {
    const i = insn(loc) & ~@as(u32, 0xfff << 10);
    put(u32, loc, i | ((v & 0xfff) << 10));
}

fn branch(loc: []u8, delta: i64, comptime bits: u5, comptime shift: u5) Error!void {
    if (delta & 3 != 0) return error.RelocationOverflow;
    const v = delta >> 2;
    if (v < -(@as(i64, 1) << (bits - 1)) or v >= (@as(i64, 1) << (bits - 1))) return error.RelocationOverflow;
    const mask: u32 = ((@as(u32, 1) << bits) - 1) << shift;
    const imm: u32 = @truncate(@as(u64, @bitCast(v)));
    put(u32, loc, (insn(loc) & ~mask) | ((imm << shift) & mask));
}

test "the linker keeps what the entry reaches and clears a dropped builtin" {
    const gpa = std.testing.allocator;
    var w: lobj.Writer = .{ .gpa = gpa, .arch = .x86_64, .os = .linux };
    defer w.deinit();
    // _start: call f (e8 rel32), then the registration of two builtins,
    // each 16 bytes with its function at offset 0, and a dead function.
    const start = try w.atom(.text, 4, &[_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 }, 6, "_start");
    try w.reloc(.{ .offset = 1, .type = 4, .target = .{ .index = 1, .space = .atom }, .addend = -4 });
    const f = try w.atom(.text, 4, &[_]u8{0xc3}, 1, "f");
    _ = f;
    const reg = try w.atom(.rodata, 3, &@as([32]u8, @splat(0)), 32, "reg");
    try w.reloc(.{ .offset = 0, .type = 1, .target = .{ .index = 3, .space = .atom }, .addend = 0 });
    try w.reloc(.{ .offset = 16, .type = 1, .target = .{ .index = 4, .space = .atom }, .addend = 0 });
    const kept = try w.atom(.text, 4, &[_]u8{0xc3}, 1, "kept");
    const gone = try w.atom(.text, 4, &[_]u8{0xc3}, 1, "gone");
    _ = try w.atom(.text, 4, &[_]u8{0xc3}, 1, "dead");
    try w.roots.append(gpa, reg);
    w.reg_layout = .{ 16, 0, 8 };
    try w.guards.append(gpa, .{ .kind = 0, .path = try w.string("lib"), .names = try w.string("kept,gone"), .atom = reg, .offset = 0 });
    w.entry = .{ .name = try w.string("_start"), .atom = start, .offset = 0 };
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try w.write(&buf.writer);
    const bytes = try gpa.alignedAlloc(u8, .@"8", buf.written().len);
    defer gpa.free(bytes);
    @memcpy(bytes, buf.written());
    const o = try lobj.read(bytes);
    const keep: Keep = .{ .ctx = undefined, .keeps = struct {
        fn k(_: *const anyopaque, _: lobj.GuardKind, _: []const u8, name: []const u8) bool {
            return std.mem.eql(u8, name, "kept");
        }
    }.k };
    const r = try link(gpa, &o, keep, null);
    defer gpa.free(r.bytes);
    // _start, f, reg, and kept: 6 + 1 + 32 + 1 bytes.
    try std.testing.expectEqual(@as(u64, 40), r.kept);
    _ = kept;
    _ = gone;
    // The call reaches f, the next atom of the code, 16 bytes on.
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, r.bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    const text: usize = @intCast(eh.e_entry - 0x200000);
    try std.testing.expectEqual(@as(i32, 16 - 5), std.mem.readInt(i32, r.bytes[text + 1 ..][0..4], .little));
    // The registration holds the address of `kept` and null for `gone`.
    const reg_at = @sizeOf(elf.Elf64_Ehdr) + 6 * @sizeOf(Phdr);
    const reg_off = std.mem.alignForward(usize, reg_at, 8);
    try std.testing.expect(std.mem.readInt(u64, r.bytes[reg_off..][0..8], .little) != 0);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, r.bytes[reg_off + 16 ..][0..8], .little));
}
