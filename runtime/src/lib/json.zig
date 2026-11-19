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
const aux = @import("aux.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;
const String = object.String;

const max_depth = 1000;

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
        // Fast path: no escapes.
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                const raw = p.s[start..p.i];
                p.i += 1;
                return p.mkString(raw);
            }
            if (c == '\\') break;
            if (c < 0x20) return p.fail("control character in string", .{});
            p.i += 1;
        }
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

    fn mkString(p: *Parser, bytes: []const u8) Error!Value {
        const a = wtf8.analyze(bytes);
        if (!a.valid) return p.fail("invalid UTF-8 in string", .{});
        return Value.obj(.string, state.newStringKnown(p.l.g, bytes, a.ascii, a.chars) catch return p.l.raiseMem());
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
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

    const Frame = struct {
        t: *Table,
        is_array: bool,
        n: i64 = 0,
        key: Value = .nil,
    };

    fn parse(p: *Parser) Error!Value {
        const l = p.l;
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(l.g.gpa);
        // Containers are anchored on the Lus stack so they stay reachable
        // while the parse allocates.
        const anchor = l.top;
        defer l.top = anchor;
        var result: Value = .nil;
        var v: Value = undefined;
        outer: while (true) {
            // Read a value: scalar, or open a container.
            if (try p.scalar()) |sv| {
                v = sv;
            } else {
                const c = p.s[p.i];
                p.i += 1;
                if (stack.items.len >= max_depth) return p.fail("maximum nesting depth exceeded", .{});
                const t = try l.newTable(0, 0);
                try l.push(Value.obj(.table, t));
                stack.append(l.g.gpa, .{ .t = t, .is_array = c == '[' }) catch return l.raiseMem();
                const top = &stack.items[stack.items.len - 1];
                if (c == '[') {
                    if (p.peek() == ']') {
                        p.i += 1;
                        v = Value.obj(.table, t);
                        _ = stack.pop();
                    } else continue :outer;
                } else {
                    if (p.peek() == '}') {
                        p.i += 1;
                        v = Value.obj(.table, t);
                        _ = stack.pop();
                    } else {
                        if (p.peek() != '"') return p.fail("expected string key in object", .{});
                        top.key = try p.string();
                        try p.expect(':', "after object key");
                        continue :outer;
                    }
                }
            }
            // Deliver v to the enclosing container, closing finished ones.
            while (true) {
                if (stack.items.len == 0) {
                    result = v;
                    break :outer;
                }
                const f = &stack.items[stack.items.len - 1];
                if (f.is_array) {
                    f.n += 1;
                    if (!v.isNil()) try ops.rawSet(l, f.t, Value.int(f.n), v);
                    if (p.peek() == ',') {
                        p.i += 1;
                        continue :outer;
                    }
                    try p.expect(']', "after array element");
                } else {
                    try ops.rawSet(l, f.t, f.key, v);
                    if (p.peek() == ',') {
                        p.i += 1;
                        if (p.peek() != '"') return p.fail("expected string key", .{});
                        f.key = try p.string();
                        try p.expect(':', "after object key");
                        continue :outer;
                    }
                    try p.expect('}', "after object value");
                }
                v = Value.obj(.table, f.t);
                _ = stack.pop();
            }
        }
        if (p.peek() != null) return p.fail("unexpected trailing characters", .{});
        return result;
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
    out: std.ArrayList(u8) = .empty,
    filter: Value,
    /// Tables on the current path, for cycle detection.
    path: std.AutoHashMapUnmanaged(usize, void) = .empty,
    depth: usize = 0,

    fn write(w: *Writer, b: []const u8) Error!void {
        w.out.appendSlice(w.l.g.gpa, b) catch return w.l.raiseMem();
    }

    fn str(w: *Writer, s: []const u8) Error!void {
        const gpa = w.l.g.gpa;
        w.out.append(gpa, '"') catch return w.l.raiseMem();
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '"' => try w.write("\\\""),
                '\\' => try w.write("\\\\"),
                '\n' => try w.write("\\n"),
                '\r' => try w.write("\\r"),
                '\t' => try w.write("\\t"),
                0x08 => try w.write("\\b"),
                0x0c => try w.write("\\f"),
                0...7, 11, 14...31, 127 => w.out.print(gpa, "\\u{x:0>4}", .{c}) catch return w.l.raiseMem(),
                else => {
                    if (c >= 0x80) {
                        const d = wtf8.decodeValid(s, i);
                        if (d.cp >= 0xD800 and d.cp <= 0xDFFF) {
                            // Lone surrogates are escaped so the output is
                            // valid UTF-8.
                            w.out.print(gpa, "\\u{x:0>4}", .{d.cp}) catch return w.l.raiseMem();
                        } else {
                            try w.write(s[i .. i + d.len]);
                        }
                        i += d.len;
                        continue;
                    }
                    w.out.append(gpa, c) catch return w.l.raiseMem();
                },
            }
            i += 1;
        }
        w.out.append(gpa, '"') catch return w.l.raiseMem();
    }

    fn number(w: *Writer, v: Value) Error!void {
        const gpa = w.l.g.gpa;
        switch (v.tag) {
            .integer => w.out.print(gpa, "{d}", .{v.asInt()}) catch return w.l.raiseMem(),
            .float => {
                const f = v.asFloat();
                if (std.math.isNan(f) or std.math.isInf(f)) return w.write("null");
                ops.formatG(gpa, &w.out, f, 17) catch return w.l.raiseMem();
            },
            else => ops.numberToBuf(gpa, &w.out, v) catch return w.l.raiseMem(),
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
            if (w.path.contains(@intFromPtr(cur.as(Table)))) return w.l.raiseFmt("circular reference detected in table", .{});
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

    fn value_(w: *Writer, v: Value) Error!void {
        switch (v.tag) {
            .nil => try w.write("null"),
            .true => try w.write("true"),
            .false => try w.write("false"),
            .integer, .float, .bigint, .decimal => try w.number(v),
            .string => try w.str(v.as(String).bytes()),
            .table => try w.tableValue(v.as(Table)),
            else => try w.write("null"),
        }
    }

    fn tableValue(w: *Writer, t: *Table) Error!void {
        const l = w.l;
        const key = @intFromPtr(t);
        if (w.path.contains(key)) return l.raiseFmt("circular reference detected in table", .{});
        if (w.depth >= max_depth) return l.raiseFmt("maximum nesting depth exceeded", .{});
        // The writer recurses natively, so each level is charged against
        // the interpreter's native call budget and deep nesting raises a
        // catchable C stack overflow.
        if (l.g.native_depth >= Thread.max_ncalls) return l.raiseFmt("C stack overflow", .{});
        w.path.put(l.g.gpa, key, {}) catch return l.raiseMem();
        w.depth += 1;
        l.g.native_depth += 1;
        defer {
            _ = w.path.remove(key);
            w.depth -= 1;
            l.g.native_depth -= 1;
        }
        // Array detection: the key set is exactly 1..n.
        var count: i64 = 0;
        var only_ints = true;
        var max: i64 = 0;
        var k: Value = .nil;
        while (table.next(t, k) catch null) |kv| : (k = kv.key) {
            count += 1;
            if (kv.key.tag == .integer and kv.key.asInt() >= 1) {
                max = @max(max, kv.key.asInt());
            } else only_ints = false;
        }
        if (count == 0 or (only_ints and max == count)) {
            try w.write("[");
            var i: i64 = 1;
            var first = true;
            while (i <= max) : (i += 1) {
                const raw = table.getInt(t, i);
                var item = (try w.transform(Value.int(i), raw)) orelse Value.nil;
                if (!serializable(item)) item = .nil;
                if (!first) try w.write(",");
                first = false;
                try w.value_(item);
            }
            try w.write("]");
            return;
        }
        try w.write("{");
        var first = true;
        k = .nil;
        while (table.next(t, k) catch null) |kv| : (k = kv.key) {
            if (kv.key.tag != .string) continue;
            const item = (try w.transform(kv.key, kv.val)) orelse continue;
            if (!serializable(item)) continue;
            if (!first) try w.write(",");
            first = false;
            try w.str(kv.key.as(String).bytes());
            try w.write(":");
            try w.value_(item);
        }
        try w.write("}");
    }
};

fn tojson(l: *Thread) Error!u32 {
    const v = try aux.checkAny(l, 1);
    const filter = l.arg(2);
    if (!filter.isNil() and filter.tag != .closure and filter.tag != .native) return aux.typeError(l, 2, "function");
    var w: Writer = .{ .l = l, .filter = filter };
    defer w.out.deinit(l.g.gpa);
    defer w.path.deinit(l.g.gpa);
    const root = (try w.transform(.nil, v)) orelse Value.nil;
    try w.value_(if (Writer.serializable(root)) root else .nil);
    return aux.retStr(l, w.out.items);
}
