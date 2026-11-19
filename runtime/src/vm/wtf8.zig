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

const vec_len = 16;
const V = @Vector(vec_len, u8);

/// Validates `bytes` as WTF-8 and counts code points. ASCII runs are
/// processed sixteen bytes at a time.
pub fn analyze(bytes: []const u8) Analysis {
    var i: usize = 0;
    var chars: usize = 0;
    var ascii = true;
    const n = bytes.len;
    var prev_lead_surrogate = false;
    while (i < n) {
        // Fast path: a block of sixteen ASCII bytes.
        if (i + vec_len <= n) {
            const block: V = bytes[i..][0..vec_len].*;
            const high: @Vector(vec_len, bool) = block >= @as(V, @splat(0x80));
            if (!@reduce(.Or, high)) {
                i += vec_len;
                chars += vec_len;
                prev_lead_surrogate = false;
                continue;
            }
        }
        const c = bytes[i];
        if (c < 0x80) {
            i += 1;
            chars += 1;
            prev_lead_surrogate = false;
            continue;
        }
        ascii = false;
        const d = decodeAt(bytes, i) orelse return .{ .valid = false, .ascii = false, .chars = chars, .error_offset = i };
        // A trail surrogate directly after a lead surrogate must have been
        // encoded as one supplementary character.
        if (d.cp >= 0xDC00 and d.cp <= 0xDFFF and prev_lead_surrogate)
            return .{ .valid = false, .ascii = false, .chars = chars, .error_offset = i };
        prev_lead_surrogate = d.cp >= 0xD800 and d.cp <= 0xDBFF;
        i += d.len;
        chars += 1;
    }
    return .{ .valid = true, .ascii = ascii, .chars = chars };
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

/// Appends `bytes` to `out`, replacing every invalid sequence with U+FFFD.
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
        if (decodeAt(bytes, i)) |d| {
            const is_trail = d.cp >= 0xDC00 and d.cp <= 0xDFFF;
            if (!(is_trail and prev_lead)) {
                try out.appendSlice(gpa, bytes[i .. i + d.len]);
                prev_lead = d.cp >= 0xD800 and d.cp <= 0xDBFF;
                i += d.len;
                continue;
            }
        }
        try out.appendSlice(gpa, "\xEF\xBF\xBD");
        prev_lead = false;
        i += 1;
    }
}

const testing = std.testing;

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
