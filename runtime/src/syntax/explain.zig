//! The long explanations of the diagnostic codes, which
//! `lus check --explain CODE` prints. Each entry has a paragraph that says
//! why the code matters and how to resolve it, a flagged example that
//! reports the code, and a fixed example that reports nothing. The tests
//! below lint every example, so an explanation cannot drift from what
//! `lint` reports.

const std = @import("std");
const lint = @import("lint.zig");

pub const Explanation = struct {
    code: []const u8,
    /// One or more paragraphs, separated by a blank line. `write` wraps
    /// each paragraph.
    text: []const u8,
    /// Source that reports `code`. Empty for a code without an example.
    flagged: []const u8 = "",
    /// The same program in a form that reports nothing.
    fixed: []const u8 = "",
};

/// The codes `lus check` reports itself, beside the codes of `lint`.
pub const check_codes = [_]struct { code: []const u8, severity: lint.Severity, summary: []const u8 }{
    .{ .code = "syntax", .severity = .@"error", .summary = "The file does not parse." },
    .{ .code = "compile", .severity = .@"error", .summary = "The compiler rejects the file for another reason." },
};

pub const all = [_]Explanation{
    .{
        .code = "syntax",
        .text = "The parser stops at the first error in a file, so `lus check` reports nothing else for that file until the error is fixed. The message names the token where parsing failed, which often follows the real mistake. An unclosed parenthesis is reported at the end of the file. A missing `end` is reported at the next statement that cannot continue the block.",
    },
    .{
        .code = "compile",
        .text = "The file parses, but the compiler rejects it with an error that no lint code covers, such as a limit on the number of locals or upvalues of one function, or a `<meta>` initializer that raises. Running the file reports the same message.",
    },
    .{
        .code = "unused-local",
        .text = "A local that no code reads is usually left over from an edit, or a sign that a later line reads another variable by mistake. Delete the declaration or use the value.\n\nStart the name of a local with `_` when its value is deliberately unused. Such a local is never reported.",
        .flagged =
        \\global print
        \\local function area(width, height)
        \\    local perimeter = 2 * (width + height)
        \\    return width * height
        \\end
        \\print(area(2, 3))
        ,
        .fixed =
        \\global print
        \\local function area(width, height)
        \\    return width * height
        \\end
        \\print(area(2, 3))
        ,
    },
    .{
        .code = "unused-function",
        .text = "A local function that nothing calls or passes on is dead code. Delete it, or call it where it was meant to run. A function whose name starts with `_` is never reported.",
        .flagged =
        \\global print
        \\local function double(x)
        \\    return x * 2
        \\end
        \\print(21)
        ,
        .fixed =
        \\global print
        \\local function double(x)
        \\    return x * 2
        \\end
        \\print(double(21))
        ,
    },
    .{
        .code = "unused-param",
        .text = "A parameter that the body never reads usually means the body reads the wrong name, or that the parameter can be removed. When the signature is fixed, as for a callback, start the name with `_` to mark the parameter as deliberately unused. The parameter `self` is never reported.",
        .flagged =
        \\global print
        \\local function handle(event, payload)
        \\    return payload.id
        \\end
        \\print(handle("open", { id = 1 }))
        ,
        .fixed =
        \\global print
        \\local function handle(_event, payload)
        \\    return payload.id
        \\end
        \\print(handle("open", { id = 1 }))
        ,
    },
    .{
        .code = "unused-loop-var",
        .text = "Name a loop variable that the body never reads `_`, the name for a value the code ignores.",
        .flagged =
        \\global ipairs, print
        \\for i, name in ipairs({ "Ada", "Grace" }) do
        \\    print(name)
        \\end
        ,
        .fixed =
        \\global ipairs, print
        \\for _, name in ipairs({ "Ada", "Grace" }) do
        \\    print(name)
        \\end
        ,
    },
    .{
        .code = "unused-label",
        .text = "A label that no `goto` names is left over from an edit. Delete it. `continue` covers the most common use of a label at the end of a loop body.",
        .flagged =
        \\global print
        \\for i = 1, 3 do
        \\    print(i)
        \\    ::next::
        \\end
        ,
        .fixed =
        \\global print
        \\for i = 1, 3 do
        \\    print(i)
        \\end
        ,
    },
    .{
        .code = "shadowed-local",
        .text = "A local that hides a visible local of the same name makes the outer one unreachable for the rest of the scope, so an edit that meant to read the outer variable reads the inner one. Rename one of them. A name that starts with `_` is never reported.",
        .flagged =
        \\global print
        \\local count = 0
        \\local function bump(count)
        \\    return count + 1
        \\end
        \\print(bump(count))
        ,
        .fixed =
        \\global print
        \\local count = 0
        \\local function bump(n)
        \\    return n + 1
        \\end
        \\print(bump(count))
        ,
    },
    .{
        .code = "undefined-global",
        .text = "A free name that the file never assigns and the runtime does not define reads as `nil` at run time, which usually means a misspelled local. Correct the name. When another chunk defines the global, declare it with `global NAME` at the top of the file, which also turns every other free name into a compile error. Lus writes the absent value as `nil`, so a read of `null` is reported with a reminder.",
        .flagged =
        \\local items = { 1, 2, 3 }
        \\return #itmes
        ,
        .fixed =
        \\local items = { 1, 2, 3 }
        \\return #items
        ,
    },
    .{
        .code = "implicit-global",
        .text = "An assignment to a name that no local or `global` declaration introduces creates a global, which every chunk of the program shares. Declare the name with `global` at the top of the file when it must be global. Otherwise make it a `local`.",
        .flagged =
        \\counter = 0
        \\return counter
        ,
        .fixed =
        \\global counter
        \\counter = 0
        \\return counter
        ,
    },
    .{
        .code = "unreachable-code",
        .text = "A statement after `break`, `continue`, or `goto` in the same block never runs. Delete it, or move it before the jump. A label ends the unreachable part, because a `goto` can reach it.",
        .flagged =
        \\global print
        \\for i = 1, 3 do
        \\    if i == 2 then
        \\        break
        \\        print("stopped")
        \\    end
        \\    print(i)
        \\end
        ,
        .fixed =
        \\global print
        \\for i = 1, 3 do
        \\    if i == 2 then
        \\        print("stopped")
        \\        break
        \\    end
        \\    print(i)
        \\end
        ,
    },
    .{
        .code = "duplicate-key",
        .text = "A table constructor that sets the same constant key twice keeps the later value, so the earlier one never takes effect. This is usually a copy or merge mistake. Keep the value that was meant.",
        .flagged =
        \\global print
        \\local options = { timeout = 5, retries = 3, timeout = 10 }
        \\print(options)
        ,
        .fixed =
        \\global print
        \\local options = { timeout = 10, retries = 3 }
        \\print(options)
        ,
    },
    .{
        .code = "self-assign",
        .text = "An assignment of a variable or field to itself changes nothing unless a metamethod runs, which usually means the right side names the wrong variable.",
        .flagged =
        \\global print
        \\local function move(point, dx)
        \\    point.x = point.x
        \\    return point, dx
        \\end
        \\print(move({ x = 1 }, 2))
        ,
        .fixed =
        \\global print
        \\local function move(point, dx)
        \\    point.x = point.x + dx
        \\    return point
        \\end
        \\print(move({ x = 1 }, 2))
        ,
    },
    .{
        .code = "deprecated-pcall",
        .text = "Lus catches errors with the `catch` expression, which evaluates its operand and returns `true` followed by the results, or `false` followed by the error object. `catch[handler] f()` passes the error object to `handler` first, which takes the place of the message handler of `xpcall`. The names `pcall` and `xpcall` are not defined.",
        .flagged =
        \\local ok, err = pcall(error, "boom")
        \\return ok, err
        ,
        .fixed =
        \\global error
        \\local ok, err = catch error("boom")
        \\return ok, err
        ,
    },
    .{
        .code = "pledge-after-seal",
        .text = "`pledge(\"seal\")` freezes the permissions of the program, so a later call of `pledge` grants nothing. Request every permission before the seal.",
        .flagged =
        \\global pledge
        \\pledge("fs:read")
        \\pledge("seal")
        \\pledge("network")
        ,
        .fixed =
        \\global pledge
        \\pledge("fs:read", "network")
        \\pledge("seal")
        ,
    },
    .{
        .code = "use-from",
        .text = "Locals that copy fields of one table under the same names can be declared with `from`, which reads each name as a field of the source.",
        .flagged =
        \\global print, config
        \\local host, port = config.host, config.port
        \\print(host, port)
        ,
        .fixed =
        \\global print, config
        \\local host, port from config
        \\print(host, port)
        ,
    },
    .{
        .code = "use-optional-chain",
        .text = "A chain of `and` tests or nested `if` statements that guards each step of a field access against `nil` can be written with optional chaining. Each `?.` step yields `nil` when the value before it is `nil`.",
        .flagged =
        \\global print, config
        \\local url = config and config.db and config.db.url
        \\print(url)
        ,
        .fixed =
        \\global print, config
        \\local url = config?.db?.url
        \\print(url)
        ,
    },
    .{
        .code = "use-if-assign",
        .text = "A local that exists only to be tested by the next `if` can be declared in the condition, which limits its scope to the `if` statement.",
        .flagged =
        \\global print, config
        \\local found = config.find()
        \\if found then
        \\    print(found)
        \\end
        ,
        .fixed =
        \\global print, config
        \\if found = config.find() then
        \\    print(found)
        \\end
        ,
    },
    .{
        .code = "use-interpolation",
        .text = "A chain of three or more concatenations that mixes literals and values is shorter as a string with interpolation, where `$name` and `$(expression)` insert values.",
        .flagged =
        \\global print
        \\local count = 3
        \\print("total: " .. count .. " items")
        ,
        .fixed =
        \\global print
        \\local count = 3
        \\print(`total: $count items`)
        ,
    },
    .{
        .code = "use-for-from",
        .text = "A generic `for` whose body starts by copying fields of its only loop variable into locals of the same names can name those fields in the loop header with `for ... from`, which reads them from each record directly.",
        .flagged =
        \\global print, records
        \\for r in records do
        \\    local name, age = r.name, r.age
        \\    print(name, age)
        \\end
        ,
        .fixed =
        \\global print, records
        \\for name, age from records do
        \\    print(name, age)
        \\end
        ,
    },
    .{
        .code = "concat-in-loop",
        .text = "A string that grows by `..` in a loop is copied in full on every pass, so the loop takes time quadratic in the length of the result. Collect the parts in a list and join them once with `table.concat`. On 20000 passes the joined form is about 100 times faster (`spec/design/hints.md`).",
        .flagged =
        \\global ipairs, print
        \\local text = ""
        \\for _, line in ipairs({ "a", "b" }) do
        \\    text = text .. line .. "\n"
        \\end
        \\print(text)
        ,
        .fixed =
        \\global ipairs, print, table
        \\local parts = {}
        \\for _, line in ipairs({ "a", "b" }) do
        \\    parts[#parts + 1] = line
        \\end
        \\print(table.concat(parts, "\n"))
        ,
    },
    .{
        .code = "insert-front-in-loop",
        .text = "`table.insert(t, 1, v)` moves every element of `t` up by one, so a loop of such inserts takes time quadratic in the length of the list. Append instead and reverse the list once, or walk the source backwards.",
        .flagged =
        \\global ipairs, print, table
        \\local out = {}
        \\for _, item in ipairs({ 1, 2, 3 }) do
        \\    table.insert(out, 1, item)
        \\end
        \\print(out)
        ,
        .fixed =
        \\global print
        \\local items = { 1, 2, 3 }
        \\local out = {}
        \\for i = #items, 1, -1 do
        \\    out[#out + 1] = items[i]
        \\end
        \\print(out)
        ,
    },
    .{
        .code = "closure-in-loop",
        .text = "A function expression in a loop creates a new function on every pass. When it captures nothing that the loop declares, every pass creates the same function, so create it once before the loop.",
        .flagged =
        \\global print
        \\local list = {}
        \\for i = 1, 3 do
        \\    list[i] = function(x) return x * 2 end
        \\end
        \\print(list)
        ,
        .fixed =
        \\global print
        \\local function double(x) return x * 2 end
        \\local list = {}
        \\for i = 1, 3 do
        \\    list[i] = double
        \\end
        \\print(list)
        ,
    },
    .{
        .code = "select-in-loop",
        .text = "`select(i, ...)` copies the arguments from position `i` on every call, so a loop over the arguments takes quadratic time. Pack them once with `table.pack(...)` and index the result, whose field `n` holds the count.",
        .flagged =
        \\global print, select
        \\local function sum(...)
        \\    local total = 0
        \\    for i = 1, select("#", ...) do
        \\        total = total + select(i, ...)
        \\    end
        \\    return total
        \\end
        \\print(sum(1, 2, 3))
        ,
        .fixed =
        \\global print, table
        \\local function sum(...)
        \\    local args = table.pack(...)
        \\    local total = 0
        \\    for i = 1, args.n do
        \\        total = total + args[i]
        \\    end
        \\    return total
        \\end
        \\print(sum(1, 2, 3))
        ,
    },
    .{
        .code = "table-to-group",
        .text = "A table built from named fields that never leaves its function can be a local group, declared with `<group>`, which keeps each field in a local of its own, so the function allocates no table.",
        .flagged =
        \\global ipairs, print
        \\local function centroid(points)
        \\    local acc = { x = 0, y = 0 }
        \\    for _, p in ipairs(points) do
        \\        acc.x = acc.x + p.x
        \\        acc.y = acc.y + p.y
        \\    end
        \\    return acc.x / #points, acc.y / #points
        \\end
        \\print(centroid({ { x = 1, y = 2 } }))
        ,
        .fixed =
        \\global ipairs, print
        \\local function centroid(points)
        \\    local acc <group> = { x = 0, y = 0 }
        \\    for _, p in ipairs(points) do
        \\        acc.x = acc.x + p.x
        \\        acc.y = acc.y + p.y
        \\    end
        \\    return acc.x / #points, acc.y / #points
        \\end
        \\print(centroid({ { x = 1, y = 2 } }))
        ,
    },
    .{
        .code = "pairs-over-list",
        .text = "`pairs` over a table built as a list visits its elements in an unspecified order. `ipairs` visits them in order and is about 1.3 times as fast on the case measured in `spec/design/hints.md`.",
        .flagged =
        \\global pairs, print
        \\local list = { 3, 5 }
        \\list[#list + 1] = 8
        \\for _, v in pairs(list) do
        \\    print(v)
        \\end
        ,
        .fixed =
        \\global ipairs, print
        \\local list = { 3, 5 }
        \\list[#list + 1] = 8
        \\for _, v in ipairs(list) do
        \\    print(v)
        \\end
        ,
    },
    .{
        .code = "format-to-interpolation",
        .text = "A `string.format` whose format holds only literal text and `%s` writes the same string as a string with interpolation, which is about 1.5 times as fast on the case measured in `spec/design/hints.md`. Formats with other conversions, such as `%d`, are not reported, because `%d` raises an error for a float where interpolation writes it.",
        .flagged =
        \\global print, string
        \\local name, count = "list", 3
        \\print(string.format("%s has %s", name, count))
        ,
        .fixed =
        \\global print
        \\local name, count = "list", 3
        \\print(`$name has $count`)
        ,
    },
    .{
        .code = "redundant-tostring",
        .text = "Concatenation converts a number to text itself, so `tostring` around a number that is an operand of `..` does the same work twice. The code is reported only where the operand is known to be a number, because `..` raises an error for a table or `nil`.",
        .flagged =
        \\global print, tostring
        \\for i = 1, 3 do
        \\    print("item " .. tostring(i))
        \\end
        ,
        .fixed =
        \\global print
        \\for i = 1, 3 do
        \\    print("item " .. i)
        \\end
        ,
    },
    .{
        .code = "doc-unknown-param",
        .text = "A doc comment that documents a parameter the function does not have usually holds a misspelled or renamed parameter, which `lus doc` and the language server then show wrongly. Make the `@param` name match the parameter.",
        .flagged =
        \\--- Returns the area of a rectangle.
        \\--- @param width number The width.
        \\--- @param hieght number The height.
        \\local function area(width, height)
        \\    return width * height
        \\end
        \\return area
        ,
        .fixed =
        \\--- Returns the area of a rectangle.
        \\--- @param width number The width.
        \\--- @param height number The height.
        \\local function area(width, height)
        \\    return width * height
        \\end
        \\return area
        ,
    },
    .{
        .code = "package-flag",
        .text = "A package reads only the compile-time flags that its header declares with `@flag`, which lists them for the users of the package and for `lus doc`. Declare the flag or stop reading it.",
        .flagged =
        \\--- Formats dates.
        \\--- @package dates
        \\--- @version 1.0.0
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\--- @flag strict boolean Reject unknown fields.
        \\
        \\global flags
        \\return { strict = flags.strict, loud = flags.loud }
        ,
        .fixed =
        \\--- Formats dates.
        \\--- @package dates
        \\--- @version 1.0.0
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\--- @flag strict boolean Reject unknown fields.
        \\--- @flag loud boolean Print each step.
        \\
        \\global flags
        \\return { strict = flags.strict, loud = flags.loud }
        ,
    },
    .{
        .code = "package-pledge",
        .text = "A package runs with the permissions that the program requiring it grants and seals. A package therefore declares each permission it needs with `@permission` in its header and leaves the calls of `pledge` to the program.",
        .flagged =
        \\--- Reads settings files.
        \\--- @package settings
        \\--- @version 1.0.0
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\
        \\global pledge
        \\pledge("fs:read")
        \\return {}
        ,
        .fixed =
        \\--- Reads settings files.
        \\--- @package settings
        \\--- @version 1.0.0
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\--- @permission fs:read
        \\
        \\return {}
        ,
    },
    .{
        .code = "package-header",
        .text = "The header of a package must carry `@package`, `@version`, `@lus`, and `@license`. The name is 2 to 40 characters from `a` to `z`, `0` to `9`, and `_`, and starts with a letter. The version is `MAJOR.MINOR.PATCH`. `@lus` names a line such as `2.0` or a release such as `2.0.3`. The atmosphere registry rejects a package whose header fails these checks.",
        .flagged =
        \\--- Formats dates.
        \\--- @package Dates
        \\--- @version 1.4
        \\
        \\return {}
        ,
        .fixed =
        \\--- Formats dates.
        \\--- @package dates
        \\--- @version 1.4.0
        \\--- @lus 2.0
        \\--- @license 0BSD
        \\
        \\return {}
        ,
    },
    .{
        .code = "assign-const",
        .text = "A `<const>` local, a `<close>` local, and the control variable of a numeric `for` cannot be assigned, so the compiler rejects the chunk. Declare a new local for the new value.",
        .flagged =
        \\global print
        \\local limit <const> = 10
        \\limit = 20
        \\print(limit)
        ,
        .fixed =
        \\global print
        \\local limit <const> = 10
        \\local raised = limit * 2
        \\print(raised)
        ,
    },
    .{
        .code = "undeclared-global",
        .text = "Once a file declares globals by name, every free name must appear in a `global` declaration, so a misspelled name is a compile error. Declare the name, or make it a local. `global *` declares every name.",
        .flagged =
        \\global print
        \\print(count)
        ,
        .fixed =
        \\global print
        \\local count = 3
        \\print(count)
        ,
    },
    .{
        .code = "undefined-label",
        .text = "A `goto` must name a label that is visible at the jump: one in the same block or an enclosing block of the same function. The compiler rejects the chunk otherwise. `continue` jumps to the next iteration of the innermost loop without a label.",
        .flagged =
        \\global print
        \\for i = 1, 3 do
        \\    if i == 2 then goto skip end
        \\    print(i)
        \\end
        ,
        .fixed =
        \\global print
        \\for i = 1, 3 do
        \\    if i == 2 then continue end
        \\    print(i)
        \\end
        ,
    },
    .{
        .code = "duplicate-label",
        .text = "A label must not repeat a label of the same name that is visible where it appears, so the compiler rejects the chunk. Rename one of the labels.",
        .flagged =
        \\global print
        \\local n = 0
        \\::again::
        \\n = n + 1
        \\do
        \\    ::again::
        \\    print(n)
        \\end
        \\if n < 3 then goto again end
        ,
        .fixed =
        \\global print
        \\local n = 0
        \\::again::
        \\n = n + 1
        \\print(n)
        \\if n < 3 then goto again end
        ,
    },
    .{
        .code = "continue-outside-loop",
        .text = "`continue` jumps to the next iteration of the innermost loop, so it must appear inside a loop of the same function. The compiler rejects the chunk otherwise. A function body leaves early with `return`.",
        .flagged =
        \\global print
        \\local function visit(item)
        \\    if item == nil then
        \\        continue
        \\    end
        \\    print(item)
        \\end
        \\visit(1)
        ,
        .fixed =
        \\global print
        \\local function visit(item)
        \\    if item == nil then
        \\        return
        \\    end
        \\    print(item)
        \\end
        \\visit(1)
        ,
    },
    .{
        .code = "continue-into-scope",
        .text = "The condition of a `repeat` loop sees the locals of the loop body. A `continue` that skips the declaration of such a local would leave the condition reading a variable that was never set, so the compiler rejects the chunk. Declare the local before the `continue`.",
        .flagged =
        \\local n = 0
        \\repeat
        \\    n = n + 1
        \\    if n == 1 then
        \\        continue
        \\    end
        \\    local later = n
        \\until later > 2
        ,
        .fixed =
        \\local n = 0
        \\repeat
        \\    n = n + 1
        \\    local later = n
        \\    if n == 1 then
        \\        continue
        \\    end
        \\until later > 2
        ,
    },
};

pub fn find(code: []const u8) ?*const Explanation {
    for (&all) |*e| if (std.mem.eql(u8, e.code, code)) return e;
    return null;
}

/// The severity and summary of `code`, from `lint.codes` or `check_codes`.
pub fn summary(code: []const u8) ?struct { severity: lint.Severity, summary: []const u8 } {
    for (lint.codes) |c| if (std.mem.eql(u8, c.code, code)) return .{ .severity = c.severity, .summary = c.summary };
    for (check_codes) |c| if (std.mem.eql(u8, c.code, code)) return .{ .severity = c.severity, .summary = c.summary };
    return null;
}

/// Writes `text` with each paragraph wrapped at `width` columns.
fn wrap(w: *std.Io.Writer, text: []const u8, width: usize) !void {
    var paras = std.mem.splitSequence(u8, text, "\n\n");
    var first = true;
    while (paras.next()) |p| {
        if (!first) try w.writeAll("\n");
        first = false;
        var col: usize = 0;
        var words = std.mem.tokenizeAny(u8, p, " \n");
        while (words.next()) |word| {
            if (col > 0 and col + 1 + word.len > width) {
                try w.writeAll("\n");
                col = 0;
            } else if (col > 0) {
                try w.writeAll(" ");
                col += 1;
            }
            try w.writeAll(word);
            col += word.len;
        }
        try w.writeAll("\n");
    }
}

fn indented(w: *std.Io.Writer, src: []const u8) !void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) try w.writeAll("\n") else try w.print("    {s}\n", .{line});
    }
}

/// Writes the explanation of `code`. Returns false for an unknown code.
pub fn write(w: *std.Io.Writer, code: []const u8) !bool {
    const s = summary(code) orelse return false;
    try w.print("{s} ({s})\n\n", .{ code, s.severity.label() });
    try wrap(w, s.summary, 76);
    if (find(code)) |e| {
        try w.writeAll("\n");
        try wrap(w, e.text, 76);
        if (e.flagged.len > 0) {
            try w.print("\nThis code reports {s}:\n\n", .{code});
            try indented(w, e.flagged);
            try w.writeAll("\nThis code reports nothing:\n\n");
            try indented(w, e.fixed);
        }
    }
    return true;
}

const testing = std.testing;

fn lintOf(arena: std.mem.Allocator, src: []const u8) ![]lint.Diagnostic {
    var diag: ?[]const u8 = null;
    const chunk = try @import("parser.zig").parse(testing.allocator, arena, src, .{ .chunkname = "=explain" }, &diag);
    return lint.lint(arena, chunk, .{});
}

test "every code has an explanation" {
    for (lint.codes) |c| {
        const e = find(c.code) orelse {
            std.debug.print("no explanation for {s}\n", .{c.code});
            return error.TestUnexpectedResult;
        };
        try testing.expect(e.flagged.len > 0 and e.fixed.len > 0);
    }
    for (check_codes) |c| try testing.expect(find(c.code) != null);
    for (all) |e| try testing.expect(summary(e.code) != null);
}

test "every flagged example reports its code and every fixed example reports nothing" {
    for (all) |e| {
        if (e.flagged.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var reported = false;
        for (try lintOf(arena, e.flagged)) |d| reported = reported or std.mem.eql(u8, d.code, e.code);
        if (!reported) {
            std.debug.print("the flagged example of {s} does not report it\n", .{e.code});
            return error.TestUnexpectedResult;
        }
        for (try lintOf(arena, e.fixed)) |d| {
            std.debug.print("the fixed example of {s} reports {s}: {s}\n", .{ e.code, d.code, d.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "the prose holds no dashes or semicolons" {
    for (all) |e| {
        try testing.expect(std.mem.indexOf(u8, e.text, "\u{2014}") == null);
        try testing.expect(std.mem.indexOf(u8, e.text, "\u{2013}") == null);
        try testing.expect(std.mem.indexOfScalar(u8, e.text, ';') == null);
    }
}

test write {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try write(&out.writer, "unused-local"));
    try testing.expect(std.mem.startsWith(u8, out.written(), "unused-local (warning)\n\nA local variable is never read.\n"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n        local perimeter = 2 * (width + height)\n") != null);
    try testing.expect(!try write(&out.writer, "no-such-code"));
}
