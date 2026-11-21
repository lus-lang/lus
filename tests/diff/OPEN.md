# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## The optimizing tier loses an upvalue increment

Found by the differential tester. `open/opt_lost_upvalue_increment.lus` prints `31` with `LUS_JIT=off`, `eager`, and `baseline`, and `30` from the second call of `u1` onward with `opt-eager` (with or without `LUS_JIT_DIRECT=off`) and with `LUS_JIT_THRESHOLD=2 LUS_JIT_OPT_THRESHOLD=3`. A closure that adds to an upvalue runs 29 times in a loop, and one of its calls is lost. The reproducer needs its surrounding statements to trigger: a variadic `P` that calls a global function, the argument `(math.tointeger0 or 0) & 62`, a table constructor, and a generic `for` over `nil`. `LUS_JIT_DUMP=1` shows the exits "snapshot 5 of the unit at 0, pc 10" and "snapshot 2 of the unit at 10, pc 16". A second program from another seed, `open/opt_lost_upvalue_increment_2.lus`, loses 5 of 6080 increments the same way. In both, the closure's argument is an arithmetic expression, and a later statement of the same function raises an error that an outer `catch` captures. Replacing the argument with a plain local, or the raising statement with `error("x")`, hides the bug. The speed session owns the tier and has the report.

## A table with a hole formats as an empty object

Found by the JSON fuzz target. `tojson(fromjson('[1,null,3]'))` returns `{}`. `fromjson` turns `null` into `nil`, which leaves a hole, and `tojson` writes a table whose integer keys are not contiguous as an object of its string keys. Both behaviors are specified (`spec/stdlib/base/tojson.md`), but together they lose data on a round trip of valid JSON. A fix is a design decision, for example writing such a table as an array with `null` in its holes up to its largest integer key.

## NaN prints differently on arm64 and x86-64

Found by the differential tester across architectures. `print(0/0)` prints `nan` on arm64 and `-nan` on x86-64, and `-(0/0)` prints the other one. The interpreter and every JIT tier agree on each platform, since the sign of a NaN comes from the hardware. `tostring`, `string.format`, and concatenation all show it. Printing every NaN as `nan` would make the output of a program the same on every platform.

## A worker test hung once under an allocation failure

Found by the allocation failure sweep. One run of `workercoro_test.lus` with `LUS_FAIL_ALLOC=1022` hung until the runner killed it. The numbering of allocations depends on the timing of the worker threads, and the hang did not come back in 51 runs around that number. The nightly sweep keeps looking for it.

## Worker permission sets change allocators

Found while fixing a leak. `pledge.snapshot` copies the permission set of the creating state with that state's counting allocator, and the worker frees the copy with its own counting allocator, or `Worker.destroy` frees it with the parent allocator when the worker never started. The memory is correct, since every counting allocator wraps the same parent, but the byte count of the creating state keeps the copy forever and the count of the worker saturates at zero.
