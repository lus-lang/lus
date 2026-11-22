//! HTTP bodies read as streams, and `network.fetch`.
//!
//! A body is decoded from the buffer of the socket that carries it, by
//! its framing: a `Content-Length`, chunked transfer coding, or the end of
//! the stream. The state of the decoding lives in the socket (`Body`), so
//! a native that waits and runs again continues from there. A body reader
//! (`network.body`) is the userdata that hands a body to Lus code piece
//! by piece. `network.fetch` returns one for a response when its options
//! ask for a stream, and `network.serve` gives one with every request.
//!
//! `fetch` is a native that runs through phases kept in the socket: the
//! TLS handshake, sending the request, sending a body that a function
//! produces, reading the head of the response, and reading the body.
//! Every phase waits through the scheduler, so `fetch` suspends inside a
//! detached coroutine and runs the scheduler anywhere else.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const pledge = @import("../vm/pledge.zig");
const sched = @import("../vm/sched.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const net = @import("network.zig");
const tls = @import("tls.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;

pub const reader_name = "network.body";

/// A response body that `fetch` reads whole holds at most 64 MiB.
const fetch_max_body = 64 * 1024 * 1024;
/// The status line and the headers of a response fit in 64 KiB.
const max_response_head = 64 * 1024;
/// Every wait of `fetch` lasts at most 30 seconds, unless its options say
/// otherwise.
const fetch_timeout_ms = 30000;
/// What one `read` of a body reader returns at most by default.
const default_read = 64 * 1024;
/// A line of a body reader holds at most 1 MiB by default.
const default_line_limit = 1024 * 1024;

/// The limits of a request body that `network.serve` decodes: its line
/// of a chunk fits in 1 KiB, and its framing, which is the lines of its
/// chunks, the line ends after them, and its trailers, may spend 64 KiB
/// and 8 bytes more for every byte of data.
pub const request_limits = struct {
    pub const chunk_line = 1024;
    pub const framing = 64 * 1024;
    pub const framing_per_byte = 8;
};

// ---------------------------------------------------------------------
// Decoding a body

pub const Framing = enum { none, length, chunked, eof };

/// The decoding of a body from the buffer of its socket.
pub const Body = struct {
    framing: Framing,
    /// The bytes that a body with a length, or the current chunk, still
    /// carries.
    left: u64 = 0,
    chunk: enum { line, data, end, trailers } = .line,
    /// The bytes of framing that a chunked body has spent.
    framing_bytes: usize = 0,
    /// The bytes of data decoded so far.
    total: usize = 0,
    /// Decoded bytes that no read has returned yet.
    pending: std.ArrayList(u8) = .empty,
    done: bool = false,
    /// A request body follows the limits of `request_limits`, and its
    /// failures carry the status that refuses the request.
    request: bool = false,
    /// The status that refuses a request whose body broke its framing,
    /// or zero.
    bad: u16 = 0,
    /// The text of the failure of a response body.
    bad_msg: []const u8 = "",
    /// The exchange this body belongs to. A reader of an earlier exchange
    /// finds a different number.
    gen: u32 = 0,
    /// Set once a reader returned a part of the body.
    started: bool = false,
    /// Set while `req.body` reads the whole body.
    whole: bool = false,
    /// The most data that `req.body` takes, which refuses a larger body
    /// as soon as its length or the size of a chunk shows it, or zero.
    limit: usize = 0,
    /// The request asked for `100 Continue` before its body, which the
    /// server sends when the body is first read.
    expect_continue: bool = false,

    pub fn deinit(b: *Body, gpa: std.mem.Allocator) void {
        b.pending.deinit(gpa);
    }
};

const Step = enum { progress, more, bad };

fn refuse(b: *Body, status: u16, msg: []const u8) Step {
    b.bad = status;
    b.bad_msg = msg;
    return .bad;
}

/// The size of a chunk line, or null when the line is malformed: a size
/// in hexadecimal digits alone, then extensions after a semicolon that
/// hold no control character other than a tab.
pub fn chunkSize(line: []const u8) ?u64 {
    var digits = line;
    var ext: []const u8 = "";
    if (std.mem.indexOfScalar(u8, line, ';')) |semi| {
        digits = line[0..semi];
        ext = line[semi..];
    }
    digits = std.mem.trimEnd(u8, digits, " \t");
    if (digits.len == 0 or digits.len > 2 * @sizeOf(u64)) return null;
    var size: u64 = 0;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        size = size * 16 + d;
    }
    for (ext) |c| {
        if ((c < ' ' and c != '\t') or c == 0x7f) return null;
    }
    return size;
}

/// The end of the line that starts at `from` in `buf`: the index of its
/// carriage return, or null when the line is incomplete. A request needs
/// CRLF, and a response may end a line with a line feed alone.
fn lineEnd(b: *const Body, buf: []const u8, from: usize) ?struct { end: usize, next: usize } {
    if (b.request) {
        const eol = std.mem.indexOfPos(u8, buf, from, "\r\n") orelse return null;
        return .{ .end = eol, .next = eol + 2 };
    }
    const nl = std.mem.indexOfScalarPos(u8, buf, from, '\n') orelse return null;
    const end = if (nl > from and buf[nl - 1] == '\r') nl - 1 else nl;
    return .{ .end = end, .next = nl + 1 };
}

/// Decodes what the buffer of `s` holds into `b.pending`, at most `max`
/// bytes of data, and takes the bytes it used out of the buffer.
fn decode(l: *Thread, s: *net.Socket, b: *Body, max: usize) Error!Step {
    const gpa = l.g.gpa;
    const buf = s.buf.items;
    var pos: usize = 0;
    var room = max;
    const result: Step = step: while (true) {
        if (b.done) break :step .progress;
        switch (b.framing) {
            .none => {
                b.done = true;
                break :step .progress;
            },
            .eof, .length => {
                const avail = buf.len - pos;
                var n = @min(avail, room);
                if (b.framing == .length) n = @min(n, b.left);
                if (n == 0 and !(b.framing == .length and b.left == 0)) break :step if (room == 0) .progress else .more;
                b.pending.appendSlice(gpa, buf[pos..][0..n]) catch return l.raiseMem();
                pos += n;
                room -= n;
                b.total += n;
                if (b.framing == .length) {
                    b.left -= n;
                    if (b.left == 0) b.done = true;
                }
                break :step .progress;
            },
            .chunked => switch (b.chunk) {
                .line => {
                    const le = lineEnd(b, buf, pos) orelse {
                        if (b.request and buf.len - pos > request_limits.chunk_line) break :step refuse(b, 400, "malformed chunked body");
                        break :step .more;
                    };
                    const line = buf[pos..le.end];
                    if (b.request and line.len > request_limits.chunk_line) break :step refuse(b, 400, "malformed chunked body");
                    const size = chunkSize(line) orelse break :step refuse(b, 400, "invalid chunk size");
                    b.framing_bytes += le.next - pos;
                    pos = le.next;
                    if (size == 0) {
                        b.chunk = .trailers;
                        continue;
                    }
                    if (b.limit != 0 and size > b.limit - @min(b.limit, b.total)) break :step refuse(b, 413, "request body too large");
                    // The line end after the data counts with its chunk.
                    b.framing_bytes += 2;
                    if (b.request and b.framing_bytes > request_limits.framing + request_limits.framing_per_byte * (b.total + size))
                        break :step refuse(b, 413, "chunked body framing too large");
                    b.left = size;
                    b.chunk = .data;
                },
                .data => {
                    const n: usize = @intCast(@min(@min(b.left, buf.len - pos), room));
                    if (n == 0) break :step if (room == 0 or pos > 0) .progress else .more;
                    b.pending.appendSlice(gpa, buf[pos..][0..n]) catch return l.raiseMem();
                    pos += n;
                    room -= n;
                    b.total += n;
                    b.left -= n;
                    if (b.left > 0) break :step .progress;
                    b.chunk = .end;
                },
                .end => {
                    if (b.request) {
                        if (buf.len - pos < 2) break :step if (pos > 0) .progress else .more;
                        if (buf[pos] != '\r' or buf[pos + 1] != '\n') break :step refuse(b, 400, "invalid chunk terminator");
                        pos += 2;
                    } else {
                        const le = lineEnd(b, buf, pos) orelse break :step if (pos > 0) .progress else .more;
                        if (le.end != pos) break :step refuse(b, 400, "invalid chunk terminator");
                        pos = le.next;
                    }
                    b.chunk = .line;
                },
                // Trailer lines follow the last chunk, up to an empty line.
                .trailers => {
                    const le = lineEnd(b, buf, pos) orelse {
                        if (b.request and b.framing_bytes + (buf.len - pos) > request_limits.framing + request_limits.framing_per_byte * b.total)
                            break :step refuse(b, 431, "chunked body trailers too large");
                        break :step if (pos > 0) .progress else .more;
                    };
                    const len = le.end - pos;
                    b.framing_bytes += le.next - pos;
                    pos = le.next;
                    if (b.request and b.framing_bytes > request_limits.framing + request_limits.framing_per_byte * b.total)
                        break :step refuse(b, 431, "chunked body trailers too large");
                    if (len == 0) {
                        b.done = true;
                        break :step .progress;
                    }
                },
            },
        }
    };
    if (pos > 0) consume(s, pos);
    return result;
}

fn consume(s: *net.Socket, n: usize) void {
    const rest = s.buf.items.len - n;
    std.mem.copyForwards(u8, s.buf.items[0..rest], s.buf.items[n..]);
    s.buf.items.len = rest;
}

/// The failure of a body as an error of Lus code.
fn raiseBad(l: *Thread, b: *Body) Error {
    if (b.request) return l.raiseFmt("invalid request body: {s}", .{b.bad_msg});
    return l.raiseFmt("{s}", .{b.bad_msg});
}

/// Reads more bytes of `b` into the buffer of `s`, waiting as needed. The
/// end of the stream ends a body that runs to it, and truncates any
/// other. `timeout` is the error of a wait that runs out.
fn refill(l: *Thread, s: *net.Socket, b: *Body, comptime timeout: []const u8) Error!void {
    if (b.expect_continue) {
        // The client waits for this line before it sends the body.
        b.expect_continue = false;
        _ = net.trySend(l, s, "HTTP/1.1 100 Continue\r\n\r\n");
    }
    const got = (try net.tryFill(l, s, 65536)) orelse {
        // A request body that stalls is refused with 408.
        if (b.request) {
            b.bad = 408;
            b.bad_msg = "request timeout";
        }
        return l.raiseFmt(timeout, .{});
    };
    switch (got) {
        .got => {},
        .eof => {
            if (b.framing == .eof) {
                b.done = true;
                return;
            }
            b.bad = 400;
            b.bad_msg = if (b.request) "truncated request body" else if (b.framing == .chunked) "truncated chunked response" else "truncated response body";
            return raiseBad(l, b);
        },
        .fail => |e| return l.raiseFmt("receive: {s}", .{net.errText(e)}),
    }
}

/// Decodes more of `b`, at most `max` bytes, and reads the socket when
/// the buffer holds too little. Raises when the body broke its framing.
fn advance(l: *Thread, s: *net.Socket, b: *Body, max: usize, comptime timeout: []const u8) Error!void {
    if (b.bad != 0) return raiseBad(l, b);
    switch (try decode(l, s, b, max)) {
        .progress => {},
        .bad => return raiseBad(l, b),
        .more => try refill(l, s, b, timeout),
    }
}

/// Makes `b.pending` hold at least one byte, or the body end. Waits for
/// the socket as needed. Returns false at the end of the body.
fn pull(l: *Thread, s: *net.Socket, b: *Body, max: usize) Error!bool {
    while (true) {
        if (b.pending.items.len > 0) return true;
        if (b.done) return false;
        try advance(l, s, b, max, "receive timeout");
    }
}

/// Takes the first `n` pending bytes of `b` as a new vector on the stack.
fn takePending(l: *Thread, b: *Body, n: usize) Error!void {
    const v = try vector.newVector(l, b.pending.items[0..n]);
    const rest = b.pending.items.len - n;
    std.mem.copyForwards(u8, b.pending.items[0..rest], b.pending.items[n..]);
    b.pending.items.len = rest;
    try l.push(Value.obj(.vector, v));
}

// ---------------------------------------------------------------------
// The state of a socket

/// Frees what this file keeps in a socket that closes.
pub fn freeState(gpa: std.mem.Allocator, s: *net.Socket) void {
    if (s.body) |b| {
        b.deinit(gpa);
        gpa.destroy(b);
        s.body = null;
    }
    if (s.fetch) |f| {
        f.deinit(gpa);
        gpa.destroy(f);
        s.fetch = null;
    }
}

/// Starts the body of a new exchange on `s` and returns it. The number of
/// the exchange goes up by one.
pub fn startBody(l: *Thread, s: *net.Socket, framing: Framing, length: u64, request: bool) Error!*Body {
    const gpa = l.g.gpa;
    var gen: u32 = 1;
    if (s.body) |old| {
        gen = old.gen +% 1;
        old.pending.clearRetainingCapacity();
        const keep = old.pending;
        old.* = .{ .framing = framing, .left = length, .request = request, .gen = gen, .pending = keep };
        if (framing == .length and length == 0) old.done = true;
        return old;
    }
    const b = gpa.create(Body) catch return l.raiseMem();
    b.* = .{ .framing = framing, .left = length, .request = request, .gen = gen };
    if (framing == .length and length == 0) b.done = true;
    s.body = b;
    return b;
}

// ---------------------------------------------------------------------
// Body readers

/// A body reader. Its user value is the socket, which it keeps alive.
pub const Reader = struct {
    sock: *net.Socket,
    gen: u32,
    /// A response reader closes its socket at the end of the body and in
    /// `close`. A request reader leaves the connection to the server.
    response: bool,
    /// Set at the end of the body, after which every read returns nil
    /// without the socket.
    finished: bool = false,
    closed: bool = false,
};

pub const reader_methods = [_]aux.Reg{
    .{ .name = "read", .func = readerRead },
    .{ .name = "readline", .func = readerReadline },
    .{ .name = "lines", .func = readerLines },
    .{ .name = "readall", .func = readerReadall },
    .{ .name = "close", .func = readerClose },
};

/// Pushes a new reader of the body of `s`, which is at `sock_slot` on the
/// stack.
pub fn pushReader(l: *Thread, s: *net.Socket, slot: u32, response: bool) Error!*Reader {
    const g = l.g;
    gc.maybeCollect(g);
    const mt: *Table = @ptrCast(@alignCast(g.ext.get(reader_name).?));
    const u = gc.alloc(g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Reader), 1)) catch return l.raiseMem();
    u.size = @sizeOf(Reader);
    u.nuser = 1;
    u.metatable = mt;
    u.userValues()[0] = l.stack[slot];
    const r: *Reader = @ptrCast(@alignCast(u.data()));
    r.* = .{ .sock = s, .gen = s.body.?.gen, .response = response };
    try l.push(Value.obj(.userdata, u));
    gc.barrierBack(g, &u.hdr);
    return r;
}

fn toReader(l: *Thread, v: Value) ?*Reader {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    const mt: *Table = @ptrCast(@alignCast(l.g.ext.get(reader_name) orelse return null));
    if (u.metatable != mt) return null;
    return @ptrCast(@alignCast(u.data()));
}

/// The body of a reader that may still read, or null at its end.
fn readerBody(l: *Thread, i: u32) Error!?*Body {
    const r = toReader(l, l.arg(i)) orelse return aux.typeError(l, i, reader_name);
    return bodyOf(l, r);
}

fn bodyOf(l: *Thread, r: *Reader) Error!?*Body {
    if (r.closed) return l.raiseFmt("attempt to use a closed body", .{});
    if (r.finished) return null;
    const s = r.sock;
    const b = s.body orelse return l.raiseFmt("the body is no longer available", .{});
    if (b.gen != r.gen) return l.raiseFmt("the body is no longer available", .{});
    if (s.closed) return l.raiseFmt("attempt to use a closed body", .{});
    b.started = true;
    return b;
}

/// Marks a reader whose body ended. A response reader closes its socket,
/// since `fetch` asks the server to close the connection after the
/// response.
fn finish(l: *Thread, i: u32) void {
    finishReader(l, toReader(l, l.arg(i)).?);
}

fn finishReader(l: *Thread, r: *Reader) void {
    r.finished = true;
    if (r.response) net.closeSocketOf(l, r.sock);
}

/// reader:read(n): up to `n` bytes of the body as a vector, or nil at its
/// end.
fn readerRead(l: *Thread) Error!u32 {
    const max: usize = blk: {
        if (l.arg(2).isNil()) break :blk default_read;
        const n = try aux.checkInt(l, 2);
        if (n <= 0) return aux.argError(l, 2, "size must be positive", .{});
        break :blk @intCast(@min(n, std.math.maxInt(u32)));
    };
    const b = (try readerBody(l, 1)) orelse return aux.retNil(l);
    const r = toReader(l, l.arg(1)).?;
    if (!try pull(l, r.sock, b, max)) {
        finish(l, 1);
        return aux.retNil(l);
    }
    try takePending(l, b, @min(max, b.pending.items.len));
    return 1;
}

/// reader:readline(limit): the next line of the body without its line
/// end, as a vector, or nil at its end. The last line may lack a line end.
fn readerReadline(l: *Thread) Error!u32 {
    const limit: usize = blk: {
        if (l.arg(2).isNil()) break :blk default_line_limit;
        const n = try aux.checkInt(l, 2);
        if (n <= 0) return aux.argError(l, 2, "limit must be positive", .{});
        break :blk @intCast(@min(n, std.math.maxInt(u32)));
    };
    const b = (try readerBody(l, 1)) orelse return aux.retNil(l);
    const r = toReader(l, l.arg(1)).?;
    var scanned: usize = 0;
    while (true) {
        if (std.mem.indexOfScalarPos(u8, b.pending.items, scanned, '\n')) |nl| {
            var len = nl;
            if (len > 0 and b.pending.items[len - 1] == '\r') len -= 1;
            if (len > limit) return l.raiseFmt("line too long", .{});
            try takePending(l, b, len);
            const rest = b.pending.items.len - (nl - len + 1);
            std.mem.copyForwards(u8, b.pending.items[0..rest], b.pending.items[nl - len + 1 ..]);
            b.pending.items.len = rest;
            return 1;
        }
        scanned = b.pending.items.len;
        if (scanned > limit + 1) return l.raiseFmt("line too long", .{});
        if (b.done) {
            if (b.pending.items.len == 0) {
                finish(l, 1);
                return aux.retNil(l);
            }
            try takePending(l, b, b.pending.items.len);
            return 1;
        }
        // The decoded bytes stay pending while the next part arrives.
        try advance(l, r.sock, b, 16384, "receive timeout");
    }
}

/// reader:lines(): an iterator over the lines of the body, for a
/// generic `for`.
fn readerLines(l: *Thread) Error!u32 {
    _ = toReader(l, l.arg(1)) orelse return aux.typeError(l, 1, reader_name);
    l.top = l.base() + 1;
    try l.push(try aux.native(l, linesNext, "lines"));
    try l.push(l.stack[l.base()]);
    return 2;
}

/// The iterator of `lines`, which leaves out the control value that the
/// generic `for` passes.
fn linesNext(l: *Thread) Error!u32 {
    l.top = l.base() + 1;
    return readerReadline(l);
}

/// Reads the rest of the body of `r` into one vector, at most `limit`
/// bytes, and pushes it. Raises `too_large` past the limit.
fn readRest(l: *Thread, r: *Reader, limit: usize, comptime too_large: []const u8) Error!void {
    const b = (try bodyOf(l, r)) orelse return l.push(Value.obj(.vector, try vector.newVector(l, &.{})));
    while (!b.done) {
        if (b.pending.items.len > limit) return tooLarge(l, r.sock, too_large);
        try advance(l, r.sock, b, 1 << 20, "receive timeout");
    }
    if (b.pending.items.len > limit) return tooLarge(l, r.sock, too_large);
    const v = try vector.newVectorFrom(l, &b.pending);
    b.pending = .empty;
    try l.push(Value.obj(.vector, v));
    finishReader(l, r);
}

/// Raises `msg` for a body over its limit. A request body that goes over
/// it makes the server refuse the request with 413.
fn tooLarge(l: *Thread, s: *net.Socket, comptime msg: []const u8) Error {
    if (s.body) |b| {
        if (b.request) {
            b.bad = 413;
            b.bad_msg = "request body too large";
        }
    }
    return l.raiseFmt(msg, .{});
}

/// reader:readall(limit): the rest of the body as one vector.
fn readerReadall(l: *Thread) Error!u32 {
    const limit: usize = blk: {
        if (l.arg(2).isNil()) break :blk fetch_max_body;
        const n = try aux.checkInt(l, 2);
        if (n <= 0) return aux.argError(l, 2, "limit must be positive", .{});
        break :blk @intCast(@min(n, std.math.maxInt(u32)));
    };
    const r = toReader(l, l.arg(1)) orelse return aux.typeError(l, 1, reader_name);
    try readRest(l, r, limit, "body too large");
    return 1;
}

/// reader:close(): stops reading. A response reader closes its
/// connection. A request reader leaves the rest of the body to the server.
fn readerClose(l: *Thread) Error!u32 {
    const r = toReader(l, l.arg(1)) orelse return aux.typeError(l, 1, reader_name);
    if (r.closed) return 0;
    r.closed = true;
    if (r.response and !r.finished) net.closeSocketOf(l, r.sock);
    return 0;
}

pub fn readerTostring(l: *Thread) Error!u32 {
    const r = toReader(l, l.arg(1)) orelse return aux.typeError(l, 1, reader_name);
    if (r.closed) return aux.retStr(l, "body (closed)");
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, "body (0x{x})", .{l.arg(1).payload}) catch "body");
}

pub fn readerCloseMeta(l: *Thread) Error!u32 {
    return readerClose(l);
}

// ---------------------------------------------------------------------
// Request bodies in network.serve

/// The status that refuses the request whose body broke its framing
/// while the handler read it, or zero.
pub fn requestRefusal(s: *net.Socket) u16 {
    const b = s.body orelse return 0;
    return if (b.request) b.bad else 0;
}

/// Reads and drops what is left of the request body of `s`, so that the
/// next request starts after it. Returns false when the connection must
/// close: the body broke its framing, went over `limit`, or waits for a
/// `100 Continue` that the server never sent, or the peer left.
pub fn drainRequest(l: *Thread, s: *net.Socket, limit: usize) Error!bool {
    const b = s.body orelse return true;
    if (!b.request) return true;
    while (true) {
        b.pending.clearRetainingCapacity();
        if (b.done) return true;
        if (b.bad != 0 or b.expect_continue) return false;
        switch (try decode(l, s, b, 1 << 20)) {
            .progress => {
                if (b.total > limit) return false;
                continue;
            },
            .bad => return false,
            .more => {},
        }
        const got = (try net.tryFill(l, s, 65536)) orelse return false;
        switch (got) {
            .got => {},
            .eof, .fail => return false,
        }
    }
}

/// readbody(req): reads the whole body of the request table `req`, at
/// most `limit` bytes, stores it as `req.body`, and returns it. The
/// `__index` of request tables calls it.
pub fn requestBody(l: *Thread, limit: usize) Error!u32 {
    const req = try aux.checkTable(l, 1);
    const rv = try aux.getField(l, req, "reader");
    const r = toReader(l, rv) orelse return aux.retNil(l);
    if (r.finished) return l.raiseFmt("the request body was already read through req.reader", .{});
    if (r.sock.body) |b| {
        if (b.gen == r.gen) {
            if (b.started and !b.whole) return l.raiseFmt("the request body was already read through req.reader", .{});
            b.whole = true;
            b.limit = limit;
            if (b.framing == .length and b.left > limit) return tooLarge(l, r.sock, "request body too large");
        }
    }
    try readRest(l, r, limit, "request body too large");
    const body = l.stack[l.top - 1];
    try ops.rawSet(l, req, try l.newStringValue("body"), body);
    return aux.ret(l, body);
}

// ---------------------------------------------------------------------
// network.fetch

const ParsedUrl = struct {
    https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    var r: ParsedUrl = undefined;
    if (std.mem.eql(u8, scheme, "http")) {
        r.https = false;
        r.port = 80;
    } else if (std.mem.eql(u8, scheme, "https")) {
        r.https = true;
        r.port = 443;
    } else return null;
    const rest = url[sep + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/:") orelse rest.len;
    if (host_end == 0 or host_end >= 256) return null;
    r.host = rest[0..host_end];
    var i = host_end;
    if (i < rest.len and rest[i] == ':') {
        const pstart = i + 1;
        var j = pstart;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j == pstart or (j < rest.len and rest[j] != '/')) return null;
        const port = std.fmt.parseInt(u32, rest[pstart..j], 10) catch return null;
        if (port == 0 or port > 65535) return null;
        r.port = @intCast(port);
        i = j;
    }
    r.path = if (i < rest.len) rest[i..] else "/";
    if (r.path.len >= 2048) return null;
    return r;
}

/// The state of one `fetch`, kept in its socket.
pub const Fetch = struct {
    phase: enum { handshake, send, generate, head, body } = .handshake,
    /// The bytes being sent and how many went out.
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    /// Set once the function that produces the request body returned nil.
    last: bool = false,
    /// What the request asked for and what the response said.
    head_method: bool = false,
    stream: bool = false,
    status: i64 = 0,
    /// Where the search for the end of the head continues.
    scan: usize = 0,

    pub fn deinit(f: *Fetch, gpa: std.mem.Allocator) void {
        f.out.deinit(gpa);
    }
};

/// Appends the bytes of a header name or value: a string, or a number
/// converted to a string. Returns false for any other value.
fn headerText(l: *Thread, v: Value, buf: *std.ArrayList(u8)) Error!bool {
    const s = switch (v.tag) {
        .string => v.as(object.String),
        else => if (v.isNumber()) try ops.toString(l, v) else return false,
    };
    buf.appendSlice(l.g.gpa, s.bytes()) catch return l.raiseMem();
    return true;
}

/// The default User-Agent header: `Lus/` and the version of the build.
const user_agent = "User-Agent: Lus/" ++ @import("build_options").version ++ "\r\n";

/// Formats the head of the request, and the body when it is a string or
/// a vector. `body_fn` says the body comes from a function, which the
/// request sends with chunked transfer coding unless the caller set a
/// `Content-Length`.
fn buildRequest(l: *Thread, req: *std.ArrayList(u8), method: []const u8, u: ParsedUrl, body: ?[]const u8, body_fn: bool) Error!void {
    const gpa = l.g.gpa;
    const default_port: u16 = if (u.https) 443 else 80;
    req.print(gpa, "{s} {s} HTTP/1.1\r\n", .{ method, u.path }) catch return l.raiseMem();
    // The headers of the caller come after the request line, and a default
    // header that the caller also names is left out.
    var own: std.ArrayList(u8) = .empty;
    defer own.deinit(gpa);
    var has_host = false;
    var has_conn = false;
    var has_agent = false;
    var has_length = false;
    if (l.arg(3).tag == .table) {
        const ht = l.arg(3).as(Table);
        var key: Value = .nil;
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(gpa);
        var val: std.ArrayList(u8) = .empty;
        defer val.deinit(gpa);
        while (table.next(ht, key) catch null) |kv| {
            key = kv.key;
            name.clearRetainingCapacity();
            val.clearRetainingCapacity();
            if (!try headerText(l, kv.key, &name)) continue;
            if (std.mem.indexOfAny(u8, name.items, "\r\n") != null)
                return l.raiseFmt("invalid characters in HTTP header", .{});
            // A list sends one header line for each of its values.
            const list: ?*Table = if (kv.val.tag == .table) kv.val.as(Table) else null;
            const n: i64 = if (list) |t| table.length(t) else 1;
            var i: i64 = 1;
            while (i <= n) : (i += 1) {
                val.clearRetainingCapacity();
                const v = if (list) |t| table.getInt(t, i) else kv.val;
                if (!try headerText(l, v, &val)) continue;
                if (std.mem.indexOfAny(u8, val.items, "\r\n") != null)
                    return l.raiseFmt("invalid characters in HTTP header", .{});
                if (std.ascii.eqlIgnoreCase(name.items, "host")) has_host = true;
                if (std.ascii.eqlIgnoreCase(name.items, "connection")) has_conn = true;
                if (std.ascii.eqlIgnoreCase(name.items, "user-agent")) has_agent = true;
                if (std.ascii.eqlIgnoreCase(name.items, "content-length")) has_length = true;
                own.print(gpa, "{s}: {s}\r\n", .{ name.items, val.items }) catch return l.raiseMem();
            }
        }
    }
    if (!has_host) {
        if (u.port != default_port)
            req.print(gpa, "Host: {s}:{d}\r\n", .{ u.host, u.port }) catch return l.raiseMem()
        else
            req.print(gpa, "Host: {s}\r\n", .{u.host}) catch return l.raiseMem();
    }
    if (!has_conn) req.appendSlice(gpa, "Connection: close\r\n") catch return l.raiseMem();
    if (!has_agent) req.appendSlice(gpa, user_agent) catch return l.raiseMem();
    req.appendSlice(gpa, own.items) catch return l.raiseMem();
    if (body_fn) {
        if (!has_length) req.appendSlice(gpa, "Transfer-Encoding: chunked\r\n") catch return l.raiseMem();
    } else if (body) |b| if (b.len > 0) {
        req.print(gpa, "Content-Length: {d}\r\n", .{b.len}) catch return l.raiseMem();
    };
    req.appendSlice(gpa, "\r\n") catch return l.raiseMem();
    if (body) |b| req.appendSlice(gpa, b) catch return l.raiseMem();
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn parseContentLength(s: []const u8) ?u64 {
    const t = trimSpaces(s);
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

/// Parses the status code of "HTTP/<major>.<minor> <code>".
fn parseStatus(line: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return null;
    var i: usize = 5;
    const digits = struct {
        fn run(s: []const u8, start: usize) usize {
            var j = start;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            return j;
        }
    }.run;
    var j = digits(line, i);
    if (j == i or j >= line.len or line[j] != '.') return null;
    i = j + 1;
    j = digits(line, i);
    if (j == i) return null;
    i = j;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    var neg = false;
    if (i < line.len and (line[i] == '-' or line[i] == '+')) {
        neg = line[i] == '-';
        i += 1;
    }
    j = digits(line, i);
    if (j == i) return null;
    const n = std.fmt.parseInt(i64, line[i..@min(j, i + 18)], 10) catch return null;
    return if (neg) -n else n;
}

/// Stores a response header in `t`, decoding invalid UTF-8 lossily. A
/// header that repeats joins its earlier values with ", ", as HTTP allows
/// for a field that appears more than once.
fn setHeader(l: *Thread, t: *Table, key: []const u8, val: []const u8) Error!void {
    const gpa = l.g.gpa;
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    {
        var kb: std.ArrayList(u8) = .empty;
        defer kb.deinit(gpa);
        wtf8.appendLossy(gpa, &kb, key) catch return l.raiseMem();
        const prev = table.getStr(t, try l.newString(kb.items));
        if (prev.tag == .string) {
            tmp.appendSlice(gpa, prev.as(object.String).bytes()) catch return l.raiseMem();
            tmp.appendSlice(gpa, ", ") catch return l.raiseMem();
        }
    }
    wtf8.appendLossy(gpa, &tmp, val) catch return l.raiseMem();
    try l.push(try l.newStringValue(tmp.items));
    defer l.top -= 1;
    tmp.clearRetainingCapacity();
    wtf8.appendLossy(gpa, &tmp, key) catch return l.raiseMem();
    const k = try l.newStringValue(tmp.items);
    try l.push(k);
    defer l.top -= 1;
    try ops.rawSet(l, t, k, l.stack[l.top - 2]);
}

/// The options of `fetch` in argument 5.
const FetchOptions = struct {
    stream: bool = false,
    timeout_ms: i32 = fetch_timeout_ms,
};

fn fetchOptions(l: *Thread) Error!FetchOptions {
    var o: FetchOptions = .{};
    if (l.arg(5).isNil()) return o;
    const t = try aux.checkTable(l, 5);
    var key: Value = .nil;
    while (table.next(t, key) catch null) |e| : (key = e.key) {
        const name = if (e.key.tag == .string) e.key.as(object.String).bytes() else "";
        if (std.mem.eql(u8, name, "stream")) {
            if (e.val.tag != .true and e.val.tag != .false) return aux.argError(l, 5, "stream must be a boolean", .{});
            o.stream = e.val.tag == .true;
        } else if (std.mem.eql(u8, name, "timeout")) {
            const secs: f64 = switch (e.val.tag) {
                .integer => @floatFromInt(e.val.asInt()),
                .float => e.val.asFloat(),
                else => return aux.argError(l, 5, "timeout must be a number of seconds", .{}),
            };
            if (std.math.isNan(secs) or secs == 0) return aux.argError(l, 5, "timeout must be positive, or negative for no timeout", .{});
            const ms = @ceil(secs * 1000);
            o.timeout_ms = if (secs < 0) -1 else if (ms >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(ms);
        } else {
            return aux.argError(l, 5, "unknown option '{s}'", .{name});
        }
    }
    return o;
}

/// The slots of `fetch` on its stack, after its five arguments.
const sock_slot = 5;
const headers_slot = 6;

pub fn fetch(l: *Thread) Error!u32 {
    const b = l.base();
    if (sched.restarted(l) and l.top > b + sock_slot) {
        if (net.toObject(l, net.Socket, net.socket_name, l.stack[b + sock_slot])) |s| {
            if (s.fetch != null) return runFetch(l, s);
        }
    }
    try l.ensure(8);
    while (l.top < b + 5) : (l.top += 1) l.stack[l.top] = .nil;
    l.top = b + 5;

    const url = try aux.checkBytes(l, 1);
    const method = (try aux.optString(l, 2, "GET")).?;
    const body_arg = l.arg(4);
    const body_fn = body_arg.tag == .closure or body_arg.tag == .native;
    const body: ?[]const u8 = switch (body_arg.tag) {
        .nil => null,
        .string => body_arg.as(object.String).bytes(),
        .vector => body_arg.as(object.Vector).bytes.items,
        .closure, .native => null,
        else => return aux.typeError(l, 4, "string, vector, or function"),
    };
    const o = try fetchOptions(l);
    if (std.mem.indexOfAny(u8, method, "\r\n") != null) return l.raiseFmt("invalid characters in HTTP method", .{});
    if (std.mem.indexOfAny(u8, url, "\r\n") != null) return l.raiseFmt("invalid characters in URL", .{});
    try pledge.require(l, "network:http", url);
    const u = parseUrl(url) orelse return l.raiseFmt("invalid URL: {s}", .{url});

    const gpa = l.g.gpa;
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    try buildRequest(l, &req, method, u, body, body_fn);

    const cfg: ?*tls.Config = if (u.https) try tls.httpsConfig(l) else null;
    defer if (cfg) |c| tls.freeConfig(c);
    const stream, const peer = try net.connectTo(l, u.host, u.port);
    const s = net.newObject(l, net.Socket, net.socket_name, .{ .stream = stream, .local = stream.socket.address, .peer = peer }) catch |e| {
        stream.close(l.g.io);
        return e;
    };
    s.timeout_ms = o.timeout_ms;
    const f = gpa.create(Fetch) catch {
        net.releaseSocket(l, s);
        return l.raiseMem();
    };
    f.* = .{ .stream = o.stream, .head_method = std.ascii.eqlIgnoreCase(method, "HEAD") };
    s.fetch = f;
    f.out = req;
    req = .empty;
    if (cfg) |c| {
        tls.attach(l, s, c, u.host) catch |e| {
            net.releaseSocket(l, s);
            return e;
        };
    } else f.phase = .send;
    return runFetch(l, s);
}

/// Runs the phases of a fetch from the one it reached. Any failure that
/// does not suspend closes the socket.
fn runFetch(l: *Thread, s: *net.Socket) Error!u32 {
    return fetchPhases(l, s) catch |e| {
        if (!l.yielding and !s.closed) net.releaseSocket(l, s);
        return e;
    };
}

fn fetchPhases(l: *Thread, s: *net.Socket) Error!u32 {
    const f = s.fetch.?;
    const b = l.base();
    while (true) switch (f.phase) {
        .handshake => {
            try tls.handshake(l, s);
            f.phase = .send;
        },
        .send => {
            try sendOut(l, s, f);
            f.phase = if (l.arg(4).tag == .closure or l.arg(4).tag == .native) .generate else .head;
        },
        .generate => {
            if (f.out_off >= f.out.items.len) {
                if (f.last) {
                    f.phase = .head;
                    continue;
                }
                try nextChunk(l, f);
            }
            try sendOut(l, s, f);
        },
        .head => {
            if (try readHead(l, s, f)) |framing| {
                const body_len = framing.len;
                _ = try startBody(l, s, framing.framing, body_len, false);
                f.phase = .body;
            }
        },
        .body => {
            const status = f.status;
            if (f.stream) {
                // The reader takes the place of the body, and the socket
                // stays open until the body ends or the reader closes.
                _ = try pushReader(l, s, b + sock_slot, true);
                const reader = l.stack[l.top - 1];
                l.stack[b] = Value.int(status);
                l.stack[b + 1] = reader;
                l.stack[b + 2] = l.stack[b + headers_slot];
                l.top = b + 3;
                s.fetch.?.deinit(l.g.gpa);
                l.g.gpa.destroy(s.fetch.?);
                s.fetch = null;
                return 3;
            }
            l.top = b + headers_slot + 1;
            try l.push(try readWhole(l, s));
            net.closeSocketOf(l, s);
            const v = l.stack[l.top - 1];
            l.stack[b] = Value.int(status);
            l.stack[b + 1] = v;
            l.stack[b + 2] = l.stack[b + headers_slot];
            l.top = b + 3;
            return 3;
        },
    };
}

/// Sends `f.out` from `f.out_off` on, waiting as needed.
fn sendOut(l: *Thread, s: *net.Socket, f: *Fetch) Error!void {
    while (f.out_off < f.out.items.len) {
        switch (net.trySend(l, s, f.out.items[f.out_off..])) {
            .n => |n| {
                f.out_off += n;
                sched.opDone(l);
            },
            .again => {
                if (!try sched.waitIo(l, s.stream.socket.handle, net.againDir(s, .write), s.timeout_ms)) return l.raiseFmt("fetch timeout", .{});
                try net.stillOpen(l, s);
            },
            .fail => |e| return l.raiseFmt("failed to send request: {s}", .{net.errText(e)}),
        }
    }
    f.out.clearRetainingCapacity();
    f.out_off = 0;
}

/// Calls the function that produces the request body for its next chunk
/// and frames it in `f.out`.
fn nextChunk(l: *Thread, f: *Fetch) Error!void {
    const gpa = l.g.gpa;
    const v = try ops.call1(l, l.arg(4), &.{});
    switch (v.tag) {
        .nil => {
            f.last = true;
            if (requestIsChunked(l)) f.out.appendSlice(gpa, "0\r\n\r\n") catch return l.raiseMem();
        },
        .string, .vector => {
            const data = if (v.tag == .string) v.as(object.String).bytes() else v.as(object.Vector).bytes.items;
            if (data.len == 0) return;
            if (requestIsChunked(l)) {
                f.out.print(gpa, "{x}\r\n", .{data.len}) catch return l.raiseMem();
                f.out.appendSlice(gpa, data) catch return l.raiseMem();
                f.out.appendSlice(gpa, "\r\n") catch return l.raiseMem();
            } else {
                f.out.appendSlice(gpa, data) catch return l.raiseMem();
            }
        },
        else => return l.raiseFmt("the request body function returned a {s} (string, vector, or nil expected)", .{l.typeNameOf(v)}),
    }
}

/// Whether the request sends its body with chunked transfer coding, which
/// it does unless the caller set a `Content-Length`.
fn requestIsChunked(l: *Thread) bool {
    if (l.arg(3).tag != .table) return true;
    const ht = l.arg(3).as(Table);
    var key: Value = .nil;
    while (table.next(ht, key) catch null) |kv| : (key = kv.key) {
        if (kv.key.tag == .string and std.ascii.eqlIgnoreCase(kv.key.as(object.String).bytes(), "content-length")) return false;
    }
    return true;
}

const HeadResult = struct { framing: Framing, len: u64 };

/// Reads and parses the head of the response. Returns null when the head
/// is incomplete and the native should continue, after a wait, with
/// another call. Pushes the headers table into its slot.
fn readHead(l: *Thread, s: *net.Socket, f: *Fetch) Error!?HeadResult {
    const b = l.base();
    while (true) {
        const buf = s.buf.items;
        const end = headEnd(buf, &f.scan);
        if (end) |e| return try parseHead(l, s, f, buf[0..e.head], e.next, b);
        if (buf.len > max_response_head) return l.raiseFmt("response head too large", .{});
        const got = (try net.tryFill(l, s, 16384)) orelse return l.raiseFmt("fetch timeout", .{});
        switch (got) {
            .got => {},
            .eof => return l.raiseFmt("failed to read response", .{}),
            .fail => |e| return l.raiseFmt("failed to read response: {s}", .{net.errText(e)}),
        }
    }
}

/// Finds the empty line that ends the head in `buf`. Lines may end with a
/// line feed alone.
fn headEnd(buf: []const u8, scan: *usize) ?struct { head: usize, next: usize } {
    var i = scan.*;
    while (std.mem.indexOfScalarPos(u8, buf, i, '\n')) |nl| {
        if (nl + 1 < buf.len and buf[nl + 1] == '\n') return .{ .head = nl, .next = nl + 2 };
        if (nl + 2 < buf.len and buf[nl + 1] == '\r' and buf[nl + 2] == '\n') return .{ .head = nl, .next = nl + 3 };
        if (nl + 2 >= buf.len) break;
        i = nl + 1;
    }
    scan.* = if (buf.len > 2) buf.len - 2 else 0;
    return null;
}

fn parseHead(l: *Thread, s: *net.Socket, f: *Fetch, head: []const u8, next: usize, b: u32) Error!HeadResult {
    var lines = std.mem.splitScalar(u8, head, '\n');
    const first = std.mem.trimEnd(u8, lines.first(), "\r");
    const status = parseStatus(first) orelse return l.raiseFmt("invalid HTTP response: {s}", .{first[0..@min(first.len, 200)]});
    const headers = try l.newTable(0, 8);
    l.top = b + headers_slot;
    try l.push(Value.obj(.table, headers));
    var content_length: ?u64 = null;
    var chunked = false;
    var lower: std.ArrayList(u8) = .empty;
    defer lower.deinit(l.g.gpa);
    while (lines.next()) |raw| {
        const hl = std.mem.trimEnd(u8, raw, "\r");
        if (hl.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, hl, ':') orelse continue;
        lower.clearRetainingCapacity();
        lower.appendSlice(l.g.gpa, hl[0..colon]) catch return l.raiseMem();
        for (lower.items) |*ch| ch.* = std.ascii.toLower(ch.*);
        const key = lower.items;
        const val = std.mem.trimStart(u8, hl[colon + 1 ..], " ");
        try setHeader(l, headers, key, val);
        if (std.mem.eql(u8, key, "content-length")) {
            const len = parseContentLength(val) orelse return l.raiseFmt("invalid Content-Length", .{});
            if (!f.stream and len > fetch_max_body) return l.raiseFmt("invalid Content-Length", .{});
            content_length = len;
        } else if (std.mem.eql(u8, key, "transfer-encoding")) {
            if (hasChunked(val)) chunked = true;
        }
    }
    consume(s, next);
    f.status = status;
    // A response to HEAD, and a 1xx, 204 or 304 response, ends after its
    // headers, whatever Content-Length says (RFC 9112, section 6.3).
    if (f.head_method or status == 204 or status == 304 or (status >= 100 and status < 200)) return .{ .framing = .none, .len = 0 };
    if (chunked) return .{ .framing = .chunked, .len = 0 };
    if (content_length) |n| return .{ .framing = .length, .len = n };
    return .{ .framing = .eof, .len = 0 };
}

/// Whether a Transfer-Encoding value names chunked coding.
fn hasChunked(val: []const u8) bool {
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(trimSpaces(part), "chunked")) return true;
    }
    return false;
}

/// Reads the whole response body of `s` and returns it as a vector.
fn readWhole(l: *Thread, s: *net.Socket) Error!Value {
    const body = s.body.?;
    while (!body.done) {
        if (body.pending.items.len > fetch_max_body) return l.raiseFmt("response body too large", .{});
        try advance(l, s, body, 1 << 20, "fetch timeout");
    }
    if (body.pending.items.len > fetch_max_body) return l.raiseFmt("response body too large", .{});
    const v = try vector.newVectorFrom(l, &body.pending);
    body.pending = .empty;
    return Value.obj(.vector, v);
}
