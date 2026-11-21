# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## A table with a hole formats as an empty object

Found by the JSON fuzz target. `tojson(fromjson('[1,null,3]'))` returns `{}`. `fromjson` turns `null` into `nil`, which leaves a hole, and `tojson` writes a table whose integer keys are not contiguous as an object of its string keys. Both behaviors are specified (`spec/stdlib/base/tojson.md`), but together they lose data on a round trip of valid JSON. A fix is a design decision, for example writing such a table as an array with `null` in its holes up to its largest integer key.

## NaN prints differently on arm64 and x86-64

Found by the differential tester across architectures. `print(0/0)` prints `nan` on arm64 and `-nan` on x86-64, and `-(0/0)` prints the other one. The interpreter and every JIT tier agree on each platform, since the sign of a NaN comes from the hardware. `tostring`, `string.format`, and concatenation all show it. Printing every NaN as `nan` would make the output of a program the same on every platform.

## A worker test hung once under an allocation failure

Found by the allocation failure sweep. One run of `workercoro_test.lus` with `LUS_FAIL_ALLOC=1022` hung until the runner killed it. The numbering of allocations depends on the timing of the worker threads, and the hang did not come back in 51 runs around that number. The nightly sweep keeps looking for it.
