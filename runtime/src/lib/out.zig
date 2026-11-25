//! Buffered standard output shared by `print`, `io.write`, and the
//! runtime's warnings. Flushed when full, before reading standard input,
//! before writing to standard error, and when the state closes. The same
//! moments flush every other file handle that holds buffered output,
//! which the `io` library lists in `pending`.

const std = @import("std");
const state = @import("../vm/state.zig");
const Global = state.Global;

pub const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    file: std.Io.File,
    /// The buffering mode set by `setvbuf`.
    mode: Mode = .full,
    /// The size of the buffer, which `setvbuf` sets.
    limit: usize = 1 << 16,
    /// The other file handles that hold buffered output, which
    /// `flush_pending` writes out.
    pending: std.ArrayList(*anyopaque) = .empty,
    /// The first write error since the last one `io.write` or `flush`
    /// reported. `print` and the runtime's own writes leave it in place.
    failed: ?anyerror = null,
    /// A buffer that receives the output in place of the file, which
    /// `lus test --doc` sets to compare the output of a code block with
    /// its `-->` comments.
    capture: ?*std.ArrayList(u8) = null,

    pub const Mode = enum { no, line, full };

    pub fn write(o: *Out, g: *Global, bytes: []const u8) void {
        defer switch (o.mode) {
            .full => {},
            .no => o.flush(g),
            .line => if (std.mem.indexOfScalar(u8, bytes, '\n') != null) o.flush(g),
        };
        if (o.buf.items.len + bytes.len > o.limit) o.flush(g);
        if (bytes.len >= o.limit) {
            o.send(g, bytes);
            return;
        }
        o.buf.appendSlice(g.gpa, bytes) catch {
            o.flush(g);
            o.send(g, bytes);
        };
    }

    pub fn flush(o: *Out, g: *Global) void {
        if (o.buf.items.len == 0) return;
        o.send(g, o.buf.items);
        o.buf.clearRetainingCapacity();
    }

    fn send(o: *Out, g: *Global, bytes: []const u8) void {
        if (o.capture) |c| {
            c.appendSlice(g.gpa, bytes) catch |e| o.fail(e);
            return;
        }
        o.file.writeStreamingAll(g.io, bytes) catch |e| o.fail(e);
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

/// Writes the buffered output of the handles in `pending`. The `io`
/// library sets it when it opens.
pub var flush_pending: ?*const fn (g: *Global) void = null;

/// Flushes the standard output alone.
pub fn flushStdout(g: *Global) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        o.flush(g);
    }
}

/// Flushes the standard output, then every other handle with buffered
/// output.
pub fn flushAll(g: *Global) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        o.flush(g);
        if (o.pending.items.len > 0) if (flush_pending) |f| f(g);
    }
}

pub fn deinit(g: *Global) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        o.flush(g);
        if (o.pending.items.len > 0) if (flush_pending) |f| f(g);
        o.pending.deinit(g.gpa);
        o.buf.deinit(g.gpa);
        g.gpa.destroy(o);
        _ = g.ext.remove("out.stdout");
    }
}

/// Writes directly to standard error after flushing standard output.
pub fn stderr(g: *Global, bytes: []const u8) void {
    flushAll(g);
    writeStderr(g, bytes);
}

/// Writes to standard error, or to the capture buffer of the standard
/// output when `lus test --doc` has set one, so a code block that warns
/// shows its warning in the output that its comments name.
pub fn writeStderr(g: *Global, bytes: []const u8) void {
    if (g.ext.get("out.stdout")) |p| {
        const o: *Out = @ptrCast(@alignCast(p));
        if (o.capture) |c| {
            c.appendSlice(g.gpa, bytes) catch {};
            return;
        }
    }
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
