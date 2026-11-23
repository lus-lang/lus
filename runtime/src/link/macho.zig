//! The Mach-O writer of the linker (`spec/design/aot.md`, "The linker").
//! It lays the kept atoms out as a position-independent executable for
//! macOS or iOS that loads libSystem, starts at `main` through `LC_MAIN`,
//! and carries an ad hoc code signature, as the system linker writes for
//! an unsigned build.
//!
//! `dyld` writes every absolute address when it maps the executable. The
//! linker records each one as a chained fixup: a rebase, which adds the
//! address the executable loads at, or a bind, which names an import. A
//! fixup lives in a writable segment, so constants that hold addresses go
//! to `__DATA_CONST`, which `dyld` makes read only once it has written
//! them. A call to an import goes through a stub that loads the address
//! from the global offset table.

const std = @import("std");
const lobj = @import("lobj.zig");
const link = @import("link.zig");
const Linker = link.Linker;
const Error = link.Error;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The address of the Mach-O header, above the 4 GB of `__PAGEZERO`.
const base: u64 = 0x1_0000_0000;

/// The size of a page that the code signature hashes.
const sig_page = 4096;

/// The identifier of the code signature. `codesign` replaces it when a
/// developer signs the executable for distribution.
const identifier = "lus";

const Sect = struct {
    seg: Seg,
    name: []const u8,
    addr: u64 = 0,
    size: u64 = 0,
    align_log2: u8 = 0,
    flags: u32,
};

const Seg = enum { text, data_const, data };

const Fixup = struct {
    addr: u64,
    kind: union(enum) {
        rebase: u64,
        bind: struct { ordinal: u32, addend: u8 },
    },
};

/// Where an atom goes.
const Place = enum { text, cstring, const_reloc, init, data, thread_vars, tdata, tbss, bss };

/// Writes the executable of `l`. A nonempty `payload`, the bundle of
/// `lus build`, goes into a segment `__LUS` before `__LINKEDIT`, inside
/// what the signature covers.
pub fn write(l: *Linker, payload: []const u8) Error![]u8 {
    var m: MachO = .{ .l = l, .gpa = l.gpa, .payload = payload };
    defer m.deinit();
    return m.run();
}

const MachO = struct {
    l: *Linker,
    gpa: std.mem.Allocator,
    page: u64 = 0x4000,
    place_of: []Place = &.{},
    /// The imports that kept atoms use, in the order of their ordinals.
    imports: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// The imports that kept code calls, each with a stub.
    stubs: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    sects: std.ArrayList(Sect) = .empty,
    stubs_addr: u64 = 0,
    seg_addr: [3]u64 = .{ 0, 0, 0 },
    seg_size: [3]u64 = .{ 0, 0, 0 },
    seg_filesize: [3]u64 = .{ 0, 0, 0 },
    header_size: u64 = 0,
    has_tlv: bool = false,
    payload: []const u8 = "",

    fn deinit(m: *MachO) void {
        m.gpa.free(m.place_of);
        m.imports.deinit(m.gpa);
        m.stubs.deinit(m.gpa);
        m.fixups.deinit(m.gpa);
        m.sects.deinit(m.gpa);
    }

    fn isBranch(ty: u32) bool {
        return ty == 282 or ty == 283;
    }

    /// Sorts the kept atoms into sections and finds the imports, the
    /// stubs, and the slots of the global offset table they need.
    fn classify(m: *MachO) Error!void {
        const l = m.l;
        const o = l.o;
        if (o.arch != .aarch64) return error.UnsupportedTarget;
        m.place_of = try m.gpa.alloc(Place, o.atoms.len);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i]) continue;
            var fixed = false;
            for (o.atomRelocs(a)) |r| {
                if (l.isDropped(i, r.offset)) continue;
                if (r.type == 257 and r.target.space != .none) fixed = true;
                if (r.target.space == .import) {
                    if (l.usesGot(r.type) != null or r.type == 257) {
                        try m.imports.put(m.gpa, r.target.index, {});
                    } else if (isBranch(r.type)) {
                        try m.imports.put(m.gpa, r.target.index, {});
                        try m.stubs.put(m.gpa, r.target.index, {});
                    } else {
                        std.log.err("{s}: relocation type {d} names the import {s}", .{ o.string(a.name), r.type, o.string(o.imports[r.target.index].name) });
                        return error.UnsupportedRelocation;
                    }
                }
                if (l.usesGot(r.type)) |tls| try l.got.put(m.gpa, .{ .target = r.target, .sym = r.sym, .tls = tls }, {});
            }
            m.place_of[i] = switch (a.kind) {
                .text => .text,
                .rodata => if (fixed) .const_reloc else .cstring,
                .init_array => .init,
                .data => .data,
                .thread_vars => .thread_vars,
                .tdata => .tdata,
                .tbss => .tbss,
                .bss => .bss,
                .fini_array => {
                    std.log.err("{s}: functions that run at exit are not supported on Mach-O", .{o.string(a.name)});
                    return error.UnsupportedTarget;
                },
            };
            if (a.kind == .thread_vars) m.has_tlv = true;
        }
        // Each stub loads the address of its import from the global
        // offset table.
        for (m.stubs.keys()) |im| try l.got.put(m.gpa, .{ .target = .{ .index = @intCast(im), .space = .import }, .sym = 0, .tls = false }, {});
    }

    fn placeAtoms(m: *MachO, pos: *u64, p: Place) u8 {
        const l = m.l;
        var al: u8 = 0;
        for (l.o.atoms, 0..) |a, i| {
            if (!l.live[i] or m.place_of[i] != p) continue;
            al = @max(al, a.align_log2);
            pos.* = std.mem.alignForward(u64, pos.*, @as(u64, 1) << @intCast(a.align_log2));
            l.addr[i] = pos.*;
            pos.* += a.size;
        }
        return al;
    }

    fn any(m: *const MachO, p: Place) bool {
        for (m.l.live, m.place_of) |live, q| if (live and q == p) return true;
        return false;
    }

    /// Adds a section of atoms of `p`, laid out from `pos`.
    fn section(m: *MachO, seg: Seg, name: []const u8, flags: u32, pos: *u64, p: Place) Error!void {
        if (!m.any(p)) return;
        var start = pos.*;
        var probe = start;
        const al = m.placeAtoms(&probe, p);
        start = std.mem.alignForward(u64, start, @as(u64, 1) << @intCast(al));
        pos.* = start;
        _ = m.placeAtoms(pos, p);
        try m.sects.append(m.gpa, .{ .seg = seg, .name = name, .addr = start, .size = pos.* - start, .align_log2 = al, .flags = flags });
    }

    fn layout(m: *MachO) Error!void {
        const l = m.l;
        const o = l.o;
        l.addr = try m.gpa.alloc(u64, o.atoms.len);
        @memset(l.addr, link.no_addr);
        m.header_size = 32 + m.commandsSize();
        // __TEXT: the header, the code, the stubs, and the constants.
        var pos = base + m.header_size;
        try m.section(.text, "__text", 0x8000_0400, &pos, .text);
        if (m.stubs.count() > 0) {
            pos = std.mem.alignForward(u64, pos, 4);
            m.stubs_addr = pos;
            try m.sects.append(m.gpa, .{ .seg = .text, .name = "__stubs", .addr = pos, .size = 12 * m.stubs.count(), .align_log2 = 2, .flags = 0x8000_0400 });
            pos += 12 * m.stubs.count();
        }
        try m.section(.text, "__const", 0, &pos, .cstring);
        m.seg_addr[0] = base;
        m.seg_size[0] = std.mem.alignForward(u64, pos - base, m.page);
        m.seg_filesize[0] = m.seg_size[0];
        // __DATA_CONST: the global offset table, the constants that hold
        // addresses, and the initializers.
        pos = base + m.seg_size[0];
        const dc = pos;
        if (l.got.count() > 0) {
            l.got_addr = pos;
            try m.sects.append(m.gpa, .{ .seg = .data_const, .name = "__got", .addr = pos, .size = 8 * l.got.count(), .align_log2 = 3, .flags = 0 });
            pos += 8 * l.got.count();
        }
        try m.section(.data_const, "__const", 0, &pos, .const_reloc);
        try m.section(.data_const, "__mod_init_func", 0x9, &pos, .init);
        m.seg_addr[1] = dc;
        m.seg_size[1] = std.mem.alignForward(u64, pos - dc, m.page);
        m.seg_filesize[1] = m.seg_size[1];
        // __DATA: the data, the descriptors of thread-local variables, the
        // template of thread-local data, then the zeroed data.
        pos = dc + m.seg_size[1];
        const d = pos;
        try m.section(.data, "__data", 0, &pos, .data);
        try m.section(.data, "__thread_vars", 0x13, &pos, .thread_vars);
        // Thread-local atoms get offsets in the template, which starts
        // at its alignment.
        var tls_align: u8 = 0;
        for (o.atoms, 0..) |a, i| if (l.live[i] and (a.kind == .tdata or a.kind == .tbss)) {
            tls_align = @max(tls_align, a.align_log2);
        };
        pos = std.mem.alignForward(u64, pos, @as(u64, 1) << @intCast(tls_align));
        const tls_start = pos;
        var tpos: u64 = 0;
        _ = m.placeAtoms(&tpos, .tdata);
        const tdata_size = tpos;
        if (tdata_size > 0) try m.sects.append(m.gpa, .{ .seg = .data, .name = "__thread_data", .addr = tls_start, .size = tdata_size, .align_log2 = tls_align, .flags = 0x11 });
        var tbss_start = tpos;
        var first_tbss = true;
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or a.kind != .tbss) continue;
            tpos = std.mem.alignForward(u64, tpos, @as(u64, 1) << @intCast(a.align_log2));
            if (first_tbss) tbss_start = tpos;
            first_tbss = false;
            l.addr[i] = tpos;
            tpos += a.size;
        }
        if (tpos > tbss_start) try m.sects.append(m.gpa, .{ .seg = .data, .name = "__thread_bss", .addr = tls_start + tbss_start, .size = tpos - tbss_start, .align_log2 = tls_align, .flags = 0x12 });
        l.tls = .{ .addr = tls_start, .filesz = tdata_size, .memsz = tpos, .align_ = @as(u64, 1) << @intCast(tls_align) };
        const file_end = tls_start + tdata_size;
        pos = tls_start + tpos;
        try m.section(.data, "__bss", 0x1, &pos, .bss);
        m.seg_addr[2] = d;
        m.seg_size[2] = std.mem.alignForward(u64, @max(pos, d + 1) - d, m.page);
        m.seg_filesize[2] = std.mem.alignForward(u64, file_end - d, m.page);
        // The stubs of imports, and the names the linker defines: both
        // name the Mach-O header.
        l.import_addr = try m.gpa.alloc(u64, o.imports.len);
        @memset(l.import_addr, 0);
        for (m.stubs.keys(), 0..) |im, k| l.import_addr[im] = m.stubs_addr + 12 * k;
        l.linker_addr = try m.gpa.alloc(u64, o.linker_names.len);
        @memset(l.linker_addr, base);
    }

    fn segOf(m: *const MachO, addr: u64) ?Seg {
        for (0..3) |k| if (addr >= m.seg_addr[k] and addr < m.seg_addr[k] + m.seg_size[k]) return @fromBackingInt(@intCast(k));
        return null;
    }

    fn fixup(m: *MachO, addr: u64, kind: @FieldType(Fixup, "kind")) Error!void {
        const seg = m.segOf(addr) orelse return error.RelocationOverflow;
        if (seg == .text or addr % 4 != 0) {
            std.log.err("an absolute address at 0x{x} outside the writable segments", .{addr});
            return error.UnsupportedRelocation;
        }
        try m.fixups.append(m.gpa, .{ .addr = addr, .kind = kind });
    }

    fn ordinal(m: *const MachO, im: u32) u32 {
        return @intCast(m.imports.getIndex(im).?);
    }

    /// The fixup of an address of `t` plus `add`, or its value when it
    /// needs none.
    fn pointer(m: *MachO, out: []u8, addr: u64, t: lobj.Target, sym: u32, add: i64) Error!void {
        const l = m.l;
        const loc = out[link.index(addr - base)..][0..8];
        switch (t.space) {
            .none => std.mem.writeInt(u64, loc, sym +% @as(u64, @bitCast(add)), .little),
            .import => {
                const a = std.math.cast(u8, @as(i64, sym) + add) orelse return error.RelocationOverflow;
                try m.fixup(addr, .{ .bind = .{ .ordinal = m.ordinal(t.index), .addend = a } });
            },
            else => try m.fixup(addr, .{ .rebase = l.symbol(t, sym) +% @as(u64, @bitCast(add)) }),
        }
    }

    fn fileSize(m: *const MachO) u64 {
        return m.seg_addr[2] - base + m.seg_filesize[2];
    }

    fn writeSegments(m: *MachO) Error![]u8 {
        const l = m.l;
        const o = l.o;
        const out = try m.gpa.alloc(u8, link.index(m.fileSize()));
        errdefer m.gpa.free(out);
        @memset(out, 0);
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const at = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            @memcpy(out[link.index(at - base)..][0..link.index(a.size)], o.bytes(a));
        }
        for (l.got.keys(), 0..) |k, i| try m.pointer(out, l.got_addr + 8 * i, k.target, k.sym, 0);
        // A stub: adrp x16, slot@PAGE; ldr x16, [x16, slot@PAGEOFF];
        // br x16.
        for (m.stubs.keys(), 0..) |im, k| {
            const at = m.stubs_addr + 12 * k;
            const loc = out[link.index(at - base)..][0..12];
            std.mem.writeInt(u32, loc[0..4], 0x9000_0010, .little);
            std.mem.writeInt(u32, loc[4..8], 0xf940_0210, .little);
            std.mem.writeInt(u32, loc[8..12], 0xd61f_0200, .little);
            const slot = l.gotSlot(.{ .offset = 0, .type = 0, .target = .{ .index = @intCast(im), .space = .import }, .addend = 0 }, false);
            try l.apply(.{ .offset = 0, .type = 275, .target = .none_target, .sym = @intCast(slot - base), .addend = @intCast(base) }, loc[0..], at);
            try l.apply(.{ .offset = 0, .type = 286, .target = .none_target, .sym = @intCast(slot - base), .addend = @intCast(base) }, loc[4..], at + 4);
        }
        for (o.atoms, 0..) |a, i| {
            if (!l.live[i] or lobj.zeroed(a.kind)) continue;
            const at = if (a.kind == .tdata) l.tls.addr + l.addr[i] else l.addr[i];
            for (o.atomRelocs(a)) |r| {
                const p = at + r.offset;
                const loc = out[link.index(p - base)..];
                if (l.isDropped(i, r.offset)) {
                    @memset(loc[0..8], 0);
                    continue;
                }
                switch (r.type) {
                    257 => try m.pointer(out, p, r.target, r.sym, r.addend),
                    // The offset of a thread-local variable in the
                    // template, in its descriptor.
                    1028 => std.mem.writeInt(u64, loc[0..8], l.symbol(r.target, r.sym) +% @as(u64, @bitCast(r.addend)), .little),
                    258 => if (r.target.space != .none) {
                        std.log.err("{s}: a 32-bit absolute address in a position-independent executable", .{o.string(a.name)});
                        return error.UnsupportedRelocation;
                    } else try l.apply(r, loc, p),
                    else => try l.apply(r, loc, p),
                }
            }
        }
        return out;
    }

    /// The chained fixups of `dyld` (`<mach-o/fixup-chains.h>`), in the
    /// pointer format `DYLD_CHAINED_PTR_64_OFFSET`.
    fn chainedFixups(m: *MachO, out: []u8, blob: *std.ArrayList(u8)) Error!void {
        const gpa = m.gpa;
        const o = m.l.o;
        std.mem.sort(Fixup, m.fixups.items, {}, struct {
            fn lt(_: void, a: Fixup, b: Fixup) bool {
                return a.addr < b.addr;
            }
        }.lt);
        // Each fixup links to the next one on its page, in strides of 4
        // bytes.
        for (m.fixups.items, 0..) |f, k| {
            var next: u64 = 0;
            if (k + 1 < m.fixups.items.len) {
                const n = m.fixups.items[k + 1];
                const seg = @backingInt(m.segOf(f.addr).?);
                if (m.segOf(n.addr).? == m.segOf(f.addr).? and (n.addr - m.seg_addr[seg]) / m.page == (f.addr - m.seg_addr[seg]) / m.page) next = (n.addr - f.addr) / 4;
            }
            const v: u64 = switch (f.kind) {
                .rebase => |t| blk: {
                    const off = t -% base;
                    if (off >= 1 << 36) return error.RelocationOverflow;
                    break :blk off | next << 51;
                },
                .bind => |b| @as(u64, b.ordinal) | @as(u64, b.addend) << 24 | next << 51 | 1 << 63,
            };
            std.mem.writeInt(u64, out[link.index(f.addr - base)..][0..8], v, .little);
        }
        const nsegs = m.segCount();
        // dyld_chained_fixups_header, then dyld_chained_starts_in_image.
        try blob.appendNTimes(gpa, 0, 32);
        const starts = blob.items.len;
        try appendU32(gpa, blob, @intCast(nsegs));
        const seg_offsets = blob.items.len;
        try blob.appendNTimes(gpa, 0, 4 * nsegs);
        for (0..3) |k| {
            const seg: Seg = @fromBackingInt(@intCast(k));
            const idx = m.segIndex(seg) orelse continue;
            var has = false;
            for (m.fixups.items) |f| if (m.segOf(f.addr).? == seg) {
                has = true;
            };
            if (!has) continue;
            while (blob.items.len % 8 != 0) try blob.append(gpa, 0);
            std.mem.writeInt(u32, blob.items[seg_offsets + 4 * idx ..][0..4], @intCast(blob.items.len - starts), .little);
            const pages = m.seg_size[k] / m.page;
            try appendU32(gpa, blob, @intCast(22 + 2 * pages));
            try appendU16(gpa, blob, @intCast(m.page));
            try appendU16(gpa, blob, 6); // DYLD_CHAINED_PTR_64_OFFSET
            try appendU64(gpa, blob, m.seg_addr[k] - base);
            try appendU32(gpa, blob, 0);
            try appendU16(gpa, blob, @intCast(pages));
            const page_starts = blob.items.len;
            try blob.appendNTimes(gpa, 0xff, 2 * pages);
            var last_page: ?u64 = null;
            for (m.fixups.items) |f| {
                if (m.segOf(f.addr).? != seg) continue;
                const pg = (f.addr - m.seg_addr[k]) / m.page;
                if (last_page == pg) continue;
                last_page = pg;
                std.mem.writeInt(u16, blob.items[page_starts + 2 * pg ..][0..2], @intCast((f.addr - m.seg_addr[k]) % m.page), .little);
            }
        }
        while (blob.items.len % 4 != 0) try blob.append(gpa, 0);
        const imports_off = blob.items.len;
        try blob.appendNTimes(gpa, 0, 4 * m.imports.count());
        const symbols_off = blob.items.len;
        for (m.imports.keys(), 0..) |im, k| {
            const imp = o.imports[im];
            const name_off = blob.items.len - symbols_off;
            if (name_off >= 1 << 23) return error.RelocationOverflow;
            const lib_ordinal: u32 = @as(u32, imp.lib) + 1;
            const v: u32 = lib_ordinal | @as(u32, imp.weak) << 8 | @as(u32, @intCast(name_off)) << 9;
            std.mem.writeInt(u32, blob.items[imports_off + 4 * k ..][0..4], v, .little);
            try blob.append(gpa, '_');
            try blob.appendSlice(gpa, o.string(imp.name));
            try blob.append(gpa, 0);
        }
        const h = blob.items[0..28];
        std.mem.writeInt(u32, h[0..4], 0, .little);
        std.mem.writeInt(u32, h[4..8], @intCast(starts), .little);
        std.mem.writeInt(u32, h[8..12], @intCast(imports_off), .little);
        std.mem.writeInt(u32, h[12..16], @intCast(symbols_off), .little);
        std.mem.writeInt(u32, h[16..20], @intCast(m.imports.count()), .little);
        std.mem.writeInt(u32, h[20..24], 1, .little); // DYLD_CHAINED_IMPORT
        std.mem.writeInt(u32, h[24..28], 0, .little);
        while (blob.items.len % 8 != 0) try blob.append(gpa, 0);
    }

    /// The segments in the order of their load commands: `__PAGEZERO`,
    /// `__TEXT`, then `__DATA_CONST` and `__DATA` when they hold
    /// sections, then `__LINKEDIT`.
    fn segCount(m: *const MachO) usize {
        var n: usize = 3;
        if (m.payload.len > 0) n += 1;
        if (m.segHasSects(.data_const)) n += 1;
        if (m.segHasSects(.data)) n += 1;
        return n;
    }

    fn segHasSects(m: *const MachO, seg: Seg) bool {
        if (seg == .text) return true;
        if (m.sects.items.len > 0) {
            for (m.sects.items) |s| if (s.seg == seg) return true;
            return false;
        }
        return m.planned(seg) > 0;
    }

    fn segIndex(m: *const MachO, seg: Seg) ?usize {
        if (!m.segHasSects(seg)) return null;
        return switch (seg) {
            .text => 1,
            .data_const => 2,
            .data => if (m.segHasSects(.data_const)) 3 else 2,
        };
    }

    /// The number of sections a segment gets, known before the layout.
    fn planned(m: *const MachO, seg: Seg) usize {
        const l = m.l;
        var n: usize = 0;
        switch (seg) {
            .text => {
                n += one(m.any(.text)) + one(m.stubs.count() > 0) + one(m.any(.cstring));
            },
            .data_const => {
                n += one(l.got.count() > 0) + one(m.any(.const_reloc)) + one(m.any(.init));
            },
            .data => {
                n += one(m.any(.data)) + one(m.any(.thread_vars)) + one(m.any(.tdata)) + one(m.any(.tbss)) + one(m.any(.bss));
            },
        }
        return n;
    }

    fn libCommandSize(name: []const u8) u64 {
        return std.mem.alignForward(u64, 24 + name.len + 1, 8);
    }

    /// The size of the load commands, which the layout needs before it
    /// knows any address.
    fn commandsSize(m: *const MachO) u64 {
        const o = m.l.o;
        var n: u64 = 0;
        n += 72; // __PAGEZERO
        for ([_]Seg{ .text, .data_const, .data }) |seg| {
            const k = m.planned(seg);
            if (seg != .text and k == 0) continue;
            n += 72 + 80 * k;
        }
        if (m.payload.len > 0) n += 72 + 80; // __LUS
        n += 72; // __LINKEDIT
        n += 16 + 16 + 24 + 80; // chained fixups, exports trie, symtab, dysymtab
        n += 32 + 24 + 24 + 16 + 24; // dylinker, uuid, build version, source version, main
        for (o.libs) |lib| n += libCommandSize(o.string(lib));
        n += 16; // code signature
        return n;
    }

    fn run(m: *MachO) Error![]u8 {
        const l = m.l;
        const o = l.o;
        if (o.arch == .x86_64) m.page = 0x1000;
        try m.classify();
        try m.layout();
        const segs = try m.writeSegments();
        defer m.gpa.free(segs);
        // __LINKEDIT: the chained fixups, the exports trie, an empty
        // symbol table, then the code signature.
        var le: std.ArrayList(u8) = .empty;
        defer le.deinit(m.gpa);
        try m.chainedFixups(segs, &le);
        const fixups_size = le.items.len;
        const trie_off = le.items.len;
        try m.exportsTrie(&le);
        const trie_size = le.items.len - trie_off;
        const str_off = le.items.len;
        try le.appendNTimes(m.gpa, 0, 8);
        while (le.items.len % 16 != 0) try le.append(m.gpa, 0);
        const lus_size = std.mem.alignForward(u64, m.payload.len, m.page);
        const linkedit_off = segs.len + lus_size;
        const sig_off = linkedit_off + le.items.len;
        const n_pages = std.math.divCeil(u64, sig_off, sig_page) catch unreachable;
        const sig_size = std.mem.alignForward(u64, 12 + 8 + 88 + identifier.len + 1 + 32 * n_pages, 16);
        const total = sig_off + sig_size;
        const out = try m.gpa.alloc(u8, link.index(total));
        errdefer m.gpa.free(out);
        @memset(out, 0);
        @memcpy(out[0..segs.len], segs);
        @memcpy(out[segs.len..][0..m.payload.len], m.payload);
        @memcpy(out[link.index(linkedit_off)..][0..le.items.len], le.items);
        const linkedit_size = total - linkedit_off;
        try m.headers(out, .{
            .linkedit_off = linkedit_off,
            .linkedit_size = linkedit_size,
            .fixups_off = linkedit_off,
            .fixups_size = fixups_size,
            .trie_off = linkedit_off + trie_off,
            .trie_size = trie_size,
            .str_off = linkedit_off + str_off,
            .sig_off = sig_off,
            .sig_size = sig_size,
        });
        sign(out, sig_off, m.seg_filesize[0]);
        return out;
    }

    /// The exports trie: the Mach-O header as `__mh_execute_header`.
    fn exportsTrie(m: *MachO, le: *std.ArrayList(u8)) Error!void {
        const name = "__mh_execute_header";
        const child: u8 = 1 + 1 + name.len + 1 + 1;
        try le.appendSlice(m.gpa, &.{ 0, 1 });
        try le.appendSlice(m.gpa, name);
        try le.appendSlice(m.gpa, &.{ 0, child });
        // The terminal of the child: flags 0, offset 0, no children.
        try le.appendSlice(m.gpa, &.{ 2, 0, 0, 0 });
        while (le.items.len % 8 != 0) try le.append(m.gpa, 0);
    }

    const Linkedit = struct {
        linkedit_off: u64,
        linkedit_size: u64,
        fixups_off: u64,
        fixups_size: u64,
        trie_off: u64,
        trie_size: u64,
        str_off: u64,
        sig_off: u64,
        sig_size: u64,
    };

    fn headers(m: *MachO, out: []u8, le: Linkedit) Error!void {
        const l = m.l;
        const o = l.o;
        var w: Cmds = .{ .buf = out[32..link.index(m.header_size)] };
        var ncmds: u32 = 0;
        // __PAGEZERO.
        w.segment("__PAGEZERO", 0, base, 0, 0, 0, 0, 0, 0);
        ncmds += 1;
        for ([_]Seg{ .text, .data_const, .data }, [_][]const u8{ "__TEXT", "__DATA_CONST", "__DATA" }, 0..) |seg, name, k| {
            if (!m.segHasSects(seg)) continue;
            var nsects: u32 = 0;
            for (m.sects.items) |s| nsects += @intFromBool(s.seg == seg);
            const prot: u32 = if (seg == .text) 5 else 3;
            const flags: u32 = if (seg == .data_const) 0x10 else 0; // SG_READ_ONLY
            w.segment(name, m.seg_addr[k], m.seg_size[k], m.seg_addr[k] - base, m.seg_filesize[k], prot, prot, nsects, flags);
            for (m.sects.items) |s| {
                if (s.seg != seg) continue;
                const zerofill = s.flags == 0x1 or s.flags == 0x12;
                w.sect(s.name, name, s.addr, s.size, if (zerofill) 0 else @intCast(s.addr - base), s.align_log2, s.flags);
            }
            ncmds += 1;
        }
        // __LUS: the bundle, after the file part of __DATA.
        const lus_addr = base + m.seg_size[0] + m.seg_size[1] + m.seg_size[2];
        const lus_off = m.seg_addr[2] - base + m.seg_filesize[2];
        const lus_size = std.mem.alignForward(u64, m.payload.len, m.page);
        if (m.payload.len > 0) {
            w.segment("__LUS", lus_addr, lus_size, lus_off, lus_size, 1, 1, 1, 0);
            w.sect("__bundle", "__LUS", lus_addr, m.payload.len, @intCast(lus_off), 0, 0);
            ncmds += 1;
        }
        w.segment("__LINKEDIT", lus_addr + lus_size, std.mem.alignForward(u64, le.linkedit_size, m.page), le.linkedit_off, le.linkedit_size, 1, 1, 0, 0);
        ncmds += 1;
        w.linkeditData(0x8000_0034, le.fixups_off, le.fixups_size); // LC_DYLD_CHAINED_FIXUPS
        w.linkeditData(0x8000_0033, le.trie_off, le.trie_size); // LC_DYLD_EXPORTS_TRIE
        // LC_SYMTAB with no symbols, and LC_DYSYMTAB.
        w.u32s(&.{ 0x2, 24, 0, 0, @intCast(le.str_off), 8 });
        w.u32s(&.{ 0xb, 80 });
        w.zeros(72);
        ncmds += 4;
        // LC_LOAD_DYLINKER.
        w.u32s(&.{ 0xe, 32, 12 });
        w.str("/usr/lib/dyld", 20);
        // LC_UUID, filled from the hash of the file below.
        const uuid_at = w.pos + 8;
        w.u32s(&.{ 0x1b, 24 });
        w.zeros(16);
        // LC_BUILD_VERSION: macOS 11 or iOS 15, without tools.
        const platform: u32, const minos: u32 = if (o.os == .ios) .{ 2, 15 << 16 } else .{ 1, 11 << 16 };
        w.u32s(&.{ 0x32, 24, platform, minos, minos, 0 });
        // LC_SOURCE_VERSION.
        w.u32s(&.{ 0x2a, 16, 0, 0 });
        // LC_MAIN.
        const entry = l.addr[o.entry.atom] + o.entry.offset;
        w.u32s(&.{ 0x8000_0028, 24 });
        w.u64s(&.{ entry - base, 0 });
        ncmds += 5;
        for (o.libs) |lib| {
            const name = o.string(lib);
            const size: u32 = @intCast(libCommandSize(name));
            // LC_LOAD_DYLIB: libSystem 1351.0.0, compatible with 1.0.0.
            w.u32s(&.{ 0xc, size, 24, 2, 1351 << 16, 1 << 16 });
            w.str(name, size - 24);
            ncmds += 1;
        }
        w.linkeditData(0x1d, le.sig_off, le.sig_size); // LC_CODE_SIGNATURE
        ncmds += 1;
        std.debug.assert(w.pos == w.buf.len);
        // mach_header_64.
        const cpu: u32 = if (o.arch == .x86_64) 0x0100_0007 else 0x0100_000c;
        const subtype: u32 = if (o.arch == .x86_64) 3 else 0;
        // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE, and
        // MH_HAS_TLV_DESCRIPTORS when there are thread-local variables.
        var flags: u32 = 0x1 | 0x4 | 0x80 | 0x20_0000;
        if (m.has_tlv) flags |= 0x80_0000;
        const h = [_]u32{ 0xfeedfacf, cpu, subtype, 2, ncmds, @intCast(m.header_size - 32), flags, 0 };
        for (h, 0..) |v, k| std.mem.writeInt(u32, out[4 * k ..][0..4], v, .little);
        var digest: [32]u8 = undefined;
        Sha256.hash(out[0..link.index(le.sig_off)], &digest, .{});
        digest[6] = (digest[6] & 0x0f) | 0x40;
        digest[8] = (digest[8] & 0x3f) | 0x80;
        @memcpy(out[32 + uuid_at ..][0..16], digest[0..16]);
    }
};

/// Writes load commands into the space after the Mach-O header.
const Cmds = struct {
    buf: []u8,
    pos: usize = 0,

    fn u32s(w: *Cmds, vs: []const u32) void {
        for (vs) |v| {
            std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
            w.pos += 4;
        }
    }

    fn u64s(w: *Cmds, vs: []const u64) void {
        for (vs) |v| {
            std.mem.writeInt(u64, w.buf[w.pos..][0..8], v, .little);
            w.pos += 8;
        }
    }

    fn zeros(w: *Cmds, n: usize) void {
        @memset(w.buf[w.pos..][0..n], 0);
        w.pos += n;
    }

    fn str(w: *Cmds, s: []const u8, field: usize) void {
        @memset(w.buf[w.pos..][0..field], 0);
        @memcpy(w.buf[w.pos..][0..s.len], s);
        w.pos += field;
    }

    fn segment(w: *Cmds, name: []const u8, vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64, maxprot: u32, initprot: u32, nsects: u32, flags: u32) void {
        w.u32s(&.{ 0x19, 72 + 80 * nsects });
        w.str(name, 16);
        w.u64s(&.{ vmaddr, vmsize, fileoff, filesize });
        w.u32s(&.{ maxprot, initprot, nsects, flags });
    }

    fn sect(w: *Cmds, name: []const u8, seg: []const u8, addr: u64, size: u64, offset: u32, align_log2: u8, flags: u32) void {
        w.str(name, 16);
        w.str(seg, 16);
        w.u64s(&.{ addr, size });
        w.u32s(&.{ offset, align_log2, 0, 0, flags, 0, 0, 0 });
    }

    fn linkeditData(w: *Cmds, cmd: u32, off: u64, size: u64) void {
        w.u32s(&.{ cmd, 16, @intCast(off), @intCast(size) });
    }
};

/// Writes the ad hoc code signature at `sig_off`: a superblob that holds
/// one code directory, with the SHA-256 hash of each page of the file
/// before it. The flags mark it as signed ad hoc by the linker, as the
/// system linker signs an executable that nobody signed.
fn sign(out: []u8, sig_off: u64, text_size: u64) void {
    const n_pages = std.math.divCeil(u64, sig_off, sig_page) catch unreachable;
    const cd_size: u32 = @intCast(88 + identifier.len + 1 + 32 * n_pages);
    const sb = out[link.index(sig_off)..];
    const be = std.builtin.Endian.big;
    std.mem.writeInt(u32, sb[0..4], 0xfade0cc0, be); // CSMAGIC_EMBEDDED_SIGNATURE
    std.mem.writeInt(u32, sb[4..8], 20 + cd_size, be);
    std.mem.writeInt(u32, sb[8..12], 1, be);
    std.mem.writeInt(u32, sb[12..16], 0, be); // CSSLOT_CODEDIRECTORY
    std.mem.writeInt(u32, sb[16..20], 20, be);
    const cd = sb[20..];
    const hash_off: u32 = @intCast(88 + identifier.len + 1);
    const words = [_]u32{
        0xfade0c02, // CSMAGIC_CODEDIRECTORY
        cd_size,
        0x20400, // the version with the executable segment
        0x2 | 0x20000, // CS_ADHOC | CS_LINKER_SIGNED
        hash_off,
        88, // the identifier
        0, // special slots
        @intCast(n_pages),
        @intCast(sig_off),
    };
    for (words, 0..) |v, k| std.mem.writeInt(u32, cd[4 * k ..][0..4], v, be);
    cd[36] = 32; // hash size
    cd[37] = 2; // CS_HASHTYPE_SHA256
    cd[38] = 0; // platform
    cd[39] = 12; // log2 of the page size
    @memset(cd[40..56], 0); // spare2, scatter, team, spare3
    std.mem.writeInt(u64, cd[56..64], 0, be); // codeLimit64
    std.mem.writeInt(u64, cd[64..72], 0, be); // execSegBase
    std.mem.writeInt(u64, cd[72..80], text_size, be); // execSegLimit
    std.mem.writeInt(u64, cd[80..88], 1, be); // CS_EXECSEG_MAIN_BINARY
    @memcpy(cd[88..][0..identifier.len], identifier);
    cd[88 + identifier.len] = 0;
    for (0..n_pages) |k| {
        const start = k * sig_page;
        const end = @min(start + sig_page, sig_off);
        Sha256.hash(out[link.index(start)..link.index(end)], cd[hash_off + 32 * k ..][0..32], .{});
    }
}

fn one(b: bool) usize {
    return @intFromBool(b);
}

fn appendU16(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: u16) !void {
    var x: [2]u8 = undefined;
    std.mem.writeInt(u16, &x, v, .little);
    try b.appendSlice(gpa, &x);
}

fn appendU32(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: u32) !void {
    var x: [4]u8 = undefined;
    std.mem.writeInt(u32, &x, v, .little);
    try b.appendSlice(gpa, &x);
}

fn appendU64(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: u64) !void {
    var x: [8]u8 = undefined;
    std.mem.writeInt(u64, &x, v, .little);
    try b.appendSlice(gpa, &x);
}

test "a Mach-O executable binds its imports and rebases its pointers" {
    const gpa = std.testing.allocator;
    var w: lobj.Writer = .{ .gpa = gpa, .arch = .aarch64, .os = .macos };
    defer w.deinit();
    // main: bl exit, then a pointer to main and a pointer to exit.
    const main = try w.atom(.text, 2, &[_]u8{ 0, 0, 0, 0x94 }, 4, "main");
    const exit = try w.import("exit", "/usr/lib/libSystem.B.dylib", false);
    try w.reloc(.{ .offset = 0, .type = 283, .target = exit, .addend = 0 });
    const ptrs = try w.atom(.data, 3, &@as([16]u8, @splat(0)), 16, "ptrs");
    try w.reloc(.{ .offset = 0, .type = 257, .target = .{ .index = @intCast(main), .space = .atom }, .addend = 0 });
    try w.reloc(.{ .offset = 8, .type = 257, .target = exit, .addend = 0 });
    try w.roots.append(gpa, ptrs);
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
    const out = r.bytes;
    try std.testing.expectEqual(@as(u32, 0xfeedfacf), std.mem.readInt(u32, out[0..4], .little));
    // The call reaches the stub, which loads the slot of exit.
    const text = 32 + std.mem.readInt(u32, out[20..24], .little);
    const bl = std.mem.readInt(u32, out[text..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0x94), bl >> 24);
    const stub = text + 4 * (bl & 0x3ff_ffff);
    try std.testing.expectEqual(@as(u32, 0xd61f_0200), std.mem.readInt(u32, out[stub + 8 ..][0..4], .little));
    // The data segment holds a rebase to main and a bind of exit, which
    // chain to each other.
    const page = 0x4000;
    const data = std.mem.alignForward(usize, stub + 12, page) + page;
    const rebase = std.mem.readInt(u64, out[data..][0..8], .little);
    try std.testing.expectEqual(@as(u64, text), rebase & ((1 << 36) - 1));
    try std.testing.expectEqual(@as(u64, 2), rebase >> 51 & 0xfff);
    const bind = std.mem.readInt(u64, out[data + 8 ..][0..8], .little);
    try std.testing.expect(bind >> 63 == 1);
    // The signature hashes the file before it.
    const sig = std.mem.indexOf(u8, out, &.{ 0xfa, 0xde, 0x0c, 0xc0 }).?;
    try std.testing.expectEqual(sig, std.mem.readInt(u32, out[sig + 20 + 32 ..][0..4], .big));
}

pub const EmbedError = error{ OutOfMemory, NotMachO, Malformed, NoRoom, AlreadyBundled, UnsupportedFixups };

/// Puts `payload` into a new segment `__LUS` of the executable `exe`,
/// which the system linker wrote, and signs the result ad hoc again. The
/// segment goes before `__LINKEDIT`, which moves up by the size of the
/// segment along with every offset into it, so the signature covers the
/// payload. The load commands need 168 free bytes before the first
/// section, which the linkers of Zig and Apple leave.
pub fn embed(gpa: std.mem.Allocator, exe: []const u8, payload: []const u8) EmbedError![]u8 {
    if (exe.len < 32 or rd32(exe, 0) != 0xfeedfacf) return error.NotMachO;
    const page: u64 = if (rd32(exe, 4) == 0x0100_000c) 0x4000 else 0x1000;
    const ncmds = rd32(exe, 16);
    const sizeofcmds = rd32(exe, 20);
    if (32 + @as(u64, sizeofcmds) > exe.len) return error.Malformed;
    var linkedit: ?usize = null;
    var sig: ?usize = null;
    var text_filesize: u64 = 0;
    var first_data: u64 = exe.len;
    var at: usize = 32;
    for (0..ncmds) |_| {
        if (at + 8 > 32 + sizeofcmds) return error.Malformed;
        const cmd = rd32(exe, at);
        const size = rd32(exe, at + 4);
        if (size < 8 or at + size > 32 + sizeofcmds) return error.Malformed;
        switch (cmd) {
            0x19 => {
                const name = std.mem.sliceTo(exe[at + 8 ..][0..16], 0);
                if (std.mem.eql(u8, name, "__LINKEDIT")) linkedit = at;
                if (std.mem.eql(u8, name, "__LUS")) return error.AlreadyBundled;
                if (std.mem.eql(u8, name, "__TEXT")) text_filesize = rd64(exe, at + 48);
                const nsects = rd32(exe, at + 64);
                for (0..nsects) |k| {
                    const sp = at + 72 + k * 80;
                    const off = rd32(exe, sp + 48);
                    if (off != 0 and rd64(exe, sp + 40) != 0) first_data = @min(first_data, off);
                }
            },
            0x1d => sig = at,
            0x8000_0034 => return error.UnsupportedFixups,
            else => {},
        }
        at += size;
    }
    const le = linkedit orelse return error.Malformed;
    const need: u64 = 72 + 80 + if (sig == null) @as(u64, 16) else 0;
    if (first_data < 32 + sizeofcmds + need) return error.NoRoom;
    const le_off = rd64(exe, le + 40);
    const le_addr = rd64(exe, le + 24);
    const le_end = if (sig) |s| rd32(exe, s + 8) else le_off + rd64(exe, le + 48);
    if (le_off > le_end or le_end > exe.len) return error.Malformed;
    const shift = std.mem.alignForward(u64, payload.len, page);
    const new_le_off = le_off + shift;
    const sig_off = std.mem.alignForward(u64, new_le_off + (le_end - le_off), 16);
    const n_pages = std.math.divCeil(u64, sig_off, sig_page) catch unreachable;
    const sig_size = std.mem.alignForward(u64, 12 + 8 + 88 + identifier.len + 1 + 32 * n_pages, 16);
    const out = try gpa.alloc(u8, link.index(sig_off + sig_size));
    errdefer gpa.free(out);
    @memset(out, 0);
    // The load commands, rewritten into the copy with __LUS before
    // __LINKEDIT, then the sections up to __LINKEDIT.
    const cmds_end = 32 + @as(usize, sizeofcmds);
    @memcpy(out[0..32], exe[0..32]);
    @memcpy(out[cmds_end + link.index(need) .. link.index(le_off)], exe[cmds_end + link.index(need) .. link.index(le_off)]);
    var w: Cmds = .{ .buf = out[32 .. cmds_end + link.index(need)] };
    at = 32;
    for (0..ncmds) |_| {
        const cmd = rd32(exe, at);
        const size = rd32(exe, at + 4);
        if (at == le) {
            w.segment("__LUS", le_addr, shift, le_off, shift, 1, 1, 1, 0);
            w.sect("__bundle", "__LUS", le_addr, payload.len, @intCast(le_off), 0, 0);
        }
        const c = w.buf[w.pos..][0..size];
        @memcpy(c, exe[at..][0..size]);
        w.pos += size;
        const moved = struct {
            fn f(b: []u8, off: usize, width: u8, from: u64, by: u64) void {
                if (width == 8) {
                    const v = std.mem.readInt(u64, b[off..][0..8], .little);
                    if (v >= from) std.mem.writeInt(u64, b[off..][0..8], v + by, .little);
                } else {
                    const v = std.mem.readInt(u32, b[off..][0..4], .little);
                    if (v >= from and v != 0) std.mem.writeInt(u32, b[off..][0..4], @intCast(v + by), .little);
                }
            }
        }.f;
        switch (cmd) {
            0x19 => if (at == le) {
                std.mem.writeInt(u64, c[24..32], le_addr + shift, .little);
                std.mem.writeInt(u64, c[40..48], new_le_off, .little);
                std.mem.writeInt(u64, c[48..56], sig_off + sig_size - new_le_off, .little);
                std.mem.writeInt(u64, c[32..40], std.mem.alignForward(u64, sig_off + sig_size - new_le_off, page), .little);
            },
            0x2 => for ([_]usize{ 8, 16 }) |o| moved(c, o, 4, le_off, shift), // LC_SYMTAB
            0xb => for ([_]usize{ 32, 40, 48, 56, 64, 72 }) |o| moved(c, o, 4, le_off, shift), // LC_DYSYMTAB
            0x22, 0x8000_0022 => for ([_]usize{ 8, 16, 24, 32, 40 }) |o| moved(c, o, 4, le_off, shift), // LC_DYLD_INFO
            0x1d => {
                std.mem.writeInt(u32, c[8..12], @intCast(sig_off), .little);
                std.mem.writeInt(u32, c[12..16], @intCast(sig_size), .little);
            },
            0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x8000_0033 => moved(c, 8, 4, le_off, shift),
            else => {},
        }
        at += size;
    }
    if (sig == null) w.linkeditData(0x1d, sig_off, sig_size);
    const h = out[0..32];
    std.mem.writeInt(u32, h[16..20], ncmds + 1 + @intFromBool(sig == null), .little);
    std.mem.writeInt(u32, h[20..24], @intCast(sizeofcmds + need), .little);
    @memcpy(out[link.index(le_off)..][0..payload.len], payload);
    @memcpy(out[link.index(new_le_off)..][0..link.index(le_end - le_off)], exe[link.index(le_off)..link.index(le_end)]);
    sign(out, sig_off, text_filesize);
    return out;
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
