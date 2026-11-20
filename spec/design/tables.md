# Tables

A Lus table has an array part for the keys 1 to n and a hash part for every other key, as in Lua. This note describes how the two parts are stored, how the array part specializes by element kind, how small tables keep their parts in their own cell, how all of this interacts with the collector, and which further designs were measured. None of it is visible to programs. A table behaves exactly as a Lua table does whatever its storage.

## Layout

The table object holds its header, the metamethod absence cache, its metatable, the array part (a pointer, a length, and an element kind), the hash part, the weak mode, the read-only flag, the border hint of the length operator, and the size of the storage that trails it in its cell.

The hash part uses open addressing with linear probing over a power-of-two number of nodes, each a key and a value. Dead entries keep their key with a nil value until the next rehash, so `next` stays valid while a program clears fields during a traversal. A rehash sizes the array part to the largest power of two that is more than half full, as Lua does, and moves every other entry into a hash part kept under a load factor of three quarters. An array part in the backing allocator that grows and keeps its kind is reallocated, which extends it in place or remaps its pages without a copy. The resident memory of a list of three million booleans fell from 138 MB, which the copies of each doubling left behind, to 73 MB.

A table created for a known number of keys, as a constructor creates it, sizes a small hash part exactly. A part of at most four nodes may hold a key in every node, so the record `{x = 1, y = 2}` takes two nodes and its whole table fits a 128-byte cell. A probe for an absent key ends at the first empty node, and a part with no empty node is recognized from its count of used nodes and probed with a bound of one visit per node. A part that grows later follows the load factor again. On `tables.lus`, which keeps three million such records alive, this took the heap from 770 MB to 560 MB and the run from 0.189 to 0.165 seconds.

## Element kinds

The array part has one of four kinds.

- `none`: every slot is nil.
- `int`: every slot is nil or an integer.
- `float`: every slot is nil or a float.
- `boxed`: slots hold arbitrary values.

The first three kinds are unboxed. They store one 64-bit word per slot, the payload of the integer or float, which halves the memory of numeric arrays. A boxed part stores a full 16-byte value per slot.

Nil is the word `0x7FF4000000000000` in an unboxed part. As a float it is a signaling NaN, which no arithmetic produces. As an integer it is a large positive number that programs rarely store. Storing a number with exactly these bits makes the part boxed, so every integer and every float bit pattern survives a round trip through a table.

A load from an unboxed part compares the word with the nil word and otherwise rebuilds the value from the word and the kind. The integer codes of the `int` and `float` kinds equal the value tags they hold, so the rebuild is a single store of the word and the tag.

### Transitions

A new array part starts as `none`. A store follows these rules.

- Storing nil into an unboxed part writes the nil word and keeps the kind.
- Storing an integer into a `none` or `int` part makes or keeps it `int`.
- Storing a float into a `none` or `float` part makes or keeps it `float`.
- Every other store makes the part `boxed` first.

So an integer stored into a `float` part, or a float stored into an `int` part, boxes the part. This keeps the integer and float subtypes apart, which `math.type` and the formatting of numbers can observe. A part never narrows back to an unboxed kind, even if a program later stores only numbers into it again. A rehash keeps the kind of the part, and when a hash entry with an integer key moves into the array part, the rehash computes the kind that admits every entry before it allocates the new part. An array part of length zero keeps its kind as well, so a table that once held strings in its array part starts boxed when its array part grows again.

The interpreter stores into an array slot inline when the value fits the kind. A value that does not fit takes the generic path, which boxes the part and then stores. Constructors and vararg tables compute the kind of the whole list once and then copy it in. Native code makes the same inline loads and stores (`jit.md`), and it reads the layout it needs from `table.layout`, which is computed from the declarations of the table.

Traversal order does not depend on the kind. `next` walks the array part from index 1 and then the hash part, and a store that boxes the part during a traversal keeps every value at its index, so the traversal continues from the same key.

## Constructor size feedback

The C operand of `NEWTABLE` is the number of fields of the constructor, and it is only a hint for the size of the hash part. The interpreter remembers the table that the last `NEWTABLE` made, with the instruction and the collection cycle. When a store makes the hash part of that same table grow before the cycle ends, `ops.rawSet` raises the hint of the instruction to the number of keys the table holds, up to eight. The function that holds the instruction is alive until the next mark phase ends, so the instruction is safe to write during the cycle. A record that a program builds field by field, as `{}` followed by stores or `{key = k, value = v}` followed by `prev` and `next`, then gets its final hash part in its cell at construction, one allocation instead of two with a rehash between them. Code that a JIT tier compiled keeps the hint it read, which is correct with any hint.

On a loop that builds four million such nodes, the interpreter went from 0.218 s to 0.094 s. `lru` from the cross-language suite went from 1.83 s to 1.50 s. It allocates fewer bytes per node, and its peak memory still rose from about 400 MB to 530 MB, because its collections start later in terms of operations. Its live data is about 35 MB, so the peak there follows the pacing of the generational collector.

A store that creates an array part for a value other than a number allocates the part boxed, so the value lands with one allocation.

## Storage in the table cell

A table created with known sizes, as every constructor and `table.create` create them, keeps its first parts in its own cell when they fit in 512 bytes: the hash part first, then the array part. Building a small record or a short list then takes one allocation from the page heap, where separate parts would take one or two more from the backing allocator. The array part there reserves 16 bytes per slot, so an unboxed part boxes in place by walking down from the last slot. A part that outgrows the cell moves to the backing allocator as before, and the space it leaves stays with the cell until the table dies.

## Barriers and the collector

Integers and floats are not collectable, so a store into an unboxed part never runs the write barrier. Boxing a part copies only numbers and nil, so the conversion needs no barrier either. The store that caused it then runs the usual table barrier for its value. A table that is black or old when its part boxes is therefore handled exactly like any other table that receives a collectable value.

The marker traces only boxed array parts. An unboxed part adds nothing to the mark work, and a large numeric array no longer makes the marker read every slot. Weak tables never clear numbers, so unboxed parts of weak tables need no clearing either. The forward barrier for large tables counts the slots of the array part whatever its kind.

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
