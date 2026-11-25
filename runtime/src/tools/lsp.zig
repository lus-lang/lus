//! The language server that `lus lsp` runs (`packages/language-server`).
//!
//! The build embeds the sources of the server, without its tests, as one
//! raw deflate stream of entries `path NUL length data`, where the length
//! is a 32-bit little-endian count of bytes (`agentDocsModule` in
//! `build.zig`). `load` inflates the stream and returns each module as a
//! preinclude named `lus-language.PATH`, with the slashes of the path as
//! dots, and `main.lus` as the main chunk. The CLI installs the modules
//! and runs the main chunk with the arguments after `lsp`, so `lus lsp`
//! speaks the Language Server Protocol on standard input and output.
//! `lus lsp --version` prints the version of the server.

const std = @import("std");
const docs = @import("agent_docs");
const package = @import("../lib/package.zig");

pub const Bundle = struct {
    raw: []u8,
    modules: []package.Preinclude,
    main: []const u8,

    pub fn deinit(b: *Bundle, gpa: std.mem.Allocator) void {
        for (b.modules) |m| {
            gpa.free(m.name);
            gpa.free(m.path);
        }
        gpa.free(b.modules);
        gpa.free(b.raw);
    }
};

pub fn load(gpa: std.mem.Allocator) !Bundle {
    const raw = try gpa.alloc(u8, docs.language_server_len);
    errdefer gpa.free(raw);
    var in: std.Io.Reader = .fixed(docs.language_server);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d = std.compress.flate.Decompress.init(&in, .raw, window);
    try d.reader.readSliceAll(raw);

    var modules: std.ArrayList(package.Preinclude) = .empty;
    errdefer {
        for (modules.items) |m| {
            gpa.free(m.name);
            gpa.free(m.path);
        }
        modules.deinit(gpa);
    }
    var main: ?[]const u8 = null;
    var i: usize = 0;
    while (i < raw.len) {
        const nul = std.mem.indexOfScalarPos(u8, raw, i, 0) orelse return error.Damaged;
        const path = raw[i..nul];
        if (nul + 5 > raw.len) return error.Damaged;
        const len = std.mem.readInt(u32, raw[nul + 1 ..][0..4], .little);
        const start = nul + 5;
        if (start + len > raw.len) return error.Damaged;
        const src = raw[start .. start + len];
        i = start + len;
        if (std.mem.eql(u8, path, "main.lus")) {
            main = src;
            continue;
        }
        if (!std.mem.endsWith(u8, path, ".lus")) return error.Damaged;
        const dotted = try std.mem.replaceOwned(u8, gpa, path[0 .. path.len - ".lus".len], "/", ".");
        defer gpa.free(dotted);
        const name = try std.fmt.allocPrint(gpa, "lus-language.{s}", .{dotted});
        errdefer gpa.free(name);
        const shown = try std.fmt.allocPrint(gpa, "lus-language/{s}", .{path});
        errdefer gpa.free(shown);
        try modules.append(gpa, .{ .name = name, .path = shown, .src = src });
    }
    return .{ .raw = raw, .modules = try modules.toOwnedSlice(gpa), .main = main orelse return error.Damaged };
}

test load {
    var b = try load(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, b.main, "lus-language.server") != null);
    var has_server = false;
    for (b.modules) |m| {
        has_server = has_server or std.mem.eql(u8, m.name, "lus-language.server");
        try std.testing.expect(!std.mem.startsWith(u8, m.name, "lus-language.tests"));
    }
    try std.testing.expect(has_server);
}
