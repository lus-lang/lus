# Tables

A Lus table has an array part for the keys 1 to n and a hash part for every other key, as in Lua. This note describes how the two parts are stored, how the array part specializes by element kind, how small tables keep their parts in their own cell, how all of this interacts with the collector, and which further designs were measured. None of it is visible to programs. A table behaves exactly as a Lua table does whatever its storage.

## Layout

The table object takes 48 bytes on 64-bit targets. The object header leaves five bytes over after its tag, flags, and finalizer state, and a table keeps its read-only flag and the border hint of the length operator there. The rest holds the metatable, the pointer of the array part, and the pointer of the hash part, then the length of each part, the count of used nodes, the metamethod absence cache, the element kind of the array part, and one byte for the weak mode and the size of the storage that trails the table in its cell. The lengths are 32 bits wide, and native code reads them so. The size of the hash part, a power of two, gives its logarithm when one is needed.

A table took 64 bytes before. A table is the most common object of most programs, and the 16 bytes count once per table: on the cross-language suite, ReleaseFast on an Apple M4 Max, the peak resident memory of `json`, which holds four million tables, fell from 825 to 742 MB, and of `csv`, whose two million rows are tables, from 709 to 695 MB, and of `lru` from 76 to 72 MB. Times stayed the same or improved: in the best of seven runs `lru` went from 1.34 to 1.26 seconds, and in `tests/bench/run.sh` `tables.lus` from 0.109 to 0.095 and `interp.lus` from 1.06 to 0.95, while the other benchmarks stayed within the noise of the machine in every column.

The hash part uses open addressing with linear probing over a power-of-two number of nodes, each the payloads of a key and a value (see Hash nodes below). Dead entries keep their key with a nil value until the next rehash, so `next` stays valid while a program clears fields during a traversal. A rehash sizes the array part to the largest power of two that is more than half full, as Lua does, and moves every other entry into a hash part kept under a load factor of three quarters. An array part in the backing allocator that grows and keeps its kind is reallocated, which extends it in place or remaps its pages without a copy. The resident memory of a list of three million booleans fell from 138 MB, which the copies of each doubling left behind, to 73 MB.

A table created for a known number of keys, as a constructor creates it, sizes a small hash part exactly. A part of at most four nodes may hold a key in every node, so the record `{x = 1, y = 2}` takes two nodes and its whole table fits a 128-byte cell. A probe for an absent key ends at the first empty node, and a part with no empty node is recognized from its count of used nodes and probed with a bound of one visit per node. A part that grows later follows the load factor again. On `tables.lus`, which keeps three million such records alive, this took the heap from 770 MB to 560 MB and the run from 0.189 to 0.165 seconds.

## Element kinds

The array part has one of five kinds.

- `none`: every slot is nil.
- `int`: every slot is nil or an integer.
- `float`: every slot is nil or a float.
- `string`: every slot is nil or a string.
- `boxed`: slots hold arbitrary values.

The first four kinds are unboxed. They store one 64-bit word per slot, the payload of the integer, float, or string, which halves the memory of numeric arrays and of lists of strings. A boxed part stores a full 16-byte value per slot.

Nil is the word `0x7FF4000000000000` in an unboxed part. As a float it is a signaling NaN, which no arithmetic produces. As an integer it is a large positive number that programs rarely store. Storing a number with exactly these bits makes the part boxed, so every integer and every float bit pattern survives a round trip through a table.

The payload of a string is its address, which never equals the nil word. A load from an unboxed part compares the word with the nil word and otherwise rebuilds the value from the word and the kind. The integer codes of the unboxed kinds equal the value tags they hold, so the rebuild is a single store of the word and the tag.

### Transitions

A new array part starts as `none`. A store follows these rules.

- Storing nil into an unboxed part writes the nil word and keeps the kind.
- Storing an integer into a `none` or `int` part makes or keeps it `int`.
- Storing a float into a `none` or `float` part makes or keeps it `float`.
- Storing a string into a `none` or `string` part makes or keeps it `string`.
- Every other store makes the part `boxed` first.

So an integer stored into a `float` part, or a float stored into an `int` part, boxes the part. This keeps the integer and float subtypes apart, which `math.type` and the formatting of numbers can observe. A part never narrows back to an unboxed kind, even if a program later stores only numbers into it again. A rehash keeps the kind of the part, and when a hash entry with an integer key moves into the array part, the rehash computes the kind that admits every entry before it allocates the new part. An array part of length zero keeps its kind as well, so a table that once held strings in its array part starts boxed when its array part grows again.

The interpreter stores into an array slot inline when the value fits the kind. A value that does not fit takes the generic path, which boxes the part and then stores. Constructors and vararg tables compute the kind of the whole list once and then copy it in. Native code makes the same inline loads and stores (`jit.md`), and it reads the layout it needs from `table.layout`, which is computed from the declarations of the table.

Traversal order does not depend on the kind. `next` walks the array part from index 1 and then the hash part, and a store that boxes the part during a traversal keeps every value at its index, so the traversal continues from the same key.

## Constructor size feedback

The C operand of `NEWTABLE` is the number of fields of the constructor, and it is only a hint for the size of the hash part. The interpreter remembers the table that the last `NEWTABLE` made, with the instruction and the collection cycle. When a store makes the hash part of that same table grow before the cycle ends, `ops.rawSet` raises the C hint of the instruction to the number of keys the table holds, and when the array part grows, it raises the B hint to the number of elements, each up to eight. A list such as `local escaped = {}` followed by `escaped[j] = v` for a few values then gets its array part at construction too. The function that holds the instruction is alive until the next mark phase ends, so the instruction is safe to write during the cycle. A record that a program builds field by field, as `{}` followed by stores or `{key = k, value = v}` followed by `prev` and `next`, then gets its final hash part in its cell at construction, one allocation instead of two with a rehash between them. Code that a JIT tier compiled keeps the hint it read, which is correct with any hint.

On a loop that builds four million such nodes, the interpreter went from 0.218 s to 0.094 s. `lru` from the cross-language suite went from 1.83 s to 1.50 s. It allocates fewer bytes per node, and its peak memory still rose from about 400 MB to 530 MB, because its collections start later in terms of operations. Its live data is about 35 MB, so the peak there follows the pacing of the generational collector.

A store that creates an array part for a value other than a number allocates the part boxed, so the value lands with one allocation.

## Hash nodes

A node holds the payloads of its key and its value, 16 bytes. Their tags live apart, two bytes per node, in a tag area just below the first node, and they run backward: the tags of node i are `2 * i` bytes below those of node 0. The address of a tag therefore depends on the index of its node alone, never on the size of the part, so code that knows the index of a node, as the inline caches and optimized code do, finds both its payload and its tags at fixed distances from the first node. The tag area is rounded up to 8 bytes, which keeps the nodes aligned.

A node whose key tag is nil is empty, and every reader tests the tag before it trusts a payload. A new part clears only its tag area, which takes a single store for a part of up to four nodes. A value moves between a node and a register as a payload word and a tag byte, where a node of two full values moved as 16 bytes.

An 8-node part takes 144 bytes where it took 256, and a 2-node part 40 where it took 64. A record with six fields, which takes eight nodes, fits a 224-byte cell with its table where it took a 320-byte cell. On the cross-language suite, ReleaseFast on an Apple M4 Max, the new nodes took the peak resident memory of `json`, which keeps two million such records, from 1055 to 855 MB, of `lru` from 89 to 80 MB, and of `logs` from 517 to 493 MB. `csv` rose from 694 to 707 MB. The size class of 208 bytes then took `json` to 831 MB (`gc.md`). `lru`, which reads and writes a map of 50,000 string keys, became faster, 1.44 s against 1.24 s in the best of five runs. In `tests/bench/run.sh`, `interp` and `messages` became 8 to 10 percent faster, and every other benchmark stayed within the noise of the machine in every column, `methods` included, whose baseline column is 2 percent slower.

A node of 32 bytes held two full values, and native code copied a value with one 16-byte move. Three things kept the split layout as fast. Code that knows the index of a node computes the address of its tags with one shifted subtraction. A field read loads both tags of a node with one 16-bit load. A new part clears only its tag area, where clearing whole nodes had cost every small constructor a few stores more, and a call to `memset` once the compiler merged the stores of the different sizes.

## Storage in the table cell

A table created with known sizes, as every constructor and `table.create` create them, keeps its first parts in its own cell when they fit in 512 bytes: the tag area and the nodes of the hash part first, then the array part. Building a small record or a short list then takes one allocation from the page heap, where separate parts would take one or two more from the backing allocator. The array part there reserves 16 bytes per slot, so an unboxed part boxes in place by walking down from the last slot. A part that outgrows the cell moves to the backing allocator as before, and the space it leaves stays with the cell until the table dies. A list that a parser makes once it read every value, as `fromjson` makes its arrays, takes one word per slot in the cell when every value fits an unboxed kind. Such a part boxes into the backing allocator. The two-string lists of the `json` program take 80 bytes each where they took 96, which lowers its live data by 15 MB.

## Barriers and the collector

Integers and floats are not collectable, so a store of a number into an unboxed part never runs the write barrier. A store into a `string` part runs the usual table barrier for its string, in the interpreter and in both tiers of native code, which test the tag of the stored value after every unboxed store. Boxing a part copies values that the table already holds, so the conversion needs no barrier. The store that caused it then runs the usual table barrier for its value. A table that is black or old when its part boxes is therefore handled exactly like any other table that receives a collectable value.

The marker traces only boxed array parts. A numeric part adds nothing to the mark work, and a large numeric array never makes the marker read every slot. A `string` part has every string it holds marked, and since strings reference nothing, none of them goes on the gray stack. Weak tables never clear numbers or strings, so unboxed parts of weak tables need no clearing either.

Lists of strings are common: the lines of a file, the fields of a CSV row, the words of a text, the pieces a program joins with `table.concat`. In the cross-language suite the `string` kind took the peak resident memory of `wordfreq`, whose list of 21.6 million words has an array part of 33.5 million slots, from 588 to 332 MB, and of `csv`, whose two million rows each hold six strings, from 917 to 749 MB. Times stayed within the noise of the machine. The forward barrier for large tables counts the slots of the array part whatever its kind.

The parts that trail a table in its cell belong to the cell. Sweeping a dead table frees only the parts that live in the backing allocator, and the size of a table object includes its trailing storage.

## Aggregates

`table.sum`, `table.mean`, and `table.stdev` add their terms in a fixed order. The term for index i goes into accumulator (i - 1) % 8, and the eight accumulators combine pairwise: accumulator j with j + 4, then the first two of those sums with the last two, then the final pair. Integer and float array parts run this order eight slots at a time with Zig vector operations, and the nil word masks out holes. Boxed parts, tables with metatables, and keys beyond the array part follow the same order one element at a time. The results are therefore identical bit for bit across kinds and platforms, and the order is part of the specification of each function.

## Designs measured and kept out

### Hidden-class shapes

The interpreter caches string-keyed field accesses by predicting the hash node that held the key last time. A hit compares the key pointer in the predicted node and loads the value next to it. A shape design would compare a shape pointer and load a fixed slot, which costs the same on a hit. Shapes would win only where the prediction misses.

Counting the cache outcomes on the benchmarks shows that the prediction almost never misses on keys that exist. On `tables.lus` the field loads hit 5,999,998 times and miss 3 times. On `methods.lus` they hit 39,999,994 times and miss 5,000,013 times, and every miss there is the lookup of a method name in the instance itself, a key the instance never holds, before the cache finds it through `__index`. On a microbenchmark a field load costs about 0.5 ns over an empty loop iteration, and a load through `__index` costs about 3.5 ns. A shape that also cached absence could save at most about 3 ns on each of the 5,000,000 inherited lookups of `methods.lus`, under 15 ms of a run of about 300 ms, and it would add transition trees, shape objects for the collector to trace, and a dictionary mode for tables with deletes or non-string keys. The measured cost of the constructor stores pointed to the allocation of the parts, not to finding the slots, and storing small parts in the table cell removed most of it. Lus therefore keeps the slot-prediction caches as its field caches.

### Template constructors

The compiler already sizes every constructor: `NEWTABLE` carries the number of list items and of fields, so a constructor allocates its parts once. With the parts in the table cell, a constructor with two fields costs about 14 ns, of which about 6 ns is the empty table and the loop around it. Copying a template hash part could save a share of the remaining field stores, and the plain `NEWTABLE` stays as the constructor op.

## Measurements

Wall times in seconds, best of five runs, ReleaseFast on an Apple silicon Mac. The baseline is the `rewrite` branch at the merge of the page heap and generational collector. `luajit -joff` runs LuaJIT 2.1 with its JIT disabled.

| benchmark | before | after | luajit -joff |
|---|---:|---:|---:|
| arrays | 0.328 | 0.276 | 0.255 |
| closures | 0.103 | 0.102 | 0.136 |
| data | 0.449 | 0.035 | 0.283 |
| fib | 0.065 | 0.065 | 0.037 |
| gcpause | 0.452 | 0.435 | 0.477 |
| interp | 1.152 | 1.155 | 2.146 |
| loop | 0.259 | 0.245 | 0.260 |
| methods | 0.403 | 0.309 | 0.249 |
| patterns | 0.216 | 0.218 | 0.260 |
| strings | 0.185 | 0.179 | 0.250 |
| tables | 0.223 | 0.196 | 0.167 |
| unicode | 0.108 | 0.102 | 0.033 |

The `interp` row varies by about 5 percent from run to run on this machine, so it comes from a separate series of seven alternating runs. `arrays` gains from unboxed loads and stores, `data` from the vector loops (the aggregates alone drop from 0.43 s to 0.017 s, and table construction is most of what remains), and `methods` and `tables` from keeping small parts in the table cell. LuaJIT runs `data` as plain Lua loops from `lua/data.lua`.
