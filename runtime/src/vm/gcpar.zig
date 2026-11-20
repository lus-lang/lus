//! Parallel marking on native targets. A mark phase that has a lot of
//! gray objects left while the program is stopped traces them on several
//! threads. Each thread traces from its own gray stack and claims an
//! object by setting its mark bit atomically, so every object is traced
//! once. A thread whose stack runs empty takes work from a shared pool,
//! which threads with long stacks refill in chunks while some thread
//! waits. The drain ends when every thread waits and the pool is empty.
//! The helper threads belong to the process and serve one state at a
//! time. A state that finds them busy marks alone. The design is
//! described in `spec/design/gc.md`.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const state_mod = @import("state.zig");
const Global = state_mod.Global;
const Header = gc.Header;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

/// Parallel marking needs threads, so the WebAssembly build and
/// single-threaded builds mark alone.
pub const enabled = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

const Entry = *align(1) Header;
const GrayList = gc.GrayList;

/// Entries moved between threads at once.
const chunk_len = 1024;

/// The most threads that mark together, the calling thread included.
const max_workers = 8;

/// Gray stacks of helper threads live in the C heap, which every thread
/// may use. The heap of the state counts its bytes without locking.
pub const stack_alloc: Allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

const Chunk = struct {
    next: ?*Chunk = null,
    len: usize = 0,
    items: [chunk_len]Entry = undefined,
};

/// A lock for short critical sections: the pool of chunks and the rare
/// appends to the lists of the collector.
pub const SpinLock = struct {
    state: Atomic(bool) = .init(false),

    pub fn lock(s: *SpinLock) void {
        while (s.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            while (s.state.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(s: *SpinLock) void {
        s.state.store(false, .release);
    }
};

/// One parallel drain of the gray stack. It lives on the stack of the
/// thread that started it, which waits for every helper to leave it.
pub const Drain = struct {
    /// The counters that threads change while others read them each get
    /// a cache line of their own.
    idle: Atomic(u32) align(std.atomic.cache_line) = .init(0),
    next_initial: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    shared: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    /// Threads in the drain, the calling one included. A helper joins
    /// when it wakes, so a slow one never holds the drain up.
    joined: Atomic(u32) align(std.atomic.cache_line) = .init(1),
    /// Set when the drain found no work left. Helpers that wake later
    /// stay out.
    done: Atomic(bool) = .init(false),
    g: *Global,
    /// The gray stack of the state when the drain started. Threads take
    /// ranges of it by advancing `next_initial`.
    initial: []const Entry,
    /// Chunks that threads with long stacks gave away.
    lock: SpinLock = .{},
    full: ?*Chunk = null,
    /// Helpers that joined and have not left yet.
    active: Atomic(u32) = .init(0),
    /// Bytes traced by the helpers.
    work: Atomic(usize) = .init(0),

    fn hasShared(d: *Drain) bool {
        return d.shared.load(.acquire) != 0 or d.next_initial.load(.monotonic) < d.initial.len;
    }

    /// Fills `stack` with work from the pool. Returns false when the pool
    /// is empty.
    fn take(d: *Drain, stack: *GrayList) bool {
        if (d.shared.load(.acquire) != 0) {
            d.lock.lock();
            const c = d.full;
            if (c) |ch| {
                d.full = ch.next;
                _ = d.shared.fetchSub(1, .release);
            }
            d.lock.unlock();
            if (c) |ch| {
                defer freeChunk(ch);
                stack.appendSlice(stack_alloc, ch.items[0..ch.len]) catch {
                    // Without room, the entries are traced right away.
                    var m = gc.ParMarker.initPar(d, stack);
                    for (ch.items[0..ch.len]) |e| m.visit(e);
                    m.flush();
                };
                return true;
            }
        }
        if (d.next_initial.load(.monotonic) < d.initial.len) {
            const i = d.next_initial.fetchAdd(chunk_len, .monotonic);
            if (i < d.initial.len) {
                const part = d.initial[i..@min(i + chunk_len, d.initial.len)];
                stack.appendSlice(stack_alloc, part) catch {
                    var m = gc.ParMarker.initPar(d, stack);
                    for (part) |e| m.visit(e);
                    m.flush();
                };
                return true;
            }
        }
        return false;
    }

    /// Moves entries below the top of `stack` into chunks of the pool,
    /// one per waiting thread. The top entries stay, since `popGray`
    /// already prefetched them.
    fn give(d: *Drain, stack: *GrayList) void {
        var want = d.idle.load(.monotonic);
        while (want > 0 and stack.items.len >= 2 * chunk_len + keep_top) : (want -= 1) {
            const c = newChunk() orelse return;
            const n = stack.items.len;
            const from = n - keep_top - chunk_len;
            @memcpy(c.items[0..chunk_len], stack.items[from..][0..chunk_len]);
            c.len = chunk_len;
            std.mem.copyForwards(Entry, stack.items[from..][0..keep_top], stack.items[n - keep_top ..][0..keep_top]);
            stack.items.len = n - chunk_len;
            d.lock.lock();
            c.next = d.full;
            d.full = c;
            _ = d.shared.fetchAdd(1, .release);
            d.lock.unlock();
        }
    }
};

/// Entries at the top of a gray stack that `give` leaves in place.
const keep_top = 16;

/// Visits between two checks for waiting threads.
const share_interval = 32;

/// The tracing loop of one thread.
fn work(d: *Drain, index: u32) void {
    const stack = &pool.stacks[index].list;
    stack.clearRetainingCapacity();
    var m = gc.ParMarker.initPar(d, stack);
    outer: while (true) {
        var n: u32 = 0;
        while (gc.popGray(stack)) |e| {
            m.visit(e);
            n +%= 1;
            if (n % share_interval == 0 and stack.items.len >= 2 * chunk_len + keep_top and d.idle.load(.monotonic) != 0) d.give(stack);
        }
        if (d.take(stack)) continue;
        // Wait for work. The drain ends when every thread in it waits and
        // the pool is empty: only a thread with work of its own refills
        // it. A helper that joins later starts without work.
        _ = d.idle.fetchAdd(1, .acq_rel);
        while (true) {
            if (d.hasShared()) {
                _ = d.idle.fetchSub(1, .acq_rel);
                if (d.take(stack)) continue :outer;
                _ = d.idle.fetchAdd(1, .acq_rel);
                continue;
            }
            if (d.done.load(.acquire)) break :outer;
            if (d.idle.load(.acquire) == d.joined.load(.acquire)) {
                d.done.store(true, .release);
                break :outer;
            }
            std.atomic.spinLoopHint();
        }
    }
    m.flush();
    // A large stack goes back to the C heap, as the gray stack of the
    // state does after a mark phase.
    if (stack.capacity > gc.gray_keep) stack.clearAndFree(stack_alloc);
}

// ---------------------------------------------------------------------
// Chunks

var free_lock: SpinLock = .{};
var free_chunks: ?*Chunk = null;
var nfree: usize = 0;

/// Chunks kept for the next drain.
const max_free_chunks = 256;

fn newChunk() ?*Chunk {
    free_lock.lock();
    if (free_chunks) |c| {
        free_chunks = c.next;
        nfree -= 1;
        free_lock.unlock();
        return c;
    }
    free_lock.unlock();
    return stack_alloc.create(Chunk) catch null;
}

fn freeChunk(c: *Chunk) void {
    free_lock.lock();
    if (nfree < max_free_chunks) {
        c.next = free_chunks;
        free_chunks = c;
        nfree += 1;
        free_lock.unlock();
        return;
    }
    free_lock.unlock();
    stack_alloc.destroy(c);
}

// ---------------------------------------------------------------------
// Helper threads

const Pool = struct {
    /// Set while a state drains in parallel.
    busy: Atomic(bool) = .init(false),
    /// Set once the helpers were started (or could not be).
    started: Atomic(u8) = .init(0),
    start_lock: SpinLock = .{},
    helpers: u32 = 0,
    /// Bumped for every drain. Helpers wait for it to change.
    gen: Atomic(u32) = .init(0),
    /// The current drain, its generation, and its size, read together
    /// under `job_lock`.
    job_lock: SpinLock = .{},
    job: ?*Drain = null,
    job_gen: u32 = 0,
    sleepers: Atomic(u32) = .init(0),
    /// One gray stack per thread, kept between drains. Each has its own
    /// cache line, since its thread writes its length at every push.
    stacks: [max_workers]Stack = @splat(.{}),
};

var pool: Pool = .{};

const Stack = struct {
    list: GrayList align(std.atomic.cache_line) = .empty,
};

/// The futex calls of `std.Io.Threaded` only reach the operating system,
/// so the helpers use a private instance that every state shares.
var futex_io: std.Io.Threaded = .init_single_threaded;

/// Spins before a helper sleeps, so that drains in quick succession,
/// such as those of an atomic phase, find the helpers awake.
const spin_limit = 20_000;

/// The number of threads that mark, the calling one included. Set with
/// `LUS_GC_THREADS` (1 marks alone). The default uses up to eight
/// threads and leaves one processor to the rest of the system. On Linux
/// `getCpuCount` counts the processors of the affinity mask of the
/// process, so a container limited to a few processors starts few
/// helpers.
fn wantedWorkers() u32 {
    if (std.c.getenv("LUS_GC_THREADS")) |s| {
        const n = std.fmt.parseInt(u32, std.mem.span(s), 10) catch 0;
        if (n >= 1) return @min(n, max_workers);
    }
    const cpus = std.Thread.getCpuCount() catch 1;
    return @intCast(std.math.clamp(cpus -| 1, 1, max_workers));
}

/// The stack of a helper thread. The C library of Linux places the
/// static thread-local storage of every thread at the top of its stack,
/// and that storage holds the alternate signal stack of the standard
/// library (`std.options.signal_stack_size`, 256 KiB by default). The
/// size therefore counts that storage on top of the room the helper
/// needs for tracing and for the thread-local data of the C libraries.
const helper_stack_size: usize = 512 * 1024 + (std.options.signal_stack_size orelse 0);

fn startHelpers() void {
    pool.start_lock.lock();
    defer pool.start_lock.unlock();
    if (pool.started.load(.acquire) != 0) return;
    const want = wantedWorkers();
    var k: u32 = 1;
    // A helper that fails to start leaves the drain to the threads that
    // did start. With none, every drain runs on the calling thread.
    while (k < want) : (k += 1) {
        if (!spawnHelper(k)) break;
        pool.helpers = k;
    }
    pool.started.store(1, .release);
}

/// Starts helper `index` as a detached thread. Returns false when the
/// system refuses a new thread. With POSIX threads the runtime calls
/// the C library itself, so that every error of `pthread_create` comes
/// back as a value.
fn spawnHelper(index: u32) bool {
    if (!std.Thread.use_pthreads) {
        const t = std.Thread.spawn(.{ .stack_size = helper_stack_size }, helperMain, .{index}) catch return false;
        t.detach();
        return true;
    }
    const c = std.c;
    const arg: ?*anyopaque = @ptrFromInt(@as(usize, index) + 1);
    var handle: c.pthread_t = undefined;
    var attr: c.pthread_attr_t = undefined;
    var started = false;
    if (c.pthread_attr_init(&attr) == .SUCCESS) {
        if (c.pthread_attr_setstacksize(&attr, helper_stack_size) == .SUCCESS)
            started = c.pthread_create(&handle, &attr, helperEntry, arg) == .SUCCESS;
        _ = c.pthread_attr_destroy(&attr);
    }
    // The default attributes of the C library size the stack for its
    // own thread-local storage, so they serve as the second try.
    if (!started) started = c.pthread_create(&handle, null, helperEntry, arg) == .SUCCESS;
    if (!started) return false;
    _ = c.pthread_detach(handle);
    return true;
}

/// The entry point of a helper started with POSIX threads. The index
/// arrives in the argument pointer, offset by one to keep it non-null.
fn helperEntry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    std.Thread.maybeAttachSignalStack();
    helperMain(@intCast(@intFromPtr(arg) - 1));
    return null;
}

fn helperMain(index: u32) void {
    var seen: u32 = 0;
    while (true) {
        var spins: u32 = 0;
        while (pool.gen.load(.acquire) == seen) {
            if (spins < spin_limit) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            _ = pool.sleepers.fetchAdd(1, .seq_cst);
            if (pool.gen.load(.seq_cst) == seen) futex_io.io().futexWaitUncancelable(u32, &pool.gen.raw, seen);
            _ = pool.sleepers.fetchSub(1, .seq_cst);
        }
        // A helper joins the drain it woke for unless that drain ended.
        // Joining happens under the lock that the drain takes before it
        // returns, so a helper never touches a drain that is gone.
        pool.job_lock.lock();
        seen = pool.job_gen;
        const d = pool.job orelse {
            pool.job_lock.unlock();
            continue;
        };
        if (d.done.load(.acquire)) {
            pool.job_lock.unlock();
            continue;
        }
        _ = d.joined.fetchAdd(1, .acq_rel);
        _ = d.active.fetchAdd(1, .acq_rel);
        pool.job_lock.unlock();
        work(d, index);
        _ = d.active.fetchSub(1, .acq_rel);
    }
}

/// Gray entries below which a drain stays on one thread. The stress
/// build drains in parallel as often as it can, to exercise the drain.
pub const min_entries: usize = if (gc.stress != 0) 32 else 4096;

/// Objects a drain traces alone between two checks of `min_entries`.
pub const check_interval: u32 = if (gc.stress != 0) 16 else 1024;

/// Traces every entry of the gray stack of `g` and everything they
/// reach on several threads. Returns false, leaving the stack as it is,
/// when the helpers serve another state or there are none. `work`
/// receives the bytes traced.
pub fn drain(g: *Global, work_out: *usize) bool {
    if (!enabled) return false;
    if (pool.started.load(.acquire) == 0) startHelpers();
    if (pool.helpers == 0) return false;
    if (pool.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return false;
    defer pool.busy.store(false, .release);
    const s = &g.gcs;
    var d: Drain = .{ .g = g, .initial = s.gray.items };
    pool.job_lock.lock();
    pool.job = &d;
    const gen = pool.gen.load(.monotonic) +% 1;
    pool.job_gen = gen;
    pool.job_lock.unlock();
    // The store and the load of `sleepers` pair with the increment of
    // `sleepers` and the load of `gen` in `helperMain`. Both sides are
    // sequentially consistent, so a helper that goes to sleep either sees
    // the new generation or is counted here and woken.
    pool.gen.store(gen, .seq_cst);
    if (pool.sleepers.load(.seq_cst) != 0) futex_io.io().futexWake(u32, &pool.gen.raw, std.math.maxInt(u32));
    // The calling thread takes part as worker zero.
    work(&d, 0);
    pool.job_lock.lock();
    pool.job = null;
    pool.job_lock.unlock();
    while (d.active.load(.acquire) != 0) std.atomic.spinLoopHint();
    s.gray.clearRetainingCapacity();
    work_out.* += d.work.load(.monotonic);
    return true;
}
