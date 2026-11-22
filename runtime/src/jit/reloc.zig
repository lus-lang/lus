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
    /// A field of unit `b` of function `a`, at `c` bytes from its start.
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
    /// The code of function `a`, at offset `b`.
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
};

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
    }
}

/// Whether an immediate needs a relocation or a `literal` name when the
/// assembler compiles ahead of time: a value that does not fit 32 bits,
/// which is where every address of a 64-bit process lies.
pub fn wide(v: u64) bool {
    const s: i64 = @bitCast(v);
    return s < std.math.minInt(i32) or s > std.math.maxInt(u32);
}

fn expectPatchable(comptime M: type, dst: M.Reg) !void {
    const gpa = std.testing.allocator;
    const r: Reloc = .{ .kind = .routine, .a = 7 };
    var a = M.Assembler.init(gpa);
    defer a.deinit();
    a.aot = true;
    a.movImmReloc(dst, 0x1122334455667788, r);
    a.trap();
    try std.testing.expect(a.finish());
    try std.testing.expectEqual(@as(usize, 1), a.relocs.items.len);
    try std.testing.expectEqual(@as(u32, 0), a.unrelocated);
    // Patching another address gives the bytes of that address.
    var b = M.Assembler.init(gpa);
    defer b.deinit();
    b.aot = true;
    b.movImmReloc(dst, 0x0000_7FFF_ABCD_0123, r);
    b.trap();
    try std.testing.expect(b.finish());
    apply(a.buf.items, a.relocs.items[0], 0x0000_7FFF_ABCD_0123);
    try std.testing.expectEqualSlices(u8, b.buf.items, a.buf.items);
}

test "every assembler writes a patchable address" {
    try expectPatchable(@import("a64.zig"), .x9);
    try expectPatchable(@import("x64.zig"), .rcx);
    try expectPatchable(@import("rv64.zig"), .x5);
    try expectPatchable(@import("la64.zig"), .r12);
    try expectPatchable(@import("ppc64.zig"), .r21);
    try expectPatchable(@import("s390x.zig"), .r11);
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
