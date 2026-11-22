//! The proof that decides which builtins a bundled program can reach
//! (`spec/design/aot.md`, "Leaving out code"). It reads the bytecode of
//! every bundled function, conservatively, and the linker keeps the
//! builtins that `keeps` names.
//!
//! The program qualifies when every global access names a constant, it
//! never reads `_ENV` as a value, it reaches neither the debug library
//! nor the loaders of code, and every `require` names a constant module.
//! A global read with a constant name, followed by reads of constant
//! fields into the same register, reaches the path it spells, such as
//! `network.tcp.connect`. The value at the end of such a chain may be
//! used in any way, so every builtin under that path is reached as well.
//! A field read with a constant key anywhere in the program reaches the
//! methods of that name, and a read with any other key reaches every
//! method.

const std = @import("std");
const object = @import("../vm/object.zig");
const op = @import("../compile/opcodes.zig");
const aux = @import("../lib/auxlib.zig");

const Proto = object.Proto;
const Set = std.StringHashMapUnmanaged(void);

/// Where and why the proof could not name what a function reaches.
pub const Failure = struct {
    chunk: []const u8,
    line: u32,
    why: []const u8,
};

pub const Proof = struct {
    arena: std.heap.ArenaAllocator,
    /// The globals and the paths under them that the program reads.
    reached: Set = .empty,
    /// The paths whose value the program uses as a whole.
    wholes: Set = .empty,
    /// The field names that the program reads with constant keys.
    names: Set = .empty,
    /// The program reads a field with a key that is not a constant.
    dynamic: bool = false,
    failed: ?Failure = null,

    pub fn init(gpa: std.mem.Allocator) Proof {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(pr: *Proof) void {
        pr.arena.deinit();
    }

    /// Adds the function `p` and every function it holds.
    pub fn add(pr: *Proof, p: *const Proto, chunk: []const u8) void {
        if (pr.failed != null) return;
        pr.function(p, chunk);
        for (p.protos) |q| pr.add(q, chunk);
    }

    /// Records that native code compiled ahead of time calls the builtin
    /// at `path` directly.
    pub fn reach(pr: *Proof, path: []const u8) void {
        pr.put(&pr.reached, path);
    }

    /// Whether the linker keeps the entry `name` of the registration of
    /// kind `kind` at `path` (`aux.setFuncs`).
    pub fn keeps(pr: *const Proof, kind: aux.Kind, path: []const u8, name: []const u8) bool {
        if (kind == .always or pr.failed != null) return true;
        if (kind == .fields or kind == .library) {
            var buf: [256]u8 = undefined;
            const key = if (path.len == 0) name else std.fmt.bufPrint(&buf, "{s}.{s}", .{ path, name }) catch return true;
            if (pr.reached.contains(key) or pr.wholly(path)) return true;
        }
        if (kind == .methods or kind == .library) {
            if (!pr.dynamic and !pr.names.contains(name)) return false;
            if (kind == .library) return true;
            const colon = std.mem.indexOfScalar(u8, path, ':') orelse return true;
            return colon == 0 or pr.ownerReached(path[0..colon]);
        }
        return false;
    }

    /// Whether `path` or a path that holds it is used as a whole.
    fn wholly(pr: *const Proof, path: []const u8) bool {
        if (path.len == 0) return false;
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (i == path.len or path[i] == '.') {
                if (pr.wholes.contains(path[0..i])) return true;
            }
        }
        return false;
    }

    /// Whether the program reaches anything under the library `lib`.
    fn ownerReached(pr: *const Proof, lib: []const u8) bool {
        if (pr.wholly(lib)) return true;
        var it = pr.reached.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, lib) and (k.len == lib.len or k.*[lib.len] == '.')) return true;
        }
        return false;
    }

    fn put(pr: *Proof, set: *Set, key: []const u8) void {
        if (set.contains(key)) return;
        const a = pr.arena.allocator();
        const k = a.dupe(u8, key) catch return pr.oom();
        set.put(a, k, {}) catch return pr.oom();
    }

    fn oom(pr: *Proof) void {
        if (pr.failed == null) pr.failed = .{ .chunk = "", .line = 0, .why = "the proof ran out of memory" };
    }

    fn fail(pr: *Proof, p: *const Proto, chunk: []const u8, pc: usize, why: []const u8) void {
        if (pr.failed != null) return;
        const line = if (pc < p.lines.len) p.lines[pc] else p.line_defined;
        pr.failed = .{ .chunk = chunk, .line = line, .why = why };
    }

    fn function(pr: *Proof, p: *const Proto, chunk: []const u8) void {
        for (p.locvars) |v| if (std.mem.eql(u8, v.name.bytes(), "_ENV")) return pr.fail(p, chunk, v.start_pc, "_ENV is a local variable");
        const code = p.code;
        var pc: usize = 0;
        while (pc < code.len) : (pc += 1) {
            const i = code[pc];
            switch (op.op(i)) {
                .getupval, .setupval => if (isEnv(p, op.b(i))) return pr.fail(p, chunk, pc, "_ENV is read or written as a value"),
                .globaldefr => return pr.fail(p, chunk, pc, "a global is defined in an environment held by a register"),
                .gettable => pr.dynamic = true,
                .getfield, .self => if (constString(p, op.c(i))) |k| pr.put(&pr.names, k),
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
        // A metatable leads to the methods of its values by any key.
        if (std.mem.eql(u8, name, "getmetatable")) pr.dynamic = true;
        const ra = op.a(p.code[pc]);
        if (std.mem.eql(u8, name, "require")) {
            const mod = requiredModule(p, pc, ra) orelse return pr.fail(p, chunk, pc, "require names a module that is not a constant");
            // A required library is a value the program holds as a whole.
            pr.put(&pr.wholes, mod);
            pr.put(&pr.reached, "require");
            return;
        }
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll(name) catch return pr.fail(p, chunk, pc, "a global name is too long");
        pr.put(&pr.reached, w.buffered());
        var j = pc + 1;
        while (j < p.code.len) : (j += 1) {
            const n = p.code[j];
            if (op.op(n) != .getfield or op.a(n) != ra or op.b(n) != ra) break;
            const k = constString(p, op.c(n)) orelse break;
            w.print(".{s}", .{k}) catch break;
            pr.put(&pr.reached, w.buffered());
        }
        pr.put(&pr.wholes, w.buffered());
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
    var pr: Proof = .init(std.testing.allocator);
    pr.add(p, "=proof");
    // The proof copies every name it keeps, and the failure names a
    // constant reason and the chunk name above, so it outlives the state.
    return pr;
}

test "a call of a library function keeps only that function" {
    var pr = try proveSource("print(string.upper(\"a\"), math.pi)\nlocal t = network.tcp.connect\nreturn t");
    defer pr.deinit();
    try std.testing.expect(pr.failed == null);
    try std.testing.expect(pr.keeps(.fields, "", "print"));
    try std.testing.expect(!pr.keeps(.fields, "", "tojson"));
    try std.testing.expect(pr.keeps(.library, "string", "upper"));
    try std.testing.expect(!pr.keeps(.library, "string", "lower"));
    try std.testing.expect(pr.keeps(.fields, "network.tcp", "connect"));
    try std.testing.expect(!pr.keeps(.fields, "network.tcp", "listen"));
    try std.testing.expect(!pr.keeps(.fields, "io", "open"));
    try std.testing.expect(pr.keeps(.always, "", "__gc"));
}

test "a library used as a value keeps all of it" {
    var pr = try proveSource("local t = io\nlocal n = require(\"network\")\nreturn t, n");
    defer pr.deinit();
    try std.testing.expect(pr.failed == null);
    try std.testing.expect(pr.keeps(.fields, "io", "open"));
    try std.testing.expect(pr.keeps(.fields, "network.tcp", "listen"));
    try std.testing.expect(!pr.keeps(.fields, "os", "time"));
}

test "methods follow the field names and the library that makes the values" {
    var pr = try proveSource("local f = io.open(\"x\")\nf:close()\nlocal s = (\"a\"):rep(2)\nreturn s");
    defer pr.deinit();
    try std.testing.expect(pr.failed == null);
    try std.testing.expect(pr.keeps(.methods, ":io.file", "close"));
    try std.testing.expect(!pr.keeps(.methods, ":io.file", "seek"));
    try std.testing.expect(pr.keeps(.library, "string", "rep"));
    try std.testing.expect(!pr.keeps(.methods, "network:socket", "close"));
    var dyn = try proveSource("local function get(t, k) return t[k] end\nreturn get, network.tcp");
    defer dyn.deinit();
    try std.testing.expect(dyn.keeps(.methods, ":io.file", "seek"));
    try std.testing.expect(dyn.keeps(.methods, "network:socket", "close"));
    try std.testing.expect(!dyn.keeps(.methods, "io.sqlite:db", "exec"));
}

test "the proof fails where a program can reach any builtin" {
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
        var pr = try proveSource(src);
        defer pr.deinit();
        try std.testing.expect(pr.failed != null);
        try std.testing.expect(pr.keeps(.fields, "io", "open"));
    }
}
