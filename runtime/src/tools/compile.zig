//! `lus compile`: compiles a script to a binary chunk.
//!
//! Usage: lus compile [options] SCRIPT
//!
//!   -o FILE                the output path (default: the script name with
//!                          the extension .lusc)
//!   -s, --strip            leave out debug information
//!   -F name[=value]        define a compile-time flag (also --flag)
//!
//! The chunk is the one `string.dump` writes for the compiled script, and
//! `lus` runs it as it runs a source file.

const std = @import("std");
const lus = @import("../lus.zig");
const api = lus.api;
const codegen = lus.compile.codegen;
const dump = lus.compile.dump;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: lus compile [options] SCRIPT
    \\
    \\Compiles SCRIPT to a binary chunk.
    \\
    \\Options:
    \\  -o FILE           write the chunk to FILE (default: SCRIPT.lusc)
    \\  -s, --strip       leave out debug information
    \\  -F name[=value]   define a compile-time flag (also --flag)
    \\
;

const Options = struct {
    output: ?[]const u8 = null,
    script: ?[]const u8 = null,
    strip: bool = false,
    flags: std.ArrayList([]const u8) = .empty,

    fn deinit(o: *Options, gpa: Allocator) void {
        o.flags.deinit(gpa);
    }
};

fn parseOptions(gpa: Allocator, args: []const []const u8) !?Options {
    var o: Options = .{};
    errdefer o.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const Kind = enum { output, flag };
        const kind: ?Kind = if (std.mem.eql(u8, a, "-o"))
            .output
        else if (std.mem.eql(u8, a, "-F") or std.mem.eql(u8, a, "--flag"))
            .flag
        else
            null;
        if (kind) |k| {
            i += 1;
            if (i >= args.len) {
                std.debug.print("lus compile: '{s}' needs an argument\n{s}", .{ a, usage });
                return null;
            }
            switch (k) {
                .output => o.output = args[i],
                .flag => try o.flags.append(gpa, args[i]),
            }
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--strip")) {
            o.strip = true;
        } else if (std.mem.startsWith(u8, a, "-F") and a.len > 2) {
            try o.flags.append(gpa, a[2..]);
        } else if (std.mem.startsWith(u8, a, "--flag=")) {
            try o.flags.append(gpa, a["--flag=".len..]);
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus compile: unknown option '{s}'\n{s}", .{ a, usage });
            return null;
        } else if (o.script == null) {
            o.script = a;
        } else {
            std.debug.print("lus compile: more than one script given\n{s}", .{usage});
            return null;
        }
    }
    if (o.script == null) {
        std.debug.print("{s}", .{usage});
        return null;
    }
    return o;
}

/// The output path for `script` when `-o` is absent.
fn defaultOutput(gpa: Allocator, script: []const u8) ![]u8 {
    const base = std.fs.path.basename(script);
    const dir = script[0 .. script.len - base.len];
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| (if (d == 0) base else base[0..d]) else base;
    return std.fmt.allocPrint(gpa, "{s}{s}.lusc", .{ dir, stem });
}

/// Compiles the file at `path` to a binary chunk named `chunkname`.
/// Prints the problem and returns error.Reported on failure.
fn compileFile(gpa: Allocator, io: std.Io, path: []const u8, chunkname: []const u8, flags: []const []const u8, strip: bool) ![]u8 {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        std.debug.print("lus compile: cannot open {s} ({s})\n", .{ path, @errorName(e) });
        return error.Reported;
    };
    defer gpa.free(src);
    if (dump.isBinary(src)) {
        std.debug.print("lus compile: {s} is already a binary chunk\n", .{path});
        return error.Reported;
    }
    // A state backs compilation, so flags fold exactly as when the script
    // runs. Collection stays off while the prototypes wait to be dumped.
    const l = try api.newState(gpa, io);
    defer api.close(l);
    l.g.gc_stopped = true;
    try api.setFlags(l, flags);
    const fl: ?*const std.StringHashMapUnmanaged(lus.vm.value.Value) = if (l.g.ext.get("flags.compile")) |p| @ptrCast(@alignCast(p)) else null;
    const r = try codegen.compile(l.g, src, .{ .chunkname = chunkname, .flags = fl });
    const proto = switch (r) {
        .err => |msg| {
            defer gpa.free(msg);
            std.debug.print("lus compile: {s}\n", .{msg});
            return error.Reported;
        },
        .ok => |p| p,
    };
    return dump.dump(gpa, proto, strip) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            std.debug.print("lus compile: {s} holds a constant that cannot be dumped\n", .{path});
            return error.Reported;
        },
    };
}

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var opts = (try parseOptions(gpa, args)) orelse return 2;
    defer opts.deinit(gpa);
    const script = opts.script.?;
    const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{script});
    defer gpa.free(chunkname);
    const data = compileFile(gpa, io, script, chunkname, opts.flags.items, opts.strip) catch |e| {
        if (e == error.Reported) return 1;
        return e;
    };
    defer gpa.free(data);
    const out_path = if (opts.output) |o| try gpa.dupe(u8, o) else try defaultOutput(gpa, script);
    defer gpa.free(out_path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = data }) catch |e| {
        std.debug.print("lus compile: cannot write {s} ({s})\n", .{ out_path, @errorName(e) });
        return 1;
    };
    return 0;
}

test "default output" {
    const gpa = std.testing.allocator;
    const a = try defaultOutput(gpa, "dir/app.lus");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("dir/app.lusc", a);
    const b = try defaultOutput(gpa, "app");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("app.lusc", b);
}
