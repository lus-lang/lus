//! The wire layer of `lus debug`: Debug Adapter Protocol framing over a
//! pair of file descriptors, an inbox filled by a reader thread, and a
//! small JSON writer for responses and events.
//!
//! Every message is a JSON body preceded by a `Content-Length` header and
//! a blank line. Writes come from the interpreter thread and from the
//! threads that forward the program's output, so a mutex keeps each
//! message whole.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fd_t = std.c.fd_t;

// ---------------------------------------------------------------------
// JSON writer

/// Builds one JSON document. Values written in a row inside an object or
/// array are separated by commas automatically.
pub const Json = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    comma: bool = false,

    pub fn deinit(j: *Json) void {
        j.buf.deinit(j.gpa);
    }

    fn sep(j: *Json) Allocator.Error!void {
        if (j.comma) try j.buf.append(j.gpa, ',');
        j.comma = true;
    }

    pub fn beginObject(j: *Json) Allocator.Error!void {
        try j.sep();
        try j.buf.append(j.gpa, '{');
        j.comma = false;
    }

    pub fn endObject(j: *Json) Allocator.Error!void {
        try j.buf.append(j.gpa, '}');
        j.comma = true;
    }

    pub fn beginArray(j: *Json) Allocator.Error!void {
        try j.sep();
        try j.buf.append(j.gpa, '[');
        j.comma = false;
    }

    pub fn endArray(j: *Json) Allocator.Error!void {
        try j.buf.append(j.gpa, ']');
        j.comma = true;
    }

    /// Writes an object key. The next value written belongs to it.
    pub fn key(j: *Json, k: []const u8) Allocator.Error!void {
        try j.sep();
        try writeString(j.gpa, &j.buf, k);
        try j.buf.append(j.gpa, ':');
        j.comma = false;
    }

    pub fn string(j: *Json, s: []const u8) Allocator.Error!void {
        try j.sep();
        try writeString(j.gpa, &j.buf, s);
    }

    pub fn int(j: *Json, n: i64) Allocator.Error!void {
        try j.sep();
        try j.buf.print(j.gpa, "{d}", .{n});
    }

    pub fn boolean(j: *Json, b: bool) Allocator.Error!void {
        try j.sep();
        try j.buf.appendSlice(j.gpa, if (b) "true" else "false");
    }

    /// Shorthands for a key followed by its value.
    pub fn fieldString(j: *Json, k: []const u8, s: []const u8) Allocator.Error!void {
        try j.key(k);
        try j.string(s);
    }

    pub fn fieldInt(j: *Json, k: []const u8, n: i64) Allocator.Error!void {
        try j.key(k);
        try j.int(n);
    }

    pub fn fieldBool(j: *Json, k: []const u8, b: bool) Allocator.Error!void {
        try j.key(k);
        try j.boolean(b);
    }
};

/// Appends `s` as a JSON string. Control characters are escaped, and any
/// other byte is copied, so well-formed text stays readable.
pub fn writeString(gpa: Allocator, buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try buf.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try buf.print(gpa, "\\u{x:0>4}", .{c}),
        else => try buf.append(gpa, c),
    };
    try buf.append(gpa, '"');
}

// ---------------------------------------------------------------------
// Transport

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    in_fd: fd_t,
    out_fd: fd_t,
    write_mutex: Io.Mutex = .init,
    /// A word-sized counter, since 32-bit targets lack 64-bit atomics.
    seq: std.atomic.Value(isize) = .init(1),

    // The inbox, filled by the reader thread.
    in_mutex: Io.Mutex = .init,
    in_cond: Io.Condition = .init,
    inbox: std.ArrayList([]u8) = .empty,
    closed: bool = false,
    /// True while the inbox holds a message, read without the lock by
    /// the interpreter's line hook.
    pending: std.atomic.Value(bool) = .init(false),

    pub fn nextSeq(t: *Transport) i64 {
        return @intCast(t.seq.fetchAdd(1, .monotonic));
    }

    /// Sends one framed message.
    pub fn send(t: *Transport, body: []const u8) void {
        var header: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
        t.write_mutex.lockUncancelable(t.io);
        defer t.write_mutex.unlock(t.io);
        writeAll(t.out_fd, h);
        writeAll(t.out_fd, body);
    }

    /// Starts the thread that reads messages into the inbox.
    pub fn startReader(t: *Transport) !void {
        const th = try std.Thread.spawn(.{}, readerMain, .{t});
        th.detach();
    }

    /// Takes the next message without waiting. The caller owns it.
    pub fn poll(t: *Transport) ?[]u8 {
        t.in_mutex.lockUncancelable(t.io);
        defer t.in_mutex.unlock(t.io);
        return t.takeLocked();
    }

    /// Waits for the next message. Returns null once the client has
    /// closed the connection and every message was taken.
    pub fn wait(t: *Transport) ?[]u8 {
        t.in_mutex.lockUncancelable(t.io);
        defer t.in_mutex.unlock(t.io);
        while (t.inbox.items.len == 0 and !t.closed) t.in_cond.waitUncancelable(t.io, &t.in_mutex);
        return t.takeLocked();
    }

    pub fn isClosed(t: *Transport) bool {
        t.in_mutex.lockUncancelable(t.io);
        defer t.in_mutex.unlock(t.io);
        return t.closed and t.inbox.items.len == 0;
    }

    fn takeLocked(t: *Transport) ?[]u8 {
        if (t.inbox.items.len == 0) return null;
        const m = t.inbox.orderedRemove(0);
        t.pending.store(t.inbox.items.len > 0, .release);
        return m;
    }

    fn put(t: *Transport, msg: ?[]u8) void {
        t.in_mutex.lockUncancelable(t.io);
        defer t.in_mutex.unlock(t.io);
        if (msg) |m| {
            t.inbox.append(t.gpa, m) catch {
                t.gpa.free(m);
                return;
            };
            t.pending.store(true, .release);
        } else {
            t.closed = true;
            t.pending.store(true, .release);
        }
        t.in_cond.broadcast(t.io);
    }

    fn readerMain(t: *Transport) void {
        var r: FrameReader = .{ .fd = t.in_fd };
        while (true) {
            const msg = r.next(t.gpa) catch null;
            t.put(msg);
            if (msg == null) return;
        }
    }
};

/// Reads `Content-Length` framed messages from a descriptor.
const FrameReader = struct {
    fd: fd_t,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(r: *FrameReader) !bool {
        if (r.start > 0) {
            std.mem.copyForwards(u8, r.buf[0 .. r.end - r.start], r.buf[r.start..r.end]);
            r.end -= r.start;
            r.start = 0;
        }
        if (r.end == r.buf.len) return error.HeaderTooLong;
        const n = readSome(r.fd, r.buf[r.end..]);
        if (n == 0) return false;
        r.end += n;
        return true;
    }

    /// Returns the next message body, or null at the end of input.
    fn next(r: *FrameReader, gpa: Allocator) !?[]u8 {
        // The header ends at the first blank line.
        var len: ?usize = null;
        while (true) {
            if (std.mem.indexOf(u8, r.buf[r.start..r.end], "\r\n\r\n")) |i| {
                const header = r.buf[r.start .. r.start + i];
                var lines = std.mem.splitSequence(u8, header, "\r\n");
                while (lines.next()) |line| {
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    const name = std.mem.trim(u8, line[0..colon], " ");
                    if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                        len = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
                    }
                }
                r.start += i + 4;
                break;
            }
            if (!try r.fill()) return null;
        }
        const n = len orelse return error.MissingLength;
        const body = try gpa.alloc(u8, n);
        errdefer gpa.free(body);
        var got: usize = 0;
        while (got < n) {
            if (r.start == r.end) {
                if (!try r.fill()) return null;
            }
            const take = @min(n - got, r.end - r.start);
            @memcpy(body[got .. got + take], r.buf[r.start .. r.start + take]);
            r.start += take;
            got += take;
        }
        return body;
    }
};

/// Reads at most `dst.len` bytes, retrying on interruption. Returns 0 at
/// the end of input or on an error.
pub fn readSome(fd: fd_t, dst: []u8) usize {
    while (true) {
        const n = std.c.read(fd, dst.ptr, dst.len);
        if (n > 0) return @intCast(n);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        return 0;
    }
}

pub fn writeAll(fd: fd_t, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) {
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

test "json writer separates values" {
    var j: Json = .{ .gpa = std.testing.allocator };
    defer j.deinit();
    try j.beginObject();
    try j.fieldInt("a", 1);
    try j.key("b");
    try j.beginArray();
    try j.string("x\n");
    try j.boolean(true);
    try j.endArray();
    try j.fieldString("c", "q\"");
    try j.endObject();
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":[\"x\\n\",true],\"c\":\"q\\\"\"}", j.buf.items);
}
