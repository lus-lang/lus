//! Executable memory for native code. Each state owns an arena of chunks
//! mapped from the operating system. A block of code is carved out of a
//! chunk, and a chunk with no blocks left goes back to the system.
//!
//! The bookkeeping lives outside the chunks, so executable pages hold
//! nothing but code.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const darwin = builtin.os.tag.isDarwin();
/// Apple Silicon maps code with MAP_JIT and flips each thread between
/// writing and executing it.
const toggles = darwin and builtin.cpu.arch == .aarch64;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

/// Windows maps chunks writable and switches the pages of a block to
/// executable once its code is in place. A state and its arena belong to
/// one thread, so no other thread runs code from pages that are writable.
const windows = builtin.os.tag == .windows;
const mem_commit = 0x1000;
const mem_reserve = 0x2000;
const mem_release = 0x8000;
const page_readwrite = 0x04;
const page_execute_read = 0x20;
extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, kind: u32) callconv(.winapi) i32;
extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, protect: u32, old: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn FlushInstructionCache(process: *anyopaque, addr: ?*const anyopaque, size: usize) callconv(.winapi) i32;

/// On Windows each chunk registers a function table that covers its
/// blocks, so the exception dispatcher, debuggers, and profilers walk
/// through native code (`winunwind.zig`). Native code keeps `r12` on
/// x86-64, and `x29` on arm64, at the frame of the entry sequence, so the
/// unwind information at the start of the chunk describes every block.
/// x86-64 needs one entry for a chunk. An arm64 record covers at most
/// `winunwind.arm64_max_len` bytes, so a larger chunk takes one entry for
/// each part of that size and one record for the shorter last part.
const unwinds = windows and switch (builtin.cpu.arch) {
    .x86_64 => @import("x64.zig").frame_pointer,
    .aarch64 => true,
    else => false,
};
const arm64 = builtin.cpu.arch == .aarch64;
const winunwind = @import("winunwind.zig");
const Entry = if (arm64) winunwind.RuntimeFunctionArm64 else winunwind.RuntimeFunction;
/// The bytes at the start of a chunk that hold its unwind information.
const header = if (unwinds) 64 else 0;
extern "ntdll" fn RtlAddGrowableFunctionTable(table: *?*anyopaque, entries: [*]Entry, count: u32, max: u32, range_base: usize, range_end: usize) callconv(.winapi) u32;
extern "ntdll" fn RtlDeleteGrowableFunctionTable(table: *anyopaque) callconv(.winapi) void;

const chunk_size = 1 << 20;
const block_align = 16;

const Span = struct {
    start: usize,
    len: usize,
};

/// A chunk mapped from the system, with the function table it registered
/// on Windows.
const Chunk = struct {
    span: Span,
    table: ?*anyopaque = null,
    entries: []Entry = &.{},
};

pub const Arena = struct {
    chunks: std.ArrayList(Chunk) = .empty,
    /// Free spans, sorted by address, with neighbors merged.
    free: std.ArrayList(Span) = .empty,
    /// Bytes handed out and not yet freed.
    used: usize = 0,

    pub fn deinit(a: *Arena, gpa: std.mem.Allocator) void {
        for (a.chunks.items) |c| drop(gpa, c);
        a.chunks.deinit(gpa);
        a.free.deinit(gpa);
        a.* = .{};
    }

    /// Returns a block of `len` bytes, or null when the system refuses
    /// executable memory.
    pub fn alloc(a: *Arena, gpa: std.mem.Allocator, len: usize) ?[]u8 {
        const need = std.mem.alignForward(usize, @max(len, 1), block_align);
        for (0..2) |attempt| {
            for (a.free.items, 0..) |*s, i| {
                if (s.len < need) continue;
                const start = s.start;
                if (s.len == need) {
                    _ = a.free.orderedRemove(i);
                } else {
                    s.start += need;
                    s.len -= need;
                }
                a.used += need;
                return @as([*]u8, @ptrFromInt(start))[0..need];
            }
            if (attempt == 1) break;
            const size = std.mem.alignForward(usize, @max(need, chunk_size), std.heap.pageSize());
            // Room for the two list entries a later free may need.
            a.chunks.ensureUnusedCapacity(gpa, 1) catch return null;
            a.free.ensureUnusedCapacity(gpa, 2) catch return null;
            const c = map(size) orelse return null;
            var chunk: Chunk = .{ .span = c };
            if (unwinds) register(gpa, &chunk) catch {
                unmap(c);
                return null;
            };
            a.chunks.appendAssumeCapacity(chunk);
            a.insertFree(usable(c));
        }
        return null;
    }

    /// Returns a block to the arena.
    pub fn release(a: *Arena, gpa: std.mem.Allocator, block: []u8) void {
        // Code compiled ahead of time into the executable lies outside
        // every chunk and stays where it is.
        const start = @intFromPtr(block.ptr);
        const owned = for (a.chunks.items) |c| {
            if (start >= c.span.start and start < c.span.start + c.span.len) break true;
        } else false;
        if (!owned) return;
        a.used -= block.len;
        // The list has room unless growing it failed. A block that cannot
        // be recorded stays unused until the state closes.
        a.free.ensureUnusedCapacity(gpa, 1) catch return;
        a.insertFree(.{ .start = @intFromPtr(block.ptr), .len = block.len });
        // Drop a chunk that is entirely free again.
        for (a.chunks.items, 0..) |c, ci| {
            const u = usable(c.span);
            for (a.free.items, 0..) |s, si| {
                if (s.start == u.start and s.len == u.len) {
                    _ = a.free.orderedRemove(si);
                    _ = a.chunks.swapRemove(ci);
                    drop(gpa, c);
                    return;
                }
            }
        }
    }

    /// Inserts a span in address order and merges it with its neighbors
    /// inside the same chunk.
    fn insertFree(a: *Arena, span: Span) void {
        var i: usize = 0;
        while (i < a.free.items.len and a.free.items[i].start < span.start) i += 1;
        a.free.insertAssumeCapacity(i, span);
        if (i + 1 < a.free.items.len and a.mergeable(a.free.items[i], a.free.items[i + 1])) {
            a.free.items[i].len += a.free.items[i + 1].len;
            _ = a.free.orderedRemove(i + 1);
        }
        if (i > 0 and a.mergeable(a.free.items[i - 1], a.free.items[i])) {
            a.free.items[i - 1].len += a.free.items[i].len;
            _ = a.free.orderedRemove(i);
        }
    }

    fn mergeable(a: *const Arena, lo: Span, hi: Span) bool {
        if (lo.start + lo.len != hi.start) return false;
        for (a.chunks.items) |c| {
            if (lo.start >= c.span.start and lo.start < c.span.start + c.span.len) return hi.start < c.span.start + c.span.len;
        }
        return false;
    }
};

/// The part of a chunk that blocks are carved from, after its header.
fn usable(c: Span) Span {
    return .{ .start = c.start + header, .len = c.len - header };
}

/// Writes the unwind information at the start of a new chunk and
/// registers a function table whose entries cover the rest of it.
fn register(gpa: std.mem.Allocator, c: *Chunk) error{OutOfMemory}!void {
    const len = c.span.len - header;
    const n = if (arm64) std.math.divCeil(usize, len, winunwind.arm64_max_len) catch unreachable else 1;
    const entries = try gpa.alloc(Entry, n);
    errdefer gpa.free(entries);
    const base: [*]u8 = @ptrFromInt(c.span.start);
    var old: u32 = 0;
    if (VirtualProtect(base, header, page_readwrite, &old) == 0) return error.OutOfMemory;
    if (arm64) {
        // The record of a whole part at 0, and of the last part after it.
        var buf: [winunwind.arm64_info_len]u8 = undefined;
        @memcpy(base[0..buf.len], winunwind.infoArm64(&buf, winunwind.arm64_max_len));
        const last: u32 = @intCast(len - (n - 1) * winunwind.arm64_max_len);
        @memcpy(base[buf.len..][0..buf.len], winunwind.infoArm64(&buf, last));
        for (entries, 0..) |*e, i| e.* = .{
            .begin = @intCast(header + i * winunwind.arm64_max_len),
            .unwind = if (i == n - 1) winunwind.arm64_info_len else 0,
        };
    } else {
        var buf: [winunwind.max_info]u8 = undefined;
        const rec = winunwind.info(&buf, .{ .prologue = false, .frame_pointer = true });
        @memcpy(base[0..rec.len], rec);
        entries[0] = .{ .begin = header, .end = @intCast(c.span.len), .unwind = 0 };
    }
    if (VirtualProtect(base, header, page_execute_read, &old) == 0) return error.OutOfMemory;
    var table: ?*anyopaque = null;
    if (RtlAddGrowableFunctionTable(&table, entries.ptr, @intCast(n), @intCast(n), c.span.start, c.span.start + c.span.len) != 0) return error.OutOfMemory;
    c.table = table;
    c.entries = entries;
}

/// Unregisters the function table of a chunk and returns it to the
/// system.
fn drop(gpa: std.mem.Allocator, c: Chunk) void {
    if (unwinds) {
        if (c.table) |t| RtlDeleteGrowableFunctionTable(t);
        gpa.free(c.entries);
    }
    unmap(c.span);
}

/// Set when the process may map no executable memory: on an iOS device,
/// which grants it only to the system, and under `LUS_JIT_NO_EXEC`.
pub var refuse_exec = builtin.os.tag == .ios and builtin.abi != .simulator;

fn map(size: usize) ?Span {
    if (refuse_exec) return null;
    if (windows) {
        const m = VirtualAlloc(null, size, mem_commit | mem_reserve, page_readwrite) orelse return null;
        // A process with Arbitrary Code Guard cannot make pages
        // executable, which the first install would find out too late.
        var old: u32 = 0;
        if (VirtualProtect(m, size, page_execute_read, &old) == 0) {
            _ = VirtualFree(m, 0, mem_release);
            return null;
        }
        return .{ .start = @intFromPtr(m), .len = size };
    }
    const prot: posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (darwin) flags.JIT = true;
    const m = posix.mmap(null, size, prot, flags, -1, 0) catch return null;
    return .{ .start = @intFromPtr(m.ptr), .len = size };
}

fn unmap(s: Span) void {
    if (windows) {
        _ = VirtualFree(@ptrFromInt(s.start), 0, mem_release);
        return;
    }
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(s.start);
    posix.munmap(p[0..s.len]);
}

/// Copies finished code into a block and makes it runnable.
pub fn install(block: []u8, code: []const u8) void {
    if (windows) return installWindows(block, code);
    if (toggles) pthread_jit_write_protect_np(0);
    @memcpy(block[0..code.len], code);
    if (toggles) pthread_jit_write_protect_np(1);
    if (darwin) {
        sys_icache_invalidate(block.ptr, code.len);
    } else if (builtin.cpu.arch == .aarch64) {
        syncCode(@intFromPtr(block.ptr), @intFromPtr(block.ptr) + code.len);
    } else if (builtin.cpu.arch == .riscv64) {
        // fence.i reaches only the hart that runs it. The system call
        // makes every hart that runs the process fetch the new code.
        const start = @intFromPtr(block.ptr);
        _ = std.os.linux.syscall3(.riscv_flush_icache, start, start + code.len, 0);
    } else if (builtin.cpu.arch == .loongarch64) {
        // The instruction caches of LoongArch64 follow stores in hardware,
        // and ibar orders the stores before the next instruction fetch.
        asm volatile ("ibar 0");
    } else if (builtin.cpu.arch == .powerpc64le) {
        syncCodePower(@intFromPtr(block.ptr), @intFromPtr(block.ptr) + code.len);
    } else if (builtin.cpu.arch == .arm) {
        // The cacheflush system call of ARM Linux makes every core that
        // runs the process fetch the new code.
        const start = @intFromPtr(block.ptr);
        _ = std.os.linux.syscall3(.cacheflush, start, start + code.len, 0);
    }
}

/// Makes the pages of the block writable, copies the code, and makes them
/// executable again. Other blocks on the same pages stay runnable for
/// every thread except this one, which runs no native code meanwhile.
fn installWindows(block: []u8, code: []const u8) void {
    const page = std.heap.pageSize();
    const start = std.mem.alignBackward(usize, @intFromPtr(block.ptr), page);
    const end = std.mem.alignForward(usize, @intFromPtr(block.ptr) + code.len, page);
    var old: u32 = 0;
    // The pages were committed when the chunk was mapped, so switching
    // their protection fails only when the system is out of resources.
    if (VirtualProtect(@ptrFromInt(start), end - start, page_readwrite, &old) == 0) @panic("VirtualProtect failed");
    @memcpy(block[0..code.len], code);
    if (VirtualProtect(@ptrFromInt(start), end - start, page_execute_read, &old) == 0) @panic("VirtualProtect failed");
    _ = FlushInstructionCache(GetCurrentProcess(), block.ptr, code.len);
}

/// Makes the bytes just written to `start..end` visible to instruction
/// fetch on POWER: every data cache line is stored, a barrier follows,
/// every instruction cache line is invalidated, and a barrier and an
/// instruction barrier follow. The stride is 32 bytes, the smallest cache
/// line of the processors the ISA describes.
fn syncCodePower(start: usize, end: usize) void {
    const line = 32;
    var addr = start & ~@as(usize, line - 1);
    while (addr < end) : (addr += line) asm volatile ("dcbst 0, %[a]"
        :
        : [a] "r" (addr),
    );
    asm volatile ("sync");
    addr = start & ~@as(usize, line - 1);
    while (addr < end) : (addr += line) asm volatile ("icbi 0, %[a]"
        :
        : [a] "r" (addr),
    );
    asm volatile ("sync");
    asm volatile ("isync");
}

/// Makes every core fetch the bytes just written to `start..end`, on an
/// aarch64 system other than Darwin. The data cache lines are cleaned,
/// the instruction cache lines are invalidated, and a barrier follows
/// each loop. The barrier after the invalidation is what makes it
/// complete on every core before the new code runs. The `__clear_cache`
/// of the compiler runtime leaves that barrier out, and code installed
/// through it ran stale instructions now and then on a busy machine.
fn syncCode(start: u64, end: u64) void {
    const ctr = asm volatile ("mrs %[ctr], ctr_el0"
        : [ctr] "=r" (-> u64),
    );
    // With the IDC bit set the data cache needs no cleaning.
    if ((ctr >> 28) & 1 == 0) {
        const line = @as(u64, 4) << @intCast((ctr >> 16) & 15);
        var addr = start & ~(line - 1);
        while (addr < end) : (addr += line) {
            asm volatile ("dc cvau, %[addr]"
                :
                : [addr] "r" (addr),
            );
        }
    }
    asm volatile ("dsb ish");
    // With the DIC bit set the instruction cache needs no invalidation.
    if ((ctr >> 29) & 1 == 0) {
        const line = @as(u64, 4) << @intCast(ctr & 15);
        var addr = start & ~(line - 1);
        while (addr < end) : (addr += line) {
            asm volatile ("ic ivau, %[addr]"
                :
                : [addr] "r" (addr),
            );
        }
        asm volatile ("dsb ish");
    }
    asm volatile ("isb");
}

test "arena reuses and merges blocks" {
    const gpa = std.testing.allocator;
    var a: Arena = .{};
    defer a.deinit(gpa);
    const x = a.alloc(gpa, 100) orelse return error.SkipZigTest;
    const y = a.alloc(gpa, 200).?;
    const z = a.alloc(gpa, 50).?;
    try std.testing.expectEqual(@intFromPtr(x.ptr) + 112, @intFromPtr(y.ptr));
    a.release(gpa, y);
    const w = a.alloc(gpa, 208).?;
    try std.testing.expectEqual(@intFromPtr(y.ptr), @intFromPtr(w.ptr));
    a.release(gpa, x);
    a.release(gpa, w);
    a.release(gpa, z);
    // Everything merged back, so the chunk returned to the system.
    try std.testing.expectEqual(@as(usize, 0), a.chunks.items.len);
    try std.testing.expectEqual(@as(usize, 0), a.used);
}

test "installed code runs" {
    if (!(builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .riscv64 or builtin.cpu.arch == .loongarch64 or builtin.cpu.arch == .powerpc64le)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var a: Arena = .{};
    defer a.deinit(gpa);
    // A function that returns 42.
    const code: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &.{ 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 },
        // li a0, 42; ret
        .riscv64 => &.{ 0x13, 0x05, 0xA0, 0x02, 0x67, 0x80, 0x00, 0x00 },
        // addi.d $a0, $zero, 42; jirl $zero, $ra, 0
        .loongarch64 => &.{ 0x04, 0xA8, 0xC0, 0x02, 0x20, 0x00, 0x00, 0x4C },
        // li 3, 42; blr
        .powerpc64le => &.{ 0x2A, 0x00, 0x60, 0x38, 0x20, 0x00, 0x80, 0x4E },
        else => &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 },
    };
    const block = a.alloc(gpa, code.len) orelse return error.SkipZigTest;
    install(block, code);
    const f: *const fn () callconv(.c) u32 = @ptrFromInt(@intFromPtr(block.ptr));
    try std.testing.expectEqual(@as(u32, 42), f());
    a.release(gpa, block);
}

/// The convention of native code and of the routines it calls.
const native_cc: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86_64) .{ .x86_64_sysv = .{} } else .c;

/// What the walk of `unwindHelper` found: whether it passed through the
/// block of native code, and the start of the function it reached next.
var unwind_walk: struct { in_block: bool = false, reached: usize = 0 } = .{};
var unwind_block: [2]usize = .{ 0, 0 };

/// Called by native code: unwinds its own frame, then the frame of the
/// block that called it, with the function tables of the system.
fn unwindHelper() callconv(native_cc) void {
    const w = std.os.windows;
    var ctx: w.CONTEXT = undefined;
    w.ntdll.RtlCaptureContext(&ctx);
    var history = std.mem.zeroes(w.UNWIND_HISTORY_TABLE);
    for (0..4) |_| {
        var image: usize = 0;
        const pc = ctx.getRegs().ip;
        const fe = w.ntdll.RtlLookupFunctionEntry(pc, &image, &history) orelse return;
        if (pc >= unwind_block[0] and pc < unwind_block[1]) {
            unwind_walk.in_block = true;
        } else if (unwind_walk.in_block) {
            unwind_walk.reached = image + fe.BeginAddress;
            return;
        }
        var data: ?*anyopaque = null;
        var frame: usize = 0;
        _ = w.ntdll.RtlVirtualUnwind(0, image, pc, fe, &ctx, &data, &frame, null);
    }
}

/// Enters the block as the runtime enters native code.
noinline fn unwindEnter(f: *const fn () callconv(native_cc) void) void {
    f();
}

test "the stack unwinds through native code on Windows" {
    if (!unwinds) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const A = if (arm64) @import("a64.zig") else @import("x64.zig");
    var a: Arena = .{};
    defer a.deinit(gpa);
    // The entry sequence, a call of the helper, and the return.
    var as = A.Assembler.init(gpa);
    defer as.deinit();
    as.prologue();
    as.call(@intFromPtr(&unwindHelper));
    as.epilogue();
    // The arm64 call loads its target from the constant pool, which
    // `finish` writes after the code and points the load at.
    try std.testing.expect(as.finish());
    const code = as.buf.items;
    const block = a.alloc(gpa, code.len) orelse return error.SkipZigTest;
    defer a.release(gpa, block);
    install(block, code);
    unwind_block = .{ @intFromPtr(block.ptr), @intFromPtr(block.ptr) + code.len };
    unwind_walk = .{};
    unwindEnter(@ptrFromInt(@intFromPtr(block.ptr)));
    try std.testing.expect(unwind_walk.in_block);
    try std.testing.expectEqual(@intFromPtr(&unwindEnter), unwind_walk.reached);
}
