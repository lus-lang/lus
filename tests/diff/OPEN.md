# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## An allocation that fails in a detached coroutine can leave the main chunk waiting

Harness: `tests/oom/run.lus` through the coverage build. With `LUS_FAIL_ALLOC=928`, `receive_in_the_main_chunk_runs_the_coroutines_test` of `tests/conformance/workercoro_test.lus` sometimes waits forever in the `worker.receive` of the main chunk. The numbering of allocations follows the timing of the worker threads, so the same N lands in different places from run to run, and a ReleaseSafe build hangs at other numbers, such as 6356.

`LUS_FAIL_ALLOC_TRACE` shows the cause in a run that hung. The failing allocation is the first call of the `sender` coroutine, which the main chunk runs from inside `worker.receive`. The coroutine fails before it sends `"main"`, so the worker waits in `worker.peek` for a message that never comes, and the main chunk waits for the answer of the worker. The program deadlocks as written, and the worker machinery behaves correctly. The runtime cannot stop such a program early, since the main chunk still holds the failed coroutine and may collect its error after the receive.

What is open is the harness. The I/O sweep already counts a hang from a peer that waits for a failed operation apart from the failures, and the allocation sweep needs the same rule, or these tests need a shape whose waits cannot depend on a coroutine that an allocation failure stops. The timeouts of `network_test.lus` under the allocation sweep (N of 2353, 3815, 3855, and 3875 in the coverage build) are likely of the same kind.
