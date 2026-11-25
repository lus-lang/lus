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
    if b == 0 then
        error("division by zero", 0)
    end

    return a / b
end

local ok, value = catch divide(1, 0)
assert(not ok and value == "division by zero")

local ok2, err = catch[function(e)
    return "wrapped: " .. e
end] divide(1, 0)

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
assert(`tab\there \$x \u{48}` == "tab\there $x H")

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
    if i % 2 == 0 then
        continue
    end

    total = total + i
end

assert(total == 25)

-- do expressions
local size = do
    if #items > 1 then
        provide "many"
    end

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

## Values that follow other values

An `<observe>` local whose initializer names other `<observe>` locals is _derived_ from them. Each assignment to one of those sources computes every derived local again from its initializer, once each, in declaration order. An assignment from a nested function, such as a callback, updates them too. A derived local is read-only.

```lus
local price <observe> = 12
local quantity <observe> = 1
local total <observe> = price * quantity
local label <observe> = `total: $total`

local function add_one()
    quantity = quantity + 1
end

add_one()
assert(label == "total: 24")
price = 10
assert(label == "total: 20")
```

Only an assignment to the variable starts an update. A write to a field of a table that a source holds, such as `cart[3] = x`, updates nothing, so assign a new table instead. Other variables an initializer reads are inputs that the update reads again, and a change to one of them updates nothing. If an initializer raises an error, the assignment raises it and the derived locals not yet updated keep their previous values. An assignment to an observed local while an update runs raises an error. Observed locals cannot be globals, group fields, or `<lazy>`, `<close>`, or `<meta>`.

## Values for each coroutine

A `<context>` local holds one value for each coroutine. An assignment changes the value of the running coroutine only, and a read returns the value of the running coroutine, wherever the reading function was defined. The initializer is the value of every coroutine that assigned nothing. A new coroutine starts with the values of the coroutine that creates it, so the connections of `network.serve` see the values of the coroutine that runs `serve`. A worker starts from the defaults.

```lus
local request_id <context> = "none"

local function current()
    return request_id
end

local co = coroutine.create(function(id)
    request_id = id
    coroutine.yield(current())
    return current()
end)

assert(select(2, coroutine.resume(co, "r1")) == "r1")
assert(current() == "none")
assert(select(2, coroutine.resume(co)) == "r1")
```

`<context>` combines with no other attribute, and globals and group fields cannot be context variables. `debug.getcontext(co, n)` returns the name and value of variable number `n` as coroutine `co` sees it, and `debug.setcontext(co, n, value)` assigns it.

## Failures and waits

A failed socket operation returns `nil` and an error object, a table with the fields `code` and `message`, and `status` for HTTP failures. Its `__tostring` gives the message. A bad argument, a closed socket, and a missing permission raise. A refused file read returns `nil`, a message, and the error number, as in Lua.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
server:settimeout(0.05)
local sock, err = server:accept()
assert(sock == nil and err.code == "timeout")
assert(tostring(err) == "accept timeout")
```

`network.tcp.connect` and `network.tls.connect` take `{ timeout = SECONDS }`. `sock:reader(max)` returns a coroutine that yields each received part as a vector, which `network.lines` reads line by line. `sock:starttls(options)` switches a plain connection to TLS, as the client or, with `server = true` and a certificate, as the server.

Operations that wait for an event return a coroutine, and each resume waits for the next event: `coroutine.sleep(seconds)`, `p.exit` of a process from `os.spawn`, `os.signal("interrupt", "terminate")`, and `fs.watch(path)`. Inside a detached coroutine a wait suspends only that coroutine. Closing a sleep before its time ends wakes the coroutine that waits on it with `false` and `"closed"`. A sleep of `math.huge` never ends by itself, so it parks a coroutine until another one closes the sleep.

```lus
local wake = coroutine.sleep(math.huge)
local result

local waiter = coroutine.detach(coroutine.create(function()
    result = table.pack(coroutine.resume(wake))
end))

coroutine.close(wake)
coroutine.resume(waiter)
assert(result[1] == false and result[2] == "closed")
```

## Globals and permissions

A file that names its globals with a `global` declaration gets an error for every other free name, which catches typos at compile time. Write the declaration at the top of the file, then pledge.

```lus nocheck
global fs, print, pledge

pledge("fs:read")
pledge("seal")
```

`pledge("seal")` freezes the permission set. A grant without a value covers the grants of the same permission with values, whichever comes first. `pledge("~exec")` denies a permission for good. Permission values narrow a grant: `fs:read=/var/log/*`, `network:http=api.example.com`, `network:server=127.0.0.1:8080`.

## Modules

`require("name")` searches `LUS_PATH` and needs the `load` permission plus read access to the file. A module returns a table, as in Lua. `lus build` bundles a script and every module it requires by a literal name into one executable, and those bundled modules load without extra permissions.
