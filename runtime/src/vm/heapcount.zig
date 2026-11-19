//! An allocator wrapper that counts the bytes a state holds. Every
//! allocation a state makes goes through it, so the collector paces itself
//! on the real heap size, including table parts, string bodies and vector
//! buffers that live outside the object headers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Counting = struct {
    child: Allocator,
    bytes: usize = 0,

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bytes += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.bytes = (self.bytes -| memory.len) + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.bytes = (self.bytes -| memory.len) + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.bytes -|= memory.len;
    }
};

test "counting allocator tracks live bytes" {
    var c: Counting = .{ .child = std.testing.allocator };
    const a = c.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), c.bytes);
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 0), c.bytes);
}
