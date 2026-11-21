# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## A worker test hung once under an allocation failure

Found by the allocation failure sweep. One run of `workercoro_test.lus` with `LUS_FAIL_ALLOC=1022` hung until the runner killed it. The numbering of allocations depends on the timing of the worker threads, and the hang did not come back in 51 runs around that number. The nightly sweep keeps looking for it.
