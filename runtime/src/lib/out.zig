//! Buffered standard output shared by `print`, `io.write`, and the
//! runtime's warnings. Flushed when full, before reading standard input,
//! before writing to standard error, and when the state closes.

const std = @import("std");
const state = @import("../vm/state.zig");
const Global = state.Global;

pub const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    file: std.Io.File,
    /// The buffering mode set by `setvbuf`.
    mode: Mode = .full,
    /// The first write error since the last one `io.write` or `flush`
    /// reported. `print` and the runtime's own writes leave it in place.
    failed: ?anyerror = null,

    pub const Mode = enum { no, line, full };

    pub fn write(o: *Out, g: *Global, bytes: []const u8) void {
        defer switch (o.mode) {
            .full => {},
            .no => o.flush(g),
            .line => if (std.mem.indexOfScalar(u8, bytes, '\n') != null) o.flush(g),
        };
        if (o.buf.items.len + bytes.len > 1 << 16) o.flush(g);
        if (bytes.len >= 1 << 16) {
            o.file.writeStreamingAll(g.io, bytes) catch |e| o.fail(e);
            return;
        }
        o.buf.appendSlice(g.gpa, bytes) catch {
            o.flush(g);
            o.file.writeStreamingAll(g.io, bytes) catch |e| o.fail(e);
        };
    }

    pub fn flush(o: *Out, g: *Global) void {
        if (o.buf.items.len == 0) return;
        o.file.writeStreamingAll(g.io, o.buf.items) catch |e| o.fail(e);
        o.buf.clearRetainingCapacity();
    }

    fn fail(o: *Out, e: anyerror) void {
        if (o.failed == null) o.failed = e;
    }

    /// Returns and clears the recorded write error.
    pub fn takeError(o: *Out) ?anyerror {
        defer o.failed = null;
        return o.failed;
    }
};

/// The buffered standard output of a state. `openAll` creates it with
/// `prepare`, so a state with its libraries open never allocates here.
pub fn stdout(g: *Global) *Out {
    return prepare(g) catch @panic("out of memory");
}

/// Creates the standard output of a state, or returns the one it has.
pub fn prepare(g: *Global) error{OutOfMemory}!*Out {
    if (g.ext.get("out.stdout")) |p| return @ptrCast(@alignCast(p));
    try g.ext.ensureUnusedCapacity(g.gpa, 1);
    const o = try g.gpa.create(Out);
    o.* = .{ .file = std.Io.File.stdout() };
    g.ext.putAssumeCapacity("out.stdout", o);
    return o;
}

pub fn flushAll(g: *Global) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        o.flush(g);
    }
}

pub fn deinit(g: *Global) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        o.flush(g);
        o.buf.deinit(g.gpa);
        g.gpa.destroy(o);
        _ = g.ext.remove("out.stdout");
    }
}

/// Writes directly to standard error after flushing standard output.
pub fn stderr(g: *Global, bytes: []const u8) void {
    flushAll(g);
    std.Io.File.stderr().writeStreamingAll(g.io, bytes) catch {};
}

pub fn warning(g: *Global, prefix: ?[]const u8, msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    const s = if (prefix) |p|
        std.fmt.bufPrint(&buf, "Lus warning: {s} ({s})\n", .{ msg, p }) catch "Lus warning\n"
    else
        std.fmt.bufPrint(&buf, "Lus warning: {s}\n", .{msg}) catch "Lus warning\n";
    stderr(g, s);
}
