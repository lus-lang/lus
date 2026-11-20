//! The `tocsv` and `fromcsv` globals: RFC 4180 CSV with a configurable
//! single character delimiter. Fields are strings, quoted fields may hold
//! delimiters, line breaks and doubled quotes, and rows end at "\n",
//! "\r\n" or "\r".

const std = @import("std");
const value = @import("../vm/value.zig");
const object = @import("../vm/object.zig");
const state = @import("../vm/state.zig");
const ops = @import("../vm/ops.zig");
const wtf8 = @import("../vm/wtf8.zig");
const table = @import("../vm/table.zig");
const gc = @import("../vm/gc.zig");
const aux = @import("auxlib.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;
const Table = object.Table;

pub fn open(l: *Thread) Error!void {
    try aux.setGlobal(l, "tocsv", try aux.native(l, tocsv, "tocsv"));
    try aux.setGlobal(l, "fromcsv", try aux.native(l, fromcsv, "fromcsv"));
}

/// The optional delimiter argument `i`: exactly one character, a comma
/// by default.
fn checkDelimiter(l: *Thread, i: u32) Error![]const u8 {
    if (l.arg(i).isNil()) return ",";
    const s = try aux.checkString(l, i);
    if (s.chars != 1) return aux.argError(l, i, "delimiter must be a single character", .{});
    return s.bytes();
}

// ---------------------------------------------------------------------
// Parser

const Parser = struct {
    l: *Thread,
    src: []const u8,
    /// The source is ASCII, so every field is.
    ascii: bool,
    pos: usize = 0,
    delim: []const u8,
    field: std.ArrayList(u8) = .empty,
    /// The column count of the last row, which sizes the next one.
    width: usize = 0,

    fn atDelim(p: *const Parser) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], p.delim);
    }

    fn atFieldEnd(p: *const Parser) bool {
        return p.pos >= p.src.len or p.atDelim() or p.src[p.pos] == '\n' or p.src[p.pos] == '\r';
    }

    /// Raises a parse error at the current position, counted in
    /// characters from 1.
    fn fail(p: *Parser, msg: []const u8) Error {
        const at = wtf8.analyze(p.src[0..p.pos]).chars + 1;
        return p.l.raiseFmt("CSV parse error at position {d}: {s}", .{ at, msg });
    }

    /// A string of field text. The source is a string, so it is valid
    /// WTF-8, and a field cut from it at ASCII bytes is valid as well.
    fn make(p: *Parser, bytes: []const u8) Error!Value {
        var ascii = p.ascii;
        var chars = bytes.len;
        if (!ascii) {
            ascii = wtf8.asciiPrefix(bytes) == bytes.len;
            if (!ascii) chars = wtf8.countChars(bytes);
        }
        return Value.obj(.string, state.newStringKnown(p.l.g, bytes, ascii, chars) catch return p.l.raiseMem());
    }

    /// Parses a quoted field. `pos` is at the opening quote on entry and
    /// after the closing quote on exit.
    fn quoted(p: *Parser) Error!Value {
        const gpa = p.l.g.gpa;
        p.field.clearRetainingCapacity();
        p.pos += 1;
        while (p.pos < p.src.len) {
            const rest = p.src[p.pos..];
            const q = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            p.field.appendSlice(gpa, rest[0..q]) catch return p.l.raiseMem();
            p.pos += q + 1;
            if (p.pos < p.src.len and p.src[p.pos] == '"') {
                // A doubled quote stands for one quote.
                p.field.append(gpa, '"') catch return p.l.raiseMem();
                p.pos += 1;
            } else {
                return p.make(p.field.items);
            }
        }
        p.pos = p.src.len;
        return p.fail("unterminated quoted field");
    }

    fn unquoted(p: *Parser) Error!Value {
        const start = p.pos;
        if (p.delim.len == 1) {
            const d = p.delim[0];
            var i = p.pos;
            while (i < p.src.len) : (i += 1) {
                const c = p.src[i];
                if (c == d or c == '\n' or c == '\r') break;
            }
            p.pos = i;
        } else {
            while (!p.atFieldEnd()) p.pos += 1;
        }
        return p.make(p.src[start..p.pos]);
    }

    /// Parses one row into a new table and stores it at `rows[n]`. The
    /// fields wait on the stack, which keeps them alive, and the row is
    /// made at its exact size. A row with more than `flush_at` fields
    /// moves them into its table in batches.
    fn row(p: *Parser, rows: *Table, n: i64) Error!void {
        const l = p.l;
        const gpa = l.g.gpa;
        const slot = l.top;
        try l.push(.nil);
        defer l.top = slot;
        var r: ?*Table = null;
        var stored: usize = 0;
        while (true) {
            const is_quoted = p.pos < p.src.len and p.src[p.pos] == '"';
            const f = if (is_quoted) try p.quoted() else try p.unquoted();
            if (is_quoted and !p.atFieldEnd()) return p.fail("unexpected character after quoted field");
            try l.push(f);
            const last = p.pos >= p.src.len or !p.atDelim();
            if (last or l.top - slot > flush_at) {
                const count = l.top - slot - 1;
                if (r == null) {
                    const t = try l.newTable(if (last) count else @max(count, p.width), 0);
                    l.stack[slot] = Value.obj(.table, t);
                    r = t;
                }
                const t = r.?;
                // A long row grows by doubling, like any array.
                if (stored + count > t.asize and !last)
                    table.resize(gpa, t, @max(stored + count, 2 * @as(usize, t.asize)), t.hash_used) catch return l.raiseMem();
                table.storeList(gpa, t, stored, l.stack[slot + 1 ..][0..count]) catch return l.raiseMem();
                stored += count;
                l.top = slot + 1;
            }
            if (p.pos >= p.src.len) break;
            if (!last) {
                p.pos += p.delim.len;
                continue;
            }
            // A line ending closes the row.
            if (p.src[p.pos] == '\r') p.pos += 1;
            if (p.pos < p.src.len and p.src[p.pos] == '\n') p.pos += 1;
            break;
        }
        const t = r.?;
        gc.barrierBack(l.g, &t.hdr);
        p.width = stored;
        const rv = Value.obj(.table, t);
        if (n >= 1 and n <= rows.asize and !rows.isReadonly() and rows.metatable == null and table.arrayStoreFast(rows, @intCast(n - 1), rv)) {
            gc.barrierBack(l.g, &rows.hdr);
        } else try ops.rawSet(l, rows, Value.int(n), rv);
    }

    const flush_at = 256;
};

fn fromcsv(l: *Thread) Error!u32 {
    const input = try aux.checkBytes(l, 1);
    const use_headers = l.arg(2).truthy();
    const delim = try checkDelimiter(l, 3);
    l.top = l.base() + @min(l.argCount(), 3);

    const rows = try l.newTable(0, 0);
    try l.push(Value.obj(.table, rows));
    var p: Parser = .{ .l = l, .src = input, .ascii = l.arg(1).as(object.String).flags.ascii, .delim = delim };
    defer p.field.deinit(l.g.gpa);
    var nrows: i64 = 0;
    if (input.len > 0) {
        while (true) {
            nrows += 1;
            try p.row(rows, nrows);
            if (p.pos >= input.len) break;
        }
    }
    if (!use_headers or nrows == 0) return 1;

    // The first row names the keys of the following rows.
    const header = (try ops.index(l, Value.obj(.table, rows), Value.int(1))).as(Table);
    const ncols = @import("../vm/table.zig").length(header);
    const keyed = try l.newTable(@intCast(nrows - 1), 0);
    try l.push(Value.obj(.table, keyed));
    var i: i64 = 2;
    while (i <= nrows) : (i += 1) {
        const data = try ops.index(l, Value.obj(.table, rows), Value.int(i));
        const k = try l.newTable(0, @intCast(ncols));
        try l.push(Value.obj(.table, k));
        defer l.top -= 1;
        var j: i64 = 1;
        while (j <= ncols) : (j += 1) {
            const name = try ops.index(l, Value.obj(.table, header), Value.int(j));
            const field = try ops.index(l, data, Value.int(j));
            try ops.setIndex(l, Value.obj(.table, k), name, field);
        }
        try ops.rawSet(l, keyed, Value.int(i - 1), Value.obj(.table, k));
    }
    return 1;
}

// ---------------------------------------------------------------------
// Writer

/// `#v` honoring `__len`, which must produce an integer.
fn lengthOf(l: *Thread, v: Value) Error!i64 {
    const n = try ops.length(l, v);
    if (n.tag == .integer) return n.asInt();
    return ops.toIntegerStrict(n) orelse l.raiseFmt("object length is not an integer", .{});
}

fn needsQuoting(s: []const u8, delim: []const u8) bool {
    if (std.mem.indexOf(u8, s, delim) != null) return true;
    return std.mem.indexOfAny(u8, s, "\"\n\r") != null;
}

fn writeField(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, delim: []const u8) !void {
    if (!needsQuoting(s, delim)) return buf.appendSlice(gpa, s);
    try buf.append(gpa, '"');
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '"')) |q| {
        // Double every quote.
        try buf.appendSlice(gpa, rest[0 .. q + 1]);
        try buf.append(gpa, '"');
        rest = rest[q + 1 ..];
    }
    try buf.appendSlice(gpa, rest);
    try buf.append(gpa, '"');
}

fn tocsv(l: *Thread) Error!u32 {
    _ = try aux.checkTable(l, 1);
    const delim = try checkDelimiter(l, 2);
    l.top = l.base() + @min(l.argCount(), 2);
    const gpa = l.g.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const rows = l.arg(1);
    const nrows = try lengthOf(l, rows);
    var i: i64 = 1;
    while (i <= nrows) : (i += 1) {
        const r = try ops.index(l, rows, Value.int(i));
        if (r.tag != .table) return l.raiseFmt("row {d} is not a table", .{i});
        // Keep the row reachable while `__tostring` and `__index` run.
        try l.push(r);
        defer l.top -= 1;
        const ncols = try lengthOf(l, r);
        var j: i64 = 1;
        while (j <= ncols) : (j += 1) {
            if (j > 1) buf.appendSlice(gpa, delim) catch return l.raiseMem();
            const f = try ops.index(l, r, Value.int(j));
            if (f.isNil()) continue;
            try l.push(f);
            defer l.top -= 1;
            const s = try ops.toString(l, f);
            writeField(gpa, &buf, s.bytes(), delim) catch return l.raiseMem();
        }
        buf.append(gpa, '\n') catch return l.raiseMem();
    }
    return aux.retStr(l, buf.items);
}
