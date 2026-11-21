//! Edge coverage of the runtime, compiled in by `-Dcoverage=true`.
//!
//! The build instruments the runtime with the same pass that `zig build
//! test --fuzz` uses: LLVM gives every edge of the control flow graph an
//! 8-bit counter in the section `__sancov_cntrs` and records the address
//! of each edge in `__sancov_pcs1`, which the linker brackets with start
//! and end symbols, as the fuzzer of the Zig test runner reads them. Edge
//! coverage counts both sides of every branch, so the share of edges
//! covered is the branch coverage of the code.
//!
//! `LUS_COVERAGE=DIR` makes every process write the edges it reached to a
//! file of its own in DIR when it exits, so the processes that `lus test`
//! starts all count. `LUS_COVERAGE_REPORT=DIR` makes `lus` merge the files
//! of DIR, map each edge to its source file through the debug information
//! of the binary, and print the coverage of each directory of `src` and
//! the files with the most uncovered edges. With `LUS_COVERAGE_FILE` set to
//! a path below `src`, such as `vm/interp.zig`, the report lists the lines
//! of that file that hold an uncovered edge instead. The files and the
//! report must come from the same build.

const std = @import("std");
const builtin = @import("builtin");

export fn __sanitizer_cov_trace_pc_indir(callee: usize) void {
    _ = callee;
}

const prefix: [2][]const u8 = switch (builtin.object_format) {
    .elf => .{ "__start_", "__stop_" },
    .macho => .{ "\x01section$start$__DATA$", "\x01section$end$__DATA$" },
    else => @compileError("coverage needs ELF or Mach-O"),
};

/// One counter per edge.
fn counters() []u8 {
    const start = @extern([*]u8, .{ .name = prefix[0] ++ "__sancov_cntrs", .linkage = .weak }) orelse return &.{};
    const end = @extern([*]u8, .{ .name = prefix[1] ++ "__sancov_cntrs", .linkage = .weak }) orelse return &.{};
    return start[0 .. end - start];
}

/// The address of each edge, in the order of the counters.
fn pcs() []const usize {
    const start = @extern([*]usize, .{ .name = prefix[0] ++ "__sancov_pcs1", .linkage = .weak }) orelse return &.{};
    const end = @extern([*]usize, .{ .name = prefix[1] ++ "__sancov_pcs1", .linkage = .weak }) orelse return &.{};
    return start[0 .. end - start];
}

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;

var out_dir: ?[]const u8 = null;
var dir_buf: [1024]u8 = undefined;

/// Reads `LUS_COVERAGE` and arranges for the edges to be written when the
/// process exits, however it exits.
pub fn setup(environ: anytype) void {
    const d = environ.get("LUS_COVERAGE") orelse return;
    if (d.len > dir_buf.len) return;
    @memcpy(dir_buf[0..d.len], d);
    out_dir = dir_buf[0..d.len];
    _ = atexit(dumpAtExit);
}

fn dumpAtExit() callconv(.c) void {
    dump();
}

/// A digest of the layout of the edges, which tells the files of one build
/// from those of another. It hashes the distance of each edge from the
/// first real one, which the slide of the loaded image leaves unchanged.
fn digest() u64 {
    const table = pcs();
    // LLVM leaves some entries as the placeholder 1, which the loader does
    // not relocate, so they hash as themselves.
    var base: usize = 0;
    for (table) |pc| if (pc > 1) {
        base = pc;
        break;
    };
    var h = std.hash.Wyhash.init(0);
    for (table) |pc| {
        const d = if (pc <= 1) pc else pc -% base;
        h.update(std.mem.asBytes(&d));
    }
    return h.final();
}

const magic = "LUSCOV1\x00";

/// Writes the header, then one byte per edge, 1 when the edge ran, to a new
/// file in the directory of `LUS_COVERAGE`.
pub fn dump() void {
    const dir = out_dir orelse return;
    out_dir = null;
    var name_buf: [1200]u8 = undefined;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}/{d}-{d}-{d}.cov", .{ dir, std.c.getpid(), ts.sec, ts.nsec }, 0) catch return;
    const fd = std.c.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    const c = counters();
    var header: [16]u8 = undefined;
    @memcpy(header[0..8], magic);
    std.mem.writeInt(u64, header[8..16], digest(), .little);
    _ = std.c.write(fd, &header, header.len);
    var chunk: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < c.len) {
        const n = @min(chunk.len, c.len - i);
        for (0..n) |k| chunk[k] = @intFromBool(c[i + k] != 0);
        _ = std.c.write(fd, &chunk, n);
        i += n;
    }
}

const Tally = struct { total: usize = 0, hit: usize = 0 };

/// Merges the coverage files of `dir` and prints the report.
pub fn report(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, only: ?[]const u8) !u8 {
    const table = pcs();
    const n = @min(counters().len, table.len);
    const merged = try gpa.alloc(u8, n);
    defer gpa.free(merged);
    @memset(merged, 0);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var files: usize = 0;
    var foreign: usize = 0;
    const mine = digest();
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".cov")) continue;
        const data = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        defer gpa.free(data);
        if (data.len != n + 16 or !std.mem.eql(u8, data[0..8], magic) or std.mem.readInt(u64, data[8..16], .little) != mine) {
            foreign += 1;
            continue;
        }
        for (data[16..], 0..) |b, i| merged[i] |= b;
        files += 1;
    }
    if (foreign > 0) std.debug.print("lus: skipped {d} coverage files of another build\n", .{foreign});

    const si = try std.debug.getSelfDebugInfo();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var by_dir: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    var by_file: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    // Lines of `only` with an uncovered edge, and with a covered one.
    var missed_lines: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    var hit_lines: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    for (0..n) |i| {
        symbols.clearRetainingCapacity();
        si.getSymbols(io, arena, arena, table[i], false, &symbols) catch continue;
        if (symbols.items.len == 0) continue;
        const loc = symbols.items[0].source_location orelse continue;
        const at = std.mem.indexOf(u8, loc.file_name, "/runtime/src/") orelse continue;
        const rel = loc.file_name[at + "/runtime/src/".len ..];
        const top = if (std.mem.indexOfScalar(u8, rel, '/')) |s| rel[0..s] else ".";
        const hit = merged[i] != 0;
        if (only) |want| if (std.mem.eql(u8, rel, want)) {
            try (if (hit) &hit_lines else &missed_lines).put(arena, loc.line, {});
        };
        inline for (.{ &by_dir, &by_file }, .{ top, rel }) |map, key| {
            const gop = try map.getOrPut(arena, try arena.dupe(u8, key));
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.total += 1;
            if (hit) gop.value_ptr.hit += 1;
        }
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    if (only) |want| {
        const lines = missed_lines.keys();
        std.mem.sort(u64, lines, {}, std.sort.asc(u64));
        try o.print("lines of {s} with an uncovered edge (* when no edge of the line ran):\n", .{want});
        for (lines) |ln| try o.print("  {d}{s}\n", .{ ln, if (hit_lines.contains(ln)) "" else " *" });
        try o.flush();
        return 0;
    }
    try o.print("{d} coverage files, {d} edges\n\nedges covered by directory of src:\n", .{ files, n });
    var all: Tally = .{};
    for (by_dir.keys(), by_dir.values()) |k, v| {
        try o.print("  {s:<10} {d:>6.1}%  {d} of {d}\n", .{ k, pct(v), v.hit, v.total });
        all.hit += v.hit;
        all.total += v.total;
    }
    try o.print("  {s:<10} {d:>6.1}%  {d} of {d}\n\nfiles with the most uncovered edges:\n", .{ "all", pct(all), all.hit, all.total });
    const Entry = struct { name: []const u8, missed: usize, t: Tally };
    var list: std.ArrayList(Entry) = .empty;
    for (by_file.keys(), by_file.values()) |k, v| try list.append(arena, .{ .name = k, .missed = v.total - v.hit, .t = v });
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.missed > b.missed;
        }
    }.lt);
    for (list.items[0..@min(25, list.items.len)]) |e| {
        try o.print("  {s:<34} {d:>6.1}%  {d} uncovered\n", .{ e.name, pct(e.t), e.missed });
    }
    try o.flush();
    return 0;
}

fn pct(t: Tally) f64 {
    if (t.total == 0) return 0;
    return @as(f64, @floatFromInt(t.hit)) * 100.0 / @as(f64, @floatFromInt(t.total));
}
