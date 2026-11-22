//! Tests and fuzz targets for the TLS layer (`lib/tls.zig` and the
//! vendored Mbed TLS). A client and a server run a handshake in memory,
//! where each reads what the other wrote, with a certificate that the test
//! makes when it runs. The fuzz targets feed bytes to a client that waits
//! for the flight of a server, to a server that waits for the hello of a
//! client, to a connection after its handshake, and to the parsers of
//! certificates and keys. Their seeds are the bytes of a real handshake,
//! recorded when the target starts.

const std = @import("std");
const tls = @import("lib/tls.zig");

const Smith = std.testing.Smith;
const gpa = std.testing.allocator;

const read = tls.codes.read;

/// A client and a server whose handshake runs in memory.
const Pair = struct {
    client: tls.MemoryEnd = .{ .conn = undefined, .gpa = gpa },
    server: tls.MemoryEnd = .{ .conn = undefined, .gpa = gpa },
    client_cfg: *tls.Config,
    server_cfg: *tls.Config,
    /// What each end wrote, in the order the flights went out.
    client_wrote: std.ArrayList(u8) = .empty,
    server_wrote: std.ArrayList(u8) = .empty,

    fn init(p: *Pair, id: *const tls.TestIdentity) !void {
        p.client_cfg = try tls.memoryConfig(false);
        errdefer tls.freeConfig(p.client_cfg);
        p.server_cfg = try tls.memoryConfig(true);
        errdefer tls.freeConfig(p.server_cfg);
        try tls.memoryOwn(p.server_cfg, id);
        try p.client.init(p.client_cfg, "localhost");
        errdefer p.client.deinit();
        try p.server.init(p.server_cfg, null);
    }

    fn deinit(p: *Pair) void {
        p.client.deinit();
        p.server.deinit();
        tls.freeConfig(p.client_cfg);
        tls.freeConfig(p.server_cfg);
        p.client_wrote.deinit(gpa);
        p.server_wrote.deinit(gpa);
    }

    /// Hands what one end wrote to the other and runs both handshakes
    /// until they finish. Fails when either end fails.
    fn handshake(p: *Pair) !void {
        var client_done = false;
        var server_done = false;
        var rounds: usize = 0;
        var c_in: std.ArrayList(u8) = .empty;
        defer c_in.deinit(gpa);
        var s_in: std.ArrayList(u8) = .empty;
        defer s_in.deinit(gpa);
        while (!(client_done and server_done)) : (rounds += 1) {
            if (rounds > 32) return error.HandshakeStuck;
            if (!client_done) {
                const r = p.client.step();
                if (r == 0) client_done = true else if (r != read) return error.ClientFailed;
            }
            try p.client_wrote.appendSlice(gpa, p.client.out.items);
            try s_in.appendSlice(gpa, p.client.out.items);
            p.client.out.clearRetainingCapacity();
            p.server.in = s_in.items;
            if (!server_done) {
                const r = p.server.step();
                if (r == 0) server_done = true else if (r != read) return error.ServerFailed;
            }
            try p.server_wrote.appendSlice(gpa, p.server.out.items);
            try c_in.appendSlice(gpa, p.server.out.items);
            p.server.out.clearRetainingCapacity();
            p.client.in = c_in.items;
        }
        // The input of each end stays valid only for this call.
        p.client.in = &.{};
        p.client.in_pos = 0;
        p.server.in = &.{};
        p.server.in_pos = 0;
    }
};

var identity: ?tls.TestIdentity = null;

fn testIdentity() !*const tls.TestIdentity {
    if (identity == null) {
        identity = .{};
        try identity.?.make("localhost");
    }
    return &identity.?;
}

test "a client and a server finish a handshake and exchange data" {
    var p: Pair = .{ .client_cfg = undefined, .server_cfg = undefined };
    try p.init(try testIdentity());
    defer p.deinit();
    try p.handshake();
    try std.testing.expect(p.client.write("ping") == 4);
    p.server.in = p.client.out.items;
    p.server.in_pos = 0;
    var buf: [64]u8 = undefined;
    var n = p.server.read(&buf);
    // A TLS 1.3 server may first hand over a session ticket, which the
    // read takes in passing.
    if (n < 0) n = p.server.read(&buf);
    try std.testing.expectEqualStrings("ping", buf[0..@intCast(n)]);
}

/// Records the flights of one real handshake, for seeds. The seeds live
/// as long as the process, since every target reads them.
fn recordHandshake(client: *std.ArrayList(u8), server: *std.ArrayList(u8)) !void {
    var p: Pair = .{ .client_cfg = undefined, .server_cfg = undefined };
    try p.init(try testIdentity());
    defer p.deinit();
    try p.handshake();
    try client.appendSlice(std.heap.page_allocator, p.client_wrote.items);
    try server.appendSlice(std.heap.page_allocator, p.server_wrote.items);
}

/// Runs the handshake of `end` over `input`, which ends the stream once
/// it runs out, until it finishes or fails, then reads what follows.
fn drive(end: *tls.MemoryEnd, input: []const u8) void {
    end.in = input;
    end.in_pos = 0;
    end.eof_at_end = true;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const r = end.step();
        end.out.clearRetainingCapacity();
        if (r != read) break;
    }
    var buf: [256]u8 = undefined;
    rounds = 0;
    while (rounds < 64) : (rounds += 1) {
        if (end.read(&buf) <= 0) break;
    }
}

const seeds = struct {
    var client: std.ArrayList(u8) = .empty;
    var server: std.ArrayList(u8) = .empty;
    var recorded = false;

    fn get() ![2][]const u8 {
        if (!recorded) {
            try recordHandshake(&client, &server);
            recorded = true;
        }
        return .{ client.items, server.items };
    }
};

fn sliceInput(smith: *Smith, buf: []u8) []u8 {
    const n = smith.slice(buf);
    return buf[0..n];
}

test "fuzz: a client parses any flight of a server" {
    const s = try seeds.get();
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const input = sliceInput(smith, &buf);
            const cfg = try tls.memoryConfig(false);
            defer tls.freeConfig(cfg);
            var end: tls.MemoryEnd = .{ .conn = undefined, .gpa = gpa };
            try end.init(cfg, "localhost");
            defer end.deinit();
            drive(&end, input);
        }
    }.one, .{ .corpus = &.{ s[1], s[1][0..@min(s[1].len, 128)] } });
}

test "fuzz: a server parses any hello of a client" {
    const s = try seeds.get();
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const input = sliceInput(smith, &buf);
            const cfg = try tls.memoryConfig(true);
            defer tls.freeConfig(cfg);
            try tls.memoryOwn(cfg, try testIdentity());
            var end: tls.MemoryEnd = .{ .conn = undefined, .gpa = gpa };
            try end.init(cfg, null);
            defer end.deinit();
            drive(&end, input);
        }
    }.one, .{ .corpus = &.{ s[0], s[0][0..@min(s[0].len, 64)] } });
}

test "fuzz: a connection parses any record after its handshake" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var p: Pair = .{ .client_cfg = undefined, .server_cfg = undefined };
            try p.init(try testIdentity());
            defer p.deinit();
            try p.handshake();
            // The server writes real records, and the fuzzer changes their
            // bytes before the client reads them.
            _ = p.server.write("first record of data");
            _ = p.server.write("second");
            var records: std.ArrayList(u8) = .empty;
            defer records.deinit(gpa);
            try records.appendSlice(gpa, p.server.out.items);
            const edits = smith.valueRangeAtMost(u8, 0, 8);
            for (0..edits) |_| {
                if (records.items.len == 0) break;
                records.items[smith.index(records.items.len)] = smith.value(u8);
            }
            const keep = if (smith.value(bool)) smith.index(records.items.len + 1) else records.items.len;
            p.client.in = records.items[0..keep];
            p.client.in_pos = 0;
            p.client.eof_at_end = true;
            var buf: [256]u8 = undefined;
            var rounds: usize = 0;
            while (rounds < 16) : (rounds += 1) {
                if (p.client.read(&buf) <= 0) break;
            }
        }
    }.one, .{});
}

test "fuzz: certificates and keys parse or fail" {
    const id = try testIdentity();
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            tls.parseAll(sliceInput(smith, &buf));
        }
    }.one, .{ .corpus = &.{ id.certPem(), id.keyPem() } });
}
