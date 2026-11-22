//! Allocation failure sweeps of the compiler and the binary chunk format,
//! in the manner of the malloc tests of SQLite.
//!
//! Each sweep compiles a program once to count its allocations, then once
//! for every allocation number N with the allocation N failing. Every run
//! must end in a result or in `error.OutOfMemory`, and the testing
//! allocator finds any block that a failing run leaks. The fault points of
//! `codegen.zig` give every append of the code generator a number of its
//! own, so a sweep reaches the failing edge of each call site.

const std = @import("std");
const api = @import("../api.zig");
const Thread = @import("../vm/state.zig").Thread;
const heapcount = @import("../vm/heapcount.zig");
const codegen = @import("codegen.zig");
const dump = @import("dump.zig");
const Value = @import("../vm/value.zig").Value;

const inject = heapcount.inject;

/// Programs that together reach most constructs of the language.
const corpus = [_][]const u8{
    \\local a, b, c = 1, 2.5, "s"
    \\local t = { 1, 2, 3, x = a, ["y"] = b, [a + 1] = c, f = function(...) return ... end }
    \\local big = { 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53, t.f(1, 2) }
    \\local n = a + b - a * b / b // a % b ^ 2
    \\local m = 1 + a; m = a + 1; m = a - 1; m = 1 - a; m = a * 2; m = a / 2; m = a // 2; m = a % 3
    \\local bits = (a & 3) | (a ~ 5) << 2 >> 1 ~ ~a
    \\bits = a & b; bits = a | 7; bits = a << 1; bits = 1 << a; bits = a >> 1
    \\local cmp = a < b, a <= b, a > b, a >= b, a == b, a ~= b, a == 1, 1 == a, a < 1, a > 1, a <= 1, a >= 1, a == "s", a == nil, a ~= true
    \\local logic = a and b or c, not a, a and (b or c), (a or b) and c, not (a == b) and c
    \\local s = c .. a .. b .. "x" .. `interp {a} and {b + 1} done`
    \\local neg = -a, -b, -(a + b), #t, #c
    \\local k = 10n * 3n + 7n, 1.5d + 2.25d, 0x7fffffffffffffff, 1e300, -0.0, 3 // 0.0
    \\if a < b and b < 3 or c == "s" then n = 1 elseif a > 2 then n = 2 elseif not c then n = 3 else n = 4 end
    \\while a < 10 and b do a = a + 1 if a == 5 then break end end
    \\repeat local z = a; a = a - 1 until z < 3 or a == 0
    \\for i = 1, 10, 2 do n = n + i end
    \\for i = 10, 1, -1 do n = n - i end
    \\for i = 1.0, 2.0, 0.5 do n = n + i end
    \\for key, val in pairs(t) do n = key end
    \\for _, v in ipairs({ 1, 2 }) do if v == 2 then goto skip end n = v ::skip:: end
    \\do local inner <const> = 4 n = inner + 1 end
    \\local x <close> = nil
    \\local function rec(q) if q == 0 then return 0 end return rec(q - 1) + 1 end
    \\local obj = { v = 1 }
    \\function obj.get(self) return self.v end
    \\function obj:set(v) self.v = v end
    \\obj:set(3); obj.get(obj); obj["get"](obj)
    \\local function va(...) local p, q = ...; local all = { ... }; return select("#", ...), p, q, ... end
    \\return va(t[1], t.x, t["y"], big[54], rec(2), n, m, bits, cmp, logic, s, neg, k)
    ,
    \\local t = { a = { b = { c = 1 } }, list = { 1, 2, 3, 4, 5 } }
    \\local v = t?.a?.b?.c, t?.z?.y, t.a?.b, t?.list[2], t?.a.b?.c
    \\local f = t?.fn and t.fn(1)
    \\local x = do local y = 10 provide y * 2 end
    \\local y = 5 + do provide 10 end
    \\local ok, err = catch error("e")
    \\local ok2, a, b = catch (function() return 1, 2 end)()
    \\catch error("statement")
    \\local s1, s2, s3 = t.list[2,4], t.list[3,], t.list[,]
    \\local str = ("hello")[2,3]
    \\local p, q from t.a
    \\local name, value from { name = "n", value = 2 }
    \\if z = t.a then x = z end
    \\if w = nil then x = 0 elseif u = t.list then x = u end
    \\while i = t.list[1] do t.list[1] = nil end
    \\local E = enum Red, Green, Blue end
    \\local g <group> = { gx = 1, gy = 2, sub = { inner = 3 } }
    \\g.gx = g.gy + g.sub.inner
    \\local h <group> = g
    \\for k = 1, 3 do if k == 2 then continue end x = x + k end
    \\for name2, age from { { name2 = "a", age = 1 } } do x = x + age end
    \\global gl = 1
    \\gl = gl + 1
    \\local m <meta> = 2 + 3
    \\local lz <lazy> = do provide x + 1 end
    \\local o1 <observe> = 1
    \\local o2 <observe> = o1 + 1
    \\o1 = 5
    \\return v, f, x, y, ok, err, ok2, a, b, s1, s2, s3, str, p, q, name, value, E.Red, g.gx, h.gy, gl, m, lz, o2
    ,
    \\local people = { { name = "A", age = 30, region = "e" }, { name = "B", age = 17, region = "w" } }
    \\local orders = { { who = "A", amount = 5 }, { who = "B", amount = 7 } }
    \\local out, lim = {}, 1
    \\for row in query(@people as p where p.age > 18 and p.region == "e" select p.name order by p.name) do out[#out + 1] = row end
    \\for row in query(@people as p select p.region, count(*) as n group by p.region order by n desc limit lim) do out[#out + 1] = row end
    \\for row in query(@people as p, orders as o where o.who == p.name and o.amount > 1 select p.name, o.amount as amt) do out[#out + 1] = row end
    \\for row in query(@people as p select count(*) as n, sum(p.age) as s, count(p.name) as c) do out[#out + 1] = row end
    \\for row in query(@people as p select p.name order by p.age desc, p.name limit 2 offset 1) do out[#out + 1] = row end
    \\for row in query(@people as p select distinct p.region) do out[#out + 1] = row end
    \\for row in query(@people as p where p.age >= lim or not p.region select p.missing as m limit 1) do out[#out + 1] = row end
    \\return out
    ,
};

/// A program that reads compile-time flags, compiled as the modules of a
/// remote package are, with each read of a flag folded to its value.
const flags_program =
    \\local level = flags.level
    \\local function f()
    \\    if flags.debug then return 1 elseif not flags.quiet and flags.level then return 2 end
    \\    if flags.level == 3 and flags.name == "x" or flags.name ~= "y" then level = 0 end
    \\    if flags.level < 4 and not (flags.level >= 9) then level = 1 end
    \\    if flags then level = 2 end
    \\    if flags[1] then level = 3 end
    \\    local m <meta> = flags.level
    \\    return flags["level"], flags.missing, flags[level], m
    \\end
    \\local function g()
    \\    local flags = { debug = true }
    \\    if flags.debug then return flags.debug end
    \\    return function() if flags.level then return 1 end end
    \\end
    \\local flags2 = flags
    \\return f(), g(), level, flags2.debug
;

/// Programs that fail to compile in the code generator, at the end of a
/// function and in the middle of a statement.
const failing = [_][]const u8{
    "local function f() goto nowhere end return f",
    "local x <const> = 1 local function f() local y = 2 x = y end",
    "for i = 1, 2 do local a <close>, b <close> = 1, 2 end",
};

/// Runs `body` with allocation `n` of the state failing, and returns
/// whether the run made at least `n` allocations, so the sweep ends at the
/// first run that no failure reached.
fn attempt(l: *Thread, n: usize, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Thread) anyerror!void) !bool {
    inject.count.store(0, .monotonic);
    inject.target = n;
    defer inject.target = 0;
    body(ctx, l) catch |e| switch (e) {
        error.OutOfMemory => {},
        else => return e,
    };
    return inject.count.load(.monotonic) >= n;
}

/// Sweeps every allocation of `body` in one state. The prototypes of the
/// runs stay with the collector of the state until it closes.
fn sweep(ctx: anytype, comptime body: fn (@TypeOf(ctx), *Thread) anyerror!void) !void {
    const l = try api.newState(std.testing.allocator, std.testing.io);
    defer api.close(l);
    var n: usize = 1;
    while (try attempt(l, n, ctx, body)) n += 1;
    // The sweep reached the end of the work.
    try std.testing.expect(n > 1);
}

const Source = struct { src: []const u8, opts: codegen.Options };

fn compileOne(s: Source, l: *Thread) !void {
    const r = try codegen.compile(l.g, s.src, s.opts);
    switch (r) {
        .ok => {},
        .err => |msg| {
            defer l.g.gpa.free(msg);
            if (inject.target == 0 or inject.count.load(.monotonic) < inject.target) {
                std.debug.print("{s}\n--\n{s}\n", .{ msg, s.src });
                return error.TestUnexpectedResult;
            }
        },
    }
}

fn failOne(src: []const u8, l: *Thread) !void {
    const r = try codegen.compile(l.g, src, .{ .chunkname = "=sweep" });
    switch (r) {
        .ok => return error.TestUnexpectedResult,
        .err => |msg| l.g.gpa.free(msg),
    }
}

fn dumpOne(src: []const u8, l: *Thread) !void {
    const gpa = std.testing.allocator;
    // The program compiles before the failures start, so that the sweep
    // reaches the writer and the reader.
    const saved = inject.target;
    inject.target = 0;
    const r = try codegen.compile(l.g, src, .{ .chunkname = "=sweep" });
    const chunk = try dump.dump(gpa, r.ok, false);
    defer gpa.free(chunk);
    inject.count.store(0, .monotonic);
    inject.target = saved;
    const again = try dump.dump(gpa, r.ok, true);
    gpa.free(again);
    const was_stopped = l.g.gc_stopped;
    l.g.gc_stopped = true;
    defer l.g.gc_stopped = was_stopped;
    _ = try dump.undump(l.g, chunk, "=sweep");
}

test "the compiler survives the failure of each allocation" {
    for (corpus) |src| try sweep(Source{ .src = src, .opts = .{ .chunkname = "=sweep" } }, compileOne);
}

test "the compiler survives allocation failures while it folds flags" {
    const gpa = std.testing.allocator;
    var flags: std.StringHashMapUnmanaged(Value) = .empty;
    defer flags.deinit(gpa);
    try flags.put(gpa, "level", Value.int(3));
    try flags.put(gpa, "debug", Value.false);
    const l = try api.newState(gpa, std.testing.io);
    defer api.close(l);
    try flags.put(gpa, "name", Value.obj(.string, try l.newString("x")));
    for ([_]bool{ true, false }) |fold| {
        try sweep(Source{ .src = flags_program, .opts = .{ .chunkname = "=sweep", .flags = &flags, .fold_flag_reads = fold } }, compileOne);
    }
}

test "the compiler reports its errors under allocation failures" {
    for (failing) |src| try sweep(src, failOne);
}

test "binary chunks survive the failure of each allocation" {
    for (corpus) |src| try sweep(src, dumpOne);
}
