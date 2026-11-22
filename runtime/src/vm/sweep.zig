//! Allocation failure sweeps of running programs, in the manner of the
//! malloc tests of SQLite.
//!
//! Each sweep runs a program once for every allocation number N of the
//! state with the allocation N failing. A run may end with an error, which
//! must be "not enough memory" once a failure was reached. It must not
//! crash or leak, and the state must run the next attempt correctly. The
//! programs keep their values in locals, so each attempt starts from the
//! same state.

const std = @import("std");
const api = @import("../api.zig");
const Thread = @import("state.zig").Thread;
const heapcount = @import("heapcount.zig");
const jit = @import("../jit/jit.zig");

const inject = heapcount.inject;

/// Programs that reach the tables, strings, closures, coroutines,
/// metatables, and the core libraries.
const programs = [_][]const u8{
    \\local t = {}
    \\for i = 1, 40 do t[i] = i * 2 end
    \\for i = 1, 40 do t["k" .. i] = { i } end
    \\t[1.5] = "f"; t[true] = 1; t.extra = 7
    \\local n = 0
    \\for k, v in pairs(t) do n = n + 1 end
    \\for i = 40, 1, -1 do table.remove(t) end
    \\table.insert(t, 1, "a"); table.insert(t, "b")
    \\assert(#t == 2 and n == 83)
    ,
    \\local parts = {}
    \\for i = 1, 30 do parts[#parts + 1] = string.rep("x", i) .. i end
    \\local s = table.concat(parts, ",")
    \\local u = s:upper():lower()
    \\local pieces = 0
    \\for w in s:gmatch("[^,]+") do pieces = pieces + 1 end
    \\local r = s:gsub("x+", function(m) return #m end)
    \\local f = string.format("%s|%5d|%.3f|%q", "a", 42, 1.5, "q\n")
    \\assert(pieces == 30 and #u == #s and #r > 0 and #f > 0)
    \\local v = `interp $(pieces) and $(f)`
    \\assert(#v > 0 and ("héllo"):sub(2, 3) == "él")
    ,
    \\local function counter()
    \\    local c = 0
    \\    return function() c = c + 1 return c end
    \\end
    \\local fs = {}
    \\for i = 1, 20 do fs[i] = counter() end
    \\for i = 1, 20 do fs[i]() end
    \\local co = coroutine.wrap(function(a)
    \\    for i = 1, 5 do a = coroutine.yield(a + i) end
    \\    return a
    \\end)
    \\local x = co(1)
    \\for i = 1, 5 do x = co(x) end
    \\local ok, err = catch error({ code = 1 })
    \\assert(not ok and err.code == 1)
    ,
    \\local mt = { __index = function(t, k) return k .. "!" end, __add = function(a, b) return 3 end,
    \\    __concat = function(a, b) return "cc" end, __len = function() return 9 end,
    \\    __call = function(self, y) return y end, __eq = function() return true end }
    \\local a = setmetatable({}, mt)
    \\local b = setmetatable({}, mt)
    \\assert(a.x == "x!" and a + 1 == 3 and a .. "s" == "cc" and #a == 9 and a(5) == 5 and a == b)
    \\local weak = setmetatable({}, { __mode = "k" })
    \\for i = 1, 20 do weak[{}] = i end
    \\collectgarbage()
    \\local g = setmetatable({}, { __gc = function() end })
    \\g = nil
    \\collectgarbage()
    ,
    \\local big = 10n ^ 40 + 7n
    \\local d = 1.25d * 3 + decimal("0.5")
    \\local s = tostring(big) .. tostring(d)
    \\local j = tojson({ a = { 1, 2, 3 }, b = "x", c = true })
    \\local back = fromjson(j)
    \\local sorted = { 5, 3, 9, 1, 7, 2, 8 }
    \\table.sort(sorted, function(p, q) return p > q end)
    \\local m = table.map(sorted, function(v) return v * 2 end)
    \\assert(#s > 0 and back.b == "x" and sorted[1] == 9 and m[1] == 18)
    \\local E = enum Red, Green end
    \\local q, rows = {}, { { n = 1 }, { n = 2 } }
    \\for row in query(@rows as r where r.n > 1 select r.n) do q[#q + 1] = row end
    \\assert(#q == 1 and E.Red ~= E.Green)
    ,
};

fn attempt(l: *Thread, n: usize, src: []const u8) !bool {
    inject.count.store(0, .monotonic);
    inject.target = n;
    const msg = api.doString(l, src, "=sweep");
    const reached = inject.count.load(.monotonic) >= n;
    inject.target = 0;
    if (msg) |m| {
        if (!reached or std.mem.indexOf(u8, m, "not enough memory") == null) {
            std.debug.print("attempt {d}: {s}\n", .{ n, m });
            return error.TestUnexpectedResult;
        }
    }
    return reached;
}

fn sweep(src: []const u8, setting: jit.Setting) !void {
    const l = try api.newState(std.testing.allocator, std.testing.io);
    defer api.close(l);
    try api.openLibs(l);
    jit.configure(l.g, setting, 1);
    // A clean run first, so that the libraries make their lazy tables
    // before the failures start.
    if (api.doString(l, src, "=sweep")) |m| {
        std.debug.print("{s}\n", .{m});
        return error.TestUnexpectedResult;
    }
    var n: usize = 1;
    while (try attempt(l, n, src)) n += 1;
    try std.testing.expect(n > 1);
    // The state still runs the program after the sweep.
    if (api.doString(l, src, "=sweep")) |m| {
        std.debug.print("{s}\n", .{m});
        return error.TestUnexpectedResult;
    }
}

test "the runtime survives the failure of each allocation" {
    for (programs) |src| try sweep(src, .off);
}
