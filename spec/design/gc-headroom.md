# Heap headroom for objects that die old

_Status: decided and shipped. A refill sweeps up to 32 waiting pages, collector steps during a sweep follow what the program allocates, the growth of the old generation calls for a major collection before minor collections probe, and the pause is 150. `logs` keeps its peak at every pause, and `lru` peaks 14 percent lower. Section 5 gives the measurements._

A program that keeps a steady set of objects and replaces them after a long life, as a cache does, frees its dead objects only in major collections, since every one of them survived a minor collection first (`gc.md`, Generational mode). Between two major collections the heap holds the live set and every object that died since the last one. This note measures how much memory that headroom takes on the cross-language suite, finds which parts of the collector set it, and records the changes that shipped with their measurements. The constraints of the collector stay as they are: objects never move, so a raw pointer handed to C stays valid, every state keeps its own heap, and no collector step pauses the program for more than a millisecond.

All figures are peak resident memory and wall time of ReleaseFast builds on an Apple M4 Max, best of two runs on a machine with other load. Live data and page counts come from a build that reports the number of pages in use, the bytes of their live cells, and the bytes held outside them at chosen points of a program.

## 1. What the heap holds

The table gives, for each program of the suite, its peak resident memory and the state of its small-object heap at its end, just before and just after a full collection. Occupancy is the share of the bytes of the pages in use that live cells fill. Packed is the number of pages the same live cells would fill with no free cell left in any page. Outside is what the state holds in the backing allocator, such as array parts, hash parts, long strings, and the string table.

| program | peak | pages before | occupancy before | pages after | occupancy after | packed after | outside after |
|---|---:|---:|---:|---:|---:|---:|---:|
| csv | 502 MB | 322 MB | 99% | 322 MB | 99% | 322 MB | 47 MB |
| json | 530 MB | 362 MB | 99% | 324 MB | 99% | 324 MB | 106 MB |
| logs | 316 MB | 71 MB | 99% | 31 MB | 97% | 30 MB | 134 MB |
| lru | 43 MB | 23 MB | 77% | 23 MB | 39% | 9 MB | 4 MB |
| template | 502 MB | 331 MB | 99% | 192 MB | 99% | 192 MB | 109 MB |
| wordfreq | 249 MB | 0.6 MB | 39% | 0.6 MB | 44% | 0.6 MB | 68 MB |

The peaks of this build are a few megabytes above the usual ones, because the reporting adds a full collection at the end. Five of the six programs keep their pages full. What they hold at their peak is live data, in pages and outside them, which no policy for dead objects can lower. `lru` is the program the note concerns. Its 9 MB of live cells occupy 23 MB of pages after a full collection. The free cells of those pages are where the program allocates until the next major collection, which finds them 77 percent full again.

## 2. What sets the headroom of `lru`

The pacer aims to start each major collection when the heap reaches `pause` percent of the live data (`gc.md`, Pacing). On `lru` that parameter has almost no effect on the peak. Lower values even raise it.

| pause | time | peak |
|---:|---:|---:|
| 175 | 0.87 s | 41.2 MB |
| 150 | 0.97 s | 39.9 MB |
| 125 | 1.04 s | 47.8 MB |

The heap reports explain it. At a pause of 110 the counted heap of `lru` peaks at 24 MB, against 27 MB at 175, yet the program holds 1,902 pages against 1,500. The pages that a major collection judged wait to be swept. The allocator sweeps at most four of them per refill before it takes a fresh page (`heap.refill`). When collections follow each other closely, many pages wait at once, so the allocator takes fresh pages while pages full of free cells wait for a sweep. Each fresh page joins the heap for good. A page returns to the pool only when it holds no live object, while the cells of `lru` die one by one across all its pages.

A build in which the allocator sweeps every waiting page of its size class before it takes a fresh page shows the bound of that effect. The pause then trades time for memory as the pacer intends.

| pause | time, four sweeps | peak, four sweeps | time, every page | peak, every page |
|---:|---:|---:|---:|---:|
| 175 | 0.87 s | 41.2 MB | 0.87 s | 39.8 MB |
| 150 | 0.97 s | 39.9 MB | 0.93 s | 38.5 MB |
| 125 | 1.04 s | 47.8 MB | 0.96 s | 33.9 MB |
| 100 | 1.20 s | 47.2 MB | 1.04 s | 34.2 MB |

At a pause of 125, `lru` peaks at 33.9 MB where it peaks at 41.2 MB now, an 18 percent cut, in 10 percent more time.

## 3. Sweeping before growing

A refill sweeps the waiting pages of its size class until one has room. It takes a fresh page only when none waits or when it has swept 32 pages, so a run of full pages still ends the refill early. A page sweeps in 1 to 20 microseconds, depending on how many of its dead cells free something outside them, such as the body of a string. The longest refill of each program, with the timing measured inside the allocator on a loaded machine, stays under a millisecond with 32 pages and passes it with 64.

| program | longest refill, four pages | longest refill, 32 pages |
|---|---:|---:|
| csv | 0.25 ms | 0.17 ms |
| json | 0.38 ms | 0.37 ms |
| logs | 0.10 ms | 0.16 ms |
| lru | 0.02 ms | 0.06 ms |
| template | 0.26 ms | 0.60 ms |
| wordfreq | 0.04 ms | 0.04 ms |

A refill of one or two pages already takes a quarter of a millisecond in `csv`, `json`, and `template`, where a dead table frees a large array part. With 64 pages, `template` reached 0.77 ms on an idle machine and 1.2 ms on a loaded one. Against 64 pages, 32 cost `logs` 2 MB, `lru` 1 to 2 MB, and `template` 4 MB.

The sweep alone moved the peak of `logs` from 285 MB to 328 MB at the default pause, and the peak of `logs` already moved with the pause before it: 285 MB at 175, 326 MB at 150 and at 125. Two parts of the collector set the peak of `logs`, and neither concerns the sweep itself.

The program builds a million lines, joins them, and drops the table that held them. The join makes an 80 MB string, and the newline appended to it makes a second one, so the first is dead as soon as the second exists. The minor collection that runs while the second string is made still finds the first on the stack, and it becomes old. A major collection must free it, with the lines.

**The pace of the sweep.** Collector steps run every `stepsize` bytes by which the heap count grows. During the parse, the refills sweep pages of dead lines and free about as much as the program allocates, so the count falls by 40 MB and no step runs for 450,000 lines. Large objects are freed when the sweep ends, so the dead 80 MB string waited for that step while the hash parts of the tables of addresses and strings doubled on top of it. A page that a refill sweeps now brings the next step closer by the bytes it freed. The steps of the sweep then follow what the program allocates, and the string is freed within a few steps of the mark.

**The first collection after the join.** The minor collection that meets the joined text finds an old generation three times the size the last major collection left. Generational mode then asked for a major collection only when no minor collection probed the program first, and a probe that came first waited for 40 MB more of allocation, with a goal doubled because the heap had grown. The growth of the old generation now calls for the major collection before any probe, since it already says what the probe would find.

## 4. Other policies and their bounds

**Major collections paced on the growth of the old generation.** Generational mode already starts a major collection when survivors of minor collections grow the old generation past `minormajor` percent of the heap that the last major collection left. Setting `minormajor` to 10 and `minormul` to 5 left every peak of the suite within 2 MB but that of `logs`, which rose to 380 MB. `lru` runs major collections without minor ones between them (`gc.md`). The other programs keep their data live. The bound of this policy on the suite is that of the pause, which section 2 traces to the sweep. The change of section 3 orders this test before the probes of minor collections.

**Pretenuring.** `gc.md` records an allocation-site prototype that allocated the tables of long-lived sites as old objects. It saves the trace of a survivor in a minor collection. It frees nothing earlier, since a pretenured object that dies waits for a major collection as any old object does. Its bound on peak memory is zero.

**Incremental mode.** With a pause of 100 and a step multiplier of 1000, `lru` peaks at 45.7 MB in 1.91 s. With a pause of 125 and a step multiplier of 400, it peaks at 43.9 MB in 1.53 s. Objects that die while a mark phase runs survive that cycle, so an incremental cycle keeps more garbage than a major collection that marks in one stop.

**Choosing fuller pages first.** An allocator that refills from the fullest pages of a class, so that sparse pages empty and return to the pool, frees pages only when the objects of a page die together. In `lru` they die one by one, in the order of the cache, across every page. A test that keeps every third of two million tables leaves its pages a third full after a full collection. No order of allocation empties them without moving the objects that remain. On `lru` the free cells of its sparse pages are the room the program allocates into until the next major collection, so ordering pages changes where the program allocates and leaves the number of pages the same.

**Compaction.** Moving live objects into fewer pages would bring `lru` toward its packed size of 9 MB of cells, about 18 MB of resident memory with the rest of the process. Moving invalidates the raw pointers that native code and C embedders hold into the heap, which the collector guarantees to keep valid, so compaction stays outside the design.

## 5. Results

The table gives the suite on `rewrite` and with the three changes of section 3 at three pauses, best of three runs on a machine with other load. Peaks are peak memory footprints.

| program | rewrite, 175 | 175 | 150 | 125 |
|---|---:|---:|---:|---:|
| csv | 446.3 MB, 0.68 s | 445.6 MB, 0.70 s | 445.6 MB, 0.69 s | 445.6 MB, 0.68 s |
| json | 496.8 MB, 0.54 s | 483.5 MB, 0.55 s | 483.5 MB, 0.56 s | 483.5 MB, 0.56 s |
| logs | 285.2 MB, 0.62 s | 286.0 MB, 0.62 s | 286.0 MB, 0.62 s | 286.0 MB, 0.61 s |
| lru | 38.9 MB, 0.86 s | 36.8 MB, 0.94 s | 33.3 MB, 0.88 s | 32.8 MB, 0.97 s |
| template | 466.8 MB, 0.57 s | 473.4 MB, 0.58 s | 473.1 MB, 0.58 s | 473.4 MB, 0.58 s |
| wordfreq | 235.3 MB, 1.06 s | 235.3 MB, 1.05 s | 235.3 MB, 1.08 s | 235.3 MB, 1.06 s |

`logs` peaks at 286 MB at every pause, where `rewrite` peaks at 285 MB at 175 and 326 MB at 150 and 125. The pause is 150. It takes `lru` from 38.9 MB to 33.3 MB at the same speed, where a pause of 125 saves half a megabyte more for 10 percent more time. `json` peaks 13 MB lower at every pause. `template` peaks 6 MB higher, a cost of the 32-page budget, and stays the lowest peak of the suite for that program. `csv` and `wordfreq` stay level.

The conformance suite passes in every mode, with the stress build and its verifier, on Linux, and in WebAssembly, since the sweep order and the pacing change the moment each finalizer and each weak entry is cleared.
