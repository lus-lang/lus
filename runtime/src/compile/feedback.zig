//! Warm starts: a binary chunk may carry the feedback of an earlier run,
//! so that the functions that were hot then have native code before the
//! chunk runs. The design is described in `spec/design/warmstart.md`.
//!
//! The feedback is an optional section that follows the chunk:
//!
//!   magic "LUSFDBK" | version u8 | runtime version | chunk hash u64
//!   | prototype count | one flag byte per prototype | checksum u64
//!
//! The runtime version is a length (unsigned LEB128) and its bytes. The
//! chunk hash covers every byte of the chunk before the section, and the
//! checksum covers the section up to the checksum. Prototypes are counted
//! in the order the chunk stores them: a function, then its nested
//! functions, depth first. Integers are little endian.
//!
//! A section that fails any check is ignored and the chunk loads cold.
//! Every flag only decides when a function compiles, and compiling never
//! changes what a function does, so stale feedback costs at most some
//! compile time.

const std = @import("std");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const value = @import("../vm/value.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const jit = @import("../jit/jit.zig");
const Proto = object.Proto;
const Thread = state.Thread;
const Value = value.Value;
const Allocator = std.mem.Allocator;

pub const magic = "LUSFDBK";
/// Bumped whenever the meaning of the section changes.
pub const format_version: u8 = 1;
/// The runtime that wrote the section. Feedback from any other runtime is
/// ignored.
pub const runtime_version = @import("../api.zig").version;

/// Flag of a function that had native code when the profiling run ended.
pub const flag_hot: u8 = 1;
/// The flags this runtime understands. A section with any other bit set
/// is ignored.
const known_flags: u8 = flag_hot;

pub const Status = enum {
    /// The chunk carries no section.
    absent,
    /// The section is well formed and belongs to the chunk.
    valid,
    /// The section belongs to another chunk or another runtime.
    stale,
    /// The section is damaged.
    corrupt,
};

pub const Feedback = struct {
    status: Status = .absent,
    /// One flag per prototype when the status is `valid`. Points into the
    /// loaded bytes.
    flags: []const u8 = &.{},
};

/// True when the bytes after a chunk begin a feedback section. Any other
/// trailing bytes make the chunk malformed.
pub fn startsSection(rest: []const u8) bool {
    return std.mem.startsWith(u8, rest, magic);
}

fn hash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// The number of prototypes in `p`, counting `p` itself.
pub fn count(p: *const Proto) usize {
    var n: usize = 1;
    for (p.protos) |q| n += count(q);
    return n;
}

/// Checks the section `rest` that follows `chunk`, whose main function is
/// `p`. Never fails: a section that does not check out is reported as
/// stale or corrupt and is never used.
pub fn check(chunk: []const u8, rest: []const u8, p: *const Proto) Feedback {
    if (rest.len == 0) return .{};
    var r: Reader = .{ .src = rest };
    const parsed = r.section() catch return .{ .status = .corrupt };
    if (r.pos != rest.len) return .{ .status = .corrupt };
    if (parsed.checksum != hash(rest[0 .. rest.len - 8])) return .{ .status = .corrupt };
    for (parsed.flags) |f| if (f & ~known_flags != 0) return .{ .status = .corrupt };
    if (parsed.version != format_version) return .{ .status = .stale };
    if (!std.mem.eql(u8, parsed.runtime, runtime_version)) return .{ .status = .stale };
    if (parsed.chunk_hash != hash(chunk)) return .{ .status = .stale };
    if (parsed.flags.len != count(p)) return .{ .status = .stale };
    return .{ .status = .valid, .flags = parsed.flags };
}

const Parsed = struct {
    version: u8,
    runtime: []const u8,
    chunk_hash: u64,
    flags: []const u8,
    checksum: u64,
};

const Reader = struct {
    src: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) error{Malformed}![]const u8 {
        if (n > r.src.len - r.pos) return error.Malformed;
        r.pos += n;
        return r.src[r.pos - n .. r.pos];
    }
    fn uint(r: *Reader) error{Malformed}!usize {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = (try r.take(1))[0];
            if (shift >= 64) return error.Malformed;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        // No length can exceed the input.
        if (v > r.src.len) return error.Malformed;
        return @intCast(v);
    }
    fn word(r: *Reader) error{Malformed}!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }
    fn section(r: *Reader) error{Malformed}!Parsed {
        if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.Malformed;
        const version = (try r.take(1))[0];
        const runtime = try r.take(try r.uint());
        const chunk_hash = try r.word();
        const flags = try r.take(try r.uint());
        const checksum = try r.word();
        return .{ .version = version, .runtime = runtime, .chunk_hash = chunk_hash, .flags = flags, .checksum = checksum };
    }
};

/// Appends a feedback section for `chunk` to `out`. `flags` holds one
/// flag per prototype of the chunk.
pub fn appendSection(gpa: Allocator, out: *std.ArrayList(u8), chunk: []const u8, flags: []const u8) Allocator.Error!void {
    const first = out.items.len;
    try out.appendSlice(gpa, magic);
    try out.append(gpa, format_version);
    try appendUint(gpa, out, runtime_version.len);
    try out.appendSlice(gpa, runtime_version);
    try appendWord(gpa, out, hash(chunk));
    try appendUint(gpa, out, flags.len);
    try out.appendSlice(gpa, flags);
    try appendWord(gpa, out, hash(out.items[first..]));
}

fn appendUint(gpa: Allocator, out: *std.ArrayList(u8), v: usize) Allocator.Error!void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) return out.append(gpa, b);
        try out.append(gpa, b | 0x80);
    }
}

fn appendWord(gpa: Allocator, out: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try out.appendSlice(gpa, &tmp);
}

/// The flags of every prototype of `p`, in chunk order, as the run that
/// is ending leaves them.
pub fn collect(gpa: Allocator, p: *const Proto) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try collectInto(gpa, &list, p);
    return list.toOwnedSlice(gpa);
}

fn collectInto(gpa: Allocator, list: *std.ArrayList(u8), p: *const Proto) Allocator.Error!void {
    try list.append(gpa, if (p.jit_state == .compiled) flag_hot else 0);
    for (p.protos) |q| try collectInto(gpa, list, q);
}

/// Compiles the functions that valid feedback marks hot. Only a state
/// whose JIT runs in its default mode uses feedback: an interpreted state
/// compiles nothing, and an eager one compiles every function anyway.
pub fn apply(l: *Thread, p: *Proto, fb: Feedback) void {
    if (!jit.enabled or fb.status != .valid) return;
    if (jit.setting(l.g) != .on) return;
    var i: usize = 0;
    applyTree(l, p, fb.flags, &i);
}

fn applyTree(l: *Thread, p: *Proto, flags: []const u8, i: *usize) void {
    const f = flags[i.*];
    i.* += 1;
    if (f & flag_hot != 0 and p.jit_state == .fresh) {
        // Counting with nothing left to count: the JIT compiles the
        // function now, or declines it as it would at run time.
        p.jit_state = .counting;
        _ = jit.expire(l, p);
    }
    for (p.protos) |q| applyTree(l, q, flags, i);
}

// ---------------------------------------------------------------------
// Profiling runs

/// The key under which a profiling run keeps its state in `Global.ext`.
pub const ext_key = "feedback.profile";
/// The registry field that holds every chunk loaded during a profiling
/// run, by chunk name, so that the chunks stay alive until the run ends.
const registry_field = "_PROFILE";

/// A profiling run. `start` installs it in a state, `api.load` records
/// every chunk the program loads, and `harvest` reads the flags of each
/// chunk before the state closes.
pub const Profile = struct {
    gpa: Allocator,
    /// Flags by chunk name, filled by `harvest`.
    results: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Whether the run had a JIT to count with.
    jit_on: bool = false,

    pub fn deinit(p: *Profile) void {
        var it = p.results.iterator();
        while (it.next()) |e| {
            p.gpa.free(e.key_ptr.*);
            p.gpa.free(e.value_ptr.*);
        }
        p.results.deinit(p.gpa);
    }

    /// The flags recorded for `chunkname`, or null when no chunk of that
    /// name ran.
    pub fn get(p: *const Profile, chunkname: []const u8) ?[]const u8 {
        return p.results.get(chunkname);
    }
};

/// Installs `p` in the state of `l`. The run counts with the JIT in its
/// default mode whatever the environment asks for, because the counters
/// are what the profile reads.
pub fn start(l: *Thread, p: *Profile) Allocator.Error!void {
    const g = l.g;
    try g.ext.put(g.gpa, ext_key, p);
    if (jit.enabled) {
        if (jit.setting(g) != .on) jit.configure(g, .on, jit.default_threshold);
        p.jit_on = jit.setting(g) == .on;
    }
}

/// Called by `api.load` with the loaded function on top of the stack.
/// During a profiling run, keeps the first chunk loaded under each name.
pub fn record(l: *Thread, chunkname: []const u8) state.Error!void {
    const g = l.g;
    if (g.ext.get(ext_key) == null) return;
    const aux = @import("../lib/aux.zig");
    const reg = g.registry.as(object.Table);
    var chunks = try aux.getField(l, reg, registry_field);
    if (chunks.tag != .table) {
        chunks = Value.obj(.table, try l.newTable(0, 4));
        try aux.setField(l, reg, registry_field, chunks);
    }
    const t = chunks.as(object.Table);
    const f = l.stack[l.top - 1];
    const key = try l.newStringValue(chunkname);
    if (!table.get(t, key).isNil()) return;
    try ops.rawSet(l, t, key, f);
}

/// Reads the flags of every chunk the run recorded.
pub fn harvest(l: *Thread, p: *Profile) !void {
    const aux = @import("../lib/aux.zig");
    const reg = l.g.registry.as(object.Table);
    const chunks = try aux.getField(l, reg, registry_field);
    if (chunks.tag != .table) return;
    const t = chunks.as(object.Table);
    var key: Value = .nil;
    while (try table.next(t, key)) |e| : (key = e.key) {
        if (e.key.tag != .string or e.val.tag != .closure) continue;
        const name = e.key.as(object.String).bytes();
        if (p.results.contains(name)) continue;
        const flags = try collect(p.gpa, e.val.as(object.Closure).proto);
        errdefer p.gpa.free(flags);
        const owned = try p.gpa.dupe(u8, name);
        errdefer p.gpa.free(owned);
        try p.results.put(p.gpa, owned, flags);
    }
}

test "a section round trips and rejects damage" {
    const gpa = std.testing.allocator;
    var p: Proto = .{ .hdr = undefined };
    var q: Proto = .{ .hdr = undefined };
    var children = [_]*Proto{&q};
    p.protos = &children;
    const chunk = "\x1bLus pretend chunk";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendSection(gpa, &out, chunk, &.{ 0, flag_hot });

    const ok = check(chunk, out.items, &p);
    try std.testing.expectEqual(Status.valid, ok.status);
    try std.testing.expectEqualSlices(u8, &.{ 0, flag_hot }, ok.flags);

    // Another chunk, another shape, damage, and truncation.
    try std.testing.expectEqual(Status.stale, check("\x1bLus other chunk", out.items, &p).status);
    try std.testing.expectEqual(Status.stale, check(chunk, out.items, &q).status);
    for (0..out.items.len) |i| {
        const saved = out.items[i];
        out.items[i] ^= 0x10;
        try std.testing.expect(check(chunk, out.items, &p).status != .valid);
        out.items[i] = saved;
        if (i > 0) try std.testing.expectEqual(Status.corrupt, check(chunk, out.items[0..i], &p).status);
    }
    try std.testing.expectEqual(Status.absent, check(chunk, "", &p).status);
}
