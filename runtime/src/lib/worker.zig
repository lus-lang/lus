//! The worker library: OS threads that run a script in a state of their
//! own and talk to their creator by message passing.
//!
//! Every worker owns a complete `Global` with its own heap and collector,
//! so no collection ever stops more than one thread. A message is a graph
//! copy. The sender walks the value once and builds a `Packet` in memory
//! that no heap owns, recording every table it meets in a forwarding table
//! so shared references and cycles keep their shape. The receiver rebuilds
//! the graph in its own heap. Vectors move instead of being copied: the
//! sender's vector is detached and the receiver takes over its buffer.
//! Strings longer than `blob.min_len` bytes travel as shared immutable
//! blobs (`vm/blob.zig`), so the packet and the receiver refer to the
//! sender's bytes instead of copying them.
//!
//! Each worker has two mailboxes. The inbox carries values from the
//! creator to the worker and has a condition that `worker.peek` waits on.
//! The outbox carries values back and holds the worker's final status.
//! A creator waits for any of its workers through the event counter of
//! its domain, the per-state record of the workers it created. Nothing
//! polls: every wait sleeps on a condition variable.
//!
//! In a state with detached coroutines, `worker.receive` and
//! `worker.peek` are suspension points (`spec/design/coroutines.md`).
//! They wait through the scheduler of the state, and whoever changes a
//! mailbox also wakes that scheduler from its own thread
//! (`sched.notify`), so the other coroutines run while one waits for a
//! message.
//!
//! When the creating state closes, it marks every worker as shutting down,
//! wakes those parked in `worker.peek`, and joins all threads. A woken
//! `worker.peek` raises an error that no `catch` intercepts, so the worker
//! script unwinds even when it retries in a loop.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const gc = @import("../vm/gc.zig");
const numeric = @import("../vm/numeric.zig");
const pledge = @import("../vm/pledge.zig");
const os = @import("os.zig");
const sched = @import("../vm/sched.zig");
const blob = @import("../vm/blob.zig");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const out = @import("out.zig");
const vector = @import("vector.zig");
const Value = value.Value;
const Thread = state.Thread;
const Global = state.Global;
const Error = state.Error;
const Table = object.Table;
const String = object.String;
const Userdata = object.Userdata;
const Vector = object.Vector;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Tables may nest this deep in one message. Shared and cyclic references
/// do not count, since the forwarding table resolves them.
const max_depth = 100;

// ---------------------------------------------------------------------
// Packets

const Item = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    string: Str,
    shared: Shared,
    bigint: Big,
    decimal: Dec,
    table: u32,
    vector: u32,
};

const Str = struct { bytes: []const u8, ascii: bool, chars: u32 };
/// A string carried as a blob: an index into the blobs of the packet.
const Shared = struct { index: u32, ascii: bool, chars: u32 };
const Big = struct { limbs: []const std.math.big.Limb, positive: bool };
const Dec = struct { limbs: []const std.math.big.Limb, positive: bool, exponent: i32 };
const Pair = struct { key: Item, val: Item };

/// One message in transit. Everything except the vector buffers and the
/// blobs lives in the arena. The buffers belong to the packet until the
/// receiver adopts them, and the packet holds one reference to each blob.
const Packet = struct {
    arena: std.heap.ArenaAllocator,
    root: Item = .nil,
    tables: []const []const Pair = &.{},
    vectors: []std.ArrayList(u8) = &.{},
    blobs: []const *blob.Blob = &.{},
    next: ?*Packet = null,

    fn destroy(p: *Packet, gpa: Allocator) void {
        for (p.vectors) |*v| v.deinit(gpa);
        for (p.blobs) |b| b.release();
        p.arena.deinit();
        gpa.destroy(p);
    }
};

const Encoder = struct {
    l: *Thread,
    arena: Allocator,
    tables: std.ArrayList([]const Pair) = .empty,
    seen: std.AutoHashMapUnmanaged(*Table, u32) = .empty,
    vectors: std.ArrayList(*Vector) = .empty,
    seen_vectors: std.AutoHashMapUnmanaged(*Vector, u32) = .empty,
    /// The blobs of the message, one reference for each string that
    /// refers to one, held until the packet takes them over.
    blobs: std.ArrayList(*blob.Blob) = .empty,

    fn deinit(e: *Encoder) void {
        const gpa = e.l.g.parent_gpa;
        e.seen.deinit(gpa);
        e.vectors.deinit(gpa);
        e.seen_vectors.deinit(gpa);
        for (e.blobs.items) |b| b.release();
        e.blobs.deinit(gpa);
    }

    /// The index of the blob of `s` in the message, or null when the
    /// message copies the bytes of `s`.
    fn blobIndex(e: *Encoder, s: *String) Error!?u32 {
        const l = e.l;
        e.blobs.ensureUnusedCapacity(l.g.parent_gpa, 1) catch return l.raiseMem();
        const b = (blob.acquire(l.g, s) catch return l.raiseMem()) orelse return null;
        e.blobs.appendAssumeCapacity(b);
        return @intCast(e.blobs.items.len - 1);
    }

    fn item(e: *Encoder, v: Value, depth: u32) Error!Item {
        const l = e.l;
        return switch (v.tag) {
            .nil => .nil,
            .false => .{ .boolean = false },
            .true => .{ .boolean = true },
            .integer => .{ .int = v.asInt() },
            .float => .{ .float = v.asFloat() },
            .string => blk: {
                const s = v.as(String);
                if (s.len > blob.min_len) if (try e.blobIndex(s)) |i| break :blk .{ .shared = .{ .index = i, .ascii = s.flags().ascii, .chars = s.chars() } };
                const bytes = e.arena.dupe(u8, s.bytes()) catch return l.raiseMem();
                break :blk .{ .string = .{ .bytes = bytes, .ascii = s.flags().ascii, .chars = s.chars() } };
            },
            .bigint => blk: {
                const b = v.as(numeric.BigInt);
                const limbs = e.arena.dupe(std.math.big.Limb, b.limbs()) catch return l.raiseMem();
                break :blk .{ .bigint = .{ .limbs = limbs, .positive = b.positive } };
            },
            .decimal => blk: {
                const d = v.as(numeric.Decimal);
                const limbs = e.arena.dupe(std.math.big.Limb, d.limbs()) catch return l.raiseMem();
                break :blk .{ .decimal = .{ .limbs = limbs, .positive = d.positive, .exponent = d.exponent } };
            },
            .vector => blk: {
                const vec = v.as(Vector);
                if (vec.detached) return l.raiseFmt("cannot send a vector that was transferred to another worker", .{});
                const gop = e.seen_vectors.getOrPut(l.g.parent_gpa, vec) catch return l.raiseMem();
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(e.vectors.items.len);
                    e.vectors.append(l.g.parent_gpa, vec) catch return l.raiseMem();
                }
                break :blk .{ .vector = gop.value_ptr.* };
            },
            .table => .{ .table = try e.tableIndex(v.as(Table), depth) },
            else => l.raiseFmt("cannot serialize {s} to worker", .{value.typeName(v.tag)}),
        };
    }

    fn tableIndex(e: *Encoder, t: *Table, depth: u32) Error!u32 {
        const l = e.l;
        if (e.seen.get(t)) |i| return i;
        if (depth >= max_depth) return l.raiseFmt("table nesting too deep for serialization", .{});
        // Record the table before its contents so a cycle back to it
        // resolves to this index.
        const index: u32 = @intCast(e.tables.items.len);
        e.seen.put(l.g.parent_gpa, t, index) catch return l.raiseMem();
        e.tables.append(e.arena, &.{}) catch return l.raiseMem();
        var count: usize = 0;
        var k: Value = .nil;
        while (table.next(t, k) catch null) |r| : (k = r.key) count += 1;
        const pairs = e.arena.alloc(Pair, count) catch return l.raiseMem();
        var i: usize = 0;
        k = .nil;
        while (table.next(t, k) catch null) |r| : (k = r.key) {
            if (i == count) break;
            pairs[i] = .{ .key = try e.item(r.key, depth + 1), .val = try e.item(r.val, depth + 1) };
            i += 1;
        }
        e.tables.items[index] = pairs[0..i];
        return index;
    }
};

/// Copies `v` out of the heap of `l` into a new packet.
fn encode(l: *Thread, v: Value) Error!*Packet {
    const gpa = l.g.parent_gpa;
    const p = gpa.create(Packet) catch return l.raiseMem();
    p.* = .{ .arena = .init(gpa) };
    errdefer p.destroy(gpa);
    var e: Encoder = .{ .l = l, .arena = p.arena.allocator() };
    defer e.deinit();
    p.root = try e.item(v, 0);
    p.tables = e.tables.items;
    // Vectors move only once the whole value has been accepted.
    const vecs = p.arena.allocator().alloc(std.ArrayList(u8), e.vectors.items.len) catch return l.raiseMem();
    for (e.vectors.items, vecs) |vec, *dst| {
        dst.* = vec.bytes;
        vec.bytes = .empty;
        vec.detached = true;
    }
    p.vectors = vecs;
    p.blobs = p.arena.allocator().dupe(*blob.Blob, e.blobs.items) catch return l.raiseMem();
    e.blobs.clearRetainingCapacity();
    return p;
}

/// Rebuilds the value of `p` in the heap of `l`. The packet stays owned
/// by the caller, minus any vector buffers it handed over.
fn decode(l: *Thread, p: *Packet) Error!Value {
    const g = l.g;
    // Nothing created here is reachable until the root is returned, so
    // the collector waits until the graph is complete.
    const was_stopped = g.gc_stopped;
    g.gc_stopped = true;
    defer g.gc_stopped = was_stopped;
    const tabs = g.gpa.alloc(*Table, p.tables.len) catch return l.raiseMem();
    defer g.gpa.free(tabs);
    for (p.tables, tabs) |pairs, *t| t.* = try l.newTable(0, pairs.len);
    const vecs = g.gpa.alloc(?*Vector, p.vectors.len) catch return l.raiseMem();
    defer g.gpa.free(vecs);
    @memset(vecs, null);
    const d: Decoder = .{ .l = l, .p = p, .tabs = tabs, .vecs = vecs };
    for (p.tables, tabs) |pairs, t| {
        for (pairs) |kv| try ops.rawSet(l, t, try d.conv(kv.key), try d.conv(kv.val));
    }
    return d.conv(p.root);
}

const Decoder = struct {
    l: *Thread,
    p: *Packet,
    tabs: []*Table,
    vecs: []?*Vector,

    fn conv(d: Decoder, it: Item) Error!Value {
        const l = d.l;
        const g = l.g;
        return switch (it) {
            .nil => .nil,
            .boolean => |b| Value.boolean(b),
            .int => |i| Value.int(i),
            .float => |f| Value.float(f),
            .string => |s| Value.obj(.string, state.newStringKnown(g, s.bytes, s.ascii, s.chars) catch return l.raiseMem()),
            .bigint => |b| Value.obj(.bigint, numeric.newBigFromConst(g, .{ .limbs = b.limbs, .positive = b.positive }) catch return l.raiseMem()),
            .decimal => |dc| Value.obj(.decimal, numeric.newDecFromConst(g, .{ .limbs = dc.limbs, .positive = dc.positive }, dc.exponent) catch return l.raiseMem()),
            .shared => |s| Value.obj(.string, blob.newString(g, d.p.blobs[s.index], s.ascii, s.chars) catch return l.raiseMem()),
            .table => |i| Value.obj(.table, d.tabs[i]),
            .vector => |i| blk: {
                if (d.vecs[i] == null) d.vecs[i] = try vector.newVectorFrom(l, &d.p.vectors[i]);
                break :blk Value.obj(.vector, d.vecs[i].?);
            },
        };
    }
};

// ---------------------------------------------------------------------
// Mailboxes, workers and domains

const Queue = struct {
    head: ?*Packet = null,
    tail: ?*Packet = null,

    fn push(q: *Queue, p: *Packet) void {
        p.next = null;
        if (q.tail) |t| t.next = p else q.head = p;
        q.tail = p;
    }

    fn pop(q: *Queue) ?*Packet {
        const p = q.head orelse return null;
        q.head = p.next;
        if (q.head == null) q.tail = null;
        p.next = null;
        return p;
    }

    fn clear(q: *Queue, gpa: Allocator) void {
        while (q.pop()) |p| p.destroy(gpa);
    }
};

const Status = enum { running, dead, failed };

/// The record shared by a worker thread and its creator. The creator's
/// thread allocates and frees it. Fields under "inbox" are guarded by
/// `in_mutex` and fields under "outbox" by `out_mutex`. The startup data
/// is written before the thread starts and only read afterwards.
const Worker = struct {
    domain: *Domain,

    // Inbox.
    in_mutex: Io.Mutex = .init,
    in_cond: Io.Condition = .init,
    inbox: Queue = .{},
    shutdown: bool = false,
    /// The state of the worker, once its `worker.peek` waits through the
    /// scheduler. Whoever changes the inbox wakes that scheduler.
    waker: ?*Global = null,
    /// The domain of the workers this worker created, so a shutdown can
    /// wake it while it waits in `worker.receive`.
    child_domain: ?*Domain = null,

    // Outbox.
    out_mutex: Io.Mutex = .init,
    outbox: Queue = .{},
    status: Status = .running,
    err_msg: ?[]u8 = null,
    /// A copy of the error value of a failed worker when it is not a
    /// string and can cross between states, such as a table.
    err_value: ?*Packet = null,

    // Startup data.
    chunkname: []u8,
    source: ?[]u8 = null,
    load_error: ?[]u8 = null,
    args: []*Packet = &.{},
    flags: [][]u8 = &.{},
    pledges: ?*anyopaque = null,
    environ: ?*std.process.Environ.Map = null,
    /// Set when `environ` is a copy that the worker owns, made because its
    /// creator changed its environment with `os.setenv`.
    environ_owned: bool = false,
    warn_on: bool = false,
    env_frozen: bool = false,
    pause: usize = 200,
    /// The hash seed of the creator, so strings keep their hashes.
    seed: u64 = 0,

    // Owned by the creator's thread.
    thread: ?std.Thread = null,
    handle_alive: bool = true,
    done: std.atomic.Value(bool) = .init(false),

    fn destroy(w: *Worker, gpa: Allocator) void {
        w.inbox.clear(gpa);
        w.outbox.clear(gpa);
        if (w.err_msg) |m| gpa.free(m);
        if (w.err_value) |p| p.destroy(gpa);
        gpa.free(w.chunkname);
        if (w.source) |s| gpa.free(s);
        if (w.load_error) |m| gpa.free(m);
        for (w.args) |p| p.destroy(gpa);
        gpa.free(w.args);
        for (w.flags) |f| gpa.free(f);
        gpa.free(w.flags);
        if (w.pledges) |p| pledge.discard(gpa, p);
        if (w.environ_owned) if (w.environ) |m| os.freeEnviron(m);
        gpa.destroy(w);
    }
};

/// The workers created by one state. Only the owning state's thread
/// touches `workers`. Worker threads bump `epoch` whenever an outbox
/// changes, which wakes a creator blocked in `worker.receive`.
const Domain = struct {
    gpa: Allocator,
    io: Io,
    workers: std.ArrayList(*Worker) = .empty,
    ev_mutex: Io.Mutex = .init,
    ev_cond: Io.Condition = .init,
    epoch: u64 = 0,
    /// The state that owns the domain, once its `worker.receive` waits
    /// through the scheduler. Guarded by `ev_mutex`.
    waker: ?*Global = null,

    fn notify(d: *Domain) void {
        d.ev_mutex.lockUncancelable(d.io);
        d.epoch +%= 1;
        d.ev_cond.broadcast(d.io);
        if (d.waker) |g| sched.notify(g);
        d.ev_mutex.unlock(d.io);
    }

    /// Makes every later event of the domain wake the scheduler of the
    /// state of `l`, which owns the domain.
    fn wakes(d: *Domain, l: *Thread) Error!void {
        if (d.waker != null) return;
        try enableNotify(l, "worker.receive");
        d.ev_mutex.lockUncancelable(d.io);
        d.waker = l.g;
        d.ev_mutex.unlock(d.io);
    }

    fn currentEpoch(d: *Domain) u64 {
        d.ev_mutex.lockUncancelable(d.io);
        defer d.ev_mutex.unlock(d.io);
        return d.epoch;
    }

    fn waitPast(d: *Domain, seen: u64) void {
        d.ev_mutex.lockUncancelable(d.io);
        defer d.ev_mutex.unlock(d.io);
        while (d.epoch == seen) d.ev_cond.waitUncancelable(d.io, &d.ev_mutex);
    }

    /// Joins finished threads and frees workers that nothing refers to.
    fn sweep(d: *Domain) void {
        var i: usize = 0;
        while (i < d.workers.items.len) {
            const w = d.workers.items[i];
            if (w.thread) |t| if (w.done.load(.acquire)) {
                t.join();
                w.thread = null;
            };
            if (w.thread == null and !w.handle_alive) {
                _ = d.workers.swapRemove(i);
                w.destroy(d.gpa);
            } else i += 1;
        }
    }
};

const domain_key = "worker.domain";
const self_key = "worker.self";
const mt_key = "worker.mt";

fn domainOf(l: *Thread) Error!*Domain {
    const g = l.g;
    if (g.ext.get(domain_key)) |p| return @ptrCast(@alignCast(p));
    // Domains and workers are shared between threads, so they use the
    // process allocator rather than the counting allocator of one state.
    const d = g.parent_gpa.create(Domain) catch return l.raiseMem();
    d.* = .{ .gpa = g.parent_gpa, .io = g.io };
    g.ext.put(g.gpa, domain_key, d) catch {
        g.parent_gpa.destroy(d);
        return l.raiseMem();
    };
    // A worker records its domain so a shutdown can reach a receive.
    if (selfOf(g)) |w| {
        w.in_mutex.lockUncancelable(g.io);
        w.child_domain = d;
        w.in_mutex.unlock(g.io);
    }
    return d;
}

fn selfOf(g: *Global) ?*Worker {
    const p = g.ext.get(self_key) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Whether `g` runs a worker body.
pub fn isWorker(g: *Global) bool {
    return g.ext.get(self_key) != null;
}

/// Marks every worker of `d` as shutting down and wakes those that wait
/// in `worker.peek`, in a scheduler, or in a `worker.receive` of their own.
fn signalShutdown(d: *Domain) void {
    const io = d.io;
    for (d.workers.items) |w| {
        w.in_mutex.lockUncancelable(io);
        w.shutdown = true;
        w.in_cond.broadcast(io);
        if (w.waker) |wg| sched.notify(wg);
        if (w.child_domain) |cd| cd.notify();
        w.in_mutex.unlock(io);
    }
}

/// How long a process that exits waits for its workers to stop.
const exit_grace: Io.Duration = .fromMilliseconds(500);

/// Stops the workers created by `g` before the process exits. A worker
/// stops at its next wait, so most end at once. One that computes or
/// blocks in a read the runtime cannot wake gets `exit_grace` to end.
/// Returns false when some worker still runs after that. Its thread and
/// everything it shares with this state are then left to the exit of the
/// process, which ends the thread.
pub fn stopForExit(g: *Global) bool {
    const p = g.ext.get(domain_key) orelse return true;
    const d: *Domain = @ptrCast(@alignCast(p));
    const io = d.io;
    signalShutdown(d);
    const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = exit_grace, .clock = .awake } }).toDeadline(io);
    d.ev_mutex.lockUncancelable(io);
    defer d.ev_mutex.unlock(io);
    while (true) {
        const all = for (d.workers.items) |w| {
            if (w.thread != null and !w.done.load(.acquire)) break false;
        } else true;
        if (all) return true;
        d.ev_cond.waitTimeout(io, &d.ev_mutex, deadline) catch return false;
    }
}

/// Stops every worker created by `g` and waits for their threads. Called
/// when the state closes.
pub fn closeState(g: *Global) void {
    const p = g.ext.get(domain_key) orelse return;
    const d: *Domain = @ptrCast(@alignCast(p));
    const io = d.io;
    signalShutdown(d);
    for (d.workers.items) |w| {
        if (w.thread) |t| t.join();
        w.thread = null;
        w.destroy(d.gpa);
    }
    d.workers.deinit(d.gpa);
    if (selfOf(g)) |w| {
        w.in_mutex.lockUncancelable(io);
        w.child_domain = null;
        w.in_mutex.unlock(io);
    }
    _ = g.ext.remove(domain_key);
    d.gpa.destroy(d);
}

/// Raises the uncatchable shutdown error when the creator of this worker
/// state is closing.
fn checkShutdown(l: *Thread, w: *Worker, comptime what: []const u8) Error!void {
    const io = l.g.io;
    w.in_mutex.lockUncancelable(io);
    const stop = w.shutdown;
    w.in_mutex.unlock(io);
    if (stop) return halt(l, what);
}

fn halt(l: *Thread, comptime what: []const u8) Error {
    l.g.halting = true;
    return l.raiseMsg(what ++ " interrupted: interpreter shutting down");
}

// ---------------------------------------------------------------------
// The worker thread

fn threadMain(w: *Worker) void {
    var msg: ?[]u8 = null;
    var val: ?*Packet = null;
    run(w, &msg, &val);
    w.out_mutex.lockUncancelable(w.domain.io);
    w.status = if (msg != null) .failed else .dead;
    w.err_msg = msg;
    w.err_value = val;
    w.out_mutex.unlock(w.domain.io);
    w.domain.notify();
    w.done.store(true, .release);
}

/// Copies an error value that is not a string out of the state of the
/// worker, so the creator raises the value itself. A value that cannot
/// cross, such as a table holding a function, leaves only its message.
fn keepError(l: *Thread, v: Value, val: *?*Packet) void {
    if (v.tag == .string or v.isNil()) return;
    val.* = encode(l, v) catch null;
}

fn run(w: *Worker, msg: *?[]u8, val: *?*Packet) void {
    const gpa = w.domain.gpa;
    const io = w.domain.io;
    const fail = struct {
        fn f(m: *?[]u8, a: Allocator, text: []const u8) void {
            m.* = a.dupe(u8, text) catch null;
            if (m.* == null) m.* = a.dupe(u8, "worker error") catch null;
        }
    }.f;
    const l = api.newStateSeeded(gpa, io, w.seed) catch return fail(msg, gpa, "failed to create worker state");
    const g = l.g;
    defer {
        // The inbox outlives the state, so it forgets the scheduler.
        w.in_mutex.lockUncancelable(io);
        w.waker = null;
        w.in_mutex.unlock(io);
        out.deinit(g);
        api.close(l);
    }
    g.environ = w.environ;
    if (w.environ_owned) {
        os.adoptEnviron(g, w.environ.?) catch return fail(msg, gpa, "failed to create worker state");
        w.environ_owned = false;
    }
    g.warn_on = w.warn_on;
    g.pause = w.pause;
    api.setFlags(l, w.flags) catch return fail(msg, gpa, "failed to create worker state");
    api.openLibs(l) catch return fail(msg, gpa, "failed to open worker libraries");
    // Preincluded modules come from the sources the CLI retained, so the
    // worker requires them without touching the file system.
    @import("package.zig").installPreincludes(l) catch return fail(msg, gpa, api.errorMessage(l, l.err));
    // The worker runs with its creator's permissions, sealed so that it
    // can never grant itself more.
    if (w.pledges) |p| {
        pledge.adopt(l, p, gpa) catch return fail(msg, gpa, "not enough memory");
        w.pledges = null;
    }
    g.ext.put(gpa, self_key, w) catch return fail(msg, gpa, "not enough memory");
    setup(l) catch return fail(msg, gpa, api.errorMessage(l, l.err));
    // A worker inherits a frozen environment, after its own functions are
    // in place.
    if (w.env_frozen) api.freezeEnv(l);

    if (w.load_error) |e| return fail(msg, gpa, e);
    const base = l.top;
    api.load(l, w.source.?, w.chunkname) catch return fail(msg, gpa, api.errorMessage(l, l.stack[l.top - 1]));
    for (w.args) |p| {
        const v = decode(l, p) catch return fail(msg, gpa, api.errorMessage(l, l.err));
        l.push(v) catch return fail(msg, gpa, api.errorMessage(l, l.err));
    }
    if (!api.pcall(l, @intCast(w.args.len), 0)) {
        const e = l.stack[l.top - 1];
        keepError(l, e, val);
        return fail(msg, gpa, api.errorMessage(l, e));
    }
    l.top = base;
    // The coroutines that the body detached run to their end, as they do
    // after the main chunk of a program. The error of one that failed
    // with nothing left to collect it is the error of the worker.
    // A shutdown ends the wait, and the state then closes the coroutines
    // that remain. It reaches a scheduler that waits for a socket through
    // the wake source of the scheduler.
    if (sched.active(g) and sched.enableNotify(g)) {
        w.in_mutex.lockUncancelable(io);
        w.waker = g;
        w.in_mutex.unlock(io);
    }
    sched.drainWhile(l, w, running) catch {
        keepError(l, l.err, val);
        return fail(msg, gpa, api.errorMessage(l, l.err));
    };
}

/// True until the creator of the worker `ctx` shuts it down.
fn running(ctx: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(ctx));
    const io = w.domain.io;
    w.in_mutex.lockUncancelable(io);
    defer w.in_mutex.unlock(io);
    return !w.shutdown;
}

/// Adds the worker-side functions to the `worker` table of a worker state.
fn setup(l: *Thread) Error!void {
    var t_v = try aux.getField(l, l.g.globals.as(Table), "worker");
    if (t_v.tag != .table) {
        t_v = Value.obj(.table, try l.newTable(0, 2));
        try aux.setGlobal(l, "worker", t_v);
    }
    try aux.setFuncs(l, t_v.as(Table), &.{
        .{ .name = "message", .func = message },
        .{ .name = "peek", .func = peek },
    });
}

/// worker.message(value): appends a copy of `value` to the outbox.
fn message(l: *Thread) Error!u32 {
    const w = selfOf(l.g) orelse return l.raiseFmt("worker.message called outside worker context", .{});
    const p = try encode(l, l.arg(1));
    w.out_mutex.lockUncancelable(l.g.io);
    w.outbox.push(p);
    w.out_mutex.unlock(l.g.io);
    w.domain.notify();
    return 0;
}

/// Gives the scheduler of the state of `l` a wake source, so another
/// thread can wake it. A wait that other coroutines share must never
/// sleep on a condition, since the event it waits for may need one of
/// those coroutines to run first. A system that cannot open the source,
/// for lack of memory or descriptors, therefore raises an error.
fn enableNotify(l: *Thread, what: []const u8) Error!void {
    if (!sched.enableNotify(l.g)) return l.raiseFmt("{s}: cannot wait while detached coroutines run (no wake source: out of memory or descriptors)", .{what});
}

/// True when a wait for the inbox of `w` goes through the scheduler of
/// the state of `l`: detached coroutines exist. Every later change of the
/// inbox then wakes that scheduler.
fn inboxWakes(w: *Worker, l: *Thread) Error!bool {
    const g = l.g;
    if (!sched.active(g)) return false;
    if (w.waker != null) return true;
    try enableNotify(l, "worker.peek");
    w.in_mutex.lockUncancelable(g.io);
    w.waker = g;
    w.in_mutex.unlock(g.io);
    return true;
}

/// worker.peek(): waits until the creator sends a value and returns it.
/// The detached coroutines of the worker run while it waits.
fn peek(l: *Thread) Error!u32 {
    const w = selfOf(l.g) orelse return l.raiseFmt("worker.peek called outside worker context", .{});
    const io = l.g.io;
    while (true) {
        const scheduled = try inboxWakes(w, l);
        w.in_mutex.lockUncancelable(io);
        if (!scheduled) {
            while (w.inbox.head == null and !w.shutdown) w.in_cond.waitUncancelable(io, &w.in_mutex);
        }
        const p = w.inbox.pop();
        const stop = w.shutdown;
        w.in_mutex.unlock(io);
        if (p) |pk| {
            defer pk.destroy(l.g.parent_gpa);
            return aux.ret(l, try decode(l, pk));
        }
        if (stop) return halt(l, "worker.peek");
        // The inbox was empty a moment ago, so the next value or the
        // shutdown wakes the scheduler.
        try sched.waitNotify(l);
    }
}

// ---------------------------------------------------------------------
// The creator's functions

fn checkWorker(l: *Thread, i: u32) Error!*Worker {
    const v = l.arg(i);
    if (v.tag == .userdata) {
        const u = v.as(Userdata);
        if (l.g.ext.get(mt_key)) |mt| if (u.metatable == @as(*Table, @ptrCast(@alignCast(mt)))) {
            const slot: *?*Worker = @ptrCast(@alignCast(u.data()));
            return slot.* orelse aux.argError(l, i, "released worker handle", .{});
        };
    }
    return aux.typeError(l, i, "worker");
}

/// The command line flags of `g` as `-F` specifications, so a worker
/// sees the same `flags` values.
fn flagSpecs(l: *Thread) Error![][]u8 {
    const gpa = l.g.parent_gpa;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    if (l.g.ext.get("flags.compile")) |p| {
        const map: *std.StringHashMapUnmanaged(Value) = @ptrCast(@alignCast(p));
        var it = map.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const v = e.value_ptr.*;
            const spec = switch (v.tag) {
                .integer => std.fmt.allocPrint(gpa, "{s}={d}", .{ name, v.asInt() }),
                .float => std.fmt.allocPrint(gpa, "{s}={e}", .{ name, v.asFloat() }),
                .string => std.fmt.allocPrint(gpa, "{s}={s}", .{ name, v.as(String).bytes() }),
                else => gpa.dupe(u8, name),
            } catch return l.raiseMem();
            list.append(gpa, spec) catch {
                gpa.free(spec);
                return l.raiseMem();
            };
        }
    }
    return list.toOwnedSlice(gpa) catch l.raiseMem();
}

/// worker.create(path, ...): starts a worker running the script at `path`
/// with the remaining arguments as its varargs.
fn create(l: *Thread) Error!u32 {
    const g = l.g;
    const gpa = g.parent_gpa;
    const path = try aux.checkBytes(l, 1);
    try pledge.require(l, "load", null);
    try pledge.require(l, "fs:read", path);
    const d = try domainOf(l);
    d.sweep();

    const w = gpa.create(Worker) catch return l.raiseMem();
    w.* = .{ .domain = d, .chunkname = &.{} };
    var started = false;
    defer if (!started) w.destroy(gpa);
    w.chunkname = std.fmt.allocPrint(gpa, "@{s}", .{path}) catch return l.raiseMem();
    // The creator opens the script, so the worker reads exactly the file
    // its creator was allowed to read.
    if (Io.Dir.cwd().readFileAlloc(g.io, path, gpa, .unlimited)) |src| {
        w.source = src;
    } else |e| {
        const reason = @import("os.zig").errnoOf(e).msg;
        w.load_error = std.fmt.allocPrint(gpa, "cannot open worker script '{s}': {s}", .{ path, reason }) catch return l.raiseMem();
    }
    var args: std.ArrayList(*Packet) = .empty;
    errdefer {
        for (args.items) |p| p.destroy(gpa);
        args.deinit(gpa);
    }
    var i: u32 = 2;
    while (i <= l.argCount()) : (i += 1) {
        const p = try encode(l, l.arg(i));
        args.append(gpa, p) catch {
            p.destroy(gpa);
            return l.raiseMem();
        };
    }
    w.args = args.toOwnedSlice(gpa) catch return l.raiseMem();
    w.flags = try flagSpecs(l);
    w.pledges = pledge.snapshot(l) catch return l.raiseMem();
    // A creator that changed its environment gives the worker a copy, so
    // the two never share a map that one of them writes.
    if (os.ownedEnviron(g) != null) {
        w.environ = os.copyEnviron(g) catch return l.raiseMem();
        w.environ_owned = true;
    } else w.environ = g.environ;
    w.warn_on = g.warn_on;
    w.env_frozen = g.env_frozen;
    w.pause = g.pause;
    w.seed = g.seed;

    // The handle, rooted on the stack before the thread starts.
    const u = gc.alloc(g, Userdata, .userdata, Userdata.allocSize(@sizeOf(?*Worker), 0)) catch return l.raiseMem();
    u.size = @sizeOf(?*Worker);
    const mt: *Table = @ptrCast(@alignCast(g.ext.get(mt_key).?));
    u.metatable = mt;
    const slot: *?*Worker = @ptrCast(@alignCast(u.data()));
    slot.* = null;
    try l.push(Value.obj(.userdata, u));
    try @import("base.zig").registerFinalizer(l, &u.hdr, mt);

    d.workers.append(gpa, w) catch return l.raiseMem();
    w.thread = std.Thread.spawn(.{}, threadMain, .{w}) catch {
        _ = d.workers.pop();
        return l.raiseFmt("failed to start worker thread", .{});
    };
    started = true;
    slot.* = w;
    return 1;
}

/// worker.status(w): "running" or "dead".
fn status(l: *Thread) Error!u32 {
    const w = try checkWorker(l, 1);
    w.out_mutex.lockUncancelable(l.g.io);
    const s = w.status;
    w.out_mutex.unlock(l.g.io);
    return aux.retStr(l, if (s == .running) "running" else "dead");
}

/// worker.send(w, value): appends a copy of `value` to the inbox of `w`.
fn send(l: *Thread) Error!u32 {
    const w = try checkWorker(l, 1);
    const p = try encode(l, l.arg(2));
    w.in_mutex.lockUncancelable(l.g.io);
    w.inbox.push(p);
    w.in_cond.signal(l.g.io);
    if (w.waker) |wg| sched.notify(wg);
    w.in_mutex.unlock(l.g.io);
    return 0;
}

/// worker.receive(w1, ...): waits until one of the workers has a message
/// or all of them have finished. Returns one value per worker, the
/// message in the ready worker's position and nil elsewhere. An error
/// in a worker is raised here. The detached coroutines of the state run
/// while it waits.
fn receive(l: *Thread) Error!u32 {
    const n = l.argCount();
    if (n == 0) return l.raiseFmt("expected at least one worker", .{});
    var i: u32 = 1;
    while (i <= n) : (i += 1) _ = try checkWorker(l, i);
    const d = try domainOf(l);
    const io = l.g.io;
    const self = selfOf(l.g);
    while (true) {
        // The outboxes are read after this, so an event that follows the
        // reading wakes the scheduler.
        const scheduled = sched.active(l.g);
        if (scheduled) try d.wakes(l);
        const seen = d.currentEpoch();
        var all_dead = true;
        i = 1;
        while (i <= n) : (i += 1) {
            const w = try checkWorker(l, i);
            w.out_mutex.lockUncancelable(io);
            // Messages sent before the error arrive first.
            const p = w.outbox.pop();
            if (p) |pk| {
                w.out_mutex.unlock(io);
                defer pk.destroy(l.g.parent_gpa);
                const v = try decode(l, pk);
                try l.ensure(n);
                var j: u32 = 1;
                while (j <= n) : (j += 1) l.push(if (j == i) v else .nil) catch unreachable;
                return n;
            }
            if (w.status == .failed) {
                if (w.err_value) |pk| {
                    // A copy of the value is raised, so every receive
                    // raises an equal value.
                    const v = decode(l, pk) catch |e| {
                        w.out_mutex.unlock(io);
                        return e;
                    };
                    w.out_mutex.unlock(io);
                    return l.raise(v);
                }
                const text = w.err_msg orelse "worker error";
                const s = l.newString(text) catch |e| {
                    w.out_mutex.unlock(io);
                    return e;
                };
                w.out_mutex.unlock(io);
                return l.raise(Value.obj(.string, s));
            }
            if (w.status == .running) all_dead = false;
            w.out_mutex.unlock(io);
        }
        if (all_dead) {
            try l.ensure(n);
            var j: u32 = 0;
            while (j < n) : (j += 1) l.push(.nil) catch unreachable;
            return n;
        }
        if (self) |w| try checkShutdown(l, w, "worker.receive");
        if (scheduled) try sched.waitNotify(l) else d.waitPast(seen);
        if (self) |w| try checkShutdown(l, w, "worker.receive");
    }
}

fn handleGc(l: *Thread) Error!u32 {
    const v = l.arg(1);
    if (v.tag != .userdata) return 0;
    const slot: *?*Worker = @ptrCast(@alignCast(v.as(Userdata).data()));
    const w = slot.* orelse return 0;
    slot.* = null;
    w.handle_alive = false;
    w.domain.sweep();
    return 0;
}

fn handleToString(l: *Thread) Error!u32 {
    const w = try checkWorker(l, 1);
    var buf: [64]u8 = undefined;
    return aux.retStr(l, std.fmt.bufPrint(&buf, "worker: 0x{x}", .{@intFromPtr(w)}) catch "worker");
}

pub fn open(l: *Thread) Error!void {
    const g = l.g;
    const mt = try l.newTable(0, 4);
    try aux.setField(l, g.registry.as(Table), "worker.state", Value.obj(.table, mt));
    try aux.setField(l, mt, "__name", try l.newStringValue("worker"));
    try aux.setField(l, mt, "__gc", try aux.native(l, handleGc, "gc"));
    try aux.setField(l, mt, "__tostring", try aux.native(l, handleToString, "tostring"));
    g.ext.put(g.gpa, mt_key, mt) catch return l.raiseMem();
    const t = try aux.newLib(l, &.{
        .{ .name = "create", .func = create },
        .{ .name = "status", .func = status },
        .{ .name = "receive", .func = receive },
        .{ .name = "send", .func = send },
    });
    try aux.setGlobal(l, "worker", Value.obj(.table, t));
}
