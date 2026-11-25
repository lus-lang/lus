//! The PE writer of the linker (`spec/design/aot.md`, "The linker"). It
//! lays the kept atoms out as a console executable for Windows on x86-64
//! or arm64, which the loader may map at any address, and starts the
//! startup code of the C library of MinGW.
//!
//! An import is a slot of the import address table, which the loader
//! fills with the address of the function or the datum in its library.
//! Code reads the slot directly, or calls the jump through it that the
//! converter adds for each function (`convert.zig`). The loader adds the
//! difference between the address it maps the image at and the address
//! the image was linked at to every absolute address, which the table of
//! base relocations lists.

const std = @import("std");
const lobj = @import("lobj.zig");
const link = @import("link.zig");
const Linker = link.Linker;
const Error = link.Error;

/// The preferred address of the image, above 4 GB as for every 64-bit
/// executable that the linker of the C library writes.
const image_base: u64 = 0x1_4000_0000;
const section_align: u64 = 0x1000;
const file_align: u64 = 0x200;

/// Where an atom goes.
const Place = enum { text, rdata, data, bss };

const Sect = struct {
    name: []const u8,
    /// The address, and the size in memory.
    addr: u64 = 0,
    size: u64 = 0,
    /// The offset in the file, and the size there, a multiple of
    /// `file_align` and zero for zeroed data.
    raw: u64 = 0,
    raw_size: u64 = 0,
    flags: u32,
};

/// The bytes of an entry of the function table: the start, the end, and
/// the unwind information on x86-64, and the start and the unwind
/// information, which gives the length, on arm64.
fn entrySize(arch: lobj.Arch) u32 {
    return if (arch == .aarch64) 8 else 12;
}

/// The relocation type that writes an absolute address of 64 bits, which
/// gets a base relocation.
fn abs64(arch: lobj.Arch) u32 {
    return if (arch == .aarch64) 257 else 1;
}

/// The data directories of the optional header that the writer fills.
const Dir = enum(u8) { import = 1, exception = 3, basereloc = 5, tls = 9, iat = 12 };

/// Writes the executable of `l`, followed by `payload`, the bundle of
/// `lus build`, which the runtime finds from the end of its file.
pub fn write(l: *Linker, payload: []const u8) Error![]u8 {
    var p: Pe = .{ .l = l, .gpa = l.gpa };
    defer p.deinit();
    return p.run(payload);
}

const Pe = struct {
    l: *Linker,
    gpa: std.mem.Allocator,
    place_of: []Place = &.{},
    /// The imports that kept atoms use, grouped by library.
    imports: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    libs: std.AutoArrayHashMapUnmanaged(u16, void) = .empty,
    sects: std.ArrayList(Sect) = .empty,
    /// The addresses in the image that hold absolute addresses.
    fixups: std.ArrayList(u64) = .empty,
    dirs: [16][2]u32 = @splat(.{ 0, 0 }),
    idata: Sect = .{ .name = ".idata", .flags = 0xc000_0040 },
    /// The function table, in `.rdata` after the constants.
    pdata_addr: u64 = 0,
    pdata_count: u64 = 0,
    headers_size: u64 = 0,

    fn deinit(p: *Pe) void {
        p.gpa.free(p.place_of);
        p.imports.deinit(p.gpa);
        p.libs.deinit(p.gpa);
        p.sects.deinit(p.gpa);
        p.fixups.deinit(p.gpa);
    }

    fn run(p: *Pe, payload: []const u8) Error![]u8 {
        try p.classify();
        try p.layout();
        const image = try p.writeImage();
        defer p.gpa.free(image);
        const all = try p.gpa.alloc(u8, image.len + payload.len);
        @memcpy(all[0..image.len], image);
        @memcpy(all[image.len..], payload);
        return all;
    }

    fn classify(p: *Pe) Error!void {
        const l = p.l;
        const o = l.o;
        if (o.arch != .x86_64 and o.arch != .aarch64) return error.UnsupportedTarget;
        p.place_of = try p.gpa.alloc(Place, o.atoms.len);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i]) continue;
            for (o.atomRelocs(a)) |r| {
                if (l.isDropped(i, r.offset) or r.target.space != .import) continue;
                try p.imports.put(p.gpa, r.target.index, {});
                try p.libs.put(p.gpa, o.imports[r.target.index].lib, {});
            }
            p.place_of[i] = switch (a.kind) {
                .text => .text,
                .rodata => .rdata,
                .data => .data,
                .bss => .bss,
                else => {
                    std.log.err("{s}: atoms of kind {s} are not supported on Windows", .{ o.string(a.name), @tagName(a.kind) });
                    return error.UnsupportedTarget;
                },
            };
        }
    }

    fn placeAtoms(p: *Pe, pos: *u64, place: Place) void {
        const l = p.l;
        for (l.o.atoms, 0..) |a, i| {
            if (!l.live[i] or p.place_of[i] != place) continue;
            pos.* = std.mem.alignForward(u64, pos.*, @as(u64, 1) << @intCast(a.align_log2));
            l.addr[i] = pos.*;
            pos.* += a.size;
        }
    }

    /// The sizes of the import tables of the libraries in `p.libs`: the
    /// descriptors, the lookup tables, the address tables, then the hints
    /// and names of the imports and the names of the libraries.
    fn importsSize(p: *const Pe) struct { lookup: u64, iat: u64, names: u64, total: u64 } {
        const o = p.l.o;
        const descriptors = 20 * (p.libs.count() + 1);
        const slots = 8 * (p.imports.count() + p.libs.count());
        var names: u64 = 0;
        for (p.imports.keys()) |im| names += std.mem.alignForward(u64, 2 + o.string(o.imports[im].name).len + 1, 2);
        for (p.libs.keys()) |lib| names += o.string(o.libs[lib]).len + 1;
        // The tables of slots start on a multiple of 8, which a load of a
        // slot on arm64 scales its offset by.
        const lookup = std.mem.alignForward(u64, descriptors, 8);
        const iat = lookup + slots;
        return .{ .lookup = lookup, .iat = iat, .names = iat + slots, .total = iat + slots + names };
    }

    fn section(p: *Pe, name: []const u8, flags: u32, pos: *u64, place: Place) Error!void {
        const start = pos.*;
        p.placeAtoms(pos, place);
        if (pos.* == start) return;
        try p.sects.append(p.gpa, .{ .name = name, .addr = start, .size = pos.* - start, .flags = flags });
        pos.* = std.mem.alignForward(u64, pos.*, section_align);
    }

    fn layout(p: *Pe) Error!void {
        const l = p.l;
        const o = l.o;
        l.base = image_base;
        l.addr = try p.gpa.alloc(u64, o.atoms.len);
        @memset(l.addr, link.no_addr);
        // The headers: MS-DOS, the signature, COFF, the optional header,
        // and at most six section headers.
        p.headers_size = std.mem.alignForward(u64, 64 + 4 + 20 + 240 + 6 * 40, file_align);
        var pos = image_base + std.mem.alignForward(u64, p.headers_size, section_align);
        try p.section(".text", 0x6000_0020, &pos, .text);
        // The constants, then the entries of the function table whose
        // functions are kept.
        const rdata = pos;
        p.placeAtoms(&pos, .rdata);
        const es = entrySize(o.arch);
        for (o.atoms) |a| {
            if (a.kind != .unwind) continue;
            var off: u32 = 0;
            while (off + es <= a.size) : (off += es) {
                if (l.unwindKept(a, off)) p.pdata_count += 1;
            }
        }
        if (p.pdata_count > 0) {
            pos = std.mem.alignForward(u64, pos, 4);
            p.pdata_addr = pos;
            pos += es * p.pdata_count;
        }
        if (pos > rdata) {
            try p.sects.append(p.gpa, .{ .name = ".rdata", .addr = rdata, .size = pos - rdata, .flags = 0x4000_0040 });
            pos = std.mem.alignForward(u64, pos, section_align);
        }
        try p.section(".data", 0xc000_0040, &pos, .data);
        try p.section(".bss", 0xc000_0080, &pos, .bss);
        if (p.imports.count() > 0) {
            const sizes = p.importsSize();
            p.idata.addr = pos;
            p.idata.size = sizes.total;
            pos = std.mem.alignForward(u64, pos + sizes.total, section_align);
        }
        // The slot of each import, in the address table of its library.
        l.import_addr = try p.gpa.alloc(u64, o.imports.len);
        @memset(l.import_addr, 0);
        if (p.imports.count() > 0) {
            var slot = p.idata.addr + p.importsSize().iat;
            for (p.libs.keys()) |lib| {
                for (p.imports.keys()) |im| if (o.imports[im].lib == lib) {
                    l.import_addr[im] = slot;
                    slot += 8;
                };
                slot += 8;
            }
        }
        // The names that the linker defines name the image, and code
        // reaches thread-local variables from the start of the template.
        l.linker_addr = try p.gpa.alloc(u64, o.linker_names.len);
        @memset(l.linker_addr, image_base);
        for (o.atoms, 0..) |a, i| if (l.live[i] and std.mem.eql(u8, o.string(a.name), ".tls")) {
            l.tls.addr = l.addr[i];
        };
        l.end = pos;
    }

    fn rva(addr: u64) Error!u32 {
        return std.math.cast(u32, addr - image_base) orelse error.RelocationOverflow;
    }

    /// The sections in the order of the file, with their offsets there,
    /// the import tables and the base relocations included.
    fn fileLayout(p: *Pe, reloc_size: u64) Error!u64 {
        if (p.imports.count() > 0) try p.sects.append(p.gpa, p.idata);
        if (reloc_size > 0) try p.sects.append(p.gpa, .{ .name = ".reloc", .addr = p.l.end, .size = reloc_size, .flags = 0x4200_0040 });
        var off = p.headers_size;
        for (p.sects.items) |*s| {
            if (s.flags & 0x80 != 0) continue;
            s.raw = off;
            s.raw_size = std.mem.alignForward(u64, s.size, file_align);
            off += s.raw_size;
        }
        return off;
    }

    fn fileOffset(p: *const Pe, addr: u64) usize {
        for (p.sects.items) |s| if (addr >= s.addr and addr < s.addr + s.size) return link.index(s.raw + (addr - s.addr));
        unreachable;
    }

    fn writeImage(p: *Pe) Error![]u8 {
        const l = p.l;
        const o = l.o;
        // Absolute addresses of things in the image get base relocations,
        // which their positions decide before any byte is written.
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            for (o.atomRelocs(a)) |r| {
                if (r.type == abs64(o.arch) and r.target.space != .none and !l.isDropped(i, r.offset)) try p.fixups.append(p.gpa, l.addr[i] + r.offset);
            }
        }
        std.mem.sort(u64, p.fixups.items, {}, std.sort.asc(u64));
        var relocs: std.ArrayList(u8) = .empty;
        defer relocs.deinit(p.gpa);
        try p.baseRelocations(&relocs);
        const file_size = try p.fileLayout(relocs.items.len);
        const out = try p.gpa.alloc(u8, link.index(file_size));
        errdefer p.gpa.free(out);
        @memset(out, 0);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            @memcpy(out[p.fileOffset(l.addr[i])..][0..link.index(a.size)], o.bytes(a));
        }
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            for (o.atomRelocs(a)) |r| {
                const at = l.addr[i] + r.offset;
                const loc = out[p.fileOffset(at)..];
                if (l.isDropped(i, r.offset)) {
                    @memset(loc[0..8], 0);
                    continue;
                }
                try l.apply(r, loc, at);
            }
        }
        if (p.imports.count() > 0) try p.importTables(out);
        if (p.pdata_count > 0) try p.functionTable(out);
        if (relocs.items.len > 0) {
            @memcpy(out[p.fileOffset(l.end)..][0..relocs.items.len], relocs.items);
            p.dirs[@backingInt(Dir.basereloc)] = .{ try rva(l.end), @intCast(relocs.items.len) };
        }
        for (o.atoms, 0..) |a, i| if (l.live[i] and std.mem.eql(u8, o.string(a.name), "_tls_used")) {
            p.dirs[@backingInt(Dir.tls)] = .{ try rva(l.addr[i]), 40 };
        };
        try p.headers(out);
        return out;
    }

    /// The entries of the function table, relocated and sorted by the
    /// start of their functions, as the unwinder of Windows searches it.
    fn functionTable(p: *Pe, out: []u8) Error!void {
        const l = p.l;
        const o = l.o;
        const es = entrySize(o.arch);
        const table = out[p.fileOffset(p.pdata_addr)..][0..link.index(es * p.pdata_count)];
        var k: usize = 0;
        for (o.atoms) |a| {
            if (a.kind != .unwind) continue;
            var off: u32 = 0;
            while (off + es <= a.size) : (off += es) {
                if (!l.unwindKept(a, off)) continue;
                const entry = table[es * k ..][0..es];
                @memcpy(entry, o.bytes(a)[off..][0..es]);
                for (o.atomRelocs(a)) |r| {
                    if (r.offset < off or r.offset >= off + es) continue;
                    try l.apply(r, entry[r.offset - off ..], p.pdata_addr + es * k + (r.offset - off));
                }
                k += 1;
            }
        }
        if (o.arch == .aarch64) sortEntries([2]u32, table) else sortEntries([3]u32, table);
        p.dirs[@backingInt(Dir.exception)] = .{ try rva(p.pdata_addr), @intCast(es * p.pdata_count) };
    }

    fn sortEntries(comptime Entry: type, table: []u8) void {
        const entries = std.mem.bytesAsSlice(Entry, table);
        std.mem.sort(Entry, @alignCast(entries), {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.littleToNative(u32, a[0]) < std.mem.littleToNative(u32, b[0]);
            }
        }.lt);
    }

    /// A block of base relocations for each page of 4 KB that holds an
    /// absolute address, each entry of type DIR64 with its offset in the
    /// page, padded to 4 bytes.
    fn baseRelocations(p: *Pe, out: *std.ArrayList(u8)) Error!void {
        var k: usize = 0;
        while (k < p.fixups.items.len) {
            const page = p.fixups.items[k] & ~@as(u64, 0xfff);
            const start = out.items.len;
            try appendU32(p.gpa, out, try rva(page));
            try appendU32(p.gpa, out, 0);
            while (k < p.fixups.items.len and p.fixups.items[k] & ~@as(u64, 0xfff) == page) : (k += 1) {
                try appendU16(p.gpa, out, @intCast(0xa000 | (p.fixups.items[k] & 0xfff)));
            }
            if ((out.items.len - start) % 4 != 0) try appendU16(p.gpa, out, 0);
            std.mem.writeInt(u32, out.items[start + 4 ..][0..4], @intCast(out.items.len - start), .little);
        }
    }

    /// The import descriptors, one per library and a null one, then for
    /// each library a lookup table and an address table of the hints and
    /// names of its imports, each ended by a null slot.
    fn importTables(p: *Pe, out: []u8) Error!void {
        const o = p.l.o;
        const sizes = p.importsSize();
        const at = p.idata.addr;
        const buf = out[p.fileOffset(at)..][0..link.index(sizes.total)];
        var slot: u64 = 0;
        var name_at = sizes.names;
        for (p.libs.keys(), 0..) |lib, k| {
            const desc = buf[20 * k ..][0..20];
            std.mem.writeInt(u32, desc[0..4], try rva(at + sizes.lookup + slot), .little);
            std.mem.writeInt(u32, desc[16..20], try rva(at + sizes.iat + slot), .little);
            for (p.imports.keys()) |im| {
                if (o.imports[im].lib != lib) continue;
                const name = o.string(o.imports[im].name);
                const hint = try rva(at + name_at);
                std.mem.writeInt(u64, buf[link.index(sizes.lookup + slot)..][0..8], hint, .little);
                std.mem.writeInt(u64, buf[link.index(sizes.iat + slot)..][0..8], hint, .little);
                @memcpy(buf[link.index(name_at + 2)..][0..name.len], name);
                name_at += std.mem.alignForward(u64, 2 + name.len + 1, 2);
                slot += 8;
            }
            slot += 8;
        }
        for (p.libs.keys(), 0..) |lib, k| {
            const name = o.string(o.libs[lib]);
            std.mem.writeInt(u32, buf[20 * k + 12 ..][0..4], try rva(at + name_at), .little);
            @memcpy(buf[link.index(name_at)..][0..name.len], name);
            name_at += name.len + 1;
        }
        p.dirs[@backingInt(Dir.import)] = .{ try rva(at), @intCast(20 * (p.libs.count() + 1)) };
        p.dirs[@backingInt(Dir.iat)] = .{ try rva(at + sizes.iat), @intCast(sizes.names - sizes.iat) };
    }

    fn headers(p: *Pe, out: []u8) Error!void {
        const l = p.l;
        const o = l.o;
        // The MS-DOS header, whose last field points at the signature.
        out[0] = 'M';
        out[1] = 'Z';
        std.mem.writeInt(u32, out[0x3c..][0..4], 64, .little);
        @memcpy(out[64..68], "PE\x00\x00");
        var w: Out = .{ .buf = out, .pos = 68 };
        // The COFF header: AMD64 or ARM64, an executable that handles
        // addresses above 2 GB.
        w.u16s(&.{ if (o.arch == .aarch64) 0xaa64 else 0x8664, @intCast(p.sects.items.len) });
        w.u32s(&.{ 0, 0, 0 });
        w.u16s(&.{ 240, 0x22 });
        // The optional header of PE32+.
        var code: u64 = 0;
        var init: u64 = 0;
        var uninit: u64 = 0;
        for (p.sects.items) |s| {
            if (s.flags & 0x20 != 0) code += s.raw_size else if (s.flags & 0x80 != 0) uninit += std.mem.alignForward(u64, s.size, file_align) else init += s.raw_size;
        }
        const last = p.sects.items[p.sects.items.len - 1];
        const image_size = std.mem.alignForward(u64, last.addr + last.size - image_base, section_align);
        w.u16s(&.{0x20b});
        w.bytes(&.{ 14, 0 });
        w.u32s(&.{ @intCast(code), @intCast(init), @intCast(uninit), try rva(l.addr[o.entry.atom] + o.entry.offset), try rva(p.sects.items[0].addr) });
        w.u64s(&.{image_base});
        w.u32s(&.{ section_align, file_align });
        // Windows 6.0, as the C library requires, or Windows 6.2, the first
        // that runs on arm64.
        const minor: u16 = if (o.arch == .aarch64) 2 else 0;
        w.u16s(&.{ 6, minor, 0, 0, 6, minor });
        w.u32s(&.{ 0, @intCast(image_size), @intCast(p.headers_size), 0 });
        // The console subsystem. HIGH_ENTROPY_VA, DYNAMIC_BASE, NX_COMPAT,
        // and TERMINAL_SERVER_AWARE.
        w.u16s(&.{ 3, 0x8160 });
        // The stack that a Zig executable reserves, 16 MB.
        w.u64s(&.{ 16 << 20, 0x1000, 0x100000, 0x1000 });
        w.u32s(&.{ 0, 16 });
        for (p.dirs) |d| w.u32s(&d);
        for (p.sects.items) |s| {
            var name: [8]u8 = @splat(0);
            @memcpy(name[0..s.name.len], s.name);
            w.bytes(&name);
            w.u32s(&.{ @intCast(s.size), try rva(s.addr), @intCast(s.raw_size), @intCast(s.raw), 0, 0 });
            w.u16s(&.{ 0, 0 });
            w.u32s(&.{s.flags});
        }
        std.debug.assert(w.pos <= p.headers_size);
    }
};

const Out = struct {
    buf: []u8,
    pos: usize,

    fn bytes(w: *Out, b: []const u8) void {
        @memcpy(w.buf[w.pos..][0..b.len], b);
        w.pos += b.len;
    }

    fn u16s(w: *Out, vs: []const u16) void {
        for (vs) |v| {
            std.mem.writeInt(u16, w.buf[w.pos..][0..2], v, .little);
            w.pos += 2;
        }
    }

    fn u32s(w: *Out, vs: []const u32) void {
        for (vs) |v| {
            std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
            w.pos += 4;
        }
    }

    fn u64s(w: *Out, vs: []const u64) void {
        for (vs) |v| {
            std.mem.writeInt(u64, w.buf[w.pos..][0..8], v, .little);
            w.pos += 8;
        }
    }
};

fn appendU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn appendU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

test "PE imports, base relocations, and the entry" {
    const gpa = std.testing.allocator;
    var w: lobj.Writer = .{ .gpa = gpa, .arch = .x86_64, .os = .windows };
    defer w.deinit();
    // main: call ExitProcess through its jump, then a pointer to main.
    const main = try w.atom(.text, 4, &[_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 }, 6, "main");
    try w.reloc(.{ .offset = 1, .type = 2, .target = .{ .index = 1, .space = .atom }, .addend = -4 });
    const exit = try w.import("ExitProcess", "kernel32.dll", false);
    _ = try w.atom(.text, 1, &[_]u8{ 0xff, 0x25, 0, 0, 0, 0 }, 6, "ExitProcess");
    try w.reloc(.{ .offset = 2, .type = 2, .target = exit, .addend = -4 });
    const ptr = try w.atom(.data, 3, &@as([8]u8, @splat(0)), 8, "ptr");
    try w.reloc(.{ .offset = 0, .type = 1, .target = .{ .index = @intCast(main), .space = .atom }, .addend = 0 });
    try w.roots.append(gpa, ptr);
    // Entries of the function table for main and for a dead function,
    // each naming its unwind information.
    const dead = try w.atom(.text, 4, &[_]u8{0xc3}, 1, "dead");
    for ([_]u32{ main, dead }) |f| {
        const info = try w.atom(.rodata, 2, &[_]u8{ 1, 0, 0, 0 }, 4, "unwind info");
        _ = try w.atom(.unwind, 2, &@as([12]u8, @splat(0)), 12, "function table");
        try w.reloc(.{ .offset = 0, .type = lobj.pe_addr32nb, .target = .{ .index = @intCast(f), .space = .atom }, .addend = 0 });
        try w.reloc(.{ .offset = 4, .type = lobj.pe_addr32nb, .target = .{ .index = @intCast(f), .space = .atom }, .addend = 1 });
        try w.reloc(.{ .offset = 8, .type = lobj.pe_addr32nb, .target = .{ .index = @intCast(info), .space = .atom }, .addend = 0 });
    }
    w.entry = .{ .name = try w.string("main"), .atom = main, .offset = 0 };
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
    try std.testing.expectEqualStrings("MZ", img[0..2]);
    const pe_at = std.mem.readInt(u32, img[0x3c..][0..4], .little);
    try std.testing.expectEqualStrings("PE\x00\x00", img[pe_at..][0..4]);
    const opt = pe_at + 24;
    try std.testing.expectEqual(@as(u16, 0x20b), std.mem.readInt(u16, img[opt..][0..2], .little));
    const nsects = std.mem.readInt(u16, img[pe_at + 6 ..][0..2], .little);
    // .text, .rdata with the function table, .data, .idata, and .reloc.
    try std.testing.expectEqual(@as(u16, 5), nsects);
    const shdrs = opt + 240;
    const Hdr = struct { va: u32, raw: u32 };
    var by_name: std.StringHashMapUnmanaged(Hdr) = .empty;
    defer by_name.deinit(gpa);
    for (0..nsects) |k| {
        const h = img[shdrs + 40 * k ..][0..40];
        try by_name.put(gpa, std.mem.sliceTo(h[0..8], 0), .{ .va = std.mem.readInt(u32, h[12..16], .little), .raw = std.mem.readInt(u32, h[20..24], .little) });
    }
    const text = by_name.get(".text").?;
    const data = by_name.get(".data").?;
    const idata = by_name.get(".idata").?;
    const entry = std.mem.readInt(u32, img[opt + 16 ..][0..4], .little);
    try std.testing.expectEqual(text.va, entry);
    // The import descriptor names kernel32.dll and ExitProcess.
    const dirs = opt + 112;
    const imp_rva = std.mem.readInt(u32, img[dirs + 8 ..][0..4], .little);
    try std.testing.expectEqual(idata.va, imp_rva);
    const desc = img[idata.raw..][0..20];
    const name_rva = std.mem.readInt(u32, desc[12..16], .little);
    try std.testing.expectEqualStrings("kernel32.dll", std.mem.sliceTo(img[idata.raw + (name_rva - idata.va) ..], 0));
    const iat_rva = std.mem.readInt(u32, desc[16..20], .little);
    const hint_rva: u32 = @intCast(std.mem.readInt(u64, img[idata.raw + (iat_rva - idata.va) ..][0..8], .little));
    try std.testing.expectEqualStrings("ExitProcess", std.mem.sliceTo(img[idata.raw + (hint_rva - idata.va) + 2 ..], 0));
    // The jump reads the slot of ExitProcess.
    const jump = text.raw + 6;
    const disp = std.mem.readInt(i32, img[jump + 2 ..][0..4], .little);
    try std.testing.expectEqual(@as(i64, iat_rva), @as(i64, text.va + 6 + 6) + disp);
    // The pointer holds the address of main, with a base relocation.
    try std.testing.expectEqual(image_base + text.va, std.mem.readInt(u64, img[data.raw..][0..8], .little));
    const rel_rva = std.mem.readInt(u32, img[dirs + 40 ..][0..4], .little);
    const reloc = by_name.get(".reloc").?;
    try std.testing.expectEqual(reloc.va, rel_rva);
    try std.testing.expectEqual(data.va, std.mem.readInt(u32, img[reloc.raw..][0..4], .little));
    try std.testing.expectEqual(@as(u16, 0xa000), std.mem.readInt(u16, img[reloc.raw + 8 ..][0..2], .little));
    // One entry in the function table, for main, which names the unwind
    // information that main keeps.
    const exc_rva = std.mem.readInt(u32, img[dirs + 24 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, img[dirs + 28 ..][0..4], .little));
    const rdata = by_name.get(".rdata").?;
    const entry_at = rdata.raw + (exc_rva - rdata.va);
    try std.testing.expectEqual(text.va, std.mem.readInt(u32, img[entry_at..][0..4], .little));
    try std.testing.expectEqual(text.va + 1, std.mem.readInt(u32, img[entry_at + 4 ..][0..4], .little));
    try std.testing.expectEqual(rdata.va, std.mem.readInt(u32, img[entry_at + 8 ..][0..4], .little));
}

test "PE on arm64: the jump of an import, base relocations, and thread-local offsets" {
    const gpa = std.testing.allocator;
    var w: lobj.Writer = .{ .gpa = gpa, .arch = .aarch64, .os = .windows };
    defer w.deinit();
    // main: bl ExitProcess, then add x0, x0, :secrel_hi12:v and add x0,
    // x0, :secrel_lo12:v, as code reaches a thread-local variable.
    const main = try w.atom(.text, 2, &[_]u8{ 0x00, 0x00, 0x00, 0x94, 0x00, 0x00, 0x40, 0x91, 0x00, 0x00, 0x00, 0x91 }, 12, "main");
    try w.reloc(.{ .offset = 0, .type = 283, .target = .{ .index = 1, .space = .atom }, .addend = 0 });
    try w.reloc(.{ .offset = 4, .type = lobj.pe_secrel_hi12a, .target = .{ .index = 3, .space = .atom }, .addend = 0x1000 });
    try w.reloc(.{ .offset = 8, .type = lobj.pe_secrel_lo12a, .target = .{ .index = 3, .space = .atom }, .addend = 0x1008 });
    const exit = try w.import("ExitProcess", "kernel32.dll", false);
    // adrp x16, slot; ldr x16, [x16, :lo12:slot]; br x16
    _ = try w.atom(.text, 2, &[_]u8{ 0x10, 0x00, 0x00, 0x90, 0x10, 0x02, 0x40, 0xf9, 0x00, 0x02, 0x1f, 0xd6 }, 12, "ExitProcess");
    try w.reloc(.{ .offset = 0, .type = 275, .target = exit, .addend = 0 });
    try w.reloc(.{ .offset = 4, .type = 286, .target = exit, .addend = 0 });
    const ptr = try w.atom(.data, 3, &@as([8]u8, @splat(0)), 8, "ptr");
    try w.reloc(.{ .offset = 0, .type = 257, .target = .{ .index = @intCast(main), .space = .atom }, .addend = 0 });
    try w.roots.append(gpa, ptr);
    const tls = try w.atom(.data, 3, &@as([0x2000]u8, @splat(0)), 0x2000, ".tls");
    try std.testing.expectEqual(@as(u32, 3), tls);
    // A second library makes the descriptors 60 bytes, which leaves the
    // tables of slots aligned only by the padding after them.
    const beep = try w.import("MessageBeep", "user32.dll", false);
    const ptr2 = try w.atom(.data, 3, &@as([8]u8, @splat(0)), 8, "ptr2");
    try w.reloc(.{ .offset = 0, .type = 257, .target = beep, .addend = 0 });
    try w.roots.append(gpa, ptr2);
    try w.roots.append(gpa, tls);
    // An entry of the function table for main, with packed unwind data.
    _ = try w.atom(.unwind, 2, &[_]u8{ 0, 0, 0, 0, 0x01, 0, 0, 0 }, 8, "function table");
    try w.reloc(.{ .offset = 0, .type = lobj.pe_addr32nb, .target = .{ .index = @intCast(main), .space = .atom }, .addend = 0 });
    w.entry = .{ .name = try w.string("main"), .atom = main, .offset = 0 };
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
    const pe_at = std.mem.readInt(u32, img[0x3c..][0..4], .little);
    try std.testing.expectEqual(@as(u16, 0xaa64), std.mem.readInt(u16, img[pe_at + 4 ..][0..2], .little));
    const opt = pe_at + 24;
    const nsects = std.mem.readInt(u16, img[pe_at + 6 ..][0..2], .little);
    const Hdr = struct { va: u32, raw: u32 };
    var by_name: std.StringHashMapUnmanaged(Hdr) = .empty;
    defer by_name.deinit(gpa);
    for (0..nsects) |k| {
        const h = img[opt + 240 + 40 * k ..][0..40];
        try by_name.put(gpa, std.mem.sliceTo(h[0..8], 0), .{ .va = std.mem.readInt(u32, h[12..16], .little), .raw = std.mem.readInt(u32, h[20..24], .little) });
    }
    const text = by_name.get(".text").?;
    const data = by_name.get(".data").?;
    const idata = by_name.get(".idata").?;
    const dirs = opt + 112;
    const desc = img[idata.raw..][0..20];
    const iat_rva = std.mem.readInt(u32, desc[16..20], .little);
    // bl reaches the jump right after main.
    const insn = struct {
        fn at(b: []const u8, off: usize) u32 {
            return std.mem.readInt(u32, b[off..][0..4], .little);
        }
    }.at;
    try std.testing.expectEqual(@as(u32, 0x94000003), insn(img, text.raw));
    // The thread-local offset 0x1008 splits into 1 << 12 and 8.
    try std.testing.expectEqual(@as(u32, 0x91400400), insn(img, text.raw + 4));
    try std.testing.expectEqual(@as(u32, 0x91002000), insn(img, text.raw + 8));
    try std.testing.expectEqual(@as(u32, 0), iat_rva % 8);
    // The jump finds the slot of ExitProcess from its page and offset.
    const adrp = insn(img, text.raw + 12);
    const pages: i64 = @as(i21, @bitCast(@as(u21, @intCast(((adrp >> 29) & 3) | ((adrp >> 3) & 0x1ffffc)))));
    const ldr = insn(img, text.raw + 16);
    const page: i64 = @intCast((image_base + text.va + 12) & ~@as(u64, 0xfff));
    try std.testing.expectEqual(@as(i64, @intCast(image_base + iat_rva)), page + pages * 4096 + ((ldr >> 10) & 0xfff) * 8);
    // The pointer holds the address of main, with a base relocation.
    try std.testing.expectEqual(image_base + text.va, std.mem.readInt(u64, img[data.raw..][0..8], .little));
    const reloc = by_name.get(".reloc").?;
    try std.testing.expectEqual(data.va, std.mem.readInt(u32, img[reloc.raw..][0..4], .little));
    // One entry of eight bytes, whose packed unwind data stays as it was.
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, img[dirs + 28 ..][0..4], .little));
    const exc_rva = std.mem.readInt(u32, img[dirs + 24 ..][0..4], .little);
    const rdata = by_name.get(".rdata").?;
    const entry_at = rdata.raw + (exc_rva - rdata.va);
    try std.testing.expectEqual(text.va, std.mem.readInt(u32, img[entry_at..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, img[entry_at + 4 ..][0..4], .little));
}
