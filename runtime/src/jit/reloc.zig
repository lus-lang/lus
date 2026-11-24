//! Relocations of native code compiled ahead of time (`spec/design/aot.md`).
//! Native code embeds absolute addresses. When the emitter compiles for
//! an executable that loads the code later, each address becomes a
//! relocation that names what the address points to, and the loader
//! writes the address of the running process in its place.
//!
//! Every assembler records a relocation where `movImmReloc`,
//! `storeImm64Reloc`, or `callReloc` writes an address, in a form whose
//! bytes the loader can patch. When the assembler compiles for the JIT,
//! those routines are `movImm`, `storeImm64`, and `call`, and record
//! nothing.

const std = @import("std");

/// What an address points to.
pub const Kind = enum(u8) {
    /// A value that is not an address, such as an integer constant of
    /// the program. It needs no relocation, and naming it tells the
    /// coverage check that a wide immediate is intended.
    literal,
    /// Routine `a` of `jit.routines`, which native code calls.
    routine,
    /// The global state, plus `a` bytes.
    global,
    /// The function `a`, numbered in the order of the bundled chunks.
    proto,
    /// Constant `b` of function `a`.
    proto_const,
    /// The inline cache entry of instruction `b` of function `a`, plus
    /// the offset `c`.
    ic,
    /// A field of function `a`, at `b` bytes from its start.
    proto_field,
    /// A field of the optimized unit of function `a` that starts at
    /// instruction `b`, at `c` bytes from its start.
    unit,
    /// The native function `a` of `jit.natives`.
    native,
    /// The object that constant `b` of function `a` holds: a string, a
    /// bigint, a decimal, or another collectable constant.
    const_obj,
    /// The object that the word of the global state at offset `a` holds,
    /// such as the name of a metamethod.
    global_value,
    /// The interned string whose characters are string `a` of the string
    /// table of the code.
    interned,
    /// The code of function `a` at offset `c`: its optimized unit that
    /// starts at instruction `b`, or its baseline code when `b` is
    /// `aot.baseline_pc`.
    code,
};

pub const Reloc = struct {
    kind: Kind,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,

    pub const literal: Reloc = .{ .kind = .literal };
};

/// The shape of the bytes that hold an address.
pub const Form = enum(u8) {
    /// Eight bytes in the byte order of the target: a pool word, or the
    /// immediate of x86-64 `movabs`.
    word,
    /// The five instructions of ppc64le that build an address 16 bits at
    /// a time: `lis`, `ori`, `sldi`, `oris`, and `ori`.
    ppc_seq,
    /// The two instructions of s390x that build an address 32 bits at a
    /// time: `llihf` and `iilf`.
    s390_pair,
    /// The aarch64 pair `adr` and `ldr`, which loads an address from a
    /// pool word that `adr` points at. In an executable on a target
    /// without executable memory, the linker points the pair at a slot of
    /// a data atom with `adrp` and `ldr`, and the loader writes the slot
    /// (`spec/design/aot.md`, "The linker").
    slot,
    /// The two instructions of 32-bit ARM that build an address 16 bits
    /// at a time: `movw` and `movt`. An address of a 32-bit target is one
    /// word, and the register pair that holds it has a zero high word.
    arm_pair,

    /// The number of bytes the form covers.
    pub fn size(f: Form) usize {
        return switch (f) {
            .word => 8,
            .ppc_seq => 20,
            .s390_pair => 12,
            .slot => 8,
            .arm_pair => 8,
        };
    }
};

/// The offset in `code` of the pool word that the `adr` at `at` points
/// at, or null when it lies outside the code.
pub fn slotTarget(code: []const u8, at: u32) ?usize {
    if (at + 4 > code.len) return null;
    const w = std.mem.readInt(u32, code[at..][0..4], .little);
    const imm: u21 = @truncate(((w >> 5) & 0x7FFFF) << 2 | ((w >> 29) & 3));
    const delta: i64 = @as(i21, @bitCast(imm));
    const target = @as(i64, at) + delta;
    if (target < 0 or target + 8 > code.len) return null;
    return @intCast(target);
}

/// What a wide immediate is, as the resolver of the emitter decides.
pub const Resolution = union(enum) {
    /// An address of something the loader can find again.
    address: Reloc,
    /// A value that is not an address.
    literal,
    /// An address of something the loader cannot find, which makes the
    /// code unusable ahead of time.
    unknown,
};

/// Maps a wide immediate to what it is, for an assembler that compiles
/// ahead of time.
pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, v: u64) Resolution,
};

/// One relocation of a piece of code: where its bytes are, their form,
/// and what the address points to.
pub const Entry = struct {
    at: u32,
    form: Form,
    r: Reloc,
};

/// Writes `addr` into the bytes of `e` in `code`.
pub fn apply(code: []u8, e: Entry, addr: u64) void {
    switch (e.form) {
        .word => std.mem.writeInt(u64, code[e.at..][0..8], addr, @import("builtin").cpu.arch.endian()),
        .ppc_seq => {
            const halves = [_]u16{ @truncate(addr >> 48), @truncate(addr >> 32), 0, @truncate(addr >> 16), @truncate(addr) };
            for (halves, 0..) |h, i| {
                if (i == 2) continue;
                const p = code[e.at + i * 4 ..][0..4];
                const w = std.mem.readInt(u32, p, .little);
                std.mem.writeInt(u32, p, (w & 0xFFFF_0000) | h, .little);
            }
        },
        .s390_pair => {
            std.mem.writeInt(u32, code[e.at + 2 ..][0..4], @truncate(addr >> 32), .big);
            std.mem.writeInt(u32, code[e.at + 8 ..][0..4], @truncate(addr), .big);
        },
        .slot => if (slotTarget(code, e.at)) |t| std.mem.writeInt(u64, code[t..][0..8], addr, .little),
        .arm_pair => {
            const halves = [_]u32{ @as(u16, @truncate(addr)), @as(u16, @truncate(addr >> 16)) };
            for (halves, 0..) |h, i| {
                const p = code[e.at + i * 4 ..][0..4];
                const w = std.mem.readInt(u32, p, .little);
                std.mem.writeInt(u32, p, (w & 0xFFF0_F000) | (h >> 12) << 16 | (h & 0xFFF), .little);
            }
        },
    }
}

/// The executable image of this process, which a static executable
/// loads below 4 GB. `aot.State.fromEnv` records it.
pub var image: struct { lo: u64 = 0, hi: u64 = 0 } = .{};

/// Whether an immediate needs a relocation or a `literal` name when the
/// assembler compiles ahead of time: a value that does not fit 32 bits,
/// which is where the heap and the code of a 64-bit process lie, or an
/// address in the executable image.
pub fn wide(v: u64) bool {
    const s: i64 = @bitCast(v);
    return s < std.math.minInt(i32) or s > std.math.maxInt(u32) or (v >= image.lo and v < image.hi);
}

/// Whether an immediate of a 32-bit target needs a relocation or a
/// `literal` name when the assembler compiles ahead of time. Every
/// address of such a target is one word, so the resolver decides for
/// each value with a zero high word that lies above the first 64 KB,
/// where the image, the heap, and the code of a process begin. The
/// instruction counts, the slot numbers, and the tags that the emitters
/// write lie below.
pub fn wide32(v: u64) bool {
    return v >> 32 == 0 and v >= 0x10000;
}

fn expectPatchable(comptime M: type, dst: M.Reg) !void {
    try expectPatchableAt(M, dst, 0x1122334455667788, 0x0000_7FFF_ABCD_0123);
}

fn expectPatchableAt(comptime M: type, dst: M.Reg, first: u64, second: u64) !void {
    const gpa = std.testing.allocator;
    const r: Reloc = .{ .kind = .routine, .a = 7 };
    var a = M.Assembler.init(gpa);
    defer a.deinit();
    a.aot = true;
    a.movImmReloc(dst, first, r);
    a.trap();
    try std.testing.expect(a.finish());
    try std.testing.expectEqual(@as(usize, 1), a.relocs.items.len);
    try std.testing.expectEqual(@as(u32, 0), a.unrelocated);
    // Patching another address gives the bytes of that address.
    var b = M.Assembler.init(gpa);
    defer b.deinit();
    b.aot = true;
    b.movImmReloc(dst, second, r);
    b.trap();
    try std.testing.expect(b.finish());
    apply(a.buf.items, a.relocs.items[0], second);
    try std.testing.expectEqualSlices(u8, b.buf.items, a.buf.items);
}

test "every assembler writes a patchable address" {
    try expectPatchable(@import("a64.zig"), .x9);
    try expectPatchable(@import("x64.zig"), .rcx);
    try expectPatchable(@import("rv64.zig"), .x5);
    try expectPatchable(@import("la64.zig"), .r12);
    try expectPatchable(@import("ppc64.zig"), .r21);
    try expectPatchable(@import("s390x.zig"), .r11);
    // An address of 32-bit ARM is one word. The first value takes one
    // instruction outside the patchable form, and the pair holds it too.
    try expectPatchableAt(@import("a32.zig"), .t0, 0x0000_FF00, 0xABCD_0123);
    try expectPatchableAt(@import("a32.zig"), .t5, 0x1122_3344, 0x7FFF_0000);
}

test "a wide immediate without a relocation is counted ahead of time" {
    const M = @import("a64.zig");
    var a = M.Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.aot = true;
    a.movImm(.x9, 0x1122334455667788);
    a.movImm(.x9, 42);
    a.movImmReloc(.x9, 0x1122334455667788, .literal);
    try std.testing.expectEqual(@as(u32, 1), a.unrelocated);
}
