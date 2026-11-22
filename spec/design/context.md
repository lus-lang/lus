# Context variables

A _context variable_ is a local variable whose value belongs to the running coroutine. It is declared with the `<context>` attribute, whose initializer is the default that every coroutine sees until it assigns its own value.

```lus nocheck
local request_id <context> = "none"
request_id = crypto.uuid(7)   -- the running coroutine only
print(request_id)             -- the running coroutine's value
```

The variable is lexically scoped like any local, so its identity is the key. Two libraries that each declare `request_id` have two variables, so no two libraries can collide on a name.

## Inheritance

A new coroutine starts with the values of the coroutine that created it, plain or detached, including the connection coroutines of `network.serve`, which inherit from the coroutine that runs `serve`. The values are shared copy on write: neither side copies anything until one of them assigns. An assignment after the creation stays on the side that made it. This is the mechanism of permission sets (`vm/pledge.zig`, `inherit`). A worker starts from the defaults, because values cannot cross states.

The main coroutine has storage of its own like any other coroutine.

## Representation

- The declaration asks the state for a _slot_, a small integer, when it runs. The state records the initializer as the default of the slot in a list of the state (`Global.ctx_defaults`), which the collector marks. The slot lives in a hidden local, so closures capture it like any local.
- A coroutine holds a pointer to a _context array_: a reference count, a length, and one value per slot. The pointer is null until the coroutine or an ancestor assigns a context variable.
- Creating a coroutine copies the pointer and increments the count: two instructions, on the path that creating a coroutine takes today. Freeing a coroutine decrements the count and frees the array at zero.
- Reads and writes are two new instructions in the bytecode, `GETCTX A B` and `SETCTX A B`, where register `B` holds the slot object of the variable (see [Reclaiming slots](#reclaiming-slots)). `GETCTX` loads the array of the running coroutine, then the slot, and falls back to the default when the array is null or shorter than the slot. That is two loads and a compare on the fast path, which both JIT tiers and the AOT compiler emit inline.
- `SETCTX` copies the array first when its count is above one or it is too short, then stores. A write therefore allocates at most once per coroutine.
- The collector marks the array of every coroutine it traverses. An array shared by several coroutines is marked several times, which costs a few loads.

The measurements to record before merging: the cost of a read and a write in a loop under each tier, against a local and an upvalue, and the time to create and collect a coroutine against the commit before. Any slowdown beyond noise blocks the merge.

## Combinations

`<context>` combines with no other attribute. `const`, `close`, `lazy`, `observe`, and `meta` each describe a single value with one lifetime, which a per-coroutine value contradicts, so a combination is a compile error that names both attributes. A field of a local group and a global cannot be context variables either, for the same reason, so `global x <context>` is a compile error.

## Debug interface

`debug.getcontext(co, n)` returns the name and the value of context variable number `n` as coroutine `co` sees it, which is its own assignment, the inherited value, or the default. It returns nil past the last variable, like `debug.getupvalue` and `debug.getlocal`. `co` defaults to the running coroutine. `debug.setcontext(co, n, value)` assigns the value for `co` and returns the name.

The numbers follow the order in which declarations ran in the state, starting at 1. Two variables named `request_id` in two files therefore have two numbers. A third result of `getcontext`, the source and line of the declaration such as `"app/log.lus:3"`, tells them apart for tools.

`lus debug` shows the variables in a "Context" scope of the DAP variables view, next to the locals and the upvalues of a frame, with the values of the coroutine that the frame belongs to.

## Later

Two features build on this design and are left for later: scoped rebinding, which sets a value for a block and restores it at the end of the block, and cancellation with deadlines in the style of Go contexts, as a package.

## Decisions

The user settled the open questions of the first draft.

- A declaration may appear anywhere. Each run of it creates a new variable with a slot of its own, like any local. The collector reclaims the slot of a variable that nothing refers to any more (X1, choice c).
- Assigning `nil` stores `nil` for the running coroutine, which then reads `nil`. The default no longer applies to that coroutine (X2, choice a).
- `debug.getcontext` names a variable by number and returns the declaring source and line as its third result (X3, choice a).

## Reclaiming slots

The hidden local of a declaration holds a _slot object_, a small object of the collector that carries the slot number, in place of a plain integer. Closures capture the slot object like any local, so it lives exactly as long as some frame or closure can still reach the variable.

When the collector frees a slot object, the state puts the slot number on a free list and clears that index in every context array, which the state keeps in a list for this purpose. The next declaration that runs takes a number from the free list before it grows the table of defaults. A read never meets a value of an earlier variable, because no array keeps one, so a read stays two loads and a compare. Clearing walks every array once per reclaimed slot, which is rare next to reads, and it releases the values the arrays held, so a reclaimed variable never keeps its values alive.

`GETCTX` and `SETCTX` read the slot number from the slot object in their register, which is one more load than an integer in a register would cost. The measurement before merging compares the read with a local and an upvalue under each tier, so this load is part of the number recorded.

## Numbering in the debug interface

`debug.getcontext(co, n)` counts the live variables of the state in the order in which their declarations ran, starting at 1. A reclaimed variable leaves the count, so the numbers of the variables declared after it move down by one, as the numbers of `debug.getlocal` move when a block ends. A tool reads the numbers afresh each time it stops, as it does for locals.

## Measurements

`tests/bench/context.lus` reads and writes a variable 20 million times in a loop and compares a local, an upvalue, and a context variable. The numbers are seconds on an Apple silicon Mac, ReleaseFast, with other work running on the machine, so differences under 10 percent are noise.

| Loop | JIT off | Baseline tier | Both tiers |
| --- | ---: | ---: | ---: |
| read a local | 0.050 | 0.028 | 0.011 |
| read an upvalue | 0.072 | 0.035 | 0.014 |
| read a context variable, default | 0.082 | 0.071 | 0.116 |
| read a context variable, assigned | 0.101 | 0.083 | 0.074 |
| write an upvalue | 0.056 | 0.023 | 0.018 |
| write a context variable | 0.103 | 0.042 | 0.065 |

A read costs about 2 ns more than a local in the interpreter and in the baseline tier, which calls a helper for `GETCTX` and `SETCTX` (`jit/helpers.zig`, `ctxGet` and `ctxSet`) and leaves a write that must copy the array to the step routine. The optimizing tier runs both instructions through their templates, so a hot loop that reads a context variable costs 3 to 5 ns per read where a local costs half a nanosecond. Lowering the two instructions in the optimizing tier, with a guard on the slot object and a load of the value through the array, is the next step for code that reads context variables in hot loops.

Creating and running a coroutine (`coroutine.resume(coroutine.create(f))`, best of seven runs of a million) took 193 to 213 ns both on the commit before this work and after it, with the JIT off and on. The copy of the array pointer and its count is lost in the noise of the allocation.
