//! The unwind information of native code on Windows on x86-64
//! (`spec/design/platforms.md`, "Unwind information"). The exception
//! dispatcher of Windows, debuggers, and profilers walk the stack with
//! the function table of each chunk of executable memory, whose entries
//! name an `UNWIND_INFO` record. The encoder here is a pure function, so
//! its tests run on every host.

const std = @import("std");

/// An entry of the function table: the range of code it covers and its
/// unwind information, each relative to the base of the table.
pub const RuntimeFunction = extern struct {
    begin: u32,
    end: u32,
    unwind: u32,
};

/// The numbers of the registers in unwind codes.
const rbx = 3;
const rbp = 5;
const r12 = 12;
const r13 = 13;
const r14 = 14;
const r15 = 15;

const push_nonvol = 0;
const alloc_large = 1;
const alloc_small = 2;
const set_fpreg = 3;

/// The longest record `info` writes.
pub const max_info = 4 + 2 * 10;

/// What a range of code runs under.
pub const Frame = struct {
    /// The range starts with the entry sequence: six pushes, `sub rsp, 8`,
    /// and with `frame_pointer` a store of the stop depth and a move of the
    /// stack pointer to `r12`,
    /// whose codes then carry their offsets. Without it the range runs
    /// after that sequence, and every code applies from its start.
    prologue: bool,
    /// The code keeps `r12` at the stack pointer after the entry
    /// sequence, so the unwinder finds the frame from it at any depth.
    frame_pointer: bool,
    /// Bytes below the frame of the entry sequence that the range keeps
    /// allocated, when the unwinder finds the frame from the stack
    /// pointer.
    depth: u32 = 0,
};

/// The offsets in the entry sequence after each of its instructions, as
/// `x64.Assembler.prologue` emits it: push rbx, push rbp, push r12 to
/// r15, sub rsp 8, then mov [rsp], rsi and mov r12, rsp.
const after_push = [6]u8{ 1, 2, 4, 6, 8, 10 };
const after_sub = 14;
/// After `mov [rsp], rsi`, which stores the stop depth, and `mov r12,
/// rsp`.
const after_mov = 21;

/// Writes the `UNWIND_INFO` of `f` to `buf` and returns its bytes. The
/// unwind codes come in the reverse order of the operations they undo.
pub fn info(buf: *[max_info]u8, f: Frame) []const u8 {
    var codes: [10]u16 = undefined;
    var n: usize = 0;
    const at = struct {
        fn of(fr: Frame, off: u8) u8 {
            return if (fr.prologue) off else 0;
        }
    }.of;
    if (f.frame_pointer) {
        codes[n] = code(at(f, after_mov), set_fpreg, 0);
        n += 1;
    }
    const alloc = 8 + (if (f.frame_pointer) 0 else f.depth);
    if (alloc <= 128) {
        codes[n] = code(at(f, after_sub), alloc_small, @intCast(alloc / 8 - 1));
        n += 1;
    } else {
        // The size in eight-byte words follows in the next slot.
        codes[n] = code(at(f, after_sub), alloc_large, 0);
        codes[n + 1] = @intCast(alloc / 8);
        n += 2;
    }
    const pushed = [6]u4{ rbx, rbp, r12, r13, r14, r15 };
    var k: usize = 6;
    while (k > 0) {
        k -= 1;
        codes[n] = code(at(f, after_push[k]), push_nonvol, pushed[k]);
        n += 1;
    }
    const count = n;
    // The array of codes takes an even number of slots.
    if (n % 2 == 1) {
        codes[n] = 0;
        n += 1;
    }
    buf[0] = 1; // version 1, no flags
    buf[1] = if (f.prologue) (if (f.frame_pointer) after_mov else after_sub) else 0;
    buf[2] = @intCast(count);
    buf[3] = if (f.frame_pointer) r12 else 0; // frame register, offset 0
    for (codes[0..n], 0..) |c, i| std.mem.writeInt(u16, buf[4 + 2 * i ..][0..2], c, .little);
    return buf[0 .. 4 + 2 * n];
}

fn code(offset: u8, op: u4, op_info: u4) u16 {
    return @as(u16, offset) | @as(u16, op) << 8 | @as(u16, op_info) << 12;
}

test "the unwind information of the entry sequence with a frame pointer" {
    var buf: [max_info]u8 = undefined;
    const b = info(&buf, .{ .prologue = true, .frame_pointer = true });
    try std.testing.expectEqualSlices(u8, &.{
        1, 21, 8, r12,
        21, 0x03, // SET_FPREG at 21
        14, 0x02, // ALLOC_SMALL 8 at 14
        10, 0xF0, // PUSH_NONVOL r15 at 10
        8, 0xE0, // r14
        6, 0xD0, // r13
        4, 0xC0, // r12
        2, 0x50, // rbp
        1, 0x30, // rbx
    }, b);
}

test "the unwind information of code that runs deeper than the entry sequence" {
    var buf: [max_info]u8 = undefined;
    const small = info(&buf, .{ .prologue = false, .frame_pointer = false, .depth = 40 });
    // ALLOC_SMALL of 48 bytes: (48 / 8) - 1 = 5, then the six pushes and a
    // slot of padding.
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 7, 0, 0, 0x52, 0, 0xF0, 0, 0xE0, 0, 0xD0, 0, 0xC0, 0, 0x50, 0, 0x30, 0, 0 }, small);
    const large = info(&buf, .{ .prologue = false, .frame_pointer = false, .depth = 4096 });
    // ALLOC_LARGE with the size in words in the next slot: (4096 + 8) / 8.
    try std.testing.expectEqual(@as(u8, 8), large[2]);
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, large[4..6], .little));
    try std.testing.expectEqual(@as(u16, 513), std.mem.readInt(u16, large[6..8], .little));
}
