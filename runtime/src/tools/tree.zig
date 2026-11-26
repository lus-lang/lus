//! `lus tree`: prints the require tree of a program.
//!
//! Usage: lus tree [--json] FILE
//!
//! The tree starts at FILE and follows its literal requires, the calls of
//! `require` whose argument is one string constant (`modtree.scan`). Each
//! name resolves against the templates of `LUS_PATH`, or of the default
//! `package.path` when `LUS_PATH` is unset, relative to the current
//! directory, as `require` and `lus build` resolve it. A module of the standard library, a remote module, a name
//! that resolves to no file, and a file that does not parse end their
//! branch. A module that the tree already showed with its requires is
//! marked `(*)` and not expanded again, which also ends every cycle. A
//! chunk that also loads modules in a way the scan cannot follow, such as
//! `require(name)` or `load`, is marked `(dynamic)`.
//!
//! Each line names the module, then the file it resolved to in
//! parentheses. `--json` prints the tree as one object per module, with
//! `name`, `kind` (`file`, `builtin`, `remote`, `missing`, or `invalid`),
//! `path` for a file, `dynamic`, `repeat`, and `requires`.
//!
//! The exit status is 0 when every literal require resolves and every
//! file parses, 1 otherwise, and 2 for a usage problem or an unreadable
//! FILE.

const std = @import("std");
const modtree = @import("../modtree.zig");
const package = @import("../lib/package.zig");
const remote = @import("../remote.zig");
const Allocator = std.mem.Allocator;

const usage = @import("usage.zig").of("tree");

pub const Kind = enum { file, builtin, remote, missing, invalid };

pub const Node = struct {
    name: []const u8,
    kind: Kind,
    path: ?[]const u8 = null,
    dynamic: bool = false,
    /// Shown with its requires earlier in the tree.
    repeat: bool = false,
    requires: []Node = &.{},
};

const Builder = struct {
    arena: Allocator,
    io: std.Io,
    templates: []const u8,
    /// Paths already expanded.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    ok: bool = true,

    fn resolve(b: *Builder, name: []const u8) !?[]const u8 {
        const mod = try std.mem.replaceOwned(u8, b.arena, name, ".", std.fs.path.sep_str);
        var it = std.mem.splitScalar(u8, b.templates, ';');
        while (it.next()) |tmpl| {
            if (tmpl.len == 0) continue;
            const candidate = try std.mem.replaceOwned(u8, b.arena, tmpl, "?", mod);
            if (std.Io.Dir.cwd().statFile(b.io, candidate, .{})) |st| {
                if (st.kind != .directory) return candidate;
            } else |_| {}
        }
        return null;
    }

    /// Builds the node of the chunk in `path`, named `name`.
    fn file(b: *Builder, name: []const u8, path: []const u8) anyerror!Node {
        var node: Node = .{ .name = name, .kind = .file, .path = path };
        if (b.seen.contains(path)) {
            node.repeat = true;
            return node;
        }
        try b.seen.put(b.arena, path, {});
        const src = std.Io.Dir.cwd().readFileAlloc(b.io, path, b.arena, .unlimited) catch {
            b.ok = false;
            node.kind = .missing;
            return node;
        };
        const sc = (try modtree.scan(b.arena, b.arena, src, path)) orelse {
            b.ok = false;
            node.kind = .invalid;
            return node;
        };
        node.dynamic = sc.dynamic;
        var kids: std.ArrayList(Node) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (sc.literal) |lit| {
            if ((try names.getOrPut(b.arena, lit)).found_existing) continue;
            try kids.append(b.arena, try b.module(lit));
        }
        node.requires = kids.items;
        return node;
    }

    fn module(b: *Builder, name: []const u8) !Node {
        if (remote.isUrl(name)) return .{ .name = name, .kind = .remote };
        if (package.answeredEarly(name)) return .{ .name = name, .kind = .builtin };
        const path = try b.resolve(name) orelse {
            b.ok = false;
            return .{ .name = name, .kind = .missing };
        };
        return b.file(name, path);
    }
};

/// Builds the tree of the program in `path`. `ok` reports whether every
/// literal require resolved and every file parsed.
pub fn build(arena: Allocator, io: std.Io, path: []const u8, templates: []const u8, ok: *bool) !Node {
    var b: Builder = .{ .arena = arena, .io = io, .templates = templates };
    const root = try b.file(path, path);
    ok.* = b.ok and root.kind == .file;
    return root;
}

fn note(n: Node) []const u8 {
    return switch (n.kind) {
        .file => "",
        .builtin => " (standard library)",
        .remote => " (remote)",
        .missing => " (not found)",
        .invalid => " (does not parse)",
    };
}

/// A path as the tree shows it: with `/` between its parts on every
/// system, so the output reads the same on Windows, where `require` joins
/// the parts of a dotted name with `\`. Elsewhere a backslash is part of a
/// file name and stays.
pub fn shown(arena: Allocator, path: []const u8, windows: bool) ![]const u8 {
    if (!windows or std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const copy = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

const is_windows = @import("builtin").os.tag == .windows;

fn writeLine(arena: Allocator, w: *std.Io.Writer, n: Node, top: bool) !void {
    try w.writeAll(try shown(arena, n.name, is_windows));
    if (n.path) |p| if (!top and n.kind != .missing) try w.print(" ({s})", .{try shown(arena, p, is_windows)});
    try w.writeAll(note(n));
    if (n.dynamic) try w.writeAll(" (dynamic)");
    if (n.repeat and n.kind == .file) try w.writeAll(" (*)");
    try w.writeAll("\n");
}

fn writeKids(w: *std.Io.Writer, n: Node, prefix: *std.ArrayList(u8), arena: Allocator) !void {
    for (n.requires, 0..) |kid, i| {
        const last = i + 1 == n.requires.len;
        try w.print("{s}{s}", .{ prefix.items, if (last) "└── " else "├── " });
        try writeLine(arena, w, kid, false);
        const len = prefix.items.len;
        try prefix.appendSlice(arena, if (last) "    " else "│   ");
        try writeKids(w, kid, prefix, arena);
        prefix.shrinkRetainingCapacity(len);
    }
}

pub fn writeText(arena: Allocator, w: *std.Io.Writer, root: Node) !void {
    try writeLine(arena, w, root, true);
    var prefix: std.ArrayList(u8) = .empty;
    try writeKids(w, root, &prefix, arena);
}

pub fn writeJson(arena: Allocator, w: *std.Io.Writer, n: Node) !void {
    try w.writeAll("{\"name\": ");
    try std.json.Stringify.encodeJsonString(try shown(arena, n.name, is_windows), .{}, w);
    try w.print(", \"kind\": \"{s}\"", .{@tagName(n.kind)});
    if (n.path) |p| {
        try w.writeAll(", \"path\": ");
        try std.json.Stringify.encodeJsonString(try shown(arena, p, is_windows), .{}, w);
    }
    try w.print(", \"dynamic\": {}, \"repeat\": {}, \"requires\": [", .{ n.dynamic, n.repeat });
    for (n.requires, 0..) |kid, i| {
        if (i > 0) try w.writeAll(", ");
        try writeJson(arena, w, kid);
    }
    try w.writeAll("]}");
}

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    var json = false;
    var file: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.Io.File.stdout().writeStreamingAll(init.io, usage) catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if ((a.len > 1 and a[0] == '-') or file != null) {
            std.debug.print("{s}", .{usage});
            return 2;
        } else file = a;
    }
    const path = file orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        std.debug.print("lus tree: cannot open {s}\n", .{path});
        return 2;
    };
    const templates = init.environ_map.get("LUS_PATH") orelse package.default_path;
    var ok = true;
    const root = try build(arena, io, path, templates, &ok);

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    if (json) {
        try writeJson(arena, &out.writer, root);
        try out.writer.writeAll("\n");
    } else try writeText(arena, &out.writer, root);
    std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    return if (ok) 0 else 1;
}

test "tree follows literal requires and marks repeats, builtins, and missing names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app/util");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/main.lus", .data = "local a = require(\"a\")\nlocal b = require(\"util.b\")\nlocal s = require(\"string\")\nrequire(\"a\")\nrequire(\"gone\")\nrequire(\"https://example.com/x.lus\")\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/a.lus", .data = "return require(\"util.b\")\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/util/b.lus", .data = "local m = require(name)\nreturn require(\"a\")\n" });

    const base = try tmp.dir.realPathFileAlloc(io, "app", a);
    const tmpl = try std.fmt.allocPrint(a, "{s}/?.lus", .{base});
    const main_path = try std.fmt.allocPrint(a, "{s}/main.lus", .{base});
    var ok = true;
    const root = try build(a, io, main_path, tmpl, &ok);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 5), root.requires.len);
    try std.testing.expectEqual(Kind.file, root.requires[0].kind);
    const b = root.requires[0].requires[0];
    try std.testing.expectEqualStrings("util.b", b.name);
    try std.testing.expect(b.dynamic);
    try std.testing.expect(b.requires[0].repeat);
    try std.testing.expect(root.requires[1].repeat);
    try std.testing.expectEqual(Kind.builtin, root.requires[2].kind);
    try std.testing.expectEqual(Kind.missing, root.requires[3].kind);
    try std.testing.expectEqual(Kind.remote, root.requires[4].kind);

    var out: std.Io.Writer.Allocating = .init(a);
    try writeText(a, &out.writer, root);
    // The real path of the directory is the one the tree shows, which on
    // Windows has a drive letter and `/` in place of `\\`.
    const text = try std.mem.replaceOwned(u8, a, out.written(), try shown(a, base, is_windows), "D");
    try std.testing.expectEqualStrings(
        \\D/main.lus
        \\├── a (D/a.lus)
        \\│   └── util.b (D/util/b.lus) (dynamic)
        \\│       └── a (D/a.lus) (*)
        \\├── util.b (D/util/b.lus) (*)
        \\├── string (standard library)
        \\├── gone (not found)
        \\└── https://example.com/x.lus (remote)
        \\
    , text);
}

test shown {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // What `resolve` builds on Windows for `util.b` from a template with
    // a drive letter and forward slashes.
    try std.testing.expectEqualStrings("C:/w/app/util/b.lus", try shown(a, "C:/w/app/util\\b.lus", true));
    try std.testing.expectEqualStrings("C:/w/app/a.lus", try shown(a, "C:\\w\\app\\a.lus", true));
    // Elsewhere a backslash belongs to the file name.
    try std.testing.expectEqualStrings("odd\\name.lus", try shown(a, "odd\\name.lus", false));
}
