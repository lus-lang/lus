//! The `network` library: TCP client and server sockets, UDP sockets,
//! `network.fetch`, an HTTP and HTTPS client, and `network.serve`, an HTTP
//! server (`serve.zig`). Sockets are userdata. Every operation blocks its
//! caller, optionally bounded by a timeout set with `settimeout`.
//!
//! TCP connect, accept, send, and receive and UDP receive and sendto are
//! suspension points (`spec/design/coroutines.md`). Inside a detached
//! coroutine they suspend the coroutine while the socket is not ready,
//! and the scheduler runs the others. Anywhere else they keep their
//! caller blocked and run the scheduler while they wait. An operation
//! first tries its system call without waiting, and waits through
//! `sched.waitIo` only when the call reports that it would block. While
//! no detached coroutine exists and no timeout is set, an operation
//! blocks in its system call.
//!
//! Data received from the network are vectors, and every send accepts a
//! string or a vector (spec/design/strings.md).
//!
//! Host names resolve through `std.Io.net.HostName.lookup`. HTTPS uses
//! `std.crypto.tls.Client` and verifies the server against the system
//! certificate bundle. The standard library has no TLS server, so there is
//! no server side TLS.
//!
//! On Windows an operation asks `WSAPoll` whether the socket is ready
//! before it runs its blocking call, and it blocks in that call when the
//! question fails.

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
const sched = @import("../vm/sched.zig");
const aux = @import("auxlib.zig");
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

pub const socket_name = "network.socket";
pub const server_name = "network.server";
const udp_name = "network.udpsocket";

/// A TCP connection.
pub const Socket = struct {
    stream: net.Stream,
    local: net.IpAddress,
    peer: net.IpAddress,
    /// -1 blocks, 0 polls, a positive value waits that many milliseconds.
    timeout_ms: i32 = -1,
    closed: bool = false,
    /// Bytes read from the socket and not yet returned.
    buf: std.ArrayList(u8) = .empty,
    /// Set once the handle is in non-blocking mode, which happens the
    /// first time an operation on the socket must not block. From then on
    /// every operation waits through the scheduler.
    nonblocking: bool = false,
    /// The state of the HTTP exchange that `network.serve` runs on this
    /// connection.
    http: ?*@import("serve.zig").Http = null,
    /// The server whose `network.serve` accepted this connection. The
    /// coroutine of the connection keeps that server alive, and the
    /// socket leaves the count of the server when it closes.
    owner: ?*Server = null,
    /// Set when the server closed the connection at the end of its drain
    /// time, so the natives of the server end its exchange quietly.
    drained: bool = false,
    /// The other open connections of the same server.
    conn_prev: ?*Socket = null,
    conn_next: ?*Socket = null,
};

/// A listening TCP socket.
pub const Server = struct {
    server: net.Server,
    timeout_ms: i32 = -1,
    closed: bool = false,
    // What `network.serve` keeps for the server it serves on.
    /// The connections it accepted that are still open.
    live: u32 = 0,
    /// How many connections it keeps open at once.
    max_live: u32 = 0,
    /// The timeout it gives every connection, in milliseconds.
    idle_ms: i32 = -1,
    /// True while it waits for a connection to close before it accepts
    /// the next one.
    full: bool = false,
    /// The open connections, linked through `conn_next`.
    conns: ?*Socket = null,
    /// Whether `network.serve` bound the server itself.
    serve_owned: bool = false,
    /// How long the connections may take to finish once the coroutine of
    /// `serve` closed, in milliseconds, or -1 without a limit.
    drain_ms: i32 = 10_000,
    /// Set once the coroutine of `serve` closed. The connections finish
    /// the request in progress and close.
    draining: bool = false,
    /// The time on the clock of the scheduler at which the connections
    /// that are still open close, when `drain_ms` is not -1.
    drain_deadline: u64 = 0,
    /// The value of this server, which `network.serve` records so that
    /// the coroutine that ends a drain can hold the server.
    self_value: @import("../vm/value.zig").Value = .nil,
};

/// Adds the connection `c` to the list of its server.
pub fn linkConnection(s: *Server, c: *Socket) void {
    c.owner = s;
    c.conn_prev = null;
    c.conn_next = s.conns;
    if (s.conns) |n| n.conn_prev = c;
    s.conns = c;
}

fn unlinkConnection(s: *Server, c: *Socket) void {
    if (c.conn_prev) |p| p.conn_next = c.conn_next else s.conns = c.conn_next;
    if (c.conn_next) |n| n.conn_prev = c.conn_prev;
    c.conn_prev = null;
    c.conn_next = null;
}

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

    const t = try aux.newLib(l, .fields, "network", &.{
        .{ .name = "fetch", .func = fetch },
        .{ .name = "serve", .func = @import("serve.zig").serve },
    });
    try l.push(Value.obj(.table, t));
    defer l.top -= 1;
    const tcp = try aux.newLib(l, .fields, "network.tcp", &.{
        .{ .name = "connect", .func = tcpConnect },
        .{ .name = "bind", .func = tcpBind },
    });
    try aux.setField(l, t, "tcp", Value.obj(.table, tcp));
    const udp = try aux.newLib(l, .fields, "network.udp", &.{.{ .name = "open", .func = udpOpen }});
    try aux.setField(l, t, "udp", Value.obj(.table, udp));
    try aux.setGlobal(l, "network", Value.obj(.table, t));
}

fn makeMetatable(l: *Thread, comptime name: []const u8, comptime methods: []const aux.Reg, gcf: state.NativeFn, tostr: state.NativeFn) Error!void {
    const mt = try l.newTable(0, 8);
    try l.push(Value.obj(.table, mt));
    defer l.top -= 1;
    const m = try aux.newLib(l, .methods, "network:" ++ name, methods);
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
pub fn newObject(l: *Thread, comptime T: type, comptime name: []const u8, init: T) Error!*T {
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

pub fn toObject(l: *Thread, comptime T: type, comptime name: []const u8, v: Value) ?*T {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    if (u.metatable != metatableOf(l, name)) return null;
    return @ptrCast(@alignCast(u.data()));
}

pub fn checkSocket(l: *Thread, i: u32) Error!*Socket {
    const s = toObject(l, Socket, socket_name, l.arg(i)) orelse return aux.typeError(l, i, socket_name);
    if (s.closed) return l.raiseFmt("attempt to use a closed socket", .{});
    return s;
}

/// Raises when a coroutine closed the socket while its caller, which
/// kept the stack, ran the scheduler.
pub fn stillOpen(l: *Thread, s: *Socket) Error!void {
    if (s.closed) return l.raiseFmt("attempt to use a closed socket", .{});
}

pub fn checkServer(l: *Thread, i: u32) Error!*Server {
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

pub fn checkPort(l: *Thread, i: u32, allow_zero: bool) Error!u16 {
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
pub fn hostPort(buf: []u8, host: []const u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port }) catch host;
}

// ---------------------------------------------------------------------
// Errors

/// The message the C library gives for the error a socket call failed
/// with, so messages read the same on every platform.
pub fn errText(err: anyerror) []const u8 {
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
    if (timeout_ms < 0) return .ready;
    if (is_windows) return if (sched.pollOne(handle, if (for_write) .write else .read, timeout_ms)) .ready else .timeout;
    var fds = [_]posix.pollfd{.{
        .fd = handle,
        .events = if (for_write) posix.POLL.OUT else posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms) catch return .failed;
    return if (n == 0) .timeout else .ready;
}

/// True when an operation on a socket with this timeout may block in its
/// system call: nothing bounds it, and no coroutine could run while it
/// waits.
pub inline fn blocksPlainly(l: *Thread, timeout_ms: i32) bool {
    return timeout_ms < 0 and !sched.active(l.g);
}

/// Waits until `handle` is ready, through the scheduler. Raises
/// "`what` timeout" when the timeout of the socket runs out first.
pub fn awaitIo(l: *Thread, handle: net.Socket.Handle, dir: sched.Dir, timeout_ms: i32, comptime what: []const u8) Error!void {
    if (!try sched.waitIo(l, handle, dir, timeout_ms)) return l.raiseFmt(what ++ " timeout", .{});
}

/// What a system call that never waits reports.
pub const Try = union(enum) { n: usize, again, fail: anyerror };

fn sockError(e: posix.E) anyerror {
    return switch (e) {
        .CONNRESET => error.ConnectionResetByPeer,
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NOTCONN => error.SocketUnconnected,
        .PIPE => error.BrokenPipe,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .NETDOWN => error.NetworkDown,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .ACCES, .PERM => error.AccessDenied,
        .NOBUFS, .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .MSGSIZE => error.MessageOversize,
        else => error.Unexpected,
    };
}

/// Puts the handle of a socket in non-blocking mode. A send with
/// MSG_DONTWAIT alone still blocks on some systems once it has written a
/// part of its data.
fn unblock(s: *Socket) void {
    if (s.nonblocking) return;
    setNonblocking(s.stream.socket.handle, true);
    s.nonblocking = true;
}

/// Reads what the socket holds now, at most `dst.len` bytes.
pub fn tryRecv(l: *Thread, s: *Socket, dst: []u8) Try {
    const handle = s.stream.socket.handle;
    if (comptime is_windows) {
        if (!sched.readyNow(handle, .read)) return .again;
        const n = readSome(l.g.io, s.stream, dst) catch |e| return .{ .fail = e };
        return .{ .n = n };
    }
    unblock(s);
    while (true) {
        const rc = posix.system.recv(handle, dst.ptr, dst.len, posix.MSG.DONTWAIT);
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .n = @intCast(rc) },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .fail = sockError(e) },
        }
    }
}

/// Writes what the socket takes now of `data`.
pub fn trySend(l: *Thread, s: *Socket, data: []const u8) Try {
    const handle = s.stream.socket.handle;
    if (comptime is_windows) {
        if (!sched.readyNow(handle, .write)) return .again;
        return afd.sendNow(l.g.io, handle, data);
    }
    unblock(s);
    const flags: u32 = posix.MSG.DONTWAIT | if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
    while (true) {
        const rc = posix.system.send(handle, data.ptr, data.len, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .n = @intCast(rc) },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .fail = sockError(e) },
        }
    }
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

/// The local address of a socket, through getsockname. On Windows the
/// AFD driver reports it, since the standard library opens sockets as AFD
/// endpoints that Winsock never registers.
fn localAddress(io: Io, handle: net.Socket.Handle, fallback: net.IpAddress) net.IpAddress {
    if (comptime is_windows) return afd.localAddress(io, handle) orelse fallback;
    var storage: Io.Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(handle, &storage.any, &len)) != .SUCCESS) return fallback;
    return Io.Threaded.addressFromPosix(&storage);
}

fn closeHandle(handle: net.Socket.Handle) void {
    if (comptime is_windows) return;
    _ = posix.system.close(handle);
}

fn setNonblocking(fd: posix.fd_t, on: bool) void {
    if (comptime is_windows) return;
    const bit: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    const cur = posix.system.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (cur < 0) return;
    const next = if (on) cur | bit else cur & ~bit;
    if (next != cur) _ = posix.system.fcntl(fd, posix.F.SETFL, next);
}

/// A connection attempt that waits through the scheduler. It lives in the
/// scheduler record of its thread, so it survives the runs of
/// `network.tcp.connect` and is released when the thread is closed.
const Connecting = struct {
    addrs: [max_addresses]net.IpAddress = undefined,
    n: usize = 0,
    i: usize = 0,
    fd: posix.fd_t = -1,
    last: anyerror = error.ConnectionRefused,

    fn release(g: *state.Global, ctx: *anyopaque) void {
        const c: *Connecting = @ptrCast(@alignCast(ctx));
        c.drop(g);
        g.gpa.destroy(c);
    }

    fn drop(c: *Connecting, g: *state.Global) void {
        if (c.fd < 0) return;
        sched.forget(g, c.fd);
        closeHandle(c.fd);
        c.fd = -1;
    }
};

/// Starts a connection to `a` on a new socket that never blocks. Returns
/// true when the connection is already established.
fn startConnect(a: *const net.IpAddress, out: *posix.fd_t) !bool {
    const Threaded = Io.Threaded;
    const cloexec: u32 = if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(Threaded.posixAddressFamily(a), posix.SOCK.STREAM | cloexec, posix.IPPROTO.TCP);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| return sockError(e),
    }
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeHandle(fd);
    if (cloexec == 0) _ = posix.system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    setNonblocking(fd, true);
    var storage: Threaded.PosixAddress = undefined;
    const len = Threaded.addressToPosix(a, &storage);
    while (true) {
        switch (posix.errno(posix.system.connect(fd, &storage.any, len))) {
            .SUCCESS, .ISCONN => {
                out.* = fd;
                return true;
            },
            .INTR => continue,
            .INPROGRESS, .AGAIN => {
                out.* = fd;
                return false;
            },
            else => |e| return sockError(e),
        }
    }
}

/// The error a connection attempt ended with, or null when it succeeded.
fn connectResult(fd: posix.fd_t) ?anyerror {
    var code: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &code, &len)) != .SUCCESS) return error.Unexpected;
    if (code == 0) return null;
    return sockError(@fromBackingInt(@intCast(code)));
}

/// `connectHost` for a thread that shares the state with detached
/// coroutines: the attempt waits through the scheduler.
fn connectScheduled(l: *Thread, host: []const u8, port: u16) Error!struct { net.Stream, net.IpAddress } {
    const g = l.g;
    const t = try sched.ensureTask(l);
    var c: *Connecting = undefined;
    if (sched.restarted(l) and t.ctx != null) {
        c = @ptrCast(@alignCast(t.ctx.?));
    } else {
        c = g.gpa.create(Connecting) catch return l.raiseMem();
        c.* = .{};
        errdefer g.gpa.destroy(c);
        c.n = (try resolve(l, host, port, null, &c.addrs)).len;
        t.ctx = c;
        t.cancel = Connecting.release;
    }
    // Every way out other than a suspension ends the attempt.
    defer if (!l.yielding) {
        t.ctx = null;
        t.cancel = null;
        c.drop(g);
        g.gpa.destroy(c);
    };
    while (c.i < c.n) {
        const a = &c.addrs[c.i];
        var done = false;
        if (c.fd < 0) {
            done = startConnect(a, &c.fd) catch |e| {
                c.last = e;
                c.i += 1;
                continue;
            };
        }
        if (!done) {
            if (!sched.readyNow(c.fd, .write)) {
                _ = try sched.waitIo(l, c.fd, .write, -1);
                continue;
            }
            if (connectResult(c.fd)) |e| {
                c.drop(g);
                c.last = e;
                c.i += 1;
                continue;
            }
        }
        const fd = c.fd;
        sched.forget(g, fd);
        c.fd = -1;
        setNonblocking(fd, false);
        noSigpipe(fd);
        return .{ .{ .socket = .{ .handle = fd, .address = localAddress(l.g.io, fd, a.*) } }, a.* };
    }
    return l.raiseFmt("cannot connect to {s}:{d}: {s}", .{ host, port, errText(c.last) });
}

const ListenError = error{ AccessDenied, AddressInUse, AddressUnavailable, AddressFamilyUnsupported, SystemResources, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

/// Creates a listening TCP socket. On POSIX systems it sets SO_REUSEADDR
/// alone, so a port can be bound again right after a close while a second
/// live bind still fails. `std.Io` would also set SO_REUSEPORT, which lets
/// two sockets bind the same port. On Windows the socket binds for
/// exclusive use, so a second bind fails there too.
const Stage = enum { bind, listen };

fn listenTcp(io: Io, addr: *const net.IpAddress, backlog: u31, stage: *Stage) !net.Server {
    stage.* = .bind;
    if (comptime is_windows) return afd.listen(io, addr, backlog, stage);
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

/// TCP sockets through the AFD driver, for what `std.Io` leaves out on
/// Windows. The standard library opens every socket as an AFD endpoint
/// and binds a listening socket with the shared mode of SO_REUSEADDR, so
/// a second socket could bind the same port. These listeners bind with
/// the exclusive mode of SO_EXCLUSIVEADDRUSE instead.
const afd = if (is_windows) struct {
    const w = std.os.windows;
    const Threaded = Io.Threaded;

    /// The share mode of a bind request that matches SO_EXCLUSIVEADDRUSE.
    const share_exclusive: w.AFD.BIND_INFO.MODE = @fromBackingInt(@intCast(3));
    /// SO_EXCLUSIVEADDRUSE, which Winsock defines as `~SO_REUSEADDR`.
    const so_exclusiveaddruse: u32 = ~@as(u32, w.ws2_32.SO.REUSEADDR);

    fn request(io: Io, handle: net.Socket.Handle, code: w.CTL_CODE, in: []const u8, out: []u8) !w.IO_STATUS_BLOCK {
        const r = try io.operate(.{ .device_io_control = .{
            .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
            .code = code,
            .in = in,
            .out = out,
        } });
        return r.device_io_control;
    }

    fn control(io: Io, handle: net.Socket.Handle, code: w.CTL_CODE, in: []const u8, out: []u8) !w.NTSTATUS {
        return (try request(io, handle, code, in, out)).u.Status;
    }

    /// Opens a TCP endpoint for the family of `addr`, as `std.Io` does.
    fn openStream(addr: *const net.IpAddress) !net.Socket.Handle {
        var handle: w.HANDLE = undefined;
        var iosb: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtCreateFile(
            &handle,
            .{
                .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true },
                .GENERIC = .{ .WRITE = true, .READ = true },
            },
            &.{
                .ObjectName = @constCast(&w.UNICODE_STRING.init(
                    w.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' },
                )),
            },
            &iosb,
            null,
            .{},
            .{ .READ = true, .WRITE = true },
            .OPEN_IF,
            .{ .IO = .ASYNCHRONOUS },
            &w.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
                .EndpointType = .{},
                .GroupID = 0,
                .AddressFamily = Threaded.posixAddressFamily(addr),
                .SocketType = posix.SOCK.STREAM,
                .Protocol = posix.IPPROTO.TCP,
                .TransportDeviceNameLength = 0,
                .TransportDeviceName = undefined,
            } },
            @sizeOf(w.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
        );
        return switch (status) {
            .SUCCESS => handle,
            .PROTOCOL_NOT_SUPPORTED => error.AddressFamilyUnsupported,
            .INSUFFICIENT_RESOURCES => error.SystemResources,
            else => error.Unexpected,
        };
    }

    /// Sets a boolean socket option. A driver that refuses it leaves the
    /// endpoint as it was.
    fn enable(io: Io, handle: net.Socket.Handle, optname: u32) void {
        const one: w.BOOL = .TRUE;
        _ = control(io, handle, w.IOCTL.AFD.SOCKOPT, std.mem.asBytes(&w.AFD.SOCKOPT_INFO{
            .mode = .set,
            .level = w.ws2_32.SOL.SOCKET,
            .optname = optname,
            .optval = &one,
            .optlen = @sizeOf(w.BOOL),
        }), &.{}) catch {};
    }

    /// Binds an endpoint to `addr` and returns the address it received.
    fn bindTo(io: Io, handle: net.Socket.Handle, addr: *const net.IpAddress, mode: w.AFD.BIND_INFO.MODE) !net.IpAddress {
        const Bind = extern struct { info: w.AFD.BIND_INFO, address: Threaded.PosixAddress };
        var bind: Bind = .{ .info = .{ .Mode = mode }, .address = undefined };
        const len = Threaded.addressToPosix(addr, &bind.address);
        const in = @as([]const u8, @ptrCast(&bind))[0 .. @offsetOf(Bind, "address") + len];
        const out = @as([]u8, @ptrCast(&bind.address))[0..len];
        switch (try control(io, handle, w.IOCTL.AFD.BIND, in, out)) {
            .SUCCESS => {},
            .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => return error.AddressInUse,
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_ADDRESS_COMPONENT, .INVALID_ADDRESS => return error.AddressUnavailable,
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        return Threaded.addressFromPosix(&bind.address);
    }

    /// The flag of a send request that makes the driver answer at once: it
    /// takes what its buffer has room for, or reports that the endpoint is
    /// not ready. Winsock sets it for a socket in non-blocking mode.
    const immediate: u32 = 0x4;
    /// The most bytes one send request carries, so that a send on a
    /// driver that queues a whole request stays short.
    const send_chunk = 64 * 1024;

    /// Writes what the endpoint takes now of `data`.
    fn sendNow(io: Io, handle: net.Socket.Handle, data: []const u8) Try {
        if (data.len == 0) return .{ .n = 0 };
        const part = data[0..@min(data.len, send_chunk)];
        const bufs = [_]w.AFD.WSABUF(.@"const"){.{ .len = @intCast(part.len), .buf = part.ptr }};
        const plain: u32 = @bitCast(w.AFD{ .NO_FAST_IO = true, .OVERLAPPED = true });
        const info: w.AFD.SEND_INFO = .{
            .BufferArray = &bufs,
            .BufferCount = 1,
            .AfdFlags = @bitCast(plain | immediate),
            .TdiFlags = .{},
        };
        const iosb = request(io, handle, w.IOCTL.AFD.SEND, std.mem.asBytes(&info), &.{}) catch |e| return .{ .fail = e };
        return switch (iosb.u.Status) {
            .SUCCESS => if (iosb.Information == 0) .again else .{ .n = iosb.Information },
            .DEVICE_NOT_READY, .CANT_WAIT => .again,
            .INSUFFICIENT_RESOURCES => .{ .fail = error.SystemResources },
            .CONNECTION_RESET, .CONNECTION_ABORTED, .REMOTE_DISCONNECT, .LOCAL_DISCONNECT => .{ .fail = error.ConnectionResetByPeer },
            .IO_TIMEOUT => .{ .fail = error.ConnectionTimedOut },
            else => .{ .fail = error.Unexpected },
        };
    }

    extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: w.BOOL, initial_state: w.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, ms: u32) callconv(.winapi) u32;

    /// How long a connection attempt waits before it looks at its request
    /// again, in milliseconds. The poll for the endpoint ends the wait
    /// earlier when the driver reports the end of the attempt there.
    const connect_tick_ms = 20;

    /// A connection attempt that waits through the scheduler. It lives in
    /// the scheduler record of its thread, like `Connecting`. The connect
    /// request stays with the driver while the thread waits, so the
    /// record holds what the request writes to: its status block and the
    /// event that the driver sets when the request ends.
    const Attempt = struct {
        const Target = extern struct { reserved: [3]usize = @splat(0), address: Threaded.PosixAddress };

        addrs: [max_addresses]net.IpAddress = undefined,
        n: usize = 0,
        i: usize = 0,
        last: anyerror = error.ConnectionRefused,
        handle: ?w.HANDLE = null,
        event: ?w.HANDLE = null,
        /// True while the driver holds the request.
        pending: bool = false,
        iosb: w.IO_STATUS_BLOCK = undefined,
        target: Target = .{ .address = undefined },
        local: net.IpAddress = undefined,

        fn release(g: *state.Global, ctx: *anyopaque) void {
            const c: *Attempt = @ptrCast(@alignCast(ctx));
            c.drop(g);
            if (c.event) |e| w.CloseHandle(e);
            g.gpa.destroy(c);
        }

        /// Ends the attempt on the current address. A request that the
        /// driver still holds is canceled, and the driver has let go of
        /// the status block once the event is set.
        fn drop(c: *Attempt, g: *state.Global) void {
            const h = c.handle orelse return;
            if (c.pending) {
                var cancel_iosb: w.IO_STATUS_BLOCK = undefined;
                _ = w.ntdll.NtCancelIoFileEx(h, &c.iosb, &cancel_iosb);
                _ = WaitForSingleObject(c.event.?, 0xFFFF_FFFF);
                c.pending = false;
            }
            sched.forget(g, h);
            w.CloseHandle(h);
            c.handle = null;
        }

        /// Opens an endpoint and hands the driver a connect request for
        /// `a` that it completes later.
        fn start(c: *Attempt, io: Io, a: *const net.IpAddress) !void {
            if (c.event == null) c.event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
            const h = try openStream(a);
            errdefer w.CloseHandle(h);
            enable(io, h, w.ws2_32.SO.REUSE_UNICASTPORT);
            const any: net.IpAddress = switch (a.*) {
                .ip4 => .{ .ip4 = .unspecified(0) },
                .ip6 => .{ .ip6 = .unspecified(0) },
            };
            c.local = try bindTo(io, h, &any, .Active);
            c.target = .{ .address = undefined };
            const len = Threaded.addressToPosix(a, &c.target.address);
            const size: u32 = @intCast(@offsetOf(Target, "address") + len);
            // The call resets the event before it queues the request.
            const status = w.ntdll.NtDeviceIoControlFile(h, c.event.?, null, null, &c.iosb, w.IOCTL.AFD.CONNECT, &c.target, size, null, 0);
            c.pending = status == .PENDING;
            // A request that the driver refused at once wrote no status.
            if (status != .PENDING and status != .SUCCESS) c.iosb.u.Status = status;
            c.handle = h;
        }

        /// True once the driver ended the request.
        fn done(c: *Attempt) bool {
            if (!c.pending) return true;
            if (WaitForSingleObject(c.event.?, 0) != 0) return false;
            c.pending = false;
            return true;
        }

        /// The error the request ended with, or null when it connected.
        fn result(c: *Attempt) ?anyerror {
            return switch (c.iosb.u.Status) {
                .SUCCESS => null,
                .CONNECTION_REFUSED, .PORT_CONNECTION_REFUSED => error.ConnectionRefused,
                .IO_TIMEOUT, .TIMEOUT => error.ConnectionTimedOut,
                .NETWORK_UNREACHABLE => error.NetworkUnreachable,
                .HOST_UNREACHABLE => error.HostUnreachable,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                .CONNECTION_RESET, .CONNECTION_ABORTED => error.ConnectionResetByPeer,
                else => error.Unexpected,
            };
        }
    };

    /// `connectHost` for a thread that shares the state with detached
    /// coroutines. The connect request of each address goes to the driver
    /// without waiting for its end, and the thread waits through the
    /// scheduler until the driver set the event of the request. An
    /// address whose request cannot be made this way, or ends in a way
    /// the driver does not explain, connects through the standard
    /// library, which waits in the call.
    fn connectScheduled(l: *Thread, host: []const u8, port: u16) Error!struct { net.Stream, net.IpAddress } {
        const g = l.g;
        const io = g.io;
        const t = try sched.ensureTask(l);
        var c: *Attempt = undefined;
        if (sched.restarted(l) and t.ctx != null) {
            c = @ptrCast(@alignCast(t.ctx.?));
        } else {
            c = g.gpa.create(Attempt) catch return l.raiseMem();
            c.* = .{};
            errdefer g.gpa.destroy(c);
            c.n = (try resolve(l, host, port, null, &c.addrs)).len;
            t.ctx = c;
            t.cancel = Attempt.release;
        }
        // Every way out other than a suspension ends the attempt.
        defer if (!l.yielding) {
            t.ctx = null;
            t.cancel = null;
            Attempt.release(g, c);
        };
        while (c.i < c.n) {
            const a = &c.addrs[c.i];
            var failed: ?anyerror = null;
            if (c.handle == null) c.start(io, a) catch {
                failed = error.Unexpected;
            };
            if (failed == null) {
                if (!c.done()) {
                    // Each wait is short and has a deadline of its own.
                    sched.opDone(l);
                    _ = try sched.waitIo(l, c.handle.?, .write, connect_tick_ms);
                    continue;
                }
                failed = c.result();
            }
            if (failed) |e| {
                c.drop(g);
                c.last = e;
                // A request that ended in a way the driver does not
                // explain is made again by the standard library.
                if (e == error.Unexpected) {
                    if (a.connect(io, .{ .mode = .stream, .protocol = .tcp })) |connected| {
                        var stream = connected;
                        stream.socket.address = afd.localAddress(io, stream.socket.handle) orelse stream.socket.address;
                        return .{ stream, a.* };
                    } else |e2| {
                        c.last = e2;
                    }
                }
                c.i += 1;
                continue;
            }
            const handle = c.handle.?;
            sched.forget(g, handle);
            c.handle = null;
            return .{ .{ .socket = .{ .handle = handle, .address = afd.localAddress(io, handle) orelse c.local } }, a.* };
        }
        return l.raiseFmt("cannot connect to {s}:{d}: {s}", .{ host, port, errText(c.last) });
    }

    fn listen(io: Io, addr: *const net.IpAddress, backlog: u31, stage: *Stage) !net.Server {
        const handle = try openStream(addr);
        errdefer w.CloseHandle(handle);
        // The option and the share mode of the bind ask for the same
        // exclusivity. A driver that refuses the option still honors the
        // share mode.
        enable(io, handle, so_exclusiveaddruse);
        const bound = try bindTo(io, handle, addr, share_exclusive);
        stage.* = .listen;
        const info: w.AFD.LISTEN_INFO = .{ .UseSAN = .FALSE, .MaximumConnectionQueue = backlog, .UseDelayedAcceptance = .FALSE };
        switch (try control(io, handle, w.IOCTL.AFD.START_LISTEN, std.mem.asBytes(&info), &.{})) {
            .SUCCESS => {},
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        return .{
            .socket = .{ .handle = handle, .address = bound },
            .options = .{ .mode = .stream, .protocol = .tcp },
        };
    }

    /// The local address of an endpoint, through IOCTL_AFD_GET_ADDRESS,
    /// which fills in a socket address as getsockname does. Null unless
    /// the driver reports a whole IPv4 or IPv6 address.
    fn localAddress(io: Io, handle: net.Socket.Handle) ?net.IpAddress {
        var storage: Threaded.PosixAddress = undefined;
        @memset(std.mem.asBytes(&storage), 0);
        const iosb = request(io, handle, w.IOCTL.AFD.GET_ADDRESS, &.{}, std.mem.asBytes(&storage)) catch return null;
        if (iosb.u.Status != .SUCCESS) return null;
        const size: usize = switch (storage.any.family) {
            posix.AF.INET => @sizeOf(posix.sockaddr.in),
            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
            else => return null,
        };
        if (iosb.Information != size) return null;
        return Threaded.addressFromPosix(&storage);
    }
} else struct {};

/// Formats the numeric address of `a` without its port.
pub fn formatIp(buf: []u8, a: net.IpAddress) []const u8 {
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
    if (sched.active(l.g) or sched.restarted(l)) {
        if (comptime is_windows) return afd.connectScheduled(l, host, port);
        return connectScheduled(l, host, port);
    }
    var addrs: [max_addresses]net.IpAddress = undefined;
    const list = try resolve(l, host, port, null, &addrs);
    var last: anyerror = error.ConnectionRefused;
    for (list) |*a| {
        var stream = a.connect(l.g.io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            last = e;
            continue;
        };
        // The standard library on Windows reports the wildcard address the
        // socket was bound to before it connected.
        if (comptime is_windows) stream.socket.address = localAddress(l.g.io, stream.socket.handle, stream.socket.address);
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
    _ = try bindServer(l, host, port, backlog);
    return 1;
}

/// Binds a listening socket and pushes its server, as `network.tcp.bind`
/// does.
pub fn bindServer(l: *Thread, host: []const u8, port: u16, backlog: i64) Error!*Server {
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
    return newObject(l, Server, server_name, .{ .server = server });
}

fn socketSend(l: *Thread) Error!u32 {
    const s = try checkSocket(l, 1);
    const data = try checkData(l, 2);
    const io = l.g.io;
    const h = s.stream.socket.handle;
    // A send that waited continues after the bytes it already wrote.
    var total: usize = @min(sched.progress(l), data.len);
    while (total < data.len) {
        const chunk = @min(data.len - total, std.math.maxInt(i32));
        if (!s.nonblocking and blocksPlainly(l, s.timeout_ms)) {
            total += writeSome(io, h, data[total..][0..chunk]) catch |e| return failResult(l, "send", e);
            continue;
        }
        switch (trySend(l, s, data[total..][0..chunk])) {
            .n => |n| {
                total += n;
                sched.opDone(l);
            },
            .again => {
                try sched.saveProgress(l, total);
                try awaitIo(l, h, .write, s.timeout_ms, "send");
                try stillOpen(l, s);
            },
            .fail => |e| return failResult(l, "send", e),
        }
    }
    return aux.retInt(l, @intCast(total));
}

pub const Fill = union(enum) { got: usize, eof, fail: anyerror };

/// Reads up to `max` more bytes into the socket buffer, waiting at most
/// the socket timeout. Raises "receive timeout" when it expires.
pub fn fill(l: *Thread, s: *Socket, max: usize) Error!Fill {
    return (try tryFill(l, s, max)) orelse l.raiseFmt("receive timeout", .{});
}

/// Reads up to `max` more bytes into the socket buffer, waiting at most
/// the socket timeout. Returns null when it expires.
pub fn tryFill(l: *Thread, s: *Socket, max: usize) Error!?Fill {
    s.buf.ensureUnusedCapacity(l.g.gpa, max) catch return l.raiseMem();
    const dst = s.buf.unusedCapacitySlice()[0..max];
    var n: usize = 0;
    if (!s.nonblocking and blocksPlainly(l, s.timeout_ms)) {
        n = readSome(l.g.io, s.stream, dst) catch |e| return .{ .fail = e };
    } else while (true) {
        switch (tryRecv(l, s, dst)) {
            .n => |got| {
                n = got;
                sched.opDone(l);
                break;
            },
            // The bytes already read stay in the buffer of the socket, so
            // the receive that runs again continues from them.
            .again => {
                if (!try sched.waitIo(l, s.stream.socket.handle, .read, s.timeout_ms)) return null;
                try stillOpen(l, s);
                // The buffer may have moved while other coroutines ran.
                return tryFill(l, s, max);
            },
            .fail => |e| return .{ .fail = e },
        }
    }
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
    releaseSocket(l, s);
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
/// Closes the socket of a connection at the end of the drain time of its
/// server.
pub fn drainSocket(l: *Thread, s: *Socket) void {
    if (s.closed) return;
    s.drained = true;
    releaseSocket(l, s);
}

fn closeSocket(l: *Thread, s: *Socket) void {
    if (s.closed) return;
    const io = l.g.io;
    s.stream.shutdown(io, .send) catch {};
    if (!is_windows) {
        var tmp: [1024]u8 = undefined;
        var budget: usize = 1024;
        while (budget > 0) : (budget -= 1) {
            if (s.nonblocking) {
                switch (tryRecv(l, s, &tmp)) {
                    .n => |n| if (n == 0) break,
                    .again, .fail => break,
                }
                continue;
            }
            if (waitHandle(s.stream.socket.handle, false, 0) != .ready) break;
            const n = readSome(io, s.stream, &tmp) catch break;
            if (n == 0) break;
        }
    }
    releaseSocket(l, s);
}

/// Closes the handle of a socket and frees what the socket holds.
/// Coroutines that wait for the socket run again and find it closed.
fn releaseSocket(l: *Thread, s: *Socket) void {
    sched.forget(l.g, s.stream.socket.handle);
    s.stream.close(l.g.io);
    if (s.owner) |server| {
        unlinkConnection(server, s);
        s.owner = null;
        server.live -= 1;
        // The coroutine that ends a drain stops once every connection is
        // closed.
        if (server.draining) sched.signal(l.g);
        // A `network.serve` that waits for a free place accepts again.
        if (server.full) {
            server.full = false;
            sched.signal(l.g);
        }
    }
    s.buf.deinit(l.g.gpa);
    s.buf = .empty;
    if (s.http) |h| {
        h.deinit(l.g.gpa);
        l.g.gpa.destroy(h);
        s.http = null;
    }
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
    _ = acceptOne(l, s) catch |e| switch (e) {
        error.LusError, error.MetaCall => |x| return x,
        else => return failResult(l, "accept", e),
    };
    return 1;
}

/// Accepts one connection and pushes its socket. It waits for a
/// connection the way `accept` does, and returns the error of the system
/// call when that fails.
pub fn acceptOne(l: *Thread, s: *Server) !*Socket {
    const h = s.server.socket.handle;
    if (!blocksPlainly(l, s.timeout_ms)) {
        while (!sched.readyNow(h, .read)) {
            try awaitIo(l, h, .read, s.timeout_ms, "accept");
            if (s.closed) return l.raiseFmt("attempt to use a closed server", .{});
        }
    }
    const stream = try s.server.accept(l.g.io);
    errdefer stream.close(l.g.io);
    noSigpipe(stream.socket.handle);
    const local = localAddress(l.g.io, stream.socket.handle, s.server.socket.address);
    return newObject(l, Socket, socket_name, .{ .stream = stream, .local = local, .peer = stream.socket.address });
}

pub fn closeServer(l: *Thread, s: *Server) void {
    closeServerIn(l.g, s);
}

pub fn closeServerIn(g: *state.Global, s: *Server) void {
    if (s.closed) return;
    sched.forget(g, s.server.socket.handle);
    s.server.socket.close(g.io);
    s.closed = true;
    // A `network.serve` that waits for a free place finds the server
    // closed.
    if (s.full) {
        s.full = false;
        sched.signal(g);
    }
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
    if (!blocksPlainly(l, s.timeout_ms)) {
        while (!sched.readyNow(s.socket.handle, .write)) {
            try awaitIo(l, s.socket.handle, .write, s.timeout_ms, "sendto");
            if (s.closed) return l.raiseFmt("attempt to use a closed UDP socket", .{});
        }
    }
    s.socket.send(l.g.io, &list[0], data) catch |e| return failResult(l, "sendto", e);
    return aux.retInt(l, @intCast(data.len));
}

/// The largest datagram UDP carries: a 16-bit length minus its header.
const max_datagram = 65535;

fn udpReceive(l: *Thread) Error!u32 {
    const s = try checkUdp(l, 1);
    const size = try aux.optInt(l, 2, default_udp_size);
    if (size <= 0 or size > max_recv_size) return l.raiseFmt("invalid receive size: {d}", .{size});
    if (!blocksPlainly(l, s.timeout_ms)) {
        while (!sched.readyNow(s.socket.handle, .read)) {
            try awaitIo(l, s.socket.handle, .read, s.timeout_ms, "receive");
            if (s.closed) return l.raiseFmt("attempt to use a closed UDP socket", .{});
        }
    }
    // The buffer holds any datagram, and the call keeps the first `size`
    // bytes of it. POSIX truncates a datagram to the buffer quietly, but
    // Windows fails the receive with a buffer that is too small and drops
    // the datagram, so a short buffer would lose data there.
    const gpa = l.g.gpa;
    const want: usize = @intCast(size);
    const buf = gpa.alloc(u8, @max(want, max_datagram)) catch return l.raiseMem();
    defer gpa.free(buf);
    const msg = s.socket.receive(l.g.io, buf) catch |e| return failResult(l, "recvfrom", e);
    try l.push(Value.obj(.vector, try vector.newVector(l, msg.data[0..@min(msg.data.len, want)])));
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
    sched.forget(l.g, s.socket.handle);
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
    sched.forget(l.g, s.socket.handle);
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
    /// The thread that reads, which waits through the scheduler when it
    /// is set.
    thread: ?*Thread = null,

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
        const wait: Wait = if (r.thread) |l| blk: {
            // With detached coroutines alive, a caller that cannot suspend
            // runs the scheduler while it waits, so a `network.serve` of
            // the same state answers.
            if (!sched.active(l.g) or sched.canSuspend(l)) break :blk waitHandle(r.stream.socket.handle, false, r.timeout_ms);
            const ready = sched.waitIo(l, r.stream.socket.handle, .read, r.timeout_ms) catch break :blk .failed;
            break :blk if (ready) .ready else .timeout;
        } else waitHandle(r.stream.socket.handle, false, r.timeout_ms);
        switch (wait) {
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
/// Stores a response header in `t`. A header that repeats joins its
/// earlier values with ", ", as HTTP allows for a field that appears more
/// than once.
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

fn buildRequest(l: *Thread, req: *std.ArrayList(u8), method: []const u8, u: ParsedUrl, body: ?[]const u8) Error!void {
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
    c.sr.thread = l;
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
    // A response to HEAD, and a 1xx, 204 or 304 response, ends after its
    // headers, whatever Content-Length says (RFC 9112, section 6.3).
    const no_body = std.ascii.eqlIgnoreCase(method, "HEAD") or status == 204 or status == 304 or (status >= 100 and status < 200);
    if (no_body) {} else if (chunked) {
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
