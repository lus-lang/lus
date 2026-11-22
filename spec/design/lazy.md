# Lazy variables

_Status: proposal for review. Nothing in this note is implemented yet. The open questions at the end each list choices with a recommendation._

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

## 2. Assignment and `<const>`

A lazy variable without `<const>` accepts assignments. An assignment before the first read stores the value and discards the pending initializer, which then never runs. This is the use for expensive defaults: the declaration holds the default, which a value from the command line replaces before it is ever computed.

```lus nocheck
local cache_dir <lazy> = find_default_cache_dir()   -- scans the disk
if options.cache then
    cache_dir = options.cache                        -- the scan never runs
end
```

`<const, lazy>` declares a lazy variable that rejects every assignment at compile time, as `<const>` does. A lazy variable is never known at compile time, so comptime code cannot read it (`comptime.md`, section 2).

## 3. Other attributes and groups

`<lazy>` comes after `<const>` and before runtime attributes, as in `local port <const, lazy, only "number"> = read_port()`. A runtime attribute runs when the initializer produces the value, as it runs for the initialization of an ordinary variable.

`<lazy, close>` declares a to-be-closed variable that opens its resource on first use. At the end of the scope, the variable is closed if it was read. A variable that is still pending is not closed.

```lus nocheck
local db <lazy, close> = sqlite.open("cache.db")
if request.cached then
    return db:query(request.key)   -- opens the database here
end
```

A field of a local group may be lazy, because each field is a local variable. `local stats <group> = { count = #rows, median <lazy> = table.median(rows) }` computes the median only if `stats.median` is read.

A global cannot be lazy. `global x <lazy>` is a compile error, because a global is a field of the global table and a read of it is a table access. A value that a whole file shares lazily is a lazy local at the top of the file.

## 4. Errors and recursion

If `EXP` raises an error, the error propagates from the read while the variable stays pending. The next read evaluates `EXP` again. A configuration file that was missing on the first read is therefore read again once it exists.

While `EXP` runs, the variable is in the _evaluating_ state. A read of the variable from the same coroutine during that time raises `lazy variable 'x' read during its own initialization`, which turns an infinite recursion into an error at the read that causes it.

## 5. Coroutines

`EXP` may yield, which a socket read in a detached coroutine does. Another coroutine may then read the variable while it is evaluating, because a nested function that captured it is shared. A detached coroutine that reads an evaluating variable waits until the evaluation ends, then reads the stored value or retries the evaluation if it raised. Any other coroutine raises the error of section 4, because it has no scheduler to wait on. Workers run in separate states and never share a variable.

## 6. Debugging

`debug.getlocal` and `debug.getupvalue` return `nil` for a pending or evaluating variable and never evaluate it. `lus debug` shows such a variable as `<lazy, not computed>`. A debugger therefore never changes when an initializer runs.

## 7. Implementation and cost

The register or upvalue of a pending variable holds an internal value with its own tag, which points to the closure of `EXP`. The internal value never leaves the variable, because every read of a lazy variable goes through a `force` instruction that tests the tag. `force` leaves any other value in place and calls the initializer for a pending one. The compiler knows which variables are lazy from their declarations, so reads of ordinary variables run exactly as before.

A variable never returns to the pending state once it holds a value, since an assignment stores an ordinary value. The compiler therefore omits `force` on a read that an earlier forced read of the same variable in the same function precedes on every path. A loop that reads a lazy variable after a read before the loop pays no test inside the loop.

The baseline JIT compiles `force` as one tag comparison and a branch that is not taken after the first read. The optimizing tier compiles it as a guard on the tag. The guard is invariant in a loop that does not assign the variable, so the tier hoists it with its other loop-invariant guards. A read of a forced lazy variable in optimized code therefore costs the same as a read of an ordinary variable.

Executing a `<lazy>` declaration creates the closure of `EXP`, which allocates as a function expression does. Lazy variables belong in setup code that runs once, such as the top of a file. `lus check` warns about a `<lazy>` declaration inside a loop.

Before the implementation merges, `tests/bench/lazy.lus` measures three cases against an ordinary local: a hot loop that reads a forced lazy local, the same loop through an upvalue, and a declaration executed in a loop. The first two must be within the run-to-run variation of the ordinary local in every JIT mode.

## 8. Open questions

**Q1. Can a lazy variable be assigned?**

- **(a) Yes, unless it also has `<const>`. An assignment before the first read discards the initializer (recommended).** Expensive defaults then need no extra code.
- (b) No. A lazy variable is always read-only, and a default that the command line may replace needs a second variable.

**Q2. What happens after the initializer raises an error?**

- **(a) The variable stays pending, and the next read retries (recommended).**
- (b) The variable keeps the error, and every later read raises it again.

**Q3. What happens when a coroutine reads a variable that another coroutine is evaluating?**

- **(a) A detached coroutine waits for the evaluation. Any other coroutine raises an error (recommended).**
- (b) Every such read raises an error.
- (c) The initializer may not yield. A yield inside it raises `attempt to yield inside a lazy initializer`, so the case cannot arise.

**Q4. Which variables may be lazy?**

- **(a) Locals and fields of local groups (recommended).**
- (b) Also declared globals, through a hook on the global table that every global read of the chunk checks.

**Q5. When the initializer reads a variable that changed after the declaration, which value does it see?**

- **(a) The value at the first read, as a function body written in the declaration sees it (recommended).**
- (b) The value at the declaration. The compiler copies every variable the initializer reads when the declaration runs, which costs a copy per variable and differs from how every other nested code in Lus reads variables.
