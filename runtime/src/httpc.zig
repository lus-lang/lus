//! A blocking HTTP client for the runtime's own downloads: releases for
//! `lus version` and remote modules for `require` (`spec/design/modules.md`).
//! It is a thin layer over `std.http.Client` that returns the body and the
//! few headers these callers read, and that follows redirects only when the
//! caller's policy accepts the target.
//!
//! `https` URLs verify the server against the system certificate bundle.
//! `http` URLs are accepted only for loopback hosts, so tests and local
//! mirrors need no certificate.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The URL is malformed or uses a scheme or host this client refuses.
    BadUrl,
    /// The connection, the TLS handshake, or the transfer failed.
    Network,
    /// The body is longer than the caller's limit.
    TooLarge,
    /// Too many redirects, or a redirect the policy refused.
    Redirect,
    OutOfMemory,
};

pub const Response = struct {
    status: u16,
    body: []u8,
    /// The final URL after redirects.
    url: []u8,
    content_type: ?[]u8 = null,
    etag: ?[]u8 = null,
    cache_control: ?[]u8 = null,

    pub fn deinit(r: *Response, gpa: Allocator) void {
        gpa.free(r.body);
        gpa.free(r.url);
        if (r.content_type) |s| gpa.free(s);
        if (r.etag) |s| gpa.free(s);
        if (r.cache_control) |s| gpa.free(s);
        r.* = undefined;
    }
};

/// Decides whether a redirect from `from` to `to` may be followed.
pub const RedirectPolicy = *const fn (from: std.Uri, to: std.Uri) bool;

/// Follows any redirect to an acceptable URL.
pub fn anyRedirect(_: std.Uri, _: std.Uri) bool {
    return true;
}

/// Follows a redirect to `https`, and one to plain `http` only from a
/// server on this machine.
pub fn keepsHttps(from: std.Uri, to: std.Uri) bool {
    if (std.ascii.eqlIgnoreCase(to.scheme, "https")) return true;
    var buf: [256]u8 = undefined;
    const h = hostOf(from, &buf) orelse return false;
    return isLoopback(h);
}

/// Follows redirects within the host of the original URL only.
pub fn sameHost(from: std.Uri, to: std.Uri) bool {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const ha = hostOf(from, &a) orelse return false;
    const hb = hostOf(to, &b) orelse return false;
    return std.ascii.eqlIgnoreCase(ha, hb) and from.port == to.port;
}

/// The host of `uri` without percent encoding, or null.
pub fn hostOf(uri: std.Uri, buf: []u8) ?[]const u8 {
    const h = uri.host orelse return null;
    return h.toRaw(buf) catch null;
}

pub fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or std.ascii.eqlIgnoreCase(host, "localhost");
}

/// Whether the client accepts `uri`: `https`, or `http` to a loopback host.
pub fn acceptable(uri: std.Uri) bool {
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var buf: [256]u8 = undefined;
    const h = hostOf(uri, &buf) orelse return false;
    return isLoopback(h);
}

pub const Options = struct {
    headers: []const std.http.Header = &.{},
    max_body: usize = 64 * 1024 * 1024,
    redirect: RedirectPolicy = anyRedirect,
    max_redirects: u8 = 5,
};

pub const Client = struct {
    gpa: Allocator,
    http: std.http.Client,

    pub fn init(gpa: Allocator, io: std.Io) Client {
        return .{ .gpa = gpa, .http = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    /// Sends a GET request for `url` and reads the whole response. Any
    /// status is a success of this function, so the caller decides what
    /// a 404 means.
    pub fn get(c: *Client, url: []const u8, opts: Options) Error!Response {
        const gpa = c.gpa;
        var current = try gpa.dupe(u8, url);
        errdefer gpa.free(current);
        var hops: u8 = 0;
        while (true) {
            const uri = std.Uri.parse(current) catch return error.BadUrl;
            if (!acceptable(uri)) return error.BadUrl;
            var req = c.http.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .extra_headers = opts.headers,
                .keep_alive = false,
                .headers = .{ .user_agent = .{ .override = "lus" }, .accept_encoding = .omit },
            }) catch |e| return mapErr(e);
            defer req.deinit();
            req.sendBodiless() catch return error.Network;
            var resp = req.receiveHead(&.{}) catch return error.Network;
            const status: u16 = @backingInt(resp.head.status);
            if (resp.head.status.class() == .redirect) {
                const loc = resp.head.location orelse return error.Redirect;
                hops += 1;
                if (hops > opts.max_redirects) return error.Redirect;
                const next = resolveRef(gpa, current, loc) catch return error.Redirect;
                errdefer gpa.free(next);
                const next_uri = std.Uri.parse(next) catch return error.Redirect;
                if (!acceptable(next_uri) or !opts.redirect(uri, next_uri)) return error.Redirect;
                gpa.free(current);
                current = next;
                continue;
            }
            var out: Response = .{ .status = status, .body = &.{}, .url = current };
            errdefer {
                if (out.content_type) |s| gpa.free(s);
                if (out.etag) |s| gpa.free(s);
                if (out.cache_control) |s| gpa.free(s);
            }
            if (resp.head.content_type) |ct| out.content_type = try gpa.dupe(u8, ct);
            var hit = resp.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "etag") and out.etag == null) {
                    out.etag = try gpa.dupe(u8, h.value);
                } else if (std.ascii.eqlIgnoreCase(h.name, "cache-control") and out.cache_control == null) {
                    out.cache_control = try gpa.dupe(u8, h.value);
                }
            }
            var body: std.Io.Writer.Allocating = .init(gpa);
            defer body.deinit();
            var transfer: [64]u8 = undefined;
            const r = resp.reader(&transfer);
            _ = r.streamRemaining(&body.writer) catch |e| switch (e) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.Network,
            };
            if (body.written().len > opts.max_body) return error.TooLarge;
            out.body = try body.toOwnedSlice();
            return out;
        }
    }
};

fn mapErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => error.BadUrl,
        else => error.Network,
    };
}

/// Resolves the `Location` value `ref` against `base` and returns the
/// absolute URL.
fn resolveRef(gpa: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const base_uri = try std.Uri.parse(base);
    var buf: [8192]u8 = undefined;
    if (ref.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..ref.len], ref);
    var aux: []u8 = buf[0..];
    const resolved = try std.Uri.resolveInPlace(base_uri, ref.len, &aux);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    resolved.format(&w.writer) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

/// The `max-age` of a `Cache-Control` value in seconds, or null.
pub fn maxAge(cache_control: ?[]const u8) ?u64 {
    const cc = cache_control orelse return null;
    var it = std.mem.splitScalar(u8, cc, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.ascii.startsWithIgnoreCase(p, "max-age=")) {
            return std.fmt.parseInt(u64, p["max-age=".len..], 10) catch null;
        }
    }
    return null;
}

test "loopback and max-age" {
    const t = std.testing;
    try t.expect(acceptable(try std.Uri.parse("http://127.0.0.1:8080/x")));
    try t.expect(!acceptable(try std.Uri.parse("http://example.com/x")));
    try t.expect(acceptable(try std.Uri.parse("https://example.com/x")));
    try t.expectEqual(@as(?u64, 300), maxAge("public, max-age=300"));
    try t.expectEqual(@as(?u64, null), maxAge("no-store"));
}
