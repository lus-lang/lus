//! The proof that decides which optional libraries a bundled program can
//! reach (`spec/design/aot.md`, "Leaving out libraries"). It reads the
//! bytecode of every bundled function, conservatively.
//!
//! The program qualifies when every global access names a constant, it
//! never reads `_ENV` as a value, it reaches neither the debug library
//! nor the loaders of code, and every `require` names a constant module.
//! The optional libraries are those the build can leave out: the network
//! library (`network`), the worker library (`worker`), SQLite
//! (`io.sqlite`), and the compression codecs (`vector.archive`). A library
//! table that the program uses as a value, rather than to read one
//! constant field, keeps every optional library it holds.

const std = @import("std");
const object = @import("../vm/object.zig");
const op = @import("../compile/opcodes.zig");

const Proto = object.Proto;

/// The optional libraries, by the build option that includes each.
pub const Libs = struct {
    net: bool = false,
    workers: bool = false,
    sqlite: bool = false,
    archive: bool = false,

    pub fn names(l: Libs, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        inline for (.{ .{ "net", "network" }, .{ "workers", "worker" }, .{ "sqlite", "io.sqlite" }, .{ "archive", "vector.archive" } }) |e| {
            if (!@field(l, e[0])) {
                if (w.end != 0) w.writeAll(", ") catch {};
                w.writeAll(e[1]) catch {};
            }
        }
        return w.buffered();
    }
};

/// Where and why the proof could not name what a function reaches.
pub const Failure = struct {
    chunk: []const u8,
    line: u32,
    why: []const u8,
};

pub const Proof = struct {
    reached: Libs = .{},
    failed: ?Failure = null,

    /// Adds the function `p` and every function it holds.
    pub fn add(pr: *Proof, p: *const Proto, chunk: []const u8) void {
        if (pr.failed != null) return;
        pr.function(p, chunk);
        for (p.protos) |q| pr.add(q, chunk);
    }

    fn fail(pr: *Proof, p: *const Proto, chunk: []const u8, pc: usize, why: []const u8) void {
        if (pr.failed != null) return;
        const line = if (pc < p.lines.len) p.lines[pc] else p.line_defined;
        pr.failed = .{ .chunk = chunk, .line = line, .why = why };
    }

    fn function(pr: *Proof, p: *const Proto, chunk: []const u8) void {
        for (p.locvars) |v| if (std.mem.eql(u8, v.name.bytes(), "_ENV")) return pr.fail(p, chunk, v.start_pc, "_ENV is a local variable");
        const code = p.code;
        for (code, 0..) |i, pc| {
            switch (op.op(i)) {
                .getupval, .setupval => if (isEnv(p, op.b(i))) return pr.fail(p, chunk, pc, "_ENV is read or written as a value"),
                .globaldefr => return pr.fail(p, chunk, pc, "a global is defined in an environment held by a register"),
                .gettabup => {
                    if (!isEnv(p, op.b(i))) continue;
                    const name = constString(p, op.c(i)) orelse return pr.fail(p, chunk, pc, "a global is named by a value that is not a string");
                    pr.global(p, chunk, pc, name);
                    if (pr.failed != null) return;
                },
                else => {},
            }
        }
    }

    /// The global `name`, read by `gettabup` at `pc` into register A.
    fn global(pr: *Proof, p: *const Proto, chunk: []const u8, pc: usize, name: []const u8) void {
        const forbidden = [_][]const u8{ "_G", "debug", "load", "loadfile", "dofile", "package" };
        for (forbidden) |f| if (std.mem.eql(u8, name, f)) return pr.fail(p, chunk, pc, reasonFor(f));
        const ra = op.a(p.code[pc]);
        if (std.mem.eql(u8, name, "require")) {
            const mod = requiredModule(p, pc, ra) orelse return pr.fail(p, chunk, pc, "require names a module that is not a constant");
            pr.library(mod, null);
            return;
        }
        pr.library(name, fieldRead(p, pc, ra));
    }

    /// The library `name`, as a global or a required module, of which the
    /// program reads only the constant field `field`, or which it uses as
    /// a value when `field` is null.
    fn library(pr: *Proof, name: []const u8, field: ?[]const u8) void {
        if (std.mem.eql(u8, name, "network")) pr.reached.net = true;
        if (std.mem.eql(u8, name, "worker")) pr.reached.workers = true;
        if (std.mem.eql(u8, name, "io") and (field == null or std.mem.eql(u8, field.?, "sqlite"))) pr.reached.sqlite = true;
        if (std.mem.eql(u8, name, "vector") and (field == null or std.mem.eql(u8, field.?, "archive"))) pr.reached.archive = true;
    }
};

fn reasonFor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "_G")) return "_G holds every global";
    if (std.mem.eql(u8, name, "debug")) return "the debug library reaches every value";
    if (std.mem.eql(u8, name, "package")) return "package.loaded holds every library";
    return "a loader of code is reached";
}

fn isEnv(p: *const Proto, idx: u8) bool {
    if (idx >= p.upvals.len) return false;
    const n = p.upvals[idx].name orelse return false;
    return std.mem.eql(u8, n.bytes(), "_ENV");
}

fn constString(p: *const Proto, k: usize) ?[]const u8 {
    if (k >= p.constants.len) return null;
    const v = p.constants[k];
    if (v.tag != .string) return null;
    return v.as(object.String).bytes();
}

/// The constant field that the instruction after `pc` reads from the
/// table in register `ra`, replacing it, or null when the table is used
/// in any other way.
fn fieldRead(p: *const Proto, pc: usize, ra: u8) ?[]const u8 {
    if (pc + 1 >= p.code.len) return null;
    const n = p.code[pc + 1];
    if (op.op(n) != .getfield or op.b(n) != ra or op.a(n) != ra) return null;
    return constString(p, op.c(n));
}

/// The module that `require` in register `ra` loads when the next two
/// instructions call it with one constant string, or null.
fn requiredModule(p: *const Proto, pc: usize, ra: u8) ?[]const u8 {
    if (pc + 2 >= p.code.len) return null;
    const k = p.code[pc + 1];
    const call = p.code[pc + 2];
    if (op.op(k) != .loadk or op.a(k) != ra + 1) return null;
    if (op.op(call) != .call or op.a(call) != ra or op.b(call) != 2) return null;
    return constString(p, op.bx(k));
}

fn proveSource(src: []const u8) !Proof {
    const state = @import("../vm/state.zig");
    const codegen = @import("../compile/codegen.zig");
    const g = try state.create(std.testing.allocator, std.testing.io);
    defer state.destroy(g);
    g.gc_stopped = true;
    const p = switch (try codegen.compile(g, src, .{ .chunkname = "=proof" })) {
        .ok => |p| p,
        .err => |msg| {
            g.gpa.free(msg);
            return error.TestUnexpectedResult;
        },
    };
    var pr: Proof = .{};
    pr.add(p, "=proof");
    // The failure names a constant reason and the chunk name above, which
    // outlive the state.
    return pr;
}

test "a program that reads constant globals reaches no optional library" {
    const pr = try proveSource("local f = io.open\nprint(string.upper(\"a\"), f, math.pi)\nlocal function g() return os.time() end\nreturn g");
    try std.testing.expect(pr.failed == null);
    try std.testing.expectEqual(Libs{}, pr.reached);
}

test "a field of a library keeps only the optional library it names" {
    const pr = try proveSource("local db = io.sqlite\nlocal z = vector.archive\nlocal n = require(\"network\")\nreturn db, z, n");
    try std.testing.expect(pr.failed == null);
    try std.testing.expectEqual(Libs{ .sqlite = true, .archive = true, .net = true }, pr.reached);
}

test "a library used as a value keeps its optional libraries" {
    const pr = try proveSource("local t = io\nlocal w = worker\nreturn t, w");
    try std.testing.expect(pr.failed == null);
    try std.testing.expectEqual(Libs{ .sqlite = true, .workers = true }, pr.reached);
}

test "the proof fails where a program can reach any library" {
    const cases = [_][]const u8{
        "local e = _ENV\nreturn e",
        "local name = \"net\" .. \"work\"\nreturn require(name)",
        "return _G",
        "return debug.traceback()",
        "return load",
        "local _ENV = {}\nreturn x",
        "return package.loaded",
    };
    for (cases) |src| {
        const pr = try proveSource(src);
        try std.testing.expect(pr.failed != null);
    }
}
