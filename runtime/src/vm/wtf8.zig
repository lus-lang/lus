//! WTF-8 validation, decoding, and character counting. This is the single
//! UTF-8 codec of the runtime. The lexer, the string library, the JSON
//! codec, and the I/O boundaries all call into it.

const std = @import("std");

pub const Analysis = struct {
    valid: bool,
    ascii: bool,
    chars: usize,
    /// Byte offset of the first invalid sequence, when `valid` is false.
    error_offset: usize = 0,
};

/// Width of the vector blocks used by the scanning loops.
const block = 32;
const VB = @Vector(block, u8);

// The helpers below reduce a block with a horizontal maximum or sum
// rather than turning a comparison into a bit mask, because both
// reductions are single instructions on the vector units the runtime
// targets, while a bit mask costs several on some of them.

/// Whether any byte of the block has its high bit set.
inline fn anyHigh(v: VB) bool {
    return @reduce(.Max, v) >= 0x80;
}

/// One for every byte of the block that starts a character, that is
/// every byte that is not a continuation byte (0x80 to 0xBF), and zero
/// for the others.
inline fn leadOnes(v: VB) VB {
    const lead = (v & @as(VB, @splat(0xC0))) != @as(VB, @splat(0x80));
    return @select(u8, lead, @as(VB, @splat(1)), @as(VB, @splat(0)));
}

/// Number of bytes of the block that start a character.
inline fn leadCount(v: VB) usize {
    return @reduce(.Add, @as(@Vector(block, u16), leadOnes(v)));
}

/// Length of the leading run of ASCII bytes in `bytes`.
pub fn asciiPrefix(bytes: []const u8) usize {
    var i: usize = 0;
    while (i + block <= bytes.len and !anyHigh(bytes[i..][0..block].*)) i += block;
    while (i < bytes.len and bytes[i] < 0x80) i += 1;
    return i;
}

/// Validates `bytes` as WTF-8 and counts code points. The common case of
/// ASCII text is checked a vector block at a time. Text with multi-byte
/// characters is validated by a scalar loop that skips ASCII runs a
/// block at a time, and the characters are then counted with vector
/// operations as the bytes that are not continuation bytes.
pub fn analyze(bytes: []const u8) Analysis {
    const first = asciiPrefix(bytes);
    if (first == bytes.len) return .{ .valid = true, .ascii = true, .chars = bytes.len };
    if (firstInvalid(bytes, first)) |at|
        return .{ .valid = false, .ascii = false, .chars = countChars(bytes[0..at]), .error_offset = at };
    return .{ .valid = true, .ascii = false, .chars = countChars(bytes) };
}

inline fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Byte offset of the first invalid sequence of `bytes` at or after
/// `start`, which must be a character boundary, or null when the rest of
/// the text is valid WTF-8.
fn firstInvalid(bytes: []const u8, start: usize) ?usize {
    const n = bytes.len;
    var i = start;
    while (i < n) {
        const c = bytes[i];
        if (c < 0x80) {
            // Skip the ASCII run that starts here a block at a time.
            if (i + block <= n and !anyHigh(bytes[i..][0..block].*)) {
                i += block;
                continue;
            }
            i += 1;
            while (i < n and bytes[i] < 0x80) i += 1;
            continue;
        }
        if (c < 0xC2) return i;
        if (c < 0xE0) {
            if (i + 1 >= n or !isCont(bytes[i + 1])) return i;
            i += 2;
            continue;
        }
        if (c < 0xF0) {
            if (i + 2 >= n) return i;
            const c1 = bytes[i + 1];
            // E0 needs A0 or more to avoid an overlong form. ED accepts the
            // whole continuation range because WTF-8 allows surrogates.
            const lo: u8 = if (c == 0xE0) 0xA0 else 0x80;
            if (c1 < lo or c1 > 0xBF or !isCont(bytes[i + 2])) return i;
            i += 3;
            // A lead surrogate directly followed by a trail surrogate must
            // have been encoded as one supplementary character.
            if (c == 0xED and c1 >= 0xA0 and c1 <= 0xAF and i + 1 < n and bytes[i] == 0xED and bytes[i + 1] >= 0xB0 and bytes[i + 1] <= 0xBF)
                return i;
            continue;
        }
        if (c < 0xF5) {
            if (i + 3 >= n) return i;
            const c1 = bytes[i + 1];
            const lo: u8 = if (c == 0xF0) 0x90 else 0x80;
            const hi: u8 = if (c == 0xF4) 0x8F else 0xBF;
            if (c1 < lo or c1 > hi or !isCont(bytes[i + 2]) or !isCont(bytes[i + 3])) return i;
            i += 4;
            continue;
        }
        return i;
    }
    return null;
}

/// Number of characters in valid WTF-8: the count of bytes that are not
/// continuation bytes.
pub fn countChars(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    // Per lane counts add up in bytes for up to 255 blocks before they
    // are widened, so the inner loop is one compare and one add. The add
    // wraps because the bound already rules out overflow, and the checked
    // vector add of safe builds reports overflow where there is none.
    while (i + block <= bytes.len) {
        var acc: VB = @splat(0);
        var k: usize = 0;
        while (k < 255 and i + block <= bytes.len) : ({
            k += 1;
            i += block;
        }) acc +%= leadOnes(bytes[i..][0..block].*);
        n += @reduce(.Add, @as(@Vector(block, u16), acc));
    }
    while (i < bytes.len) : (i += 1) n += @intFromBool(!isCont(bytes[i]));
    return n;
}

/// Byte offset of the character `count` characters after the one at
/// byte `off` in valid WTF-8, or `bytes.len` when the text ends first.
/// Long distances skip whole vector blocks whose characters all come
/// before the target. The rest goes eight bytes at a time and finds the
/// target inside its word without branching, because the position of a
/// character within a word is unpredictable and a mispredicted branch
/// costs more than the arithmetic.
pub inline fn advance(bytes: []const u8, off: usize, count: usize) usize {
    // One character ahead is the length of the character at `off`,
    // which its lead byte tells.
    if (count == 1 and off < bytes.len) return off + leadLen(bytes[off]);
    // A short distance inside the text takes one or two words, inline.
    if (count < 16 and off + 16 <= bytes.len) {
        const p0 = leadPrefix(std.mem.readInt(u64, bytes[off..][0..8], .little));
        const k0: usize = @intCast(p0 >> 56);
        if (k0 > count) return off + prefixTarget(p0, count);
        const p1 = leadPrefix(std.mem.readInt(u64, bytes[off + 8 ..][0..8], .little));
        const k1: usize = @intCast(p1 >> 56);
        if (k0 + k1 > count) return off + 8 + prefixTarget(p1, count - k0);
        return advanceLong(bytes, off + 16, count - k0 - k1);
    }
    return advanceLong(bytes, off, count);
}

/// The length in bytes of the character that starts with the lead byte
/// `b` in valid WTF-8: one more for each of the three thresholds the
/// byte reaches.
inline fn leadLen(b: u8) usize {
    return @as(usize, 1) + @intFromBool(b >= 0xC0) + @intFromBool(b >= 0xE0) + @intFromBool(b >= 0xF0);
}

/// Running counts of the lead bytes of `w`: byte j holds the number of
/// lead bytes in bytes 0 through j, so the top byte holds the total. A
/// continuation byte has bit 7 set and bit 6 clear. Shifting the word
/// left by one moves bit 6 of each byte under its bit 7, and the
/// multiplication adds up one bit per lead byte.
inline fn leadPrefix(w: u64) u64 {
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    return ((~(w & ~(w << 1)) & highs) >> 7) *% ones;
}

/// The first byte whose running count in `prefix` exceeds `rem`, which
/// the caller knows to exist. Every count is at most 8, so setting bit
/// 7 of each byte keeps the subtraction from borrowing across bytes.
inline fn prefixTarget(prefix: u64, rem: usize) usize {
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    const hit = ((prefix | highs) -% (rem + 1) *% ones) & highs;
    return @ctz(hit) / 8;
}

fn advanceLong(bytes: []const u8, off: usize, count: usize) usize {
    var i = off;
    var rem = count;
    if (rem >= block) {
        while (i + block <= bytes.len) {
            const k = leadCount(bytes[i..][0..block].*);
            if (k > rem) break;
            rem -= k;
            i += block;
        }
    }
    while (i + 8 <= bytes.len) {
        const prefix = leadPrefix(std.mem.readInt(u64, bytes[i..][0..8], .little));
        const k: usize = @intCast(prefix >> 56);
        if (k > rem) return i + prefixTarget(prefix, rem);
        rem -= k;
        i += 8;
    }
    while (i < bytes.len) : (i += 1) {
        if (isCont(bytes[i])) continue;
        if (rem == 0) return i;
        rem -= 1;
    }
    return bytes.len;
}

pub const Decoded = struct { cp: u21, len: u3 };

/// Decodes one code point at `i`, accepting surrogates (WTF-8) and rejecting
/// overlong forms and values above U+10FFFF.
pub fn decodeAt(bytes: []const u8, i: usize) ?Decoded {
    const c = bytes[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    if (c < 0xC2) return null;
    if (c < 0xE0) {
        if (i + 1 >= bytes.len) return null;
        const c1 = bytes[i + 1];
        if (c1 & 0xC0 != 0x80) return null;
        return .{ .cp = (@as(u21, c & 0x1F) << 6) | (c1 & 0x3F), .len = 2 };
    }
    if (c < 0xF0) {
        if (i + 2 >= bytes.len) return null;
        const c1 = bytes[i + 1];
        const c2 = bytes[i + 2];
        if (c1 & 0xC0 != 0x80 or c2 & 0xC0 != 0x80) return null;
        const cp = (@as(u21, c & 0x0F) << 12) | (@as(u21, c1 & 0x3F) << 6) | (c2 & 0x3F);
        if (cp < 0x800) return null;
        return .{ .cp = cp, .len = 3 };
    }
    if (c < 0xF5) {
        if (i + 3 >= bytes.len) return null;
        const c1 = bytes[i + 1];
        const c2 = bytes[i + 2];
        const c3 = bytes[i + 3];
        if (c1 & 0xC0 != 0x80 or c2 & 0xC0 != 0x80 or c3 & 0xC0 != 0x80) return null;
        const cp = (@as(u21, c & 0x07) << 18) | (@as(u21, c1 & 0x3F) << 12) | (@as(u21, c2 & 0x3F) << 6) | (c3 & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return null;
        return .{ .cp = cp, .len = 4 };
    }
    return null;
}

/// Decodes a code point known to be valid. Used on already validated text.
pub inline fn decodeValid(bytes: []const u8, i: usize) Decoded {
    const c = bytes[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    return decodeAt(bytes, i).?;
}

/// Encodes one code point (surrogates allowed) into `out`, returning the
/// number of bytes written.
pub fn encode(cp: u21, out: *[4]u8) u3 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// Length in bytes of the character starting with lead byte `c` in valid
/// text.
pub inline fn seqLen(c: u8) u3 {
    if (c < 0x80) return 1;
    if (c < 0xE0) return 2;
    if (c < 0xF0) return 3;
    return 4;
}

/// Returns the lead surrogate value if `bytes` ends with an encoded lead
/// surrogate.
pub fn trailingLeadSurrogate(bytes: []const u8) ?u21 {
    if (bytes.len < 3) return null;
    const t = bytes[bytes.len - 3 ..];
    if (t[0] != 0xED or t[1] < 0xA0 or t[1] > 0xAF) return null;
    return @intCast((@as(u21, t[0] & 0x0F) << 12) | (@as(u21, t[1] & 0x3F) << 6) | (t[2] & 0x3F));
}

/// Returns the trail surrogate value if `bytes` starts with an encoded
/// trail surrogate.
pub fn leadingTrailSurrogate(bytes: []const u8) ?u21 {
    if (bytes.len < 3) return null;
    if (bytes[0] != 0xED or bytes[1] < 0xB0 or bytes[1] > 0xBF) return null;
    return @intCast((@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F));
}

/// Combines a lead and a trail surrogate into a supplementary code point.
pub fn combineSurrogates(lead: u21, trail: u21) u21 {
    return 0x10000 + ((lead - 0xD800) << 10) + (trail - 0xDC00);
}

/// The length of the maximal subpart at the start of `s`, an ill-formed
/// UTF-8 sequence: its first byte and the continuation bytes after it
/// that a well-formed sequence starting with that byte could hold. Each
/// maximal subpart becomes one U+FFFD, the practice of Unicode and of the
/// WHATWG UTF-8 decoder.
pub fn maximalSubpart(s: []const u8) usize {
    const b0 = s[0];
    // The number of continuation bytes the lead takes, and the range of
    // the first one.
    const need: usize, const lo: u8, const hi: u8 = switch (b0) {
        0xC2...0xDF => .{ 1, 0x80, 0xBF },
        0xE0 => .{ 2, 0xA0, 0xBF },
        0xE1...0xEC, 0xEE...0xEF => .{ 2, 0x80, 0xBF },
        0xED => .{ 2, 0x80, 0x9F },
        0xF0 => .{ 3, 0x90, 0xBF },
        0xF1...0xF3 => .{ 3, 0x80, 0xBF },
        0xF4 => .{ 3, 0x80, 0x8F },
        else => return 1,
    };
    var n: usize = 1;
    while (n <= need and n < s.len) : (n += 1) {
        const c = s[n];
        const ok = if (n == 1) c >= lo and c <= hi else c >= 0x80 and c <= 0xBF;
        if (!ok) break;
    }
    return n;
}

/// Appends `bytes` to `out`, replacing each maximal subpart of an invalid
/// sequence with U+FFFD.
pub fn appendLossy(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var i: usize = 0;
    var prev_lead = false;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c < 0x80) {
            try out.append(gpa, c);
            i += 1;
            prev_lead = false;
            continue;
        }
        // A trail surrogate right after a lead stands for a pair that WTF-8
        // writes as one 4-byte sequence, so it becomes one U+FFFD.
        var skip = maximalSubpart(bytes[i..]);
        if (decodeAt(bytes, i)) |d| {
            const is_trail = d.cp >= 0xDC00 and d.cp <= 0xDFFF;
            if (!(is_trail and prev_lead)) {
                try out.appendSlice(gpa, bytes[i .. i + d.len]);
                prev_lead = d.cp >= 0xD800 and d.cp <= 0xDBFF;
                i += d.len;
                continue;
            }
            skip = d.len;
        }
        try out.appendSlice(gpa, "\xEF\xBF\xBD");
        i += skip;
        prev_lead = false;
    }
}

/// Returns `bytes` when it is valid WTF-8. Otherwise returns a copy in
/// which every byte of an invalid sequence reads `<\NNN>`, its decimal
/// value, so messages that quote source text stay valid text. The result
/// may be `bytes` itself, so `gpa` is meant to be an arena.
pub fn escapeInvalid(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (analyze(bytes).valid) return bytes;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var prev_lead = false;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c < 0x80) {
            try out.append(gpa, c);
            i += 1;
            prev_lead = false;
            continue;
        }
        if (decodeAt(bytes, i)) |d| {
            const is_trail = d.cp >= 0xDC00 and d.cp <= 0xDFFF;
            if (!(is_trail and prev_lead)) {
                try out.appendSlice(gpa, bytes[i .. i + d.len]);
                prev_lead = d.cp >= 0xD800 and d.cp <= 0xDBFF;
                i += d.len;
                continue;
            }
        }
        try out.print(gpa, "<\\{d}>", .{c});
        prev_lead = false;
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Length of the longest prefix of `bytes` no longer than `max` that ends
/// on a character boundary.
pub fn boundaryBefore(bytes: []const u8, max: usize) usize {
    if (max >= bytes.len) return bytes.len;
    var n = max;
    while (n > 0 and isCont(bytes[n])) n -= 1;
    return n;
}

const testing = std.testing;

test "escapeInvalid quotes invalid bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("h\u{e9}", try escapeInvalid(a, "h\u{e9}"));
    try testing.expectEqualStrings("a<\\195>b", try escapeInvalid(a, "a\xC3b"));
    try testing.expectEqualStrings("<\\255>\u{e9}", try escapeInvalid(a, "\xFF\u{e9}"));
    try testing.expectEqual(@as(usize, 1), boundaryBefore("a\u{e9}", 2));
    try testing.expectEqual(@as(usize, 3), boundaryBefore("a\u{e9}", 3));
}

test "analyze ascii and multibyte" {
    const a = analyze("hello world, this is longer than sixteen bytes");
    try testing.expect(a.valid and a.ascii);
    try testing.expectEqual(@as(usize, 46), a.chars);
    const b = analyze("héllo €𝄞");
    try testing.expect(b.valid and !b.ascii);
    try testing.expectEqual(@as(usize, 8), b.chars);
    try testing.expect(!analyze("\xff").valid);
    try testing.expect(!analyze("\xC0\x80").valid); // overlong
    try testing.expect(analyze("\xED\xA0\x80").valid); // lone lead surrogate
    try testing.expect(!analyze("\xED\xA0\x80\xED\xB0\x80").valid); // encoded pair
}

test "surrogate helpers" {
    var buf: [4]u8 = undefined;
    const n = encode(0xD83D, &buf);
    try testing.expectEqual(@as(u21, 0xD83D), trailingLeadSurrogate(buf[0..n]).?);
    const m = encode(0xDE00, &buf);
    try testing.expectEqual(@as(u21, 0xDE00), leadingTrailSurrogate(buf[0..m]).?);
    try testing.expectEqual(@as(u21, 0x1F600), combineSurrogates(0xD83D, 0xDE00));
}

/// The byte at a time validator that `analyze` must agree with. It
/// decodes every character with `decodeAt`.
fn analyzeScalar(bytes: []const u8) Analysis {
    var i: usize = 0;
    var chars: usize = 0;
    var ascii = true;
    var prev_lead_surrogate = false;
    while (i < bytes.len) {
        const d = decodeAt(bytes, i) orelse return .{ .valid = false, .ascii = false, .chars = chars, .error_offset = i };
        if (d.cp >= 0xDC00 and d.cp <= 0xDFFF and prev_lead_surrogate)
            return .{ .valid = false, .ascii = false, .chars = chars, .error_offset = i };
        prev_lead_surrogate = d.cp >= 0xD800 and d.cp <= 0xDBFF;
        if (d.len > 1) ascii = false;
        i += d.len;
        chars += 1;
    }
    return .{ .valid = true, .ascii = ascii, .chars = chars };
}

fn expectSameAnalysis(bytes: []const u8) !void {
    const want = analyzeScalar(bytes);
    const got = analyze(bytes);
    try testing.expectEqual(want.valid, got.valid);
    try testing.expectEqual(want.chars, got.chars);
    if (want.valid) {
        try testing.expectEqual(want.ascii, got.ascii);
    } else {
        try testing.expectEqual(want.error_offset, got.error_offset);
    }
}

/// Bytes that sit on or next to every boundary of the lead and
/// continuation ranges.
const edge_bytes = [_]u8{ 0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xAF, 0xB0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF };

test "vector validator matches the scalar one on every two byte prefix" {
    // Every lead byte with every second byte, followed by the edge bytes,
    // complete and truncated after each byte.
    for (0..256) |c0| for (0..256) |c1| for (edge_bytes) |c2| for (edge_bytes) |c3| {
        const seq = [4]u8{ @intCast(c0), @intCast(c1), c2, c3 };
        try expectSameAnalysis(&seq);
        if (c0 >= 0xC0 and c3 == 0x80) {
            try expectSameAnalysis(seq[0..1]);
            try expectSameAnalysis(seq[0..2]);
            try expectSameAnalysis(seq[0..3]);
        }
    };
}

test "vector validator matches the scalar one at every block position" {
    // Sequences of edge bytes placed so that they start, cross, and end at
    // every position around a vector block boundary, then truncated.
    var buf: [2 * block + 8]u8 = undefined;
    for (edge_bytes) |c0| {
        if (c0 < 0xC0) continue;
        for (edge_bytes) |c1| for (edge_bytes) |c2| for (edge_bytes) |c3| {
            const seq = [4]u8{ c0, c1, c2, c3 };
            var off: usize = block - 5;
            while (off <= block + 1) : (off += 1) {
                @memset(&buf, 'a');
                @memcpy(buf[off..][0..4], &seq);
                try expectSameAnalysis(&buf);
                try expectSameAnalysis(buf[0 .. off + 1]);
                try expectSameAnalysis(buf[0 .. off + 2]);
                try expectSameAnalysis(buf[0 .. off + 3]);
            }
        };
    }
}

test "vector validator on surrogates and supplementary characters" {
    var out: [4]u8 = undefined;
    // Every lone surrogate is valid on its own.
    var cp: u21 = 0xD800;
    while (cp <= 0xDFFF) : (cp += 1) {
        const n = encode(cp, &out);
        try testing.expect(analyze(out[0..n]).valid);
        try expectSameAnalysis(out[0..n]);
    }
    // A lead surrogate followed by a trail surrogate is invalid at every
    // position, while the reverse order is valid.
    var buf: [3 * block]u8 = undefined;
    for (0..2 * block) |off| {
        @memset(&buf, 'x');
        @memcpy(buf[off..][0..6], "\xED\xA0\x80\xED\xB0\x80");
        const a = analyze(&buf);
        try testing.expect(!a.valid);
        try testing.expectEqual(off + 3, a.error_offset);
        try expectSameAnalysis(&buf);
        @memcpy(buf[off..][0..6], "\xED\xB0\x80\xED\xA0\x80");
        try testing.expect(analyze(&buf).valid);
        try expectSameAnalysis(&buf);
    }
    // A character from the ED row that is not a surrogate may precede a
    // trail surrogate.
    try testing.expect(analyze("\xED\x8C\x95\xED\xB0\x9C").valid);
    try testing.expect(analyze("\xED\x9F\xBF\xED\xB0\x80").valid);
    // Overlong forms and values past U+10FFFF.
    const bad = [_][]const u8{ "\xC0\xAF", "\xC1\xBF", "\xE0\x80\xAF", "\xE0\x9F\xBF", "\xF0\x80\x80\xAF", "\xF0\x8F\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xF8\x88\x80\x80\x80" };
    for (bad) |b| {
        try testing.expect(!analyze(b).valid);
        try expectSameAnalysis(b);
    }
    // Every code point is one valid character.
    cp = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        const n = encode(cp, &out);
        const a = analyze(out[0..n]);
        try testing.expect(a.valid);
        try testing.expectEqual(@as(usize, 1), a.chars);
    }
}

test "vector validator, counter, and advance on random text" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const r = prng.random();
    var buf: [200]u8 = undefined;
    var out: [4]u8 = undefined;
    for (0..20000) |_| {
        // Build valid text from random code points, then corrupt one byte
        // half of the time.
        var n: usize = 0;
        const want = r.uintLessThan(usize, buf.len - 4);
        while (n < want) {
            const cp: u21 = switch (r.uintLessThan(u8, 10)) {
                0...5 => r.uintLessThan(u21, 0x80),
                6 => r.uintLessThan(u21, 0x800),
                7 => r.uintLessThan(u21, 0x10000),
                else => r.uintLessThan(u21, 0x110000),
            };
            const k = encode(cp, &out);
            @memcpy(buf[n..][0..k], out[0..k]);
            n += k;
        }
        if (n > 0 and r.boolean()) buf[r.uintLessThan(usize, n)] = r.int(u8);
        try expectSameAnalysis(buf[0..n]);
        const a = analyze(buf[0..n]);
        if (!a.valid) continue;
        try testing.expectEqual(a.chars, countChars(buf[0..n]));
        // Advancing agrees with stepping one character at a time.
        const from_char = r.uintLessThan(usize, a.chars + 1);
        var off: usize = 0;
        for (0..from_char) |_| off += seqLen(buf[off]);
        const steps = r.uintLessThan(usize, a.chars - from_char + 2);
        var want_off = off;
        for (0..steps) |_| {
            if (want_off >= n) break;
            want_off += seqLen(buf[want_off]);
        }
        try testing.expectEqual(want_off, advance(buf[0..n], off, steps));
    }
}

test "ascii prefix" {
    try testing.expectEqual(@as(usize, 0), asciiPrefix(""));
    try testing.expectEqual(@as(usize, 3), asciiPrefix("abc"));
    var buf: [100]u8 = undefined;
    for (0..buf.len) |k| {
        @memset(&buf, 'a');
        buf[k] = 0xC3;
        try testing.expectEqual(k, asciiPrefix(&buf));
    }
}
