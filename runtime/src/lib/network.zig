//! The `network` library: TCP client and server sockets, UDP sockets, and
//! `network.fetch`, an HTTP and HTTPS client. Sockets are userdata. Every
//! operation blocks, optionally bounded by a timeout set with
//! `settimeout`. Workers provide concurrency.
//!
//! Data received from the network are vectors, and every send accepts a
//! string or a vector (spec/design/strings.md).
//!
//! Host names resolve through `std.Io.net.HostName.lookup`. HTTPS uses
//! `std.crypto.tls.Client` and verifies the server against the system
//! certificate bundle. The standard library has no TLS server, so there is
//! no server side TLS.
//!
//! Timeouts wait with `poll` on POSIX systems. On Windows they are not
//! enforced yet and operations block until they complete.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const pledge = @import("../vm/pledge.zig");
const aux = @import("aux.zig");
const vector = @import("vector.zig");
const base = @import("base.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const Userdata = object.Userdata;
const net = std.Io.net;
const Io = std.Io;
const posix = std.posix;
const is_windows = builtin.os.tag == .windows;

const default_backlog = 128;
const default_recv_size = 4096;
const default_udp_size = 8192;
const max_recv_size = 1024 * 1024;
const default_line_limit = 1024 * 1024;
const default_all_limit = 64 * 1024 * 1024;
const fetch_timeout_ms = 30000;
const fetch_max_body = 64 * 1024 * 1024;

const socket_name = "network.socket";
const server_name = "network.server";
const udp_name = "network.udpsocket";

/// A TCP connection.
const Socket = struct {
    stream: net.Stream,
    local: net.IpAddress,
    peer: net.IpAddress,
    /// -1 blocks, 0 polls, a positive value waits that many milliseconds.
    timeout_ms: i32 = -1,
    closed: bool = false,
    /// Bytes read from the socket and not yet returned.
    buf: std.ArrayList(u8) = .empty,
};

/// A listening TCP socket.
const Server = struct {
    server: net.Server,
    timeout_ms: i32 = -1,
    closed: bool = false,
};

/// A UDP socket. An unbound socket holds a placeholder bound to an
/// ephemeral port on all interfaces, which `setsockname` replaces.
const Udp = struct {
    socket: net.Socket,
    timeout_ms: i32 = -1,
    bound: bool,
    closed: bool = false,
};

pub fn open(l: *Thread) Error!void {
    try makeMetatable(l, socket_name, &.{
        .{ .name = "send", .func = socketSend },
        .{ .name = "receive", .func = socketReceive },
        .{ .name = "close", .func = socketClose },
        .{ .name = "settimeout", .func = socketSettimeout },
        .{ .name = "getsockname", .func = socketGetsockname },
        .{ .name = "getpeername", .func = socketGetpeername },
    }, socketGc, socketTostring);
    try makeMetatable(l, server_name, &.{
        .{ .name = "accept", .func = serverAccept },
        .{ .name = "close", .func = serverClose },
        .{ .name = "settimeout", .func = serverSettimeout },
        .{ .name = "getsockname", .func = serverGetsockname },
    }, serverGc, serverTostring);
    try makeMetatable(l, udp_name, &.{
        .{ .name = "sendto", .func = udpSendto },
        .{ .name = "receive", .func = udpReceive },
        .{ .name = "setsockname", .func = udpSetsockname },
        .{ .name = "getsockname", .func = udpGetsockname },
        .{ .name = "close", .func = udpClose },
        .{ .name = "settimeout", .func = udpSettimeout },
    }, udpGc, udpTostring);

    const t = try aux.newLib(l, &.{.{ .name = "fetch", .func = fetch }});
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    const tcp = try aux.newLib(l, &.{
        .{ .name = "connect", .func = tcpConnect },
        .{ .name = "bind", .func = tcpBind },
    });
    try aux.setField(l, t, "tcp", Value.obj(.table, tcp));
    const udp = try aux.newLib(l, &.{.{ .name = "open", .func = udpOpen }});
    try aux.setField(l, t, "udp", Value.obj(.table, udp));
    try aux.setGlobal(l, "network", Value.obj(.table, t));
}

fn makeMetatable(l: *Thread, comptime name: []const u8, methods: []const aux.Reg, gcf: state.NativeFn, tostr: state.NativeFn) Error!void {
    const mt = try l.newTable(0, 8);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    const m = try aux.newLib(l, methods);
    try aux.setField(l, mt, "__index", Value.obj(.table, m));
    try aux.setField(l, mt, "__name", try l.newStringValue(name));
    try aux.setField(l, mt, "__tostring", try aux.native(l, tostr, "tostring"));
    try aux.setField(l, mt, "__gc", try aux.native(l, gcf, "gc"));
    try aux.setField(l, mt, "__close", try aux.native(l, gcf, "close"));
    // The registry roots the metatable, and the extension map records it
    // for fast lookup.
    const g = l.g;
    try aux.setField(l, g.registry.as(Table), name, Value.obj(.table, mt));
    g.ext.put(g.gpa, name, mt) catch return l.raiseMem();
}

fn metatableOf(l: *Thread, comptime name: []const u8) *Table {
    return @ptrCast(@alignCast(l.g.ext.get(name).?));
}

/// Creates a userdata holding `init` and pushes it.
fn newObject(l: *Thread, comptime T: type, comptime name: []const u8, init: T) Error!*T {
    const g = l.g;
    gc.maybeCollect(g);
    const mt = metatableOf(l, name);
    const u = gc.alloc(g, Userdata, .userdata, Userdata.allocSize(@sizeOf(T), 0)) catch return l.raiseMem();
    u.size = @sizeOf(T);
    u.nuser = 0;
    u.metatable = mt;
    const p: *T = @ptrCast(@alignCast(u.data()));
    p.* = init;
    try l.push(Value.obj(.userdata, u));
    try base.registerFinalizer(l, &u.hdr, mt);
    return p;
}

fn toObject(l: *Thread, comptime T: type, comptime name: []const u8, v: Value) ?*T {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != metatableOf(l, name)) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn checkSocket(l: *Thread, i: u32) Error!*Socket {
    const s = toObject(l, Socket, socket_name, l.arg(i)) orelse return aux.typeError(l, i, socket_name);
    if (s.closed) return l.raiseFmt("attempt to use a closed socket", .{});
    return s;
}

fn checkServer(l: *Thread, i: u32) Error!*Server {
    const s = toObject(l, Server, server_name, l.arg(i)) orelse return aux.typeError(l, i, server_name);
    if (s.closed) return l.raiseFmt("attempt to use a closed server", .{});
    return s;
}

fn checkUdp(l: *Thread, i: u32) Error!*Udp {
    const s = toObject(l, Udp, udp_name, l.arg(i)) orelse return aux.typeError(l, i, udp_name);
    if (s.closed) return l.raiseFmt("attempt to use a closed UDP socket", .{});
    return s;
}

// ---------------------------------------------------------------------
// Arguments

fn checkPort(l: *Thread, i: u32, allow_zero: bool) Error!u16 {
    const p = try aux.checkInt(l, i);
    const min: i64 = if (allow_zero) 0 else 1;
    if (p < min or p > 65535) return aux.argError(l, i, "port out of range", .{});
    return @intCast(p);
}

fn optPort(l: *Thread, i: u32, default: u16, allow_zero: bool) Error!u16 {
    if (l.arg(i).isNil()) return default;
    return checkPort(l, i, allow_zero);
}

/// The bytes of a string or vector argument.
fn checkData(l: *Thread, i: u32) Error![]const u8 {
    if (l.arg(i).tag == .vector) return (try vector.checkVector(l, i)).bytes.items;
    return aux.checkBytes(l, i);
}

fn timeoutArg(l: *Thread, i: u32) Error!i32 {
    const secs = try aux.checkFloat(l, i);
    if (std.math.isNan(secs) or secs < 0) return -1;
    if (secs == 0) return 0;
    const ms = secs * 1000;
    if (ms >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intFromFloat(ms);
}

/// Formats "host:port" for permission checks and messages.
fn hostPort(buf: []u8, host: []const u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port }) catch host;
}

// ---------------------------------------------------------------------
// Errors

/// The message the C library gives for the error a socket call failed
/// with, so messages read the same on every platform.
fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Connection refused",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.ConnectionAborted => "Software caused connection abort",
        error.AddressInUse => "Address already in use",
        error.AddressUnavailable => "Can't assign requested address",
        error.AddressFamilyUnsupported => "Address family not supported by protocol family",
        error.AccessDenied, error.BlockedByFirewall => "Permission denied",
        error.NetworkUnreachable => "Network is unreachable",
        error.HostUnreachable => "No route to host",
        error.NetworkDown => "Network is down",
        error.Timeout, error.ConnectionTimedOut => "Operation timed out",
        error.SocketUnconnected => "Socket is not connected",
        error.SocketNotListening => "Invalid argument",
        error.BrokenPipe => "Broken pipe",
        error.SystemResources => "No buffer space available",
        error.ProcessFdQuotaExceeded => "Too many open files",
        error.SystemFdQuotaExceeded => "Too many open files in system",
        error.MessageOversize => "Message too long",
        error.UnknownHostName, error.NoAddressReturned => "Domain name not found",
        error.InvalidHostName, error.NameTooLong => "Invalid host name",
        error.NameServerFailure => "Name server failure",
        error.Canceled => "Operation canceled",
        else => @errorName(err),
    };
}

/// Returns `nil, "prefix: message"`, the result of a failed socket call.
fn failResult(l: *Thread, prefix: []const u8, err: anyerror) Error!u32 {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ prefix, errText(err) }) catch prefix;
    return aux.retFail(l, msg);
}

// ---------------------------------------------------------------------
// Low-level socket operations

const Wait = enum { ready, timeout, failed };

/// Waits until `handle` is readable (or writable) for at most
/// `timeout_ms` milliseconds. A negative timeout does not wait.
fn waitHandle(handle: net.Socket.Handle, for_write: bool, timeout_ms: i32) Wait {
    if (timeout_ms < 0 or is_windows) return .ready;
    var fds = [_]posix.pollfd{.{
        .fd = handle,
        .events = if (for_write) posix.POLL.OUT else posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms) catch return .failed;
    return if (n == 0) .timeout else .ready;
}

/// Reads at most `dst.len` bytes. Returns 0 at the end of the stream.
fn readSome(io: Io, stream: net.Stream, dst: []u8) !usize {
    var bufs = [_][]u8{dst};
    return stream.read(io, &bufs);
}

fn writeSome(io: Io, handle: net.Socket.Handle, data: []const u8) !usize {
    var parts = [_][]const u8{data};
    const r = try io.operate(.{ .net_write = .{ .socket_handle = handle, .data = &parts } });
    return try r.net_write;
}

/// Keeps writes to a closed peer from raising SIGPIPE on systems whose
/// send calls cannot suppress it per call.
fn noSigpipe(handle: net.Socket.Handle) void {
    if (comptime is_windows) return;
    if (comptime @hasDecl(posix.SO, "NOSIGPIPE")) {
        const one: c_int = 1;
        posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&one)) catch {};
    }
}

/// The local address of a socket, through getsockname.
fn localAddress(handle: net.Socket.Handle, fallback: net.IpAddress) net.IpAddress {
    if (comptime is_windows) return fallback;
    var storage: Io.Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(handle, &storage.any, &len)) != .SUCCESS) return fallback;
    return Io.Threaded.addressFromPosix(&storage);
}

fn closeHandle(handle: net.Socket.Handle) void {
    if (comptime is_windows) return;
    _ = posix.system.close(handle);
}

const ListenError = error{ AccessDenied, AddressInUse, AddressUnavailable, AddressFamilyUnsupported, SystemResources, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

/// Creates a listening TCP socket. On POSIX systems it sets SO_REUSEADDR
/// alone, so a port can be bound again right after a close while a second
/// live bind still fails. `std.Io` would also set SO_REUSEPORT, which lets
/// two sockets bind the same port.
const Stage = enum { bind, listen };

fn listenTcp(io: Io, addr: *const net.IpAddress, backlog: u31, stage: *Stage) !net.Server {
    stage.* = .bind;
    if (comptime is_windows) return addr.listen(io, .{ .kernel_backlog = backlog });
    const Threaded = Io.Threaded;
    const family = Threaded.posixAddressFamily(addr);
    const cloexec: u32 = if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(family, posix.SOCK.STREAM | cloexec, posix.IPPROTO.TCP);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    }
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeHandle(fd);
    if (cloexec == 0) _ = posix.system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    const one: c_int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    noSigpipe(fd);
    var storage: Threaded.PosixAddress = undefined;
    var len = Threaded.addressToPosix(addr, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, len))) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
    stage.* = .listen;
    switch (posix.errno(posix.system.listen(fd, backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Unexpected,
    }
    len = @sizeOf(Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(fd, &storage.any, &len)) != .SUCCESS) return error.Unexpected;
    return .{ .socket = .{ .handle = fd, .address = Threaded.addressFromPosix(&storage) }, .options = {} };
}

/// Formats the numeric address of `a` without its port.
fn formatIp(buf: []u8, a: net.IpAddress) []const u8 {
    return switch (a) {
        .ip4 => |ip4| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] }) catch "?",
        .ip6 => |ip6| blk: {
            const u: net.Ip6Address.Unresolved = .{ .bytes = ip6.bytes, .interface_name = null };
            break :blk std.fmt.bufPrint(buf, "{f}", .{u}) catch "?";
        },
    };
}

/// Pushes the numeric address and port of `a`.
fn pushAddress(l: *Thread, a: net.IpAddress) Error!u32 {
    var buf: [64]u8 = undefined;
    try l.push(try l.newStringValue(formatIp(&buf, a)));
    try l.push(Value.int(a.getPort()));
    return 2;
}

// ---------------------------------------------------------------------
// Name resolution

const max_addresses = 16;

/// Resolves `host` to at most `max_addresses` addresses, raising "cannot
/// resolve" on failure. Literal addresses resolve without a lookup.
/// `family` restricts the result when it is not null.
fn resolve(l: *Thread, host: []const u8, port: u16, family: ?net.IpAddress.Family, out: *[max_addresses]net.IpAddress) Error![]net.IpAddress {
    if (net.IpAddress.parse(host, port)) |a| {
        out[0] = a;
        return out[0..1];
    } else |_| {}
    const name = net.HostName.init(host) catch |e| return l.raiseFmt("cannot resolve '{s}': {s}", .{ host, errText(e) });
    var results: [32]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&results);
    const io = l.g.io;
    name.lookup(io, &queue, .{ .port = port, .family = family }) catch |e| return l.raiseFmt("cannot resolve '{s}': {s}", .{ host, errText(e) });
    var n: usize = 0;
    while (queue.getOne(io)) |r| switch (r) {
        .address => |a| if (n < out.len) {
            out[n] = a;
            n += 1;
        },
        .canonical_name => {},
    } else |_| {}
    if (n == 0) return l.raiseFmt("cannot resolve '{s}': {s}", .{ host, errText(error.NoAddressReturned) });
    return out[0..n];
}

/// Connects to the first address of `host` that accepts, raising "cannot
/// connect" when none does.
fn connectHost(l: *Thread, host: []const u8, port: u16) Error!struct { net.Stream, net.IpAddress } {
    var addrs: [max_addresses]net.IpAddress = undefined;
    const list = try resolve(l, host, port, null, &addrs);
    var last: anyerror = error.ConnectionRefused;
    for (list) |*a| {
        const stream = a.connect(l.g.io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            last = e;
            continue;
        };
        noSigpipe(stream.socket.handle);
        return .{ stream, a.* };
    }
    return l.raiseFmt("cannot connect to {s}:{d}: {s}", .{ host, port, errText(last) });
}

// ---------------------------------------------------------------------
// TCP sockets

fn tcpConnect(l: *Thread) Error!u32 {
    const host = try aux.checkBytes(l, 1);
    const port = try checkPort(l, 2, false);
    var hp: [512]u8 = undefined;
    try pledge.require(l, "network:tcp", hostPort(&hp, host, port));
    const stream, const peer = try connectHost(l, host, port);
    errdefer stream.close(l.g.io);
    _ = try newObject(l, Socket, socket_name, .{ .stream = stream, .local = stream.socket.address, .peer = peer });
    return 1;
}

fn tcpBind(l: *Thread) Error!u32 {
    const host = try aux.checkBytes(l, 1);
    const port = try checkPort(l, 2, true);
    const backlog = try aux.optInt(l, 3, default_backlog);
    var hp: [512]u8 = undefined;
    try pledge.require(l, "network:tcp", hostPort(&hp, host, port));
    var addrs: [max_addresses]net.IpAddress = undefined;
    const list = try resolve(l, host, port, null, &addrs);
    var stage: Stage = .bind;
    const backlog_c: u31 = @intCast(std.math.clamp(backlog, 0, std.math.maxInt(u31)));
    const server = listenTcp(l.g.io, &list[0], backlog_c, &stage) catch |e| switch (stage) {
        .bind => return l.raiseFmt("cannot bind to {s}:{d}: {s}", .{ host, port, errText(e) }),
        .listen => return l.raiseFmt("cannot listen on {s}:{d}: {s}", .{ host, port, errText(e) }),
    };
    errdefer server.socket.close(l.g.io);
    _ = try newObject(l, Server, server_name, .{ .server = server });
    return 1;
}

fn socketSend(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    const data = try checkData(l, 2);
    const io = l.g.io;
    const h = s.stream.socket.handle;
    var total: usize = 0;
    while (total < data.len) {
        switch (waitHandle(h, true, s.timeout_ms)) {
            .ready => {},
            .timeout => return l.raiseFmt("send timeout", .{}),
            .failed => return failResult(l, "send", error.Unexpected),
        }
        const chunk = @min(data.len - total, std.math.maxInt(i32));
        const n = writeSome(io, h, data[total..][0..chunk]) catch |e| return failResult(l, "send", e);
        total += n;
    }
    return aux.retInt(l, @intCast(total));
}

const Fill = union(enum) { got: usize, eof, fail: anyerror };

/// Reads up to `max` more bytes into the socket buffer, waiting at most
/// the socket timeout. Raises "receive timeout" when it expires.
fn fill(l: *Thread, s: *Socket, max: usize) Error!Fill {
    switch (waitHandle(s.stream.socket.handle, false, s.timeout_ms)) {
        .ready => {},
        .timeout => return l.raiseFmt("receive timeout", .{}),
        .failed => return .{ .fail = error.Unexpected },
    }
    s.buf.ensureUnusedCapacity(l.g.gpa, max) catch return l.raiseMem();
    const dst = s.buf.unusedCapacitySlice()[0..max];
    const n = readSome(l.g.io, s.stream, dst) catch |e| return .{ .fail = e };
    if (n == 0) return .eof;
    s.buf.items.len += n;
    return .{ .got = n };
}

/// Pushes the first `n` buffered bytes as a vector and removes them.
fn takeBuffered(l: *Thread, s: *Socket, n: usize, skip: usize) Error!u32 {
    const v = try vector.newVector(l, s.buf.items[0..n]);
    const consumed = n + skip;
    const rest = s.buf.items.len - consumed;
    std.mem.copyForwards(u8, s.buf.items[0..rest], s.buf.items[consumed..]);
    s.buf.items.len = rest;
    return aux.ret(l, Value.obj(.vector, v));
}

/// Closes a socket whose peer exceeded a receive limit. It skips the
/// graceful shutdown and does not drain input the peer controls.
fn limitExceeded(l: *Thread, s: *Socket) Error {
    s.stream.close(l.g.io);
    s.buf.deinit(l.g.gpa);
    s.buf = .empty;
    s.closed = true;
    return l.raiseFmt("receive limit exceeded", .{});
}

fn receiveLimit(l: *Thread, i: u32, default: i64) Error!usize {
    const n = try aux.optInt(l, i, default);
    if (n <= 0) return aux.argError(l, i, "max_bytes must be positive", .{});
    return @intCast(n);
}

fn recvBytes(l: *Thread, s: *Socket, n: usize) Error!u32 {
    while (s.buf.items.len < n) {
        switch (try fill(l, s, @min(default_recv_size, n - s.buf.items.len))) {
            .got => {},
            .eof => return takeBuffered(l, s, s.buf.items.len, 0),
            .fail => |e| return failResult(l, "receive", e),
        }
    }
    return takeBuffered(l, s, n, 0);
}

fn recvLine(l: *Thread, s: *Socket, limit: usize) Error!u32 {
    var scanned: usize = 0;
    while (true) {
        const items = s.buf.items;
        if (std.mem.indexOfScalarPos(u8, items, scanned, '\n')) |nl| {
            var len = nl;
            if (len > 0 and items[len - 1] == '\r') len -= 1;
            if (len > limit) return limitExceeded(l, s);
            return takeBuffered(l, s, len, nl - len + 1);
        }
        scanned = items.len;
        if (items.len > limit and !(items.len == limit + 1 and items[limit] == '\r')) return limitExceeded(l, s);
        switch (try fill(l, s, default_recv_size)) {
            .got => {},
            .eof => {
                if (s.buf.items.len > limit) return limitExceeded(l, s);
                return takeBuffered(l, s, s.buf.items.len, 0);
            },
            .fail => |e| return failResult(l, "receive", e),
        }
    }
}

fn recvAll(l: *Thread, s: *Socket, limit: usize) Error!u32 {
    if (s.buf.items.len > limit) return limitExceeded(l, s);
    while (true) {
        switch (try fill(l, s, default_recv_size)) {
            .got => if (s.buf.items.len > limit) return limitExceeded(l, s),
            .eof => return takeBuffered(l, s, s.buf.items.len, 0),
            .fail => |e| return failResult(l, "receive", e),
        }
    }
}

fn socketReceive(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    if (l.arg(2).isNumber()) {
        const n = try aux.checkInt(l, 2);
        if (n <= 0 or n > max_recv_size) return l.raiseFmt("invalid receive size: {d}", .{n});
        return recvBytes(l, s, @intCast(n));
    }
    const pattern = (try aux.optString(l, 2, "*l")).?;
    if (std.mem.eql(u8, pattern, "*l")) return recvLine(l, s, try receiveLimit(l, 3, default_line_limit));
    if (std.mem.eql(u8, pattern, "*a")) return recvAll(l, s, try receiveLimit(l, 3, default_all_limit));
    return l.raiseFmt("invalid receive pattern: {s}", .{pattern});
}

/// Closes a connection gracefully: sends FIN, then discards pending input
/// so the close does not reset the connection.
fn closeSocket(l: *Thread, s: *Socket) void {
    if (s.closed) return;
    const io = l.g.io;
    s.stream.shutdown(io, .send) catch {};
    if (!is_windows) {
        var tmp: [1024]u8 = undefined;
        var budget: usize = 1024;
        while (budget > 0) : (budget -= 1) {
            if (waitHandle(s.stream.socket.handle, false, 0) != .ready) break;
            const n = readSome(io, s.stream, &tmp) catch break;
            if (n == 0) break;
        }
    }
    s.stream.close(io);
    s.buf.deinit(l.g.gpa);
    s.buf = .empty;
    s.closed = true;
}

fn socketClose(l: *Thread) Error!u32 {
    const s = toObject(l, Socket, socket_name, l.arg(1)) orelse return aux.typeError(l, 1, socket_name);
    closeSocket(l, s);
    return 0;
}

fn socketGc(l: *Thread) Error!u32 {
    if (toObject(l, Socket, socket_name, l.arg(1))) |s| closeSocket(l, s);
    return 0;
}

fn socketSettimeout(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    s.timeout_ms = try timeoutArg(l, 2);
    return 0;
}

fn socketGetsockname(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    return pushAddress(l, s.local);
}

fn socketGetpeername(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    return pushAddress(l, s.peer);
}

fn objectTostring(l: *Thread, comptime label: []const u8, closed: bool) Error!u32 {
    if (closed) return aux.retStr(l, label ++ " (closed)");
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, label ++ " (0x{x})", .{l.arg(1).payload}) catch label);
}

fn socketTostring(l: *Thread) Error!u32 {
    const s = toObject(l, Socket, socket_name, l.arg(1)) orelse return aux.typeError(l, 1, socket_name);
    return objectTostring(l, "socket", s.closed);
}

// ---------------------------------------------------------------------
// TCP servers

fn serverAccept(l: *Thread) Error!u32 {
    const s = try checkServer(l, 1);
    switch (waitHandle(s.server.socket.handle, false, s.timeout_ms)) {
        .ready => {},
        .timeout => return l.raiseFmt("accept timeout", .{}),
        .failed => return failResult(l, "accept", error.Unexpected),
    }
    const stream = s.server.accept(l.g.io) catch |e| return failResult(l, "accept", e);
    errdefer stream.close(l.g.io);
    noSigpipe(stream.socket.handle);
    const local = localAddress(stream.socket.handle, s.server.socket.address);
    _ = try newObject(l, Socket, socket_name, .{ .stream = stream, .local = local, .peer = stream.socket.address });
    return 1;
}

fn closeServer(l: *Thread, s: *Server) void {
    if (s.closed) return;
    s.server.socket.close(l.g.io);
    s.closed = true;
}

fn serverClose(l: *Thread) Error!u32 {
    const s = toObject(l, Server, server_name, l.arg(1)) orelse return aux.typeError(l, 1, server_name);
    closeServer(l, s);
    return 0;
}

fn serverGc(l: *Thread) Error!u32 {
    if (toObject(l, Server, server_name, l.arg(1))) |s| closeServer(l, s);
    return 0;
}

fn serverSettimeout(l: *Thread) Error!u32 {
    const s = try checkServer(l, 1);
    s.timeout_ms = try timeoutArg(l, 2);
    return 0;
}

fn serverGetsockname(l: *Thread) Error!u32 {
    const s = try checkServer(l, 1);
    return pushAddress(l, s.server.socket.address);
}

fn serverTostring(l: *Thread) Error!u32 {
    const s = toObject(l, Server, server_name, l.arg(1)) orelse return aux.typeError(l, 1, server_name);
    return objectTostring(l, "server", s.closed);
}

// ---------------------------------------------------------------------
// UDP sockets

fn bindUdp(io: Io, addr: *const net.IpAddress) !net.Socket {
    const sock = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    noSigpipe(sock.handle);
    return sock;
}

fn udpOpen(l: *Thread) Error!u32 {
    const port = try optPort(l, 1, 0, true);
    const address = try aux.optString(l, 2, null);
    const bind = port > 0 or address != null;
    if (bind) {
        var hp: [512]u8 = undefined;
        try pledge.require(l, "network:udp", hostPort(&hp, address orelse "0.0.0.0", port));
    } else try pledge.require(l, "network:udp", null);
    var addr: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(port) };
    if (address) |a| {
        addr = .{ .ip4 = net.Ip4Address.parse(a, port) catch return l.raiseFmt("invalid address: {s}", .{a}) };
    }
    const sock = bindUdp(l.g.io, &addr) catch |e| {
        if (bind) return l.raiseFmt("cannot bind UDP socket: {s}", .{errText(e)});
        return l.raiseFmt("cannot create UDP socket: {s}", .{errText(e)});
    };
    errdefer sock.close(l.g.io);
    _ = try newObject(l, Udp, udp_name, .{ .socket = sock, .bound = bind });
    return 1;
}

fn udpSendto(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    const data = try checkData(l, 2);
    const address = try aux.checkBytes(l, 3);
    const port = try checkPort(l, 4, false);
    if (data.len > std.math.maxInt(i32)) return aux.argError(l, 2, "datagram too large", .{});
    // network:udp is checked for every destination, so a grant scoped to
    // one host does not permit datagrams to any other.
    var hp: [512]u8 = undefined;
    try pledge.require(l, "network:udp", hostPort(&hp, address, port));
    var addrs: [max_addresses]net.IpAddress = undefined;
    const list = try resolve(l, address, port, if (s.socket.address == .ip4) .ip4 else null, &addrs);
    switch (waitHandle(s.socket.handle, true, s.timeout_ms)) {
        .ready => {},
        .timeout => return l.raiseFmt("sendto timeout", .{}),
        .failed => return failResult(l, "sendto", error.Unexpected),
    }
    s.socket.send(l.g.io, &list[0], data) catch |e| return failResult(l, "sendto", e);
    return aux.retInt(l, @intCast(data.len));
}

fn udpReceive(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    const size = try aux.optInt(l, 2, default_udp_size);
    if (size <= 0 or size > max_recv_size) return l.raiseFmt("invalid receive size: {d}", .{size});
    const gpa = l.g.gpa;
    const buf = gpa.alloc(u8, @intCast(size)) catch return l.raiseMem();
    defer gpa.free(buf);
    switch (waitHandle(s.socket.handle, false, s.timeout_ms)) {
        .ready => {},
        .timeout => return l.raiseFmt("receive timeout", .{}),
        .failed => return failResult(l, "recvfrom", error.Unexpected),
    }
    const msg = s.socket.receive(l.g.io, buf) catch |e| return failResult(l, "recvfrom", e);
    try l.push(Value.obj(.vector, try vector.newVector(l, msg.data)));
    _ = try pushAddress(l, msg.from);
    return 3;
}

fn udpSetsockname(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    const address = try aux.checkBytes(l, 2);
    const port = try checkPort(l, 3, true);
    var hp: [512]u8 = undefined;
    try pledge.require(l, "network:udp", hostPort(&hp, address, port));
    var addrs: [max_addresses]net.IpAddress = undefined;
    const list = try resolve(l, address, port, .ip4, &addrs);
    // A socket binds once, as with bind(2).
    if (s.bound) return failResult(l, "bind", error.SocketNotListening);
    const sock = bindUdp(l.g.io, &list[0]) catch |e| return failResult(l, "bind", e);
    s.socket.close(l.g.io);
    s.socket = sock;
    s.bound = true;
    return 0;
}

fn udpGetsockname(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    return pushAddress(l, s.socket.address);
}

fn udpSettimeout(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    s.timeout_ms = try timeoutArg(l, 2);
    return 0;
}

fn closeUdp(l: *Thread, s: *Udp) void {
    if (s.closed) return;
    s.socket.close(l.g.io);
    s.closed = true;
}

fn udpClose(l: *Thread) Error!u32 {
    const s = toObject(l, Udp, udp_name, l.arg(1)) orelse return aux.typeError(l, 1, udp_name);
    closeUdp(l, s);
    return 0;
}

fn udpGc(l: *Thread) Error!u32 {
    if (toObject(l, Udp, udp_name, l.arg(1))) |s| closeUdp(l, s);
    return 0;
}

fn udpTostring(l: *Thread) Error!u32 {
    const s = toObject(l, Udp, udp_name, l.arg(1)) orelse return aux.typeError(l, 1, udp_name);
    return objectTostring(l, "udpsocket", s.closed);
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

/// A socket reader that waits at most `timeout_ms` for each read. A
/// timeout or socket error is kept in `err` and reported as ReadFailed.
const TimedReader = struct {
    io: Io,
    stream: net.Stream,
    timeout_ms: i32,
    interface: Io.Reader,
    err: ?anyerror = null,

    fn init(io: Io, stream: net.Stream, timeout_ms: i32, buffer: []u8) TimedReader {
        return .{
            .io = io,
            .stream = stream,
            .timeout_ms = timeout_ms,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
        switch (waitHandle(r.stream.socket.handle, false, r.timeout_ms)) {
            .ready => {},
            .timeout => {
                r.err = error.Timeout;
                return error.ReadFailed;
            },
            .failed => {
                r.err = error.Unexpected;
                return error.ReadFailed;
            },
        }
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const n = r.stream.read(r.io, iovecs[0..dest_n]) catch |e| {
            r.err = e;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

const tls_len = std.crypto.tls.Client.min_buffer_len;

/// The connection of one fetch, heap allocated because the TLS client
/// keeps pointers to the socket reader and writer.
const FetchConn = struct {
    stream: net.Stream,
    sr: TimedReader,
    sw: net.Stream.Writer,
    tls: std.crypto.tls.Client,
    use_tls: bool,
    sr_buf: [tls_len]u8,
    sw_buf: [tls_len]u8,
    tls_read: [tls_len]u8,
    tls_write: [tls_len]u8,

    fn reader(c: *FetchConn) *Io.Reader {
        return if (c.use_tls) &c.tls.reader else &c.sr.interface;
    }

    fn writer(c: *FetchConn) *Io.Writer {
        return if (c.use_tls) &c.tls.writer else &c.sw.interface;
    }

    fn sendAll(c: *FetchConn, data: []const u8) bool {
        const w = c.writer();
        w.writeAll(data) catch return false;
        w.flush() catch return false;
        if (c.use_tls) c.sw.interface.flush() catch return false;
        return true;
    }
};

/// Reads one LF terminated line into `buf`, without the LF and an optional
/// CR before it. A line longer than the buffer returns its first part and
/// leaves the rest for the next read. Returns null on a read error.
fn readHttpLine(r: *Io.Reader, buf: []u8) ?usize {
    var pos: usize = 0;
    while (true) {
        const b = r.takeByte() catch |e| switch (e) {
            error.EndOfStream => return pos,
            error.ReadFailed => return null,
        };
        if (b == '\n') {
            if (pos > 0 and buf[pos - 1] == '\r') pos -= 1;
            return pos;
        }
        buf[pos] = b;
        pos += 1;
        if (pos >= buf.len - 1) return pos;
    }
}

/// Reads up to `dst.len` bytes. Returns 0 at the end of the stream and
/// null on a read error.
fn readBody(r: *Io.Reader, dst: []u8) ?usize {
    return r.readSliceShort(dst) catch null;
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn parseContentLength(s: []const u8) ?usize {
    const t = trimSpaces(s);
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, t, 10) catch null;
}

fn parseChunkSize(s: []const u8) ?usize {
    const t = std.mem.trimStart(u8, s, " \t");
    var end: usize = 0;
    while (end < t.len and std.ascii.isHex(t[end])) end += 1;
    if (end == 0) return null;
    const after = std.mem.trimStart(u8, t[end..], " \t");
    if (after.len > 0 and after[0] != ';') return null;
    return std.fmt.parseInt(usize, t[0..end], 16) catch null;
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

/// Stores one response header in `t`, decoding invalid UTF-8 lossily.
fn setHeader(l: *Thread, t: *Table, key: []const u8, val: []const u8) Error!void {
    const gpa = l.g.gpa;
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
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

fn buildRequest(l: *Thread, req: *std.ArrayList(u8), method: []const u8, u: ParsedUrl, body: ?[]const u8) Error!void {
    const gpa = l.g.gpa;
    const default_port: u16 = if (u.https) 443 else 80;
    req.print(gpa, "{s} {s} HTTP/1.1\r\n", .{ method, u.path }) catch return l.raiseMem();
    if (u.port != default_port)
        req.print(gpa, "Host: {s}:{d}\r\n", .{ u.host, u.port }) catch return l.raiseMem()
    else
        req.print(gpa, "Host: {s}\r\n", .{u.host}) catch return l.raiseMem();
    req.appendSlice(gpa, "Connection: close\r\nUser-Agent: Lus/1.0\r\n") catch return l.raiseMem();
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
            if (!try headerText(l, kv.val, &val)) continue;
            if (std.mem.indexOfAny(u8, name.items, "\r\n") != null or std.mem.indexOfAny(u8, val.items, "\r\n") != null)
                return l.raiseFmt("invalid characters in HTTP header", .{});
            req.print(gpa, "{s}: {s}\r\n", .{ name.items, val.items }) catch return l.raiseMem();
        }
    }
    if (body) |b| if (b.len > 0) {
        req.print(gpa, "Content-Length: {d}\r\n", .{b.len}) catch return l.raiseMem();
    };
    req.appendSlice(gpa, "\r\n") catch return l.raiseMem();
    if (body) |b| req.appendSlice(gpa, b) catch return l.raiseMem();
}

fn fetch(l: *Thread) Error!u32 {
    const url = try aux.checkBytes(l, 1);
    const method = (try aux.optString(l, 2, "GET")).?;
    const body: ?[]const u8 = if (l.arg(4).isNil()) null else try checkData(l, 4);
    if (std.mem.indexOfAny(u8, method, "\r\n") != null) return l.raiseFmt("invalid characters in HTTP method", .{});
    if (std.mem.indexOfAny(u8, url, "\r\n") != null) return l.raiseFmt("invalid characters in URL", .{});
    try pledge.require(l, "network:http", url);
    const u = parseUrl(url) orelse return l.raiseFmt("invalid URL: {s}", .{url});

    const g = l.g;
    const gpa = g.gpa;
    const io = g.io;

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    try buildRequest(l, &req, method, u, body);

    const stream, _ = try connectHost(l, u.host, u.port);
    defer stream.close(io);

    const c = gpa.create(FetchConn) catch return l.raiseMem();
    defer gpa.destroy(c);
    c.stream = stream;
    c.use_tls = false;
    c.sr = .init(io, stream, fetch_timeout_ms, &c.sr_buf);
    c.sw = stream.writer(io, &c.sw_buf);

    if (u.https) {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(gpa);
        const now = Io.Clock.real.now(io);
        bundle.rescan(gpa, io, now) catch |e| return l.raiseFmt("cannot load system certificates: {s}", .{@errorName(e)});
        var lock: Io.RwLock = .init;
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        c.tls = std.crypto.tls.Client.init(&c.sr.interface, &c.sw.interface, .{
            .host = .{ .explicit = u.host },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } },
            .read_buffer = &c.tls_read,
            .write_buffer = &c.tls_write,
            .entropy = &entropy,
            .realtime_now = now,
            // HTTP framing detects truncated bodies through Content-Length
            // and chunk sizes, as with the legacy runtime.
            .allow_truncation_attacks = true,
        }) catch |e| {
            const name = @errorName(e);
            if (std.mem.indexOf(u8, name, "Certificate") != null)
                return l.raiseFmt("SSL certificate verification failed for {s}", .{u.host});
            const cause: anyerror = switch (e) {
                error.ReadFailed => c.sr.err orelse e,
                error.WriteFailed => c.sw.err orelse e,
                else => e,
            };
            return failResult(l, "SSL handshake failed", cause);
        };
        c.use_tls = true;
    }

    if (!c.sendAll(req.items)) return l.raiseFmt("failed to send request", .{});

    const r = c.reader();
    var line: [4096]u8 = undefined;
    const status_len = readHttpLine(r, &line) orelse return l.raiseFmt("failed to read response", .{});
    const status = parseStatus(line[0..status_len]) orelse return l.raiseFmt("invalid HTTP response: {s}", .{line[0..status_len]});

    const headers = try l.newTable(0, 8);
    try l.push(Value.obj(.table, headers));
    const headers_idx = l.top - 1;
    var content_length: ?usize = null;
    var chunked = false;
    while (true) {
        const n = readHttpLine(r, &line) orelse return l.raiseFmt("failed to read response headers", .{});
        if (n == 0) break;
        const hl = line[0..n];
        const colon = std.mem.indexOfScalar(u8, hl, ':') orelse continue;
        const key = hl[0..colon];
        for (key) |*ch| ch.* = std.ascii.toLower(ch.*);
        const val = std.mem.trimStart(u8, hl[colon + 1 ..], " ");
        try setHeader(l, headers, key, val);
        if (std.mem.eql(u8, key, "content-length")) {
            const len = parseContentLength(val) orelse return l.raiseFmt("invalid Content-Length", .{});
            if (len > fetch_max_body) return l.raiseFmt("invalid Content-Length", .{});
            content_length = len;
        } else if (std.mem.eql(u8, key, "transfer-encoding")) {
            if (std.mem.indexOf(u8, val, "chunked") != null) chunked = true;
        }
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    var buf: [4096]u8 = undefined;
    if (chunked) {
        while (true) {
            const n = readHttpLine(r, &line) orelse return l.raiseFmt("truncated chunked response", .{});
            const size = parseChunkSize(line[0..n]) orelse return l.raiseFmt("invalid chunk size", .{});
            if (size > fetch_max_body - resp.items.len) return l.raiseFmt("invalid chunk size", .{});
            if (size == 0) break;
            var remaining = size;
            while (remaining > 0) {
                const want = @min(remaining, buf.len);
                const got = readBody(r, buf[0..want]) orelse 0;
                if (got == 0) return l.raiseFmt("truncated chunked response", .{});
                resp.appendSlice(gpa, buf[0..got]) catch return l.raiseMem();
                remaining -= got;
            }
            const t = readHttpLine(r, &line);
            if (t == null or t.? != 0) return l.raiseFmt("invalid chunk terminator", .{});
        }
    } else if (content_length) |len| {
        var remaining = len;
        while (remaining > 0) {
            const want = @min(remaining, buf.len);
            const got = readBody(r, buf[0..want]) orelse 0;
            if (got == 0) return l.raiseFmt("truncated response body", .{});
            resp.appendSlice(gpa, buf[0..got]) catch return l.raiseMem();
            remaining -= got;
        }
    } else {
        while (true) {
            const got = readBody(r, &buf) orelse 0;
            if (got == 0) break;
            if (got > fetch_max_body - resp.items.len) return l.raiseFmt("response body too large", .{});
            resp.appendSlice(gpa, buf[0..got]) catch return l.raiseMem();
            if (got < buf.len) break;
        }
    }

    if (c.use_tls) {
        c.tls.end() catch {};
        c.sw.interface.flush() catch {};
    }

    const vec = try vector.newVectorFrom(l, &resp);
    try l.push(Value.obj(.vector, vec));
    const ht = l.stack[headers_idx];
    l.stack[headers_idx] = Value.int(status);
    try l.push(ht);
    return 3;
}
