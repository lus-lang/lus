//! TLS over the sockets of the `network` library, for `network.tls`,
//! HTTPS in `network.fetch`, and `network.serve` with TLS. The protocol is
//! the vendored Mbed TLS, reached through the small C interface of
//! `src/tls/shim.c`.
//!
//! A TLS socket is an ordinary socket whose `tls` field holds a
//! connection. The connection moves bytes through two callbacks that read
//! and write the socket without waiting. When the socket is not ready, the
//! callback says so, Mbed TLS returns from the call with a code that asks
//! for reading or writing, and the operation of the socket waits through
//! the scheduler for that direction, like the operations of a plain
//! socket. A native that runs again after a wait calls Mbed TLS again,
//! which continues where it stopped, so the handshake, a receive, and a
//! send are suspension points.
//!
//! The certificates of the system load once per process, the first time a
//! connection verifies a server without a certificate authority of its
//! own, and every connection shares them.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const sched = @import("../vm/sched.zig");
const aux = @import("auxlib.zig");
const net = @import("network.zig");
const faultio = @import("../vm/faultio.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

pub const Chain = opaque {};
pub const Config = opaque {};
pub const Conn = opaque {};

const SendFn = *const fn (ctx: ?*anyopaque, buf: [*]const u8, len: usize) callconv(.c) c_int;
const RecvFn = *const fn (ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(.c) c_int;

extern fn lus_tls_init() c_int;
extern fn lus_tls_strerror(code: c_int, buf: [*]u8, size: usize) void;
extern fn lus_tls_chain_new() ?*Chain;
extern fn lus_tls_chain_free(c: ?*Chain) void;
extern fn lus_tls_chain_add_der(c: *Chain, der: [*]const u8, len: usize) c_int;
extern fn lus_tls_chain_add_pem(c: *Chain, pem: [*]const u8, len: usize) c_int;
extern fn lus_tls_chain_count(c: *const Chain) c_int;
extern fn lus_tls_config_new(server: c_int) ?*Config;
extern fn lus_tls_config_free(cfg: ?*Config) void;
extern fn lus_tls_config_ca(cfg: *Config, ca: *Chain, owned: c_int) void;
extern fn lus_tls_config_verify(cfg: *Config, verify: c_int) void;
extern fn lus_tls_config_own(cfg: *Config, cert: [*]const u8, cert_len: usize, key: [*]const u8, key_len: usize, password: ?[*]const u8, password_len: usize, which: *c_int) c_int;
extern fn lus_tls_config_alpn(cfg: *Config, text: [*]const u8, len: usize, n: c_int) c_int;
extern fn lus_tls_new(cfg: *Config, servername: ?[*:0]const u8, io: ?*anyopaque, send: SendFn, recv: RecvFn, err: *c_int) ?*Conn;
extern fn lus_tls_free(t: ?*Conn) void;
extern fn lus_tls_set_io(t: *Conn, io: ?*anyopaque, send: SendFn, recv: RecvFn) void;
extern fn lus_tls_handshake(t: *Conn) c_int;
extern fn lus_tls_handshake_done(t: *Conn) c_int;
extern fn lus_tls_read(t: *Conn, buf: [*]u8, len: usize) c_int;
extern fn lus_tls_write(t: *Conn, buf: [*]const u8, len: usize) c_int;
extern fn lus_tls_pending(t: *Conn) usize;
extern fn lus_tls_close_notify(t: *Conn) c_int;
extern fn lus_tls_verify_info(t: *Conn, buf: [*]u8, size: usize) void;
extern fn lus_tls_version(t: *Conn) ?[*:0]const u8;
extern fn lus_tls_cipher(t: *Conn) ?[*:0]const u8;
extern fn lus_tls_alpn(t: *Conn) ?[*:0]const u8;
extern fn lus_tls_servername(t: *Conn) ?[*:0]const u8;

const want_read: c_int = -0x6900;
const want_write: c_int = -0x6880;
const peer_close_notify: c_int = -0x7880;
const conn_eof: c_int = -0x7280;
const new_session_ticket: c_int = -0x7B00;
const net_recv_failed: c_int = -0x004C;
const net_send_failed: c_int = -0x004E;
const x509_verify_failed: c_int = -0x2700;

/// The largest piece of plain text that one call hands Mbed TLS.
const max_write = 16384;

// ---------------------------------------------------------------------
// The process

var init_lock: std.atomic.Mutex = .unlocked;
var init_done: enum(u8) { no, ok, failed } = .no;
var system_lock: std.atomic.Mutex = .unlocked;
var system_chain: ?*Chain = null;

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// Sets up Mbed TLS for the process, once. Returns false when it failed.
fn initProcess() bool {
    if (@atomicLoad(@TypeOf(init_done), &init_done, .acquire) == .ok) return true;
    spinLock(&init_lock);
    defer init_lock.unlock();
    if (init_done == .no) @atomicStore(@TypeOf(init_done), &init_done, if (lus_tls_init() == 0) .ok else .failed, .release);
    return init_done == .ok;
}

fn ensureInit(l: *Thread) Error!void {
    if (!initProcess()) return l.raiseFmt("TLS is unavailable: the cryptography library failed to start", .{});
}

/// The certificates of the system on FreeBSD. The bundle of the
/// ca_root_nss package is at /etc/ssl/cert.pem or under /usr/local. The
/// base system keeps its trusted certificates in /etc/ssl/certs, which
/// certctl fills. The first bundle found is read, or else the directory.
fn rescanFreebsd(cb: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp) !void {
    const files = [_][]const u8{ "/etc/ssl/cert.pem", "/usr/local/etc/ssl/cert.pem", "/usr/local/share/certs/ca-root-nss.crt" };
    cb.bytes.clearRetainingCapacity();
    cb.map.clearRetainingCapacity();
    for (files) |path| {
        if (cb.addCertsFromFilePathAbsolute(gpa, io, now, path)) |_| return else |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        }
    }
    try cb.addCertsFromDirPathAbsolute(gpa, io, now, "/etc/ssl/certs");
}

/// The certificates of the system, loaded on first use and kept for the
/// life of the process.
fn systemChain(l: *Thread) Error!*Chain {
    spinLock(&system_lock);
    defer system_lock.unlock();
    if (system_chain) |c| return c;
    const gpa = std.heap.page_allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    const io = l.g.io;
    const scan = if (builtin.os.tag == .freebsd) rescanFreebsd else std.crypto.Certificate.Bundle.rescan;
    scan(&bundle, gpa, io, std.Io.Clock.real.now(io)) catch |e|
        return l.raiseFmt("cannot load the certificates of the system: {s}", .{@errorName(e)});
    const chain = lus_tls_chain_new() orelse return l.raiseMem();
    const bytes = bundle.bytes.items;
    var it = bundle.map.valueIterator();
    while (it.next()) |start| {
        const elem = std.crypto.Certificate.der.Element.parse(bytes, start.*) catch continue;
        // A certificate that Mbed TLS cannot read is left out.
        _ = lus_tls_chain_add_der(chain, bytes[start.*..].ptr, elem.slice.end - start.*);
    }
    system_chain = chain;
    return chain;
}

// ---------------------------------------------------------------------
// Errors

/// The text of the last TLS failure of this thread, which `errText` of
/// the network library reports for `error.TlsFailure`.
threadlocal var last_buf: [320]u8 = undefined;
threadlocal var last_len: usize = 0;
/// The `code` of the last TLS failure: "certificate" for a certificate
/// that did not verify, "tls" for anything else.
threadlocal var last_cert = false;

pub fn lastCode() []const u8 {
    return if (last_cert) "certificate" else "tls";
}

pub fn lastMessage() []const u8 {
    return if (last_len == 0) "TLS failure" else last_buf[0..last_len];
}

fn setMessage(comptime fmt: []const u8, args: anytype) void {
    last_cert = false;
    const s = std.fmt.bufPrint(&last_buf, fmt, args) catch &last_buf;
    last_len = s.len;
}

fn codeText(code: c_int, buf: []u8) []const u8 {
    lus_tls_strerror(code, buf.ptr, buf.len);
    const s = std.mem.sliceTo(buf, 0);
    // Mbed TLS prefixes its texts with the module, such as "SSL - ".
    return if (std.mem.indexOf(u8, s, " - ")) |i| s[i + 3 ..] else s;
}

// ---------------------------------------------------------------------
// Connections

/// The TLS state of a socket.
pub const Tls = struct {
    conn: *Conn,
    /// The socket and the thread that the callbacks of the running call
    /// read and write through.
    sock: *net.Socket,
    thread: *Thread,
    /// The direction that the last call that could not finish waits for.
    want: sched.Dir = .read,
    /// The failure of the socket that ended the last call.
    io_err: ?anyerror = null,
    handshaken: bool = false,
    /// The name that a client checks the certificate of the server
    /// against, for its error messages.
    servername: [256]u8 = undefined,
    servername_len: usize = 0,
};

fn sendCb(ctx: ?*anyopaque, buf: [*]const u8, len: usize) callconv(.c) c_int {
    const t: *Tls = @ptrCast(@alignCast(ctx.?));
    const n = @min(len, std.math.maxInt(i32));
    switch (net.rawSend(t.thread, t.sock, buf[0..n])) {
        .n => |got| return @intCast(got),
        .again => {
            t.want = .write;
            return want_write;
        },
        .fail => |e| {
            t.io_err = e;
            return net_send_failed;
        },
    }
}

fn recvCb(ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(.c) c_int {
    const t: *Tls = @ptrCast(@alignCast(ctx.?));
    const n = @min(len, std.math.maxInt(i32));
    switch (net.rawRecv(t.thread, t.sock, buf[0..n])) {
        .n => |got| {
            // The fault build damages one chunk of the record layer.
            if (got > 0 and faultio.netStep(&.{.tls_receive}) != null) buf[got / 2] ^= 0x10;
            return @intCast(got);
        },
        .again => {
            t.want = .read;
            return want_read;
        },
        .fail => |e| {
            t.io_err = e;
            return net_recv_failed;
        },
    }
}

/// Points the callbacks of the connection of `s` at `l` and `s` for the
/// call that follows.
fn bind(l: *Thread, s: *net.Socket) *Tls {
    const t = s.tls.?;
    t.thread = l;
    t.sock = s;
    t.io_err = null;
    return t;
}

/// Starts TLS on `s` under `cfg`, which the connection keeps alive. A
/// client sends `servername` in SNI and checks the certificate against it.
pub fn attach(l: *Thread, s: *net.Socket, cfg: *Config, servername: ?[]const u8) Error!void {
    const gpa = l.g.gpa;
    const t = gpa.create(Tls) catch return l.raiseMem();
    t.* = .{ .conn = undefined, .sock = s, .thread = l };
    var name_z: [257]u8 = undefined;
    var name_ptr: ?[*:0]const u8 = null;
    if (servername) |n| {
        if (n.len > 255 or std.mem.indexOfScalar(u8, n, 0) != null) {
            gpa.destroy(t);
            return l.raiseFmt("invalid server name", .{});
        }
        @memcpy(name_z[0..n.len], n);
        name_z[n.len] = 0;
        name_ptr = name_z[0..n.len :0];
        @memcpy(t.servername[0..n.len], n);
        t.servername_len = n.len;
    }
    var err: c_int = 0;
    t.conn = lus_tls_new(cfg, name_ptr, t, sendCb, recvCb, &err) orelse {
        gpa.destroy(t);
        var buf: [160]u8 = undefined;
        return l.raiseFmt("cannot start TLS: {s}", .{codeText(err, &buf)});
    };
    s.tls = t;
}

/// Frees the TLS state of `s`, after one attempt to tell the peer that
/// the connection closes.
pub fn detach(l: *Thread, s: *net.Socket) void {
    const t = s.tls orelse return;
    if (t.handshaken) {
        _ = bind(l, s);
        _ = lus_tls_close_notify(t.conn);
    }
    lus_tls_free(t.conn);
    l.g.gpa.destroy(t);
    s.tls = null;
}

/// Frees the TLS state of `s` without a word to the peer, for a socket
/// that closes abruptly.
pub fn drop(l: *Thread, s: *net.Socket) void {
    const t = s.tls orelse return;
    lus_tls_free(t.conn);
    l.g.gpa.destroy(t);
    s.tls = null;
}

/// The direction that an operation on `s` waits for after it could not
/// finish: what TLS asked for, or `default` for a plain socket.
pub fn waitDir(s: *net.Socket, default: sched.Dir) sched.Dir {
    return if (s.tls) |t| t.want else default;
}

/// Describes a failed call of Mbed TLS for `error.TlsFailure`.
fn fail(t: *Tls, code: c_int) net.Try {
    if (t.io_err) |e| return .{ .fail = e };
    var buf: [160]u8 = undefined;
    setMessage("TLS: {s}", .{codeText(code, &buf)});
    return .{ .fail = error.TlsFailure };
}

/// Reads plain text into `dst` without waiting. Returns 0 at the end of
/// the stream, which a close_notify of the peer or the end of the TCP
/// stream marks.
pub fn recv(l: *Thread, s: *net.Socket, dst: []u8) net.Try {
    const t = bind(l, s);
    const n = @min(dst.len, std.math.maxInt(i32));
    while (true) {
        const r = lus_tls_read(t.conn, dst.ptr, n);
        if (r > 0) {
            t.handshaken = true;
            return .{ .n = @intCast(r) };
        }
        switch (r) {
            0, peer_close_notify, conn_eof => return .{ .n = 0 },
            want_read, want_write => return .again,
            new_session_ticket => continue,
            else => {
                if (t.io_err) |e| {
                    if (e == error.ConnectionResetByPeer and lus_tls_handshake_done(t.conn) != 0) return .{ .n = 0 };
                }
                return handshakeFail(t, r);
            },
        }
    }
}

/// Writes plain text from `data` without waiting. A call that returned
/// `again` must run again with the same data, since TLS may already hold
/// a part of it.
pub fn send(l: *Thread, s: *net.Socket, data: []const u8) net.Try {
    const t = bind(l, s);
    const n = @min(data.len, max_write);
    const r = lus_tls_write(t.conn, data.ptr, n);
    if (r >= 0) {
        t.handshaken = true;
        return .{ .n = @intCast(r) };
    }
    return switch (r) {
        want_read, want_write => .again,
        else => handshakeFail(t, r),
    };
}

/// A failure that may come from the handshake: a certificate that did not
/// verify names the reason.
fn handshakeFail(t: *Tls, code: c_int) net.Try {
    if (t.io_err == null and lus_tls_handshake_done(t.conn) == 0) {
        var info: [256]u8 = undefined;
        lus_tls_verify_info(t.conn, &info, info.len);
        const why = std.mem.sliceTo(&info, 0);
        if (why.len > 0 or code == x509_verify_failed) {
            setMessage("certificate verification failed for {s}: {s}", .{ t.servername[0..t.servername_len], if (why.len > 0) why else "untrusted certificate" });
            last_cert = true;
            return .{ .fail = error.TlsFailure };
        }
        var buf: [160]u8 = undefined;
        setMessage("TLS handshake failed: {s}", .{codeText(code, &buf)});
        return .{ .fail = error.TlsFailure };
    }
    return fail(t, code);
}

/// Runs the handshake of `s` to its end, waiting through the scheduler.
/// A native that runs again after a wait calls it again, and it continues.
/// Each wait lasts at most the timeout of the socket, or, when `deadline`
/// is not zero, until that time on the clock of `sched.now`. Returns false
/// when a wait runs out.
pub fn handshake(l: *Thread, s: *net.Socket, deadline: u64) Error!bool {
    while (true) {
        const t = bind(l, s);
        if (t.handshaken) return true;
        const r = lus_tls_handshake(t.conn);
        if (r == 0) {
            t.handshaken = true;
            sched.opDone(l);
            return true;
        }
        if (r == want_read or r == want_write) {
            var wait = s.timeout_ms;
            if (deadline != 0) {
                const now = sched.now(l.g);
                if (now >= deadline) return false;
                wait = @intCast(@min((deadline - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32)));
            }
            if (!try sched.waitIo(l, s.stream.socket.handle, t.want, wait)) return false;
            try net.stillOpen(l, s);
            continue;
        }
        switch (handshakeFail(t, r)) {
            // A failure of the socket itself names its reason.
            .fail => |e| if (e != error.TlsFailure) return net.raiseFail(l, net.errCode(e), 0, "TLS handshake failed: {s}", .{net.errText(e)}),
            else => {},
        }
        return net.raiseFail(l, lastCode(), 0, "{s}", .{lastMessage()});
    }
}

/// tlsinfo(): the version, the cipher suite, the protocol that ALPN
/// chose, and the server name of a TLS socket, or nil for a plain one.
pub fn pushInfo(l: *Thread, s: *net.Socket) Error!u32 {
    const t = s.tls orelse return aux.retNil(l);
    const info = try l.newTable(0, 4);
    try l.push(Value.obj(.table, info));
    if (t.handshaken) {
        if (lus_tls_version(t.conn)) |v| try aux.setField(l, info, "version", try l.newStringValue(std.mem.span(v)));
        if (lus_tls_cipher(t.conn)) |v| try aux.setField(l, info, "cipher", try l.newStringValue(std.mem.span(v)));
        if (lus_tls_alpn(t.conn)) |v| try aux.setField(l, info, "alpn", try l.newStringValue(std.mem.span(v)));
    }
    if (lus_tls_servername(t.conn)) |v| try aux.setField(l, info, "servername", try l.newStringValue(std.mem.span(v)));
    return 1;
}

// ---------------------------------------------------------------------
// Configurations

/// What the options of a client connection set besides its configuration.
pub const ClientOptions = struct {
    servername: ?[]const u8 = null,
    timeout_ms: ?i32 = null,
};

fn fieldString(l: *Thread, i: u32, name: []const u8, v: Value) Error![]const u8 {
    return switch (v.tag) {
        .string => v.as(object.String).bytes(),
        .vector => v.as(object.Vector).bytes.items,
        else => aux.argError(l, i, "{s} must be a string", .{name}),
    };
}

/// Reads the list of ALPN protocols in `v` into the configuration.
fn setAlpn(l: *Thread, i: u32, cfg: *Config, v: Value) Error!void {
    if (v.tag != .table) return aux.argError(l, i, "alpn must be a list of strings", .{});
    const list = v.as(Table);
    const n = table.length(list);
    if (n < 1 or n > 16) return aux.argError(l, i, "alpn must list between 1 and 16 protocols", .{});
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(l.g.gpa);
    var k: i64 = 1;
    while (k <= n) : (k += 1) {
        const p = table.getInt(list, k);
        if (p.tag != .string) return aux.argError(l, i, "alpn must be a list of strings", .{});
        const b = p.as(object.String).bytes();
        if (b.len == 0 or b.len > 255 or std.mem.indexOfScalar(u8, b, 0) != null) return aux.argError(l, i, "invalid ALPN protocol name", .{});
        text.appendSlice(l.g.gpa, b) catch return l.raiseMem();
        text.append(l.g.gpa, 0) catch return l.raiseMem();
    }
    if (lus_tls_config_alpn(cfg, text.items.ptr, text.items.len, @intCast(n)) != 0) return l.raiseMem();
}

/// Trusts the certificates of the PEM text `pem`.
fn setCa(l: *Thread, i: u32, cfg: *Config, pem: []const u8) Error!void {
    const chain = lus_tls_chain_new() orelse return l.raiseMem();
    const r = lus_tls_chain_add_pem(chain, pem.ptr, pem.len);
    if (r < 0 or lus_tls_chain_count(chain) == 0) {
        lus_tls_chain_free(chain);
        var buf: [160]u8 = undefined;
        return aux.argError(l, i, "ca holds no certificate that parses: {s}", .{codeText(r, &buf)});
    }
    lus_tls_config_ca(cfg, chain, 1);
}

/// Adds a certificate of this end with its key.
fn addOwn(l: *Thread, i: u32, cfg: *Config, cert: []const u8, key: []const u8, password: ?[]const u8) Error!void {
    var which: c_int = 0;
    const pw = password orelse "";
    const r = lus_tls_config_own(cfg, cert.ptr, cert.len, key.ptr, key.len, if (password != null) pw.ptr else null, pw.len, &which);
    if (r == 0) return;
    var buf: [160]u8 = undefined;
    return switch (which) {
        1 => aux.argError(l, i, "invalid certificate: {s}", .{codeText(r, &buf)}),
        2 => aux.argError(l, i, "invalid private key: {s}", .{codeText(r, &buf)}),
        else => aux.argError(l, i, "too many certificates", .{}),
    };
}

fn timeoutMs(l: *Thread, i: u32, v: Value) Error!i32 {
    const secs: f64 = switch (v.tag) {
        .integer => @floatFromInt(v.asInt()),
        .float => v.asFloat(),
        else => return aux.argError(l, i, "timeout must be a number of seconds", .{}),
    };
    if (std.math.isNan(secs)) return aux.argError(l, i, "timeout must be a number of seconds", .{});
    if (secs < 0) return -1;
    const ms = @ceil(secs * 1000);
    return if (ms >= std.math.maxInt(i32)) std.math.maxInt(i32) else @intFromFloat(ms);
}

/// Builds the configuration of a client from the options table in
/// argument `i`, when there is one. `default_name` is the host it
/// connects to. With `allow_timeout`, the options may also set `timeout`.
pub fn clientConfig(l: *Thread, i: u32, default_name: ?[]const u8, allow_timeout: bool, out: *ClientOptions) Error!*Config {
    const v: Value = if (l.hasArg(i)) l.arg(i) else .nil;
    if (!v.isNil() and v.tag != .table) _ = try aux.checkTable(l, i);
    return clientConfigFrom(l, i, v, default_name, allow_timeout, out);
}

/// Builds the configuration of a client from the options table `v`, nil
/// for none, which came in argument `i`.
pub fn clientConfigFrom(l: *Thread, i: u32, v: Value, default_name: ?[]const u8, allow_timeout: bool, out: *ClientOptions) Error!*Config {
    try ensureInit(l);
    const cfg = lus_tls_config_new(0) orelse return l.raiseMem();
    errdefer lus_tls_config_free(cfg);
    out.servername = default_name;
    var verify = true;
    var has_ca = false;
    var cert: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    if (!v.isNil()) {
        if (v.tag != .table) return aux.argError(l, i, "tls must be a table", .{});
        const t = v.as(Table);
        var k: Value = .nil;
        while (table.next(t, k) catch null) |e| : (k = e.key) {
            const name = if (e.key.tag == .string) e.key.as(object.String).bytes() else "";
            if (std.mem.eql(u8, name, "servername")) {
                out.servername = try fieldString(l, i, name, e.val);
            } else if (std.mem.eql(u8, name, "alpn")) {
                try setAlpn(l, i, cfg, e.val);
            } else if (std.mem.eql(u8, name, "ca")) {
                try setCa(l, i, cfg, try fieldString(l, i, name, e.val));
                has_ca = true;
            } else if (std.mem.eql(u8, name, "cert")) {
                cert = try fieldString(l, i, name, e.val);
            } else if (std.mem.eql(u8, name, "key")) {
                key = try fieldString(l, i, name, e.val);
            } else if (std.mem.eql(u8, name, "password")) {
                password = try fieldString(l, i, name, e.val);
            } else if (std.mem.eql(u8, name, "verify")) {
                if (e.val.tag != .true and e.val.tag != .false) return aux.argError(l, i, "verify must be a boolean", .{});
                verify = e.val.tag == .true;
            } else if (allow_timeout and std.mem.eql(u8, name, "timeout")) {
                out.timeout_ms = try timeoutMs(l, i, e.val);
            } else {
                return aux.argError(l, i, "unknown option '{s}'", .{name});
            }
        }
    }
    if ((cert == null) != (key == null)) return aux.argError(l, i, "cert and key go together", .{});
    if (cert) |c| try addOwn(l, i, cfg, c, key.?, password);
    // A certificate is checked against a name, so a connection that
    // verifies needs one.
    if (verify and out.servername == null) return aux.argError(l, i, "servername is required", .{});
    lus_tls_config_verify(cfg, @intFromBool(verify));
    if (verify and !has_ca) lus_tls_config_ca(cfg, try systemChain(l), 0);
    return cfg;
}

/// The configuration of an HTTPS client for `host`, as `network.fetch`
/// uses it: the `tls` option of fetch in `v`, nil for none, which came in
/// argument `i`, and HTTP/1.1 through ALPN.
pub fn httpsConfig(l: *Thread, i: u32, v: Value, host: []const u8, out: *ClientOptions) Error!*Config {
    const cfg = try clientConfigFrom(l, i, v, host, false, out);
    errdefer lus_tls_config_free(cfg);
    const alpn = "http/1.1\x00";
    if (lus_tls_config_alpn(cfg, alpn.ptr, alpn.len, 1) != 0) return l.raiseMem();
    return cfg;
}

/// Builds the configuration of a server from the `tls` option of
/// `network.serve` in `v`: a table with `cert`, `key`, and `password`, or
/// a list of such tables, one for each name that SNI may ask for.
pub fn serverConfig(l: *Thread, i: u32, v: Value) Error!*Config {
    try ensureInit(l);
    if (v.tag != .table) return aux.argError(l, i, "tls must be a table", .{});
    const cfg = lus_tls_config_new(1) orelse return l.raiseMem();
    errdefer lus_tls_config_free(cfg);
    const t = v.as(Table);
    const n = table.length(t);
    if (n == 0) {
        try serverEntry(l, i, cfg, t);
    } else {
        var k: i64 = 1;
        while (k <= n) : (k += 1) {
            const e = table.getInt(t, k);
            if (e.tag != .table) return aux.argError(l, i, "tls must list tables with cert and key", .{});
            try serverEntry(l, i, cfg, e.as(Table));
        }
    }
    const alpn = "http/1.1\x00";
    if (lus_tls_config_alpn(cfg, alpn.ptr, alpn.len, 1) != 0) return l.raiseMem();
    return cfg;
}

fn serverEntry(l: *Thread, i: u32, cfg: *Config, t: *Table) Error!void {
    var cert: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var k: Value = .nil;
    while (table.next(t, k) catch null) |e| : (k = e.key) {
        const name = if (e.key.tag == .string) e.key.as(object.String).bytes() else "";
        if (std.mem.eql(u8, name, "cert")) {
            cert = try fieldString(l, i, "tls.cert", e.val);
        } else if (std.mem.eql(u8, name, "key")) {
            key = try fieldString(l, i, "tls.key", e.val);
        } else if (std.mem.eql(u8, name, "password")) {
            password = try fieldString(l, i, "tls.password", e.val);
        } else {
            return aux.argError(l, i, "unknown tls option '{s}'", .{name});
        }
    }
    if (cert == null or key == null) return aux.argError(l, i, "tls needs cert and key", .{});
    try addOwn(l, i, cfg, cert.?, key.?, password);
}

pub fn freeConfig(cfg: *Config) void {
    lus_tls_config_free(cfg);
}

/// Builds the configuration of a server from the options of
/// `sock:starttls` in `t`: `cert`, `key`, and `password` for one
/// certificate, or `certs`, a list of such tables, one for each name that
/// SNI may ask for, and `alpn`, the protocols the server accepts.
fn rawServerConfig(l: *Thread, i: u32, t: *Table) Error!*Config {
    try ensureInit(l);
    const cfg = lus_tls_config_new(1) orelse return l.raiseMem();
    errdefer lus_tls_config_free(cfg);
    var cert: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var list: ?*Table = null;
    var k: Value = .nil;
    while (table.next(t, k) catch null) |e| : (k = e.key) {
        const name = if (e.key.tag == .string) e.key.as(object.String).bytes() else "";
        if (std.mem.eql(u8, name, "server")) {
            continue;
        } else if (std.mem.eql(u8, name, "cert")) {
            cert = try fieldString(l, i, name, e.val);
        } else if (std.mem.eql(u8, name, "key")) {
            key = try fieldString(l, i, name, e.val);
        } else if (std.mem.eql(u8, name, "password")) {
            password = try fieldString(l, i, name, e.val);
        } else if (std.mem.eql(u8, name, "certs")) {
            if (e.val.tag != .table) return aux.argError(l, i, "certs must be a list of tables with cert and key", .{});
            list = e.val.as(Table);
        } else if (std.mem.eql(u8, name, "alpn")) {
            try setAlpn(l, i, cfg, e.val);
        } else {
            return aux.argError(l, i, "unknown option '{s}'", .{name});
        }
    }
    if ((cert == null) != (key == null)) return aux.argError(l, i, "cert and key go together", .{});
    if (cert) |c| try addOwn(l, i, cfg, c, key.?, password);
    if (list) |lt| {
        const n = table.length(lt);
        var j: i64 = 1;
        while (j <= n) : (j += 1) {
            const e = table.getInt(lt, j);
            if (e.tag != .table) return aux.argError(l, i, "certs must be a list of tables with cert and key", .{});
            try serverEntry(l, i, cfg, e.as(Table));
        }
    }
    if (cert == null and list == null) return aux.argError(l, i, "a server needs cert and key, or certs", .{});
    return cfg;
}

const config_name = "network.tlsconfig";
const cache_key = "network.tls.servers";

fn configGc(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.tag != .userdata) return 0;
    const u = v.as(object.Userdata);
    // Only a configuration holds this state behind this metatable.
    const own: ?*Table = if (l.g.ext.get(config_name)) |p| @ptrCast(@alignCast(p)) else null;
    if (own == null or u.metatable != own or u.size != @sizeOf(?*Config)) return 0;
    const slot: *?*Config = @ptrCast(@alignCast(u.data()));
    if (slot.*) |cfg| lus_tls_config_free(cfg);
    slot.* = null;
    return 0;
}

/// The table that maps the options tables of `sock:starttls` to the server
/// configurations built from them. Its keys are weak, so a configuration
/// lives as long as its options table.
fn serverCache(l: *Thread) Error!*Table {
    const g = l.g;
    if (g.ext.get(cache_key)) |p| return @ptrCast(@alignCast(p));
    const cache = try l.newTable(0, 4);
    try l.push(Value.obj(.table, cache));
    defer l.top -= 1;
    const mode = try l.newTable(0, 1);
    try l.push(Value.obj(.table, mode));
    try aux.setField(l, mode, "__mode", try l.newStringValue("k"));
    l.top -= 1;
    cache.metatable = mode;
    @import("../vm/gc.zig").barrierBack(g, &cache.hdr);
    const mt = try l.newTable(0, 2);
    try l.push(Value.obj(.table, mt));
    try aux.setField(l, mt, "__gc", try aux.native(l, configGc, "gc"));
    try aux.setField(l, mt, "__name", try l.newStringValue(config_name));
    try aux.lockMetatable(l, mt);
    try aux.setField(l, g.registry.as(Table), config_name, Value.obj(.table, mt));
    g.ext.put(g.gpa, config_name, mt) catch return l.raiseMem();
    l.top -= 1;
    try aux.setField(l, g.registry.as(Table), cache_key, Value.obj(.table, cache));
    g.ext.put(g.gpa, cache_key, cache) catch return l.raiseMem();
    return cache;
}

/// The server configuration of the options table in argument `i` of
/// `sock:starttls`. The certificates load once for each options table, so
/// a server that passes one table to every connection parses them once,
/// and a new table loads new certificates.
pub fn serverConfigOf(l: *Thread, i: u32) Error!*Config {
    const t = try aux.checkTable(l, i);
    const cache = try serverCache(l);
    const found = table.get(cache, Value.obj(.table, t));
    if (found.tag == .userdata) {
        const slot: *?*Config = @ptrCast(@alignCast(found.as(object.Userdata).data()));
        if (slot.*) |cfg| return cfg;
    }
    const cfg = try rawServerConfig(l, i, t);
    const g = l.g;
    const mt: *Table = @ptrCast(@alignCast(g.ext.get(config_name).?));
    const gcm = @import("../vm/gc.zig");
    gcm.maybeCollect(g);
    const u = gcm.alloc(g, object.Userdata, .userdata, object.Userdata.allocSize(@sizeOf(?*Config), 0)) catch {
        lus_tls_config_free(cfg);
        return l.raiseMem();
    };
    u.size = @sizeOf(?*Config);
    u.nuser = 0;
    u.metatable = mt;
    const slot: *?*Config = @ptrCast(@alignCast(u.data()));
    slot.* = cfg;
    try l.push(Value.obj(.userdata, u));
    defer l.top -= 1;
    try @import("base.zig").registerFinalizer(l, &u.hdr, mt);
    try @import("../vm/ops.zig").rawSet(l, cache, Value.obj(.table, t), Value.obj(.userdata, u));
    return cfg;
}

// ---------------------------------------------------------------------
// Connections in memory, for the unit tests and the fuzz targets

/// A TLS endpoint whose peer is a byte buffer: what it sends collects in
/// `out`, and what it receives comes from `in`.
pub const MemoryEnd = struct {
    conn: *Conn,
    in: []const u8 = &.{},
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// Reports the end of the stream when `in` runs out, in place of
    /// asking to wait.
    eof_at_end: bool = false,

    fn sendMem(ctx: ?*anyopaque, buf: [*]const u8, len: usize) callconv(.c) c_int {
        const m: *MemoryEnd = @ptrCast(@alignCast(ctx.?));
        const n = @min(len, 1 << 20);
        m.out.appendSlice(m.gpa, buf[0..n]) catch return net_send_failed;
        return @intCast(n);
    }

    fn recvMem(ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(.c) c_int {
        const m: *MemoryEnd = @ptrCast(@alignCast(ctx.?));
        const rest = m.in.len - m.in_pos;
        if (rest == 0) return if (m.eof_at_end) 0 else want_read;
        const n = @min(@min(len, rest), 1 << 20);
        @memcpy(buf[0..n], m.in[m.in_pos..][0..n]);
        m.in_pos += n;
        return @intCast(n);
    }

    pub fn init(m: *MemoryEnd, cfg: *Config, servername: ?[*:0]const u8) !void {
        if (!initProcess()) return error.TlsUnavailable;
        var err: c_int = 0;
        m.conn = lus_tls_new(cfg, servername, m, sendMem, recvMem, &err) orelse return error.TlsUnavailable;
    }

    pub fn deinit(m: *MemoryEnd) void {
        lus_tls_free(m.conn);
        m.out.deinit(m.gpa);
    }

    /// Runs the handshake as far as the input allows. Returns 0 when it
    /// finished, `want_read` when it needs more input, or an error code.
    pub fn step(m: *MemoryEnd) c_int {
        return lus_tls_handshake(m.conn);
    }

    pub fn read(m: *MemoryEnd, buf: []u8) c_int {
        return lus_tls_read(m.conn, buf.ptr, buf.len);
    }

    pub fn write(m: *MemoryEnd, data: []const u8) c_int {
        return lus_tls_write(m.conn, data.ptr, data.len);
    }
};

extern fn lus_tls_test_identity(cn: [*:0]const u8, cert: [*]u8, cert_cap: usize, key: [*]u8, key_cap: usize) c_int;

/// A key and a self-signed certificate for `cn`, as PEM text, which the
/// unit tests and the fuzz targets make when they run.
pub const TestIdentity = struct {
    cert: [4096]u8 = undefined,
    key: [1024]u8 = undefined,

    pub fn make(id: *TestIdentity, cn: [*:0]const u8) !void {
        if (!initProcess()) return error.TlsUnavailable;
        if (lus_tls_test_identity(cn, &id.cert, id.cert.len, &id.key, id.key.len) != 0) return error.TlsFailure;
    }

    pub fn certPem(id: *const TestIdentity) []const u8 {
        return std.mem.sliceTo(&id.cert, 0);
    }

    pub fn keyPem(id: *const TestIdentity) []const u8 {
        return std.mem.sliceTo(&id.key, 0);
    }
};

/// Gives the server configuration `cfg` the identity `id`.
pub fn memoryOwn(cfg: *Config, id: *const TestIdentity) !void {
    var which: c_int = 0;
    const c = id.certPem();
    const k = id.keyPem();
    if (lus_tls_config_own(cfg, c.ptr, c.len, k.ptr, k.len, null, 0, &which) != 0) return error.TlsFailure;
}

/// Parses `bytes` as PEM certificates, DER certificates, and a private
/// key, for the fuzz targets. Each parse may fail.
pub fn parseAll(bytes: []const u8) void {
    if (!initProcess()) return;
    const chain = lus_tls_chain_new() orelse return;
    defer lus_tls_chain_free(chain);
    _ = lus_tls_chain_add_pem(chain, bytes.ptr, bytes.len);
    _ = lus_tls_chain_add_der(chain, bytes.ptr, bytes.len);
    const cfg = lus_tls_config_new(1) orelse return;
    defer lus_tls_config_free(cfg);
    var which: c_int = 0;
    const half = bytes.len / 2;
    _ = lus_tls_config_own(cfg, bytes.ptr, half, bytes[half..].ptr, bytes.len - half, null, 0, &which);
}

pub fn memoryConfig(server: bool) !*Config {
    if (!initProcess()) return error.TlsUnavailable;
    const cfg = lus_tls_config_new(@intFromBool(server)) orelse return error.OutOfMemory;
    lus_tls_config_verify(cfg, 0);
    return cfg;
}

pub const codes = struct {
    pub const read = want_read;
    pub const write = want_write;
};
