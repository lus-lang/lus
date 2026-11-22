//! Fuzz targets for the parsers and formatters of the standard library.
//!
//! Each target runs a property, written in Lus, over an input from the
//! fuzzer. The input reaches the property as three globals: `S`, the whole
//! input as a string, `A` and `B`, the input split in two at a point the
//! first byte chooses, and `V`, the raw bytes as a vector. Bytes that are
//! not WTF-8 are replaced, so every input is a string. A property raises an
//! error whose message starts with `PROPERTY` when an invariant breaks, and
//! catches every other error, since most inputs are invalid. A target
//! fails on a broken property, a crash, or a leak.
//!
//! `zig build test` runs every target once over its seeds, and `zig build
//! test --fuzz` mutates them (`runtime/HACKING.md`, "Fuzzing").

const std = @import("std");
const api = @import("api.zig");
const aux = @import("lib/auxlib.zig");
const vector = @import("lib/vector.zig");
const wtf8 = @import("vm/wtf8.zig");
const Value = @import("vm/value.zig").Value;

const Smith = std.testing.Smith;
const gpa = std.testing.allocator;

/// Runs `property` with the globals described above and fails when it
/// reports a broken invariant.
fn check(comptime property: []const u8, input: []const u8) !void {
    const l = try api.newState(gpa, std.testing.io);
    defer api.close(l);
    try api.openLibs(l);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try wtf8.appendLossy(gpa, &text, input);
    const s = text.items;
    const cut = if (s.len == 0) 0 else wtf8.boundaryBefore(s, @as(usize, s[0]) % (s.len + 1));
    try aux.setGlobal(l, "S", try l.newStringValue(s));
    try aux.setGlobal(l, "A", try l.newStringValue(s[0..cut]));
    try aux.setGlobal(l, "B", try l.newStringValue(s[cut..]));
    try aux.setGlobal(l, "V", Value.obj(.vector, try vector.newVector(l, input)));
    try api.load(l, prelude ++ property, "=property");
    if (!api.pcall(l, 0, 0)) {
        const msg = api.errorMessage(l, l.stack[l.top - 1]);
        std.debug.print("input: {any}\n{s}\n", .{ input, msg });
        return error.PropertyFailed;
    }
}

/// Helpers every property shares. `same` compares two values deeply, and
/// `veq` compares the bytes of two vectors.
const prelude =
    \\local function fail(...) local t = { ... } for i = 1, select("#", ...) do t[i] = tostring(t[i]) end error("PROPERTY: " .. table.concat(t, " "), 0) end
    \\local function same(a, b)
    \\    if a == b then return true end
    \\    if a ~= a and b ~= b then return true end
    \\    if type(a) ~= "table" or type(b) ~= "table" then return false end
    \\    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    \\    for k in pairs(b) do if a[k] == nil then return false end end
    \\    return true
    \\end
    \\local function veq(a, b)
    \\    if vector.size(a) ~= vector.size(b) then return false end
    \\    for i = 0, vector.size(a) - 1 do if vector.get(a, i) ~= vector.get(b, i) then return false end end
    \\    return true
    \\end
    \\
;

fn target(comptime property: []const u8, comptime corpus: []const []const u8) type {
    return struct {
        fn one(_: void, smith: *Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const n = smith.slice(&buf);
            try check(property, buf[0..n]);
        }
        fn run() !void {
            try std.testing.fuzz({}, one, .{ .corpus = corpus });
        }
    };
}

// A JSON text that parses formats to a text that parses again to a value
// that formats the same way.
const json = target(
    \\local ok, v = catch fromjson(S)
    \\if ok then
    \\    local ok2, t = catch tojson(v)
    \\    if ok2 then
    \\        local ok3, v2 = catch fromjson(t)
    \\        if not ok3 then fail("tojson output does not parse:", t, v2) end
    \\        -- tojson writes null in every hole of an array, and the decimal
    \\        -- keys of a sparse table as strings, so its output parses back to
    \\        -- a value that formats to the same text. An empty object and a
    \\        -- trailing null have no key, so v itself may differ from v2.
    \\        local t2 = tojson(v2)
    \\        if t2 ~= t then fail("round trip changed", t, "to", t2) end
    \\    end
    \\    local ok4, pretty = catch tojson(v, { indent = 2 })
    \\    if ok4 and ok2 then
    \\        local ok5, v3 = catch fromjson(pretty)
    \\        if not ok5 or tojson(v3) ~= tojson(fromjson(t)) then fail("indented output differs", t, pretty) end
    \\    end
    \\end
, &.{ "{\"a\":[1,2.5,-3e10,true,null,\"x\\u00e9\\ud83d\\ude00\"]}", "[[],{},\"\",0,-0,1e400]", "\"\\ud800\"", "12345678901234567890", "{\"a\":1,\"a\":2}", " [1 , 2 ] ", "1.0", "-0.0", "[1e-400]" });

// CSV that parses formats to CSV that parses to the same rows.
const csv = target(
    \\local ok, rows = catch fromcsv(S)
    \\if ok then
    \\    local ok2, t = catch tocsv(rows)
    \\    if ok2 then
    \\        local ok3, rows2 = catch fromcsv(t)
    \\        if not ok3 then fail("tocsv output does not parse:", t, rows2) end
    \\        if not same(rows, rows2) then fail("round trip changed the rows of", S, "into", t) end
    \\        if tocsv(rows2) ~= t then fail("tocsv is not stable for", t) end
    \\    end
    \\end
, &.{ "a,b\n1,\"x\"\"y\"\n", "\"a\nb\",c\r\n,\n", ",,,\n\n\"\"", "a;b\tc", "\"unterminated", "x\r\ny\rz\n" });

// A pattern that compiles finds, matches, and substitutes consistently,
// and substituting every match by itself leaves the subject unchanged.
const patterns = target(
    \\local subject = B:sub(1, 64)
    \\local okf, i, j = catch string.find(subject, A)
    \\local okm, m = catch string.match(subject, A)
    \\local okg, r = catch string.gsub(subject, A, "%0")
    \\-- As in Lua, find searches plainly for a pattern without special
    \\-- characters, and gsub with "%0" never reads the captures, so the three
    \\-- disagree on some invalid patterns. They must agree when all succeed.
    \\if okf and okm and okg then
    \\    if (i == nil) ~= (m == nil) then fail("find and match disagree on", A, subject) end
    \\    if r ~= subject then fail("gsub with %0 changed", subject, "to", r, "for", A) end
    \\    if i and (i < 1 or j < i - 1 or j > #subject) then fail("find returned", i, j, "for", A, subject) end
    \\    -- gmatch reads a leading ^ as a character, so it may reach a part of
    \\    -- the pattern that the anchored search never reached, and raise.
    \\    local n = 0
    \\    local okm2, e = catch (function() for _ in string.gmatch(subject, A) do n = n + 1 if n > #subject + 1 then fail("gmatch did not end for", A) end end end)()
    \\    if not okm2 and tostring(e):find("PROPERTY") then error(e, 0) end
    \\end
    \\catch string.gsub(subject, A, B)
    \\catch string.find(subject, A, -3, false)
, &.{ "\x05%a+hello world", "\x03(.-)abc", "\x04[%w_]+x_y z", "\x02%bxyxxyy", "\x06%f[%w]%w+ab cd", "\x01^$", "\x08(a*(b))%1aabb", "\x03[^]]x]]", "\x04%g+é ü" });

// Formatting with any format string never crashes.
const format = target(
    \\catch string.format(S, 1, -2.5, "x", 12n, 1.25d, true, nil, 0/0, math.mininteger, "é")
    \\catch string.format(S, math.huge, -math.huge, 2^63, -0.0)
    \\catch string.format(S)
, &.{ "%d %5.2f %s %x %q %g", "%-10s|%+5d|%#x|%o|%e|%a|%c", "%.99f", "%99999d", "%q%q%q%q", "%i%u", "%%%", "%5.3s" });

// Numbers parse to values that print and parse back to themselves.
const numbers = target(
    \\local n = tonumber(S)
    \\-- As in Lua, an infinity prints as inf, which tonumber does not read.
    \\if n and n == n and n ~= math.huge and n ~= -math.huge then
    \\    local n2 = tonumber(tostring(n))
    \\    if n2 ~= n or math.type(n2) ~= math.type(n) then fail("tonumber does not read back", S, tostring(n), tostring(n2)) end
    \\end
    \\local okb, b = catch bigint(S)
    \\if okb and b then
    \\    if bigint(tostring(b)) ~= b then fail("bigint does not read back", S, tostring(b)) end
    \\    if (b + 1n) - 1n ~= b or b * 1n ~= b or -(-b) ~= b then fail("bigint identities fail for", tostring(b)) end
    \\    if b ~= 0n and (b // b ~= 1n or b % b ~= 0n) then fail("bigint division fails for", tostring(b)) end
    \\end
    \\local okd, d = catch decimal(S)
    \\-- A numeral past the limits of a decimal raises at once, so every value
    \\-- that parses takes part in the arithmetic.
    \\if okd and d then
    \\    local d2 = decimal(tostring(d))
    \\    if d2 ~= d or tostring(d2) ~= tostring(d) then fail("decimal does not read back", S, tostring(d), tostring(d2)) end
    \\    if d + 0d ~= d or d * 1d ~= d or -(-d) ~= d then fail("decimal identities fail for", tostring(d)) end
    \\end
    \\for base = 2, 36, 7 do catch tonumber(S, base) end
    \\catch math.tointeger(S)
    \\catch (S + 0)
, &.{ "12345678901234567890", "-0x7fffffffffffffff", "1e308", "0x1p-1074", "1.50", "-0.000", "1e-400", "  42  ", "0x", "1_000", "9223372036854775808", "-9223372036854775809", "123456789012345678901234567890.123456789", "nan", "inf", "1e9999", "1e9999999", "1e-9999999", "1e131071", "1e-16383" });

// Parsing times with any pattern never crashes, and a parsed time formats.
const time = target(
    \\local ok, t = catch time.parse(B, A)
    \\if ok and t then catch tostring(t) end
    \\local ok2, t2 = catch time.parse(S)
    \\if ok2 and t2 then
    \\    local ok3, s = catch tostring(t2)
    \\    if ok3 and type(s) == "string" then
    \\        local ok4, t3 = catch time.parse(s)
    \\        if ok4 and t3 and tostring(t3) ~= s then fail("time does not read back", S, s, tostring(t3)) end
    \\    end
    \\end
, &.{ "\x09%Y-%m-%d2024-01-02", "2024-02-30T25:61:61Z", "\x0c%H:%M:%S %z12:34:56 +0530", "1970-01-01T00:00:00.123456789+14:00", "\x02%s123456", "-0001-12-31", "2024-W01-1" });

// Binary layouts with any format never crash, and packing then unpacking
// returns the packed values.
const pack = target(
    \\catch string.packsize(A)
    \\catch string.unpack(A, V)
    \\catch string.unpack(A, B, 2)
    \\local ok, packed = catch string.pack(A, 1, 2, 3, 4, 5)
    \\if ok then
    \\    local ok2, a, b = catch string.unpack(A, packed)
    \\    if not ok2 then fail("unpack fails on what pack made:", A, a) end
    \\end
    \\catch vector.unpack(V, 0, A)
    \\catch vector.pack(vector.create(16), 0, A, 1, 2.5, "s")
, &.{ "\x04<i4>I2z", "\x03=!4bhjn", "\x02s1s2", "\x03Xi4i8", "\x05i16 j", "\x01!17" });

// Decompressing any bytes never crashes, and every codec gives back what
// it compressed.
const archive = target(
    \\for _, name in ipairs({ "zstd", "gzip", "deflate", "brotli", "lz4" }) do
    \\    local codec = vector.archive[name]
    \\    catch codec.decompress(V)
    \\    local ok, c = catch codec.compress(V)
    \\    if ok then
    \\        local ok2, d = catch codec.decompress(c)
    \\        if not ok2 then fail(name, "cannot decompress its own output:", d) end
    \\        if not veq(d, V) then fail(name, "round trip changed the bytes") end
    \\    end
    \\end
, &.{ "hello hello hello hello", "", "\x28\xb5\x2f\xfd\x00\x58\x00\x00", "\x1f\x8b\x08\x00\x00\x00\x00\x00", "\x04\x22\x4d\x18\x64\x40\xa7" });

// Strings keep the invariants of character indexing on any text.
const strings = target(
    \\local n = #S
    \\local count = 0
    \\for _ in utf8.codes(S, true) do count = count + 1 end
    \\if count ~= n then fail("#s is", n, "but utf8.codes counts", count) end
    \\local i = #A % (n + 1) + 1
    \\local j = #B % (n + 1)
    \\if S:sub(1, j) .. S:sub(j + 1) ~= S then fail("sub does not split at", j) end
    \\if S:sub(i, j) ~= S[i, j] and i >= 1 and j >= i then fail("slice and sub differ at", i, j) end
    \\if #S:upper() ~= n or #S:lower() ~= n and false then fail("case changed the length") end
    \\-- Reversing puts a lone trail surrogate before a lone lead surrogate
    \\-- into the order that joins them, so only text without lone
    \\-- surrogates reverses back to itself.
    \\if #S:reverse() > n then fail("reverse made the string longer") end
    \\if utf8.len(S) and S:reverse():reverse() ~= S then fail("reverse is not an involution") end
    \\if S:rep(3, A) ~= S .. A .. S .. A .. S then fail("rep with a separator is wrong") end
    \\if vector.tostring(vector.fromstring(S)) ~= S then fail("vector round trip changed the string") end
    \\catch utf8.len(S) catch utf8.offset(S, i) catch utf8.codepoint(S, 1, -1)
, &.{ "\x03héllo wörld", "\xed\xa0\x80abc", "日本語のテキスト", "\x00\x01\x02", "😀😀a", "\x05aAzZ" });

test "fuzz: JSON round trips" {
    try json.run();
}
test "fuzz: CSV round trips" {
    try csv.run();
}
test "fuzz: patterns find, match, and substitute consistently" {
    try patterns.run();
}
test "fuzz: string.format never crashes" {
    try format.run();
}
test "fuzz: numbers read back" {
    try numbers.run();
}
test "fuzz: time.parse never crashes and times read back" {
    try time.run();
}
test "fuzz: binary layouts never crash" {
    try pack.run();
}
test "fuzz: archive codecs round trip" {
    try archive.run();
}
test "fuzz: strings keep the invariants of character indexing" {
    try strings.run();
}
