//! `string.transcode(input, from, to [, ignorebad])`: conversion between
//! character encodings and binary to text encodings. Byte encodings
//! (UTF-16, UTF-32, ISO-8859-1, and `"binary"`, the raw bytes) produce
//! vectors. Text encodings (UTF-8, ASCII, base64, base64url, URL, and hex text)
//! produce strings (spec/design/strings.md). The input may be a string or
//! a vector in either case.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const wtf8 = @import("../vm/wtf8.zig");
const aux = @import("auxlib.zig");
const vector = @import("vector.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const ArrayList = std.ArrayList(u8);

const Enc = enum {
    ascii,
    utf8,
    utf8bom,
    utf16le,
    utf16be,
    utf32le,
    utf32be,
    latin1,
    binary,
    base64,
    base64url,
    base32,
    url,
    hex,

    fn isBinaryToText(e: Enc) bool {
        return e == .base64 or e == .base64url or e == .base32 or e == .url or e == .hex;
    }

    /// Whether values in this encoding are vectors.
    fn isBytes(e: Enc) bool {
        return switch (e) {
            .utf16le, .utf16be, .utf32le, .utf32be, .latin1, .binary => true,
            else => false,
        };
    }

    fn label(e: Enc) []const u8 {
        return switch (e) {
            .utf16le => "UTF-16LE",
            .utf16be => "UTF-16BE",
            .utf32le => "UTF-32LE",
            .utf32be => "UTF-32BE",
            else => "?",
        };
    }
};

const names = [_]struct { []const u8, Enc }{
    .{ "ascii", .ascii },
    .{ "utf-8", .utf8 },
    .{ "utf-8bom", .utf8bom },
    .{ "utf-16le", .utf16le },
    .{ "utf-16be", .utf16be },
    .{ "utf-32le", .utf32le },
    .{ "utf-32be", .utf32be },
    .{ "iso-8859-1", .latin1 },
    .{ "latin-1", .latin1 },
    .{ "latin1", .latin1 },
    .{ "binary", .binary },
    .{ "base64", .base64 },
    .{ "base64url", .base64url },
    .{ "base32", .base32 },
    .{ "url", .url },
    .{ "hex", .hex },
};

fn parse(name: []const u8) ?Enc {
    for (names) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return null;
}

pub fn register(l: *Thread) Error!void {
    const g = l.g;
    const sv = try aux.getField(l, g.globals.as(object.Table), "string");
    if (sv.tag != .table) return;
    try aux.setFuncs(l, sv.as(object.Table), .library, "string", &.{.{ .name = "transcode", .func = transcode }});
}

/// Pushes the result in the representation `to` calls for.
fn result(l: *Thread, to: Enc, bytes: []const u8) Error!u32 {
    if (to.isBytes()) return aux.ret(l, Value.obj(.vector, try vector.newVector(l, bytes)));
    return aux.retStr(l, bytes);
}

fn transcode(l: *Thread) Error!u32 {
    const in = l.arg(1);
    const src: []const u8 = switch (in.tag) {
        .string => in.as(object.String).bytes(),
        .vector => (try vector.checkVector(l, 1)).bytes.items,
        else => if (in.isNumber()) try aux.checkBytes(l, 1) else return aux.typeError(l, 1, "string or vector"),
    };
    const from_name = try aux.checkBytes(l, 2);
    const to_name = try aux.checkBytes(l, 3);
    const ignorebad = l.arg(4).truthy();
    var from = parse(from_name) orelse return l.raiseFmt("invalid source encoding '{s}'", .{from_name});
    const to = parse(to_name) orelse return l.raiseFmt("invalid target encoding '{s}'", .{to_name});

    const gpa = l.g.gpa;
    var raw: ArrayList = .empty;
    defer raw.deinit(gpa);
    var data = src;

    // A binary to text source decodes to raw bytes first.
    if (from.isBinaryToText()) {
        const ok = switch (from) {
            .base64 => decodeBase64(gpa, &raw, src, std.base64.standard_no_pad.Decoder, std.base64.standard_alphabet_chars, ignorebad),
            .base64url => decodeBase64(gpa, &raw, src, std.base64.url_safe_no_pad.Decoder, std.base64.url_safe_alphabet_chars, ignorebad),
            .base32 => decodeBase32(gpa, &raw, src, ignorebad),
            .url => decodeUrl(gpa, &raw, src, ignorebad),
            else => decodeHex(gpa, &raw, src, ignorebad),
        } catch return l.raiseMem();
        if (!ok) {
            if (!ignorebad) return l.raiseFmt("invalid {s} input", .{from_name});
            return result(l, to, "");
        }
        data = raw.items;
        from = .binary;
    }

    var out: ArrayList = .empty;
    defer out.deinit(gpa);

    // A binary to text target encodes the bytes as they are.
    if (to.isBinaryToText()) {
        const done = switch (to) {
            .base64 => encodeBase64(gpa, &out, data, std.base64.standard.Encoder),
            .base64url => encodeBase64(gpa, &out, data, std.base64.url_safe_no_pad.Encoder),
            .base32 => encodeBase32(gpa, &out, data),
            .url => encodeUrl(gpa, &out, data),
            else => encodeHex(gpa, &out, data),
        };
        done catch return l.raiseMem();
        return aux.retStr(l, out.items);
    }
    if (from == .binary and to == .binary) return result(l, to, data);

    try convert(l, &out, data, from, to, ignorebad);
    return result(l, to, out.items);
}

/// Character transcoding: decodes code points from `from` and encodes them
/// into `to`. Raw bytes (`"binary"`) are read and written as UTF-8.
fn convert(l: *Thread, out: *ArrayList, src_in: []const u8, from_in: Enc, to_in: Enc, ignorebad: bool) Error!void {
    const gpa = l.g.gpa;
    var src = src_in;
    var from = from_in;
    var to = to_in;
    if (from == .binary) from = .utf8;
    if (to == .binary) to = .utf8;

    const unit: usize = switch (from) {
        .utf16le, .utf16be => 2,
        .utf32le, .utf32be => 4,
        else => 1,
    };
    // With ignorebad, the bytes after the last whole unit become one
    // U+FFFD at the end, as the WHATWG decoders of UTF-16 emit it.
    var partial_unit = false;
    if (src.len % unit != 0) {
        if (!ignorebad) {
            if (unit == 2) return l.raiseFmt("invalid {s} input: odd byte count", .{from.label()});
            return l.raiseFmt("invalid {s} input: byte count not a multiple of 4", .{from.label()});
        }
        src = src[0 .. src.len - src.len % unit];
        partial_unit = true;
    }

    var p: usize = 0;
    if (from == .utf8bom) {
        if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) p = 3;
        from = .utf8;
    }
    if (to == .utf8bom) {
        out.appendSlice(gpa, "\xEF\xBB\xBF") catch return l.raiseMem();
        to = .utf8;
    }

    while (p < src.len) {
        const pos = p + 1;
        var cp: u21 = undefined;
        switch (from) {
            .ascii => {
                if (src[p] > 127) {
                    if (!ignorebad) return l.raiseFmt("invalid ASCII byte 0x{X:0>2} at position {d}", .{ src[p], pos });
                    cp = replacement;
                } else cp = src[p];
                p += 1;
            },
            .latin1 => {
                cp = src[p];
                p += 1;
            },
            .utf8 => {
                const d = wtf8.decodeAt(src, p);
                if (d == null or (d.?.cp >= 0xD800 and d.?.cp <= 0xDFFF)) {
                    if (!ignorebad) return l.raiseFmt("invalid UTF-8 sequence at position {d}", .{pos});
                    cp = replacement;
                    p += wtf8.maximalSubpart(src[p..]);
                } else {
                    cp = d.?.cp;
                    p += d.?.len;
                }
            },
            .utf16le, .utf16be => {
                const le = from == .utf16le;
                const w1 = read16(src[p..], le);
                if (w1 < 0xD800 or w1 > 0xDFFF) {
                    cp = w1;
                    p += 2;
                } else if (w1 <= 0xDBFF and p + 4 <= src.len and read16(src[p + 2 ..], le) >= 0xDC00 and read16(src[p + 2 ..], le) <= 0xDFFF) {
                    cp = wtf8.combineSurrogates(w1, read16(src[p + 2 ..], le));
                    p += 4;
                } else {
                    if (!ignorebad) return l.raiseFmt("invalid {s} sequence at position {d}", .{ from.label(), pos });
                    cp = replacement;
                    p += 2;
                }
            },
            .utf32le, .utf32be => {
                const b = src[p..][0..4];
                const v: u32 = if (from == .utf32le) std.mem.readInt(u32, b, .little) else std.mem.readInt(u32, b, .big);
                if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) {
                    if (!ignorebad) return l.raiseFmt("invalid {s} sequence at position {d}", .{ from.label(), pos });
                    cp = replacement;
                } else cp = @intCast(v);
                p += 4;
            },
            else => unreachable,
        }

        try emit(l, out, cp, to, ignorebad);
    }
    if (partial_unit) try emit(l, out, replacement, to, ignorebad);
}

/// The character that stands for an invalid input sequence under
/// ignorebad.
const replacement: u21 = 0xFFFD;

/// Encodes one code point into `to`. A character that `to` cannot
/// represent raises, or with ignorebad is skipped.
fn emit(l: *Thread, out: *ArrayList, cp: u21, to: Enc, ignorebad: bool) Error!void {
    const gpa = l.g.gpa;
    switch (to) {
        .ascii => {
            if (cp > 127) {
                if (!ignorebad) return l.raiseFmt("codepoint U+{X:0>4} cannot be encoded as ASCII", .{cp});
                return;
            }
            out.append(gpa, @intCast(cp)) catch return l.raiseMem();
        },
        .latin1 => {
            if (cp > 255) {
                if (!ignorebad) return l.raiseFmt("codepoint U+{X:0>4} cannot be encoded as ISO-8859-1", .{cp});
                return;
            }
            out.append(gpa, @intCast(cp)) catch return l.raiseMem();
        },
        .utf8 => {
            var buf: [4]u8 = undefined;
            const n = wtf8.encode(cp, &buf);
            out.appendSlice(gpa, buf[0..n]) catch return l.raiseMem();
        },
        .utf16le, .utf16be => {
            const le = to == .utf16le;
            if (cp < 0x10000) {
                write16(gpa, out, @intCast(cp), le) catch return l.raiseMem();
            } else {
                const adj = cp - 0x10000;
                write16(gpa, out, @intCast(0xD800 + (adj >> 10)), le) catch return l.raiseMem();
                write16(gpa, out, @intCast(0xDC00 + (adj & 0x3FF)), le) catch return l.raiseMem();
            }
        },
        .utf32le, .utf32be => {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, cp, if (to == .utf32le) .little else .big);
            out.appendSlice(gpa, &b) catch return l.raiseMem();
        },
        else => unreachable,
    }
}

fn read16(b: []const u8, le: bool) u21 {
    return if (le) @as(u21, b[0]) | (@as(u21, b[1]) << 8) else (@as(u21, b[0]) << 8) | b[1];
}

fn write16(gpa: std.mem.Allocator, out: *ArrayList, v: u16, le: bool) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, if (le) .little else .big);
    try out.appendSlice(gpa, &b);
}

// ---------------------------------------------------------------------
// Binary to text encodings

/// Decodes base64 with the alphabet of `dec`, skipping whitespace and
/// stopping at the first padding character. Returns false on malformed
/// input.
/// Decodes base64. With `lax`, a character outside the alphabet and an
/// incomplete last group are skipped, and the rest decodes.
fn decodeBase64(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8, dec: std.base64.Base64Decoder, alphabet: [64]u8, lax: bool) !bool {
    var clean: ArrayList = .empty;
    defer clean.deinit(gpa);
    for (src, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (lax) {
            if (std.mem.indexOfScalar(u8, &alphabet, c) != null) try clean.append(gpa, c);
            continue;
        }
        if (c == '=') {
            if (!onlyPadding(src[i..])) return false;
            break;
        }
        try clean.append(gpa, c);
    }
    if (lax and clean.items.len % 4 == 1) clean.items.len -= 1;
    const n = dec.calcSizeForSlice(clean.items) catch return false;
    try out.ensureUnusedCapacity(gpa, n);
    dec.decode(out.unusedCapacitySlice()[0..n], clean.items) catch return false;
    out.items.len += n;
    return true;
}

/// Whether `rest`, which starts at the first `=`, holds only padding and
/// whitespace. Padding ends the data, so nothing else may follow it.
fn onlyPadding(rest: []const u8) bool {
    for (rest) |c| switch (c) {
        '=', ' ', '\t', '\n', '\r' => {},
        else => return false,
    };
    return true;
}

fn encodeBase64(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8, enc: std.base64.Base64Encoder) !void {
    const n = enc.calcSize(src.len);
    try out.ensureUnusedCapacity(gpa, n);
    _ = enc.encode(out.unusedCapacitySlice()[0..n], src);
    out.items.len += n;
}

const base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Encodes base32 with the alphabet of RFC 4648, padded to a multiple of
/// eight characters.
fn encodeBase32(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8) !void {
    try out.ensureUnusedCapacity(gpa, (src.len + 4) / 5 * 8);
    var i: usize = 0;
    while (i < src.len) : (i += 5) {
        const n: usize = @min(5, src.len - i);
        var block: [5]u8 = @splat(0);
        @memcpy(block[0..n], src[i..][0..n]);
        const bits = std.mem.readInt(u40, &block, .big);
        const chars = (n * 8 + 4) / 5;
        for (0..8) |k| {
            const c: u8 = if (k < chars) base32_alphabet[@intCast((bits >> @intCast(35 - 5 * k)) & 31)] else '=';
            out.appendAssumeCapacity(c);
        }
    }
}

/// Decodes base32 in either case, skipping whitespace and stopping at the
/// first padding character. A group of 1, 3, or 6 characters cannot hold
/// whole bytes, so it is malformed. Returns false on malformed input.
/// Decodes base32. With `lax`, a character outside the alphabet is
/// skipped, and an incomplete last group adds nothing.
fn decodeBase32(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8, lax: bool) !bool {
    var acc: u64 = 0;
    var nbits: u6 = 0;
    var count: usize = 0;
    for (src, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (c == '=') {
            if (lax) continue;
            if (!onlyPadding(src[i..])) return false;
            break;
        }
        const up = std.ascii.toUpper(c);
        const d = std.mem.indexOfScalar(u8, base32_alphabet, up) orelse {
            if (lax) continue;
            return false;
        };
        acc = (acc << 5) | d;
        nbits += 5;
        count += 1;
        if (nbits >= 8) {
            nbits -= 8;
            try out.append(gpa, @truncate(acc >> nbits));
            acc &= (@as(u64, 1) << nbits) - 1;
        }
    }
    return switch (count % 8) {
        1, 3, 6 => lax,
        else => true,
    };
}

/// Decodes percent escapes and `+`. A `%` that does not start two hex
/// digits fails the decoding, or with `lax` stays in the output as it is,
/// as browsers read it.
fn decodeUrl(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8, lax: bool) !bool {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        i += 1;
        if (c == '%') {
            const h1 = if (i < src.len) std.fmt.charToDigit(src[i], 16) catch null else null;
            const h2 = if (i + 1 < src.len) std.fmt.charToDigit(src[i + 1], 16) catch null else null;
            if (h1 == null or h2 == null) {
                if (!lax) return false;
                try out.append(gpa, '%');
                continue;
            }
            try out.append(gpa, (h1.? << 4) | h2.?);
            i += 2;
        } else if (c == '+') {
            try out.append(gpa, ' ');
        } else try out.append(gpa, c);
    }
    return true;
}

fn encodeUrl(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8) !void {
    const digits = "0123456789ABCDEF";
    for (src) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &.{ '%', digits[c >> 4], digits[c & 15] });
        }
    }
}

/// Decodes pairs of hexadecimal digits. With `lax`, a pair that holds
/// another character and a lone last digit are skipped, and the rest
/// decodes.
fn decodeHex(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8, lax: bool) !bool {
    if (src.len % 2 != 0 and !lax) return false;
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 2) {
        const h1 = std.fmt.charToDigit(src[i], 16) catch if (lax) continue else return false;
        const h2 = std.fmt.charToDigit(src[i + 1], 16) catch if (lax) continue else return false;
        try out.append(gpa, (h1 << 4) | h2);
    }
    return true;
}

fn encodeHex(gpa: std.mem.Allocator, out: *ArrayList, src: []const u8) !void {
    const digits = "0123456789abcdef";
    for (src) |c| try out.appendSlice(gpa, &.{ digits[c >> 4], digits[c & 15] });
}
