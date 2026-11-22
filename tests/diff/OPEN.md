# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## A worker whose creation fails can leave `worker.receive` waiting

Harness: `tests/oom/run.lus` through the coverage build. With `LUS_FAIL_ALLOC=928`, `receive_in_the_main_chunk_runs_the_coroutines_test` of `tests/conformance/workercoro_test.lus` usually fails with "failed to create worker state", which is correct, but some runs wait forever in the `worker.receive` of the main chunk. The sweep saw the hang again when it ran the file alone, and one run of three hung afterwards on the same machine, then none of 21. The numbering of allocations follows the timing of the worker threads, so the failing allocation lands in different places, and the hanging runs have not yet printed their stack with `LUS_FAIL_ALLOC_TRACE`. The creator of a worker must see its failure and never wait for it, which part 11 of `spec/design/testing.md` checks at every step of message handling.

## A `__concat` metamethod cannot yield

Harness: the coverage work of part 8. Every other metamethod may yield inside a coroutine, including `__index`, `__newindex`, the arithmetic and bitwise ones, `__eq`, `__lt`, `__le`, `__len`, `__call`, and `__close`. A yield inside `__concat` raises "attempt to yield across a C-call boundary" in the interpreter and in both tiers of the JIT:

```lus
local mt = { __concat = function() coroutine.yield("cat") return "c" end }
local co = coroutine.create(function(a) return a .. "x" end)
print(coroutine.resume(co, setmetatable({}, mt)))
```

The concat instruction calls the metamethod natively through `ops.call1`, where the other instructions push a metamethod frame through `ops.callMeta` and finish the instruction when the frame returns. A concatenation of several operands needs to resume with the operands it has not folded yet, so its finish has to record how many remain. Lua 5.4 lets `__concat` yield, and keeps that count in the top of the stack.
