//! The writer of the linker for FreeBSD (`spec/design/aot.md`, "The
//! linker"). It lays the kept atoms out as an ELF executable at a fixed
//! address that loads the C library of FreeBSD and its sibling libraries
//! through the loader `/libexec/ld-elf.so.1`.
//!
//! The loader binds every import when it maps the executable, as
//! `DF_BIND_NOW` asks, so each import has one slot in the global offset
//! table with a dynamic relocation. A call to an import goes through a
//! stub that jumps through that slot. An absolute address of an import
//! in data gets its own dynamic relocation, which puts the constant that
//! holds it in the writable segment. Code that addresses data of a
//! library directly reaches a copy of it in the executable, which a copy
//! relocation fills and which the executable exports, so the library uses
//! the same copy. The executable also exports the definitions that the
//! libraries name, such as `environ`, which the startup object defines.

const std = @import("std");
const lobj = @import("lobj.zig");
const link = @import("link.zig");
const Linker = link.Linker;
const Error = link.Error;
const elf = std.elf;
const Allocator = std.mem.Allocator;

const interp = "/libexec/ld-elf.so.1";

/// The release of FreeBSD that the note of the executable names, which
/// the kernel and the C library read as the release the program was built
/// for.
const osrel: u32 = 1400000;

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

/// The binding and the type of a symbol in its `st_info`.
fn info(bind: u8, ty: u8) u8 {
    return bind << 4 | ty;
}

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;
const PT_NOTE = 4;
const PT_PHDR = 6;
const PT_TLS = 7;
const PT_GNU_STACK = 0x6474e551;

/// The size of a stub: an indirect jump through the slot of its import,
/// padded with traps.
const stub_size = 16;

/// The section index that the exported symbols name. The executable has
/// no section headers. The loader reads only whether a symbol is defined.
const defined_shndx = 1;

/// Where an atom goes.
const Place = enum { rodata, text, init, fini, data, tdata, tbss, bss };

const Rela = struct { offset: u64, type: u32, sym: u32, addend: i64 };

/// Writes the executable of `l`, without the payload.
pub fn write(l: *Linker) Error![]u8 {
    var d: Dyn = .{ .l = l, .gpa = l.gpa };
    defer d.deinit();
    try d.classify();
    try d.layout();
    return d.emit();
}

const Dyn = struct {
    l: *Linker,
    gpa: Allocator,
    page: u64 = 0x1000,
    place_of: []Place = &.{},
    /// The imports that kept atoms use, in the order of the dynamic
    /// symbols after the null symbol.
    imports: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// The imports that kept code calls, each with a stub.
    stubs: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// The imports of data that kept code addresses directly, each with
    /// a copy in the executable.
    copies: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// The number of absolute addresses of imports in kept data.
    absolutes: u64 = 0,
    rela: std.ArrayList(Rela) = .empty,
    dynstr: std.ArrayList(u8) = .empty,
    /// The offset in `dynstr` of the name of each dynamic symbol.
    sym_names: std.ArrayList(u32) = .empty,
    /// The offsets in `dynstr` of the libraries the executable needs.
    needed: std.ArrayList(u32) = .empty,
    phnum: u16 = 0,
    dyn_count: u64 = 0,
    interp_addr: u64 = 0,
    note_addr: u64 = 0,
    hash_addr: u64 = 0,
    nbucket: u32 = 0,
    dynsym_addr: u64 = 0,
    dynstr_addr: u64 = 0,
    rela_addr: u64 = 0,
    stubs_addr: u64 = 0,
    dynamic_addr: u64 = 0,
    copy_addr: []u64 = &.{},

    fn deinit(d: *Dyn) void {
        d.gpa.free(d.place_of);
        d.gpa.free(d.copy_addr);
        d.imports.deinit(d.gpa);
        d.stubs.deinit(d.gpa);
        d.copies.deinit(d.gpa);
        d.rela.deinit(d.gpa);
        d.dynstr.deinit(d.gpa);
        d.sym_names.deinit(d.gpa);
        d.needed.deinit(d.gpa);
    }

    fn x86(d: *const Dyn) bool {
        return d.l.o.arch == .x86_64;
    }

    fn abs64(d: *const Dyn) u32 {
        return if (d.x86()) 1 else 257;
    }

    fn isBranch(d: *const Dyn, ty: u32) bool {
        return if (d.x86()) ty == 4 else ty == 282 or ty == 283;
    }

    /// The relocations that compute an address of their target from the
    /// place or as an absolute value, which name a copy of data.
    fn isDirect(d: *const Dyn, ty: u32) bool {
        return if (d.x86())
            ty == 2 or ty == 10 or ty == 11 // PC32, 32, 32S
        else switch (ty) {
            // ADR_PREL_LO21, ADR_PREL_PG_HI21, ADD_ABS_LO12_NC, and the
            // loads and stores of LDST8 to LDST128.
            274, 275, 277, 278, 284, 285, 286, 299 => true,
            else => false,
        };
    }

    fn relGlobDat(d: *const Dyn) u32 {
        return if (d.x86()) 6 else 1025;
    }

    fn relTpoff(d: *const Dyn) u32 {
        return if (d.x86()) 18 else 1030;
    }

    fn relCopy(d: *const Dyn) u32 {
        return if (d.x86()) 5 else 1024;
    }

    fn importTarget(im: u32) lobj.Target {
        return .{ .index = @intCast(im), .space = .import };
    }

    /// Sorts the kept atoms into places and finds the imports, the stubs,
    /// the copies, and the slots of the global offset table they need.
    fn classify(d: *Dyn) Error!void {
        const l = d.l;
        const o = l.o;
        if (o.arch != .x86_64 and o.arch != .aarch64) return error.UnsupportedTarget;
        if (o.arch == .aarch64) d.page = 0x10000;
        d.place_of = try d.gpa.alloc(Place, o.atoms.len);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i]) continue;
            var writable = false;
            for (o.atomRelocs(a)) |r| {
                if (l.isDropped(i, r.offset)) continue;
                if (l.usesGot(r.type)) |tls| {
                    try l.got.put(d.gpa, .{ .target = r.target, .sym = r.sym, .tls = tls }, {});
                    if (r.target.space == .import) try d.imports.put(d.gpa, r.target.index, {});
                    continue;
                }
                if (r.target.space != .import) continue;
                const im = o.imports[r.target.index];
                try d.imports.put(d.gpa, r.target.index, {});
                if (r.type == d.abs64()) {
                    d.absolutes += 1;
                    writable = true;
                } else if (im.data == 0 and (d.isBranch(r.type) or d.isDirect(r.type))) {
                    try d.stubs.put(d.gpa, r.target.index, {});
                } else if (im.data != 0 and d.isDirect(r.type)) {
                    try d.copies.put(d.gpa, r.target.index, {});
                } else {
                    std.log.err("{s}: relocation type {d} names the import {s}", .{ o.string(a.name), r.type, o.string(im.name) });
                    return error.UnsupportedRelocation;
                }
            }
            d.place_of[i] = switch (a.kind) {
                .rodata => if (writable) .data else .rodata,
                .text => .text,
                .init_array => .init,
                .fini_array => .fini,
                .data => .data,
                .tdata => .tdata,
                .tbss => .tbss,
                .bss => .bss,
                .thread_vars, .unwind => {
                    std.log.err("{s}: atoms of kind {s} are not supported on FreeBSD", .{ o.string(a.name), @tagName(a.kind) });
                    return error.UnsupportedTarget;
                },
            };
        }
        // Each stub jumps through the slot of its import.
        for (d.stubs.keys()) |im| try l.got.put(d.gpa, .{ .target = importTarget(im), .sym = 0, .tls = false }, {});
    }

    fn placeAtoms(d: *Dyn, pos: *u64, p: Place) void {
        const l = d.l;
        for (l.o.atoms, 0..) |a, i| {
            if (!l.live[i] or d.place_of[i] != p) continue;
            pos.* = std.mem.alignForward(u64, pos.*, @as(u64, 1) << @intCast(a.align_log2));
            l.addr[i] = pos.*;
            pos.* += a.size;
        }
    }

    fn any(d: *const Dyn, p: Place) bool {
        for (d.l.live, d.place_of) |live, q| if (live and q == p) return true;
        return false;
    }

    fn string(d: *Dyn, s: []const u8) Error!u32 {
        const off: u32 = @intCast(d.dynstr.items.len);
        try d.dynstr.appendSlice(d.gpa, s);
        try d.dynstr.append(d.gpa, 0);
        return off;
    }

    fn symCount(d: *const Dyn) u64 {
        return 1 + d.imports.count() + d.l.o.symbols.len;
    }

    fn layout(d: *Dyn) Error!void {
        const l = d.l;
        const o = l.o;
        const word = 8;
        l.addr = try d.gpa.alloc(u64, o.atoms.len);
        @memset(l.addr, link.no_addr);

        // The names: the libraries the imports come from, in the order
        // the loader searches them, the imports, and the exports.
        try d.dynstr.append(d.gpa, 0);
        var used = try d.gpa.alloc(bool, o.libs.len);
        defer d.gpa.free(used);
        @memset(used, false);
        for (d.imports.keys()) |im| used[o.imports[im].lib] = true;
        for (o.libs, used) |lib, u| if (u) try d.needed.append(d.gpa, try d.string(o.string(lib)));
        try d.sym_names.append(d.gpa, 0);
        for (d.imports.keys()) |im| try d.sym_names.append(d.gpa, try d.string(o.string(o.imports[im].name)));
        for (o.symbols) |s| try d.sym_names.append(d.gpa, try d.string(o.string(s.name)));

        var got_imports: u64 = 0;
        for (l.got.keys()) |k| {
            if (k.target.space == .import) got_imports += 1;
        }
        const nrela = got_imports + d.absolutes + d.copies.count();
        const has_tls = for (o.atoms, 0..) |a, i| {
            if (l.live[i] and (a.kind == .tdata or a.kind == .tbss)) break true;
        } else false;
        // PHDR, INTERP, NOTE, three LOAD, DYNAMIC, GNU_STACK, and TLS.
        d.phnum = 8 + @as(u16, @intFromBool(has_tls));
        d.dyn_count = d.needed.items.len + 5 + 3 + 3 + 1;
        if (nrela > 0) d.dyn_count += 3;
        if (d.any(.init)) d.dyn_count += 2;
        if (d.any(.fini)) d.dyn_count += 2;
        const nsyms = d.symCount();
        d.nbucket = @intCast(@max(1, nsyms / 2));

        // The first segment, read only: the headers, the tables of the
        // loader, and the constants.
        var pos = l.base + @sizeOf(elf.Elf64_Ehdr) + @as(u64, d.phnum) * @sizeOf(Phdr);
        d.interp_addr = pos;
        pos += interp.len + 1;
        pos = std.mem.alignForward(u64, pos, 4);
        d.note_addr = pos;
        pos += 24;
        pos = std.mem.alignForward(u64, pos, 8);
        d.hash_addr = pos;
        pos += 4 * (2 + d.nbucket + nsyms);
        pos = std.mem.alignForward(u64, pos, 8);
        d.dynsym_addr = pos;
        pos += @sizeOf(elf.Elf64_Sym) * nsyms;
        d.dynstr_addr = pos;
        pos += d.dynstr.items.len;
        pos = std.mem.alignForward(u64, pos, 8);
        d.rela_addr = pos;
        pos += @sizeOf(elf.Elf64_Rela) * nrela;
        d.placeAtoms(&pos, .rodata);
        l.seg[0] = .{ .addr = l.base, .filesz = pos - l.base, .memsz = pos - l.base, .flags = elf.PF_R };

        // The code and the stubs.
        pos = std.mem.alignForward(u64, pos, d.page);
        const text = pos;
        d.placeAtoms(&pos, .text);
        pos = std.mem.alignForward(u64, pos, stub_size);
        d.stubs_addr = pos;
        pos += stub_size * d.stubs.count();
        l.seg[1] = .{ .addr = text, .filesz = pos - text, .memsz = pos - text, .flags = elf.PF_R | elf.PF_X };

        // The data: the arrays of initializers, the data, the dynamic
        // section, the global offset table, the thread-local template,
        // then the copies of data and the zeroed data.
        pos = std.mem.alignForward(u64, pos, d.page);
        const data = pos;
        pos = std.mem.alignForward(u64, pos, word);
        l.init_start = pos;
        d.placeAtoms(&pos, .init);
        l.init_end = pos;
        pos = std.mem.alignForward(u64, pos, word);
        l.fini_start = pos;
        d.placeAtoms(&pos, .fini);
        l.fini_end = pos;
        d.placeAtoms(&pos, .data);
        pos = std.mem.alignForward(u64, pos, word);
        d.dynamic_addr = pos;
        pos += @sizeOf(elf.Elf64_Dyn) * d.dyn_count;
        l.dso_handle = pos;
        pos += word;
        l.got_addr = pos;
        pos += word * @as(u64, l.got.count());
        var tls_align: u64 = 1;
        for (o.atoms, 0..) |a, i| if (l.live[i] and (a.kind == .tdata or a.kind == .tbss)) {
            tls_align = @max(tls_align, @as(u64, 1) << @intCast(a.align_log2));
        };
        pos = std.mem.alignForward(u64, pos, tls_align);
        const tls_start = pos;
        var tpos: u64 = 0;
        d.placeAtoms(&tpos, .tdata);
        const tdata_size = tpos;
        d.placeAtoms(&tpos, .tbss);
        l.tls = .{ .addr = tls_start, .filesz = tdata_size, .memsz = std.mem.alignForward(u64, tpos, tls_align), .align_ = tls_align };
        pos += tdata_size;
        const filesz = pos - data;
        l.bss_start = pos;
        d.copy_addr = try d.gpa.alloc(u64, d.copies.count());
        for (d.copies.keys(), d.copy_addr) |im, *at| {
            pos = std.mem.alignForward(u64, pos, 16);
            at.* = pos;
            pos += o.imports[im].size;
        }
        d.placeAtoms(&pos, .bss);
        l.end = pos;
        l.seg[2] = .{ .addr = data, .filesz = filesz, .memsz = pos - data, .flags = elf.PF_R | elf.PF_W };

        l.import_addr = try d.gpa.alloc(u64, o.imports.len);
        @memset(l.import_addr, 0);
        for (d.stubs.keys(), 0..) |im, k| l.import_addr[im] = d.stubs_addr + stub_size * k;
        for (d.copies.keys(), d.copy_addr) |im, at| l.import_addr[im] = at;
        l.dynamic = d.dynamic_addr;
        l.linker_addr = try d.gpa.alloc(u64, o.linker_names.len);
        for (o.linker_names, l.linker_addr) |n, *a| a.* = l.linkerSymbol(o.string(n));
    }

    /// The index of the dynamic symbol of an import.
    fn symIndex(d: *const Dyn, im: u32) u32 {
        return @intCast(1 + d.imports.getIndex(im).?);
    }

    fn emit(d: *Dyn) Error![]u8 {
        const l = d.l;
        const o = l.o;
        const base = l.base;
        const size = l.seg[2].addr + l.seg[2].filesz - base;
        const out = try d.gpa.alloc(u8, std.math.cast(usize, size) orelse return error.OutOfMemory);
        errdefer d.gpa.free(out);
        @memset(out, 0);
        const at = struct {
            fn f(b: []u8, base_: u64, addr: u64) []u8 {
                return b[link.index(addr - base_)..];
            }
        }.f;
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const addr = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            @memcpy(at(out, base, addr)[0..link.index(a.size)], o.bytes(a));
        }
        // The global offset table: an import gets a dynamic relocation,
        // anything else its address or its offset from the thread
        // pointer.
        for (l.got.keys(), 0..) |k, i| {
            const slot = l.got_addr + 8 * i;
            if (k.target.space == .import) {
                try d.rela.append(d.gpa, .{ .offset = slot, .type = if (k.tls) d.relTpoff() else d.relGlobDat(), .sym = d.symIndex(k.target.index), .addend = k.sym });
                continue;
            }
            const v: u64 = if (k.tls) @bitCast(l.tpOffset(l.symbol(k.target, k.sym))) else l.symbol(k.target, k.sym);
            std.mem.writeInt(u64, at(out, base, slot)[0..8], v, .little);
        }
        // A stub: jmp *slot(%rip) on x86-64, and adrp x16, slot; ldr x16,
        // [x16, :lo12:slot]; br x16 on aarch64.
        for (d.stubs.keys(), 0..) |im, k| {
            const addr = d.stubs_addr + stub_size * k;
            const loc = at(out, base, addr)[0..stub_size];
            const slot = l.gotSlot(.{ .offset = 0, .type = 0, .target = importTarget(im), .addend = 0 }, false);
            if (d.x86()) {
                @memset(loc, 0xcc);
                loc[0] = 0xff;
                loc[1] = 0x25;
                std.mem.writeInt(i32, loc[2..6], @intCast(@as(i64, @intCast(slot)) - @as(i64, @intCast(addr + 6))), .little);
                continue;
            }
            std.mem.writeInt(u32, loc[0..4], 0x9000_0010, .little);
            std.mem.writeInt(u32, loc[4..8], 0xf940_0210, .little);
            std.mem.writeInt(u32, loc[8..12], 0xd61f_0200, .little);
            std.mem.writeInt(u32, loc[12..16], 0xd420_0000, .little); // brk #0
            const r: lobj.Reloc = .{ .offset = 0, .type = 0, .target = .none_target, .sym = @intCast(slot), .addend = 0 };
            var rr = r;
            rr.type = 275;
            try l.apply(rr, loc[0..], addr);
            rr.type = 286;
            try l.apply(rr, loc[4..], addr + 4);
        }
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const addr = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            for (o.atomRelocs(a)) |r| {
                const p = addr + r.offset;
                const loc = at(out, base, p);
                if (l.isDropped(i, r.offset)) {
                    @memset(loc[0..8], 0);
                    continue;
                }
                if (r.type == d.abs64() and r.target.space == .import) {
                    try d.rela.append(d.gpa, .{ .offset = p, .type = d.abs64(), .sym = d.symIndex(r.target.index), .addend = @as(i64, r.sym) + r.addend });
                    continue;
                }
                try l.apply(r, loc, p);
            }
        }
        for (d.copies.keys(), d.copy_addr) |im, addr| try d.rela.append(d.gpa, .{ .offset = addr, .type = d.relCopy(), .sym = d.symIndex(im), .addend = 0 });

        // The tables of the loader.
        @memcpy(at(out, base, d.interp_addr)[0..interp.len], interp);
        const note = at(out, base, d.note_addr)[0..24];
        std.mem.writeInt(u32, note[0..4], 8, .little); // namesz
        std.mem.writeInt(u32, note[4..8], 4, .little); // descsz
        std.mem.writeInt(u32, note[8..12], 1, .little); // NT_FREEBSD_ABI_TAG
        @memcpy(note[12..20], "FreeBSD\x00");
        std.mem.writeInt(u32, note[20..24], osrel, .little);
        @memcpy(at(out, base, d.dynstr_addr)[0..d.dynstr.items.len], d.dynstr.items);
        d.writeSymbols(out);
        d.writeHash(out);
        for (d.rela.items, 0..) |r, k| {
            const e: elf.Elf64_Rela = .{ .r_offset = r.offset, .r_info = @as(u64, r.sym) << 32 | r.type, .r_addend = r.addend };
            @memcpy(at(out, base, d.rela_addr + @sizeOf(elf.Elf64_Rela) * k)[0..@sizeOf(elf.Elf64_Rela)], std.mem.asBytes(&e));
        }
        d.writeDynamic(out);
        d.headers(out);
        return out;
    }

    fn writeSymbols(d: *const Dyn, out: []u8) void {
        const l = d.l;
        const o = l.o;
        var k: usize = 1;
        const put = struct {
            fn f(dd: *const Dyn, b: []u8, n: usize, s: elf.Elf64_Sym) void {
                @memcpy(b[link.index(dd.dynsym_addr - dd.l.base + @sizeOf(elf.Elf64_Sym) * n)..][0..@sizeOf(elf.Elf64_Sym)], std.mem.asBytes(&s));
            }
        }.f;
        for (d.imports.keys()) |im| {
            const imp = o.imports[im];
            const bind: u8 = if (imp.weak != 0) elf.STB_WEAK else elf.STB_GLOBAL;
            if (d.copies.getIndex(im)) |c| {
                // The copy of data is the definition the libraries use.
                put(d, out, k, .{ .st_name = d.sym_names.items[k], .st_info = info(elf.STB_GLOBAL, elf.STT_OBJECT), .st_other = 0, .st_shndx = defined_shndx, .st_value = d.copy_addr[c], .st_size = imp.size });
            } else {
                const ty: u8 = if (imp.data != 0) elf.STT_NOTYPE else elf.STT_FUNC;
                put(d, out, k, .{ .st_name = d.sym_names.items[k], .st_info = info(bind, ty), .st_other = 0, .st_shndx = elf.SHN_UNDEF, .st_value = 0, .st_size = 0 });
            }
            k += 1;
        }
        for (o.symbols) |s| {
            const ty: u8 = if (o.atoms[s.atom].kind == .text) elf.STT_FUNC else elf.STT_OBJECT;
            put(d, out, k, .{ .st_name = d.sym_names.items[k], .st_info = info(elf.STB_GLOBAL, ty), .st_other = 0, .st_shndx = defined_shndx, .st_value = l.addr[s.atom] + s.offset, .st_size = 0 });
            k += 1;
        }
    }

    /// The hash table of System V, which the loader looks the symbols of
    /// the executable up through.
    fn writeHash(d: *const Dyn, out: []u8) void {
        const n = d.symCount();
        const h = out[link.index(d.hash_addr - d.l.base)..][0..link.index(4 * (2 + d.nbucket + n))];
        std.mem.writeInt(u32, h[0..4], d.nbucket, .little);
        std.mem.writeInt(u32, h[4..8], @intCast(n), .little);
        const buckets = h[8..][0 .. 4 * d.nbucket];
        const chains = h[8 + 4 * d.nbucket ..];
        var k: u32 = @intCast(n);
        while (k > 1) {
            k -= 1;
            const name = std.mem.sliceTo(d.dynstr.items[d.sym_names.items[k]..], 0);
            const b = 4 * (sysvHash(name) % d.nbucket);
            std.mem.writeInt(u32, chains[4 * k ..][0..4], std.mem.readInt(u32, buckets[b..][0..4], .little), .little);
            std.mem.writeInt(u32, buckets[b..][0..4], k, .little);
        }
    }

    fn writeDynamic(d: *const Dyn, out: []u8) void {
        const l = d.l;
        var k: usize = 0;
        const put = struct {
            fn f(dd: *const Dyn, b: []u8, n: *usize, tag: i64, val: u64) void {
                const e: elf.Elf64_Dyn = .{ .d_tag = tag, .d_val = val };
                @memcpy(b[link.index(dd.dynamic_addr - dd.l.base + @sizeOf(elf.Elf64_Dyn) * n.*)..][0..@sizeOf(elf.Elf64_Dyn)], std.mem.asBytes(&e));
                n.* += 1;
            }
        }.f;
        for (d.needed.items) |n| put(d, out, &k, elf.DT_NEEDED, n);
        put(d, out, &k, elf.DT_HASH, d.hash_addr);
        put(d, out, &k, elf.DT_STRTAB, d.dynstr_addr);
        put(d, out, &k, elf.DT_SYMTAB, d.dynsym_addr);
        put(d, out, &k, elf.DT_STRSZ, d.dynstr.items.len);
        put(d, out, &k, elf.DT_SYMENT, @sizeOf(elf.Elf64_Sym));
        if (d.rela.items.len > 0) {
            put(d, out, &k, elf.DT_RELA, d.rela_addr);
            put(d, out, &k, elf.DT_RELASZ, @sizeOf(elf.Elf64_Rela) * d.rela.items.len);
            put(d, out, &k, elf.DT_RELAENT, @sizeOf(elf.Elf64_Rela));
        }
        if (d.any(.init)) {
            put(d, out, &k, elf.DT_INIT_ARRAY, l.init_start);
            put(d, out, &k, elf.DT_INIT_ARRAYSZ, l.init_end - l.init_start);
        }
        if (d.any(.fini)) {
            put(d, out, &k, elf.DT_FINI_ARRAY, l.fini_start);
            put(d, out, &k, elf.DT_FINI_ARRAYSZ, l.fini_end - l.fini_start);
        }
        put(d, out, &k, elf.DT_FLAGS, elf.DF_BIND_NOW);
        put(d, out, &k, elf.DT_FLAGS_1, elf.DF_1_NOW);
        put(d, out, &k, elf.DT_DEBUG, 0);
        put(d, out, &k, elf.DT_NULL, 0);
        std.debug.assert(k <= d.dyn_count);
    }

    fn headers(d: *const Dyn, out: []u8) void {
        const l = d.l;
        const o = l.o;
        var eh: elf.Elf64_Ehdr = .{
            .e_ident = undefined,
            .e_type = .EXEC,
            .e_machine = if (d.x86()) .X86_64 else .AARCH64,
            .e_version = 1,
            .e_entry = l.addr[o.entry.atom] + o.entry.offset,
            .e_phoff = @sizeOf(elf.Elf64_Ehdr),
            .e_shoff = 0,
            .e_flags = 0,
            .e_ehsize = @sizeOf(elf.Elf64_Ehdr),
            .e_phentsize = @sizeOf(Phdr),
            .e_phnum = d.phnum,
            .e_shentsize = @sizeOf(elf.Elf64_Shdr),
            .e_shnum = 0,
            .e_shstrndx = 0,
        };
        @memset(&eh.e_ident, 0);
        @memcpy(eh.e_ident[0..4], elf.MAGIC);
        eh.e_ident[elf.EI.CLASS] = elf.ELFCLASS64;
        eh.e_ident[elf.EI.DATA] = elf.ELFDATA2LSB;
        eh.e_ident[elf.EI.VERSION] = 1;
        eh.e_ident[elf.EI.OSABI] = @backingInt(elf.OSABI.FREEBSD);
        @memcpy(out[0..@sizeOf(elf.Elf64_Ehdr)], std.mem.asBytes(&eh));
        const phdr_size = @as(u64, d.phnum) * @sizeOf(Phdr);
        var ph: [9]Phdr = undefined;
        var n: usize = 0;
        const seg = struct {
            fn f(ty: u32, flags: u32, addr: u64, b: u64, filesz: u64, memsz: u64, al: u64) Phdr {
                return .{ .p_type = ty, .p_flags = flags, .p_offset = addr - b, .p_vaddr = addr, .p_paddr = addr, .p_filesz = filesz, .p_memsz = memsz, .p_align = al };
            }
        }.f;
        ph[n] = seg(PT_PHDR, elf.PF_R, l.base + @sizeOf(elf.Elf64_Ehdr), l.base, phdr_size, phdr_size, 8);
        n += 1;
        ph[n] = seg(PT_INTERP, elf.PF_R, d.interp_addr, l.base, interp.len + 1, interp.len + 1, 1);
        n += 1;
        for (l.seg) |s| {
            ph[n] = seg(PT_LOAD, s.flags, s.addr, l.base, s.filesz, s.memsz, d.page);
            n += 1;
        }
        const dyn_size = @sizeOf(elf.Elf64_Dyn) * d.dyn_count;
        ph[n] = seg(PT_DYNAMIC, elf.PF_R | elf.PF_W, d.dynamic_addr, l.base, dyn_size, dyn_size, 8);
        n += 1;
        ph[n] = seg(PT_NOTE, elf.PF_R, d.note_addr, l.base, 24, 24, 4);
        n += 1;
        if (d.phnum == 9) {
            ph[n] = seg(PT_TLS, elf.PF_R, l.tls.addr, l.base, l.tls.filesz, l.tls.memsz, l.tls.align_);
            n += 1;
        }
        ph[n] = .{ .p_type = PT_GNU_STACK, .p_flags = elf.PF_R | elf.PF_W, .p_offset = 0, .p_vaddr = 0, .p_paddr = 0, .p_filesz = 0, .p_memsz = 0, .p_align = 16 };
        n += 1;
        std.debug.assert(n == d.phnum);
        @memcpy(out[@sizeOf(elf.Elf64_Ehdr)..][0..link.index(phdr_size)], std.mem.sliceAsBytes(ph[0..n]));
    }
};

/// The hash function of the symbol table of System V.
fn sysvHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| {
        h = (h << 4) +% c;
        const g = h & 0xf000_0000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

test "the hash of the symbol table of System V" {
    try std.testing.expectEqual(@as(u32, 0), sysvHash(""));
    try std.testing.expectEqual(@as(u32, 0x77905a6), sysvHash("printf"));
    try std.testing.expectEqual(@as(u32, 0x6cf04), sysvHash("exit"));
}

test "a FreeBSD executable imports, stubs, copies, and exports" {
    const gpa = std.testing.allocator;
    var w: lobj.Writer = .{ .gpa = gpa, .arch = .x86_64, .os = .freebsd };
    defer w.deinit();
    // _start: call exit@stub; mov stderrp(%rip), %rax; mov p, ...
    const code = [_]u8{ 0xe8, 0, 0, 0, 0, 0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3 };
    const start = try w.atom(.text, 4, &code, code.len, "_start");
    const exit = try w.importOf("exit", "libc.so.7", false, null);
    const stderrp = try w.importOf("__stderrp", "libc.so.7", false, 8);
    const lock = try w.importOf("pthread_mutex_lock", "libthr.so.3", false, null);
    try w.reloc(.{ .offset = 1, .type = 4, .target = exit, .addend = -4 });
    try w.reloc(.{ .offset = 8, .type = 2, .target = stderrp, .addend = -4 });
    const ptrs = try w.atom(.rodata, 3, &@as([8]u8, @splat(0)), 8, "ptrs");
    try w.reloc(.{ .offset = 0, .type = 1, .target = lock, .addend = 0 });
    const env = try w.atom(.bss, 3, null, 8, "environ");
    try w.symbols.append(gpa, .{ .name = try w.string("environ"), .atom = env, .offset = 0 });
    try w.roots.append(gpa, ptrs);
    try w.roots.append(gpa, env);
    w.entry = .{ .name = try w.string("_start"), .atom = start, .offset = 0 };
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try w.write(&buf.writer);
    const bytes = try gpa.alignedAlloc(u8, .@"8", buf.written().len);
    defer gpa.free(bytes);
    @memcpy(bytes, buf.written());
    const o = try lobj.read(bytes);
    const r = try link.link(gpa, &o, .all, .{});
    defer gpa.free(r.bytes);
    const img = r.bytes;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, img[0..@sizeOf(elf.Elf64_Ehdr)]);
    try std.testing.expectEqual(@as(u8, @backingInt(elf.OSABI.FREEBSD)), eh.e_ident[elf.EI.OSABI]);
    var dynamic: ?Phdr = null;
    var interp_ph: ?Phdr = null;
    for (0..eh.e_phnum) |k| {
        const ph = std.mem.bytesToValue(Phdr, img[eh.e_phoff + k * @sizeOf(Phdr) ..][0..@sizeOf(Phdr)]);
        if (ph.p_type == PT_DYNAMIC) dynamic = ph;
        if (ph.p_type == PT_INTERP) interp_ph = ph;
    }
    try std.testing.expectEqualStrings(interp ++ "\x00", img[interp_ph.?.p_offset..][0..interp_ph.?.p_filesz]);
    var strtab: u64 = 0;
    var symtab: u64 = 0;
    var rela: u64 = 0;
    var relasz: u64 = 0;
    var needed: [2][]const u8 = undefined;
    var nneeded: usize = 0;
    var needed_off: [2]u64 = undefined;
    var k: u64 = 0;
    while (true) : (k += 1) {
        const e = std.mem.bytesToValue(elf.Elf64_Dyn, img[dynamic.?.p_offset + k * 16 ..][0..16]);
        switch (e.d_tag) {
            elf.DT_NULL => break,
            elf.DT_NEEDED => {
                needed_off[nneeded] = e.d_val;
                nneeded += 1;
            },
            elf.DT_STRTAB => strtab = e.d_val,
            elf.DT_SYMTAB => symtab = e.d_val,
            elf.DT_RELA => rela = e.d_val,
            elf.DT_RELASZ => relasz = e.d_val,
            else => {},
        }
    }
    const base: u64 = 0x200000;
    for (needed_off[0..nneeded], 0..) |off, i| needed[i] = std.mem.sliceTo(img[strtab - base + off ..], 0);
    try std.testing.expectEqual(@as(usize, 2), nneeded);
    try std.testing.expectEqualStrings("libc.so.7", needed[0]);
    try std.testing.expectEqualStrings("libthr.so.3", needed[1]);
    // One slot for the stub of exit, an absolute address of
    // pthread_mutex_lock, and a copy of __stderrp.
    const types = [_]u32{ 6, 1, 5 };
    try std.testing.expectEqual(@as(u64, types.len * @sizeOf(elf.Elf64_Rela)), relasz);
    var seen: [3]bool = @splat(false);
    for (0..types.len) |i| {
        const e = std.mem.bytesToValue(elf.Elf64_Rela, img[rela - base + i * @sizeOf(elf.Elf64_Rela) ..][0..@sizeOf(elf.Elf64_Rela)]);
        const sym = std.mem.bytesToValue(elf.Elf64_Sym, img[symtab - base + (e.r_info >> 32) * @sizeOf(elf.Elf64_Sym) ..][0..@sizeOf(elf.Elf64_Sym)]);
        const name = std.mem.sliceTo(img[strtab - base + sym.st_name ..], 0);
        const ty: u32 = @truncate(e.r_info);
        if (ty == 6) {
            try std.testing.expectEqualStrings("exit", name);
            seen[0] = true;
        }
        if (ty == 1) {
            try std.testing.expectEqualStrings("pthread_mutex_lock", name);
            seen[1] = true;
        }
        if (ty == 5) {
            try std.testing.expectEqualStrings("__stderrp", name);
            try std.testing.expect(sym.st_shndx != elf.SHN_UNDEF);
            // The load reads the copy.
            const disp = std.mem.readInt(i32, img[eh.e_entry - base + 8 ..][0..4], .little);
            try std.testing.expectEqual(sym.st_value, @as(u64, @intCast(@as(i64, @intCast(eh.e_entry + 12)) + disp)));
            seen[2] = true;
        }
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
    // The call reaches a stub that jumps through the slot of exit.
    const call = std.mem.readInt(i32, img[eh.e_entry - base + 1 ..][0..4], .little);
    const stub = @as(u64, @intCast(@as(i64, @intCast(eh.e_entry + 5)) + call));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x25 }, img[stub - base ..][0..2]);
}
