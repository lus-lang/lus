//! `lus doc`: generates API documentation from doc comments.
//!
//! Usage: lus doc [-o DIR] [--format md|json] FILE...
//!
//! Each file is one module, named after the file without its extension.
//! The documented entries are the top-level declarations: local, global,
//! and field functions, locals and globals, and the fields of the table a
//! module returns. A declaration has a doc comment when a `---` comment
//! (or a `--[[- ... ]]` comment) ends on the line above it, as described
//! in `syntax/doccomment.zig`. Functions stored in the returned table and
//! global functions are public API, so they are listed even without a doc
//! comment. Other declarations are listed only when documented.
//!
//! The Markdown output starts with the module frontmatter and has one
//! section per entry. The JSON output is a model whose entries carry the
//! fields of the `spec/stdlib` frontmatter (`name`, `module`, `kind`,
//! `params`, `vararg`, `returns`, `since`, `stability`, `receiver`) plus
//! `description`, `line`, and per-parameter descriptions, so the website
//! and the specification tools can consume it. Without `-o` the output
//! goes to standard output. With `-o DIR` each module is written to
//! `DIR/MODULE.md` or `DIR/MODULE.json`.
//!
//! The exit status is 0 on success, 1 when a file does not parse, and 2
//! for a usage or I/O problem.

const std = @import("std");
const lus = @import("../lus.zig");
const doccomment = @import("../syntax/doccomment.zig");
const astexport = @import("../syntax/astexport.zig");
const ast = lus.syntax.ast;
const parser = lus.syntax.parser;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: lus doc [-o DIR] [--format md|json] FILE...
    \\
    \\  -o DIR             write one file per module into DIR
    \\  --format md|json   output format (default md)
    \\
;

const Format = enum { md, json };

pub const Param = struct {
    name: []const u8,
    type: []const u8 = "any",
    optional: bool = false,
    description: []const u8 = "",
    /// The named variable arguments of `...name`.
    rest: bool = false,
};

pub const Entry = struct {
    name: []const u8,
    kind: []const u8,
    receiver: ?[]const u8 = null,
    params: []Param = &.{},
    vararg: bool = false,
    returns: []doccomment.Return = &.{},
    since: ?[]const u8 = null,
    stability: ?[]const u8 = null,
    description: []const u8 = "",
    line: u32,
    is_function: bool = false,
};

pub const Module = struct {
    name: []const u8,
    description: []const u8 = "",
    since: ?[]const u8 = null,
    stability: ?[]const u8 = null,
    entries: []Entry,
};

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var out_dir: ?[]const u8 = null;
    var format: Format = .md;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("lus doc: '-o' needs a directory\n{s}", .{usage});
                return 2;
            }
            out_dir = args[i];
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            const f = if (i < args.len) args[i] else "";
            format = std.meta.stringToEnum(Format, f) orelse {
                std.debug.print("lus doc: '--format' takes md or json\n{s}", .{usage});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus doc: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        } else {
            try files.append(gpa, a);
        }
    }
    if (files.items.len == 0) {
        std.debug.print("{s}", .{usage});
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (out_dir) |d| std.Io.Dir.cwd().createDirPath(io, d) catch |e| {
        std.debug.print("lus doc: cannot create {s} ({s})\n", .{ d, @errorName(e) });
        return 2;
    };

    var status: u8 = 0;
    var stdout: std.Io.Writer.Allocating = .init(gpa);
    defer stdout.deinit();
    for (files.items) |file| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited) catch |e| {
            std.debug.print("lus doc: cannot read {s} ({s})\n", .{ file, @errorName(e) });
            status = 2;
            continue;
        };
        var diag: ?[]const u8 = null;
        const chunkname = try std.fmt.allocPrint(arena, "@{s}", .{file});
        const chunk = parser.parse(gpa, arena, src, .{ .chunkname = chunkname }, &diag) catch |e| switch (e) {
            error.SyntaxError => {
                std.debug.print("lus doc: {s}\n", .{diag.?});
                if (status == 0) status = 1;
                continue;
            },
            else => return e,
        };
        const module = try extract(arena, chunk, moduleName(file));
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        (switch (format) {
            .md => writeMarkdown(&buf.writer, module),
            .json => writeJson(&buf.writer, module),
        }) catch return error.OutOfMemory;
        if (out_dir) |d| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}.{s}", .{ d, module.name, @tagName(format) });
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.written() }) catch |e| {
                std.debug.print("lus doc: cannot write {s} ({s})\n", .{ path, @errorName(e) });
                status = 2;
            };
        } else {
            if (stdout.written().len > 0 and format == .md) stdout.writer.writeAll("\n") catch return error.OutOfMemory;
            stdout.writer.writeAll(buf.written()) catch return error.OutOfMemory;
        }
    }
    std.Io.File.stdout().writeStreamingAll(io, stdout.written()) catch {};
    return status;
}

fn moduleName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
}

// ---------------------------------------------------------------------
// Extraction

const Extractor = struct {
    arena: Allocator,
    docs: doccomment.Index,
    module: []const u8,
    /// Name of the local table the chunk returns, if any.
    exported: ?[]const u8,
    /// Names of the top-level locals.
    locals: std.StringHashMapUnmanaged(void) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    module_doc: ?doccomment.Doc = null,

    fn qualify(x: *Extractor, head: []const u8) []const u8 {
        if (x.exported) |e| if (std.mem.eql(u8, e, head)) return x.module;
        return head;
    }

    fn isPublicHead(x: *Extractor, head: []const u8) bool {
        if (x.exported) |e| if (std.mem.eql(u8, e, head)) return true;
        return !x.locals.contains(head);
    }

    fn add(x: *Extractor, name: []const u8, line: u32, doc: ?doccomment.Doc, value: ?*ast.Expr, constant: bool, receiver: ?[]const u8) Allocator.Error!void {
        var e: Entry = .{ .name = name, .kind = if (constant) "constant" else "variable", .line = line, .receiver = receiver };
        if (doc) |d| {
            e.description = d.text;
            e.since = d.since;
            e.stability = d.stability;
            e.returns = d.returns;
        }
        if (value) |v| if (v.kind == .function) {
            const f = v.kind.function;
            e.kind = "function";
            e.is_function = true;
            e.vararg = f.is_vararg;
            var params: std.ArrayList(Param) = .empty;
            const all = if (f.vararg_name) |vn| try std.mem.concat(x.arena, ast.Name, &.{ f.params, &.{vn} }) else f.params;
            for (all, 0..) |p, pi| {
                var param: Param = .{ .name = p.text, .rest = pi == f.params.len };
                if (doc) |d| if (d.param(p.text)) |dp| {
                    if (dp.type) |t| param.type = t;
                    param.optional = dp.optional;
                    param.description = dp.description;
                };
                try params.append(x.arena, param);
            }
            if (f.is_vararg and f.vararg_name == null) {
                if (doc) |d| if (d.param("...")) |dp| {
                    try params.append(x.arena, .{ .name = "...", .type = dp.type orelse "any", .optional = true, .description = dp.description });
                };
            }
            e.params = params.items;
        };
        try x.entries.append(x.arena, e);
    }

    fn stat(x: *Extractor, s: *ast.Stat) Allocator.Error!void {
        const doc = try x.docs.before(x.arena, s.line);
        switch (s.kind) {
            .local_function => |f| if (doc != null) {
                try x.add(f.name.text, s.line, doc, try x.fnExpr(f.func), false, null);
            },
            .global_function => |f| try x.add(f.name.text, s.line, doc, try x.fnExpr(f.func), false, null),
            .function => |f| {
                const head = f.path[0].text;
                if (doc == null and !x.isPublicHead(head)) return;
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(x.arena, x.qualify(head));
                for (f.path[1..]) |p| {
                    try name.append(x.arena, '.');
                    try name.appendSlice(x.arena, p.text);
                }
                var receiver: ?[]const u8 = null;
                if (f.method) |m| {
                    receiver = try x.arena.dupe(u8, name.items);
                    try name.append(x.arena, ':');
                    try name.appendSlice(x.arena, m.text);
                }
                try x.add(name.items, s.line, doc, try x.fnExpr(f.func), false, receiver);
            },
            .local => |l| {
                for (l.names, 0..) |n, i| {
                    const value = if (i < l.values.len) l.values[i] else null;
                    if (x.exported != null and std.mem.eql(u8, x.exported.?, n.name.text)) {
                        if (doc != null and x.module_doc == null) x.module_doc = doc;
                        if (value) |v| if (v.kind == .table) try x.fields(v.kind.table);
                        continue;
                    }
                    if (doc != null and l.names.len == 1) try x.add(n.name.text, s.line, doc, value, n.has(.@"const"), null);
                }
            },
            .global => |g| if (doc != null and g.names.len == 1 and !g.star) {
                const value = if (g.values) |v| (if (v.len > 0) v[0] else null) else null;
                var constant = g.names[0].has(.@"const");
                for (g.default_attribs) |a| if (a == .@"const") {
                    constant = true;
                };
                try x.add(g.names[0].name.text, s.line, doc, value, constant, null);
            },
            .assign => |a| if (a.targets.len == 1 and a.values.len == 1) {
                const path = (try x.fieldPath(a.targets[0])) orelse return;
                const head = path[0];
                const value = a.values[0];
                const exported = x.exported != null and std.mem.eql(u8, x.exported.?, head);
                if (path.len == 1) {
                    if (doc != null) try x.add(head, s.line, doc, value, false, null);
                    return;
                }
                if (doc == null and !(exported and value.kind == .function)) return;
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(x.arena, x.qualify(head));
                for (path[1..]) |p| {
                    try name.append(x.arena, '.');
                    try name.appendSlice(x.arena, p);
                }
                try x.add(name.items, s.line, doc, value, false, null);
            },
            else => {},
        }
    }

    fn fnExpr(x: *Extractor, f: *ast.Function) Allocator.Error!*ast.Expr {
        const e = try x.arena.create(ast.Expr);
        e.* = .{ .span = f.span, .line = f.line, .kind = .{ .function = f } };
        return e;
    }

    /// `a.b.c` as a list of names, or null for any other target.
    fn fieldPath(x: *Extractor, e: *ast.Expr) Allocator.Error!?[]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        var cur = e;
        while (true) switch (cur.kind) {
            .name => |n| {
                try parts.append(x.arena, n.text);
                break;
            },
            .index => |ix| {
                if (!ix.dot or ix.key.kind != .string) return null;
                try parts.append(x.arena, ix.key.kind.string);
                cur = ix.obj;
            },
            else => return null,
        };
        std.mem.reverse([]const u8, parts.items);
        return parts.items;
    }

    /// Named fields of the exported table constructor.
    fn fields(x: *Extractor, list: []ast.Field) Allocator.Error!void {
        for (list) |f| switch (f.kind) {
            .named => |n| {
                const line = lineOf(x.docs.src, n.name.span.start);
                const doc = try x.docs.before(x.arena, line);
                if (doc == null and n.value.kind != .function) continue;
                const name = try std.fmt.allocPrint(x.arena, "{s}.{s}", .{ x.module, n.name.text });
                try x.add(name, line, doc, n.value, false, null);
            },
            else => {},
        };
    }
};

fn lineOf(src: []const u8, offset: u32) u32 {
    return 1 + @as(u32, @intCast(std.mem.count(u8, src[0..@min(offset, src.len)], "\n")));
}

/// Builds the documentation model of one chunk.
pub fn extract(arena: Allocator, chunk: ast.Chunk, module: []const u8) Allocator.Error!Module {
    const stats = chunk.block.stats;
    var exported: ?[]const u8 = null;
    if (stats.len > 0) switch (stats[stats.len - 1].kind) {
        .return_ => |vals| if (vals.len == 1 and vals[0].kind == .name) {
            exported = vals[0].kind.name.text;
        },
        else => {},
    };
    var x: Extractor = .{ .arena = arena, .docs = doccomment.Index.init(chunk), .module = module, .exported = exported };
    for (stats) |s| switch (s.kind) {
        .local => |l| for (l.names) |n| try x.locals.put(arena, n.name.text, {}),
        .local_function => |f| try x.locals.put(arena, f.name.text, {}),
        else => {},
    };
    const mdoc = try x.docs.moduleDoc(arena);
    for (stats) |s| {
        // The module comment does not also document the first statement.
        if (mdoc) |m| if (s.line == m.end_line + 1) continue;
        try x.stat(s);
    }
    const md = mdoc orelse x.module_doc;
    return .{
        .name = module,
        .description = if (md) |d| d.text else "",
        .since = if (md) |d| d.since else null,
        .stability = if (md) |d| d.stability else null,
        .entries = x.entries.items,
    };
}

// ---------------------------------------------------------------------
// Output

fn writeMarkdown(w: *std.Io.Writer, m: Module) std.Io.Writer.Error!void {
    try w.print("---\nname: {s}\nkind: module\n", .{m.name});
    if (m.since) |s| try w.print("since: {s}\n", .{s});
    if (m.stability) |s| try w.print("stability: {s}\n", .{s});
    try w.writeAll("---\n\n");
    try w.print("# {s}\n", .{m.name});
    if (m.description.len > 0) try w.print("\n{s}\n", .{m.description});
    for (m.entries) |e| {
        try w.print("\n## {s}\n", .{e.name});
        if (e.is_function) {
            try w.print("\n```lus\nfunction {s}(", .{e.name});
            for (e.params, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                if (p.rest) try w.writeAll("...");
                try w.writeAll(p.name);
            }
            const last_is_vararg = e.params.len > 0 and (e.params[e.params.len - 1].rest or std.mem.eql(u8, e.params[e.params.len - 1].name, "..."));
            if (e.vararg and !last_is_vararg) {
                try w.writeAll(if (e.params.len > 0) ", ..." else "...");
            }
            try w.writeAll(")\n```\n");
        } else {
            try w.print("\n*{s}*\n", .{if (std.mem.eql(u8, e.kind, "constant")) "Constant" else "Variable"});
        }
        if (e.description.len > 0) try w.print("\n{s}\n", .{e.description});
        if (e.params.len > 0) {
            try w.writeAll("\n**Parameters**\n\n");
            for (e.params) |p| {
                try w.print("- `{s}{s}` (`{s}`{s})", .{ if (p.rest) "..." else "", p.name, p.type, if (p.optional) ", optional" else "" });
                if (p.description.len > 0) try w.print(": {s}", .{p.description});
                try w.writeAll("\n");
            }
        }
        if (e.returns.len > 0) {
            try w.writeAll("\n**Returns**\n\n");
            for (e.returns) |r| {
                try w.print("- `{s}`", .{r.type});
                if (r.description.len > 0) try w.print(": {s}", .{r.description});
                try w.writeAll("\n");
            }
        }
        if (e.since != null or e.stability != null) {
            try w.writeAll("\n");
            if (e.since) |s| try w.print("*Since {s}.*", .{s});
            if (e.since != null and e.stability != null) try w.writeAll(" ");
            if (e.stability) |s| try w.print("*Stability: {s}.*", .{s});
            try w.writeAll("\n");
        }
    }
}

fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try astexport.jsonString(w, s);
}

fn writeJson(w: *std.Io.Writer, m: Module) std.Io.Writer.Error!void {
    try w.writeAll("{\n  \"name\": ");
    try str(w, m.name);
    try w.writeAll(",\n  \"kind\": \"module\"");
    if (m.since) |s| {
        try w.writeAll(",\n  \"since\": ");
        try str(w, s);
    }
    if (m.stability) |s| {
        try w.writeAll(",\n  \"stability\": ");
        try str(w, s);
    }
    try w.writeAll(",\n  \"description\": ");
    try str(w, m.description);
    try w.writeAll(",\n  \"entries\": [");
    for (m.entries, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n    {" else ",\n    {");
        try w.writeAll("\"name\": ");
        try str(w, e.name);
        try w.writeAll(", \"module\": ");
        try str(w, m.name);
        try w.print(", \"kind\": \"{s}\"", .{e.kind});
        if (e.receiver) |r| {
            try w.writeAll(", \"receiver\": ");
            try str(w, r);
        }
        if (e.since) |s| {
            try w.writeAll(", \"since\": ");
            try str(w, s);
        }
        if (e.stability) |s| {
            try w.writeAll(", \"stability\": ");
            try str(w, s);
        }
        if (e.is_function) {
            try w.writeAll(", \"params\": [");
            for (e.params, 0..) |p, j| {
                if (j > 0) try w.writeAll(", ");
                try w.writeAll("{\"name\": ");
                try str(w, p.name);
                try w.writeAll(", \"type\": ");
                try str(w, p.type);
                if (p.optional) try w.writeAll(", \"optional\": true");
                if (p.rest) try w.writeAll(", \"rest\": true");
                if (p.description.len > 0) {
                    try w.writeAll(", \"description\": ");
                    try str(w, p.description);
                }
                try w.writeAll("}");
            }
            try w.writeAll("]");
            if (e.vararg) try w.writeAll(", \"vararg\": true");
            try w.writeAll(", \"returns\": [");
            for (e.returns, 0..) |r, j| {
                if (j > 0) try w.writeAll(", ");
                try w.writeAll("{\"type\": ");
                try str(w, r.type);
                if (r.description.len > 0) {
                    try w.writeAll(", \"description\": ");
                    try str(w, r.description);
                }
                try w.writeAll("}");
            }
            try w.writeAll("]");
        }
        try w.print(", \"line\": {d}, \"description\": ", .{e.line});
        try str(w, e.description);
        try w.writeAll("}");
    }
    try w.writeAll(if (m.entries.len == 0) "]\n}\n" else "\n  ]\n}\n");
}
