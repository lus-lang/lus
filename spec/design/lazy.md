# Lazy variables

_Status: implemented._

A _lazy variable_ is a local variable declared with the `<lazy>` attribute. Its initializer runs on the first read of the variable, which stores the value for every later read. A program declares an expensive value at the top of a file or a function, then pays for it only on the paths that use it.

```lus nocheck
local config <lazy> = fromjson(io.open("config.json"):read("a"))

local function serve(port)
    listen(port or config.port)   -- reads the file here, once
end
```

## 1. Semantics

The declaration `local x <lazy> = EXP` evaluates nothing. It creates `x` in the _pending_ state. The first read of `x` evaluates `EXP`, stores the value in `x`, and returns it. Every later read returns the stored value. A read is any use of the variable as a value: an operand, an argument, a field access, an interpolation, a `return`, or a capture that a nested function reads.

`EXP` sees the variables of the declaration's scope as a function body written at the same place sees them, so it reads their values at the time of the first read. The following code prints `20`, because `n` is 2 when `x` is first read.

```lus nocheck
local n = 1
local x <lazy> = n * 10
n = 2
print(x)   --> 20
```

A `<lazy>` declaration names one variable and has one expression. `EXP` is truncated to one value, as in any single assignment.

## 2. A lazy variable is read-only

A lazy variable keeps the value of its first read, so `<lazy>` implies `<const>`. An assignment to a lazy variable raises `attempt to assign to const variable 'x'` at compile time, in the declaring function and in nested functions alike. Writing `<const, lazy>` is accepted and means the same. A lazy variable is never known at compile time, so a `<meta>` initializer cannot read it (`meta.md`, section 2).

An expensive default puts the choice inside the initializer, so the default is computed only when no other value was given and the variable is read.

```lus nocheck
local cache_dir <lazy> = options.cache or find_default_cache_dir()   -- scans the disk only if needed
```

## 3. Other attributes and groups

`<lazy>` belongs with `<const>` and `<close>` at the start of the attribute list, in any order among them and before every runtime attribute, as in `local port <lazy, only "number"> = read_port()`. A runtime attribute runs when the initializer produces the value, as it runs for the initialization of an ordinary variable.

`<lazy, close>` declares a to-be-closed variable that opens its resource on first use. At the end of the scope, the variable is closed if it was read. A variable that is still pending is not closed.

```lus nocheck
local db <lazy, close> = sqlite.open("cache.db")
if request.cached then
    return db:query(request.key)   -- opens the database here
end
```

A field of a local group may be lazy, because each field is a local variable. `local stats <group> = { count = #rows, median <lazy> = table.median(rows) }` computes the median only if `stats.median` is read. Copying the group or destructuring it with `from` reads the field. A lazy field cannot be combined with runtime attributes of its group.

`<lazy>` applies to a `local` statement that names one variable and to a field of a local group. Every other declaration rejects it with `cannot use <lazy> in this declaration`: `from` destructuring, assignment conditions, and loop variables. A global declaration rejects it with `global variables cannot be <lazy>`.

A global cannot be lazy. `global x <lazy>` is a compile error, because a global is a field of the global table and a read of it is a table access. A value that a whole file shares lazily is a lazy local at the top of the file.

## 4. Errors and recursion

If `EXP` raises an error, the read raises that error as any expression would. Nothing is stored, so the variable stays pending and the next read evaluates `EXP` again. A configuration file that was missing on the first read is therefore read again once it exists.

While `EXP` runs, the variable is in the _evaluating_ state. A read of the variable from the same coroutine during that time raises `lazy variable 'x' read during its own initialization`, which turns an infinite recursion into an error at the read that causes it.

## 5. Coroutines

`EXP` may yield, which a socket read in a detached coroutine does. Another coroutine may then read the variable while it is evaluating, because a nested function that captured it is shared. A detached coroutine that reads an evaluating variable gives the other coroutines their turns until the evaluation ends, then reads the stored value, or computes the value itself if the evaluation raised an error. Any other coroutine raises `lazy variable 'x' read while another coroutine computes it`, because it has no scheduler to wait on. Workers run in separate states and never share a variable.

## 6. Debugging

The value of a lazy variable lives in a hidden local named `(lazy x)`, which holds `nil` until the first read. `debug.getlocal` and `lus debug` list that local and never evaluate the variable, so a debugger never changes when an initializer runs.

## 7. Implementation and cost

The compiler rewrites a lazy local into hidden locals and one force function, so the interpreter and the JIT tiers run it with their existing instructions. For `local x <lazy> = EXP` it declares:

- `(lazy x)`, the value that reads see, starting as `nil`,
- `(lazy force x)`, the force function,
- `(lazy state x)` and `(lazy cache x)`, which only the force function captures: the state is 1 while the value is pending, 0 once it is computed, or the thread computing it, and the cache holds the computed value.

The force function waits while another thread computes the value, raises an error when the computing thread is the caller, then marks the state with the running thread, evaluates `EXP` under `catch`, applies the runtime attributes, and stores the value in the cache. On an error it resets the state to pending and raises the error object again. A read of `x` compiles to a test of `(lazy force x)`. While it is set, the read calls it, stores the result in `(lazy x)`, and clears it. Then the read takes `(lazy x)`. The waiting, the running thread, and the rethrow are natives that compiled code reaches as builtin constants, which binary chunks store by number, so they work under any `_ENV`.

`tests/bench/lazy.lus` reads a lazy local twenty million times in a loop and compares it with an ordinary local. The ratios below are the lazy time over the ordinary time, measured with a ReleaseFast build on an Apple silicon Mac.

| case | interpreter | baseline JIT | both tiers |
| --- | ---: | ---: | ---: |
| local, first read inside the loop | 1.08 | 1.90 | 4.37 |
| local, first read before the loop | 1.06 | 1.06 | 1.51 |
| upvalue, first read before the loop | 1.32 | 1.34 | 1.71 |

The first row shows a property of the JIT rather than of lazy variables: a call that runs once inside a hot loop leaves that loop about four times slower under both tiers, and a plain loop that calls a function on its first pass shows the same 0.038 seconds against 0.010. A fix in the JIT brings the first row to the second. The test that remains costs a branch in the interpreter and the baseline tier. The optimizing tier keeps it because the loop body still holds the store that clears the force function.

Executing a `<lazy>` declaration creates the force function and its captured state, about 40 ns in the same build. Lazy variables belong in setup code that runs once, such as the top of a file.
