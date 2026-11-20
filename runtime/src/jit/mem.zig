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

const chunk_size = 1 << 20;
const block_align = 16;

const Span = struct {
    start: usize,
    len: usize,
};

pub const Arena = struct {
    chunks: std.ArrayList(Span) = .empty,
    /// Free spans, sorted by address, with neighbors merged.
    free: std.ArrayList(Span) = .empty,
    /// Bytes handed out and not yet freed.
    used: usize = 0,

    pub fn deinit(a: *Arena, gpa: std.mem.Allocator) void {
        for (a.chunks.items) |c| unmap(c);
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
            a.chunks.appendAssumeCapacity(c);
            a.insertFree(c);
        }
        return null;
    }

    /// Returns a block to the arena.
    pub fn release(a: *Arena, gpa: std.mem.Allocator, block: []u8) void {
        a.used -= block.len;
        // The list has room unless growing it failed. A block that cannot
        // be recorded stays unused until the state closes.
        a.free.ensureUnusedCapacity(gpa, 1) catch return;
        a.insertFree(.{ .start = @intFromPtr(block.ptr), .len = block.len });
        // Drop a chunk that is entirely free again.
        for (a.chunks.items, 0..) |c, ci| {
            for (a.free.items, 0..) |s, si| {
                if (s.start == c.start and s.len == c.len) {
                    _ = a.free.orderedRemove(si);
                    _ = a.chunks.swapRemove(ci);
                    unmap(c);
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
            if (lo.start >= c.start and lo.start < c.start + c.len) return hi.start < c.start + c.len;
        }
        return false;
    }
};

fn map(size: usize) ?Span {
    const prot: posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (darwin) flags.JIT = true;
    const m = posix.mmap(null, size, prot, flags, -1, 0) catch return null;
    return .{ .start = @intFromPtr(m.ptr), .len = size };
}

fn unmap(s: Span) void {
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(s.start);
    posix.munmap(p[0..s.len]);
}

/// Copies finished code into a block and makes it runnable.
pub fn install(block: []u8, code: []const u8) void {
    if (toggles) pthread_jit_write_protect_np(0);
    @memcpy(block[0..code.len], code);
    if (toggles) pthread_jit_write_protect_np(1);
    if (darwin) {
        sys_icache_invalidate(block.ptr, code.len);
    } else if (builtin.cpu.arch == .aarch64) {
        syncCode(@intFromPtr(block.ptr), @intFromPtr(block.ptr) + code.len);
    }
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
    if (!(builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var a: Arena = .{};
    defer a.deinit(gpa);
    // A function that returns 42.
    const code: []const u8 = if (builtin.cpu.arch == .aarch64)
        &.{ 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 }
    else
        &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    const block = a.alloc(gpa, code.len) orelse return error.SkipZigTest;
    install(block, code);
    const f: *const fn () callconv(.c) u32 = @ptrFromInt(@intFromPtr(block.ptr));
    try std.testing.expectEqual(@as(u32, 42), f());
    a.release(gpa, block);
}
