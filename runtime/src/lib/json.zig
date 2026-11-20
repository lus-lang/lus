//! JSON: the `tojson` and `fromjson` globals. The parser is iterative
//! (an explicit container stack, never native recursion) and the writer
//! detects cycles and enforces the nesting limit.

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const table = @import("../vm/table.zig");
const ops = @import("../vm/ops.zig");
const numeric = @import("../vm/numeric.zig");
const wtf8 = @import("../vm/wtf8.zig");
const gc = @import("../vm/gc.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

const max_depth = 1000;

/// The parser and the writer scan strings this many bytes at a time.
const scan_block = 16;
const SV = @Vector(scan_block, u8);

/// Whether every byte of the block is printable ASCII other than a
/// quote and a backslash. Those bytes go through the parser unchanged.
inline fn plainBlock(v: SV) bool {
    // A byte from 0x20 through 0x7F maps to 0 through 0x5F.
    const shifted = v -% @as(SV, @splat(0x20));
    const in_range = @reduce(.Max, shifted) < 0x60;
    const quote = @reduce(.Or, v == @as(SV, @splat('"')));
    const bslash = @reduce(.Or, v == @as(SV, @splat('\\')));
    return in_range and !quote and !bslash;
}

/// Whether the writer copies every byte of the block unchanged: printable
/// ASCII other than a quote, a backslash, and DEL, or bytes of multi-byte
/// characters other than 0xED, the lead byte of a surrogate.
inline fn verbatimBlock(v: SV) bool {
    const control = @reduce(.Min, v) < 0x20;
    const quote = @reduce(.Or, v == @as(SV, @splat('"')));
    const bslash = @reduce(.Or, v == @as(SV, @splat('\\')));
    const del = @reduce(.Or, v == @as(SV, @splat(0x7F)));
    const ed = @reduce(.Or, v == @as(SV, @splat(0xED)));
    return !control and !quote and !bslash and !del and !ed;
}

pub fn open(l: *Thread) Error!void {
    try aux.setGlobal(l, "tojson", try aux.native(l, tojson, "tojson"));
    try aux.setGlobal(l, "fromjson", try aux.native(l, fromjson, "fromjson"));
}

// ---------------------------------------------------------------------
// Parsing

const Parser = struct {
    l: *Thread,
    s: []const u8,
    i: usize = 0,
    exact: bool,
    buf: std.ArrayList(u8) = .empty,
    keys: [256]?*String = @splat(null),

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        var tmp: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&tmp, fmt, args) catch "error";
        var out: [220]u8 = undefined;
        const full = std.fmt.bufPrint(&out, "JSON parse error at position {d}: {s}", .{ p.i + 1, msg }) catch "JSON parse error";
        return p.l.raiseMsg(full);
    }

    fn ws(p: *Parser) void {
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn peek(p: *Parser) ?u8 {
        p.ws();
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn expect(p: *Parser, c: u8, ctx: []const u8) Error!void {
        if (p.peek() != c) return p.fail("expected '{c}' {s}", .{ c, ctx });
        p.i += 1;
    }

    fn hex4(p: *Parser) Error!u21 {
        if (p.i + 4 > p.s.len) return p.fail("incomplete \\uXXXX escape", .{});
        var v: u21 = 0;
        for (p.s[p.i .. p.i + 4]) |c| {
            const d = @import("../syntax/lexer.zig").hexValue(c) orelse return p.fail("invalid hex digit", .{});
            v = v * 16 + d;
        }
        p.i += 4;
        return v;
    }

    fn string(p: *Parser) Error!Value {
        const gpa = p.l.g.gpa;
        p.i += 1; // opening quote
        p.buf.clearRetainingCapacity();
        const start = p.i;
        // Fast path: no escapes. The scan skips a block at a time while
        // every byte is printable ASCII other than a quote or a
        // backslash, and it notes whether any byte is not ASCII, so an
        // ASCII string needs no second pass to validate and count.
        var high = false;
        const s = p.s;
        var i = p.i;
        while (true) {
            while (i + scan_block <= s.len) {
                const v: SV = s[i..][0..scan_block].*;
                if (!plainBlock(v)) break;
                i += scan_block;
            }
            if (i >= s.len) break;
            const c = s[i];
            if (c == '"') {
                const raw = s[start..i];
                p.i = i + 1;
                if (!high) return p.mkAscii(raw);
                return p.mkString(raw);
            }
            if (c == '\\') break;
            if (c < 0x20) {
                p.i = i;
                return p.fail("control character in string", .{});
            }
            if (c >= 0x80) high = true;
            i += 1;
        }
        p.i = i;
        p.buf.appendSlice(gpa, p.s[start..p.i]) catch return p.l.raiseMem();
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            switch (c) {
                '"' => {
                    p.i += 1;
                    return p.mkString(p.buf.items);
                },
                '\\' => {
                    p.i += 1;
                    if (p.i >= p.s.len) return p.fail("unexpected end after backslash", .{});
                    const e = p.s[p.i];
                    p.i += 1;
                    const simple: ?u8 = switch (e) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => null,
                    };
                    if (simple) |sc| {
                        p.buf.append(gpa, sc) catch return p.l.raiseMem();
                    } else if (e == 'u') {
                        var cp = try p.hex4();
                        // A lead surrogate followed by an escaped trail
                        // surrogate forms one character. Lone surrogates
                        // are kept, which WTF-8 strings can represent.
                        if (cp >= 0xD800 and cp <= 0xDBFF and p.i + 6 <= p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                            const save = p.i;
                            p.i += 2;
                            const lo = try p.hex4();
                            if (lo >= 0xDC00 and lo <= 0xDFFF) cp = wtf8.combineSurrogates(cp, lo) else p.i = save;
                        }
                        var tmp: [4]u8 = undefined;
                        const n = wtf8.encode(cp, &tmp);
                        p.buf.appendSlice(gpa, tmp[0..n]) catch return p.l.raiseMem();
                    } else return p.fail("invalid escape sequence", .{});
                },
                else => {
                    if (c < 0x20) return p.fail("control character in string", .{});
                    p.buf.append(gpa, c) catch return p.l.raiseMem();
                    p.i += 1;
                },
            }
        }
        return p.fail("unterminated string", .{});
    }

    /// Parses an object key. Short ASCII keys without escapes come from a
    /// small cache of the keys this parse has made, because objects in a
    /// document tend to repeat their keys. Every cached key waits on the
    /// stack or sits in a table of the result, which keeps it alive. A
    /// key whose value is null is never stored, so `flush` drops it from
    /// the cache. A repeated key replaces a value, which may be a
    /// container that held keys of the cache, so `flush` empties the
    /// cache when an object has a repeated key.
    fn key(p: *Parser) Error!Value {
        const s = p.s;
        const start = p.i + 1;
        var i = start;
        const limit = @min(s.len, start + max_cached_key);
        while (i < limit) : (i += 1) {
            const c = s[i];
            if (c == '"') break;
            if (c == '\\' or c < 0x20 or c >= 0x80) return p.string();
        } else return p.string();
        const text = s[start..i];
        const slot = &p.keys[keySlot(text)];
        if (slot.*) |k| {
            if (k.len == text.len and std.mem.eql(u8, k.bytes(), text)) {
                p.i = i + 1;
                gc.touchInterned(p.l.g, k);
                return Value.obj(.string, k);
            }
        }
        p.i = i + 1;
        const v = try p.mkAscii(text);
        slot.* = v.as(String);
        return v;
    }

    const max_cached_key = 32;

    fn keySlot(text: []const u8) usize {
        if (text.len == 0) return 0;
        return (text.len *% 31 +% @as(usize, text[0]) *% 7 +% text[text.len - 1] *% 3 +% text[text.len / 2]) & 255;
    }

    fn mkAscii(p: *Parser, bytes: []const u8) Error!Value {
        return Value.obj(.string, state.newStringKnown(p.l.g, bytes, true, bytes.len) catch return p.l.raiseMem());
    }

    fn mkString(p: *Parser, bytes: []const u8) Error!Value {
        const a = wtf8.analyze(bytes);
        if (!a.valid) return p.fail("invalid UTF-8 in string", .{});
        return Value.obj(.string, state.newStringKnown(p.l.g, bytes, a.ascii, a.chars) catch return p.l.raiseMem());
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
        // Fast path: an integer of at most 18 digits, which cannot
        // overflow, followed by a byte that cannot continue a number.
        {
            var i = p.i;
            const neg = p.s[i] == '-';
            if (neg) i += 1;
            const first = i;
            var acc: i64 = 0;
            while (i < p.s.len and i - first < 18) : (i += 1) {
                const d = p.s[i] -% '0';
                if (d > 9) break;
                acc = acc * 10 + d;
            }
            const n = i - first;
            const lead_ok = n == 1 or (n > 1 and p.s[first] != '0');
            if (lead_ok and (i >= p.s.len or switch (p.s[i]) {
                '0'...'9', '.', 'e', 'E' => false,
                else => true,
            })) {
                p.i = i;
                return Value.int(if (neg) -acc else acc);
            }
        }
        if (p.s[p.i] == '-') p.i += 1;
        if (p.i >= p.s.len or !std.ascii.isDigit(p.s[p.i])) return p.fail("invalid number", .{});
        if (p.s[p.i] == '0' and p.i + 1 < p.s.len and std.ascii.isDigit(p.s[p.i + 1])) return p.fail("leading zeros not allowed", .{});
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        var is_float = false;
        if (p.i < p.s.len and p.s[p.i] == '.') {
            is_float = true;
            p.i += 1;
            if (p.i >= p.s.len or !std.ascii.isDigit(p.s[p.i])) return p.fail("digit expected after decimal", .{});
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        }
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            is_float = true;
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
            if (p.i >= p.s.len or !std.ascii.isDigit(p.s[p.i])) return p.fail("digit expected in exponent", .{});
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        }
        const text = p.s[start..p.i];
        const g = p.l.g;
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |v| return Value.int(v) else |_| {}
            if (p.exact) return Value.obj(.bigint, numeric.parseBigLiteral(g, text) catch return p.l.raiseMem());
            const save = p.i;
            p.i = start;
            _ = save;
            return p.fail("number out of range", .{});
        }
        if (p.exact) return Value.obj(.decimal, numeric.parseDecimalLiteral(g, text) catch return p.fail("invalid number", .{}));
        const f = std.fmt.parseFloat(f64, text) catch return p.fail("invalid number", .{});
        if (std.math.isInf(f)) {
            p.i = start;
            return p.fail("number out of range", .{});
        }
        return Value.float(f);
    }

    fn literal(p: *Parser, lit: []const u8, v: Value) Error!Value {
        if (p.i + lit.len > p.s.len or !std.mem.eql(u8, p.s[p.i .. p.i + lit.len], lit)) return p.fail("expected '{s}'", .{lit});
        p.i += lit.len;
        return v;
    }

    /// Parses a scalar or returns null for '[' or '{' (not consumed).
    fn scalar(p: *Parser) Error!?Value {
        const c = p.peek() orelse return p.fail("unexpected end of input", .{});
        return switch (c) {
            '"' => try p.string(),
            '-', '0'...'9' => try p.number(),
            't' => try p.literal("true", .true),
            'f' => try p.literal("false", .false),
            'n' => try p.literal("null", .nil),
            '[', '{' => null,
            else => p.fail("unexpected character", .{}),
        };
    }

    /// An open container. Its values wait on the Lus stack above the slot
    /// `base`, keys and values alternating for an object, and the table
    /// is made at its exact size when the container closes. A container
    /// with more than `flush_at` waiting values moves them into its table
    /// early, so the stack stays small. The table lives in the slot
    /// `base` once it exists.
    const Frame = struct {
        base: u32,
        is_array: bool,
        t: ?*Table = null,
        /// Array elements already moved into the table.
        n: usize = 0,
    };

    /// Drops `k` from the key cache.
    fn forget(p: *Parser, k: *String) void {
        if (k.len > max_cached_key) return;
        const slot = &p.keys[keySlot(k.bytes())];
        if (slot.* == k) slot.* = null;
    }

    const flush_at = 1024;
    const tight_room = 4 * flush_at;

    /// Moves the waiting values of `f` into its table, making the table
    /// when it does not exist yet. `last` is true at the close of the
    /// container. A long array grows by doubling, as stores grow it.
    fn flush(p: *Parser, f: *Frame, last: bool) Error!void {
        const l = p.l;
        const gpa = l.g.gpa;
        const first = f.base + 1;
        const count = l.top - first;
        if (f.is_array) {
            if (f.t == null) {
                // Making the table can collect, and the waiting values
                // are on the stack, which keeps them alive.
                const t = try l.newTable(count, 0);
                l.stack[f.base] = Value.obj(.table, t);
                f.t = t;
            }
            const t = f.t.?;
            const end = f.n + count;
            if (end > t.asize) {
                const grow = if (last) end else @max(end, t.asize * 2);
                table.resize(gpa, t, grow, t.hash_used) catch return l.raiseMem();
            }
            table.storeList(gpa, t, f.n, l.stack[first..][0..count]) catch return l.raiseMem();
            f.n = end;
            gc.barrierBack(l.g, &t.hdr);
        } else {
            const pairs = count / 2;
            if (f.t == null) {
                const t = try l.newTable(0, pairs);
                l.stack[f.base] = Value.obj(.table, t);
                f.t = t;
            }
            const t = f.t.?;
            // Every key that is new adds one node. Fewer nodes mean that a
            // key repeated and its earlier value is gone.
            const used = t.hash_used;
            var added: usize = 0;
            var i: usize = 0;
            while (i < pairs) : (i += 1) {
                const k = &l.stack[first + 2 * i];
                const v = &l.stack[first + 2 * i + 1];
                if (v.isNil()) p.forget(k.as(String)) else added += 1;
                if (table.storeStr(t, k, v) == null)
                    table.set(gpa, t, k.*, v.*) catch return l.raiseMem();
            }
            if (t.hash_used != used + added) p.keys = @splat(null);
            t.tm_absent = 0;
            gc.barrierBack(l.g, &t.hdr);
        }
        l.top = first;
    }

    fn parse(p: *Parser) Error!Value {
        const l = p.l;
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(l.g.gpa);
        // Every value read waits on the Lus stack, which keeps it
        // reachable while the parse allocates, until its container
        // closes. A closed container ends in the slot of its table, which
        // is where its parent expects its next value.
        const anchor = l.top;
        defer l.top = anchor;
        outer: while (true) {
            // Read a value: scalar, or open a container.
            if (try p.scalar()) |sv| {
                try l.push(sv);
            } else {
                const c = p.s[p.i];
                p.i += 1;
                if (stack.items.len >= max_depth) return p.fail("maximum nesting depth exceeded", .{});
                try l.push(.nil);
                stack.append(l.g.gpa, .{ .base = l.top - 1, .is_array = c == '[' }) catch return l.raiseMem();
                const top = &stack.items[stack.items.len - 1];
                const close: u8 = if (c == '[') ']' else '}';
                if (p.peek() == close) {
                    p.i += 1;
                    try p.flush(top, true);
                    _ = stack.pop();
                } else if (c == '[') {
                    continue :outer;
                } else {
                    if (p.peek() != '"') return p.fail("expected string key in object", .{});
                    try l.push(try p.key());
                    try p.expect(':', "after object key");
                    continue :outer;
                }
            }
            // The value is on the stack. Continue its container, closing
            // finished ones.
            while (true) {
                if (stack.items.len == 0) break :outer;
                const f = &stack.items[stack.items.len - 1];
                // Close to the stack limit every value moves into its
                // table at once, so the parse needs stack only for the
                // containers still open.
                if (l.top - f.base > flush_at or l.top + tight_room > Thread.max_stack) try p.flush(f, false);
                if (f.is_array) {
                    if (p.peek() == ',') {
                        p.i += 1;
                        continue :outer;
                    }
                    try p.expect(']', "after array element");
                } else {
                    if (p.peek() == ',') {
                        p.i += 1;
                        if (p.peek() != '"') return p.fail("expected string key", .{});
                        try l.push(try p.key());
                        try p.expect(':', "after object key");
                        continue :outer;
                    }
                    try p.expect('}', "after object value");
                }
                try p.flush(f, true);
                _ = stack.pop();
            }
        }
        if (p.peek() != null) return p.fail("unexpected trailing characters", .{});
        return l.stack[anchor];
    }
};

fn fromjson(l: *Thread) Error!u32 {
    const a = l.arg(1);
    var src: []const u8 = undefined;
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(l.g.gpa);
    if (a.tag == .string) {
        src = a.as(String).bytes();
    } else if (a.isNumber()) {
        ops.numberToBuf(l.g.gpa, &tmp, a) catch return l.raiseMem();
        src = tmp.items;
    } else if (a.tag == .vector) {
        src = a.as(object.Vector).bytes.items;
    } else return aux.typeError(l, 1, "string");
    var exact = false;
    if (l.arg(2).tag == .table) exact = (try aux.getField(l, l.arg(2).as(Table), "exact")).truthy();
    var p: Parser = .{ .l = l, .s = src, .exact = exact };
    defer p.buf.deinit(l.g.gpa);
    const v = try p.parse();
    return aux.ret(l, v);
}

// ---------------------------------------------------------------------
// Writing

const Writer = struct {
    l: *Thread,
    /// The text, built where its string will live when it is long.
    out: std.ArrayList(u8) = .empty,
    sb: state.StringBuffer,
    filter: Value,
    /// Tables on the current path, for cycle detection. The path is as
    /// long as the nesting, which `max_depth` bounds.
    path: std.ArrayList(*Table) = .empty,
    depth: usize = 0,
    /// Continuation bytes written so far, so the result needs no second
    /// pass to count its characters.
    cont: usize = 0,

    fn write(w: *Writer, b: []const u8) Error!void {
        w.out.appendSlice(w.sb.allocator(), b) catch return w.l.raiseMem();
    }

    fn onPath(w: *Writer, t: *Table) bool {
        return std.mem.indexOfScalar(*Table, w.path.items, t) != null;
    }

    fn str(w: *Writer, s: *String) Error!void {
        const b = s.bytes();
        if (!s.flags.ascii) w.cont += b.len - s.chars;
        return w.strBytes(b);
    }

    fn strBytes(w: *Writer, s: []const u8) Error!void {
        try w.write("\"");
        var i: usize = 0;
        while (i < s.len) {
            // Copy the run of bytes that need no escape a block at a time.
            const run = i;
            while (i + scan_block <= s.len and verbatimBlock(s[i..][0..scan_block].*)) i += scan_block;
            while (i < s.len) : (i += 1) switch (s[i]) {
                0...0x1F, '"', '\\', 0x7F, 0xED => break,
                else => {},
            };
            if (i > run) try w.write(s[run..i]);
            if (i >= s.len) break;
            const c = s[i];
            switch (c) {
                '"' => try w.write("\\\""),
                '\\' => try w.write("\\\\"),
                '\n' => try w.write("\\n"),
                '\r' => try w.write("\\r"),
                '\t' => try w.write("\\t"),
                0x08 => try w.write("\\b"),
                0x0c => try w.write("\\f"),
                0xED => {
                    const d = wtf8.decodeValid(s, i);
                    if (d.cp >= 0xD800 and d.cp <= 0xDFFF) {
                        // Lone surrogates are escaped so the output is
                        // valid UTF-8. The three bytes of the character,
                        // two of them continuation bytes, become six
                        // ASCII bytes.
                        w.cont -= 2;
                        try w.escapeUnit(d.cp);
                    } else {
                        try w.write(s[i .. i + d.len]);
                    }
                    i += d.len;
                    continue;
                },
                else => try w.escapeUnit(c),
            }
            i += 1;
        }
        try w.write("\"");
    }

    /// Writes `\\u` and the four hex digits of `u`.
    fn escapeUnit(w: *Writer, u: u21) Error!void {
        var tmp: [6]u8 = undefined;
        return w.write(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{u}) catch unreachable);
    }

    fn int(w: *Writer, x: i64) Error!void {
        var buf: [20]u8 = undefined;
        var i = ops.intDigits(&buf, @abs(x));
        if (x < 0) {
            i -= 1;
            buf[i] = '-';
        }
        return w.write(buf[i..]);
    }

    fn number(w: *Writer, v: Value) Error!void {
        const gpa = w.l.g.gpa;
        switch (v.tag) {
            .integer => try w.int(v.asInt()),
            .float => {
                const f = v.asFloat();
                if (std.math.isNan(f) or std.math.isInf(f)) return w.write("null");
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(gpa);
                ops.formatG(gpa, &tmp, f, 17) catch return w.l.raiseMem();
                try w.write(tmp.items);
            },
            else => {
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(gpa);
                ops.numberToBuf(gpa, &tmp, v) catch return w.l.raiseMem();
                try w.write(tmp.items);
            },
        }
    }

    fn serializable(v: Value) bool {
        return switch (v.tag) {
            .nil, .true, .false, .integer, .float, .bigint, .decimal, .string, .table => true,
            else => false,
        };
    }

    /// Applies `__json` and the filter. Returns null when the value is
    /// dropped (filter returned nil).
    fn transform(w: *Writer, key: Value, v: Value) Error!?Value {
        var cur = v;
        // A `__json` result that itself has `__json` is transformed again,
        // so replacements chain. Each step counts against the nesting
        // limit, and a table that returns itself is a cycle.
        var steps: usize = 0;
        while (cur.tag == .table) {
            const mt = w.l.metatable(cur) orelse break;
            const k = state.newStringKnown(w.l.g, "__json", true, 6) catch return w.l.raiseMem();
            const j = table.getStr(mt, k);
            if (j.isNil()) break;
            if (w.onPath(cur.as(Table))) return w.l.raiseFmt("circular reference detected in table", .{});
            steps += 1;
            if (w.depth + steps > max_depth) return w.l.raiseFmt("maximum nesting depth exceeded", .{});
            const r = try ops.call1(w.l, j, &.{cur});
            if (r.tag == .table and r.as(Table) == cur.as(Table)) return w.l.raiseFmt("circular reference detected in table", .{});
            cur = r;
        }
        if (!w.filter.isNil()) {
            const r = try ops.call1(w.l, w.filter, &.{ key, cur });
            if (r.isNil()) return null;
            cur = r;
        }
        return cur;
    }

    /// Whether writing `v` under its key may run Lus code: there is a
    /// filter, or `v` is a table with a metatable, which may hold
    /// `__json`.
    inline fn mayRun(w: *Writer, v: Value) bool {
        return !w.filter.isNil() or (v.tag == .table and v.as(Table).metatable != null);
    }

    /// Writes `item`, which a filter or `__json` returned when `fresh` is
    /// true. Such a table may be reachable from nothing else, and the Lus
    /// code that runs while it is written may collect, so the stack keeps
    /// it alive.
    inline fn item_(w: *Writer, item: Value, fresh: bool) Error!void {
        if (!fresh or item.tag != .table) return w.value_(item);
        try w.l.push(item);
        defer w.l.top -= 1;
        return w.value_(item);
    }

    fn value_(w: *Writer, v: Value) Error!void {
        switch (v.tag) {
            .nil => try w.write("null"),
            .true => try w.write("true"),
            .false => try w.write("false"),
            .integer, .float, .bigint, .decimal => try w.number(v),
            .string => try w.str(v.as(String)),
            .table => try w.tableValue(v.as(Table)),
            else => try w.write("null"),
        }
    }

    fn tableValue(w: *Writer, t: *Table) Error!void {
        const l = w.l;
        if (w.onPath(t)) return l.raiseFmt("circular reference detected in table", .{});
        if (w.depth >= max_depth) return l.raiseFmt("maximum nesting depth exceeded", .{});
        // The writer recurses natively, so each level is charged against
        // the interpreter's native call budget and deep nesting raises a
        // catchable C stack overflow.
        if (l.g.native_depth >= Thread.max_ncalls) return l.raiseFmt("C stack overflow", .{});
        w.path.append(l.g.gpa, t) catch return l.raiseMem();
        w.depth += 1;
        l.g.native_depth += 1;
        defer {
            _ = w.path.pop();
            w.depth -= 1;
            l.g.native_depth -= 1;
        }
        // Array detection: the key set is exactly 1..n. The first key
        // that is not a positive integer settles that the table is an
        // object.
        var count: usize = 0;
        var max: i64 = 0;
        var is_object = false;
        for (0..t.asize) |idx| {
            if (!table.arrayIsNil(t, idx)) {
                count += 1;
                max = @intCast(idx + 1);
            }
        }
        for (t.hash) |n| {
            if (n.key.tag == .nil or n.val.isNil()) continue;
            if (n.key.tag == .integer and n.key.asInt() >= 1) {
                count += 1;
                max = @max(max, n.key.asInt());
            } else {
                is_object = true;
                break;
            }
        }
        if (!is_object and max == count) {
            try w.write("[");
            var i: i64 = 1;
            while (i <= max) : (i += 1) {
                const raw = table.getInt(t, i);
                const fresh = w.mayRun(raw);
                var item = (try w.transform(Value.int(i), raw)) orelse Value.nil;
                if (!serializable(item)) item = .nil;
                if (i > 1) try w.write(",");
                try w.item_(item, fresh);
            }
            try w.write("]");
            return;
        }
        // An object writes its string keys in the order of `next`, which
        // visits the hash part by node. A filter or `__json` function
        // runs Lus code that may change the table. The stack keeps the
        // key alive while that code runs, and when the code moved the
        // hash part, the walk finds the key again and continues after
        // it, as `next` would, or ends when the key is gone.
        try w.write("{");
        var first = true;
        var h: usize = 0;
        while (h < t.hash.len) : (h += 1) {
            const n = t.hash[h];
            if (n.key.tag != .string or n.val.isNil()) continue;
            const parts = t.hash;
            const fresh = w.mayRun(n.val);
            if (fresh) try l.push(n.key);
            defer if (fresh) {
                l.top -= 1;
            };
            if (try w.transform(n.key, n.val)) |item| {
                if (serializable(item)) {
                    if (!first) try w.write(",");
                    first = false;
                    try w.str(n.key.as(String));
                    try w.write(":");
                    try w.item_(item, fresh);
                }
            }
            if (fresh and (t.hash.ptr != parts.ptr or t.hash.len != parts.len)) {
                h = table.findSlot(t, n.key) orelse break;
            }
        }
        try w.write("}");
    }
};

fn tojson(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const filter = l.arg(2);
    if (!filter.isNil() and filter.tag != .closure and filter.tag != .native) return aux.typeError(l, 2, "function");
    var w: Writer = .{ .l = l, .filter = filter, .sb = .{ .g = l.g } };
    defer w.out.deinit(w.sb.allocator());
    defer w.path.deinit(l.g.gpa);
    const fresh = w.mayRun(v);
    const root = (try w.transform(.nil, v)) orelse Value.nil;
    try w.item_(if (Writer.serializable(root)) root else .nil, fresh);
    const chars = w.out.items.len - w.cont;
    const r = state.stringFromBuffer(l.g, &w.sb, &w.out, w.cont == 0, chars) catch return l.raiseMem();
    return aux.ret(l, Value.obj(.string, r));
}
