# Query shortcuts

This note plans the first of the JIT experiments. It changes how `vm/query.zig` runs a query and keeps every query result exactly as it is today. The work ships only when the measurements below show a win and every gate passes.

## What runs today

A query compiles into a step function and a plan string. The executor fetches each source into a list and walks the cross product of the lists with an odometer, calling the step function once per tuple. The step function applies the where clause and returns the record and its order keys. Grouping keeps one group table per key and folds every aggregate as tuples arrive. Ordering collects every record, sorts all of them with a stable merge sort, and then applies `limit` and `offset`.

The executor therefore spends work proportional to the product of the source sizes on every join, and work and memory proportional to the whole result on every `order by ... limit`.

## Hypotheses

Each shortcut is a separate experiment with its own verdict.

1. **Indexed joins.** When a where conjunct is an equality between a column of source `j` and a column of a later source `i`, the executor builds a hash index on that column of source `i` once per run. The odometer position for source `i` then steps through the rows whose key matches the current row of source `j`, in their list order. A join of two lists of n rows does work proportional to n plus the matches, where today it does n squared.
2. **Top k ordering.** When a query has `order by` and a `limit` k with no grouping and no `distinct`, the executor keeps the best `offset + k` records in a bounded heap ordered by their keys and their arrival position. It uses memory for `offset + k` records and work proportional to n log k.
3. **Remembered indexes.** A query that runs many times over the same source list builds the same join index each time. This experiment keeps the index across runs while the source and its rows are unchanged.
4. **Leaner grouping.** Grouping already folds aggregates in the single pass. This experiment measures what a grouped query spends per tuple, and shortens the path for the common case of one primitive group key with a single map lookup per tuple.

## Results stay identical

Every shortcut keeps the rows, their order, and the errors a query raises.

- **Row order.** The indexed odometer visits matching rows of source `i` in ascending list position for each tuple of the earlier sources, which is the order the full odometer visits them in. The heap breaks ties between equal keys by arrival position, which is what the stable sort does.
- **Equality.** The executor indexes a join only when every value of the joined columns, on both sides, is nil, a number, a string, or a boolean. Integers and floats with equal values share one entry through the same key normalization tables use, and NaN and nil match nothing, which agrees with the rule that a comparison with nil is false. When a joined column holds another kind of value, the executor walks the full product for that run, so `__eq` metamethods keep their behavior.
- **Conjunct order.** The step function evaluates conjuncts left to right and stops at the first false one, and a conjunct can raise an error or call a host function. The executor indexes a conjunct only when every conjunct before it is a column equality, so the tuples it skips are exactly the tuples the step function would have rejected before reaching anything that can raise or call out. The step function still evaluates the indexed conjunct, which holds for every tuple the index yields.
- **Column reads.** The step function reads a column with an ordinary index, which consults `__index`. The executor indexes a join only when every row that the joins up to it read is a table without a metatable, and walks the full product otherwise.
- **Plan format.** The compiler records each column equality between two sources in the plan string as a new conjunct shape. Plan strings live in compiled chunks, so the change bumps the chunk format version in `compile/dump.zig`.
- **Order errors.** With one order key, sorting raises `cannot order rows on a ... value` exactly when the non-nil keys span two classes or hold two values that do not order, because a comparison sort compares across any two classes it holds. The heap tracks those classes as records arrive and keeps every key, and when they show that the sort raises, the executor sorts all the keys as before, which raises the same error from the same pair. With several order keys, the heap applies only when the keys of each position share one class.

Host calls in a where clause run as often as before. A host call before a join keeps the full product, and a host call after it runs for the tuples that the join accepts, in both cases. The guide and the `query` spec describe the behavior as it stands.

## Measurement

The compare suite has no queries, so the experiment adds `tests/bench/queries.lus` to the Lus benchmarks with four cases at sizes that run in about a second today:

- an equality join of two lists of 2000 records,
- a three way join where one conjunct is a column equality and one is a range test,
- `order by score desc limit 10` over 200000 records,
- a grouped count and sum over 200000 records with 100 groups.

Each case prints a checksum, and the checksums must match the build without the change. The measurement takes the median of 5 runs of each case before and after, with the release build and the default JIT tiers, on the same machine in one session.

The experiment also measures what it must not cost:

- the whole compare suite with `--runs 5`, before and after, wall time and peak memory for every program,
- compile time of the largest Lus files in the repository (`lus check` over `packages/language-server`) and the bytecode size of the conformance suite, since the plan string grows by one field per conjunct,
- every existing query test, which already pins row order, nil rules, and errors.

## Kill criteria

A shortcut is killed when any of these holds after its time box:

- its target case improves by less than 3 times, measured as above,
- any compare program gets slower by more than its run to run spread or uses more memory,
- any query case that the shortcut does not apply to gets slower by more than 3 percent,
- compile time or bytecode size grows by more than 1 percent,
- the differential tester, the conformance suite, or the gc-stress build finds any difference.

A killed shortcut leaves the code as it was and its verdict is recorded in this note.

## Time boxes

- Indexed joins: 4 hours of work, including tests.
- Top k ordering: 2 hours.
- Leaner grouping: 2 hours, starting with a profile. If the profile shows that the step call dominates, the experiment stops there and records the profile.
- Remembered indexes: 1 hour of feasibility study before any code. Keeping an index is safe only when a write to the source list or to any of its rows can be detected cheaply. A table write records nothing that an index could check, and a counter on every table write would cost time on every program. The study either finds an existing signal that costs nothing or recommends killing the shortcut.

## Gates

Anything that ships passes conformance under every JIT mode, the gc-stress build with verification, `mise run diff`, the Linux VM gate, and the WebAssembly build and conformance run.

## Results

The measurements ran on one Apple silicon machine in one session, with ReleaseFast builds of `rewrite` at `5fcd4ca1` and of the change, alternating between the two. `tests/bench/queries.lus` joins lists of 6000 records, larger than planned, so that the joins run for about a second before the change. Each figure is the best run of a batch, and the checksums match in every case.

| Shortcut | Case | Before | After | Verdict |
| --- | --- | --- | --- | --- |
| Indexed joins | `join-2x6000` | 786 to 805 ms | 3.5 to 6 ms | ships |
| Indexed joins | `join-3-range` | 995 to 1000 ms | 3.3 to 6.3 ms | ships |
| Top k ordering | `order-limit-10` | 38 to 39 ms | 8.3 to 9.6 ms | ships |
| Leaner grouping | `group-100` | 9.5 ms | | stopped after the profile |
| Remembered indexes | | | | stopped after the study |

The shortcuts that ship cost nothing measurable elsewhere. `filter` and `group-100` stay within the spread of their runs, with best times of 9.18 ms before and 9.36 ms after for `filter`, and 6.42 ms before and 6.46 ms after for `group-100`. Two alternating runs of the compare suite land within run to run spread in both directions for every program, in wall time and in peak memory. The bytecode of the 37 files of `packages/language-server` is 606549 bytes with and without the change, and `lus check` over them takes 19.3 ms in both builds.

The profile of grouping shows the step calls alone taking 6.5 to 7 ms of the 9.5 ms that `group-100` takes. A grouping path with no cost at all would make the case about 1.5 times faster, so the shortcut cannot reach its target, and making the step calls cheaper belongs to another experiment.

The study of remembered indexes measured what an index costs to build. Indexing 6000 rows takes under 0.15 ms of the 2.1 ms that the join of two lists of 6000 records takes, and the rest goes to the step calls and the records of the matches. Keeping the index across runs would save at most 7 percent of a repeated join, and keeping it valid needs a signal on every table write, including the stores that compiled code makes inline on every target, which would cost every program.
