# Garbage collection

The Lus 2.0 collector is precise and non-moving. It allocates small objects from size-classed pages, marks with a bitmap per page, and sweeps lazily. It runs in one of two modes. Incremental mode interleaves tri-color marking with the program under a goal-based pacer. Generational mode keeps survivors marked as an old generation, so that minor collections trace only young objects, and switches to incremental major collections on its own when most new objects survive. Generational mode is the default. Every state owns its heap, so workers never share objects.

## The heap

Small objects live in 16 KB pages carved out of 256 KB segments aligned to their size. The first page of a segment holds the metadata of the other fifteen. Each page serves one size class, a multiple of the 16-byte granule. The classes run 16, 32, 48, and so on up to 128 bytes, then grow by a quarter (160, 192, 224, 256, 320, ...) up to 2 KB, which keeps internal fragmentation under 20 percent.

A page also holds one kind of object. Leaf pages hold strings, bigints, decimals, and vector headers, which reference no other object, so marking sets their bit and never traces them. Scan pages hold everything else. Separating the two keeps text and numbers out of the cache lines the marker reads.

Objects larger than 2 KB come straight from the backing allocator and sit in a list. Thread stacks, vector payloads, prototype code, and table parts stay in the backing allocator as well, except the small parts of a table created with known sizes, which live in the cell of the table (`tables.md`). Every byte the state holds, in pages or outside them, goes through one counting allocator, and the pacer reads its total.

A fresh page allocates by bumping a pointer. A page that was swept allocates from a free list rebuilt in address order. Allocation sites that initialize every field skip clearing the memory.

## Object metadata

Every object starts with a header of one tag byte, one flag byte, and the finalizer state. The flags are the barrier bit, the free bit of an empty cell, the large bit, and the mark bit of a large object. Small objects keep their mark bit in the bitmap of their page, one bit per granule, so a sweep reads whole 64-bit words of marks and never touches a live object.

## Sweeping

Sweeping is lazy. When a mark phase ends, every page whose objects it judged waits for a sweep. The allocator sweeps a page when its size class reaches it and then allocates from the cells the sweep freed. After four sweeps that free nothing, the allocator takes a fresh page and leaves the rest to the collector steps, so one allocation never sweeps a large part of the heap. Collector steps sweep the pages that the allocator does not reach. A page left without live objects returns to the pool of free pages, where any size class can take it, and a segment whose pages are all free goes back to the backing allocator.

A sweep frees what a dead object owns outside its cell, such as the parts of a table or the stack of a thread. Safe builds fill dead cells with a fixed pattern, so a use after free reads garbage instead of a plausible object.

## Marking

Marking is tri-color. White objects are unmarked. Gray objects are marked and wait on an explicit gray stack. Black objects are marked and traced, and they carry the barrier bit. A mark phase starts by clearing the mark bitmaps and marking the roots: the main thread, the registry, the globals, the per-type metatables, the metamethod names, the fixed objects, and the objects waiting for their finalizers. Steps then trace gray objects, each within a budget of bytes.

The marker pops gray objects from the top of the stack and prefetches the object eight places below the top, the first two cache lines of it. Objects often reach the stack long before they are traced, as when a large table pushes all of its elements at once, and the prefetch lets the marker trace one object while the next ones arrive from memory.

Tracing a value that refers to an object the marker traces pushes the object without reading it, with the low bit of its address set. The object is marked when it pops, after the prefetch brought it close, and an entry whose object was marked in between is dropped, because whoever marked it also queued it, or it is old. Objects without references, such as strings, are marked at once, since they never reach the stack. Reading each object once, when it is traced, took a full collection of the three million records of `tables.lus` from 31 ms to 21 ms.

When the gray stack runs empty, the atomic phase ends the mark phase without the program running. It marks the roots again, traces every live thread again because stores into stacks take no barrier, and marks the current values of open upvalues that a dead thread still owns when a live closure captured them. It traces the objects that stores turned gray, converges ephemerons, moves unreachable objects with finalizers to the finalizer queue in registration order and marks them for one more cycle, and clears weak tables. Dead threads then close their open upvalues, and the sweep starts.

Weak tables keep the semantics of Lua 5.4. Keys and values that are strings, bigints, or decimals count as values and are never cleared. An ephemeron table keeps a value alive only while its key is alive. A value with a pending finalizer is cleared from weak-value tables. Interned strings are weak: a dead interned string stays in the string table until its page is swept, and finding it again in that window marks it, which revives it. When a sweep leaves the string table less than a sixteenth full, the table shrinks (`strings.md`).

Inline caches record slot numbers, never pointers, so they need no tracing. Table array parts that hold only integers or only floats store bare numbers, and the marker skips them.

## Barriers

Every store of a collectable value into a heap object runs the barrier after the store. The fast path tests the barrier bit of the object, which only black objects carry. The stores covered are interpreter table stores (including a new string key), the same stores made by native code, which tests the barrier bit inline and calls `gc.barrierTable` for the slow part, `ops.rawSet` and everything built on it, `SETLIST`, upvalue stores and upvalue closing, `setmetatable` in both libraries, `debug.setupvalue`, `debug.upvaluejoin`, `debug.setuservalue`, the environment that `load` installs, user values of time zones, and lazily created enum members. A native that fills an object it just allocated needs no barrier, because a fresh object is white.

During a mark phase the barrier is backward: a store into a black object clears its bit and puts it on the gray-again list, and the collector traces it again before the atomic phase ends. A large table with no weak mode (at least 1024 slots) instead stays black, and the stored key and value turn gray. Filling a big table during a mark phase then never traces it again.

## Pacing

The pacer targets a heap size relative to the live data. After a cycle, `live` is the heap size when the mark phase ended less what the sweep freed. The next mark phase should end before the heap reaches `live * pause / 100`. When a major collection freed less than a sixteenth of what the program allocated since the previous one, the heap is growing, and the goal doubles until a collection frees more again. A heap that only grows then does a third less marking, and its peak size stays the same, since all of it is live. A program that turns from building to discarding waits one cycle at the doubled goal, which raises its peak. `gcpause.lus`, which builds a 50 MB graph and drops it, peaks at 235 MB where it peaked at 174 MB before. Marking traces about `live` bytes at `stepmul / 100` bytes per allocated byte, so the cycle starts at the goal less `live * 100 / stepmul`. A step runs every `stepsize` bytes of allocation. During marking, each step compares the work left with the room left before the goal and raises its budget when marking falls behind, up to 64 basic steps, which bounds the pause of a step that catches up. The defaults are a pause of 200, a step multiplier of 200, and a step size of 200 tables.

`collectgarbage("param", name [, value])` reads and sets `pause`, `stepmul`, `stepsize`, `minormul`, `minormajor`, and `majorminor`. `collectgarbage("step", n)` runs about `n` KB of work, or one basic step when `n` is zero, and returns true when a cycle finished. `collectgarbage("collect")` abandons a mark phase in progress, runs a complete cycle including its sweep, and runs pending finalizers.

## Generational mode

Generational mode uses sticky mark bits. Marks survive a collection, so every marked object is old and every unmarked object is young. The barrier bit then logs the first store into an old object since the last collection: the store clears the bit and appends the object to the remembered set. A large old table instead promotes the young key and value it receives by marking them and logging them.

A minor collection runs without interruption. It marks the roots and traces the remembered set, the old weak tables (so that entries referencing young objects are cleared or kept as in any table), and every live thread. Marking stops at marked objects, so it traces only young objects that survive, and each survivor becomes old. The atomic steps of a major collection follow: ephemerons, finalizers, weak tables, and dead threads. The sweep then visits only the pages that received objects since the previous collection, plus the large objects allocated since then. Every other page holds only old objects.

A minor collection runs after the program allocates `minormul` percent (default 20) of the heap that the last major collection left, and at least 1 MB. When the bytes that survived minor collections grow the old generation past `minormajor` percent (default 70) of that heap, the next collection is a major one, run as an incremental cycle that clears every mark. Old objects die only in major collections, and a program observes their death through finalizers and weak tables. While it has either, a major collection also follows every 100 minor ones, so an old object with a finalizer is finalized even when the program allocates nothing but short-lived objects. After a major collection, the collector returns to minor collections when the major freed at least `majorminor` percent (default 50) of what the program allocated since the previous major collection. Otherwise most new objects live long, so it stays with incremental cycles until a major collection frees enough again.

`collectgarbage("generational")` enters generational mode with a full collection, whose survivors form the old generation. `collectgarbage("incremental")` leaves it. Both return the previous mode. In generational mode between major collections, `collectgarbage("step")` runs one complete minor collection.

## Closing a state

Closing a state runs every pending finalizer and then frees every object. The command line runner closes its state just before the process exits, and in builds without runtime safety it stops after the finalizers, the shutdown of workers, and the flush of output: the exit of the process returns the heap, which spares a last pass that reads every live object. Safe builds and embedders that call `api.close` free everything, so the allocators of the safe builds still check the whole teardown. On `tables.lus` the full teardown was a sixth of the run.

## Checking the collector

`zig build -Dgc-stress=N` runs a small collector step at every allocation point, so marking always overlaps the program, and ends a mark phase (or runs a minor collection) at every Nth point. `zig build -Dgc-verify=true` adds a heap verifier that runs at the end of every mark phase. It checks that every marked object is black and references only marked objects through strong references, which catches a missing barrier or a missing root at the collection where it matters. The conformance suite runs clean under both options together.
