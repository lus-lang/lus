//! The link object (`spec/design/aot.md`, "The link object"): the runtime
//! of one target as atoms with their relocations, which the linker of
//! `lus build --aot` reads. The converter (`convert.zig`) writes it at
//! release time from the relocatable objects that Zig and the C compiler
//! produce.
//!
//! Relocation types are those of ELF for the architecture, which the
//! converter of another object format maps its relocations onto. A
//! relocation targets an atom, a name that the linker defines, such as
//! `__init_array_start`, a symbol that a shared library of the system
//! provides at load, or nothing for an undefined weak symbol.
//!
//! The file is little endian: the magic, the target, then the sections
//! that `Writer.write` lists, each a count followed by fixed records, and
//! last the string table and the bytes of the atoms.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "LUSLINK\x04";

pub const Arch = enum(u8) {
    x86_64,
    aarch64,
    /// 32-bit ARM, ARMv7-A in the ARM state with the hard-float ABI.
    arm,
    riscv64,
    loongarch64,
    powerpc64le,
    s390x,

    /// The byte order of the architecture, which its code and data use.
    pub fn endian(a: Arch) std.builtin.Endian {
        return if (a == .s390x) .big else .little;
    }

    /// The size of an address on the architecture.
    pub fn wordSize(a: Arch) u8 {
        return if (a == .arm) 4 else 8;
    }
};

/// The relocation types that only PE has, numbered past those of ELF: the
/// address of a target from the start of the image, and its offset from
/// the start of its section, which code uses for thread-local variables.
pub const pe_addr32nb = 0x1003;
pub const pe_secrel = 0x100b;
/// The parts of the offset of a thread-local variable from the start of
/// its section that arm64 code adds or loads with an immediate of 12
/// bits: bits 0 to 11 of an `add`, bits 12 to 23 of an `add` shifted by
/// 12, and bits 0 to 11 of a load or a store, scaled by its size.
pub const pe_secrel_lo12a = 0x1109;
pub const pe_secrel_hi12a = 0x110a;
pub const pe_secrel_lo12l = 0x110b;
pub const Os = enum(u8) {
    linux,
    macos,
    ios,
    windows,
    ios_simulator,
    freebsd,

    /// Whether executables for the system are Mach-O files that load libSystem.
    pub fn darwin(os: Os) bool {
        return os == .macos or os == .ios or os == .ios_simulator;
    }

    /// Whether the system is iOS, on a device or in the simulator.
    pub fn iphone(os: Os) bool {
        return os == .ios or os == .ios_simulator;
    }
};

pub const Kind = enum(u8) {
    text,
    rodata,
    data,
    bss,
    tdata,
    tbss,
    /// Pointers to functions that run before `main`, in order.
    init_array,
    /// Pointers to functions that run at exit.
    fini_array,
    /// The descriptors of thread-local variables on Mach-O, which `dyld`
    /// finds by the type of their section.
    thread_vars,
    /// Entries of the function table of PE, 12 bytes each: the start and
    /// the end of a function and its unwind information. The linker keeps
    /// an entry whose function it keeps.
    unwind,
};

pub const Atom = extern struct {
    kind: Kind,
    align_log2: u8,
    pad: u16 = 0,
    size: u32,
    /// The offset of the bytes in the data of the file, unused for the
    /// zeroed kinds.
    data: u32,
    first_reloc: u32,
    relocs: u32,
    /// The offset of the name in the string table: the symbol or the
    /// section the atom came from.
    name: u32,
};

/// The target of a relocation: an atom, a name the linker defines, an
/// import, or nothing.
pub const Target = packed struct(u32) {
    index: u30,
    space: enum(u2) { atom, linker, none, import },

    pub const none_target: Target = .{ .index = 0, .space = .none };
};

/// A relocation at `offset` in its atom. The symbol it names is at
/// `sym` bytes into the target atom, and `addend` is the addend of the
/// relocation, kept apart for the relocations that go through the global
/// offset table or the thread pointer.
pub const Reloc = extern struct {
    offset: u32,
    type: u32,
    target: Target,
    sym: u32 = 0,
    addend: i64,
};

/// How a program reaches the entries of a registration, in the order of
/// `aux.Kind`.
pub const GuardKind = enum(u8) { fields, methods, library, always };

/// A registration of builtins (`aux.setFuncs`): the entries `names` of
/// kind `kind` at `path`, stored as an array at `offset` in `atom`.
pub const Guard = extern struct {
    kind: u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    path: u32,
    names: u32,
    atom: u32,
    offset: u32,
};

/// A symbol that the shared library `lib` (an index into `libs`) defines,
/// bound when the system loader maps the executable. A weak import may be
/// missing, and its address is then zero. An import of data has its size
/// from the library, so an executable that addresses it directly holds
/// a copy of it. On FreeBSD an import names the version of the symbol
/// that the library defines by default, which the loader binds it to.
/// The version 0 is the empty string, for a symbol without a version.
pub const Import = extern struct {
    name: u32,
    lib: u16,
    weak: u8,
    data: u8 = 0,
    size: u32 = 0,
    version: u32 = 0,
};

/// A global symbol that the linker may name: the entry point, and on
/// FreeBSD the definitions of the executable that the shared libraries
/// of the system name, which the executable exports.
pub const Symbol = extern struct {
    name: u32,
    atom: u32,
    offset: u32,
};

pub const Object = struct {
    arch: Arch,
    os: Os,
    /// The size of an entry of a registration, and the offsets of its
    /// function and its fast path.
    reg_layout: [3]u32,
    entry: Symbol,
    atoms: []const Atom,
    relocs: []const Reloc,
    guards: []const Guard,
    symbols: []const Symbol,
    /// Atoms that are kept whatever the program reaches, apart from the
    /// entry and the arrays of functions that run before `main`.
    roots: []const u32,
    /// The names that relocations of space `linker` index.
    linker_names: []const u32,
    /// The symbols that relocations of space `import` index.
    imports: []const Import,
    /// The names of the shared libraries of the imports, in the form the
    /// loader of the system finds them: an install name on Mach-O, a DLL
    /// name on Windows.
    libs: []const u32,
    strings: []const u8,
    data: []const u8,

    pub fn string(o: *const Object, off: u32) []const u8 {
        const s = o.strings[off..];
        return s[0..std.mem.indexOfScalar(u8, s, 0).?];
    }

    pub fn bytes(o: *const Object, a: Atom) []const u8 {
        return o.data[a.data..][0..a.size];
    }

    pub fn atomRelocs(o: *const Object, a: Atom) []const Reloc {
        return o.relocs[a.first_reloc..][0..a.relocs];
    }
};

pub const Error = error{ BadLinkObject, OutOfMemory };

/// Reads a link object. The result points into `buf`, which must stay
/// alive and be aligned to 8 bytes.
/// Reads the link object in `buf`. The file is little endian, so on a
/// big-endian host the records of `buf` are swapped in place, and `buf`
/// is read once.
pub fn read(buf: []align(8) u8) Error!Object {
    var r: Reader = .{ .buf = buf };
    if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.BadLinkObject;
    const arch = std.enums.fromInt(Arch, try r.int(u8)) orelse return error.BadLinkObject;
    const os = std.enums.fromInt(Os, try r.int(u8)) orelse return error.BadLinkObject;
    r.pos = std.mem.alignForward(usize, r.pos, 4);
    const layout = try r.slice(u32, 3);
    const entry = (try r.slice(Symbol, 1))[0];
    const atoms = try r.counted(Atom);
    const relocs = try r.counted(Reloc);
    const guards = try r.counted(Guard);
    const symbols = try r.counted(Symbol);
    const roots = try r.counted(u32);
    const linker_names = try r.counted(u32);
    const imports = try r.counted(Import);
    const libs = try r.counted(u32);
    const strings = try r.counted(u8);
    r.pos = std.mem.alignForward(usize, r.pos, 8);
    const data = try r.counted(u8);
    const o: Object = .{
        .arch = arch,
        .os = os,
        .reg_layout = layout[0..3].*,
        .entry = entry,
        .atoms = atoms,
        .relocs = relocs,
        .guards = guards,
        .symbols = symbols,
        .roots = roots,
        .linker_names = linker_names,
        .imports = imports,
        .libs = libs,
        .strings = strings,
        .data = data,
    };
    // Every index the linker follows is checked once here.
    if (strings.len == 0 or strings[strings.len - 1] != 0) return error.BadLinkObject;
    for (atoms) |a| {
        if (@as(u64, a.first_reloc) + a.relocs > relocs.len) return error.BadLinkObject;
        if (a.name >= strings.len or a.align_log2 > 16) return error.BadLinkObject;
        if (std.enums.fromInt(Kind, @backingInt(a.kind)) == null) return error.BadLinkObject;
        if (zeroed(a.kind)) continue;
        if (@as(u64, a.data) + a.size > data.len) return error.BadLinkObject;
    }
    for (relocs) |rel| switch (rel.target.space) {
        .atom => if (rel.target.index >= atoms.len) return error.BadLinkObject,
        .linker => if (rel.target.index >= linker_names.len) return error.BadLinkObject,
        .import => if (rel.target.index >= imports.len) return error.BadLinkObject,
        .none => {},
    };
    for (imports) |im| if (im.name >= strings.len or im.lib >= libs.len or im.version >= strings.len) return error.BadLinkObject;
    for (libs) |n| if (n >= strings.len) return error.BadLinkObject;
    for (linker_names) |n| if (n >= strings.len) return error.BadLinkObject;
    for (roots) |a| if (a >= atoms.len) return error.BadLinkObject;
    for (guards) |g| if (g.atom >= atoms.len or g.path >= strings.len or g.names >= strings.len or g.kind > 3) return error.BadLinkObject;
    for (symbols) |s| if (s.atom >= atoms.len or s.name >= strings.len) return error.BadLinkObject;
    if (entry.atom >= atoms.len) return error.BadLinkObject;
    return o;
}

pub fn zeroed(k: Kind) bool {
    return k == .bss or k == .tbss;
}

const Reader = struct {
    buf: []align(8) u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) Error![]u8 {
        if (n > r.buf.len - r.pos) return error.BadLinkObject;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn slice(r: *Reader, comptime T: type, n: usize) Error![]const T {
        r.pos = std.mem.alignForward(usize, r.pos, @alignOf(T));
        const b = try r.take(std.math.mul(usize, n, @sizeOf(T)) catch return error.BadLinkObject);
        const items: []T = @alignCast(std.mem.bytesAsSlice(T, b));
        if (@import("builtin").cpu.arch.endian() == .big) std.mem.byteSwapAllElements(T, items);
        return items;
    }

    fn counted(r: *Reader, comptime T: type) Error![]const T {
        r.pos = std.mem.alignForward(usize, r.pos, 8);
        const n = try r.int(u64);
        return r.slice(T, std.math.cast(usize, n) orelse return error.BadLinkObject);
    }
};

/// Builds a link object in memory.
pub const Writer = struct {
    gpa: Allocator,
    arch: Arch,
    os: Os,
    reg_layout: [3]u32 = .{ 0, 0, 0 },
    entry: Symbol = .{ .name = 0, .atom = 0, .offset = 0 },
    atoms: std.ArrayList(Atom) = .empty,
    relocs: std.ArrayList(Reloc) = .empty,
    guards: std.ArrayList(Guard) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    roots: std.ArrayList(u32) = .empty,
    linker_names: std.ArrayList(u32) = .empty,
    imports: std.ArrayList(Import) = .empty,
    libs: std.ArrayList(u32) = .empty,
    strings: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    string_index: std.StringHashMapUnmanaged(u32) = .empty,

    /// A writer that holds everything `o` holds, to which more atoms can
    /// be added.
    pub fn fromObject(gpa: Allocator, o: *const Object) Allocator.Error!Writer {
        var w: Writer = .{ .gpa = gpa, .arch = o.arch, .os = o.os, .reg_layout = o.reg_layout, .entry = o.entry };
        errdefer w.deinit();
        try w.atoms.appendSlice(gpa, o.atoms);
        try w.relocs.appendSlice(gpa, o.relocs);
        try w.guards.appendSlice(gpa, o.guards);
        try w.symbols.appendSlice(gpa, o.symbols);
        try w.roots.appendSlice(gpa, o.roots);
        try w.linker_names.appendSlice(gpa, o.linker_names);
        try w.imports.appendSlice(gpa, o.imports);
        try w.libs.appendSlice(gpa, o.libs);
        try w.strings.appendSlice(gpa, o.strings);
        try w.data.appendSlice(gpa, o.data);
        return w;
    }

    pub fn deinit(w: *Writer) void {
        inline for (.{ "atoms", "relocs", "guards", "symbols", "roots", "linker_names", "imports", "libs", "strings", "data" }) |f| @field(w, f).deinit(w.gpa);
        var it = w.string_index.keyIterator();
        while (it.next()) |k| w.gpa.free(k.*);
        w.string_index.deinit(w.gpa);
    }

    /// The offset of `s` in the string table, adding it once.
    pub fn string(w: *Writer, s: []const u8) Allocator.Error!u32 {
        if (w.strings.items.len == 0) try w.strings.append(w.gpa, 0);
        if (s.len == 0) return 0;
        if (w.string_index.get(s)) |off| return off;
        const off: u32 = @intCast(w.strings.items.len);
        try w.strings.appendSlice(w.gpa, s);
        try w.strings.append(w.gpa, 0);
        // The key is a copy, since the table of strings moves as it grows.
        const key = try w.gpa.dupe(u8, s);
        errdefer w.gpa.free(key);
        try w.string_index.put(w.gpa, key, off);
        return off;
    }

    /// The index for the linker-defined name `s`.
    pub fn linkerName(w: *Writer, s: []const u8) Allocator.Error!Target {
        const off = try w.string(s);
        for (w.linker_names.items, 0..) |n, i| if (n == off) return .{ .index = @intCast(i), .space = .linker };
        try w.linker_names.append(w.gpa, off);
        return .{ .index = @intCast(w.linker_names.items.len - 1), .space = .linker };
    }

    /// The target for the function `name` of the shared library `lib`,
    /// added once.
    pub fn import(w: *Writer, name: []const u8, lib: []const u8, weak: bool) Allocator.Error!Target {
        return w.importOf(name, lib, weak, null, null);
    }

    /// The index of the shared library `lib`, added once. The loader
    /// searches the libraries in this order.
    pub fn library(w: *Writer, lib: []const u8) Allocator.Error!u16 {
        const lib_off = try w.string(lib);
        if (std.mem.indexOfScalar(u32, w.libs.items, lib_off)) |i| return @intCast(i);
        try w.libs.append(w.gpa, lib_off);
        return @intCast(w.libs.items.len - 1);
    }

    /// The target for the symbol `name` of the shared library `lib`, added
    /// once: a function, or data of `data_size` bytes, of the symbol
    /// version `version`.
    pub fn importOf(w: *Writer, name: []const u8, lib: []const u8, weak: bool, data_size: ?u32, version: ?[]const u8) Allocator.Error!Target {
        const li = try w.library(lib);
        const off = try w.string(name);
        for (w.imports.items, 0..) |im, i| if (im.name == off) {
            // A strong reference anywhere makes the import strong.
            if (!weak) w.imports.items[i].weak = 0;
            return .{ .index = @intCast(i), .space = .import };
        };
        try w.imports.append(w.gpa, .{ .name = off, .lib = li, .weak = @intFromBool(weak), .data = @intFromBool(data_size != null), .size = data_size orelse 0, .version = if (version) |v| try w.string(v) else 0 });
        return .{ .index = @intCast(w.imports.items.len - 1), .space = .import };
    }

    /// Adds an atom with bytes `bytes`, or `size` zero bytes when `bytes`
    /// is null. Its relocations follow with `reloc`.
    pub fn atom(w: *Writer, kind: Kind, align_log2: u8, bytes: ?[]const u8, size: u32, name: []const u8) Allocator.Error!u32 {
        var data: u32 = 0;
        if (bytes) |b| {
            while (w.data.items.len % 8 != 0) try w.data.append(w.gpa, 0);
            data = @intCast(w.data.items.len);
            try w.data.appendSlice(w.gpa, b);
        }
        try w.atoms.append(w.gpa, .{
            .kind = kind,
            .align_log2 = align_log2,
            .size = size,
            .data = data,
            .first_reloc = @intCast(w.relocs.items.len),
            .relocs = 0,
            .name = try w.string(name),
        });
        return @intCast(w.atoms.items.len - 1);
    }

    /// Adds a relocation to the atom added last.
    pub fn reloc(w: *Writer, rel: Reloc) Allocator.Error!void {
        try w.relocs.append(w.gpa, rel);
        w.atoms.items[w.atoms.items.len - 1].relocs += 1;
    }

    pub fn write(w: *Writer, out: *std.Io.Writer) !void {
        _ = try w.string("");
        try out.writeAll(magic);
        try out.writeByte(@backingInt(w.arch));
        try out.writeByte(@backingInt(w.os));
        var pos: usize = magic.len + 2;
        try pad(out, &pos, 4);
        try raw(out, &pos, std.mem.sliceAsBytes(&w.reg_layout));
        try raw(out, &pos, std.mem.asBytes(&w.entry));
        try counted(out, &pos, Atom, w.atoms.items);
        try counted(out, &pos, Reloc, w.relocs.items);
        try counted(out, &pos, Guard, w.guards.items);
        try counted(out, &pos, Symbol, w.symbols.items);
        try counted(out, &pos, u32, w.roots.items);
        try counted(out, &pos, u32, w.linker_names.items);
        try counted(out, &pos, Import, w.imports.items);
        try counted(out, &pos, u32, w.libs.items);
        try counted(out, &pos, u8, w.strings.items);
        try counted(out, &pos, u8, w.data.items);
    }

    fn pad(out: *std.Io.Writer, pos: *usize, a: usize) !void {
        while (pos.* % a != 0) : (pos.* += 1) try out.writeByte(0);
    }

    fn raw(out: *std.Io.Writer, pos: *usize, b: []const u8) !void {
        try out.writeAll(b);
        pos.* += b.len;
    }

    fn counted(out: *std.Io.Writer, pos: *usize, comptime T: type, items: []const T) !void {
        try pad(out, pos, 8);
        var n: [8]u8 = undefined;
        std.mem.writeInt(u64, &n, items.len, .little);
        try raw(out, pos, &n);
        try pad(out, pos, @alignOf(T));
        try raw(out, pos, std.mem.sliceAsBytes(items));
    }
};

test "a link object reads back what was written" {
    const gpa = std.testing.allocator;
    var w: Writer = .{ .gpa = gpa, .arch = .x86_64, .os = .linux };
    defer w.deinit();
    const a = try w.atom(.text, 4, "\xc3", 1, "f");
    const b = try w.atom(.data, 3, &@as([8]u8, @splat(0)), 8, "p");
    try w.reloc(.{ .offset = 0, .type = 1, .target = .{ .index = @intCast(a), .space = .atom }, .addend = 0 });
    w.entry = .{ .name = try w.string("_start"), .atom = a, .offset = 0 };
    try w.roots.append(gpa, b);
    const im = try w.import("malloc", "/usr/lib/libSystem.B.dylib", false);
    try w.reloc(.{ .offset = 0, .type = 1, .target = im, .addend = 0 });
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try w.write(&buf.writer);
    const bytes = try gpa.alignedAlloc(u8, .@"8", buf.written().len);
    defer gpa.free(bytes);
    @memcpy(bytes, buf.written());
    const o = try read(bytes);
    try std.testing.expectEqual(@as(usize, 2), o.atoms.len);
    try std.testing.expectEqualStrings("p", o.string(o.atoms[1].name));
    try std.testing.expectEqual(@as(u8, 0xc3), o.bytes(o.atoms[0])[0]);
    try std.testing.expectEqual(a, o.atomRelocs(o.atoms[1])[0].target.index);
    try std.testing.expectEqualStrings("_start", o.string(o.entry.name));
    try std.testing.expectEqualStrings("malloc", o.string(o.imports[0].name));
    try std.testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", o.string(o.libs[o.imports[0].lib]));
}
