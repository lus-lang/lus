# Lus for Lua programmers

This page lists what a model trained mostly on Lua needs to write correct Lus. Everything not listed behaves as in Lua 5.5.

## Removed and replaced

| Lua | Lus |
| --- | --- |
| `pcall(f, ...)` | `catch f(...)` |
| `xpcall(f, h, ...)` | `catch[h] f(...)` |
| `os.remove(path)` | `fs.remove(path)` |
| `os.rename(a, b)` | `fs.move(a, b)` |
| C modules through `require` | native functions registered by a host through `lus.h` |
| `LUA_PATH` | `LUS_PATH` |

`lus check` flags `pcall` and `xpcall` with the code `deprecated-pcall`.

Assignment is plain `=`, as in Lua. Write `total = total + i`. Models trained on other languages often reach for `+=`, which is a syntax error.

## Errors

`catch` is an expression. It returns `true` followed by every result, or exactly `false` and the raw error object.

```lus
local function divide(a, b)
    if b == 0 then error("division by zero", 0) end
    return a / b
end

local ok, value = catch divide(1, 0)
assert(not ok and value == "division by zero")

local ok2, err = catch[function(e) return "wrapped: " .. e end] divide(1, 0)
assert(err == "wrapped: division by zero")
```

## Strings and bytes

Strings are well formed WTF-8 text, and every string function counts characters. `#"héllo"` is 5. Raw bytes live in vectors. File reads in binary mode, socket reads, `network.fetch` bodies, `string.pack`, and the compressors all return vectors. `vector.tostring(v)` decodes bytes to text and `vector.fromstring(s)` encodes text to bytes.

```lus
assert(#"héllo" == 5)
local bytes = vector.fromstring("héllo")
assert(#bytes == 6)
assert(vector.tostring(bytes) == "héllo")
```

## New syntax

```lus
-- interpolation
local name, n = "Ada", 3
assert(`$name has $(n + 1)` == "Ada has 4")
assert(`costs $$5` == "costs $5")

-- destructuring
local point = { x = 1, y = 2 }
local x, y from point
assert(x + y == 3)

-- destructuring each item of an iterator that yields tables
local function each(list)
    local i = 0
    return function()
        i = i + 1
        return list[i]
    end
end
local sum = 0
for name, price from each({ { name = "mug", price = 8 }, { name = "pot", price = 22 } }) do
    sum = sum + price
end
assert(sum == 30)

-- optional chaining
local config = { server = { port = 8080 } }
assert(config?.server?.port == 8080)
assert(config?.database?.host == nil)

-- assignment in conditions
local items = { "a", "b" }
if first = items[1] then
    assert(first == "a")
end

-- continue
local total = 0
for i = 1, 10 do
    if i % 2 == 0 then continue end
    total = total + i
end
assert(total == 25)

-- do expressions
local size = do
    if #items > 1 then provide "many" end
    provide "few"
end
assert(size == "many")

-- enums
local Color = enum Red, Green, Blue end
assert(Color.Red ~= Color.Green)

-- slices
local letters = { "a", "b", "c", "d" }
assert(#letters[2, 3] == 2)
assert(("hello")[1, 2] == "he")

-- exact numbers
assert(2n ^ 64 == 18446744073709551616n)
assert(0.1d + 0.2d == 0.3d)
```

`for a, b from iter do` needs an iterator that yields one table per pass, such as a query. Over `ipairs` or `pairs` it raises an error, because their first result is an index or a key. Write `for _, item in ipairs(list) do local a, b from item` for a plain list.

## Compile time

A _build flag_ comes from the command line, as in `lus -Fdebug -Flevel=3 app.lus`, and the program reads it from the read-only `flags` table. A flag given without a value is `true`, and a flag that was not given is `nil`. `lus build` accepts `-F` too and stores the values in the executable.

An `if` whose condition the compiler can decide compiles only the clause that is true. Such a condition reads flags, literals, and `<meta>` locals, compares them, combines them with `and`, `or`, and `not`, and may call a pure library function such as `string.find`, `string.lower`, or `math.floor` on them. Debugging code under `if flags.debug then` therefore costs nothing in a build without `-Fdebug`. A condition that reads any other value compiles as an ordinary `if`.

A `<meta>` local runs its initializer when the file is compiled, so the program starts with the finished value. The initializer sees literals, flags, the standard library, constants, and earlier `<meta>` locals, and none of the program's other variables. Its value must be data: `nil`, a boolean, a number, a string, a vector, or a table of these. A table becomes read-only.

```lus
local SQUARES <meta> = do
    local t = {}
    for i = 1, 10 do
        t[i] = i * i
    end
    provide t
end
assert(SQUARES[4] == 16)

local MODE <meta> = (flags.mode or "release"):lower()
if MODE == "debug" then
    print("debug checks on")
end
assert(MODE == "release")
```

An initializer that reads a file pledges like any chunk, and the pledge succeeds only for permissions that the command grants with `-P`. `lus check` and `lus fmt` never run initializers.

## Values computed on first use

A `<lazy>` local runs its initializer the first time the program reads it, and later reads return the same value. A lazy local that is never read never runs its initializer, so an expensive default costs nothing in the runs that skip it. The initializer sees other variables as they are at the first read, as code in a function does. A lazy local is read-only like `<const>`. If the initializer raises an error, that read raises it, and the next read runs the initializer again.

```lus
local loads = 0
local function load_settings()
    loads = loads + 1
    return { port = 8080 }
end

local settings <lazy> = load_settings()
assert(loads == 0)
assert(settings.port == 8080)
assert(settings.port == 8080)
assert(loads == 1)
```

`<lazy, close>` opens a resource on first use and closes it at the end of the block only if the program read it. A field of a local group can be lazy too, as in `median <lazy> = table.median(rows)`.

## Globals and permissions

A file that names its globals with a `global` declaration gets an error for every other free name, which catches typos at compile time. Write the declaration at the top of the file, then pledge.

```lus nocheck
global fs, print, pledge

pledge("fs:read")
pledge("seal")
```

`pledge("seal")` freezes the permission set. `pledge("~exec")` denies a permission for good. Permission values narrow a grant: `fs:read=/var/log/*`, `network:http=api.example.com`, `network:server=127.0.0.1:8080`.

## Modules

`require("name")` searches `LUS_PATH` and needs the `load` permission plus read access to the file. A module returns a table, as in Lua. `lus build` bundles a script and every module it requires by a literal name into one executable, and those bundled modules load without extra permissions.
