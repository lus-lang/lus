//! An allocator wrapper that counts the bytes a state holds. Every
//! allocation a state makes goes through it, so the collector paces itself
//! on the real heap size, including table parts, string bodies and vector
//! buffers that live outside the object headers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
pub const fail_alloc = @import("build_options").fail_alloc;

/// Allocation failure injection, compiled in by `-Dfail-alloc=true`. Every
/// allocation of every state, and every segment of the object heap, takes
/// a number. The allocation whose number is `target` fails, and with
/// `sticky` every later one fails too. `lus` reads `LUS_FAIL_ALLOC` at
/// startup (`main.zig`) and `tests/oom/run.mjs` sweeps it.
pub const inject = struct {
    pub var target: usize = 0;
    pub var sticky: bool = false;
    pub var count: std.atomic.Value(usize) = .init(0);

    /// Whether the allocation being made must fail.
    pub inline fn fail() bool {
        if (!fail_alloc) return false;
        const n = count.fetchAdd(1, .monotonic) + 1;
        if (target == 0) return false;
        return if (sticky) n >= target else n == target;
    }
};

/// Blocks of at least this many bytes take pages of their own on macOS
/// when the state allocates from the C heap (`Counting.big_pages`).
pub const big_block = 1 << 20;

pub const Counting = struct {
    child: Allocator,
    bytes: usize = 0,
    /// Set when large blocks bypass the child. The C heap of macOS keeps
    /// the large blocks it frees mapped for later requests, so the hash
    /// parts, string tables, and array parts that a growing heap leaves
    /// behind stay in memory. A block in pages of its own goes back to
    /// the system when it is freed.
    big_pages: bool = false,
    pub fn init(child: Allocator) Counting {
        return .{ .child = child, .big_pages = builtin.os.tag == .macos and child.vtable == std.heap.c_allocator.vtable };
    }

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    inline fn isBig(self: *const Counting, len: usize) bool {
        return self.big_pages and len >= big_block;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (inject.fail()) return null;
        const p = if (self.isBig(len)) pages.rawAlloc(len, alignment, ret_addr) else self.child.rawAlloc(len, alignment, ret_addr);
        self.bytes += len;
        return p orelse {
            self.bytes -= len;
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const big = self.isBig(memory.len);
        if (big != self.isBig(new_len)) return false;
        const ok = if (big) pages.rawResize(memory, alignment, new_len, ret_addr) else self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (!ok) return false;
        self.bytes = (self.bytes -| memory.len) + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const big = self.isBig(memory.len);
        // A block that crosses the size of big blocks moves between the
        // two allocators, which the caller does with alloc and free.
        if (big != self.isBig(new_len)) return null;
        if (new_len > memory.len and inject.fail()) return null;
        const p = if (big) growPages(memory, alignment, new_len) else self.child.rawRemap(memory, alignment, new_len, ret_addr);
        self.bytes = (self.bytes -| memory.len) + new_len;
        return p orelse {
            self.bytes = (self.bytes -| new_len) + memory.len;
            return null;
        };
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (self.isBig(memory.len)) pages.rawFree(memory, alignment, ret_addr) else self.child.rawFree(memory, alignment, ret_addr);
        self.bytes -|= memory.len;
    }
};

const pages = std.heap.page_allocator;

extern "c" fn vm_copy(target_task: std.c.mach_port_t, source_address: usize, size: usize, dest_address: usize) c_int;

/// Resizes a block of pages of its own, as the C heap of macOS resizes
/// its large blocks: in place when the pages after it are free, and
/// otherwise by moving its pages to a new block with `vm_copy`, which
/// shares them instead of copying their bytes.
fn growPages(memory: []u8, alignment: Alignment, new_len: usize) ?[*]u8 {
    const page = std.heap.pageSize();
    if (alignment.toByteUnits() > page) return null;
    const old_size = std.mem.alignForward(usize, memory.len, page);
    const new_size = std.mem.alignForward(usize, new_len, page);
    if (new_size <= old_size) return pages.rawRemap(memory, alignment, new_len, @returnAddress());
    if (builtin.os.tag != .macos) return pages.rawRemap(memory, alignment, new_len, @returnAddress());
    const end = @intFromPtr(memory.ptr) + old_size;
    const more = new_size - old_size;
    const hint: ?*align(std.heap.page_size_min) anyopaque = @ptrFromInt(end);
    const tail = std.c.mmap(hint, more, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (tail != std.c.MAP_FAILED) {
        if (@intFromPtr(tail) == end) return memory.ptr;
        _ = std.c.munmap(@alignCast(tail), more);
    }
    const fresh = pages.rawAlloc(new_len, alignment, @returnAddress()) orelse return null;
    if (vm_copy(std.c.mach_task_self(), @intFromPtr(memory.ptr), old_size, @intFromPtr(fresh)) != 0) {
        @memcpy(fresh[0..memory.len], memory);
    }
    pages.rawFree(memory, alignment, @returnAddress());
    return fresh;
}

test "counting allocator tracks live bytes" {
    var c: Counting = .{ .child = std.testing.allocator };
    const a = c.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), c.bytes);
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 0), c.bytes);
}
