//! The `io` library. File handles are userdata. Regular files use
//! positional reads and writes with a position kept in the handle, so
//! seeking is exact. Pipes and standard input use streaming reads.
//!
//! Text mode reads strings and validates them as WTF-8 (counts in `read`
//! are characters). Binary mode ("b" in the mode string) reads vectors
//! and counts bytes (spec/design/strings.md).

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const gc = @import("../vm/gc.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("auxlib.zig");
const shell = @import("shell.zig");
const out = @import("out.zig");
const vector = @import("vector.zig");
const lexer = @import("../syntax/lexer.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Userdata = object.Userdata;
const String = object.String;
const Table = object.Table;

const Kind = enum { file, pipe, stdin, stdout, stderr };

pub const Handle = struct {
    file: std.Io.File,
    kind: Kind,
    closed: bool = false,
    readable: bool,
    writable: bool,
    append: bool = false,
    binary: bool = false,
    lossy: bool = false,
    pos: u64 = 0,
    /// Read-ahead buffer for streaming inputs and line reads.
    rbuf: std.ArrayList(u8) = .empty,
    rstart: usize = 0,
    eof: bool = false,
    child: ?std.process.Child = null,
};

const handle_name = "FILE*";

pub fn open(l: *Thread) Error!void {
    const io_t = try l.newTable(0, 16);
    try aux.setFuncs(l, io_t, &.{
        .{ .name = "open", .func = ioOpen },
        .{ .name = "close", .func = ioClose },
        .{ .name = "read", .func = ioRead },
        .{ .name = "write", .func = ioWrite },
        .{ .name = "flush", .func = ioFlush },
        .{ .name = "lines", .func = ioLines },
        .{ .name = "input", .func = ioInput },
        .{ .name = "output", .func = ioOutput },
        .{ .name = "type", .func = ioType },
        .{ .name = "popen", .func = ioPopen },
        .{ .name = "tmpfile", .func = ioTmpfile },
    });
    const mt = try l.newTable(0, 8);
    const methods = try aux.newLib(l, &.{
        .{ .name = "close", .func = fClose },
        .{ .name = "flush", .func = fFlush },
        .{ .name = "lines", .func = fLines },
        .{ .name = "read", .func = fRead },
        .{ .name = "seek", .func = fSeek },
        .{ .name = "setvbuf", .func = fSetvbuf },
        .{ .name = "write", .func = fWrite },
    });
    try aux.setField(l, mt, "__index", Value.obj(.table, methods));
    try aux.setField(l, mt, "__name", try l.newStringValue(handle_name));
    try aux.setField(l, mt, "__tostring", try aux.native(l, fToString, "tostring"));
    try aux.setField(l, mt, "__gc", try aux.native(l, fGc, "gc"));
    try aux.setField(l, mt, "__close", try aux.native(l, fGc, "close"));
    // The registry roots the metatable, and the extension map records it
    // for fast lookup.
    const g = l.g;
    try aux.setField(l, g.registry.as(Table), "io.mt", Value.obj(.table, mt));
    g.ext.put(g.gpa, "io.mt", mt) catch return l.raiseMem();
    const stdin = try newHandle(l, .{ .file = std.Io.File.stdin(), .kind = .stdin, .readable = true, .writable = false });
    const stdout = try newHandle(l, .{ .file = std.Io.File.stdout(), .kind = .stdout, .readable = false, .writable = true });
    const stderr = try newHandle(l, .{ .file = std.Io.File.stderr(), .kind = .stderr, .readable = false, .writable = true });
    try aux.setField(l, io_t, "stdin", stdin);
    try aux.setField(l, io_t, "stdout", stdout);
    try aux.setField(l, io_t, "stderr", stderr);
    try setDefault(l, "io.input", stdin);
    try setDefault(l, "io.output", stdout);
    if (@import("build_options").sqlite) try @import("sqlite.zig").register(l, io_t);
    try aux.setGlobal(l, "io", Value.obj(.table, io_t));
}

fn setDefault(l: *Thread, key: []const u8, v: Value) Error!void {
    try aux.setField(l, l.g.registry.as(Table), key, v);
}

fn getDefault(l: *Thread, key: []const u8) Error!Value {
    return aux.getField(l, l.g.registry.as(Table), key);
}

fn newHandle(l: *Thread, h: Handle) Error!Value {
    const g = l.g;
    const u = gc.alloc(g, Userdata, .userdata, Userdata.allocSize(@sizeOf(Handle), 0)) catch return l.raiseMem();
    u.size = @sizeOf(Handle);
    u.nuser = 0;
    const mt: *Table = @ptrCast(@alignCast(g.ext.get("io.mt").?));
    u.metatable = mt;
    const hp: *Handle = @ptrCast(@alignCast(u.data()));
    hp.* = h;
    // Regular files get closed by the collector.
    if (h.kind == .file or h.kind == .pipe) try @import("base.zig").registerFinalizer(l, &u.hdr, mt);
    return Value.obj(.userdata, u);
}

fn toHandle(l: *Thread, v: Value) ?*Handle {
    if (v.tag != .userdata) return null;
    const u = v.as(Userdata);
    const mt: *Table = @ptrCast(@alignCast(l.g.ext.get("io.mt").?));
    if (u.metatable != mt) return null;
    return @ptrCast(@alignCast(u.data()));
}

fn checkHandle(l: *Thread, i: u32) Error!*Handle {
    const h = toHandle(l, l.arg(i)) orelse return aux.typeError(l, i, handle_name);
    if (h.closed) return l.raiseFmt("attempt to use a closed file", .{});
    return h;
}

// ---------------------------------------------------------------------
// Low-level reading

/// Ensures at least `n` unread bytes are buffered, or EOF. Returns the
/// number available.
fn fill(l: *Thread, h: *Handle, n: usize) Error!usize {
    const gpa = l.g.gpa;
    if (h.kind == .stdin) out.flushAll(l.g);
    while (h.rbuf.items.len - h.rstart < n and !h.eof) {
        if (h.rstart > 0 and h.rstart == h.rbuf.items.len) {
            h.rbuf.clearRetainingCapacity();
            h.rstart = 0;
        }
        const old = h.rbuf.items.len;
        h.rbuf.ensureUnusedCapacity(gpa, 64 * 1024) catch return l.raiseMem();
        const dst = h.rbuf.unusedCapacitySlice();
        var bufs = [_][]u8{dst};
        const got = switch (h.kind) {
            .file => h.file.readPositional(l.g.io, &bufs, h.pos + (old - h.rstart)) catch |e| return ioError(l, e),
            else => h.file.readStreaming(l.g.io, &bufs) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => |x| return ioError(l, x),
            },
        };
        if (got == 0) h.eof = true;
        h.rbuf.items.len = old + got;
    }
    return h.rbuf.items.len - h.rstart;
}

fn consume(h: *Handle, n: usize) void {
    h.rstart += n;
    if (h.kind == .file) h.pos += n;
}

fn pending(h: *Handle) []const u8 {
    return h.rbuf.items[h.rstart..];
}

fn ioError(l: *Thread, e: anyerror) Error {
    return l.raiseFmt("{s}", .{@import("os.zig").errnoOf(e).msg});
}

/// Wraps read bytes as a string (text mode, validated) or vector.
fn wrap(l: *Thread, h: *Handle, bytes: []const u8) Error!Value {
    if (h.binary) return Value.obj(.vector, try vector.newVector(l, bytes));
    const a = wtf8.analyze(bytes);
    if (a.valid) return Value.obj(.string, state.newStringKnown(l.g, bytes, a.ascii, a.chars) catch return l.raiseMem());
    if (!h.lossy) return l.raiseFmt("invalid UTF-8 in input at byte {d} (open the file with {{ lossy = true }} or in binary mode)", .{a.error_offset});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    wtf8.appendLossy(l.g.gpa, &buf, bytes) catch return l.raiseMem();
    return l.newStringValue(buf.items);
}

fn readLine(l: *Thread, h: *Handle, keep_nl: bool) Error!?Value {
    var scanned: usize = 0;
    while (true) {
        const avail = pending(h);
        if (std.mem.indexOfScalarPos(u8, avail, scanned, '\n')) |nl| {
            const line = avail[0..if (keep_nl) nl + 1 else nl];
            const v = try wrap(l, h, line);
            consume(h, nl + 1);
            return v;
        }
        scanned = avail.len;
        if (h.eof) break;
        _ = try fill(l, h, avail.len + 1);
        if (pending(h).len == avail.len) break;
    }
    const rest = pending(h);
    if (rest.len == 0) return null;
    const v = try wrap(l, h, rest);
    consume(h, rest.len);
    return v;
}

fn readAll(l: *Thread, h: *Handle) Error!Value {
    while (!h.eof) _ = try fill(l, h, pending(h).len + 64 * 1024);
    const rest = pending(h);
    const v = try wrap(l, h, rest);
    consume(h, rest.len);
    return v;
}

/// Reads `n` characters (text) or bytes (binary).
fn readCount(l: *Thread, h: *Handle, n: usize) Error!?Value {
    if (n == 0) {
        if (try fill(l, h, 1) == 0) return null;
        return try wrap(l, h, "");
    }
    if (h.binary) {
        const got = try fill(l, h, n);
        if (got == 0) return null;
        const take = @min(got, n);
        const v = try wrap(l, h, pending(h)[0..take]);
        consume(h, take);
        return v;
    }
    // Text: count whole characters.
    var bytes: usize = 0;
    var chars: usize = 0;
    while (chars < n) {
        if (try fill(l, h, bytes + 4) <= bytes) break;
        const p = pending(h);
        const len = wtf8.seqLen(p[bytes]);
        if (bytes + len > p.len) {
            bytes = p.len;
            break;
        }
        bytes += len;
        chars += 1;
    }
    if (bytes == 0) return null;
    const v = try wrap(l, h, pending(h)[0..bytes]);
    consume(h, bytes);
    return v;
}

fn readNumber(l: *Thread, h: *Handle) Error!?Value {
    // Skip whitespace, then take the longest numeral prefix.
    while (true) {
        if (try fill(l, h, 1) == 0) return null;
        const c = pending(h)[0];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) consume(h, 1) else break;
    }
    var n: usize = 0;
    while (n < 200) {
        if (try fill(l, h, n + 1) <= n) break;
        const c = pending(h)[n];
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-' or c == '_') n += 1 else break;
    }
    const text = pending(h)[0..n];
    const num = lexer.parseNumber(text);
    consume(h, n);
    if (num) |x| return switch (x) {
        .integer => |i| Value.int(i),
        .float => |f| Value.float(f),
    };
    return null;
}

fn doRead(l: *Thread, h: *Handle, first: u32) Error!u32 {
    if (!h.readable) return failResult(l, "file not opened for reading");
    const nargs = l.argCount();
    if (nargs < first) {
        const v = (try readLine(l, h, false)) orelse return aux.retNil(l);
        return aux.ret(l, v);
    }
    var i = first;
    var count: u32 = 0;
    while (i <= nargs) : (i += 1) {
        const fmt = l.arg(i);
        var v: ?Value = null;
        if (fmt.tag == .integer or fmt.tag == .float) {
            const n = try aux.checkInt(l, i);
            v = try readCount(l, h, @intCast(@max(n, 0)));
        } else {
            var f = try aux.checkBytes(l, i);
            if (f.len > 0 and f[0] == '*') f = f[1..];
            if (f.len == 0) return aux.argError(l, i, "invalid format", .{});
            v = switch (f[0]) {
                'n' => try readNumber(l, h),
                'l' => try readLine(l, h, false),
                'L' => try readLine(l, h, true),
                'a' => try readAll(l, h),
                else => return aux.argError(l, i, "invalid format", .{}),
            };
        }
        if (v) |x| {
            try l.push(x);
            count += 1;
        } else {
            try l.push(.nil);
            return count + 1;
        }
    }
    return count;
}

fn failResult(l: *Thread, msg: []const u8) Error!u32 {
    try l.push(.nil);
    try l.push(try l.newStringValue(msg));
    try l.push(Value.int(0));
    return 3;
}

// ---------------------------------------------------------------------
// Writing

fn doWrite(l: *Thread, h: *Handle, first: u32, self: Value) Error!u32 {
    if (!h.writable) return failResult(l, "file not opened for writing");
    const nargs = l.argCount();
    var i = first;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    while (i <= nargs) : (i += 1) {
        const v = l.arg(i);
        if (v.tag == .vector) {
            buf.appendSlice(l.g.gpa, v.as(object.Vector).bytes.items) catch return l.raiseMem();
        } else if (v.tag == .string) {
            buf.appendSlice(l.g.gpa, v.as(String).bytes()) catch return l.raiseMem();
        } else if (v.isNumber()) {
            ops.numberToBuf(l.g.gpa, &buf, v) catch return l.raiseMem();
        } else return aux.typeError(l, i, "string");
    }
    try writeBytes(l, h, buf.items);
    return aux.ret(l, self);
}

fn writeBytes(l: *Thread, h: *Handle, bytes: []const u8) Error!void {
    switch (h.kind) {
        .stdout => {
            const o = out.stdout(l.g);
            o.write(l.g, bytes);
            if (o.takeError()) |e| return ioError(l, e);
        },
        .stderr => out.stderr(l.g, bytes),
        .file => {
            if (h.append) h.pos = h.file.length(l.g.io) catch h.pos;
            h.file.writePositionalAll(l.g.io, bytes, h.pos) catch |e| return ioError(l, e);
            h.pos += bytes.len;
            // Buffered read-ahead is stale after a write.
            h.rbuf.clearRetainingCapacity();
            h.rstart = 0;
            h.eof = false;
        },
        else => h.file.writeStreamingAll(l.g.io, bytes) catch |e| return ioError(l, e),
    }
}

// ---------------------------------------------------------------------
// Opening and closing

const ModeInfo = struct { read: bool, write: bool, append: bool, truncate: bool, create: bool, binary: bool };

fn parseMode(m: []const u8) ?ModeInfo {
    if (m.len == 0) return null;
    var mi: ModeInfo = .{ .read = false, .write = false, .append = false, .truncate = false, .create = false, .binary = false };
    switch (m[0]) {
        'r' => mi.read = true,
        'w' => {
            mi.write = true;
            mi.truncate = true;
            mi.create = true;
        },
        'a' => {
            mi.write = true;
            mi.append = true;
            mi.create = true;
        },
        else => return null,
    }
    var rest = m[1..];
    if (rest.len > 0 and rest[0] == '+') {
        mi.read = true;
        mi.write = true;
        rest = rest[1..];
    }
    if (rest.len > 0 and rest[0] == 'b') {
        mi.binary = true;
        rest = rest[1..];
    }
    if (rest.len != 0) return null;
    return mi;
}

pub fn openFile(l: *Thread, path: []const u8, mode: []const u8, lossy: bool) Error!?Value {
    const mi = parseMode(mode) orelse return l.raiseFmt("bad argument #2 to 'open' (invalid mode '{s}')", .{mode});
    const io = l.g.io;
    const cwd = std.Io.Dir.cwd();
    const file = blk: {
        if (mi.create) {
            break :blk cwd.createFile(io, path, .{ .read = mi.read, .truncate = mi.truncate }) catch |e| {
                const t = try errText(l, path, e);
                defer l.g.gpa.free(t);
                l.err = try l.newStringValue(t);
                return null;
            };
        }
        break :blk cwd.openFile(io, path, .{ .mode = if (mi.write) .read_write else .read_only }) catch |e| {
            const t = try errText(l, path, e);
            defer l.g.gpa.free(t);
            l.err = try l.newStringValue(t);
            return null;
        };
    };
    var h: Handle = .{ .file = file, .kind = .file, .readable = mi.read, .writable = mi.write, .append = mi.append, .binary = mi.binary, .lossy = lossy };
    if (mi.append) h.pos = file.length(io) catch 0;
    return try newHandle(l, h);
}

fn errText(l: *Thread, path: []const u8, e: anyerror) Error![]const u8 {
    const what = switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        else => @errorName(e),
    };
    return std.fmt.allocPrint(l.g.gpa, "{s}: {s}", .{ path, what }) catch l.raiseMem();
}

fn ioOpen(l: *Thread) Error!u32 {
    const path = try aux.checkBytes(l, 1);
    const mode = (try aux.optString(l, 2, "r")).?;
    var lossy = false;
    if (l.arg(3).tag == .table) {
        lossy = (try aux.getField(l, l.arg(3).as(Table), "lossy")).truthy();
    }
    try checkOpen(l, path, mode);
    const r = try openFile(l, path, mode, lossy);
    if (r) |v| return aux.ret(l, v);
    const msg = l.err;
    try l.push(.nil);
    try l.push(msg);
    try l.push(Value.int(2));
    return 3;
}

fn closeHandle(l: *Thread, h: *Handle) Error!u32 {
    switch (h.kind) {
        .stdin, .stdout, .stderr => {
            try l.push(.nil);
            try l.push(try l.newStringValue("cannot close standard file"));
            return 2;
        },
        .pipe => {
            h.closed = true;
            if (h.child == null) h.file.close(l.g.io);
            var status: shell.Status = .{ .exited = 0 };
            if (h.child) |*c| {
                // Both ends close before the wait, as with pclose. A child
                // that reads sees the end of its input and can exit, and a
                // child that still writes gets SIGPIPE on POSIX systems or
                // a broken pipe on Windows instead of blocking forever.
                if (c.stdin) |f| {
                    f.close(l.g.io);
                    c.stdin = null;
                }
                if (c.stdout) |f| {
                    f.close(l.g.io);
                    c.stdout = null;
                }
                status = shell.wait(l.g.io, c) catch return aux.retNil(l);
            }
            h.rbuf.deinit(l.g.gpa);
            return pushStatus(l, status);
        },
        .file => {
            h.closed = true;
            h.file.close(l.g.io);
            h.rbuf.deinit(l.g.gpa);
            return aux.retBool(l, true);
        },
    }
}

/// Pushes the results of `os.execute` and of closing a pipe: true or nil,
/// then "exit" and the exit code or "signal" and the signal number.
pub fn pushStatus(l: *Thread, status: shell.Status) Error!u32 {
    try l.push(if (status.success()) .true else .nil);
    switch (status) {
        .exited => |code| {
            try l.push(try l.newStringValue("exit"));
            try l.push(Value.int(code));
        },
        .signal => |sig| {
            try l.push(try l.newStringValue("signal"));
            try l.push(Value.int(sig));
        },
    }
    return 3;
}

fn ioClose(l: *Thread) Error!u32 {
    if (!l.hasArg(1)) {
        const h = toHandle(l, try getDefault(l, "io.output")).?;
        return closeHandle(l, h);
    }
    return closeHandle(l, try checkHandle(l, 1));
}

fn fClose(l: *Thread) Error!u32 {
    return closeHandle(l, try checkHandle(l, 1));
}

fn fGc(l: *Thread) Error!u32 {
    const h = toHandle(l, l.arg(1)) orelse return 0;
    if (!h.closed and (h.kind == .file or h.kind == .pipe)) _ = try closeHandle(l, h);
    return 0;
}

fn fToString(l: *Thread) Error!u32 {
    const h = toHandle(l, l.arg(1)).?;
    if (h.closed) return aux.retStr(l, "file (closed)");
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, "file (0x{x})", .{l.arg(1).payload}) catch "file");
}

fn ioType(l: *Thread) Error!u32 {
    _ = try aux.checkAny(l, 1);
    const h = toHandle(l, l.arg(1)) orelse return aux.retNil(l);
    return aux.retStr(l, if (h.closed) "closed file" else "file");
}

fn ioRead(l: *Thread) Error!u32 {
    const v = try getDefault(l, "io.input");
    const h = toHandle(l, v).?;
    if (h.closed) return l.raiseFmt("default input file is closed", .{});
    return doRead(l, h, 1);
}

fn fRead(l: *Thread) Error!u32 {
    return doRead(l, try checkHandle(l, 1), 2);
}

fn ioWrite(l: *Thread) Error!u32 {
    const v = try getDefault(l, "io.output");
    const h = toHandle(l, v).?;
    if (h.closed) return l.raiseFmt("default output file is closed", .{});
    return doWrite(l, h, 1, v);
}

fn fWrite(l: *Thread) Error!u32 {
    return doWrite(l, try checkHandle(l, 1), 2, l.arg(1));
}

fn fFlush(l: *Thread) Error!u32 {
    const h = try checkHandle(l, 1);
    if (h.kind == .stdout) {
        const o = out.stdout(l.g);
        o.flush(l.g);
        if (o.takeError()) |e| return ioError(l, e);
    }
    return aux.ret(l, l.arg(1));
}

/// io.flush(): flushes the default output file and returns true.
fn ioFlush(l: *Thread) Error!u32 {
    const v = try getDefault(l, "io.output");
    const h = toHandle(l, v).?;
    if (h.closed) return l.raiseFmt("default output file is closed", .{});
    if (h.kind == .stdout) {
        const o = out.stdout(l.g);
        o.flush(l.g);
        if (o.takeError()) |e| return ioError(l, e);
    }
    return aux.retBool(l, true);
}

fn fSetvbuf(l: *Thread) Error!u32 {
    const h = try checkHandle(l, 1);
    const mode = try aux.checkOption(l, 2, null, &.{ "no", "full", "line" });
    if (h.kind == .stdout) {
        const o = out.stdout(l.g);
        o.mode = switch (mode) {
            0 => .no,
            1 => .full,
            else => .line,
        };
        if (o.mode != .full) o.flush(l.g);
    }
    return aux.retBool(l, true);
}

fn fSeek(l: *Thread) Error!u32 {
    const h = try checkHandle(l, 1);
    const whence = try aux.checkOption(l, 2, "cur", &.{ "set", "cur", "end" });
    const off = try aux.optInt(l, 3, 0);
    if (h.kind != .file) return failResult(l, "Illegal seek");
    const base: i64 = switch (whence) {
        0 => 0,
        1 => @intCast(h.pos),
        else => @intCast(h.file.length(l.g.io) catch |e| return ioError(l, e)),
    };
    const np = base + off;
    if (np < 0) return failResult(l, "Invalid argument");
    h.pos = @intCast(np);
    h.rbuf.clearRetainingCapacity();
    h.rstart = 0;
    h.eof = false;
    return aux.retInt(l, np);
}

fn ioInput(l: *Thread) Error!u32 {
    return setDefaultFile(l, "io.input", "r");
}

fn ioOutput(l: *Thread) Error!u32 {
    return setDefaultFile(l, "io.output", "w");
}

fn setDefaultFile(l: *Thread, key: []const u8, mode: []const u8) Error!u32 {
    const a = l.arg(1);
    if (!a.isNil()) {
        if (a.tag == .string) {
            try checkOpen(l, a.as(String).bytes(), mode);
            const v = (try openFile(l, a.as(String).bytes(), mode, false)) orelse return l.raise(l.err);
            try setDefault(l, key, v);
        } else {
            _ = try checkHandle(l, 1);
            try setDefault(l, key, a);
        }
    }
    return aux.ret(l, try getDefault(l, key));
}

// --- lines ------------------------------------------------------------

fn linesAux(l: *Thread) Error!u32 {
    const nat = l.frame().native.?;
    const ups = nat.upvalues();
    const h = toHandle(l, ups[0]).?;
    if (h.closed) return l.raiseFmt("file is already closed", .{});
    // Formats are stored after the handle and the close flag.
    const n_formats = nat.nupvals - 2;
    var count: u32 = 0;
    var eof = false;
    if (n_formats == 0) {
        if (try readLine(l, h, false)) |v| {
            try l.push(v);
            count = 1;
        } else eof = true;
    } else {
        var i: u32 = 0;
        while (i < n_formats) : (i += 1) {
            const fmt = ups[2 + i];
            var v: ?Value = null;
            if (fmt.tag == .integer) {
                v = try readCount(l, h, @intCast(@max(fmt.asInt(), 0)));
            } else {
                var f = fmt.as(String).bytes();
                if (f.len > 0 and f[0] == '*') f = f[1..];
                v = switch (if (f.len > 0) f[0] else 'l') {
                    'n' => try readNumber(l, h),
                    'L' => try readLine(l, h, true),
                    'a' => try readAll(l, h),
                    else => try readLine(l, h, false),
                };
            }
            if (v) |x| {
                try l.push(x);
                count += 1;
            } else {
                if (i == 0) eof = true;
                break;
            }
        }
    }
    if (eof) {
        if (ups[1].truthy()) _ = try closeHandle(l, h);
        try l.push(.nil);
        return 1;
    }
    return count;
}

fn makeLines(l: *Thread, hv: Value, close_at_eof: bool, first_fmt: u32) Error!u32 {
    const nargs = l.argCount();
    const nf: u32 = if (nargs >= first_fmt) nargs - first_fmt + 1 else 0;
    const n = state.newNative(l.g, linesAux, "lines", 2 + nf) catch return l.raiseMem();
    n.upvalues()[0] = hv;
    n.upvalues()[1] = Value.boolean(close_at_eof);
    var i: u32 = 0;
    while (i < nf) : (i += 1) n.upvalues()[2 + i] = l.arg(first_fmt + i);
    try l.push(Value.obj(.native, n));
    try l.push(.nil);
    try l.push(.nil);
    try l.push(hv);
    return 4;
}

fn fLines(l: *Thread) Error!u32 {
    _ = try checkHandle(l, 1);
    return makeLines(l, l.arg(1), false, 2);
}

fn ioLines(l: *Thread) Error!u32 {
    if (l.arg(1).isNil()) {
        const v = try getDefault(l, "io.input");
        return makeLines(l, v, false, 2);
    }
    const path = try aux.checkBytes(l, 1);
    try checkOpen(l, path, "r");
    const v = (try openFile(l, path, "r", false)) orelse return l.raise(l.err);
    return makeLines(l, v, true, 2);
}

// --- processes and temporary files ------------------------------------

fn ioPopen(l: *Thread) Error!u32 {
    if (comptime !aux.can_spawn) return aux.unavailable(l, "io.popen");
    return popen(l);
}

fn popen(l: *Thread) Error!u32 {
    const cmd = try aux.checkBytes(l, 1);
    const mode = (try aux.optString(l, 2, "r")).?;
    const reading = std.mem.eql(u8, mode, "r");
    if (!reading and !std.mem.eql(u8, mode, "w")) return aux.argError(l, 2, "invalid mode", .{});
    out.flushAll(l.g);
    if (!@import("../vm/pledge.zig").allowed(l, "exec", null)) return l.raiseFmt("permission \"exec\" denied for popen", .{});
    const child = shell.spawn(l.g.io, l.g.gpa, cmd, if (reading) .stdout else .stdin) catch return failResult(l, "cannot run command");
    const f = if (reading) child.stdout.? else child.stdin.?;
    const hv = try newHandle(l, .{ .file = f, .kind = .pipe, .readable = reading, .writable = !reading, .child = child });
    return aux.ret(l, hv);
}

fn ioTmpfile(l: *Thread) Error!u32 {
    if (!@import("../vm/pledge.zig").allowed(l, "fs:write", null)) return l.raiseFmt("permission \"fs:write\" denied for io.tmpfile", .{});
    var rnd: [8]u8 = undefined;
    l.g.io.random(&rnd);
    const dir = if (l.g.environ) |env| env.get("TMPDIR") orelse "/tmp" else "/tmp";
    const path = std.fmt.allocPrint(l.g.gpa, "{s}/lus_{x}", .{ std.mem.trimEnd(u8, dir, "/"), std.mem.readInt(u64, &rnd, .little) }) catch return l.raiseMem();
    defer l.g.gpa.free(path);
    const v = (try openFile(l, path, "w+", false)) orelse return l.raise(l.err);
    // The file is removed right away and lives until closed.
    std.Io.Dir.cwd().deleteFile(l.g.io, path) catch {};
    return aux.ret(l, v);
}

fn checkOpen(l: *Thread, path: []const u8, mode: []const u8) Error!void {
    const pledge = @import("../vm/pledge.zig");
    const writes = std.mem.indexOfAny(u8, mode, "wa+") != null;
    const reads = mode.len > 0 and (mode[0] == 'r' or std.mem.indexOfScalar(u8, mode, '+') != null);
    if (reads) try pledge.require(l, "fs:read", path);
    if (writes) try pledge.require(l, "fs:write", path);
}
