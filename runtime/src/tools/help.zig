//! `lus help`: prints the standard library reference compiled into the
//! executable, so the documentation always matches the running version.
//!
//! Usage: lus help [NAME | MODULE | --search TEXT]
//!
//! With a function or constant name, such as `string.find` or
//! `tcp_socket:receive`, it prints the signature, the permissions the
//! call needs, its stability, and the description. With a module name,
//! such as `network` or `fs.path`, it lists every entry of the module with
//! its signature and first sentence. With no argument it lists the
//! modules. `--search TEXT` lists the entries whose name or description
//! contains TEXT. A name that matches nothing suggests the names that
//! contain it. The exit status is 0 when something was printed and 1
//! otherwise.

const std = @import("std");
const docs = @import("agent_docs");

const usage =
    \\usage: lus help [NAME | MODULE | --search TEXT]
    \\
    \\Prints the reference for a standard library function, constant, or
    \\module, from the documentation built into this executable. With no
    \\argument, lists the modules.
    \\
;

/// One stdlib entry with the frontmatter fields the reference prints.
pub const Entry = struct {
    name: []const u8 = "",
    module: []const u8 = "",
    kind: []const u8 = "",
    stability: []const u8 = "",
    returns: []const u8 = "",
    vararg: bool = false,
    params: []const Param = &.{},
    pledges: []const u8 = "",
    body: []const u8 = "",

    pub const Param = struct { name: []const u8, optional: bool = false };
};

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const status = try help(arena, &out.writer, args);
    if (status == 2) {
        std.debug.print("{s}", .{usage});
    } else {
        std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    }
    return status;
}

/// Writes the help for `args` to `w` and returns the exit status.
pub fn help(arena: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !u8 {
    const entries = try loadAll(arena);
    if (args.len == 0) return listModules(arena, w, entries);
    const a = args[0];
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return 2;
    if (std.mem.eql(u8, a, "--search") or std.mem.eql(u8, a, "-s")) {
        if (args.len < 2) return 2;
        return search(w, entries, args[1]);
    }
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, a)) {
            try writeEntry(w, e);
            return 0;
        }
    }
    var listed = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.module, a)) {
            if (!listed) try w.print("{s}\n\n", .{a});
            listed = true;
            try writeLine(w, e);
        }
    }
    if (listed) return 0;
    try w.print("no entry named '{s}'", .{a});
    var n: usize = 0;
    for (entries) |e| {
        if (std.ascii.findIgnoreCase(e.name, a) != null) {
            try w.print("{s}\n  {s}", .{ if (n == 0) ", see:" else "", e.name });
            n += 1;
            if (n == 12) break;
        }
    }
    try w.writeAll("\n");
    return 1;
}

fn loadAll(arena: std.mem.Allocator) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    for (docs.stdlib) |f| {
        const e = parse(arena, f.data) catch continue;
        if (e.name.len == 0 or std.mem.eql(u8, e.stability, "removed")) continue;
        if (std.mem.endsWith(u8, f.path, "_module.md")) continue;
        try list.append(arena, e);
    }
    return list.items;
}

fn listModules(arena: std.mem.Allocator, w: *std.Io.Writer, entries: []const Entry) !u8 {
    var seen: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (entries) |e| {
        const r = try seen.getOrPut(arena, e.module);
        if (!r.found_existing) r.value_ptr.* = 0;
        r.value_ptr.* += 1;
    }
    const keys = try arena.dupe([]const u8, seen.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    try w.writeAll("Standard library modules. `lus help MODULE` lists one, `lus help NAME` explains an entry.\n\n");
    for (keys) |k| try w.print("  {s: <24}{d} entries\n", .{ k, seen.get(k).? });
    return 0;
}

fn search(w: *std.Io.Writer, entries: []const Entry, text: []const u8) !u8 {
    var n: usize = 0;
    for (entries) |e| {
        if (std.ascii.findIgnoreCase(e.name, text) != null or std.ascii.findIgnoreCase(e.body, text) != null) {
            try writeLine(w, e);
            n += 1;
        }
    }
    if (n == 0) try w.print("nothing mentions '{s}'\n", .{text});
    return if (n == 0) 1 else 0;
}

fn writeLine(w: *std.Io.Writer, e: Entry) !void {
    try w.writeAll("  ");
    try writeSignature(w, e);
    try writeTags(w, e, " (", ")");
    const first = firstSentence(e.body);
    if (first.len > 0) try w.print("\n      {s}", .{first});
    try w.writeAll("\n");
}

fn writeEntry(w: *std.Io.Writer, e: Entry) !void {
    try writeSignature(w, e);
    try w.writeAll("\n");
    try writeTags(w, e, "", "\n");
    if (e.body.len > 0) try w.print("\n{s}\n", .{e.body});
}

pub fn writeSignature(w: *std.Io.Writer, e: Entry) !void {
    try w.writeAll(e.name);
    if (!std.mem.eql(u8, e.kind, "function")) return;
    try w.writeAll("(");
    for (e.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}{s}", .{ p.name, if (p.optional) "?" else "" });
    }
    if (e.vararg) try w.writeAll(if (e.params.len > 0) ", ..." else "...");
    try w.writeAll(")");
    if (e.returns.len > 0) try w.print(" -> {s}", .{e.returns});
}

fn writeTags(w: *std.Io.Writer, e: Entry, open: []const u8, close: []const u8) !void {
    const unstable = std.mem.eql(u8, e.stability, "unstable") or std.mem.eql(u8, e.stability, "deprecated");
    if (e.pledges.len == 0 and !unstable) return;
    try w.writeAll(open);
    if (e.pledges.len > 0) try w.print("needs {s}", .{e.pledges});
    if (unstable) try w.print("{s}{s}", .{ if (e.pledges.len > 0) ", " else "", e.stability });
    try w.writeAll(close);
}

fn firstSentence(body: []const u8) []const u8 {
    const para_end = std.mem.indexOf(u8, body, "\n\n") orelse body.len;
    const para = body[0..para_end];
    var i: usize = 0;
    while (i < para.len) : (i += 1) {
        if ((para[i] == '.' or para[i] == '?' or para[i] == '!') and (i + 1 == para.len or para[i + 1] == ' ' or para[i + 1] == '\n')) return para[0 .. i + 1];
    }
    return para;
}

// ---------------------------------------------------------------------
// Frontmatter

fn unquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

fn typeText(arena: std.mem.Allocator, t: []const u8) ![]const u8 {
    const u = unquote(t);
    if (std.mem.endsWith(u8, u, "|nil")) return std.fmt.allocPrint(arena, "{s}?", .{u[0 .. u.len - 4]});
    return u;
}

/// Reads the frontmatter fields `lus help` prints. The spec frontmatter
/// is a small YAML subset: `key: value` lines, and the lists `params` and
/// `returns` of `- name: x` items with indented fields below.
pub fn parse(arena: std.mem.Allocator, src: []const u8) !Entry {
    if (!std.mem.startsWith(u8, src, "---\n")) return error.NoFrontmatter;
    const end = std.mem.indexOfPos(u8, src, 4, "\n---") orelse return error.NoFrontmatter;
    const fm = src[4..end];
    var body = src[end + 4 ..];
    body = std.mem.trim(u8, body, " \t\r\n");

    var e: Entry = .{ .body = body };
    var params: std.ArrayList(Entry.Param) = .empty;
    var rets: std.ArrayList([]const u8) = .empty;
    const List = enum { none, params, returns, other };
    var list: List = .none;
    // The fields of the list item being read.
    var item_name: ?[]const u8 = null;
    var item_type: ?[]const u8 = null;
    var item_optional = false;

    const flush = struct {
        fn f(a: std.mem.Allocator, l: List, ps: *std.ArrayList(Entry.Param), rs: *std.ArrayList([]const u8), name: *?[]const u8, ty: *?[]const u8, opt: *bool) !void {
            switch (l) {
                .params => if (name.*) |n| try ps.append(a, .{ .name = n, .optional = opt.* }),
                .returns => if (ty.* != null or name.* != null) {
                    const t = try typeText(a, ty.* orelse "any");
                    try rs.append(a, if (name.*) |n| try std.fmt.allocPrint(a, "{s}: {s}", .{ n, t }) else t);
                },
                else => {},
            }
            name.* = null;
            ty.* = null;
            opt.* = false;
        }
    }.f;

    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const indented = line[0] == ' ';
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!indented) {
            try flush(arena, list, &params, &rets, &item_name, &item_type, &item_optional);
            list = .none;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.mem.eql(u8, key, "name")) {
                e.name = unquote(value);
            } else if (std.mem.eql(u8, key, "module")) {
                e.module = unquote(value);
            } else if (std.mem.eql(u8, key, "kind")) {
                e.kind = unquote(value);
            } else if (std.mem.eql(u8, key, "stability")) {
                e.stability = unquote(value);
            } else if (std.mem.eql(u8, key, "vararg")) {
                e.vararg = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "pledges")) {
                e.pledges = try flowList(arena, value);
            } else if (std.mem.eql(u8, key, "params")) {
                list = .params;
            } else if (std.mem.eql(u8, key, "returns")) {
                if (std.mem.eql(u8, value, "[]")) {
                    list = .other;
                } else if (value.len > 0) {
                    try rets.append(arena, try typeText(arena, value));
                    list = .other;
                } else list = .returns;
            } else {
                list = .other;
            }
            continue;
        }
        if (list != .params and list != .returns) continue;
        var field = trimmed;
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            // Only items directly under the list start a new entry.
            if (line.len - trimmed.len > 2) continue;
            try flush(arena, list, &params, &rets, &item_name, &item_type, &item_optional);
            field = trimmed[2..];
        } else if (line.len - trimmed.len > 4) continue;
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const key = field[0..colon];
        const value = std.mem.trim(u8, field[colon + 1 ..], " ");
        if (std.mem.eql(u8, key, "name")) {
            item_name = unquote(value);
        } else if (std.mem.eql(u8, key, "type")) {
            item_type = value;
        } else if (std.mem.eql(u8, key, "optional")) {
            item_optional = std.mem.eql(u8, value, "true");
        }
    }
    try flush(arena, list, &params, &rets, &item_name, &item_type, &item_optional);
    e.params = params.items;
    e.returns = try std.mem.join(arena, ", ", rets.items);
    return e;
}

/// `["a", "b"]` becomes `a, b`.
fn flowList(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    const inner = std.mem.trim(u8, value, "[] ");
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |p| {
        const u = unquote(p);
        if (u.len > 0) try parts.append(arena, u);
    }
    return std.mem.join(arena, ", ", parts.items);
}

test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parse(a,
        \\---
        \\name: string.find
        \\module: string
        \\kind: function
        \\stability: stable
        \\params:
        \\  - name: s
        \\    type: string
        \\  - name: init
        \\    type: integer
        \\    optional: true
        \\    flags: [exact]
        \\returns: integer|nil
        \\pledges: ["fs:read", "load"]
        \\---
        \\
        \\Finds a pattern. More text.
    );
    var buf: std.Io.Writer.Allocating = .init(a);
    try writeSignature(&buf.writer, e);
    try std.testing.expectEqualStrings("string.find(s, init?) -> integer?", buf.written());
    try std.testing.expectEqualStrings("fs:read, load", e.pledges);
    try std.testing.expectEqualStrings("Finds a pattern.", firstSentence(e.body));
}

test "every embedded entry parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (docs.stdlib) |f| {
        const e = try parse(arena.allocator(), f.data);
        try std.testing.expect(e.name.len > 0);
    }
}

test help {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);

    try std.testing.expectEqual(@as(u8, 0), try help(a, &out.writer, &.{"network.serve"}));
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "network.serve(host, port, handler)\nneeds network:server, network:tcp\n"));

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try help(a, &out.writer, &.{"fs.path"}));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  fs.path.join(...) -> string\n") != null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try help(a, &out.writer, &.{"serve"}));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "network.serve") != null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try help(a, &out.writer, &.{}));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  string ") != null);
}
