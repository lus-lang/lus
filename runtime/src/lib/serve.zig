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
const gc = @import("../vm/gc.zig");
const wtf8 = @import("../vm/wtf8.zig");
const pledge = @import("../vm/pledge.zig");
const sched = @import("../vm/sched.zig");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const net = @import("network.zig");
const coroutine = @import("coroutine.zig");
const http = @import("http.zig");
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
/// The line that starts a chunk, with its size and its extensions, fits
/// in 1 KiB.
const max_chunk_line = 1024;
/// The framing of a chunked body is its chunk lines, the line ends after
/// the chunks, and its trailers. A body may spend 64 KiB on it, and 8
/// bytes more for every byte it carries.
const max_framing = max_head;
const framing_per_byte = 8;
const default_backlog = 128;
/// A connection that makes no progress for a minute closes, unless the
/// options of `serve` say otherwise.
const default_idle_ms = 60 * 1000;
/// The upper end of the default for `max_connections`.
const default_max_connections = 65536;
/// How long `serve` waits before it accepts again after the system ran
/// out of descriptors or memory.
const accept_retry_ms = 100;
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
    length: u64 = 0,
    keep: bool = true,
    head: bool = false,
    /// The request is HTTP/1.0, whose clients know no chunked responses.
    http10: bool = false,
    /// A response that the handler streams sends its chunks with chunked
    /// transfer coding, or as they are when the handler set a
    /// `Content-Length`, and then the connection closes.
    stream_raw: bool = false,
    /// The response says the connection closes after it.
    close_after: bool = false,
    /// The response being written and how much of it was sent.
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    /// The Date header text and the second it was formatted for.
    date_sec: i64 = 0,
    date: [29]u8 = undefined,

    pub fn deinit(h: *Http, gpa: std.mem.Allocator) void {
        h.headers.deinit(gpa);
        h.out.deinit(gpa);
    }

    fn nextRequest(h: *Http) void {
        h.scan = 0;
        h.head_end = 0;
        h.headers.clearRetainingCapacity();
        h.framing = .none;
        h.length = 0;
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
    \\local readrequest, respond, stderr, writechunk, refusal, readbody = ...
    \\-- Request tables read their whole body on the first use of `body`.
    \\local request_mt = {
    \\    __index = function(req, key)
    \\        if key == "body" then return readbody(req) end
    \\    end,
    \\}
    \\local function report(on_error, err)
    \\    if on_error then
    \\        local ok, failure = catch on_error(err)
    \\        if ok then return end
    \\        stderr(failure)
    \\    end
    \\    stderr(err)
    \\end
    \\local function exchange(conn, handler, on_error)
    \\    while true do
    \\        local req, keep, head = readrequest(conn, request_mt)
    \\        if not req then
    \\            if keep then respond(conn, keep, nil, nil, false, false) end
    \\            return
    \\        end
    \\        local ok, status, body, headers = catch handler(req)
    \\        if not ok then
    \\            -- A request body that broke its framing or its limit while
    \\            -- the handler read it is refused with its own status.
    \\            local refused = refusal(conn)
    \\            if refused then
    \\                respond(conn, refused, nil, nil, false, false)
    \\                return
    \\            end
    \\            report(on_error, status)
    \\            respond(conn, 500, nil, nil, false, false)
    \\            return
    \\        end
    \\        if status == 101 then
    \\            -- An upgrade hands the connection to the function the handler
    \\            -- returned once the 101 response is out, and the connection
    \\            -- ends with that function.
    \\            local valid, alive = catch respond(conn, status, body, headers, true, false, req.headers["sec-websocket-key"])
    \\            if not valid then
    \\                report(on_error, alive)
    \\                respond(conn, 500, nil, nil, false, false)
    \\                return
    \\            end
    \\            if alive then
    \\                local ran, err = catch body(conn)
    \\                if not ran then report(on_error, err) end
    \\            end
    \\            return
    \\        end
    \\        if type(body) == "function" then
    \\            -- A streamed response: the head goes out, then every chunk
    \\            -- that the generator returns, as it returns it, until nil.
    \\            local valid, alive, follow = catch respond(conn, status, nil, headers, keep, head, nil, true)
    \\            if not valid then
    \\                report(on_error, alive)
    \\                respond(conn, 500, nil, nil, false, false)
    \\                return
    \\            end
    \\            if not alive then return end
    \\            if follow then
    \\                while true do
    \\                    local produced, chunk = catch body()
    \\                    if not produced then
    \\                        report(on_error, chunk)
    \\                        return
    \\                    end
    \\                    local wrote, open = catch writechunk(conn, chunk)
    \\                    if not wrote then
    \\                        report(on_error, open)
    \\                        return
    \\                    end
    \\                    if not open then return end
    \\                    if chunk == nil then break end
    \\                end
    \\            end
    \\            if not keep then return end
    \\        else
    \\            local valid, alive = catch respond(conn, status, body, headers, keep, head)
    \\            if not valid then
    \\                report(on_error, alive)
    \\                respond(conn, 500, nil, nil, false, false)
    \\                return
    \\            end
    \\            if not (alive and keep) then return end
    \\        end
    \\    end
    \\end
    \\return function(sock, handler, on_error)
    \\    local conn <close> = sock
    \\    local ok, err = catch exchange(conn, handler, on_error)
    \\    if not ok then report(on_error, err) end
    \\end
;

/// stderr(err): writes an error of a handler to standard error, in the
/// form that `lus` gives the error that ends a program.
fn reportError(l: *Thread) Error!u32 {
    const g = l.g;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g.gpa);
    buf.print(g.gpa, "lus: network.serve: {s}\n", .{api.errorMessage(l, l.arg(1))}) catch return l.raiseMem();
    @import("out.zig").stderr(g, buf.items);
    return 0;
}

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
    const report = try aux.native(l, reportError, "stderr");
    try l.push(report);
    const chunk_fn = try aux.native(l, writeChunk, "writechunk");
    try l.push(chunk_fn);
    const refused = try aux.native(l, refusal, "refusal");
    try l.push(refused);
    const body_fn = try aux.native(l, readBody, "readbody");
    try l.push(body_fn);
    const f = try ops.call1(l, chunk, &.{ read, write, report, chunk_fn, refused, body_fn });
    try l.push(f);
    try aux.setField(l, g.registry.as(Table), connection_key, f);
    g.ext.put(g.gpa, connection_key, f.as(object.Closure)) catch return l.raiseMem();
    return f;
}

/// network.serve(host, port, handler, options), or network.serve(server,
/// handler, options) with a server from `network.tcp.bind`.
pub fn serve(l: *Thread) Error!u32 {
    if (!sched.restarted(l)) try setup(l);
    // The arguments are now the server, the handler, whether `serve`
    // bound the server itself, and the `on_error` function or nil.
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

/// What the options table of `serve` holds.
const Options = struct {
    idle_ms: i32 = default_idle_ms,
    max_connections: u32,
    on_error: Value = .nil,
    tls: Value = .nil,
};

/// Half of the descriptors the process may open, so that a server at its
/// limit leaves the other half to the handlers and the rest of the
/// program.
fn defaultMaxConnections() u32 {
    if (comptime @import("builtin").os.tag == .windows) return 8192;
    const limit = std.posix.getrlimit(.NOFILE) catch return 512;
    return @intCast(std.math.clamp(@divTrunc(limit.cur, 2), 16, default_max_connections));
}

/// Reads the options table in argument `i`, when there is one.
fn readOptions(l: *Thread, i: u32) Error!Options {
    var o: Options = .{ .max_connections = defaultMaxConnections() };
    if (!l.hasArg(i) or l.arg(i).isNil()) return o;
    const t = try aux.checkTable(l, i);
    var key: Value = .nil;
    while (table.next(t, key) catch null) |e| : (key = e.key) {
        const name = if (e.key.tag == .string) e.key.as(object.String).bytes() else "";
        if (std.mem.eql(u8, name, "idle_timeout")) {
            const secs: f64 = switch (e.val.tag) {
                .integer => @floatFromInt(e.val.asInt()),
                .float => e.val.asFloat(),
                else => return aux.argError(l, i, "idle_timeout must be a number of seconds", .{}),
            };
            if (std.math.isNan(secs) or secs == 0) return aux.argError(l, i, "idle_timeout must be positive, or negative for no timeout", .{});
            const ms = @ceil(secs * 1000);
            o.idle_ms = if (secs < 0) -1 else if (ms >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(ms);
        } else if (std.mem.eql(u8, name, "max_connections")) {
            if (e.val.tag != .integer or e.val.asInt() < 1) return aux.argError(l, i, "max_connections must be a positive integer", .{});
            o.max_connections = @intCast(@min(e.val.asInt(), std.math.maxInt(u32)));
        } else if (std.mem.eql(u8, name, "on_error")) {
            if (e.val.tag != .closure and e.val.tag != .native) return aux.argError(l, i, "on_error must be a function", .{});
            o.on_error = e.val;
        } else if (std.mem.eql(u8, name, "tls")) {
            o.tls = e.val;
        } else {
            return aux.argError(l, i, "unknown option '{s}'", .{api.errorMessage(l, e.key)});
        }
    }
    return o;
}

fn setup(l: *Thread) Error!void {
    var hp: [512]u8 = undefined;
    var handler: Value = undefined;
    var server: Value = undefined;
    var owned = false;
    var options: Options = undefined;
    var options_arg: u32 = 3;
    // The connection function compiles before anything is bound.
    _ = try connectionFn(l);
    if (net.toObject(l, net.Server, net.server_name, l.arg(1))) |_| {
        const s = try net.checkServer(l, 1);
        handler = try aux.checkFunction(l, 2);
        options = try readOptions(l, 3);
        var ip: [64]u8 = undefined;
        const a = s.server.socket.address;
        try pledge.require(l, "network:server", net.hostPort(&hp, net.formatIp(&ip, a), a.getPort()));
        server = l.arg(1);
    } else {
        const host = try aux.checkBytes(l, 1);
        const port = try net.checkPort(l, 2, true);
        handler = try aux.checkFunction(l, 3);
        options = try readOptions(l, 4);
        options_arg = 4;
        try pledge.require(l, "network:server", net.hostPort(&hp, host, port));
        _ = try net.bindServer(l, host, port, default_backlog);
        server = l.stack[l.top - 1];
        owned = true;
    }
    const s = net.toObject(l, net.Server, net.server_name, server).?;
    if (!options.tls.isNil()) {
        // The certificates load before the first connection, so a bad
        // certificate fails the call.
        const cfg = net.tls.serverConfig(l, options_arg, options.tls) catch |e| {
            if (owned) net.closeServer(l, s);
            return e;
        };
        if (s.tls_config) |old| net.tls.freeConfig(old);
        s.tls_config = cfg;
    }
    s.idle_ms = options.idle_ms;
    s.max_live = options.max_connections;
    const base = l.base();
    try l.ensure(5);
    l.stack[base] = server;
    l.stack[base + 1] = handler;
    l.stack[base + 2] = Value.boolean(owned);
    l.stack[base + 3] = options.on_error;
    l.top = base + 4;
}

fn acceptLoop(l: *Thread, s: *net.Server) Error!u32 {
    const g = l.g;
    const base = l.base();
    while (true) {
        if (s.closed) return l.raiseFmt("attempt to use a closed server", .{});
        if (s.live >= s.max_live) {
            // The next connection stays in the queue of the system until
            // one of the open ones closes.
            s.full = true;
            try sched.waitNotify(l);
            continue;
        }
        const sock = net.acceptOne(l, s) catch |e| switch (e) {
            error.LusError, error.MetaCall => |x| return x,
            error.ConnectionAborted => continue,
            // The system has no descriptor or no memory for the
            // connection now. It may have one once a connection closes,
            // and after a moment in any case.
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                s.full = true;
                try sched.waitNotifyFor(l, accept_retry_ms);
                continue;
            },
            else => return l.raiseFmt("accept: {s}", .{net.errText(e)}),
        };
        sock.owner = s;
        s.live += 1;
        sock.timeout_ms = s.idle_ms;
        // The handshake runs inside the first read of the connection.
        if (s.tls_config) |cfg| try net.tls.attach(l, sock, cfg, null);
        // The socket is on the stack. Its connection gets a coroutine.
        const co = try coroutine.newCoroutine(l, try connectionFn(l));
        try l.push(Value.obj(.thread, co));
        // Growing the coroutine and giving it a task raise on the
        // coroutine, so their errors move to this thread.
        co.ensure(4) catch return l.raise(co.err);
        co.stack[1] = l.stack[l.top - 2];
        co.stack[2] = l.stack[base + 1];
        co.stack[3] = l.stack[base + 3];
        co.top = 4;
        const t = sched.ensureTask(co) catch return l.raise(co.err);
        sched.attach(g, t, .fresh, 3);
        l.top = base + 4;
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
    h.http10 = http10;

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
            const n = std.fmt.parseInt(u64, val, 10) catch return 413;
            if (seen_length and n != h.length) return 400;
            seen_length = true;
            h.length = n;
            h.framing = .length;
        }
    }
    return 0;
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
        if (h.framing != .none) {
            if (headerValue(h, buf, "expect")) |e| {
                if (!std.ascii.eqlIgnoreCase(e, "100-continue")) return .{ .bad = 417 };
            }
        }
    }
    // The body stays in the socket, for the handler to read.
    return .done;
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
    // What the handler left of the last request body goes first.
    if (h.head_end == 0 and !try http.drainRequest(l, s, max_body)) return aux.retNil(l);
    while (true) {
        switch (try parse(l, s, h)) {
            .more => |n| {
                const got = (try net.tryFill(l, s, n)) orelse {
                    // The connection made no progress for the idle
                    // timeout. One that waits between two requests closes
                    // quietly, and one that stopped inside a request
                    // learns why.
                    const idle = h.head_end == 0 and s.buf.items.len == 0;
                    h.nextRequest();
                    try l.push(.nil);
                    if (idle) return 1;
                    try l.push(Value.int(408));
                    return 2;
                };
                switch (got) {
                    .got => {},
                    .eof, .fail => {
                        h.nextRequest();
                        return aux.retNil(l);
                    },
                }
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
    // The body is read when the handler reads it: through `req.reader`, or
    // whole through `req.body`, which the metatable of the request reads
    // on first use.
    const expect = h.framing != .none and headerValue(h, buf, "expect") != null;
    const framing: http.Framing = switch (h.framing) {
        .none => .none,
        .length => .length,
        .chunked => .chunked,
    };
    const length = h.length;
    const keep = h.keep;
    const head = h.head;
    consume(s, h.head_end);
    h.nextRequest();
    const body = try http.startBody(l, s, framing, length, true);
    body.expect_continue = expect and !body.done;
    _ = try http.pushReader(l, s, l.base(), false);
    try aux.setField(l, req, "reader", l.stack[l.top - 1]);
    l.top -= 1;
    if (l.arg(2).tag == .table) {
        req.metatable = l.arg(2).as(Table);
        gc.barrierBack(l.g, &req.hdr);
    }
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

/// The `Sec-WebSocket-Accept` value for the `Sec-WebSocket-Key` of a
/// request: the SHA-1 digest of the key and the fixed GUID of RFC 6455, in
/// base64.
pub fn websocketAccept(key: []const u8, out: *[28]u8) void {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(std.mem.trim(u8, key, " \t"));
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

test "the accept value of the RFC 6455 example key" {
    var out: [28]u8 = undefined;
    websocketAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

/// Writes the header line `name: v`. The value is a string or an integer.
fn writeHeader(l: *Thread, out: *std.ArrayList(u8), name: []const u8, v: Value) Error!void {
    var num: [64]u8 = undefined;
    const val: []const u8 = switch (v.tag) {
        .string => v.as(object.String).bytes(),
        .integer => std.fmt.bufPrint(&num, "{d}", .{v.asInt()}) catch unreachable,
        else => return l.raiseFmt("handler returned an invalid value for the header '{s}' (string expected, got {s})", .{ name, l.typeNameOf(v) }),
    };
    try checkHeaderText(l, val, "value");
    out.print(l.g.gpa, "{s}: {s}\r\n", .{ name, val }) catch return l.raiseMem();
}

/// Formats the response into `h.out`. The handler returned `status`,
/// `body`, and `headers` in the arguments 2 to 4.
fn buildResponse(l: *Thread, h: *Http, keep_in: bool, head: bool, stream: bool, broken: bool) Error!void {
    // A request body that broke its framing leaves the connection in an
    // unknown place, so the connection closes after the response.
    var keep = keep_in and !broken;
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
    const upgrade = status == 101;
    const is_fn = l.arg(3).tag == .closure or l.arg(3).tag == .native;
    if (upgrade and !is_fn) return l.raiseFmt("handler returned status 101 without an upgrade function (got {s})", .{l.typeNameOf(l.arg(3))});
    switch (l.arg(3).tag) {
        .nil => {},
        .closure, .native => if (!upgrade) return l.raiseFmt("handler returned an invalid body (string, vector, or function expected, got function)", .{}),
        .string => body = l.arg(3).as(object.String).bytes(),
        .vector => body = l.arg(3).as(object.Vector).bytes.items,
        else => return l.raiseFmt("handler returned an invalid body (string or vector expected, got {s})", .{l.typeNameOf(l.arg(3))}),
    }
    const bodiless = status < 200 or status == 204 or status == 304;

    out.print(gpa, "HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) }) catch return l.raiseMem();
    var has_length = false;
    var has_date = false;
    var has_connection = false;
    var has_upgrade = false;
    var has_accept = false;
    if (!l.arg(4).isNil()) {
        if (l.arg(4).tag != .table) return l.raiseFmt("handler returned invalid headers (table expected, got {s})", .{l.typeNameOf(l.arg(4))});
        const t = l.arg(4).as(Table);
        var key: Value = .nil;
        while (table.next(t, key) catch return l.raiseFmt("handler returned invalid headers", .{})) |e| : (key = e.key) {
            if (e.key.tag != .string) return l.raiseFmt("handler returned an invalid header name ({s})", .{l.typeNameOf(e.key)});
            const name = e.key.as(object.String).bytes();
            if (name.len == 0) return l.raiseFmt("handler returned an invalid header name", .{});
            for (name) |c| if (!isToken(c)) return l.raiseFmt("handler returned an invalid header name", .{});
            if (std.ascii.eqlIgnoreCase(name, "content-length")) has_length = true;
            if (std.ascii.eqlIgnoreCase(name, "date")) has_date = true;
            if (std.ascii.eqlIgnoreCase(name, "connection")) has_connection = true;
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) has_upgrade = true;
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) has_accept = true;
            if (e.val.tag == .table) {
                // A list sends one header line for each of its values.
                const list = e.val.as(Table);
                const n = table.length(list);
                var i: i64 = 1;
                while (i <= n) : (i += 1) try writeHeader(l, out, name, table.getInt(list, i));
            } else try writeHeader(l, out, name, e.val);
        }
    }
    if (upgrade and l.arg(7).tag == .string) {
        // A WebSocket handshake answers the key of the request.
        if (!has_upgrade) out.appendSlice(gpa, "Upgrade: websocket\r\n") catch return l.raiseMem();
        if (!has_connection) {
            out.appendSlice(gpa, "Connection: Upgrade\r\n") catch return l.raiseMem();
            has_connection = true;
        }
        if (!has_accept) {
            var accept: [28]u8 = undefined;
            websocketAccept(l.arg(7).as(object.String).bytes(), &accept);
            out.print(gpa, "Sec-WebSocket-Accept: {s}\r\n", .{&accept}) catch return l.raiseMem();
        }
    }
    if (!has_date) out.print(gpa, "Date: {s}\r\n", .{dateText(h, l.g.io)}) catch return l.raiseMem();
    h.stream_raw = false;
    if (stream and !bodiless and !head) {
        // A client of HTTP/1.0 knows no chunked coding, and a length that
        // the handler set leaves the chunks unframed. Either way the end
        // of the connection ends the body.
        if (has_length or h.http10) {
            h.stream_raw = true;
            keep = false;
        } else {
            out.appendSlice(gpa, "Transfer-Encoding: chunked\r\n") catch return l.raiseMem();
        }
    } else if (stream and head and !bodiless and !has_length) {
        out.appendSlice(gpa, "Transfer-Encoding: chunked\r\n") catch return l.raiseMem();
    } else if (!has_length and !bodiless) out.print(gpa, "Content-Length: {d}\r\n", .{body.len}) catch return l.raiseMem();
    h.close_after = !keep;
    if (!keep and !has_connection) out.appendSlice(gpa, "Connection: close\r\n") catch return l.raiseMem();
    out.appendSlice(gpa, "\r\n") catch return l.raiseMem();
    if (!head and !bodiless) out.appendSlice(gpa, body) catch return l.raiseMem();
}

/// respond(sock, status, body, headers, keep, head, key): writes a
/// response. `key` is the `Sec-WebSocket-Key` of a request that the
/// response upgrades.
/// Returns true when all of it was sent. Raises when the handler returned
/// values that make no response, before it writes anything.
fn respond(l: *Thread) Error!u32 {
    const s = try net.checkSocket(l, 1);
    const h = try httpOf(l, s);
    const stream = l.arg(8).tag == .true;
    const head = l.arg(6).tag == .true;
    // A response that waited continues after the bytes it already sent.
    if (!sched.restarted(l) or h.out.items.len == 0) {
        try buildResponse(l, h, l.arg(5).tag == .true, head, stream, http.requestRefusal(s) != 0);
    }
    const sent = try flushOut(l, s, h);
    if (!stream) return aux.retBool(l, sent and !h.close_after);
    // A streamed response goes on with the chunks of the generator, unless
    // the request was HEAD or the status carries no body.
    const status: i64 = if (l.arg(2).tag == .integer) l.arg(2).asInt() else 200;
    const bodiless = status < 200 or status == 204 or status == 304;
    try l.push(Value.boolean(sent));
    try l.push(Value.boolean(sent and !head and !bodiless));
    return 2;
}

/// Sends `h.out` from `h.out_off` on. Returns whether all of it went out.
fn flushOut(l: *Thread, s: *net.Socket, h: *Http) Error!bool {
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
                // A reader that takes nothing for the idle timeout loses
                // the connection.
                if (!try sched.waitIo(l, handle, net.againDir(s, .write), s.timeout_ms)) {
                    sent = false;
                    break;
                }
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
    return sent;
}

/// writechunk(sock, chunk): writes one chunk of a streamed response, or
/// its end for nil. Returns whether the connection stays open: false
/// when the write failed, and after the end of a response that closes
/// its connection.
fn writeChunk(l: *Thread) Error!u32 {
    const s = try net.checkSocket(l, 1);
    const h = try httpOf(l, s);
    if (!sched.restarted(l) or h.out.items.len == 0) {
        const gpa = l.g.gpa;
        h.out.clearRetainingCapacity();
        h.out_off = 0;
        const v = l.arg(2);
        switch (v.tag) {
            .nil => if (!h.stream_raw) h.out.appendSlice(gpa, "0\r\n\r\n") catch return l.raiseMem(),
            .string, .vector => {
                const data = if (v.tag == .string) v.as(object.String).bytes() else v.as(object.Vector).bytes.items;
                // An empty chunk would end a chunked body.
                if (data.len == 0) return aux.retBool(l, true);
                if (!h.stream_raw) h.out.print(gpa, "{x}\r\n", .{data.len}) catch return l.raiseMem();
                h.out.appendSlice(gpa, data) catch return l.raiseMem();
                if (!h.stream_raw) h.out.appendSlice(gpa, "\r\n") catch return l.raiseMem();
            },
            else => return l.raiseFmt("the body function returned an invalid chunk (string, vector, or nil expected, got {s})", .{l.typeNameOf(v)}),
        }
    }
    const last = l.arg(2).isNil();
    const sent = try flushOut(l, s, h);
    return aux.retBool(l, sent and !(last and h.close_after));
}

/// refusal(sock): the status that refuses the request whose body broke
/// its framing or its limit while the handler read it, or nil.
fn refusal(l: *Thread) Error!u32 {
    const s = try net.checkSocket(l, 1);
    const status = http.requestRefusal(s);
    if (status == 0) return aux.retNil(l);
    return aux.retInt(l, status);
}

/// readbody(req): the whole body of a request, which `req.body` reads.
fn readBody(l: *Thread) Error!u32 {
    return http.requestBody(l, max_body);
}
