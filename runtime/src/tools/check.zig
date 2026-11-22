//! `lus check`: reports errors and lint warnings without running code.
//!
//! Usage: lus check [--json] [--list] [FILE...]
//!
//! Every file is parsed, linted (`syntax/lint.zig`), and compiled. Each
//! problem is printed as `file:line:column: severity: message [code]`.
//! With `--json` the output is one JSON array of objects with the fields
//! `file`, `line`, `column`, `endLine`, `endColumn`, `severity`, `code`,
//! and `message`, so editors and the language server can read it.
//! `--list` prints every diagnostic code with its severity and summary.
//!
//! A directory argument stands for every `.lus` file below it. A file
//! whose name ends in `_test.lus` is checked as a test file: the helpers
//! of `lus test` count as defined and the tests and case tables it
//! declares count as used.
//!
//! With no file, or with the file `-`, the source is read from standard
//! input. The exit status is 0 when nothing is reported, 1 when a
//! diagnostic is reported, and 2 for a usage or I/O problem.

const std = @import("std");
const lus = @import("../lus.zig");
const lint = @import("../syntax/lint.zig");
const paths = @import("paths.zig");
const astexport = @import("../syntax/astexport.zig");
const lexer = lus.syntax.lexer;
const parser = lus.syntax.parser;
const ast = lus.syntax.ast;
const api = lus.api;
const codegen = lus.compile.codegen;
const object = lus.vm.object;
const table = lus.vm.table;

const usage =
    \\usage: lus check [--json] [--list] [FILE...]
    \\
    \\  --json  print the diagnostics as a JSON array
    \\  --list  print every diagnostic code and exit
    \\
    \\A directory stands for every .lus file below it. With no FILE, or
    \\when FILE is -, read standard input.
    \\
;

/// The globals `lus test` defines in a test file.
pub const test_globals = [_][]const u8{ "raises", "same", "skip", "snapshot", "TEST_DIR" };

const Entry = struct {
    file: []const u8,
    d: lint.Diagnostic,
};

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var json = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            return listCodes(gpa, io);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus check: unknown option '{s}'\n{s}", .{ a, usage });
            return 2;
        } else {
            try files.append(gpa, a);
        }
    }
    if (files.items.len == 0) try files.append(gpa, "-");

    // The runtime state backs the compiler pass and names the globals
    // the standard library defines.
    const l = try api.newState(gpa, io);
    defer api.close(l);
    try api.openLibs(l);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var builtins = try globalNames(arena, l.g);
    var test_builtins = try builtins.clone(arena);
    // The `lus` command defines `arg` for the script it runs.
    try builtins.put(arena, "arg", {});
    for (test_globals) |name| try test_builtins.put(arena, name, {});

    var expanded: std.ArrayList([]const u8) = .empty;
    for (files.items) |file| try paths.expand(arena, io, file, &expanded);

    var entries: std.ArrayList(Entry) = .empty;
    var status: u8 = 0;
    for (expanded.items) |file| {
        const from_stdin = std.mem.eql(u8, file, "-");
        const src = readSource(arena, io, file, from_stdin) catch |e| {
            std.debug.print("lus check: cannot read {s} ({s})\n", .{ file, @errorName(e) });
            status = 2;
            continue;
        };
        const display = if (from_stdin) "<stdin>" else file;
        const chunkname = if (from_stdin) "=stdin" else try std.fmt.allocPrint(arena, "@{s}", .{file});
        const is_test = !from_stdin and paths.isTestFile(file);
        const opts: lint.Options = .{ .builtins = if (is_test) &test_builtins else &builtins, .test_file = is_test };
        for (try checkSource(gpa, arena, l.g, src, chunkname, opts)) |d| {
            try entries.append(arena, .{ .file = display, .d = d });
        }
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    if (json) {
        writeJson(w, entries.items) catch return error.OutOfMemory;
    } else {
        for (entries.items) |e| {
            w.print("{s}:{d}:{d}: {s}: {s} [{s}]\n", .{ e.file, e.d.line, e.d.column, e.d.severity.label(), e.d.message, e.d.code }) catch return error.OutOfMemory;
        }
    }
    std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    if (entries.items.len > 0 and status == 0) status = 1;
    return status;
}

/// Parses, lints, and compiles one source. A syntax error stops the
/// file. Otherwise the lint results come first and the compiler adds
/// the error it found, unless a lint error already covers its line.
pub fn checkSource(gpa: std.mem.Allocator, arena: std.mem.Allocator, g: *lus.vm.state.Global, src: []const u8, chunkname: []const u8, opts: lint.Options) ![]lint.Diagnostic {
    var lx = lexer.Lexer.init(gpa, arena, src);
    defer lx.deinit();
    const lexed = lx.run() catch |e| switch (e) {
        error.SyntaxError => {
            const d = lx.diag.?;
            return syntaxError(arena, src, d.span, d.message);
        },
        else => return e,
    };
    var partial: parser.Partial = .{};
    const chunk = parser.parseLexed(arena, src, lexed, .{ .chunkname = chunkname }, false, &partial) catch |e| switch (e) {
        error.SyntaxError => {
            const d = partial.diag.?;
            return syntaxError(arena, src, d.span, stripPosition(d.message));
        },
        else => return e,
    };
    var list: std.ArrayList(lint.Diagnostic) = .empty;
    try list.appendSlice(arena, try lint.lint(arena, chunk, opts));

    const r = try codegen.compileAst(g, arena, chunk, .{ .chunkname = chunkname, .meta_eval = false });
    switch (r) {
        .ok => {},
        .err => |m| {
            defer g.gpa.free(m);
            const line = messageLine(m) orelse 1;
            var covered = false;
            for (list.items) |d| {
                if (d.severity == .@"error" and d.line == line) covered = true;
            }
            if (!covered) {
                const off = lineStart(src, line);
                var d: lint.Diagnostic = .{
                    .span = .{ .start = off, .end = off },
                    .severity = .@"error",
                    .code = "compile",
                    .message = try arena.dupe(u8, stripPosition(m)),
                };
                lint.locate(src, (&d)[0..1]);
                try list.append(arena, d);
                std.mem.sort(lint.Diagnostic, list.items, {}, struct {
                    fn lt(_: void, a: lint.Diagnostic, b: lint.Diagnostic) bool {
                        return a.span.start < b.span.start;
                    }
                }.lt);
            }
        },
    }
    return list.items;
}

fn syntaxError(arena: std.mem.Allocator, src: []const u8, span: ast.Span, message: []const u8) ![]lint.Diagnostic {
    const list = try arena.alloc(lint.Diagnostic, 1);
    list[0] = .{ .span = span, .severity = .@"error", .code = "syntax", .message = try arena.dupe(u8, message) };
    lint.locate(src, list);
    return list;
}

/// Removes the "chunk:line: " prefix of a compiler or parser message.
fn stripPosition(m: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, m, i, ':')) |c| {
        var j = c + 1;
        while (j < m.len and std.ascii.isDigit(m[j])) j += 1;
        if (j > c + 1 and j + 1 < m.len and m[j] == ':' and m[j + 1] == ' ') return m[j + 2 ..];
        i = c + 1;
    }
    return m;
}

fn messageLine(m: []const u8) ?u32 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, m, i, ':')) |c| {
        var j = c + 1;
        while (j < m.len and std.ascii.isDigit(m[j])) j += 1;
        if (j > c + 1 and j < m.len and m[j] == ':') return std.fmt.parseInt(u32, m[c + 1 .. j], 10) catch null;
        i = c + 1;
    }
    return null;
}

fn lineStart(src: []const u8, line: u32) u32 {
    var cur: u32 = 1;
    for (src, 0..) |c, i| {
        if (cur == line) return @intCast(i);
        if (c == '\n') cur += 1;
    }
    return @intCast(src.len);
}

/// The string keys of the global table.
pub fn globalNames(arena: std.mem.Allocator, g: *lus.vm.state.Global) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    const t = g.globals.as(object.Table);
    var key: lus.vm.value.Value = .nil;
    while (table.next(t, key) catch null) |e| : (key = e.key) {
        if (e.key.tag == .string) try set.put(arena, try arena.dupe(u8, e.key.as(object.String).bytes()), {});
    }
    return set;
}

fn writeJson(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (entries, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n  {" else ",\n  {");
        try w.writeAll("\"file\": ");
        try astexport.jsonString(w, e.file);
        try w.print(", \"line\": {d}, \"column\": {d}, \"endLine\": {d}, \"endColumn\": {d}, \"severity\": \"{s}\", \"code\": \"{s}\", \"message\": ", .{ e.d.line, e.d.column, e.d.end_line, e.d.end_column, e.d.severity.label(), e.d.code });
        try astexport.jsonString(w, e.d.message);
        try w.writeAll("}");
    }
    try w.writeAll(if (entries.len == 0) "]\n" else "\n]\n");
}

fn listCodes(gpa: std.mem.Allocator, io: std.Io) !u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (lint.codes) |c| {
        out.writer.print("{s: <24}{s: <9}{s}\n", .{ c.code, c.severity.label(), c.summary }) catch return error.OutOfMemory;
    }
    out.writer.print("{s: <24}{s: <9}{s}\n", .{ "syntax", "error", "The file does not parse." }) catch return error.OutOfMemory;
    out.writer.print("{s: <24}{s: <9}{s}\n", .{ "compile", "error", "The compiler rejects the file for another reason." }) catch return error.OutOfMemory;
    std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    return 0;
}

fn readSource(arena: std.mem.Allocator, io: std.Io, file: []const u8, from_stdin: bool) ![]u8 {
    if (!from_stdin) return std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited);
    var buf: std.ArrayList(u8) = .empty;
    var rbuf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
    try r.interface.appendRemainingUnlimited(arena, &buf);
    return buf.items;
}
