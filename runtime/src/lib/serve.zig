//! `network.serve`: an HTTP/1.1 server with keep-alive.
//!
//! `serve` itself is a native that accepts connections in a loop. It waits
//! through the scheduler (`vm/sched.zig`), so it suspends inside a detached
//! coroutine and keeps its caller blocked anywhere else. Every connection
//! runs in a detached coroutine of its own, whose body is the small Lus
//! function in `connection_src`: it reads a request, calls the handler,
//! and writes the response, until the connection ends. Reading a request
//! and writing a response are natives that wait the same way. What they
//! have read or written so far lives in the socket, so a native that runs
//! again after a wait continues from there.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const pledge = @import("../vm/pledge.zig");
const sched = @import("../vm/sched.zig");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const net = @import("network.zig");
const coroutine = @import("coroutine.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

/// The request line and the headers of a request fit in 64 KiB.
const max_head = 64 * 1024;
/// A request carries at most 128 header lines.
const max_headers = 128;
/// A request body holds at most 16 MiB.
const max_body = 16 * 1024 * 1024;
const default_backlog = 128;
const connection_key = "network.serve.connection";

const Span = struct { off: u32 = 0, len: u32 = 0 };
const Header = struct { name: Span, val: Span };

/// The exchange in progress on a connection.
pub const Http = struct {
    /// Where the search for the end of the headers continues.
    scan: usize = 0,
    /// The length of the request line and the headers, once they are
    /// complete.
    head_end: usize = 0,
    method: Span = .{},
    path: Span = .{},
    query: Span = .{},
    headers: std.ArrayList(Header) = .empty,
    framing: enum { none, length, chunked } = .none,
    length: usize = 0,
    /// Where the next chunk of a chunked body starts.
    cpos: usize = 0,
    /// The body of a chunked request, decoded so far.
    body: std.ArrayList(u8) = .empty,
    keep: bool = true,
    head: bool = false,
    /// The response being written and how much of it was sent.
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    /// The Date header text and the second it was formatted for.
    date_sec: i64 = 0,
    date: [29]u8 = undefined,

    pub fn deinit(h: *Http, gpa: std.mem.Allocator) void {
        h.headers.deinit(gpa);
        h.body.deinit(gpa);
        h.out.deinit(gpa);
    }

    fn nextRequest(h: *Http) void {
        h.scan = 0;
        h.head_end = 0;
        h.headers.clearRetainingCapacity();
        h.framing = .none;
        h.length = 0;
        h.cpos = 0;
        h.body.clearRetainingCapacity();
    }
};

fn httpOf(l: *Thread, s: *net.Socket) Error!*Http {
    if (s.http) |h| return h;
    const h = l.g.gpa.create(Http) catch return l.raiseMem();
    h.* = .{};
    s.http = h;
    return h;
}

// ---------------------------------------------------------------------
// network.serve

const connection_src =
    \\local readrequest, respond = ...
    \\local tostring = tostring
    \\local warn = warn or function() end
    \\local function exchange(conn, handler)
    \\    while true do
    \\        local req, keep, head = readrequest(conn)
    \\        if not req then
    \\            if keep then respond(conn, keep, nil, nil, false, false) end
    \\            return
    \\        end
    \\        local ok, status, body, headers = catch handler(req)
    \\        if not ok then
    \\            warn("network.serve: ", tostring(status))
    \\            respond(conn, 500, nil, nil, false, false)
    \\            return
    \\        end
    \\        local valid, alive = catch respond(conn, status, body, headers, keep, head)
    \\        if not valid then
    \\            warn("network.serve: ", tostring(alive))
    \\            respond(conn, 500, nil, nil, false, false)
    \\            return
    \\        end
    \\        if not (alive and keep) then return end
    \\    end
    \\end
    \\return function(sock, handler)
    \\    local conn <close> = sock
    \\    local ok, err = catch exchange(conn, handler)
    \\    if not ok then warn("network.serve: ", tostring(err)) end
    \\end
;

/// The function every connection coroutine runs, compiled on first use.
fn connectionFn(l: *Thread) Error!Value {
    const g = l.g;
    if (g.ext.get(connection_key)) |p| return Value.obj(.closure, @as(*object.Closure, @ptrCast(@alignCast(p))));
    const top = l.top;
    defer l.top = top;
    api.load(l, connection_src, "=network.serve") catch return l.raise(l.err);
    const chunk = l.stack[l.top - 1];
    const read = try aux.native(l, readRequest, "readrequest");
    try l.push(read);
    const write = try aux.native(l, respond, "respond");
    try l.push(write);
    const f = try ops.call1(l, chunk, &.{ read, write });
    try l.push(f);
    try aux.setField(l, g.registry.as(Table), connection_key, f);
    g.ext.put(g.gpa, connection_key, f.as(object.Closure)) catch return l.raiseMem();
    return f;
}

/// network.serve(host, port, handler), or network.serve(server, handler)
/// with a server from `network.tcp.bind`.
pub fn serve(l: *Thread) Error!u32 {
    if (!sched.restarted(l)) try setup(l);
    // The arguments are now the server, the handler, and whether `serve`
    // bound the server itself.
    const base = l.base();
    const s = net.toObject(l, net.Server, net.server_name, l.stack[base]).?;
    const owned = l.stack[base + 2].tag == .true;
    if (owned) {
        // A server that `serve` bound closes when `serve` ends, also when
        // its coroutine is closed while it waits.
        const t = try sched.ensureTask(l);
        t.ctx = s;
        t.cancel = closeOwned;
    }
    return acceptLoop(l, s) catch |e| {
        // A suspension keeps the server open.
        if (!l.yielding and owned) {
            if (sched.taskOf(l)) |t| {
                t.ctx = null;
                t.cancel = null;
            }
            net.closeServer(l, s);
        }
        return e;
    };
}

fn closeOwned(g: *state.Global, ctx: *anyopaque) void {
    net.closeServerIn(g, @ptrCast(@alignCast(ctx)));
}

fn setup(l: *Thread) Error!void {
    var hp: [512]u8 = undefined;
    var handler: Value = undefined;
    var server: Value = undefined;
    var owned = false;
    // The connection function compiles before anything is bound.
    _ = try connectionFn(l);
    if (net.toObject(l, net.Server, net.server_name, l.arg(1))) |_| {
        const s = try net.checkServer(l, 1);
        handler = try aux.checkFunction(l, 2);
        var ip: [64]u8 = undefined;
        const a = s.server.socket.address;
        try pledge.require(l, "network:server", net.hostPort(&hp, net.formatIp(&ip, a), a.getPort()));
        server = l.arg(1);
    } else {
        const host = try aux.checkBytes(l, 1);
        const port = try net.checkPort(l, 2, true);
        handler = try aux.checkFunction(l, 3);
        try pledge.require(l, "network:server", net.hostPort(&hp, host, port));
        _ = try net.bindServer(l, host, port, default_backlog);
        server = l.stack[l.top - 1];
        owned = true;
    }
    const base = l.base();
    try l.ensure(4);
    l.stack[base] = server;
    l.stack[base + 1] = handler;
    l.stack[base + 2] = Value.boolean(owned);
    l.top = base + 3;
}

fn acceptLoop(l: *Thread, s: *net.Server) Error!u32 {
    const g = l.g;
    const base = l.base();
    while (true) {
        if (s.closed) return l.raiseFmt("attempt to use a closed server", .{});
        _ = net.acceptOne(l, s) catch |e| switch (e) {
            error.LusError, error.MetaCall => |x| return x,
            error.ConnectionAborted => continue,
            else => return l.raiseFmt("accept: {s}", .{net.errText(e)}),
        };
        // The socket is on the stack. Its connection gets a coroutine.
        const sock = l.stack[l.top - 1];
        const co = try coroutine.newCoroutine(l, try connectionFn(l));
        try l.push(Value.obj(.thread, co));
        try co.ensure(3);
        co.stack[1] = sock;
        co.stack[2] = l.stack[base + 1];
        co.top = 3;
        const t = try sched.ensureTask(co);
        sched.attach(g, t, .fresh, 2);
        l.top = base + 3;
        // The connections that are ready run before the next accept.
        try sched.pass(l);
    }
}

// ---------------------------------------------------------------------
// Reading a request

const Parse = union(enum) {
    /// The request needs more bytes. The value is how many to ask for.
    more: usize,
    done,
    /// The request is refused with this status.
    bad: u16,
};

fn isToken(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn span(off: usize, len: usize) Span {
    return .{ .off = @intCast(off), .len = @intCast(len) };
}

fn text(buf: []const u8, s: Span) []const u8 {
    return buf[s.off..][0..s.len];
}

fn headerValue(h: *const Http, buf: []const u8, comptime name: []const u8) ?[]const u8 {
    for (h.headers.items) |hd| {
        if (std.ascii.eqlIgnoreCase(text(buf, hd.name), name)) return text(buf, hd.val);
    }
    return null;
}

fn hasToken(list: []const u8, comptime token: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

/// Parses the request line and the headers in `buf[0..end]`. Returns the
/// status that refuses the request, or zero.
fn parseHead(l: *Thread, h: *Http, buf: []const u8, end: usize) Error!u16 {
    const gpa = l.g.gpa;
    const line_end = std.mem.indexOf(u8, buf[0..end], "\r\n").?;
    const line = buf[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return 400;
    const sp2 = std.mem.lastIndexOfScalar(u8, line, ' ').?;
    if (sp2 == sp1) return 400;
    const method = line[0..sp1];
    if (method.len == 0 or method.len > 32) return 400;
    for (method) |c| if (!isToken(c)) return 400;
    const target = line[sp1 + 1 .. sp2];
    if (target.len == 0) return 400;
    for (target) |c| if (c <= ' ' or c == 0x7f) return 400;
    if (!wtf8.analyze(target).valid) return 400;
    const version = line[sp2 + 1 ..];
    var http10 = false;
    if (std.mem.eql(u8, version, "HTTP/1.0")) {
        http10 = true;
    } else if (!std.mem.eql(u8, version, "HTTP/1.1")) {
        return if (std.mem.startsWith(u8, version, "HTTP/")) 505 else 400;
    }
    h.method = span(0, sp1);
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path_len = q orelse target.len;
    h.path = span(sp1 + 1, path_len);
    h.query = if (q) |i| span(sp1 + 1 + i + 1, target.len - i - 1) else .{};
    h.head = std.mem.eql(u8, method, "HEAD");

    var pos = line_end + 2;
    while (pos < end - 2) {
        const eol = std.mem.indexOfPos(u8, buf[0..end], pos, "\r\n").?;
        const hl = buf[pos..eol];
        const colon = std.mem.indexOfScalar(u8, hl, ':') orelse return 400;
        if (colon == 0 or colon > 256) return 400;
        for (hl[0..colon]) |c| if (!isToken(c)) return 400;
        const val = std.mem.trim(u8, hl[colon + 1 ..], " \t");
        for (val) |c| if (c == 0 or c == '\r' or c == '\n') return 400;
        if (!wtf8.analyze(val).valid) return 400;
        if (h.headers.items.len == max_headers) return 431;
        const voff = @intFromPtr(val.ptr) - @intFromPtr(buf.ptr);
        h.headers.append(gpa, .{ .name = span(pos, colon), .val = span(voff, val.len) }) catch return l.raiseMem();
        pos = eol + 2;
    }

    const conn = headerValue(h, buf, "connection") orelse "";
    h.keep = if (http10) hasToken(conn, "keep-alive") else !hasToken(conn, "close");
    h.framing = .none;
    h.length = 0;
    var seen_length = false;
    for (h.headers.items) |hd| {
        const name = text(buf, hd.name);
        const val = text(buf, hd.val);
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (h.framing == .chunked or seen_length) return 400;
            if (!std.ascii.eqlIgnoreCase(val, "chunked")) return 501;
            h.framing = .chunked;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (h.framing == .chunked or val.len == 0) return 400;
            for (val) |c| if (!std.ascii.isDigit(c)) return 400;
            const n = std.fmt.parseInt(usize, val, 10) catch return 413;
            if (seen_length and n != h.length) return 400;
            if (n > max_body) return 413;
            seen_length = true;
            h.length = n;
            h.framing = .length;
        }
    }
    return 0;
}

/// Decodes the chunks of a chunked body that the buffer holds in full.
fn parseChunks(l: *Thread, h: *Http, buf: []const u8) Error!Parse {
    const gpa = l.g.gpa;
    while (true) {
        const eol = std.mem.indexOfPos(u8, buf, h.cpos, "\r\n") orelse {
            if (buf.len - h.cpos > 1024) return .{ .bad = 400 };
            return .{ .more = 4096 };
        };
        var digits = buf[h.cpos..eol];
        if (std.mem.indexOfScalar(u8, digits, ';')) |semi| digits = digits[0..semi];
        digits = std.mem.trim(u8, digits, " \t");
        if (digits.len == 0 or digits.len > 16) return .{ .bad = 400 };
        const size = std.fmt.parseInt(usize, digits, 16) catch return .{ .bad = 400 };
        const data = eol + 2;
        if (size == 0) {
            // Trailer lines follow the last chunk, up to an empty line.
            var pos = data;
            while (true) {
                const tl = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse {
                    if (buf.len - data > max_head) return .{ .bad = 431 };
                    return .{ .more = 4096 };
                };
                if (tl == pos) {
                    h.cpos = pos + 2;
                    return .done;
                }
                pos = tl + 2;
            }
        }
        if (size > max_body or h.body.items.len + size > max_body) return .{ .bad = 413 };
        if (buf.len < data + size + 2) return .{ .more = @min(data + size + 2 - buf.len, 65536) };
        if (buf[data + size] != '\r' or buf[data + size + 1] != '\n') return .{ .bad = 400 };
        h.body.appendSlice(gpa, buf[data..][0..size]) catch return l.raiseMem();
        h.cpos = data + size + 2;
    }
}

fn parse(l: *Thread, s: *net.Socket, h: *Http) Error!Parse {
    if (h.head_end == 0) {
        // Empty lines before a request line are skipped.
        var skip: usize = 0;
        while (s.buf.items.len >= skip + 2 and s.buf.items[skip] == '\r' and s.buf.items[skip + 1] == '\n') skip += 2;
        if (skip > 0) {
            consume(s, skip);
            h.scan = 0;
        }
        const buf = s.buf.items;
        const from = if (h.scan > 3) h.scan - 3 else 0;
        const at = std.mem.indexOfPos(u8, buf, from, "\r\n\r\n") orelse {
            if (buf.len > max_head) return .{ .bad = 431 };
            h.scan = buf.len;
            return .{ .more = 16384 };
        };
        const end = at + 4;
        if (end > max_head) return .{ .bad = 431 };
        const status = try parseHead(l, h, buf, end);
        if (status != 0) return .{ .bad = status };
        h.head_end = end;
        h.cpos = end;
        if (h.framing != .none) {
            if (headerValue(h, buf, "expect")) |e| {
                if (!std.ascii.eqlIgnoreCase(e, "100-continue")) return .{ .bad = 417 };
                // The client waits for this line before it sends the body.
                if (buf.len == end) _ = net.trySend(l, s, "HTTP/1.1 100 Continue\r\n\r\n");
            }
        }
    }
    const buf = s.buf.items;
    switch (h.framing) {
        .none => return .done,
        .length => {
            const need = h.head_end + h.length;
            if (buf.len < need) return .{ .more = @min(need - buf.len, 65536) };
            h.cpos = need;
            return .done;
        },
        .chunked => return parseChunks(l, h, buf),
    }
}

fn consume(s: *net.Socket, n: usize) void {
    const rest = s.buf.items.len - n;
    std.mem.copyForwards(u8, s.buf.items[0..rest], s.buf.items[n..]);
    s.buf.items.len = rest;
}

/// readrequest(sock): reads the next request of a connection. Returns the
/// request table, whether the connection stays open afterwards, and
/// whether the request is a HEAD. Returns nil when the peer closed the
/// connection, and nil with a status when the request is refused.
fn readRequest(l: *Thread) Error!u32 {
    const s = try net.checkSocket(l, 1);
    const h = try httpOf(l, s);
    while (true) {
        switch (try parse(l, s, h)) {
            .more => |n| switch (try net.fill(l, s, n)) {
                .got => {},
                .eof, .fail => {
                    h.nextRequest();
                    return aux.retNil(l);
                },
            },
            .bad => |status| {
                h.nextRequest();
                try l.push(.nil);
                try l.push(Value.int(status));
                return 2;
            },
            .done => return finishRequest(l, s, h),
        }
    }
}

fn finishRequest(l: *Thread, s: *net.Socket, h: *Http) Error!u32 {
    const gpa = l.g.gpa;
    const buf = s.buf.items;
    const req = try l.newTable(0, 5);
    const slot = l.top;
    try l.push(Value.obj(.table, req));
    try aux.setField(l, req, "method", try l.newStringValue(text(buf, h.method)));
    try aux.setField(l, req, "path", try l.newStringValue(text(buf, h.path)));
    try aux.setField(l, req, "query", try l.newStringValue(text(buf, h.query)));
    const headers = try l.newTable(0, h.headers.items.len);
    try aux.setField(l, req, "headers", Value.obj(.table, headers));
    var lower: [256]u8 = undefined;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (h.headers.items) |hd| {
        const name = std.ascii.lowerString(&lower, text(buf, hd.name));
        const key = try l.newString(name);
        try l.push(Value.obj(.string, key));
        defer l.top -= 1;
        const val = text(buf, hd.val);
        const old = table.getStr(headers, key);
        if (old.tag == .string) {
            // A header that repeats joins its values with a comma.
            joined.clearRetainingCapacity();
            joined.appendSlice(gpa, old.as(object.String).bytes()) catch return l.raiseMem();
            joined.appendSlice(gpa, ", ") catch return l.raiseMem();
            joined.appendSlice(gpa, val) catch return l.raiseMem();
            try ops.rawSet(l, headers, Value.obj(.string, key), try l.newStringValue(joined.items));
        } else {
            try ops.rawSet(l, headers, Value.obj(.string, key), try l.newStringValue(val));
        }
    }
    const body = switch (h.framing) {
        .none => try vector.newVector(l, &.{}),
        .length => try vector.newVector(l, buf[h.head_end..][0..h.length]),
        .chunked => try vector.newVectorFrom(l, &h.body),
    };
    try aux.setField(l, req, "body", Value.obj(.vector, body));
    const keep = h.keep;
    const head = h.head;
    consume(s, h.cpos);
    h.nextRequest();
    l.top = slot + 1;
    try l.push(Value.boolean(keep));
    try l.push(Value.boolean(head));
    return 3;
}

// ---------------------------------------------------------------------
// Writing a response

fn reason(status: i64) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        else => switch (@divTrunc(status, 100)) {
            1 => "Informational",
            2 => "Success",
            3 => "Redirection",
            4 => "Client Error",
            else => "Server Error",
        },
    };
}

/// The value of the Date header. A connection formats it once per
/// second and keeps the text itself. A thread-local cache with an initial
/// value would put initialized data into the thread-local image of the
/// program, which every new worker thread then copies in full.
fn dateText(h: *Http, io: std.Io) []const u8 {
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (now == h.date_sec and now != 0) return &h.date;
    const days = "SunMonTueWedThuFriSat";
    const months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now, 0)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const wd: usize = @intCast((day.day + 4) % 7);
    const mi: usize = md.month.numeric() - 1;
    _ = std.fmt.bufPrint(&h.date, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[wd * 3 ..][0..3], md.day_index + 1,        months[mi * 3 ..][0..3],   yd.year,
        ds.getHoursIntoDay(),  ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch return "Thu, 01 Jan 1970 00:00:00 GMT";
    h.date_sec = now;
    return &h.date;
}

fn checkHeaderText(l: *Thread, s: []const u8, comptime what: []const u8) Error!void {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == 0) return l.raiseFmt("handler returned an invalid header " ++ what, .{});
    }
}

/// Formats the response into `h.out`. The handler returned `status`,
/// `body`, and `headers` in the arguments 2 to 4.
fn buildResponse(l: *Thread, h: *Http, keep: bool, head: bool) Error!void {
    const gpa = l.g.gpa;
    const out = &h.out;
    out.clearRetainingCapacity();
    h.out_off = 0;
    errdefer out.clearRetainingCapacity();

    var status: i64 = 200;
    if (!l.arg(2).isNil()) {
        if (l.arg(2).tag != .integer) return l.raiseFmt("handler returned an invalid status (integer expected, got {s})", .{l.typeNameOf(l.arg(2))});
        status = l.arg(2).asInt();
        if (status < 100 or status > 999) return l.raiseFmt("handler returned an invalid status ({d})", .{status});
    }
    var body: []const u8 = "";
    switch (l.arg(3).tag) {
        .nil => {},
        .string => body = l.arg(3).as(object.String).bytes(),
        .vector => body = l.arg(3).as(object.Vector).bytes.items,
        else => return l.raiseFmt("handler returned an invalid body (string or vector expected, got {s})", .{l.typeNameOf(l.arg(3))}),
    }
    const bodiless = status < 200 or status == 204 or status == 304;

    out.print(gpa, "HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) }) catch return l.raiseMem();
    var has_length = false;
    var has_date = false;
    var has_connection = false;
    if (!l.arg(4).isNil()) {
        if (l.arg(4).tag != .table) return l.raiseFmt("handler returned invalid headers (table expected, got {s})", .{l.typeNameOf(l.arg(4))});
        const t = l.arg(4).as(Table);
        var key: Value = .nil;
        while (table.next(t, key) catch return l.raiseFmt("handler returned invalid headers", .{})) |e| : (key = e.key) {
            if (e.key.tag != .string) return l.raiseFmt("handler returned an invalid header name ({s})", .{l.typeNameOf(e.key)});
            const name = e.key.as(object.String).bytes();
            if (name.len == 0) return l.raiseFmt("handler returned an invalid header name", .{});
            for (name) |c| if (!isToken(c)) return l.raiseFmt("handler returned an invalid header name", .{});
            var num: [64]u8 = undefined;
            const val: []const u8 = switch (e.val.tag) {
                .string => e.val.as(object.String).bytes(),
                .integer => std.fmt.bufPrint(&num, "{d}", .{e.val.asInt()}) catch unreachable,
                else => return l.raiseFmt("handler returned an invalid value for the header '{s}' (string expected, got {s})", .{ name, l.typeNameOf(e.val) }),
            };
            try checkHeaderText(l, val, "value");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) has_length = true;
            if (std.ascii.eqlIgnoreCase(name, "date")) has_date = true;
            if (std.ascii.eqlIgnoreCase(name, "connection")) has_connection = true;
            out.print(gpa, "{s}: {s}\r\n", .{ name, val }) catch return l.raiseMem();
        }
    }
    if (!has_date) out.print(gpa, "Date: {s}\r\n", .{dateText(h, l.g.io)}) catch return l.raiseMem();
    if (!has_length and !bodiless) out.print(gpa, "Content-Length: {d}\r\n", .{body.len}) catch return l.raiseMem();
    if (!keep and !has_connection) out.appendSlice(gpa, "Connection: close\r\n") catch return l.raiseMem();
    out.appendSlice(gpa, "\r\n") catch return l.raiseMem();
    if (!head and !bodiless) out.appendSlice(gpa, body) catch return l.raiseMem();
}

/// respond(sock, status, body, headers, keep, head): writes a response.
/// Returns true when all of it was sent. Raises when the handler returned
/// values that make no response, before it writes anything.
fn respond(l: *Thread) Error!u32 {
    const s = try net.checkSocket(l, 1);
    const h = try httpOf(l, s);
    // A response that waited continues after the bytes it already sent.
    if (!sched.restarted(l) or h.out.items.len == 0) {
        try buildResponse(l, h, l.arg(5).tag == .true, l.arg(6).tag == .true);
    }
    const handle = s.stream.socket.handle;
    var sent = true;
    while (h.out_off < h.out.items.len) {
        const rest = h.out.items[h.out_off..];
        switch (net.trySend(l, s, rest)) {
            .n => |n| {
                h.out_off += n;
                sched.opDone(l);
            },
            .again => {
                try net.awaitIo(l, handle, .write, s.timeout_ms, "send");
                try net.stillOpen(l, s);
            },
            .fail => {
                sent = false;
                break;
            },
        }
    }
    h.out_off = 0;
    if (h.out.capacity > 256 * 1024) h.out.clearAndFree(l.g.gpa) else h.out.clearRetainingCapacity();
    return aux.retBool(l, sent);
}
