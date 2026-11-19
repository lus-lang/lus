//! Shared immutable string bodies. A string longer than `min_len` bytes
//! that a worker message carries moves between heaps as a blob: the bytes
//! live once, in memory that no heap owns, and every heap that holds the
//! string holds a reference to the blob. Sending such a string copies no
//! bytes after the first time, and forwarding a received string to a
//! further worker copies none at all.
//!
//! A heap refers to a blob in two ways. A string created from a message
//! is a shared string: its cell holds the pointer to the blob in place of
//! the bytes, and `String.bytes` reads through it. A string of the heap
//! itself that was sent keeps its own bytes and records its blob in the
//! cache of the heap, so sending it again reuses the blob. Either kind of
//! string releases its reference when its heap sweeps it, so each heap
//! keeps its own collector, and the blob is freed when the last string
//! that refers to it dies in any heap.
//!
//! Every reference charges the length of the blob to the heap that holds
//! it, so the pacer of a heap sees the bytes it keeps alive.

const std = @import("std");
const object = @import("object.zig");
const gc = @import("gc.zig");
const state = @import("state.zig");
const String = object.String;
const Global = state.Global;
const Allocator = std.mem.Allocator;

/// Strings longer than this many bytes travel as blobs.
pub const min_len = 64;
/// Strings longer than this many bytes travel as blobs the first time
/// they are sent.
pub const once_len = @import("heap.zig").max_small;

pub const Blob = struct {
    refs: std.atomic.Value(u32),
    len: u32,
    /// The hash of the bytes under `seed`. A heap with the same seed
    /// takes it as the hash of its string. Workers inherit the seed of
    /// their creator, so a whole tree of workers shares one.
    hash: u32,
    seed: u64,
    gpa: Allocator,

    pub inline fn bytes(b: *const Blob) []const u8 {
        const base: [*]const u8 = @ptrCast(b);
        return (base + @sizeOf(Blob))[0..b.len];
    }

    fn allocSize(len: usize) usize {
        return @sizeOf(Blob) + len + 1;
    }

    /// A blob holding a copy of `b`, with one reference.
    pub fn create(gpa: Allocator, b: []const u8, seed: u64, hash: u32) Allocator.Error!*Blob {
        const mem = try gpa.alignedAlloc(u8, .of(Blob), allocSize(b.len));
        const blob: *Blob = @ptrCast(mem.ptr);
        blob.* = .{ .refs = .init(1), .len = @intCast(b.len), .hash = hash, .seed = seed, .gpa = gpa };
        const dst = mem[@sizeOf(Blob)..];
        @memcpy(dst[0..b.len], b);
        // Strings end with a zero byte for the C interface.
        dst[b.len] = 0;
        return blob;
    }

    pub fn retain(b: *Blob) void {
        _ = b.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(b: *Blob) void {
        if (b.refs.fetchSub(1, .release) != 1) return;
        // Every other release happened before this one.
        _ = b.refs.load(.acquire);
        const mem: [*]align(@alignOf(Blob)) u8 = @ptrCast(b);
        b.gpa.free(mem[0..allocSize(b.len)]);
    }
};

/// A reference to the blob of `s` for a message, or null when the
/// message should copy the bytes instead. A shared string, or one with a
/// blob in the cache, gives its blob. A string sent before gets a blob,
/// which the cache keeps for every later send. A string sent for the
/// first time copies, unless it is longer than `once_len`: most strings
/// are sent once, and below that length copying the bytes twice costs
/// less than allocating and freeing a blob (`spec/design/workers.md`).
pub fn acquire(g: *Global, s: *String) Allocator.Error!?*Blob {
    if (s.flags.shared or s.flags.cached) {
        const b = if (s.flags.shared) s.blob() else g.blobs.get(s).?;
        b.retain();
        return b;
    }
    if (!s.flags.sent) {
        s.flags.sent = true;
        if (s.len <= once_len) return null;
        return try Blob.create(g.parent_gpa, s.bytes(), g.seed, s.hash);
    }
    const b = try Blob.create(g.parent_gpa, s.bytes(), g.seed, s.hash);
    g.blobs.put(g.gpa, s, b) catch |e| {
        b.release();
        return e;
    };
    s.flags.cached = true;
    g.counter.bytes += b.len;
    b.retain();
    return b;
}

/// A shared string of `g` whose bytes are those of `b`. It takes a new
/// reference to the blob.
pub fn newString(g: *Global, b: *Blob, ascii: bool, chars: u32) Allocator.Error!*String {
    gc.maybeCollect(g);
    const s = try gc.allocUninit(g, String, .string, String.shared_size);
    s.len = b.len;
    s.chars = chars;
    s.hash = if (b.seed == g.seed) b.hash else object.hashBytes(g.seed, b.bytes());
    s.flags = .{ .ascii = ascii, .shared = true };
    s.crumbs = null;
    s.setBlob(b);
    b.retain();
    g.counter.bytes += b.len;
    return s;
}

/// Releases the reference that a dying string holds. Called when the
/// collector frees a string that is shared or cached.
pub fn drop(g: *Global, s: *String) void {
    const b = if (s.flags.shared) s.blob() else (g.blobs.fetchRemove(s) orelse return).value;
    g.counter.bytes -|= b.len;
    b.release();
}
