//! The `vector.archive` library: gzip, raw deflate, Zstandard, Brotli and
//! LZ4 compression. Every compressor accepts a string or a vector and
//! returns a vector, because compressed data is raw bytes
//! (spec/design/strings.md). Every decompressor accepts a vector or a string
//! and returns a vector. Programs that compressed text decode the result
//! with `vector.tostring`.
//!
//! Gzip and deflate use `std.compress.flate`. Zstandard and Brotli use the
//! upstream C libraries vendored through `build.zig.zon`. LZ4 is written
//! here, since its block and frame formats are small.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const flate = std.compress.flate;
const XxHash32 = std.hash.XxHash32;

/// Registers `vector.archive` on the `vector` library table.
pub fn open(l: *Thread) Error!void {
    const vv = try aux.getField(l, l.g.globals.as(Table), "vector");
    if (vv.tag != .table) return;
    const archive = try l.newTable(0, 5);
    try aux.setField(l, vv.as(Table), "archive", Value.obj(.table, archive));
    const codecs = [_]struct { []const u8, []const aux.Reg }{
        .{ "gzip", &.{
            .{ .name = "compress", .func = gzipCompress },
            .{ .name = "decompress", .func = gzipDecompress },
        } },
        .{ "deflate", &.{
            .{ .name = "compress", .func = deflateCompress },
            .{ .name = "decompress", .func = deflateDecompress },
        } },
        .{ "zstd", &.{
            .{ .name = "compress", .func = zstdCompress },
            .{ .name = "decompress", .func = zstdDecompress },
        } },
        .{ "brotli", &.{
            .{ .name = "compress", .func = brotliCompress },
            .{ .name = "decompress", .func = brotliDecompress },
        } },
        .{ "lz4", &.{
            .{ .name = "compress", .func = lz4Compress },
            .{ .name = "decompress", .func = lz4Decompress },
            .{ .name = "decompress_hc", .func = lz4DecompressLegacy },
        } },
    };
    inline for (codecs) |c| {
        const t = try l.newTable(0, c[1].len);
        try aux.setField(l, archive, c[0], Value.obj(.table, t));
        try aux.setFuncs(l, t, .fields, "vector.archive." ++ c[0], c[1]);
    }
    try @import("container.zig").register(l, archive);
}

// ---------------------------------------------------------------------
// Shared helpers

/// The bytes of a string or vector argument. Numbers convert to strings,
/// as they do for every string parameter.
const checkInput = vector.checkData;

/// Moves `list` into a new vector and returns it as the single result.
fn retBytes(l: *Thread, list: *std.ArrayList(u8)) Error!u32 {
    return aux.ret(l, Value.obj(.vector, try vector.newVectorFrom(l, list)));
}

/// Returns a copy of `bytes` as a vector.
fn retCopy(l: *Thread, bytes: []const u8) Error!u32 {
    return aux.ret(l, Value.obj(.vector, try vector.newVector(l, bytes)));
}

/// Default cap on decompressed output. A few kilobytes of input can expand
/// to many gigabytes, so every decompressor stops at this size unless the
/// optional trailing argument raises or lowers it.
const default_max_out: usize = 512 * 1024 * 1024;

fn maxOut(l: *Thread, i: u32) Error!usize {
    const m = try aux.optInt(l, i, 0);
    return if (m > 0) std.math.cast(usize, m) orelse std.math.maxInt(usize) else default_max_out;
}

fn tooBig(l: *Thread, max: usize) Error {
    return l.raiseFmt("decompressed size exceeds limit ({d} bytes)", .{max});
}

/// The output chunk a streaming decompressor asks for, four times the
/// input with a floor of 256 bytes, as in the reference runtime. The
/// ceiling keeps one step from reserving far more than a bomb check allows.
fn chunkSize(input_len: usize) usize {
    return std.math.clamp(input_len *| 4, 256, 16 * 1024 * 1024);
}

// ---------------------------------------------------------------------
// Gzip and raw deflate

fn gzipCompress(l: *Thread) Error!u32 {
    return flateCompress(l, .gzip);
}

fn deflateCompress(l: *Thread) Error!u32 {
    return flateCompress(l, .raw);
}

fn gzipDecompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    // Gzip and zlib streams are both accepted, told apart by the gzip magic.
    const container: flate.Container = if (input.len >= 2 and input[0] == 0x1f and input[1] == 0x8b) .gzip else .zlib;
    return flateDecompress(l, input, container, "gzip", max);
}

fn deflateDecompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    return flateDecompress(l, input, .raw, "deflate", max);
}

fn flateCompress(l: *Thread, container: flate.Container) Error!u32 {
    const input = try checkInput(l, 1);
    const level = try aux.optInt(l, 2, 6);
    if (level < 0 or level > 9) return aux.argError(l, 2, "compression level must be 0-9", .{});
    const gpa = l.g.gpa;

    const window = gpa.alloc(u8, flate.max_window_len) catch return l.raiseMem();
    defer gpa.free(window);
    var out = std.Io.Writer.Allocating.initCapacity(gpa, input.len / 2 + 64) catch return l.raiseMem();
    defer out.deinit();

    // The writer fails only when the output buffer cannot grow.
    flateWrite(&out.writer, window, container, @intCast(level), input) catch return l.raiseMem();

    var list = out.toArrayList();
    defer list.deinit(gpa);
    return retBytes(l, &list);
}

/// Writes `input` as one complete stream. Level 0 emits stored blocks.
pub fn flateWrite(out: *std.Io.Writer, window: []u8, container: flate.Container, level: u4, input: []const u8) std.Io.Writer.Error!void {
    if (level == 0) {
        var raw = try flate.Compress.Raw.init(out, window, container);
        try raw.writer.writeAll(input);
        return raw.finish();
    }
    const opts: flate.Compress.Options = switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        else => .level_9,
    };
    var c = try flate.Compress.init(out, window, container, opts);
    try c.writer.writeAll(input);
    return c.finish();
}

fn flateDecompress(l: *Thread, input: []const u8, container: flate.Container, name: []const u8, max: usize) Error!u32 {
    const gpa = l.g.gpa;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var d: flate.Decompress = .init(&in, container, &.{});
    while (true) {
        const room = max - @min(max, out.written().len) + 1;
        _ = d.reader.stream(&out.writer, .limited(room)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return l.raiseMem(),
            error.ReadFailed => {
                const e = d.err orelse error.ReadFailed;
                if (e == error.EndOfStream) return l.raiseFmt("{s} decompress: incomplete data", .{name});
                return l.raiseFmt("{s} decompress failed ({s})", .{ name, @errorName(e) });
            },
        };
        if (out.written().len > max) return tooBig(l, max);
    }
    // The decoder records the footer, and the checksum is verified here.
    const data = out.written();
    const bad: ?[]const u8 = switch (d.container_metadata) {
        .gzip => |f| if (f.crc != std.hash.Crc32.hash(data)) "WrongGzipChecksum" else if (f.count != @as(u32, @truncate(data.len))) "WrongGzipSize" else null,
        .zlib => |f| if (f.adler != std.hash.Adler32.hash(data)) "WrongZlibChecksum" else null,
        .raw => null,
    };
    if (bad) |e| return l.raiseFmt("{s} decompress failed ({s})", .{ name, e });
    var list = out.toArrayList();
    defer list.deinit(gpa);
    return retBytes(l, &list);
}

// ---------------------------------------------------------------------
// Zstandard (vendored libzstd)

const ZstdInBuffer = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const ZstdOutBuffer = extern struct { dst: ?*anyopaque, size: usize, pos: usize };
const ZstdDCtx = opaque {};
const ZstdCCtx = opaque {};

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_createCCtx() ?*ZstdCCtx;
extern fn ZSTD_freeCCtx(cctx: *ZstdCCtx) usize;
extern fn ZSTD_CCtx_setParameter(cctx: *ZstdCCtx, param: c_int, value: c_int) usize;
extern fn ZSTD_compress2(cctx: *ZstdCCtx, dst: ?*anyopaque, cap: usize, src: ?*const anyopaque, n: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;
extern fn ZSTD_minCLevel() c_int;
extern fn ZSTD_maxCLevel() c_int;
extern fn ZSTD_getFrameContentSize(src: ?*const anyopaque, n: usize) c_ulonglong;
extern fn ZSTD_decompress(dst: ?*anyopaque, cap: usize, src: ?*const anyopaque, n: usize) usize;
extern fn ZSTD_createDCtx() ?*ZstdDCtx;
extern fn ZSTD_freeDCtx(dctx: *ZstdDCtx) usize;
extern fn ZSTD_decompressStream(dctx: *ZstdDCtx, out: *ZstdOutBuffer, in: *ZstdInBuffer) usize;
extern fn ZSTD_DStreamOutSize() usize;

// The parameters of `ZSTD_CCtx_setParameter`, from zstd.h.
const zstd_c_compression_level: c_int = 100;
const zstd_c_checksum_flag: c_int = 201;

const zstd_content_size_unknown: c_ulonglong = std.math.maxInt(c_ulonglong);
const zstd_content_size_error: c_ulonglong = std.math.maxInt(c_ulonglong) - 1;

fn zstdCompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const level = try aux.optInt(l, 2, 3);
    if (level < ZSTD_minCLevel() or level > ZSTD_maxCLevel())
        return aux.argError(l, 2, "compression level out of range", .{});
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    const bound = ZSTD_compressBound(input.len);
    list.ensureTotalCapacity(gpa, bound) catch return l.raiseMem();
    // Each frame carries a checksum of its content, so decompressing
    // damaged data raises an error.
    const cctx = ZSTD_createCCtx() orelse return l.raiseMem();
    defer _ = ZSTD_freeCCtx(cctx);
    for ([_][2]c_int{ .{ zstd_c_compression_level, @intCast(level) }, .{ zstd_c_checksum_flag, 1 } }) |p| {
        const r = ZSTD_CCtx_setParameter(cctx, p[0], p[1]);
        if (ZSTD_isError(r) != 0) return l.raiseFmt("zstd compress failed: {s}", .{ZSTD_getErrorName(r)});
    }
    const n = ZSTD_compress2(cctx, list.items.ptr, bound, input.ptr, input.len);
    if (ZSTD_isError(n) != 0) return l.raiseFmt("zstd compress failed: {s}", .{ZSTD_getErrorName(n)});
    list.items.len = n;
    return retBytes(l, &list);
}

fn zstdDecompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    const frame_size = ZSTD_getFrameContentSize(input.ptr, input.len);
    if (frame_size == zstd_content_size_error) return l.raiseFmt("zstd decompress: not valid zstd data", .{});
    if (frame_size != zstd_content_size_unknown) {
        // The declared size comes from the input, so check it against the
        // cap before allocating it.
        if (frame_size > max) return tooBig(l, max);
        const size: usize = @intCast(frame_size);
        list.ensureTotalCapacity(gpa, @max(size, 1)) catch return l.raiseMem();
        const n = ZSTD_decompress(list.items.ptr, size, input.ptr, input.len);
        if (ZSTD_isError(n) != 0) return l.raiseFmt("zstd decompress failed: {s}", .{ZSTD_getErrorName(n)});
        list.items.len = n;
        return retBytes(l, &list);
    }

    const dctx = ZSTD_createDCtx() orelse return l.raiseFmt("zstd decompress: failed to create context", .{});
    defer _ = ZSTD_freeDCtx(dctx);
    var zin: ZstdInBuffer = .{ .src = input.ptr, .size = input.len, .pos = 0 };
    var ret: usize = 0;
    const chunk = ZSTD_DStreamOutSize();
    while (zin.pos < zin.size) {
        list.ensureUnusedCapacity(gpa, chunk) catch return l.raiseMem();
        const room = list.unusedCapacitySlice();
        var zout: ZstdOutBuffer = .{ .dst = room.ptr, .size = room.len, .pos = 0 };
        const before = zin.pos;
        ret = ZSTD_decompressStream(dctx, &zout, &zin);
        if (ZSTD_isError(ret) != 0) return l.raiseFmt("zstd decompress failed: {s}", .{ZSTD_getErrorName(ret)});
        if (zout.pos == 0 and zin.pos == before and ret != 0) return l.raiseFmt("zstd decompress: incomplete data", .{});
        list.items.len += zout.pos;
        if (list.items.len > max) return tooBig(l, max);
    }
    if (ret != 0) return l.raiseFmt("zstd decompress: incomplete data", .{});
    return retBytes(l, &list);
}

// ---------------------------------------------------------------------
// Brotli (vendored google/brotli)

const BrotliDecoder = opaque {};
const brotli_mode_generic: c_int = 0;
const brotli_result_error: c_int = 0;
const brotli_result_success: c_int = 1;
const brotli_result_needs_more_output: c_int = 3;

extern fn BrotliEncoderMaxCompressedSize(input_size: usize) usize;
extern fn BrotliEncoderCompress(quality: c_int, lgwin: c_int, mode: c_int, input_size: usize, input: [*]const u8, encoded_size: *usize, encoded: [*]u8) c_int;
extern fn BrotliDecoderCreateInstance(alloc: ?*const anyopaque, free: ?*const anyopaque, ctx: ?*anyopaque) ?*BrotliDecoder;
extern fn BrotliDecoderDestroyInstance(s: *BrotliDecoder) void;
extern fn BrotliDecoderDecompressStream(s: *BrotliDecoder, avail_in: *usize, next_in: *[*]const u8, avail_out: *usize, next_out: *[*]u8, total_out: ?*usize) c_int;

fn brotliCompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const quality = try aux.optInt(l, 2, 11);
    const lgwin = try aux.optInt(l, 3, 22);
    if (quality < 0 or quality > 11) return aux.argError(l, 2, "quality must be 0-11", .{});
    if (lgwin < 10 or lgwin > 24) return aux.argError(l, 3, "lgwin must be 10-24", .{});
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var size = BrotliEncoderMaxCompressedSize(input.len);
    if (size == 0) size = input.len + 256;
    list.ensureTotalCapacity(gpa, size) catch return l.raiseMem();
    if (BrotliEncoderCompress(@intCast(quality), @intCast(lgwin), brotli_mode_generic, input.len, input.ptr, &size, list.items.ptr) == 0)
        return l.raiseFmt("brotli compress failed", .{});
    list.items.len = size;
    return retBytes(l, &list);
}

fn brotliDecompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    const s = BrotliDecoderCreateInstance(null, null, null) orelse
        return l.raiseFmt("brotli decompress: failed to create decoder", .{});
    defer BrotliDecoderDestroyInstance(s);

    var next_in: [*]const u8 = input.ptr;
    var avail_in = input.len;
    const chunk = chunkSize(input.len);
    var result: c_int = undefined;
    while (true) {
        list.ensureUnusedCapacity(gpa, chunk) catch return l.raiseMem();
        const room = list.unusedCapacitySlice();
        var next_out: [*]u8 = room.ptr;
        var avail_out = room.len;
        result = BrotliDecoderDecompressStream(s, &avail_in, &next_in, &avail_out, &next_out, null);
        list.items.len += room.len - avail_out;
        if (result == brotli_result_error) return l.raiseFmt("brotli decompress failed", .{});
        if (list.items.len > max) return tooBig(l, max);
        if (result != brotli_result_needs_more_output) break;
    }
    if (result != brotli_result_success) return l.raiseFmt("brotli decompress: incomplete data", .{});
    return retBytes(l, &list);
}

// ---------------------------------------------------------------------
// LZ4 blocks

const lz4_min_match = 4;
/// The last five bytes of a block are always literals.
const lz4_last_literals = 5;
/// A match never starts within the last twelve bytes of a block.
const lz4_mf_limit = 12;
const lz4_window = 65536;
const lz4_hash_log = 16;

fn lz4Hash(seq: u32) u32 {
    return (seq *% 2654435761) >> (32 - lz4_hash_log);
}

fn readU32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

fn writeLength(out: *std.ArrayList(u8), gpa: std.mem.Allocator, len: usize) !void {
    var n = len;
    while (n >= 255) : (n -= 255) try out.append(gpa, 255);
    try out.append(gpa, @intCast(n));
}

fn emitSequence(out: *std.ArrayList(u8), gpa: std.mem.Allocator, literals: []const u8, match_len: usize, offset: usize) !void {
    const lit_code: u8 = @intCast(@min(literals.len, 15));
    const ml = if (match_len > 0) match_len - lz4_min_match else 0;
    const ml_code: u8 = @intCast(@min(ml, 15));
    try out.append(gpa, (lit_code << 4) | ml_code);
    if (literals.len >= 15) try writeLength(out, gpa, literals.len - 15);
    try out.appendSlice(gpa, literals);
    if (match_len == 0) return;
    try out.appendSlice(gpa, &.{ @truncate(offset), @truncate(offset >> 8) });
    if (ml >= 15) try writeLength(out, gpa, ml - 15);
}

/// Hash chain match finder shared by every level. `head` maps a hash to
/// the last position with that hash, and `chain` maps a position (modulo
/// the window) to the distance back to the previous one.
const Lz4Matcher = struct {
    head: [1 << lz4_hash_log]i32,
    chain: [lz4_window]u16,
    next: usize,

    fn reset(m: *Lz4Matcher) void {
        @memset(&m.head, -1);
        @memset(&m.chain, 0);
        m.next = 0;
    }

    fn insertUpTo(m: *Lz4Matcher, src: []const u8, pos: usize) void {
        while (m.next < pos) : (m.next += 1) {
            const h = lz4Hash(readU32(src[m.next..]));
            const prev = m.head[h];
            const delta: usize = if (prev < 0) 0 else m.next - @as(usize, @intCast(prev));
            m.chain[m.next & (lz4_window - 1)] = if (delta < lz4_window) @intCast(delta) else 0;
            m.head[h] = @intCast(m.next);
        }
    }
};

/// Compresses one independent block. `attempts` bounds how many chain
/// entries the match finder visits at each position.
fn lz4CompressBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), m: *Lz4Matcher, src: []const u8, attempts: usize) !void {
    m.reset();
    var anchor: usize = 0;
    if (src.len >= lz4_mf_limit + 1) {
        const match_limit = src.len - lz4_last_literals;
        const search_end = src.len - lz4_mf_limit;
        var ip: usize = 0;
        while (ip < search_end) {
            m.insertUpTo(src, ip);
            const seq = readU32(src[ip..]);
            var best_len: usize = 0;
            var best_off: usize = 0;
            var cand_i: i32 = m.head[lz4Hash(seq)];
            var tries = attempts;
            while (cand_i >= 0 and tries > 0) : (tries -= 1) {
                const cand: usize = @intCast(cand_i);
                const off = ip - cand;
                if (off >= lz4_window or off == 0) break;
                if (readU32(src[cand..]) == seq) {
                    var len: usize = lz4_min_match;
                    while (ip + len < match_limit and src[cand + len] == src[ip + len]) len += 1;
                    if (len > best_len) {
                        best_len = len;
                        best_off = off;
                        if (ip + len >= match_limit) break;
                    }
                }
                const delta = m.chain[cand & (lz4_window - 1)];
                if (delta == 0 or delta > cand) break;
                cand_i = @intCast(cand - delta);
            }
            if (best_len < lz4_min_match) {
                ip += 1;
                continue;
            }
            try emitSequence(out, gpa, src[anchor..ip], best_len, best_off);
            ip += best_len;
            anchor = ip;
        }
    }
    try emitSequence(out, gpa, src[anchor..], 0, 0);
}

const LegacyBlockError = error{ Corrupt, TooBig, OutOfMemory };

/// Decodes one block, appending to `out`. A match may reach back to
/// `dict_start`, so linked blocks pass the start of the frame and
/// independent blocks pass the start of the block. The block may not
/// produce more than `block_max` bytes, nor push `out` past `max`.
fn lz4DecodeBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8, dict_start: usize, block_max: usize, max: usize) LegacyBlockError!void {
    const start = out.items.len;
    const limit = start + @min(block_max, max - @min(max, start) + 1);
    var ip: usize = 0;
    while (true) {
        if (ip >= src.len) return error.Corrupt;
        const token = src[ip];
        ip += 1;
        var lit: usize = token >> 4;
        if (lit == 15) {
            while (true) {
                if (ip >= src.len) return error.Corrupt;
                const b = src[ip];
                ip += 1;
                lit += b;
                if (b != 255) break;
            }
        }
        if (lit > src.len - ip) return error.Corrupt;
        if (out.items.len + lit > limit) return if (out.items.len + lit > max) error.TooBig else error.Corrupt;
        try out.appendSlice(gpa, src[ip..][0..lit]);
        ip += lit;
        if (ip == src.len) return;
        if (src.len - ip < 2) return error.Corrupt;
        const offset: usize = @as(usize, src[ip]) | (@as(usize, src[ip + 1]) << 8);
        ip += 2;
        var ml: usize = token & 15;
        if (ml == 15) {
            while (true) {
                if (ip >= src.len) return error.Corrupt;
                const b = src[ip];
                ip += 1;
                ml += b;
                if (b != 255) break;
            }
        }
        ml += lz4_min_match;
        if (offset == 0 or offset > out.items.len - dict_start) return error.Corrupt;
        if (out.items.len + ml > limit) return if (out.items.len + ml > max) error.TooBig else error.Corrupt;
        try out.ensureUnusedCapacity(gpa, ml);
        const from = out.items.len - offset;
        if (offset >= ml) {
            out.appendSliceAssumeCapacity(out.items[from..][0..ml]);
        } else {
            for (0..ml) |k| out.appendAssumeCapacity(out.items[from + k]);
        }
    }
}

// ---------------------------------------------------------------------
// LZ4 frames

const lz4_magic: u32 = 0x184D2204;
const lz4_legacy_magic: u32 = 0x184C2102;
const lz4_skippable_min: u32 = 0x184D2A50;
const lz4_skippable_max: u32 = 0x184D2A5F;
/// Every frame this library writes uses independent 4 MiB blocks and a
/// content checksum.
const lz4_block_max = 4 * 1024 * 1024;
const lz4_legacy_block_max = 8 * 1024 * 1024;

fn lz4Compress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const level = try aux.optInt(l, 2, 1);
    if (level < 1 or level > 12) return aux.argError(l, 2, "compression level must be 1-12", .{});
    const gpa = l.g.gpa;
    const attempts: usize = @as(usize, 1) << @intCast(level - 1);

    const m = gpa.create(Lz4Matcher) catch return l.raiseMem();
    defer gpa.destroy(m);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    lz4WriteFrame(gpa, &list, &block, m, input, attempts) catch return l.raiseMem();
    return retBytes(l, &list);
}

fn lz4WriteFrame(gpa: std.mem.Allocator, out: *std.ArrayList(u8), block: *std.ArrayList(u8), m: *Lz4Matcher, input: []const u8, attempts: usize) !void {
    // FLG: version 01, independent blocks, content checksum. BD: 4 MiB blocks.
    const descriptor = [_]u8{ 0x40 | 0x20 | 0x04, 7 << 4 };
    var header: [7]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], lz4_magic, .little);
    header[4] = descriptor[0];
    header[5] = descriptor[1];
    header[6] = @truncate(XxHash32.hash(0, &descriptor) >> 8);
    try out.appendSlice(gpa, &header);

    var pos: usize = 0;
    while (pos < input.len) {
        const src = input[pos..@min(input.len, pos + lz4_block_max)];
        pos += src.len;
        block.clearRetainingCapacity();
        try lz4CompressBlock(gpa, block, m, src, attempts);
        var size: [4]u8 = undefined;
        if (block.items.len < src.len) {
            std.mem.writeInt(u32, &size, @intCast(block.items.len), .little);
            try out.appendSlice(gpa, &size);
            try out.appendSlice(gpa, block.items);
        } else {
            std.mem.writeInt(u32, &size, @as(u32, @intCast(src.len)) | 0x80000000, .little);
            try out.appendSlice(gpa, &size);
            try out.appendSlice(gpa, src);
        }
    }
    var tail: [8]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], 0, .little);
    std.mem.writeInt(u32, tail[4..8], XxHash32.hash(0, input), .little);
    try out.appendSlice(gpa, &tail);
}

const Lz4Error = error{ Incomplete, TooBig, OutOfMemory, Format };

const Lz4Decoder = struct {
    input: []const u8,
    pos: usize = 0,
    /// The name of the format error, in the reference library's spelling.
    reason: []const u8 = "",

    fn take(d: *Lz4Decoder, n: usize) Lz4Error![]const u8 {
        if (d.input.len - d.pos < n) return error.Incomplete;
        defer d.pos += n;
        return d.input[d.pos..][0..n];
    }

    fn takeU32(d: *Lz4Decoder) Lz4Error!u32 {
        return readU32(try d.take(4));
    }

    fn fail(d: *Lz4Decoder, reason: []const u8) Lz4Error {
        d.reason = reason;
        return error.Format;
    }

    /// Decodes the first LZ4 frame, skipping skippable frames before it.
    /// Bytes after the frame are ignored.
    fn frame(d: *Lz4Decoder, gpa: std.mem.Allocator, out: *std.ArrayList(u8), max: usize) Lz4Error!void {
        var magic = try d.takeU32();
        while (magic >= lz4_skippable_min and magic <= lz4_skippable_max) {
            _ = try d.take(try d.takeU32());
            magic = try d.takeU32();
        }
        if (magic != lz4_magic) return d.fail("ERROR_frameType_unknown");

        const desc_start = d.pos;
        const flg = (try d.take(1))[0];
        const bd = (try d.take(1))[0];
        if (flg >> 6 != 1) return d.fail("ERROR_headerVersion_wrong");
        if (flg & 0x02 != 0 or bd & 0x8F != 0) return d.fail("ERROR_reservedFlag_set");
        const independent = flg & 0x20 != 0;
        const block_checksum = flg & 0x10 != 0;
        const has_size = flg & 0x08 != 0;
        const content_checksum = flg & 0x04 != 0;
        const has_dict = flg & 0x01 != 0;
        const bsid = bd >> 4;
        if (bsid < 4) return d.fail("ERROR_maxBlockSize_invalid");
        const block_max = @as(usize, 1) << @intCast(8 + 2 * @as(u6, @intCast(bsid)));
        var content_size: ?u64 = null;
        if (has_size) content_size = std.mem.readInt(u64, (try d.take(8))[0..8], .little);
        if (has_dict) _ = try d.take(4);
        const hc = (try d.take(1))[0];
        if (hc != @as(u8, @truncate(XxHash32.hash(0, d.input[desc_start .. d.pos - 1]) >> 8)))
            return d.fail("ERROR_headerChecksum_invalid");
        if (content_size) |n| if (n > max) return error.TooBig;

        const frame_start = out.items.len;
        while (true) {
            const word = try d.takeU32();
            if (word == 0) break;
            const size: usize = word & 0x7FFFFFFF;
            if (size > block_max) return d.fail("ERROR_maxBlockSize_invalid");
            const data = try d.take(size);
            if (block_checksum and try d.takeU32() != XxHash32.hash(0, data))
                return d.fail("ERROR_blockChecksum_invalid");
            if (word & 0x80000000 != 0) {
                if (out.items.len + size > max) return error.TooBig;
                try out.appendSlice(gpa, data);
            } else {
                const dict_start = if (independent) out.items.len else frame_start;
                lz4DecodeBlock(gpa, out, data, dict_start, block_max, max) catch |e| switch (e) {
                    error.Corrupt => return d.fail("ERROR_decompressionFailed"),
                    else => |x| return x,
                };
            }
        }
        if (content_checksum and try d.takeU32() != XxHash32.hash(0, out.items[frame_start..]))
            return d.fail("ERROR_contentChecksum_invalid");
        if (content_size) |n| if (n != out.items.len - frame_start) return d.fail("ERROR_frameSize_wrong");
    }
};

fn lz4Decompress(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var d: Lz4Decoder = .{ .input = input };
    d.frame(gpa, &list, max) catch |e| return switch (e) {
        error.Incomplete => l.raiseFmt("lz4 decompress: incomplete data", .{}),
        error.TooBig => tooBig(l, max),
        error.OutOfMemory => l.raiseMem(),
        error.Format => l.raiseFmt("lz4 decompress failed: {s}", .{d.reason}),
    };
    return retBytes(l, &list);
}

/// Decodes the legacy LZ4 frame: the magic 0x184C2102 followed by blocks,
/// each a 4-byte little-endian compressed size and a raw LZ4 block that
/// decodes to at most 8 MiB. A size field that carries a modern or
/// skippable frame magic ends the legacy content, since no legacy block is
/// that large.
fn lz4DecompressLegacy(l: *Thread) Error!u32 {
    const input = try checkInput(l, 1);
    const max = try maxOut(l, 2);
    if (input.len < 4 or readU32(input) != lz4_legacy_magic)
        return l.raiseFmt("lz4 decompress_hc: not a legacy LZ4 frame", .{});
    const gpa = l.g.gpa;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var p: usize = 4;
    while (input.len - p >= 4) {
        const size = readU32(input[p..]);
        p += 4;
        if (size == lz4_magic or (size >= lz4_skippable_min and size <= lz4_skippable_max)) break;
        if (size > input.len - p) return l.raiseFmt("lz4 decompress_hc: truncated block", .{});
        const block = input[p..][0..size];
        lz4DecodeBlock(gpa, &list, block, list.items.len, lz4_legacy_block_max, max) catch |e| return switch (e) {
            error.Corrupt => l.raiseFmt("lz4 decompress_hc: corrupt block", .{}),
            error.TooBig => tooBig(l, max),
            error.OutOfMemory => l.raiseMem(),
        };
        p += size;
    }
    return retBytes(l, &list);
}

test "lz4 frame roundtrip" {
    const gpa = std.testing.allocator;
    const m = try gpa.create(Lz4Matcher);
    defer gpa.destroy(m);
    const inputs = [_][]const u8{ "", "a", "hello hello hello hello hello hello", "abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz" };
    for (inputs) |input| {
        for ([_]usize{ 1, 2048 }) |attempts| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(gpa);
            try lz4WriteFrame(gpa, &out, &block, m, input, attempts);
            var dec: std.ArrayList(u8) = .empty;
            defer dec.deinit(gpa);
            var d: Lz4Decoder = .{ .input = out.items };
            try d.frame(gpa, &dec, default_max_out);
            try std.testing.expectEqualSlices(u8, input, dec.items);
        }
    }
}
