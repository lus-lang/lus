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

- The declaration asks the state for a _slot_, a small integer, when it runs. The state records the initializer as the default of the slot in a list of the state (`Global.ctx_defaults`), which the collector marks. The slot number lives in a hidden local, so closures capture it like any local.
- A coroutine holds a pointer to a _context array_: a reference count, a length, and one value per slot. The pointer is null until the coroutine or an ancestor assigns a context variable.
- Creating a coroutine copies the pointer and increments the count: two instructions, on the path that creating a coroutine takes today. Freeing a coroutine decrements the count and frees the array at zero.
- Reads and writes are two new instructions in the bytecode, `GETCTX A B` and `SETCTX A B`, where register `B` holds the slot. `GETCTX` loads the array of the running coroutine, then the slot, and falls back to the default when the array is null or shorter than the slot. That is two loads and a compare on the fast path, which both JIT tiers and the AOT compiler emit inline.
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

## Open questions

- **X1. Where may a `<context>` declaration appear?**
  - (a) Recommended: only in the main block of a chunk. A declaration there runs once per load of the chunk, so slots stay few, and a variable that belongs to the coroutine is module state by nature. A declaration elsewhere is a compile error.
  - (b) Anywhere, with one slot per declaration site and state. A declaration that runs again keeps its slot and its first default, which differs from how every other local behaves.
  - (c) Anywhere, with a new slot each time the declaration runs, and the collector reclaims the slots of variables that no closure or frame refers to any more.
- **X2. What does assigning `nil` do?**
  - (a) Recommended: it stores `nil` for the coroutine, which then reads `nil`, like any other value. The default no longer applies to that coroutine.
  - (b) It removes the coroutine's own value, so the coroutine reads the inherited value or the default again.
- **X3. How does `debug.getcontext` identify a variable?**
  - (a) Recommended: by number in declaration order, with the source and line as a third result.
  - (b) By an identity handle that a fourth function returns for a name and a chunk.
