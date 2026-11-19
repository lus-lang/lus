//! Tests that run Lus code through the emitter. Each program runs once in
//! a state that only interprets and once in a state that compiles every
//! function on its first call, and both must produce the same text.

const std = @import("std");
const api = @import("../api.zig");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const jit = @import("jit.zig");
const Thread = state.Thread;

const gpa = std.testing.allocator;

/// Runs `src`, which returns one value, and returns that value as text.
fn evaluate(l: *Thread, src: []const u8) ![]u8 {
    api.load(l, src, "=test") catch return error.Syntax;
    if (!api.pcall(l, 0, 1)) {
        std.debug.print("error: {s}\n", .{api.errorMessage(l, l.stack[l.top - 1])});
        return error.Runtime;
    }
    const text = try gpa.dupe(u8, api.errorMessage(l, l.stack[l.top - 1]));
    l.top -= 1;
    return text;
}

fn newState(setting: jit.Setting) !*Thread {
    const l = try api.newState(gpa, std.testing.io);
    errdefer api.close(l);
    api.openLibs(l) catch return error.Libraries;
    jit.configure(l.g, setting, 1);
    return l;
}

fn expectSame(src: []const u8) !void {
    const plain = try newState(.off);
    defer api.close(plain);
    const native = try newState(.eager);
    defer api.close(native);
    const want = try evaluate(plain, src);
    defer gpa.free(want);
    const got = try evaluate(native, src);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 0), plain.g.jit.compiled);
    try std.testing.expect(native.g.jit.compiled > 0);
}

test "arithmetic templates agree with the interpreter" {
    try expectSame(
        \\local out = {}
        \\local vals = { 0, 1, -1, 7, -7, 3, 2.5, -2.5, 0.0, 1e300, math.maxinteger, math.mininteger }
        \\local function ops(a, b)
        \\    local t = { a + b, a - b, a * b, a / b, a + 1, a - 1, a * 3, a / 2, a + 0.5, a * 1.5, -a }
        \\    if math.type(a) == "integer" and math.type(b) == "integer" then
        \\        t[#t + 1] = a & b
        \\        t[#t + 1] = a | b
        \\        t[#t + 1] = a ~ b
        \\        if b ~= 0 then
        \\            t[#t + 1] = a % b
        \\            t[#t + 1] = a // b
        \\        end
        \\    end
        \\    t[#t + 1] = a % 7
        \\    t[#t + 1] = a // 7
        \\    t[#t + 1] = a % -3
        \\    t[#t + 1] = a // -3
        \\    for i = 1, #t do out[#out + 1] = tostring(t[i]) end
        \\end
        \\for _, a in ipairs(vals) do
        \\    for _, b in ipairs(vals) do ops(a, b) end
        \\end
        \\return table.concat(out, " ")
    );
}

test "comparison templates agree with the interpreter" {
    try expectSame(
        \\local out = {}
        \\local nan = 0.0 / 0.0
        \\local vals = { 0, 1, -1, 10, 9, 11, 2.5, 10.0, nan, math.maxinteger, math.mininteger, "a", "b", false }
        \\local function cmp(a, b)
        \\    local r = 0
        \\    if a == b then r = r + 1 end
        \\    if a ~= b then r = r + 2 end
        \\    if type(a) == type(b) and type(a) ~= "boolean" then
        \\        if a < b then r = r + 4 end
        \\        if a <= b then r = r + 8 end
        \\        if a > b then r = r + 16 end
        \\        if a >= b then r = r + 32 end
        \\    end
        \\    if type(a) == "number" then
        \\        if a < 10 then r = r + 64 end
        \\        if a <= 10 then r = r + 128 end
        \\        if a > 10 then r = r + 256 end
        \\        if a >= 10 then r = r + 512 end
        \\    end
        \\    if a == 10 then r = r + 1024 end
        \\    if a == "a" then r = r + 2048 end
        \\    if a == nil then r = r + 4096 end
        \\    if not a then r = r + 8192 end
        \\    out[#out + 1] = r
        \\end
        \\for _, a in ipairs(vals) do
        \\    for _, b in ipairs(vals) do cmp(a, b) end
        \\end
        \\return table.concat(out, " ")
    );
}

test "loops, calls, and closures agree with the interpreter" {
    try expectSame(
        \\local out = {}
        \\local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
        \\local function sum(a, b, c) local s = 0 for i = a, b, c do s = s + i end return s end
        \\local function count(n, acc) if n == 0 then return acc end return count(n - 1, acc + 1) end
        \\local function make(n) local c = 0 return function() c = c + n return c end end
        \\local function va(...) return select("#", ...), ... end
        \\out[#out + 1] = fib(18)
        \\out[#out + 1] = sum(1, 100, 1)
        \\out[#out + 1] = sum(100, 1, -3)
        \\out[#out + 1] = sum(1.0, 2.0, 0.25)
        \\out[#out + 1] = sum(5, 1, 1)
        \\out[#out + 1] = count(5000, 0)
        \\local f = make(3)
        \\out[#out + 1] = f() + f() + f()
        \\out[#out + 1] = table.concat({ va(1, 2, 3) }, ",")
        \\local t = {}
        \\for i = 1, 50 do t[i] = i * i end
        \\local s = 0
        \\for i, v in ipairs(t) do s = s + v end
        \\for k, v in pairs({ a = 1, b = 2 }) do s = s + v end
        \\for i in range(1, 10) do s = s + i end
        \\out[#out + 1] = s
        \\local i = 0
        \\while i < 10 do i = i + 1 if i % 2 == 0 then continue end s = s + i end
        \\repeat i = i - 1 until i <= 0
        \\out[#out + 1] = s + i
        \\local ok, err = catch error("stop")
        \\out[#out + 1] = tostring(ok) .. tostring(err)
        \\local co = coroutine.wrap(function() for j = 1, 3 do coroutine.yield(j) end end)
        \\out[#out + 1] = co() + co() + co()
        \\return table.concat(out, " ")
    );
}

test "table templates agree with the interpreter" {
    try expectSame(
        \\local out = {}
        \\local function note(v) out[#out + 1] = tostring(v) end
        \\local Class = {}
        \\Class.__index = Class
        \\function Class.new(v) return setmetatable({ v = v, w = v }, Class) end
        \\function Class:sum() return self.v + self.w end
        \\function Class:next() return Class.new(self.v + 1) end
        \\local function fields(o, n)
        \\    for _ = 1, n do
        \\        o.v = o.v + 1
        \\        o = o:next()
        \\    end
        \\    return o:sum()
        \\end
        \\note(fields(Class.new(1), 50))
        \\local function arrays(n, first, other)
        \\    local t = {}
        \\    for i = 1, n do t[i] = first end
        \\    t[n // 2] = other
        \\    local s = 0
        \\    for i = 1, n do
        \\        local v = t[i]
        \\        if type(v) == "number" then s = s + v end
        \\    end
        \\    return s, math.type(t[1]), t[n + 1], t[0], #t, t[n // 2]
        \\end
        \\for _, pair in ipairs({ { 1, 2 }, { 1, 0.5 }, { 0.5, 1 }, { 1, "s" }, { "s", 1 }, { 0.5, false } }) do
        \\    local s, kind, past, zero, len, mid = arrays(20, pair[1], pair[2])
        \\    note(s) note(kind) note(past) note(zero) note(len) note(mid)
        \\end
        \\local function strings(s) return s:upper(), #s, s:sub(2, 3) end
        \\for _ = 1, 3 do
        \\    local u, n, m = strings("héllo")
        \\    note(u) note(n) note(m)
        \\end
        \\local function tail(a, b) return math.max(a, b) end
        \\local function pass(a, b) return tail(b, a) end
        \\for i = 1, 5 do note(pass(i, 3)) end
        \\return table.concat(out, " ")
    );
}

test "collecting a function frees its native code" {
    const l = try newState(.eager);
    defer api.close(l);
    const text = try evaluate(l,
        \\pledge("load")
        \\for i = 1, 200 do
        \\    local f = load("local n = ... local s = 0 for i = 1, n do s = s + i end return s")
        \\    assert(f(10) == 55)
        \\end
        \\return "done"
    );
    defer gpa.free(text);
    const js = &l.g.jit;
    try std.testing.expect(js.compiled >= 200);
    const text2 = try evaluate(l, "collectgarbage() collectgarbage() return 'ok'");
    defer gpa.free(text2);
    // The loaded functions are gone, and so is their code.
    try std.testing.expect(js.live < 50);
    try std.testing.expect(js.arena.used < 64 * 1024);
}

test "every instruction gets an offset in increasing order" {
    const l = try newState(.eager);
    defer api.close(l);
    try api.load(l, "local s = 0 for i = 1, 10 do s = s + i end return s", "=test");
    const cl = l.stack[l.top - 1].as(object.Closure);
    try std.testing.expect(api.pcall(l, 0, 1));
    const code: *jit.Code = @ptrCast(@alignCast(cl.proto.jit_code.?));
    try std.testing.expectEqual(cl.proto.code.len + 1, code.count);
    var i: usize = 1;
    while (i < code.count) : (i += 1) try std.testing.expect(code.offs[i] > code.offs[i - 1]);
    try std.testing.expect(code.offs[code.count - 1] < code.size);
}
