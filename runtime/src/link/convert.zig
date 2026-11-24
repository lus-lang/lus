//! The converter that writes the link object (`lobj.zig`) of a target
//! from relocatable ELF, Mach-O, and COFF objects and archives. Only the release
//! build runs it, so a construct that the linker does not handle fails
//! there:
//!
//!   lus-convert --arch x86_64 --os linux [--entry _start] [--link-line FILE] -o OUT INPUT...
//!
//! The inputs are the runtime object of `zig build link-object`, the C
//! libraries, and on Linux the startup object and libc of musl. Objects
//! are always loaded. An archive member is loaded when it defines a
//! symbol that a loaded object needs, as a linker does. Each allocated
//! section of a loaded object becomes an atom, apart from the unwind
//! tables, the debug information, and the notes, which executables
//! compiled ahead of time leave out. On macOS and iOS, the symbols that
//! no input defines become imports of libSystem. On Windows, the import
//! libraries name the library of each import.

const std = @import("std");
const lobj = @import("lobj.zig");
const Allocator = std.mem.Allocator;
const elf = std.elf;

/// Names that the linker defines for the startup code of libc.
pub const linker_defined = [_][]const u8{
    "__init_array_start",    "__init_array_end",    "__fini_array_start", "__fini_array_end",
    "__preinit_array_start", "__preinit_array_end", "_DYNAMIC",           "_GLOBAL_OFFSET_TABLE_",
    "__ehdr_start",          "__dso_handle",        "_end",               "__bss_start",
    "_etext",                "_edata",              "end",                "etext",
    "edata",                 "_mh_execute_header",  "__ImageBase",        "__image_base__",
    "__global_pointer$",
};

const Sec = struct {
    name: []const u8,
    /// The kind of atom the section becomes, or null when executables
    /// leave it out.
    kind: ?lobj.Kind,
    /// The bytes, or null for a zeroed section.
    bytes: ?[]const u8,
    size: u64,
    align_log2: u8,
    /// A section that the linker does not handle, which is an error only
    /// when its object loads.
    unsupported: bool = false,
    /// The group of COFF sections it merges into, such as `.CRT`.
    group: ?[]const u8 = null,
};

/// The section index of an undefined, an absolute, and a common symbol.
const undef_sec = std.math.maxInt(u32);
const abs_sec = undef_sec - 1;
const common_sec = undef_sec - 2;
/// The section index of the slot of an import and of the jump to it,
/// which a member of an import library defines.
const import_sec = undef_sec - 3;
const thunk_sec = undef_sec - 4;

const Bind = enum { local, global, weak };

const Sym = struct {
    name: []const u8,
    /// The offset in the section, or for a common symbol its alignment.
    value: u64,
    size: u64,
    shndx: u32,
    bind: Bind,
    /// A symbol that names its section, which the relocations of ELF use.
    section: bool = false,
    /// For a weak external of COFF, the symbol it stands for when nothing
    /// defines its name.
    alias: ?u32 = null,

    /// Whether the symbol defines its name for other inputs. A weak
    /// external of COFF defines it as its alias, as an import library
    /// does for another name of an import.
    fn defines(s: Sym) bool {
        return s.bind != .local and (s.shndx != undef_sec or s.alias != null);
    }
};

/// A relocation of a section, its type mapped onto the numbering of ELF.
const Rel = struct {
    offset: u64,
    type: u32,
    sym: u32,
    addend: i64,
};

/// A COMDAT group of ELF: the members of a group whose signature an
/// earlier object already defined stay out.
const Group = struct { sig: []const u8, members: []const u32 };

const Input = struct {
    name: []const u8,
    data: []const u8,
    secs: []Sec,
    syms: []Sym,
    /// The relocations of each section.
    rels: []const []const Rel,
    groups: []const Group = &.{},
    /// The atom of each section, once the object is loaded.
    atoms: []?u32 = &.{},
    /// The offset of each section in its atom, nonzero in a merged group.
    base: []u32 = &.{},
    loaded: bool = false,
    /// The import that a member of an import library defines.
    imp: ?Import = null,
};

const Import = struct {
    name: []const u8,
    dll: []const u8,
    code: bool,
    target: lobj.Target = .none_target,
    thunk: ?u32 = null,
};

/// A section of a loaded input that merges into a group.
const Pending = struct { input: u32, sec: u32 };

/// The library that provides every symbol the objects leave undefined on
/// macOS and iOS.
const lib_system = "/usr/lib/libSystem.B.dylib";

pub const Converter = struct {
    gpa: Allocator,
    arena: Allocator,
    w: lobj.Writer,
    inputs: std.ArrayList(Input) = .empty,
    /// Defined global symbols of loaded inputs: input index and symbol.
    defs: std.StringHashMapUnmanaged(struct { input: u32, sym: u32 }) = .empty,
    /// Global symbols that archive members define, before they load.
    offers: std.StringHashMapUnmanaged(u32) = .empty,
    groups: std.StringHashMapUnmanaged(void) = .empty,
    commons: std.StringHashMapUnmanaged(u32) = .empty,
    /// The data that the linker of the C library of Windows provides.
    synthetic: std.StringHashMapUnmanaged(u32) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    arch: lobj.Arch,
    os: lobj.Os,

    pub fn init(gpa: Allocator, arena: Allocator, arch: lobj.Arch, os: lobj.Os) Converter {
        return .{ .gpa = gpa, .arena = arena, .w = .{ .gpa = gpa, .arch = arch, .os = os }, .arch = arch, .os = os };
    }

    pub fn deinit(c: *Converter) void {
        c.w.deinit();
        c.inputs.deinit(c.gpa);
        c.defs.deinit(c.gpa);
        c.offers.deinit(c.gpa);
        c.groups.deinit(c.gpa);
        c.commons.deinit(c.gpa);
        c.synthetic.deinit(c.gpa);
        c.pending.deinit(c.gpa);
    }

    fn macho(c: *const Converter) bool {
        return c.os.darwin();
    }

    /// Adds an object file, loaded at once, or an archive, whose members
    /// load as they are needed.
    pub fn addFile(c: *Converter, name: []const u8, data: []const u8) !void {
        if (std.mem.startsWith(u8, data, "!<arch>\n")) return c.addArchive(name, data);
        const i = try c.parse(name, data);
        try c.load(i);
    }

    /// Reads an archive in the GNU form, with long names in a member `//`,
    /// or the BSD form, where a member `#1/N` starts with its name.
    fn addArchive(c: *Converter, name: []const u8, data: []const u8) !void {
        var pos: usize = 8;
        var long_names: []const u8 = "";
        while (pos + 60 <= data.len) {
            const hdr = data[pos..][0..60];
            const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, hdr[48..58], " "), 10) catch return error.BadArchive;
            if (size > data.len - pos - 60) return error.BadArchive;
            var body = data[pos + 60 ..][0..size];
            const raw = std.mem.trimEnd(u8, hdr[0..16], " ");
            pos += 60 + size + (size & 1);
            if (std.mem.eql(u8, raw, "/") or std.mem.eql(u8, raw, "/SYM64/")) continue;
            if (std.mem.eql(u8, raw, "//")) {
                long_names = body;
                continue;
            }
            var mname = raw;
            if (std.mem.startsWith(u8, raw, "#1/")) {
                const n = std.fmt.parseInt(usize, raw[3..], 10) catch return error.BadArchive;
                if (n > body.len) return error.BadArchive;
                mname = std.mem.sliceTo(body[0..n], 0);
                body = body[n..];
                if (std.mem.startsWith(u8, mname, "__.SYMDEF")) continue;
            } else if (raw.len > 1 and raw[0] == '/') {
                const off = std.fmt.parseInt(usize, raw[1..], 10) catch return error.BadArchive;
                const rest = long_names[off..];
                mname = rest[0 .. std.mem.indexOfAny(u8, rest, "/\n\x00") orelse rest.len];
            } else if (std.mem.endsWith(u8, raw, "/")) mname = raw[0 .. raw.len - 1];
            const known = if (c.os == .windows) c.isCoff(body) else std.mem.startsWith(u8, body, elf.MAGIC) or isMachO(body);
            if (!known) continue;
            const i = try c.parse(try std.fmt.allocPrint(c.arena, "{s}({s})", .{ name, mname }), body);
            for (c.inputs.items[i].syms) |s| {
                if (!s.defines()) continue;
                const gop = try c.offers.getOrPut(c.gpa, s.name);
                if (!gop.found_existing) gop.value_ptr.* = i;
            }
        }
    }

    fn parse(c: *Converter, name: []const u8, data: []const u8) !u32 {
        const in = if (c.macho()) try c.parseMachO(name, data) else if (c.os == .windows) try c.parseCoff(name, data) else try c.parseElf(name, data);
        try c.inputs.append(c.gpa, in);
        return @intCast(c.inputs.items.len - 1);
    }

    fn parseElf(c: *Converter, name: []const u8, data: []const u8) !Input {
        if (data.len < @sizeOf(elf.Elf32_Ehdr) or !std.mem.startsWith(u8, data, elf.MAGIC)) return error.NotElf;
        return if (data[elf.EI.CLASS] == elf.ELFCLASS32) c.parseElfOf(Elf32, name, data) else c.parseElfOf(Elf64, name, data);
    }

    const Elf64 = struct {
        const Ehdr = elf.Elf64_Ehdr;
        const Shdr = elf.Elf64_Shdr;
        const Sym = elf.Elf64_Sym;
        const Rela = elf.Elf64_Rela;
        const Rel = elf.Elf64_Rel;
        fn relType(info: u64) u32 {
            return @truncate(info);
        }
        fn relSym(info: u64) u32 {
            return @intCast(info >> 32);
        }
    };

    const Elf32 = struct {
        const Ehdr = elf.Elf32_Ehdr;
        const Shdr = elf.Elf32_Shdr;
        const Sym = elf.Elf32_Sym;
        const Rela = elf.Elf32_Rela;
        const Rel = elf.Elf32_Rel;
        fn relType(info: u32) u32 {
            return info & 0xff;
        }
        fn relSym(info: u32) u32 {
            return info >> 8;
        }
    };

    fn parseElfOf(c: *Converter, comptime E: type, name: []const u8, data: []const u8) !Input {
        if (data.len < @sizeOf(E.Ehdr)) return error.NotElf;
        const eh = std.mem.bytesToValue(E.Ehdr, data[0..@sizeOf(E.Ehdr)]);
        if (eh.e_type != .REL) return error.NotRelocatable;
        const machine: elf.EM = switch (c.arch) {
            .x86_64 => .X86_64,
            .aarch64 => .AARCH64,
            .arm => .ARM,
            .riscv64 => .RISCV,
        };
        if (eh.e_machine != machine or (E == Elf32) != (c.arch == .arm)) {
            std.log.err("{s}: built for another architecture", .{name});
            return error.WrongArchitecture;
        }
        const shdrs = try c.arena.alloc(E.Shdr, eh.e_shnum);
        for (shdrs, 0..) |*sh, k| sh.* = std.mem.bytesToValue(E.Shdr, slice(data, eh.e_shoff + k * @sizeOf(E.Shdr), @sizeOf(E.Shdr)));
        const shstr = shdrs[eh.e_shstrndx];
        const secs = try c.arena.alloc(Sec, shdrs.len);
        var symtab: ?E.Shdr = null;
        for (shdrs, secs) |sh, *s| {
            const sname = cstr(data, shstr.sh_offset + sh.sh_name);
            s.* = .{
                .name = sname,
                .kind = elfKind(sname, sh.sh_type, sh.sh_flags, sh.sh_size),
                .bytes = null,
                .size = sh.sh_size,
                .align_log2 = if (sh.sh_addralign <= 1) 0 else @intCast(std.math.log2_int(u64, sh.sh_addralign)),
                .unsupported = std.mem.startsWith(u8, sname, ".ctors") or std.mem.startsWith(u8, sname, ".dtors"),
            };
            if (s.kind) |k| if (!lobj.zeroed(k)) {
                s.bytes = slice(data, sh.sh_offset, sh.sh_size);
            };
            if (sh.sh_type == elf.SHT_SYMTAB) symtab = sh;
        }
        var syms: []Sym = &.{};
        if (symtab) |st| {
            const strs = shdrs[st.sh_link];
            const n: usize = @intCast(st.sh_size / @sizeOf(E.Sym));
            syms = try c.arena.alloc(Sym, n);
            for (syms, 0..) |*s, k| {
                const es = std.mem.bytesToValue(E.Sym, slice(data, st.sh_offset + k * @sizeOf(E.Sym), @sizeOf(E.Sym)));
                s.* = .{
                    .name = cstr(data, strs.sh_offset + es.st_name),
                    .value = es.st_value,
                    .size = es.st_size,
                    .shndx = switch (es.st_shndx) {
                        elf.SHN_UNDEF => undef_sec,
                        elf.SHN_ABS => abs_sec,
                        elf.SHN_COMMON => common_sec,
                        else => |x| x,
                    },
                    .bind = switch (es.st_info >> 4) {
                        elf.STB_LOCAL => .local,
                        elf.STB_WEAK => .weak,
                        else => .global,
                    },
                    .section = es.st_info & 0xf == elf.STT_SECTION,
                };
            }
        }
        const rels = try c.arena.alloc([]const Rel, shdrs.len);
        @memset(rels, &.{});
        var groups: std.ArrayList(Group) = .empty;
        for (shdrs) |sh| {
            if (sh.sh_type == elf.SHT_GROUP) {
                const members = std.mem.bytesAsSlice(u32, slice(data, sh.sh_offset, sh.sh_size));
                const m = try c.arena.alloc(u32, members.len - 1);
                for (m, members[1..]) |*d, x| d.* = std.mem.littleToNative(u32, x);
                try groups.append(c.arena, .{ .sig = syms[sh.sh_info].name, .members = m });
                continue;
            }
            const rela = sh.sh_type == elf.SHT_RELA;
            if ((!rela and sh.sh_type != elf.SHT_REL) or sh.sh_info >= shdrs.len) continue;
            const size: usize = if (rela) @sizeOf(E.Rela) else @sizeOf(E.Rel);
            const n: usize = @intCast(sh.sh_size / size);
            const list = try c.arena.alloc(Rel, n);
            var used: usize = 0;
            for (0..n) |k| {
                const at = sh.sh_offset + k * size;
                var offset: u64 = undefined;
                var info: @FieldType(E.Rel, "r_info") = undefined;
                var addend: i64 = 0;
                if (rela) {
                    const r = std.mem.bytesToValue(E.Rela, slice(data, at, size));
                    offset = r.r_offset;
                    info = r.r_info;
                    addend = r.r_addend;
                } else {
                    const r = std.mem.bytesToValue(E.Rel, slice(data, at, size));
                    offset = r.r_offset;
                    info = r.r_info;
                }
                const ty = E.relType(info);
                if (ty == 0) continue;
                // RELAX and ALIGN of riscv64 permit the linker to shorten
                // code, and code that keeps its length needs neither.
                if (c.arch == .riscv64 and (ty == 51 or ty == 43)) continue;
                if (!rela) {
                    // A relocation of REL keeps its addend in the place it
                    // patches. Sections that executables leave out carry
                    // only relocations that never apply.
                    const patched = shdrs[sh.sh_info];
                    if (secs[sh.sh_info].bytes == null) continue;
                    const place = slice(data, patched.sh_offset + offset, 4);
                    addend = armAddend(ty, std.mem.readInt(u32, place[0..4], .little)) orelse continue;
                }
                list[used] = .{ .offset = offset, .type = ty, .sym = E.relSym(info), .addend = addend };
                used += 1;
            }
            rels[sh.sh_info] = list[0..used];
        }
        return .{ .name = name, .data = data, .secs = secs, .syms = syms, .rels = rels, .groups = groups.items };
    }

    /// The addend of a relocation of 32-bit ARM from the word it patches,
    /// or null for a relocation that patches nothing (`R_ARM_V4BX`). The
    /// linker applies the addend as a relocation of RELA would.
    fn armAddend(ty: u32, w: u32) ?i64 {
        return switch (ty) {
            // ABS32, REL32, GOTOFF32, BASE_PREL, TARGET1, TLS_LE32,
            // GOT_PREL, TLS_IE32, TLS_LDO32, TLS_GD32, TLS_LDM32.
            2, 3, 24, 25, 38, 108, 96, 107, 106, 104, 105 => @as(i32, @bitCast(w)),
            // PREL31.
            42 => @as(i32, @bitCast(w << 1)) >> 1,
            // CALL, JUMP24, PC24: a signed word offset in 24 bits.
            28, 29, 1 => @as(i64, @as(i32, @bitCast(w << 8)) >> 8) * 4,
            // MOVW_ABS_NC, MOVT_ABS, MOVW_PREL_NC, MOVT_PREL: a signed
            // 16-bit immediate split into 4 and 12 bits.
            43, 44, 45, 46 => @as(i16, @bitCast(@as(u16, @truncate(((w >> 4) & 0xf000) | (w & 0xfff))))),
            // V4BX marks a `bx` for ARMv4.
            40 => null,
            // The linker reports any other type.
            else => @as(i32, @bitCast(w)),
        };
    }

    fn elfKind(name: []const u8, sh_type: u32, sh_flags: u64, sh_size: u64) ?lobj.Kind {
        if (sh_flags & elf.SHF_ALLOC == 0 or sh_size == 0) return null;
        if (std.mem.startsWith(u8, name, ".eh_frame") or std.mem.startsWith(u8, name, ".note") or std.mem.eql(u8, name, ".llvm_addrsig")) return null;
        // The unwind tables of 32-bit ARM, which only an unwinder reads.
        if (std.mem.startsWith(u8, name, ".ARM.exidx") or std.mem.startsWith(u8, name, ".ARM.extab")) return null;
        if (sh_flags & elf.SHF_TLS != 0) return if (sh_type == elf.SHT_NOBITS) .tbss else .tdata;
        if (sh_type == elf.SHT_NOBITS) return .bss;
        if (sh_type == elf.SHT_INIT_ARRAY or sh_type == elf.SHT_PREINIT_ARRAY) return .init_array;
        if (sh_type == elf.SHT_FINI_ARRAY) return .fini_array;
        if (sh_flags & elf.SHF_EXECINSTR != 0) return .text;
        if (sh_flags & elf.SHF_WRITE != 0) return .data;
        return .rodata;
    }

    fn isMachO(data: []const u8) bool {
        return data.len >= 4 and std.mem.readInt(u32, data[0..4], .little) == macho_magic;
    }

    /// Reads a relocatable Mach-O object. A section of an object that Zig
    /// or clang compiles splits into one piece for each symbol, which the
    /// flag `MH_SUBSECTIONS_VIA_SYMBOLS` allows, and each piece becomes a
    /// section of the input. Names lose the underscore that Mach-O puts
    /// before every C name.
    fn parseMachO(c: *Converter, name: []const u8, data: []const u8) !Input {
        if (data.len < 32 or !isMachO(data)) return error.NotMachO;
        const cpu: u32 = switch (c.arch) {
            .x86_64 => 0x01000007,
            .aarch64 => 0x0100000c,
            .arm => 12,
            .riscv64 => 24,
        };
        if (rd(u32, data, 4) != cpu) {
            std.log.err("{s}: built for another architecture", .{name});
            return error.WrongArchitecture;
        }
        if (c.arch != .aarch64) {
            std.log.err("{s}: Mach-O objects of {s} are not supported", .{ name, @tagName(c.arch) });
            return error.Unsupported;
        }
        if (rd(u32, data, 12) != 1) return error.NotRelocatable;
        const ncmds = rd(u32, data, 16);
        const subsections = rd(u32, data, 24) & 0x2000 != 0;
        // The sections of the object in order, which non-external
        // relocations number from 1.
        const MSec = struct { segname: []const u8, sectname: []const u8, addr: u64, size: u64, offset: u32, align_: u32, reloff: u32, nreloc: u32, flags: u32 };
        var msecs: std.ArrayList(MSec) = .empty;
        var symoff: u32 = 0;
        var nsyms: u32 = 0;
        var stroff: u32 = 0;
        var at: usize = 32;
        for (0..ncmds) |_| {
            const cmd = rd(u32, data, at);
            const size = rd(u32, data, at + 4);
            if (cmd == 0x19) {
                const nsects = rd(u32, data, at + 64);
                for (0..nsects) |k| {
                    const sp = at + 72 + k * 80;
                    try msecs.append(c.arena, .{
                        .sectname = std.mem.sliceTo(data[sp..][0..16], 0),
                        .segname = std.mem.sliceTo(data[sp + 16 ..][0..16], 0),
                        .addr = rd(u64, data, sp + 32),
                        .size = rd(u64, data, sp + 40),
                        .offset = rd(u32, data, sp + 48),
                        .align_ = rd(u32, data, sp + 52),
                        .reloff = rd(u32, data, sp + 56),
                        .nreloc = rd(u32, data, sp + 60),
                        .flags = rd(u32, data, sp + 64),
                    });
                }
            } else if (cmd == 0x2) {
                symoff = rd(u32, data, at + 8);
                nsyms = rd(u32, data, at + 12);
                stroff = rd(u32, data, at + 16);
            }
            at += size;
        }
        // The symbols, with the section of each as an index into `msecs`
        // until the pieces are known.
        var syms: std.ArrayList(Sym) = .empty;
        const sym_map = try c.arena.alloc(?u32, nsyms);
        const NList = struct { strx: u32, type: u8, sect: u8, desc: u16, value: u64 };
        const nl = try c.arena.alloc(NList, nsyms);
        for (nl, 0..) |*n, k| {
            const p = symoff + k * 16;
            n.* = .{ .strx = rd(u32, data, p), .type = data[p + 4], .sect = data[p + 5], .desc = rd(u16, data, p + 6), .value = rd(u64, data, p + 8) };
        }
        // Piece boundaries: the start of each section and every symbol in
        // it that is not an alternative entry of the piece before.
        const bounds = try c.arena.alloc(std.ArrayList(u64), msecs.items.len);
        for (bounds, msecs.items) |*b, ms| {
            b.* = .empty;
            try b.append(c.arena, ms.addr);
        }
        for (nl) |n| {
            if (n.type & 0xe0 != 0 or n.type & 0x0e != 0x0e or n.sect == 0) continue;
            if (!subsections or n.desc & 0x200 != 0) continue;
            try bounds[n.sect - 1].append(c.arena, n.value);
        }
        var secs: std.ArrayList(Sec) = .empty;
        // The first piece of each section and the starts of its pieces.
        const first = try c.arena.alloc(u32, msecs.items.len);
        for (msecs.items, bounds, first) |ms, *b, *f| {
            std.mem.sort(u64, b.items, {}, std.sort.asc(u64));
            var uniq: std.ArrayList(u64) = .empty;
            for (b.items) |v| {
                if (v < ms.addr or v >= ms.addr + @max(ms.size, 1)) continue;
                if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != v) try uniq.append(c.arena, v);
            }
            b.* = uniq;
            f.* = @intCast(secs.items.len);
            const kind = machoKind(ms.segname, ms.sectname, ms.flags, ms.size);
            for (uniq.items, 0..) |start, k| {
                const end = if (k + 1 < uniq.items.len) uniq.items[k + 1] else ms.addr + ms.size;
                const off = start - ms.addr;
                const zero = if (kind) |kk| lobj.zeroed(kk) else true;
                const al: u8 = @intCast(if (off == 0) ms.align_ else @min(ms.align_, @ctz(off)));
                try secs.append(c.arena, .{
                    .name = ms.sectname,
                    .kind = kind,
                    .bytes = if (zero) null else data[@intCast(ms.offset + off)..][0..@intCast(end - start)],
                    .size = end - start,
                    .align_log2 = al,
                    .unsupported = ms.flags & 0xff == 0x15 or (kind == .fini_array),
                });
            }
        }
        const piece = struct {
            fn find(b: []const u64, f: u32, addr: u64) struct { sec: u32, off: u64 } {
                var lo: usize = 0;
                var hi: usize = b.len;
                while (hi - lo > 1) {
                    const mid = (lo + hi) / 2;
                    if (b[mid] <= addr) lo = mid else hi = mid;
                }
                return .{ .sec = f + @as(u32, @intCast(lo)), .off = addr - b[lo] };
            }
        }.find;
        for (nl, sym_map) |n, *m| {
            m.* = null;
            if (n.type & 0xe0 != 0) continue;
            const raw = cstr(data, stroff + n.strx);
            const sname = if (raw.len > 0 and raw[0] == '_') raw[1..] else raw;
            const ext = n.type & 0x01 != 0;
            const bind: Bind = if (!ext) .local else if (n.desc & 0xc0 != 0) .weak else .global;
            var s: Sym = .{ .name = sname, .value = 0, .size = 0, .shndx = undef_sec, .bind = bind };
            switch (n.type & 0x0e) {
                0x0 => if (n.value != 0) {
                    s.shndx = common_sec;
                    s.size = n.value;
                    s.value = @as(u64, 1) << @intCast((n.desc >> 8) & 0xf);
                },
                0x2 => {
                    s.shndx = abs_sec;
                    s.value = n.value;
                },
                0xe => {
                    const pc = piece(bounds[n.sect - 1].items, first[n.sect - 1], n.value);
                    s.shndx = pc.sec;
                    s.value = pc.off;
                },
                else => continue,
            }
            m.* = @intCast(syms.items.len);
            try syms.append(c.arena, s);
        }
        // Relocations go to the piece that holds them. ADDEND and
        // SUBTRACTOR qualify the relocation after them.
        const rels = try c.arena.alloc(std.ArrayList(Rel), secs.items.len);
        for (rels) |*r| r.* = .empty;
        for (msecs.items, 0..) |ms, si| {
            var addend: i64 = 0;
            var sub: ?u32 = null;
            for (0..ms.nreloc) |k| {
                const p = ms.reloff + k * 8;
                const addr = rd(u32, data, p);
                const info = rd(u32, data, p + 4);
                if (addr & 0x8000_0000 != 0) {
                    std.log.err("{s}: a scattered relocation in {s},{s}", .{ name, ms.segname, ms.sectname });
                    return error.Unsupported;
                }
                const num = info & 0xff_ffff;
                const length: u2 = @truncate(info >> 25);
                const ext = info & (1 << 27) != 0;
                const ty: u4 = @truncate(info >> 28);
                if (ty == 10) { // ARM64_RELOC_ADDEND
                    addend = @as(i24, @bitCast(@as(u24, @truncate(num))));
                    continue;
                }
                const pc = piece(bounds[si].items, first[si], ms.addr + addr);
                const sec = secs.items[pc.sec];
                // Relocations of left out sections, such as the unwind
                // tables and the debug information, are skipped.
                if (sec.kind == null) {
                    addend = 0;
                    sub = null;
                    continue;
                }
                const loc = data[ms.offset + addr ..];
                // The symbol the relocation names: an external one, or for
                // a section number the piece at the address that the
                // location holds.
                var sym: u32 = undefined;
                var inplace: i64 = switch (length) {
                    3 => std.mem.readInt(i64, loc[0..8], .little),
                    2 => std.mem.readInt(i32, loc[0..4], .little),
                    else => 0,
                };
                if (ext) {
                    sym = sym_map[num] orelse return error.BadRelocation;
                } else {
                    if (ty != 0 or num == 0) {
                        std.log.err("{s}: a relocation of type {d} by section", .{ name, ty });
                        return error.Unsupported;
                    }
                    const tp = piece(bounds[num - 1].items, first[num - 1], @bitCast(inplace));
                    sym = @intCast(syms.items.len);
                    try syms.append(c.arena, .{ .name = "", .value = tp.off, .size = 0, .shndx = tp.sec, .bind = .local, .section = true });
                    inplace = 0;
                }
                if (ty == 1) { // ARM64_RELOC_SUBTRACTOR
                    sub = sym;
                    continue;
                }
                const r: Rel = switch (ty) {
                    0 => blk: { // UNSIGNED
                        if (sub) |m| {
                            // The difference of two symbols: relative to
                            // the location when the subtrahend is in the
                            // same piece.
                            const ms_ = syms.items[m];
                            if (ms_.shndx != pc.sec) {
                                std.log.err("{s}: a difference of symbols across atoms in {s}", .{ name, ms.sectname });
                                return error.Unsupported;
                            }
                            const delta = @as(i64, @intCast(pc.off)) - @as(i64, @intCast(ms_.value));
                            break :blk .{ .offset = pc.off, .type = if (length == 3) 260 else 261, .sym = sym, .addend = inplace + delta };
                        }
                        const ts = syms.items[sym];
                        const tls_target = ts.shndx < secs.items.len and (secs.items[ts.shndx].kind == .tdata or secs.items[ts.shndx].kind == .tbss);
                        if (sec.kind == .thread_vars and tls_target) break :blk .{ .offset = pc.off, .type = 1028, .sym = sym, .addend = inplace };
                        break :blk .{ .offset = pc.off, .type = if (length == 3) 257 else 258, .sym = sym, .addend = inplace };
                    },
                    2 => .{ .offset = pc.off, .type = 283, .sym = sym, .addend = addend },
                    3 => .{ .offset = pc.off, .type = 275, .sym = sym, .addend = addend },
                    4 => .{ .offset = pc.off, .type = try pageOff(std.mem.readInt(u32, loc[0..4], .little)), .sym = sym, .addend = addend },
                    5, 8 => .{ .offset = pc.off, .type = 311, .sym = sym, .addend = addend },
                    6, 9 => .{ .offset = pc.off, .type = 312, .sym = sym, .addend = addend },
                    else => {
                        std.log.err("{s}: relocation type {d} of Mach-O in {s},{s}", .{ name, ty, ms.segname, ms.sectname });
                        return error.Unsupported;
                    },
                };
                try rels[pc.sec].append(c.arena, r);
                addend = 0;
                sub = null;
            }
        }
        const out = try c.arena.alloc([]const Rel, secs.items.len);
        for (out, rels) |*o, r| o.* = r.items;
        return .{ .name = name, .data = data, .secs = secs.items, .syms = syms.items, .rels = out };
    }

    /// The ELF type of a PAGEOFF12 relocation of aarch64, which depends on
    /// the instruction: an add, or a load or store of some size.
    fn pageOff(insn: u32) !u32 {
        if (insn & 0x1f00_0000 == 0x1100_0000) return 277; // ADD_ABS_LO12_NC
        if (insn & 0x3b00_0000 == 0x3900_0000) {
            const size = insn >> 30;
            const simd = insn & (1 << 26) != 0;
            if (simd and size == 0 and insn & (1 << 23) != 0) return 299; // LDST128
            return switch (size) {
                0 => 278,
                1 => 284,
                2 => 285,
                else => 286,
            };
        }
        std.log.err("a PAGEOFF12 relocation of instruction 0x{x}", .{insn});
        return error.Unsupported;
    }

    fn machoKind(seg: []const u8, sect: []const u8, flags: u32, size: u64) ?lobj.Kind {
        if (size == 0) return null;
        if (flags & 0x0200_0000 != 0) return null; // S_ATTR_DEBUG
        if (std.mem.eql(u8, seg, "__DWARF") or std.mem.eql(u8, seg, "__LD") or std.mem.eql(u8, seg, "__LLVM")) return null;
        if (std.mem.eql(u8, sect, "__eh_frame") or std.mem.eql(u8, sect, "__unwind_info")) return null;
        return switch (flags & 0xff) {
            0x1, 0xc => .bss, // S_ZEROFILL, S_GB_ZEROFILL
            0x9 => .init_array, // S_MOD_INIT_FUNC_POINTERS
            0xa => .fini_array, // S_MOD_TERM_FUNC_POINTERS
            0x11 => .tdata, // S_THREAD_LOCAL_REGULAR
            0x12 => .tbss, // S_THREAD_LOCAL_ZEROFILL
            0x13 => .thread_vars, // S_THREAD_LOCAL_VARIABLES
            else => if (flags & 0x8000_0400 != 0)
                .text
            else if (std.mem.eql(u8, seg, "__TEXT") or std.mem.eql(u8, seg, "__DATA_CONST") or std.mem.eql(u8, sect, "__const"))
                .rodata
            else
                .data,
        };
    }

    /// The class identifier of the large form of COFF objects, which
    /// numbers sections with 32 bits.
    const bigobj_class = [16]u8{ 0xc7, 0xa1, 0xba, 0xd1, 0xee, 0xba, 0xa9, 0x4b, 0xaf, 0x20, 0xfa, 0xf6, 0x6a, 0xa4, 0xdc, 0xb8 };

    fn coffMachine(arch: lobj.Arch) u16 {
        return switch (arch) {
            .x86_64 => 0x8664,
            .aarch64 => 0xaa64,
            .arm => 0x1c4,
            .riscv64 => 0x5064,
        };
    }

    fn isCoff(c: *const Converter, data: []const u8) bool {
        if (data.len < 20) return false;
        if (rd(u16, data, 0) == 0 and rd(u16, data, 2) == 0xffff) return true;
        return rd(u16, data, 0) == coffMachine(c.arch);
    }

    /// Reads a COFF object in the ordinary or the large form, or a short
    /// member of an import library. Sections keep the numbers of COFF,
    /// which start at 1. The sections of the startup code of the C
    /// library whose names share a prefix before `$` are merged in the
    /// order of their names once every input is loaded (`mergeGroups`).
    fn parseCoff(c: *Converter, name: []const u8, data: []const u8) !Input {
        if (data.len < 20) return error.NotCoff;
        const machine = coffMachine(c.arch);
        var nsecs: u32 = 0;
        var symoff: usize = 0;
        var nsyms: usize = 0;
        var sec_at: usize = 0;
        var big = false;
        if (rd(u16, data, 0) == 0 and rd(u16, data, 2) == 0xffff) {
            if (rd(u16, data, 6) != machine) return wrongArchitecture(name);
            const version = rd(u16, data, 4);
            if (version == 0) return c.parseImport(name, data);
            if (version != 2 or data.len < 56 or !std.mem.eql(u8, data[12..28], &bigobj_class)) return error.NotCoff;
            nsecs = rd(u32, data, 44);
            symoff = rd(u32, data, 48);
            nsyms = rd(u32, data, 52);
            sec_at = 56;
            big = true;
        } else {
            if (rd(u16, data, 0) != machine) return wrongArchitecture(name);
            nsecs = rd(u16, data, 2);
            symoff = rd(u32, data, 8);
            nsyms = rd(u32, data, 12);
            sec_at = 20 + @as(usize, rd(u16, data, 16));
        }
        const sym_size: usize = if (big) 20 else 18;
        const strtab = data[symoff + nsyms * sym_size ..];
        const secs = try c.arena.alloc(Sec, nsecs + 1);
        secs[0] = .{ .name = "", .kind = null, .bytes = null, .size = 0, .align_log2 = 0 };
        const flags = try c.arena.alloc(u32, nsecs + 1);
        flags[0] = 0;
        for (1..nsecs + 1) |k| {
            const sh = sec_at + (k - 1) * 40;
            const sname = try coffName(data[sh..][0..8], strtab);
            const f = rd(u32, data, sh + 36);
            const size = rd(u32, data, sh + 16);
            const ptr = rd(u32, data, sh + 20);
            const a = (f >> 20) & 0xf;
            const kind = coffKind(sname, f, size);
            flags[k] = f;
            secs[k] = .{
                .name = sname,
                .kind = kind,
                .bytes = if (kind != null and !lobj.zeroed(kind.?) and ptr != 0) data[ptr..][0..size] else null,
                .size = size,
                // An object that leaves the alignment out gets 16 bytes.
                .align_log2 = if (a == 0) 4 else @intCast(a - 1),
                .group = if (std.mem.startsWith(u8, sname, ".CRT$")) ".CRT" else if (std.mem.eql(u8, sname, ".tls") or std.mem.startsWith(u8, sname, ".tls$")) ".tls" else null,
            };
        }
        // Symbols, with the slots of auxiliary records kept so that the
        // indices of relocations stay valid.
        const syms = try c.arena.alloc(Sym, nsyms);
        const comdat_sym = try c.arena.alloc(?u32, nsecs + 1);
        @memset(comdat_sym, null);
        const comdat_sel = try c.arena.alloc(u8, nsecs + 1);
        @memset(comdat_sel, 0);
        const assoc = try c.arena.alloc(u32, nsecs + 1);
        @memset(assoc, 0);
        var k: usize = 0;
        while (k < nsyms) {
            const p = symoff + k * sym_size;
            const nm = try coffName(data[p..][0..8], strtab);
            const value = rd(u32, data, p + 8);
            const secnum: i32 = if (big) rd(i32, data, p + 12) else rd(i16, data, p + 12);
            const tail = p + if (big) @as(usize, 16) else 14;
            const typ = rd(u16, data, tail);
            const class = data[tail + 2];
            const naux = data[tail + 3];
            var s: Sym = .{ .name = nm, .value = value, .size = 0, .shndx = undef_sec, .bind = .local };
            const in_sec = secnum > 0 and secnum <= nsecs;
            if (in_sec) {
                s.shndx = @intCast(secnum);
            } else if (secnum != 0) {
                s.shndx = abs_sec;
            }
            switch (class) {
                2 => {
                    s.bind = .global;
                    // An external symbol without a section but with a
                    // value is common, and its value is its size.
                    if (secnum == 0 and value > 0) {
                        s.shndx = common_sec;
                        s.size = value;
                        s.value = @min(16, std.math.ceilPowerOfTwoAssert(u64, value));
                    }
                },
                105 => {
                    // A weak external takes the symbol of its auxiliary
                    // record when nothing defines its name.
                    s.bind = .weak;
                    s.shndx = undef_sec;
                    if (naux > 0) s.alias = rd(u32, data, p + sym_size);
                },
                else => {},
            }
            if (class == 3 and naux > 0 and in_sec and value == 0 and typ == 0 and std.mem.eql(u8, nm, secs[s.shndx].name)) {
                // The definition of a section, with its COMDAT selection.
                s.section = true;
                const ax = p + sym_size;
                if (flags[s.shndx] & 0x1000 != 0) {
                    comdat_sel[s.shndx] = data[ax + 14];
                    var number: u32 = rd(u16, data, ax + 12);
                    if (big) number |= @as(u32, rd(u16, data, ax + 16)) << 16;
                    if (comdat_sel[s.shndx] == 5) assoc[s.shndx] = number;
                }
            } else if (in_sec and flags[s.shndx] & 0x1000 != 0 and comdat_sym[s.shndx] == null and (class == 2 or class == 3)) {
                comdat_sym[s.shndx] = @intCast(k);
            }
            syms[k] = s;
            for (syms[k + 1 ..][0..naux]) |*x| x.* = .{ .name = "", .value = 0, .size = 0, .shndx = abs_sec, .bind = .local };
            k += 1 + @as(usize, naux);
        }
        // Each COMDAT section that is not associative leads a group with
        // the sections associated with it. A group whose symbol is static
        // belongs to its object alone, as the strings of C do.
        var groups: std.ArrayList(Group) = .empty;
        for (1..nsecs + 1) |s| {
            if (flags[s] & 0x1000 == 0 or comdat_sel[s] == 5) continue;
            if (comdat_sym[s]) |cs| if (syms[cs].bind == .local) continue;
            var members: std.ArrayList(u32) = .empty;
            try members.append(c.arena, @intCast(s));
            for (assoc, 0..) |x, j| if (x == s) try members.append(c.arena, @intCast(j));
            const sig = if (comdat_sym[s]) |cs| syms[cs].name else secs[s].name;
            try groups.append(c.arena, .{ .sig = sig, .members = members.items });
        }
        // Relocations, with the addend that COFF keeps in the bytes.
        const rels = try c.arena.alloc([]const Rel, nsecs + 1);
        @memset(rels, &.{});
        for (1..nsecs + 1) |s| {
            const sec = secs[s];
            if (sec.kind == null) continue;
            const sh = sec_at + (s - 1) * 40;
            var relptr: usize = rd(u32, data, sh + 24);
            var nrel: usize = rd(u16, data, sh + 32);
            if (flags[s] & 0x0100_0000 != 0 and nrel == 0xffff) {
                // The first relocation holds the count, itself included.
                nrel = rd(u32, data, relptr) - 1;
                relptr += 10;
            }
            const list = try c.arena.alloc(Rel, nrel);
            var used: usize = 0;
            for (0..nrel) |j| {
                const rp = relptr + j * 10;
                const off = rd(u32, data, rp);
                const ty = rd(u16, data, rp + 8);
                const m = try coffRel(c.arch, ty, sec.bytes, off) orelse continue;
                list[used] = .{ .offset = off, .type = m.type, .sym = rd(u32, data, rp + 4), .addend = m.addend };
                used += 1;
            }
            rels[s] = list[0..used];
        }
        return .{ .name = name, .data = data, .secs = secs, .syms = syms, .rels = rels, .groups = groups.items };
    }

    /// A name of a section or a symbol: eight bytes, or an offset in the
    /// string table after `/` in decimal or after `//` in base 64.
    fn coffName(raw: *const [8]u8, strtab: []const u8) ![]const u8 {
        if (raw[0] == '/' and raw[1] == '/') {
            var off: usize = 0;
            for (raw[2..]) |ch| {
                const d: usize = switch (ch) {
                    'A'...'Z' => ch - 'A',
                    'a'...'z' => ch - 'a' + 26,
                    '0'...'9' => ch - '0' + 52,
                    '+' => 62,
                    '/' => 63,
                    else => return error.BadName,
                };
                off = off * 64 + d;
            }
            return cstr(strtab, off);
        }
        if (raw[0] == '/') {
            const off = std.fmt.parseInt(usize, std.mem.sliceTo(raw[1..], 0), 10) catch return error.BadName;
            return cstr(strtab, off);
        }
        // A symbol whose first four bytes are zero names an offset.
        if (std.mem.readInt(u32, raw[0..4], .little) == 0) return cstr(strtab, std.mem.readInt(u32, raw[4..8], .little));
        return std.mem.sliceTo(raw, 0);
    }

    fn coffKind(name: []const u8, flags: u32, size: u32) ?lobj.Kind {
        if (size == 0) return null;
        // IMAGE_SCN_LNK_REMOVE and IMAGE_SCN_LNK_INFO, such as `.drectve`.
        if (flags & 0xa00 != 0) return null;
        const left_out = [_][]const u8{ ".debug", ".llvm_addrsig", ".llvm." };
        for (left_out) |p| if (std.mem.startsWith(u8, name, p)) return null;
        if (std.mem.startsWith(u8, name, ".pdata")) return .unwind;
        if (flags & 0x80 != 0) return .bss;
        if (flags & 0x2000_0020 != 0) return .text;
        if (flags & 0x8000_0000 != 0) return .data;
        return .rodata;
    }

    /// Maps a relocation of COFF onto the numbering of ELF, or onto the
    /// numbers of `link.zig` for those that only PE has, and reads its
    /// addend from the bytes. Returns null for one that does nothing.
    fn coffRel(arch: lobj.Arch, ty: u16, bytes: ?[]const u8, off: u32) !?struct { type: u32, addend: i64 } {
        if (arch != .x86_64) {
            std.log.err("COFF objects of {s} are not supported", .{@tagName(arch)});
            return error.Unsupported;
        }
        if (ty == 0) return null;
        const b = bytes orelse return error.Unsupported;
        const i32_at: i64 = std.mem.readInt(i32, b[off..][0..4], .little);
        return switch (ty) {
            1 => .{ .type = 1, .addend = std.mem.readInt(i64, b[off..][0..8], .little) }, // ADDR64
            2 => .{ .type = 10, .addend = i32_at }, // ADDR32
            3 => .{ .type = lobj.pe_addr32nb, .addend = i32_at }, // ADDR32NB
            // REL32 and REL32_1 to REL32_5, relative to the end of the
            // field and 0 to 5 more bytes.
            4...9 => .{ .type = 2, .addend = i32_at - 4 - (ty - 4) },
            0xb => .{ .type = lobj.pe_secrel, .addend = i32_at }, // SECREL
            else => {
                std.log.err("COFF relocation type {d} is not supported", .{ty});
                return error.Unsupported;
            },
        };
    }

    /// Reads a short member of an import library, which defines the slot
    /// `__imp_NAME` of the import table and, for a function, `NAME` as a
    /// jump through that slot.
    fn parseImport(c: *Converter, name: []const u8, data: []const u8) !Input {
        const size = rd(u32, data, 12);
        const info = rd(u16, data, 18);
        const strs = data[20..][0..size];
        const sym = std.mem.sliceTo(strs, 0);
        const rest = strs[sym.len + 1 ..];
        const dll = std.mem.sliceTo(rest, 0);
        const name_type = (info >> 2) & 7;
        var export_name: []const u8 = sym;
        switch (name_type) {
            1 => {},
            // NAME_NOPREFIX and NAME_UNDECORATE drop a leading `?`, `@`,
            // or `_`, and the second also what follows a later `@`.
            2, 3 => {
                if (export_name.len > 0 and std.mem.indexOfScalar(u8, "?@_", export_name[0]) != null) export_name = export_name[1..];
                if (name_type == 3) export_name = export_name[0 .. std.mem.indexOfScalar(u8, export_name, '@') orelse export_name.len];
            },
            4 => export_name = std.mem.sliceTo(rest[dll.len + 1 ..], 0),
            else => export_name = "",
        }
        const code = info & 3 == 0;
        const syms = try c.arena.alloc(Sym, if (code) 2 else 1);
        syms[0] = .{ .name = try std.fmt.allocPrint(c.arena, "__imp_{s}", .{sym}), .value = 0, .size = 8, .shndx = import_sec, .bind = .global };
        if (code) syms[1] = .{ .name = sym, .value = 0, .size = 6, .shndx = thunk_sec, .bind = .global };
        return .{ .name = name, .data = data, .secs = &.{}, .syms = syms, .rels = &.{}, .imp = .{ .name = export_name, .dll = dll, .code = code } };
    }

    fn rd(comptime T: type, data: []const u8, off: usize) T {
        return std.mem.readInt(T, data[off..][0..@sizeOf(T)], .little);
    }

    /// The `len` bytes at `off` of an input, which is in memory, so both
    /// fit a `usize` on a 32-bit host too.
    fn slice(data: []const u8, off: u64, len: u64) []const u8 {
        return data[@intCast(off)..][0..@intCast(len)];
    }

    fn cstr(data: []const u8, off: u64) []const u8 {
        const s = data[@intCast(off)..];
        return s[0..std.mem.indexOfScalar(u8, s, 0).?];
    }

    /// Loads input `i`: its sections become atoms and its globals become
    /// definitions. Relocations are resolved once every input is loaded.
    fn load(c: *Converter, i: u32) !void {
        const in = &c.inputs.items[i];
        if (in.loaded) return;
        in.loaded = true;
        in.atoms = try c.arena.alloc(?u32, in.secs.len);
        @memset(in.atoms, null);
        in.base = try c.arena.alloc(u32, in.secs.len);
        @memset(in.base, 0);
        if (in.imp) |*imp| {
            if (imp.name.len == 0) {
                std.log.err("{s}: imports by ordinal are not supported", .{in.name});
                return error.Unsupported;
            }
            imp.target = try c.w.import(imp.name, imp.dll, false);
            // jmp qword ptr [rip + slot]
            if (imp.code) imp.thunk = try c.w.atom(.text, 1, &.{ 0xff, 0x25, 0, 0, 0, 0 }, 6, in.syms[1].name);
        }
        // Members of a group seen before stay out.
        var skip = try c.arena.alloc(bool, in.secs.len);
        @memset(skip, false);
        for (in.groups) |g| {
            const gop = try c.groups.getOrPut(c.gpa, g.sig);
            if (!gop.found_existing) continue;
            for (g.members) |m| skip[m] = true;
        }
        for (in.secs, 0..) |s, k| {
            if (skip[k]) continue;
            const kind = s.kind orelse continue;
            if (s.size == 0) continue;
            if (s.unsupported) {
                std.log.err("{s}: {s} is not supported", .{ in.name, s.name });
                return error.Unsupported;
            }
            if (s.group != null) {
                try c.pending.append(c.gpa, .{ .input = i, .sec = @intCast(k) });
                continue;
            }
            const a = try c.w.atom(kind, s.align_log2, s.bytes, @intCast(s.size), atomName(in, @intCast(k)));
            in.atoms[k] = a;
            if (kind == .init_array or kind == .fini_array) try c.w.roots.append(c.gpa, a);
        }
        for (in.syms, 0..) |s, k| {
            if (!s.defines()) continue;
            if (s.shndx < in.secs.len and skip[s.shndx]) continue;
            const gop = try c.defs.getOrPut(c.gpa, s.name);
            if (gop.found_existing) {
                const old = c.inputs.items[gop.value_ptr.input].syms[gop.value_ptr.sym];
                if (!(old.bind == .weak and s.bind == .global) and old.shndx != common_sec) continue;
            }
            gop.value_ptr.* = .{ .input = i, .sym = @intCast(k) };
        }
    }

    fn atomName(in: *const Input, sec: u32) []const u8 {
        var best: ?Sym = null;
        for (in.syms) |s| {
            if (s.shndx != sec or s.value != 0 or s.name.len == 0 or s.section) continue;
            if (best == null or s.bind != .local) best = s;
        }
        return if (best) |b| b.name else in.secs[sec].name;
    }

    /// Loads the archive members that define what loaded inputs need.
    pub fn resolve(c: *Converter) !void {
        var changed = true;
        while (changed) {
            changed = false;
            var k: usize = 0;
            while (k < c.inputs.items.len) : (k += 1) {
                const in = c.inputs.items[k];
                if (!in.loaded) continue;
                for (in.syms) |s| {
                    if (s.shndx != undef_sec or s.bind != .global or s.name.len == 0) continue;
                    if (c.defs.contains(s.name)) continue;
                    const m = c.offers.get(s.name) orelse continue;
                    if (c.inputs.items[m].loaded) continue;
                    try c.load(m);
                    changed = true;
                }
            }
        }
    }

    const Resolved = struct { target: lobj.Target, sym: u32 = 0, addend: i64 };

    fn target(c: *Converter, in: *const Input, sym_index: u32, addend: i64) !Resolved {
        const s = in.syms[sym_index];
        if (s.section or s.bind == .local) return c.defined(in, s, addend);
        // A name that the linker defines wins over a weak definition, such
        // as the stand-in header that the standard library of Zig exports
        // for objects.
        const by_linker = for (linker_defined) |n| {
            if (std.mem.eql(u8, n, s.name)) break true;
        } else false;
        if (c.defs.get(s.name)) |d| {
            const din = &c.inputs.items[d.input];
            const ds = din.syms[d.sym];
            if (ds.shndx == undef_sec) return c.target(din, ds.alias.?, addend);
            if (!(by_linker and ds.bind == .weak)) return c.defined(din, ds, addend);
        }
        if (s.shndx != undef_sec and !(by_linker and s.bind == .weak)) return c.defined(in, s, addend);
        if (by_linker) return .{ .target = try c.w.linkerName(s.name), .addend = addend };
        if (s.alias) |al| return c.target(in, al, addend);
        if (c.os == .windows) if (try c.windowsData(s.name)) |a| return .{ .target = .{ .index = @intCast(a), .space = .atom }, .addend = addend };
        // On macOS and iOS, libSystem provides what the objects leave
        // undefined, which `dyld` binds at load.
        if (c.macho()) return .{ .target = try c.w.import(s.name, lib_system, s.bind == .weak), .addend = addend };
        if (s.bind == .weak) return .{ .target = .none_target, .addend = addend };
        std.log.err("{s}: undefined symbol {s}", .{ in.name, s.name });
        return error.UndefinedSymbol;
    }

    fn defined(c: *Converter, in: *const Input, s: Sym, addend: i64) !Resolved {
        if (s.shndx == import_sec) return .{ .target = in.imp.?.target, .addend = addend };
        if (s.shndx == thunk_sec) return .{ .target = .{ .index = @intCast(in.imp.?.thunk.?), .space = .atom }, .addend = addend };
        if (s.shndx == abs_sec) return .{ .target = .none_target, .sym = std.math.cast(u32, s.value) orelse return error.Unsupported, .addend = addend };
        if (s.shndx == common_sec) {
            const gop = try c.commons.getOrPut(c.gpa, s.name);
            if (!gop.found_existing) {
                // The value of a common symbol is its alignment.
                const al: u8 = if (s.value <= 1) 0 else @intCast(std.math.log2_int(u64, s.value));
                gop.value_ptr.* = try c.w.atom(.bss, al, null, @intCast(s.size), s.name);
            }
            return .{ .target = .{ .index = @intCast(gop.value_ptr.*), .space = .atom }, .addend = addend };
        }
        const a = (if (s.shndx < in.atoms.len) in.atoms[s.shndx] else null) orelse {
            std.log.err("{s}: a relocation names {s} in the section {s}, which is left out", .{ in.name, s.name, if (s.shndx < in.secs.len) in.secs[s.shndx].name else "?" });
            return error.Unsupported;
        };
        return .{ .target = .{ .index = @intCast(a), .space = .atom }, .sym = @intCast(s.value + in.base[s.shndx]), .addend = addend };
    }

    /// The data that the linker of the C library of Windows defines: the
    /// lists of constructors and destructors in the form of GCC, each a
    /// marker of -1 and a null end with nothing between, and the empty
    /// list of pseudo relocations, whose start and end are one address.
    fn windowsData(c: *Converter, name: []const u8) !?u32 {
        const table = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "__CTOR_LIST__", "__CTOR_LIST__", "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00" },
            .{ "__DTOR_LIST__", "__DTOR_LIST__", "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00" },
            .{ "__RUNTIME_PSEUDO_RELOC_LIST__", "pseudo relocations", "\x00\x00\x00\x00\x00\x00\x00\x00" },
            .{ "__RUNTIME_PSEUDO_RELOC_LIST_END__", "pseudo relocations", "\x00\x00\x00\x00\x00\x00\x00\x00" },
        };
        for (table) |e| {
            if (!std.mem.eql(u8, name, e[0])) continue;
            const gop = try c.synthetic.getOrPut(c.gpa, e[1]);
            if (!gop.found_existing) gop.value_ptr.* = try c.w.atom(.rodata, 3, e[2], @intCast(e[2].len), e[1]);
            return gop.value_ptr.*;
        }
        return null;
    }

    /// Merges the pending sections of each group into one atom, in the
    /// order of their names, as the linker of Windows does for the
    /// sections whose names share the part before `$`. The tables of
    /// initializers of the C library run from a marker in `.CRT$XCA` to
    /// one in `.CRT$XCZ`, and the template of thread-local data from
    /// `.tls` to `.tls$ZZZ`.
    fn mergeGroups(c: *Converter) !void {
        for ([_][]const u8{ ".CRT", ".tls" }) |g| {
            var members: std.ArrayList(Pending) = .empty;
            for (c.pending.items) |p| if (std.mem.eql(u8, c.inputs.items[p.input].secs[p.sec].group.?, g)) try members.append(c.arena, p);
            if (members.items.len == 0) continue;
            std.mem.sort(Pending, members.items, c, struct {
                fn lt(cv: *Converter, a: Pending, b: Pending) bool {
                    return std.mem.lessThan(u8, cv.inputs.items[a.input].secs[a.sec].name, cv.inputs.items[b.input].secs[b.sec].name);
                }
            }.lt);
            var pos: u64 = 0;
            var al: u8 = 0;
            for (members.items) |m| {
                const sec = c.inputs.items[m.input].secs[m.sec];
                pos = std.mem.alignForward(u64, pos, @as(u64, 1) << @intCast(sec.align_log2));
                c.inputs.items[m.input].base[m.sec] = @intCast(pos);
                pos += sec.size;
                al = @max(al, sec.align_log2);
            }
            const bytes = try c.arena.alloc(u8, @intCast(pos));
            @memset(bytes, 0);
            for (members.items) |m| {
                const in = &c.inputs.items[m.input];
                if (in.secs[m.sec].bytes) |b| @memcpy(bytes[in.base[m.sec]..][0..b.len], b);
            }
            const a = try c.w.atom(if (std.mem.eql(u8, g, ".tls")) .data else .rodata, al, bytes, @intCast(pos), g);
            for (members.items) |m| c.inputs.items[m.input].atoms[m.sec] = a;
            try c.w.roots.append(c.gpa, a);
        }
    }

    /// Adds the relocations of every loaded section, the registrations,
    /// and the entry.
    pub fn finish(c: *Converter, entry: []const u8) !void {
        if (c.os == .windows) try c.mergeGroups();
        // Relocations go with their atoms, which are contiguous in the
        // writer only if added in atom order, so they are collected first.
        const n_atoms = c.w.atoms.items.len;
        const lists = try c.arena.alloc(std.ArrayList(lobj.Reloc), n_atoms);
        for (lists) |*l| l.* = .empty;
        for (c.inputs.items) |*in| {
            if (!in.loaded) continue;
            for (in.rels, 0..) |rels, k| {
                const a = in.atoms[k] orelse continue;
                for (rels) |r| {
                    const res = try c.target(in, r.sym, r.addend);
                    try lists[a].append(c.arena, .{ .offset = @intCast(r.offset + in.base[k]), .type = r.type, .target = res.target, .sym = res.sym, .addend = res.addend });
                }
            }
            // The jump of an import reads its slot.
            if (in.imp) |imp| if (imp.thunk) |t| {
                try lists[t].append(c.arena, .{ .offset = 2, .type = 2, .target = imp.target, .addend = -4 });
            };
        }
        // The loader of Windows finds the directory of thread-local data
        // that the C library defines, which nothing else reaches.
        if (c.os == .windows) if (c.defs.get("_tls_used")) |d| {
            const din = &c.inputs.items[d.input];
            const res = try c.defined(din, din.syms[d.sym], 0);
            try c.w.roots.append(c.gpa, res.target.index);
        };
        // Common symbols may have added atoms after the lists were made.
        c.w.relocs.clearRetainingCapacity();
        for (c.w.atoms.items, 0..) |*a, k| {
            a.first_reloc = @intCast(c.w.relocs.items.len);
            a.relocs = 0;
            if (k >= lists.len) continue;
            try c.w.relocs.appendSlice(c.gpa, lists[k].items);
            a.relocs = @intCast(lists[k].items.len);
        }
        try c.registrations(lists);
        const d = c.defs.get(entry) orelse {
            std.log.err("the entry {s} is not defined", .{entry});
            return error.UndefinedSymbol;
        };
        const din = &c.inputs.items[d.input];
        const res = try c.defined(din, din.syms[d.sym], 0);
        c.w.entry = .{ .name = try c.w.string(entry), .atom = res.target.index, .offset = res.sym };
    }

    /// Records the registrations of builtins that `aux.setFuncs` exports
    /// as `lus.reg:KIND:PATH:NAMES`, each a pointer to its array.
    fn registrations(c: *Converter, lists: []std.ArrayList(lobj.Reloc)) !void {
        var it = c.defs.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const in = &c.inputs.items[e.value_ptr.input];
            const s = in.syms[e.value_ptr.sym];
            if (std.mem.eql(u8, name, "lus.reg_layout")) {
                const b = (in.secs[s.shndx].bytes orelse return badRegistration(name, "its layout is in a zeroed section"))[@intCast(s.value)..][0..12];
                for (&c.w.reg_layout, 0..) |*f, k| f.* = std.mem.readInt(u32, b[k * 4 ..][0..4], .little);
                continue;
            }
            if (!std.mem.startsWith(u8, name, "lus.reg:")) continue;
            const rest = name["lus.reg:".len..];
            const k1 = std.mem.indexOfScalar(u8, rest, ':') orelse return badRegistration(name, "the name has no path");
            const k2 = std.mem.lastIndexOfScalar(u8, rest, ':').?;
            if (k2 == k1) return badRegistration(name, "the name has no list of entries");
            const kind = std.meta.stringToEnum(enum { fields, methods, library, always }, rest[0..k1]) orelse return badRegistration(name, "the kind is unknown");
            // A registration without entries has nothing to leave out.
            if (k2 + 1 == rest.len) continue;
            const holder = (if (s.shndx < in.atoms.len) in.atoms[s.shndx] else null) orelse return badRegistration(name, "its pointer is in a section that is left out");
            var found: ?lobj.Reloc = null;
            for (lists[holder].items) |r| if (r.offset == s.value) {
                found = r;
            };
            const r = found orelse return badRegistration(name, "no relocation holds the address of its array");
            if (r.target.space != .atom) return badRegistration(name, "its array is not an atom");
            try c.w.guards.append(c.gpa, .{
                .kind = @backingInt(kind),
                .path = try c.w.string(rest[k1 + 1 .. k2]),
                // A guard of one function carries a tag after `#`.
                .names = try c.w.string(rest[k2 + 1 .. std.mem.indexOfScalarPos(u8, rest, k2, '#') orelse rest.len]),
                .atom = r.target.index,
                .offset = @intCast(@as(i64, r.sym) + r.addend),
            });
        }
        if (c.w.guards.items.len > 0 and c.w.reg_layout[0] == 0) {
            std.log.err("the registrations have no layout (lus.reg_layout)", .{});
            return error.BadRegistration;
        }
    }
};

const macho_magic = 0xfeedfacf;

fn wrongArchitecture(name: []const u8) error{WrongArchitecture} {
    std.log.err("{s}: built for another architecture", .{name});
    return error.WrongArchitecture;
}

fn badRegistration(name: []const u8, why: []const u8) error{BadRegistration} {
    std.log.err("the registration {s}: {s}", .{ name, why });
    return error.BadRegistration;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args_list: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(arena);
    while (it.next()) |a| try args_list.append(arena, a);
    const args = args_list.items;
    var arch: ?lobj.Arch = null;
    var os: ?lobj.Os = null;
    var entry: []const u8 = "_start";
    var out: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const a = args[k];
        if (std.mem.eql(u8, a, "--arch")) {
            k += 1;
            arch = std.meta.stringToEnum(lobj.Arch, args[k]);
        } else if (std.mem.eql(u8, a, "--os")) {
            k += 1;
            os = std.meta.stringToEnum(lobj.Os, args[k]);
        } else if (std.mem.eql(u8, a, "--entry")) {
            k += 1;
            entry = args[k];
        } else if (std.mem.eql(u8, a, "--link-line")) {
            // The command with which Zig links an executable for the
            // target, which names the startup object, libc, and
            // compiler_rt in its cache.
            k += 1;
            const line = try std.Io.Dir.cwd().readFileAlloc(io, args[k], arena, .unlimited);
            var tok = std.mem.tokenizeAny(u8, line, " \n\t");
            while (tok.next()) |t| {
                const base = std.fs.path.basename(t);
                const wanted = [_][]const u8{ "crt1.o", "rcrt1.o", "libc.a", "libcompiler_rt.a", "crt2.obj" };
                for (wanted) |w| if (std.mem.eql(u8, base, w)) try files.append(arena, t);
                // On Windows, the C library and the import libraries.
                if (os != null and os.? == .windows and std.mem.endsWith(u8, base, ".lib") and !std.mem.startsWith(u8, t, "-")) try files.append(arena, t);
            }
        } else if (std.mem.eql(u8, a, "-o")) {
            k += 1;
            out = args[k];
        } else try files.append(arena, a);
    }
    if (arch == null or os == null or out == null) {
        std.log.err("usage: lus-convert --arch ARCH --os OS [--entry NAME] -o OUT INPUT...", .{});
        return error.Usage;
    }
    var c: Converter = .init(gpa, arena, arch.?, os.?);
    defer c.deinit();
    const cwd = std.Io.Dir.cwd();
    for (files.items) |f| {
        const data = try cwd.readFileAlloc(io, f, arena, .unlimited);
        try c.addFile(f, data);
    }
    try c.resolve();
    try c.finish(entry);
    var buf: [64 * 1024]u8 = undefined;
    const file = try cwd.createFile(io, out.?, .{});
    defer file.close(io);
    var fw = file.writer(io, &buf);
    try c.w.write(&fw.interface);
    try fw.interface.flush();
}
