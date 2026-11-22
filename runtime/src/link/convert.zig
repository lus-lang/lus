//! The converter that writes the link object (`lobj.zig`) of a target
//! from relocatable ELF objects and archives. Only the release build runs
//! it, so a construct that the linker does not handle fails there:
//!
//!   lus-convert --arch x86_64 --os linux [--entry _start] [--link-line FILE] -o OUT INPUT...
//!
//! The inputs are the runtime object of `zig build link-object`, the C
//! libraries, and on Linux the startup object and libc of musl. Objects
//! are always loaded. An archive member is loaded when it defines a
//! symbol that a loaded object needs, as a linker does. Each allocated
//! section of a loaded object becomes an atom, apart from the unwind
//! tables and the notes, which executables compiled ahead of time leave
//! out.

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
    "edata",
};

const Sec = struct {
    name: []const u8,
    type: u32,
    flags: u64,
    offset: u64,
    size: u64,
    align_log2: u8,
    info: u32,
    link: u32,
};

const Sym = struct {
    name: []const u8,
    value: u64,
    size: u64,
    shndx: u16,
    bind: u8,
    type: u8,
};

const Input = struct {
    name: []const u8,
    data: []const u8,
    secs: []Sec,
    syms: []Sym,
    /// The atom of each section, once the object is loaded.
    atoms: []?u32 = &.{},
    loaded: bool = false,
};

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
    machine: elf.EM,

    pub fn init(gpa: Allocator, arena: Allocator, arch: lobj.Arch, os: lobj.Os) Converter {
        return .{
            .gpa = gpa,
            .arena = arena,
            .w = .{ .gpa = gpa, .arch = arch, .os = os },
            .machine = switch (arch) {
                .x86_64 => .X86_64,
                .aarch64 => .AARCH64,
            },
        };
    }

    pub fn deinit(c: *Converter) void {
        c.w.deinit();
        c.inputs.deinit(c.gpa);
        c.defs.deinit(c.gpa);
        c.offers.deinit(c.gpa);
        c.groups.deinit(c.gpa);
        c.commons.deinit(c.gpa);
    }

    /// Adds an object file, loaded at once, or an archive, whose members
    /// load as they are needed.
    pub fn addFile(c: *Converter, name: []const u8, data: []const u8) !void {
        if (std.mem.startsWith(u8, data, "!<arch>\n")) return c.addArchive(name, data);
        const i = try c.parse(name, data);
        try c.load(i);
    }

    fn addArchive(c: *Converter, name: []const u8, data: []const u8) !void {
        var pos: usize = 8;
        var long_names: []const u8 = "";
        while (pos + 60 <= data.len) {
            const hdr = data[pos..][0..60];
            const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, hdr[48..58], " "), 10) catch return error.BadArchive;
            const body = data[pos + 60 ..][0..size];
            const raw = std.mem.trimEnd(u8, hdr[0..16], " ");
            pos += 60 + size + (size & 1);
            if (std.mem.eql(u8, raw, "/") or std.mem.eql(u8, raw, "/SYM64/")) continue;
            if (std.mem.eql(u8, raw, "//")) {
                long_names = body;
                continue;
            }
            var mname = raw;
            if (raw.len > 1 and raw[0] == '/') {
                const off = std.fmt.parseInt(usize, raw[1..], 10) catch return error.BadArchive;
                const rest = long_names[off..];
                mname = rest[0 .. std.mem.indexOfAny(u8, rest, "/\n") orelse rest.len];
            } else if (std.mem.endsWith(u8, raw, "/")) mname = raw[0 .. raw.len - 1];
            if (!std.mem.startsWith(u8, body, elf.MAGIC)) continue;
            const i = try c.parse(try std.fmt.allocPrint(c.arena, "{s}({s})", .{ name, mname }), body);
            for (c.inputs.items[i].syms) |s| {
                if (s.shndx == elf.SHN_UNDEF or s.bind == elf.STB_LOCAL) continue;
                const gop = try c.offers.getOrPut(c.gpa, s.name);
                if (!gop.found_existing) gop.value_ptr.* = i;
            }
        }
    }

    fn parse(c: *Converter, name: []const u8, data: []const u8) !u32 {
        if (data.len < @sizeOf(elf.Elf64_Ehdr) or !std.mem.startsWith(u8, data, elf.MAGIC)) return error.NotElf;
        const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, data[0..@sizeOf(elf.Elf64_Ehdr)]);
        if (eh.e_type != .REL) return error.NotRelocatable;
        if (eh.e_machine != c.machine) {
            std.log.err("{s}: built for another architecture", .{name});
            return error.WrongArchitecture;
        }
        const shdrs = try c.arena.alloc(elf.Elf64_Shdr, eh.e_shnum);
        for (shdrs, 0..) |*sh, k| sh.* = std.mem.bytesToValue(elf.Elf64_Shdr, data[eh.e_shoff + k * @sizeOf(elf.Elf64_Shdr) ..][0..@sizeOf(elf.Elf64_Shdr)]);
        const shstr = shdrs[eh.e_shstrndx];
        const secs = try c.arena.alloc(Sec, shdrs.len);
        var symtab: ?elf.Elf64_Shdr = null;
        for (shdrs, secs) |sh, *s| {
            s.* = .{
                .name = cstr(data, shstr.sh_offset + sh.sh_name),
                .type = sh.sh_type,
                .flags = sh.sh_flags,
                .offset = sh.sh_offset,
                .size = sh.sh_size,
                .align_log2 = if (sh.sh_addralign <= 1) 0 else @intCast(std.math.log2_int(u64, sh.sh_addralign)),
                .info = sh.sh_info,
                .link = sh.sh_link,
            };
            if (sh.sh_type == elf.SHT_SYMTAB) symtab = sh;
        }
        var syms: []Sym = &.{};
        if (symtab) |st| {
            const strs = shdrs[st.sh_link];
            const n = st.sh_size / @sizeOf(elf.Elf64_Sym);
            syms = try c.arena.alloc(Sym, n);
            for (syms, 0..) |*s, k| {
                const es = std.mem.bytesToValue(elf.Elf64_Sym, data[st.sh_offset + k * @sizeOf(elf.Elf64_Sym) ..][0..@sizeOf(elf.Elf64_Sym)]);
                s.* = .{
                    .name = cstr(data, strs.sh_offset + es.st_name),
                    .value = es.st_value,
                    .size = es.st_size,
                    .shndx = es.st_shndx,
                    .bind = es.st_info >> 4,
                    .type = es.st_info & 0xf,
                };
            }
        }
        try c.inputs.append(c.gpa, .{ .name = name, .data = data, .secs = secs, .syms = syms });
        return @intCast(c.inputs.items.len - 1);
    }

    fn cstr(data: []const u8, off: u64) []const u8 {
        const s = data[off..];
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
        // Members of a group seen before stay out.
        var skip = try c.arena.alloc(bool, in.secs.len);
        @memset(skip, false);
        for (in.secs) |s| {
            if (s.type != elf.SHT_GROUP) continue;
            const sig = in.syms[s.info].name;
            const gop = try c.groups.getOrPut(c.gpa, sig);
            if (!gop.found_existing) continue;
            const members = std.mem.bytesAsSlice(u32, in.data[s.offset..][0..s.size]);
            for (members[1..]) |m| skip[std.mem.littleToNative(u32, m)] = true;
        }
        for (in.secs, 0..) |s, k| {
            if (skip[k] or s.flags & elf.SHF_ALLOC == 0) continue;
            if (s.size == 0) continue;
            if (std.mem.startsWith(u8, s.name, ".eh_frame") or std.mem.startsWith(u8, s.name, ".note") or std.mem.eql(u8, s.name, ".llvm_addrsig")) continue;
            if (std.mem.startsWith(u8, s.name, ".ctors") or std.mem.startsWith(u8, s.name, ".dtors")) {
                std.log.err("{s}: {s} is not supported", .{ in.name, s.name });
                return error.Unsupported;
            }
            const kind: lobj.Kind = if (s.flags & elf.SHF_TLS != 0)
                (if (s.type == elf.SHT_NOBITS) .tbss else .tdata)
            else if (s.type == elf.SHT_NOBITS)
                .bss
            else if (s.type == elf.SHT_INIT_ARRAY or s.type == elf.SHT_PREINIT_ARRAY)
                .init_array
            else if (s.type == elf.SHT_FINI_ARRAY)
                .fini_array
            else if (s.flags & elf.SHF_EXECINSTR != 0)
                .text
            else if (s.flags & elf.SHF_WRITE != 0)
                .data
            else
                .rodata;
            const bytes: ?[]const u8 = if (lobj.zeroed(kind)) null else in.data[s.offset..][0..s.size];
            const a = try c.w.atom(kind, s.align_log2, bytes, @intCast(s.size), atomName(in, @intCast(k)));
            in.atoms[k] = a;
            if (kind == .init_array or kind == .fini_array) try c.w.roots.append(c.gpa, a);
        }
        for (in.syms, 0..) |s, k| {
            if (s.bind == elf.STB_LOCAL or s.shndx == elf.SHN_UNDEF) continue;
            if (s.shndx < in.secs.len and skip[s.shndx]) continue;
            const gop = try c.defs.getOrPut(c.gpa, s.name);
            if (gop.found_existing) {
                const old = c.inputs.items[gop.value_ptr.input].syms[gop.value_ptr.sym];
                if (!(old.bind == elf.STB_WEAK and s.bind == elf.STB_GLOBAL) and old.shndx != elf.SHN_COMMON) continue;
            }
            gop.value_ptr.* = .{ .input = i, .sym = @intCast(k) };
        }
    }

    fn atomName(in: *const Input, sec: u32) []const u8 {
        var best: ?Sym = null;
        for (in.syms) |s| {
            if (s.shndx != sec or s.value != 0 or s.name.len == 0 or s.type == elf.STT_SECTION) continue;
            if (best == null or s.bind != elf.STB_LOCAL) best = s;
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
                    if (s.shndx != elf.SHN_UNDEF or s.bind != elf.STB_GLOBAL or s.name.len == 0) continue;
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
        if (s.type == elf.STT_SECTION or s.bind == elf.STB_LOCAL) return c.defined(in, s, addend);
        if (c.defs.get(s.name)) |d| {
            const din = &c.inputs.items[d.input];
            return c.defined(din, din.syms[d.sym], addend);
        }
        if (s.shndx != elf.SHN_UNDEF) return c.defined(in, s, addend);
        for (linker_defined) |n| if (std.mem.eql(u8, n, s.name)) return .{ .target = try c.w.linkerName(n), .addend = addend };
        if (s.bind == elf.STB_WEAK) return .{ .target = .none_target, .addend = addend };
        std.log.err("{s}: undefined symbol {s}", .{ in.name, s.name });
        return error.UndefinedSymbol;
    }

    fn defined(c: *Converter, in: *const Input, s: Sym, addend: i64) !Resolved {
        if (s.shndx == elf.SHN_ABS) return .{ .target = .none_target, .sym = std.math.cast(u32, s.value) orelse return error.Unsupported, .addend = addend };
        if (s.shndx == elf.SHN_COMMON) {
            const gop = try c.commons.getOrPut(c.gpa, s.name);
            if (!gop.found_existing) {
                // The value of a common symbol is its alignment.
                const al: u8 = if (s.value <= 1) 0 else @intCast(std.math.log2_int(u64, s.value));
                gop.value_ptr.* = try c.w.atom(.bss, al, null, @intCast(s.size), s.name);
            }
            return .{ .target = .{ .index = @intCast(gop.value_ptr.*), .space = .atom }, .addend = addend };
        }
        const a = (if (s.shndx < in.atoms.len) in.atoms[s.shndx] else null) orelse {
            std.log.err("{s}: a relocation names {s} in a section that is left out", .{ in.name, s.name });
            return error.Unsupported;
        };
        return .{ .target = .{ .index = @intCast(a), .space = .atom }, .sym = @intCast(s.value), .addend = addend };
    }

    /// Adds the relocations of every loaded section, the registrations,
    /// and the entry.
    pub fn finish(c: *Converter, entry: []const u8) !void {
        // Relocations go with their atoms, which are contiguous in the
        // writer only if added in atom order, so they are collected first.
        const n_atoms = c.w.atoms.items.len;
        const lists = try c.arena.alloc(std.ArrayList(lobj.Reloc), n_atoms);
        for (lists) |*l| l.* = .empty;
        for (c.inputs.items) |*in| {
            if (!in.loaded) continue;
            for (in.secs) |s| {
                if (s.type != elf.SHT_RELA) continue;
                const a = (if (s.info < in.atoms.len) in.atoms[s.info] else null) orelse continue;
                const n = s.size / @sizeOf(elf.Elf64_Rela);
                for (0..n) |k| {
                    const r = std.mem.bytesToValue(elf.Elf64_Rela, in.data[s.offset + k * @sizeOf(elf.Elf64_Rela) ..][0..@sizeOf(elf.Elf64_Rela)]);
                    const ty: u32 = @truncate(r.r_info);
                    if (ty == 0) continue;
                    const res = try c.target(in, @intCast(r.r_info >> 32), r.r_addend);
                    try lists[a].append(c.arena, .{ .offset = @intCast(r.r_offset), .type = ty, .target = res.target, .sym = res.sym, .addend = res.addend });
                }
            }
        }
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
                const sec = in.secs[s.shndx];
                const b = in.data[sec.offset + s.value ..][0..12];
                for (&c.w.reg_layout, 0..) |*f, k| f.* = std.mem.readInt(u32, b[k * 4 ..][0..4], .little);
                continue;
            }
            if (!std.mem.startsWith(u8, name, "lus.reg:")) continue;
            const rest = name["lus.reg:".len..];
            const k1 = std.mem.indexOfScalar(u8, rest, ':') orelse return error.BadRegistration;
            const k2 = std.mem.lastIndexOfScalar(u8, rest, ':').?;
            if (k2 == k1) return error.BadRegistration;
            const kind = std.meta.stringToEnum(enum { fields, methods, library, always }, rest[0..k1]) orelse return error.BadRegistration;
            const holder = in.atoms[s.shndx] orelse return error.BadRegistration;
            var found: ?lobj.Reloc = null;
            for (lists[holder].items) |r| if (r.offset == s.value) {
                found = r;
            };
            const r = found orelse return error.BadRegistration;
            if (r.target.space != .atom) return error.BadRegistration;
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
                const wanted = [_][]const u8{ "crt1.o", "rcrt1.o", "libc.a", "libcompiler_rt.a" };
                for (wanted) |w| if (std.mem.eql(u8, base, w)) try files.append(arena, t);
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
