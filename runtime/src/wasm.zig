//! Root of the WebAssembly build (`zig build wasm`). The module is a WASI
//! reactor: it exports the whole C embedding interface of `include/lus.h`
//! and a few helpers for the JavaScript host in `packages/wasm`, so the
//! host copies source text into linear memory and drives states with the
//! same calls a C host uses. Standard output and standard error reach the
//! host through the WASI `fd_write` import.

const std = @import("std");
const state = @import("vm/state.zig");
const Thread = state.Thread;

comptime {
    _ = @import("capi.zig");
}

const gpa = std.heap.c_allocator;

extern fn lus_close(l: *Thread) void;

/// Allocates `n` bytes of linear memory for the host. Returns 0 when the
/// memory cannot grow.
export fn lus_wasm_alloc(n: usize) ?[*]u8 {
    return @ptrCast(std.c.malloc(@max(n, 1)));
}

/// Frees memory returned by `lus_wasm_alloc`.
export fn lus_wasm_free(p: ?[*]u8) void {
    std.c.free(p);
}

/// Gives the state the environment of the WASI host, so `os.getenv` and
/// the `env` capability see the variables the host passed. Returns 0 on
/// success and -1 when memory runs out.
export fn lus_wasm_environ(l: *Thread) c_int {
    const g = l.g;
    if (g.environ != null) return 0;
    const map = gpa.create(std.process.Environ.Map) catch return -1;
    map.* = .init(gpa);
    loadEnviron(map) catch {
        map.deinit();
        gpa.destroy(map);
        return -1;
    };
    g.environ = map;
    return 0;
}

fn loadEnviron(map: *std.process.Environ.Map) !void {
    const wasi = std.os.wasi;
    var count: usize = 0;
    var size: usize = 0;
    if (wasi.environ_sizes_get(&count, &size) != .SUCCESS) return;
    const ptrs = try gpa.alloc([*:0]u8, count);
    defer gpa.free(ptrs);
    const buf = try gpa.alloc(u8, size);
    defer gpa.free(buf);
    if (wasi.environ_get(ptrs.ptr, buf.ptr) != .SUCCESS) return;
    for (ptrs) |p| {
        const entry = std.mem.span(p);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        try map.put(entry[0..eq], entry[eq + 1 ..]);
    }
}

/// Writes the buffered standard output of the state to the host. The host
/// calls it after each run, since a state that stays open would otherwise
/// keep up to 64 KiB of output until it closes.
export fn lus_wasm_flush(l: *Thread) void {
    @import("lib/out.zig").flushAll(l.g);
}

/// Registers the compile function of the host, an entry of the exported
/// function table, so that hot functions compile to WebAssembly. A host
/// that never calls this keeps every state interpreted. See
/// `spec/design/wasmjit.md`.
export fn lus_wasm_jit_host(index: u32) void {
    @import("jit/wasm.zig").setHost(index);
}

/// The address of the JIT statistics: four 32-bit counts of functions
/// compiled, modules that failed, modules deferred, and bytes emitted.
export fn lus_wasm_jit_stats() *const anyopaque {
    return &@import("jit/wasm.zig").stats;
}

/// Closes a state like `lus_close` and frees the environment that
/// `lus_wasm_environ` gave it.
export fn lus_wasm_close(l: *Thread) void {
    const env = l.g.environ;
    lus_close(l);
    if (env) |map| {
        map.deinit();
        gpa.destroy(map);
    }
}
