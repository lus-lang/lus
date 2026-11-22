//! The runtime half of the MC/DC measure, which `transform.zig` copies
//! next to the root of the transformed sources and completes with the
//! number of decisions.
//!
//! A vector holds two bits for each condition of a decision, 0 when the
//! condition did not run, 1 when it was false, and 2 when it was true, and
//! the outcome in its top bit. Each decision keeps the distinct vectors it
//! saw in a few slots. `LUS_MCDC=DIR` makes every process write them to a
//! file of its own in DIR when it exits, one `decision vector` a line.

const std = @import("std");
const root = @This();

/// Records that condition `i` of a decision ran with the value `x`.
pub inline fn c(v: *u64, comptime i: u6, x: bool) bool {
    v.* |= @as(u64, if (x) 2 else 1) << (2 * i);
    return x;
}

const slots = 16;
var table: [root.decisions + 1][slots]u64 = @splat(@splat(0));
var registered: std.atomic.Value(bool) = .init(false);

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;

/// Records the vector `v` and the outcome `r` of decision `id`.
pub fn d(id: u32, v: u64, r: bool) void {
    if (@inComptime()) return;
    const key = v | (@as(u64, @intFromBool(r)) << 63) | (1 << 62);
    const row = &table[id];
    for (row) |*slot| {
        const seen = @atomicLoad(u64, slot, .monotonic);
        if (seen == key) return;
        if (seen == 0) {
            if (@cmpxchgStrong(u64, slot, 0, key, .monotonic, .monotonic)) |other| {
                if (other == key) return;
                continue;
            }
            break;
        }
    }
    if (!registered.swap(true, .monotonic)) _ = atexit(dump);
}

fn dump() callconv(.c) void {
    const dir = std.c.getenv("LUS_MCDC") orelse return;
    var name_buf: [1200]u8 = undefined;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}/{d}-{d}-{d}.mcdc", .{ std.mem.span(dir), std.c.getpid(), ts.sec, ts.nsec }, 0) catch return;
    const fd = std.c.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    for (table, 0..) |row, id| for (row) |key| {
        if (key == 0) break;
        if (len + 48 > buf.len) {
            _ = std.c.write(fd, &buf, len);
            len = 0;
        }
        const s = std.fmt.bufPrint(buf[len..], "{d} {d} {d}\n", .{ id, key & ((1 << 62) - 1), key >> 63 }) catch return;
        len += s.len;
    };
    _ = std.c.write(fd, &buf, len);
}
