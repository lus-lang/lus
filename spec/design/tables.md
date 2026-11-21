# Tables

A Lus table has an array part for the keys 1 to n and a hash part for every other key, as in Lua. This note describes how the two parts are stored, how the array part specializes by element kind, how small tables keep their parts in their own cell, how all of this interacts with the collector, and which further designs were measured. None of it is visible to programs. A table behaves exactly as a Lua table does whatever its storage.

## Layout

The table object takes 48 bytes on 64-bit targets. The object header leaves five bytes over after its tag, flags, and finalizer state, and a table keeps its read-only flag and the border hint of the length operator there. The rest holds the metatable, the pointer of the array part, and the pointer of the hash part, then the length of each part, the count of used nodes, the metamethod absence cache, the element kind of the array part, and one byte for the weak mode and the size of the storage that trails the table in its cell. The lengths are 32 bits wide, and native code reads them so. The size of the hash part, a power of two, gives its logarithm when one is needed.

A table took 64 bytes before. A table is the most common object of most programs, and the 16 bytes count once per table: on the cross-language suite, ReleaseFast on an Apple M4 Max, the peak resident memory of `json`, which holds four million tables, fell from 825 to 742 MB, and of `csv`, whose two million rows are tables, from 709 to 695 MB, and of `lru` from 76 to 72 MB. Times stayed the same or improved: in the best of seven runs `lru` went from 1.34 to 1.26 seconds, and in `tests/bench/run.sh` `tables.lus` from 0.109 to 0.095 and `interp.lus` from 1.06 to 0.95, while the other benchmarks stayed within the noise of the machine in every column.

The hash part uses open addressing with linear probing over a power-of-two number of nodes, each the payloads of a key and a value (see Hash nodes below). Dead entries keep their key with a nil value until the next rehash, so `next` stays valid while a program clears fields during a traversal. A rehash sizes the array part to the largest power of two that is more than half full, as Lua does, and moves every other entry into a hash part kept under a load factor of three quarters. A large list grows by half of its length instead: when the part would reach at least 65,536 slots and its integer keys run from 1 without a gap, it takes one and a half times the length, rounded up to 1024 slots, so that at most a third of it stays empty where the power of two left up to half of it empty. The 21.6 million words that `wordfreq` joins took a part of 33.5 million slots, and the peak of the program fell from 334 to 270 MB. The rehash counts the keys of an unboxed part one range at a time in a loop without branches, so the extra rehashes leave the time the same. An array part in the backing allocator that grows and keeps its kind is reallocated, which extends it in place or remaps its pages without a copy. The resident memory of a list of three million booleans fell from 138 MB, which the copies of each doubling left behind, to 73 MB.

A table created for a known number of keys, as a constructor creates it, sizes a small hash part exactly. A part of at most four nodes may hold a key in every node, so the record `{x = 1, y = 2}` takes two nodes and its whole table fits a 128-byte cell. A probe for an absent key ends at the first empty node, and a part with no empty node is recognized from its count of used nodes and probed with a bound of one visit per node. A part that grows later follows the load factor again. On `tables.lus`, which keeps three million such records alive, this took the heap from 770 MB to 560 MB and the run from 0.189 to 0.165 seconds.

## Element kinds

The array part has one of six kinds.

- `none`: every slot is nil.
- `int`: every slot is nil or an integer.
- `float`: every slot is nil or a float.
- `string`: every slot is nil or a string.
- `table`: every slot is nil or a table.
- `boxed`: slots hold arbitrary values.

The first five kinds are unboxed. They store one 64-bit word per slot, the payload of the integer, float, string, or table, which halves the memory of numeric arrays, of lists of strings, and of lists of records. A boxed part stores a full 16-byte value per slot.

Nil is the word `0x7FF4000000000000` in an unboxed part. As a float it is a signaling NaN, which no arithmetic produces. As an integer it is a large positive number that programs rarely store. Storing a number with exactly these bits makes the part boxed, so every integer and every float bit pattern survives a round trip through a table.

The payload of a string or a table is its address, which never equals the nil word. A load from an unboxed part compares the word with the nil word and otherwise rebuilds the value from the word and the kind. The integer codes of the unboxed kinds equal the value tags they hold, so the rebuild is a single store of the word and the tag.

### Transitions

A new array part starts as `none`. A store follows these rules.

- Storing nil into an unboxed part writes the nil word and keeps the kind.
- Storing an integer into a `none` or `int` part makes or keeps it `int`.
- Storing a float into a `none` or `float` part makes or keeps it `float`.
- Storing a string into a `none` or `string` part makes or keeps it `string`.
- Storing a table into a `none` or `table` part makes or keeps it `table`.
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

## Stores into full parts

A hash part of up to `full_max` nodes may hold a key in every node, which keeps small records compact. `table.storeStr`, the store that the interpreter, the baseline helpers, and the field caches share, finds a key that such a full part holds by visiting each of its few nodes once, and stores the value there. Only a new key in a full part takes the general path, which rehashes. A record that gained its last fields after construction, such as an LRU node with `key`, `value`, `prev`, and `next`, fills its part, and the stores that relink it then stay on the fast path. On the lru program, with 48-byte tables, this retires 11 percent fewer instructions with the JIT off and 3 percent fewer with it on.

## Storage in the table cell

A table created with known sizes, as every constructor and `table.create` create them, keeps its first parts in its own cell when they fit in 504 bytes, which the cell counts in units of 8 bytes: the tag area and the nodes of the hash part first, then the array part. Building a small record or a short list then takes one allocation from the page heap, where separate parts would take one or two more from the backing allocator. The array part there reserves 16 bytes per slot, so an unboxed part boxes in place by walking down from the last slot. A part that outgrows the cell moves to the backing allocator as before, and the space it leaves stays with the cell until the table dies. A list that a parser makes once it read every value, as `fromjson` makes its arrays, takes one word per slot in the cell when every value fits an unboxed kind. Such a part boxes into the backing allocator. The two-string lists of the `json` program take 80 bytes each where they took 96, which lowers its live data by 15 MB.

A constructor learns the same from the lists it made. Its inline cache entry, which a constructor otherwise leaves unused, records whether the lists of its tables fitted an unboxed kind when `setlist` filled them, and the constructor then reserves one word per slot in the cell, in the interpreter, in baseline code, and in optimized code alike. A list that boxes, at `setlist` or at the store that boxes it while the table is still the last one the constructor made, marks the site for good, so that a site whose lists differ never moves one part after another to the backing allocator. The other `json` lists, the tags of the records it builds with a constructor, then take 64 bytes where they took 80, and the program peaks at 712 MB where it peaked at 729 MB. Each constructor runs a few more instructions to read the entry, 0.7 percent of `methods.lus` with the JIT off, within the noise of its time. A store that changes the kind of the list of that table teaches the site as well, so a list built by appending, as `local tags = {}` followed by `tags[j] = name`, takes one word per slot in its cell from the next table on. The tag lists of `template` take 72 bytes where they took 96, and its million records 230 MB where they took 253 MB.

## Barriers and the collector

Integers and floats are not collectable, so a store of a number into an unboxed part never runs the write barrier. A store into a `string` or `table` part runs the usual table barrier for its value, in the interpreter and in both tiers of native code, which test the tag of the stored value after every unboxed store. Boxing a part copies values that the table already holds, so the conversion needs no barrier. The store that caused it then runs the usual table barrier for its value. A table that is black or old when its part boxes is therefore handled exactly like any other table that receives a collectable value.

The marker traces only boxed array parts. A numeric part adds nothing to the mark work, and a large numeric array never makes the marker read every slot. A `string` part has every string it holds marked, and since strings reference nothing, none of them goes on the gray stack. A `table` part has its tables marked and traced like the values of a boxed part, unless the values of its table are weak, and the collector clears the dead tables of a weak part to nil as it clears boxed slots. Weak tables never clear numbers or strings, so the other unboxed parts of weak tables need no clearing.

A node whose value is nil is dead. It keeps its key until the next rehash, so that `next` continues from a key that a traversal removed, and so that a later store of the same key takes the node again. Every probe that passes a dead node compares its key with the key it looks for. Strings longer than 40 bytes, bigints, and decimals compare by content, which reads the key, and an interned string compares by address at a node index that an inline cache may have predicted. The marker therefore marks the string, bigint, and decimal keys of dead nodes as it marks them in live ones, in strong and weak tables alike, and such a key lives as long as its node. Since strings and numbers reference nothing, a dead node retains at most its own key, and the rehash that drops the node releases it. Every other collectable key compares by address alone, so the marker leaves the key of a dead node to die. A new object that takes its address is then the only value that can name the node, and its first store takes the node as its own. `tests/conformance/deadkeys_test.lus` covers removed keys across collections.

Lists of strings are common: the lines of a file, the fields of a CSV row, the words of a text, the pieces a program joins with `table.concat`. In the cross-language suite the `string` kind took the peak resident memory of `wordfreq`, whose list of 21.6 million words has an array part of 33.5 million slots, from 588 to 332 MB, and of `csv`, whose two million rows each hold six strings, from 917 to 749 MB. Times stayed within the noise of the machine. The `table` kind then took `json`, whose two lists of a million records each are tables of tables, from 743 to 727 MB, and `csv`, whose list of two million rows is one, from 530 to 513 MB, in the same time. The forward barrier for large tables counts the slots of the array part whatever its kind.

The parts that trail a table in its cell belong to the cell. Sweeping a dead table frees only the parts that live in the backing allocator, and the size of a table object includes its trailing storage.

## Aggregates

`table.sum`, `table.mean`, and `table.stdev` add their terms in a fixed order. The term for index i goes into accumulator (i - 1) % 8, and the eight accumulators combine pairwise: accumulator j with j + 4, then the first two of those sums with the last two, then the final pair. Integer and float array parts run this order eight slots at a time with Zig vector operations, and the nil word masks out holes. Boxed parts, tables with metatables, and keys beyond the array part follow the same order one element at a time. The results are therefore identical bit for bit across kinds and platforms, and the order is part of the specification of each function.

## Shapes

A table whose hash part holds only short string keys keeps those keys in a shape that every table with the same keys shares, and keeps only the values in its own storage. A record with four fields takes 88 bytes where a four-node hash part made it 120, with three fields 80 bytes where it took 120, and with six fields 104 bytes where it took 192. Records are the bulk of the heap of most programs, so the saving counts once per record: `lru` holds two records per cache entry, and `json` holds two million.

A shape is an ordered list of keys. Slot i of a table holds the value of key i of its shape. Every table starts with the empty shape. Storing a key that the shape lacks moves the table to the child shape that adds that key at the next slot, creating the child the first time. Shapes therefore form a tree rooted at the empty shape, and tables that receive the same keys in the same order share one shape. A shape finds a key by scanning its keys up to eight of them, and through a hash index of its own past that, so a lookup costs about what a probe of a hash part costs (`shape.zig`).

Shapes live outside the collected heap, and a state frees its shapes when it closes. Each shape has a 16-bit id from a registry that every state of the process shares, so a table names its shape with 16 bits and finds it without its state, and a state that closes returns its ids. The empty shape holds no key of any heap, so all states share it as id 0, and each state keeps its own list of the children of the root. The interned strings that shapes use as keys stay alive with the state. To keep that memory bounded, a shape holds at most 32 keys, has at most 32 children, the root has at most 256 children in one state, and the registry holds at most 65,534 shapes. A store that would pass a limit turns the table into a dictionary instead.

### Layout of a shaped table

A shaped table keeps the 48-byte header. `hash_used` holds the id of its shape with its top bit set, which no count of a hash part reaches, so one comparison tells a shaped table from a dictionary and names its shape. `hash_len` is zero, so every path that probes hash nodes sees an empty hash part, and the probes that native code runs inline fall through to their helpers. `hash_ptr` points to the slots, one payload word each. The byte just below the first slot holds the number of slots, which is at least the number of keys of the shape, and the tag of slot i is the byte `i + 2` below the first slot, in a tag area rounded to 8 bytes. A table without slots points into a static block whose bytes below the pointer are zero, so native code may read its count of slots. The slots live in the cell of the table when the constructor knows how many keys to expect, as a hash part does, and in the backing allocator otherwise.

A slot whose tag is nil holds no value. Assigning nil to a field sets the tag of its slot to nil and keeps the shape, so the key keeps its slot and a later store of the same key fills it again. This matches the dead nodes of a hash part, and `next` stays valid while a traversal clears fields.

### Dictionary mode

A table leaves shapes for good, and becomes a dictionary with the hash part described above, when it receives a key that is not a short string outside its array part, or when a store would pass a shape limit. The conversion moves every key of the shape into a hash part, with a dead node for a slot without a value, so that `next` continues from a key that a traversal cleared. A shaped table that receives integer keys grows its array part as a dictionary would and keeps its shape. The tables that the standard library makes while a state opens, the registry, and the globals are dictionaries from the start: they are namespaces and metatables that code reads by name, and making them shaped would build a chain of shapes for each of them, which cost `startup.lus`, which starts 2,000 worker states, 13 percent of its time.

A metatable and the table that its `__index` names may be shaped. The interpreter predicts a slot of their shapes and checks the key there, the optimizing tier guards their shapes as it guards the receiver, and the baseline tier, whose inline code follows `__index` through node predictions, calls its helper for a shaped one.

### Iteration order

`next` walks the array part, then the slots of a shaped table in order, skipping slots without a value. A shaped table therefore yields its keys in the order its shape added them, which is the order in which keys were first stored into the tables that share the shape. A constructor that learned a shape gives its tables that order from the start. A dictionary yields its keys in the order of its hash part, as before. The order stays the same while a traversal assigns to existing fields or clears them.

### Caches

The inline cache entry of a field access keeps the slot of its own lookup in `own` and the id of the shape it saw in `shape`. A hit compares `hash_used` with the cached id and loads the slot, one comparison where a dictionary hit compares the key and its tag. Native code compiles a constant key, so the shape alone proves where the key is. The interpreter, whose string fast paths also serve keys that change from one run to the next, checks the key in the slot as well. An entry with a shape and no slot records that the shape lacks the key, and the baseline tier then follows `__index` without probing the receiver. When `hash_used` names another shape or no shape, the access tries the node prediction of a dictionary, and then the general path, which updates the entry. A site that sees many shapes keeps the last one, and it pays a shape lookup on each miss, as a dictionary site pays a probe.

A store that adds a key records the transition in the same entry: the shape before in `index`, the shape after in `holder`, and the new slot in `own`. The next store at that site into a table of the shape before moves the table to the shape after and fills the slot inline, when the slots of the table have room. Any other update of `own` at a store site clears the transition, so the slot it names is always the one the transition adds. The interpreter also checks that the slot is the last one of the shape after and holds the key.

A constructor learns the shape its tables reach, as it learns their sizes. When the last table that a `newtable` instruction made moves to a child shape before the collection cycle ends, the instruction records that shape in the `shape` of its entry, and the next tables start with it and with nil in every slot. It moves only to a shape that adds keys to the one it has, so a site whose tables differ keeps the first one. A record built as `{key = k, value = v}` followed by stores into `prev` and `next` then takes its four slots in its cell at construction, and each of its stores hits an existing slot.

The optimizing tier guards the shape id that the sample table has. The guard proves both where a key lives and that a key is absent, so a field load needs one guard where a node prediction needed three, and a load of an absent key needs one guard where the walk of a probe sequence needed several. A store of a new key into a shaped table guards the shape and the room in its slots, and then sets the shape after and fills the slot. A table that the tier allocates follows the transitions of its keys at compile time, and a record that the tier kept unallocated gets the shape of its keys, in the order they arrived, when it is allocated.

The WebAssembly tier calls two small functions that each module holds, one that loads a slot and one that stores into a slot, instead of repeating the test of the shape inline at every access. Inline tests made the module of the longest function that the conformance suite compiles grow past 4 MB, the size up to which the host compiles a module at once.

### The collector

Tracing a shaped table marks the values its slots hold. Its keys stay alive with the state, so they need no marking. Weak keys never clear a string, so a weak mode of a shaped table takes effect on its values only, and the collector clears the slots whose values died.

### Measurements

Peak resident memory and best wall time of the cross-language suite, ReleaseFast on an Apple M4 Max, best of three. The baseline is the `rewrite` branch before shapes. The after column includes the pause of 175 (`gc.md`), without which `lru` peaks at 48 MB and `logs` at 406 MB.

| program | before | after | time before | time after |
|---|---:|---:|---:|---:|
| lru | 53 MB | 40 MB | 0.87 s | 0.80 s |
| json | 658 MB | 498 MB | 0.48 s | 0.50 s |
| template | 538 MB | 475 MB | 0.55 s | 0.54 s |
| logs | 408 MB | 301 MB | 0.70 s | 0.72 s |
| csv | 450 MB | 450 MB | 0.62 s | 0.66 s |
| wordfreq | 267 MB | 267 MB | 0.97 s | 0.95 s |

`csv` loses 2 percent to shapes, which come from the lookups of its region names in a table of eight fields with keys that change on every row, and 3 percent to the pause. On `tests/bench`, `tables.lus` went from 0.098 to 0.082 seconds and `fullgc.lus` from 0.058 to 0.051. `messages.lus` and `patterns.lus` are 2 to 4 percent slower, and the others are within the noise of the machine.

## Designs measured and kept out

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
