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
