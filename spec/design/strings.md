# Strings

Lus 2.0 strings hold text. Every string is well formed WTF-8, the superset of UTF-8 that also encodes lone surrogate code points. Raw bytes live in `vector` values. This split lets every string function work in characters, and lets text from Windows paths or UTF-16 sources round trip without loss.

## Characters

A character is one Unicode code point, including lone surrogates. Every string operation indexes by character:

- `#s` and `string.len(s)` return the number of characters.
- `string.sub(s, i, j)`, slices `s[i, j]`, `string.byte`, `string.find`, `string.match`, `string.gmatch`, and `string.gsub` positions are character positions.
- `string.byte(s, i, j)` returns code points and `string.char(...)` builds a string from code points.
- `string.reverse` reverses characters.
- `string.upper` and `string.lower` map ASCII letters and leave every other character unchanged.

## Patterns

Patterns match whole characters. `.` matches one character. A set such as `[éà]` may contain any characters, and ranges such as `[α-ω]` compare code points. The classes `%a`, `%d`, `%l`, `%s`, `%u`, `%w`, `%x`, `%p`, and `%c` describe ASCII characters. The pattern engine never splits a multi-byte character.

## Representation

A string object stores its byte length, its character count, its hash, and an ASCII flag. ASCII strings index any character in constant time. Non-ASCII strings build a breadcrumb index on first indexed access. The index records the byte offset of every 64th character, so any character is found by one lookup and a scan of at most 63 characters. Validation, character counting, breadcrumb construction, and the scan use vectorized loops.

The index also remembers two positions it found, each as a character index and a byte offset: where the last range started and where the last range ended. A lookup starts from the closest of these positions that lies between the breadcrumb and the character it wants, so a loop that walks forward through a string, such as a tokenizer reading `s:sub(i, i)` or a window `s:sub(i, i + 8)` moving one character at a time, scans only the distance it moves at both ends of the range. A lookup anywhere else costs what the breadcrumbs alone cost. A scan of fewer than sixteen characters reads one or two words inline and counts their lead bytes with a multiplication, and a step of one character reads the lead byte of the character it leaves.

A range that starts within sixteen characters after the start of the last one takes its start from that remembered position before anything else is looked at. Each call of a forward scan then waits for the previous call only through the one offset it reads, where the full choice between the breadcrumb and the remembered positions made it wait for more. On `unicode.lus` with the JIT off this and the one-character step took the run from 175 to 140 million cycles for 7 percent fewer instructions.

A string received from a worker message refers to a blob of bytes shared with the heap that sent it, and its cell holds a pointer to that blob in place of the bytes (`workers.md`). Short strings are interned, so equality between them is a pointer comparison. A string of up to 32 bytes hashes inline with a few multiplications in the manner of wyhash, and longer strings hash with wyhash itself. The string table probes linearly and stays at most half full. Each slot packs the pointer to a string with the top 16 bits of its hash, so a probe that passes other strings never loads them, and a lookup reads two neighboring slots at once and picks the candidate without a branch. The table halves itself after a collection that leaves it less than an eighth full. At most a quarter full, the table spent 32 to 64 bytes on every interned string, as much as the string header itself. At most half full it spends 16 to 32, and its smaller size keeps more of it in cache: `strings.lus`, which looks up a million different words, went from 0.171 to 0.141 seconds, and the peak memory of the `csv`, `template`, and `logs` programs of the cross-language suite fell by 16 to 32 MB.

`string.sub` and `setmetatable` run their common calls without a frame of their own (`jit.md`). On `unicode.lus` with the JIT off, remembering where ranges end and the inline scans took the run from 0.051 to 0.044 seconds. The common call of `string.sub` takes a string and integer positions, and the result is a substring found in or added to the string table.

## Substring views

A substring is a string of its own: its bytes are copied, and a short one is interned. The plan for 2.0 proposed that `sub` and slices return views into the buffer of their parent, with small results copied so that they never keep a large buffer alive. The two benchmarks that take substrings take small ones, nine characters in `unicode.lus` and words such as `item 12` in `strings.lus`, and a short string is interned by contract, because equality between short strings is a pointer comparison everywhere in the runtime and in native code. A view of a short substring would therefore still be copied and interned, and the benchmarks would not change.

What a view could save at most was measured by letting `string.sub` and the captures of the pattern functions return a fresh string that is neither hashed nor interned, which costs one allocation and one copy of a few bytes, as a view costs one allocation. The programs only count and take lengths, so they run correctly that way. Best of nine alternating runs, JIT off, ReleaseFast on an Apple silicon Mac:

| benchmark | interned | fresh string | cycles interned | cycles fresh |
|---|---:|---:|---:|---:|
| unicode | 0.043 s | 0.054 s | 181 M | 219 M |
| strings | 0.156 s | 0.128 s | 696 M | 553 M |
| patterns | 0.203 s | 0.201 s | 881 M | 880 M |

`unicode.lus` takes the same 148 000 substrings again and again. Interning finds each of them and allocates nothing, where a string per call makes two million objects for the collector, so the fresh strings are 21 percent slower. `strings.lus` captures a million different words from one long subject, each of which is found in a string table of a million entries that no cache holds, and skipping that lookup is 20 percent faster. The gain there comes from leaving a short string out of the string table, which is a change to what a string is and to every pointer comparison of strings, and it is the allocation, which a view needs as well, that loses on `unicode.lus`. Views are therefore kept out. A program that slices long substrings out of long text copies and hashes each of them, and a bench case of that kind is what would justify views of long results or a hash computed on first use.

## Long results

`table.concat`, the concatenation operator, and `tojson` build a long result in a buffer whose block keeps room for a string header in front of the bytes and for the terminating zero after them. When the result is too long for a small cell, the block shrinks to the string, takes the header, and becomes the string as a large object, so the bytes are held once. `table.concat` and the concatenation operator size their buffers exactly. `tojson` grows its buffer by half at a time, and the C allocator shrinks a block without moving it and without giving back its tail, so its string may keep up to a third of its block unused. Copying the text into a block of its exact size held the buffer and the string at once, and the allocator of macOS kept the freed buffer resident: the `json` program, whose text is 92 MB, peaked at 1102 MB with the copy and peaks at 1014 MB without it. A short result is interned as usual. In the cross-language suite this lowered the peak resident memory of `template`, which joins a 100 MB page, from 947 to 846 MB of heap, and of `wordfreq`, which joins a 70 MB text, from 656 to 588 MB.

Large objects take the alignment of the object header. On 64-bit targets that stays within what `malloc` guarantees, so the C allocator grows such a buffer with `realloc`. With a 16-byte alignment, above the 8 bytes that `malloc` guarantees on Apple silicon, the allocator could only allocate a new block, copy, and free the old one at every growth, and `tojson` of 50 MB of text peaked 145 MB higher.

## Concatenation

Concatenating a string that ends with a lead surrogate and a string that starts with a trail surrogate joins the pair into one supplementary character, as WTF-8 requires. Every other concatenation is a plain byte join.

## Bytes and vectors

Byte level data uses vectors.

- `vector.fromstring(s)` returns the WTF-8 bytes of a string.
- `vector.tostring(v [, i [, j [, mode]]])` decodes bytes `i` through `j` into a string. With mode `"strict"`, the default, invalid input raises an error naming the byte offset. With mode `"lossy"` each invalid sequence becomes U+FFFD.
- `string.pack` returns a vector and `string.unpack` and `string.packsize` read vectors.
- The `vector.archive` compressors accept a string or a vector and return a vector. The decompressors accept a vector or a string and return a vector, which `vector.tostring` turns back into text.
- `string.transcode(input, from, to)` converts between encodings. An input or output in a byte encoding such as `"utf-16le"`, `"latin1"`, `"base64"` decoding, or `"hex"` decoding is a vector. An input or output in a text encoding is a string.

## Input and output boundaries

Files opened in binary mode (`"rb"`, `"wb"`, and so on) read and write vectors. Files opened in text mode read strings and validate them. Invalid input in text mode raises an error with the byte offset, unless the file was opened with the option `{ lossy = true }`, which replaces each invalid sequence with U+FFFD. Writing accepts both strings and vectors in either mode. Command line arguments, environment variables, and file system paths decode as WTF-8 on Windows and as UTF-8 with lossy replacement elsewhere. Network reads return vectors.

## Interpolation

String interpolation produces a string. Interpolating a vector raises an error, because a vector holds bytes rather than text. Programs decode it explicitly with `vector.tostring`.

## Short concatenations

Most concatenations and interpolations join a few strings and integers into a short result, such as a prefix and a number. `ops.joinShort` writes such a result into a 64-byte buffer on the stack, with integers written by `ops.intDigits`, and hands it to the string table. A float, an exact number, a longer result, or a piece that starts with a trail surrogate goes to the general join, which formats any number and joins surrogate pairs. `"k" .. n` took 33 ns before and takes 14.5 ns, whether the result is new or already in the table. The csv program, which interpolates two million rows, retires 12 percent fewer instructions, and lru, which builds four million keys, runs 4 percent faster.

## Building long results

A result whose length is known before its bytes are written goes straight into its string. `state.newLongUninit` allocates a long string, the caller writes the bytes without allocating anything else, and `state.finishLong` sets the character count and the hash. `table.concat` sizes its result in a first pass over the table, and when every piece is a string the length is exact, so a long result is written in place and never passes through a buffer. A piece that starts with a trail surrogate may pair with the piece before it, and such a list takes the general path, which joins the pair.

`tojson` learns its length only at the end, so it writes into blocks of 64 KB and copies them once into a string of the exact size. The blocks never move while the text grows, and the string holds no unused capacity.

## Pattern searches

A search that does not start at an anchor tries the pattern at every position. When the pattern begins with a literal text, the search jumps between occurrences of that text. When it begins instead with a single class that must match once, such as `[&<>"']` or `%a+`, the bytewise matcher computes the set of bytes that class accepts and skips every byte outside it before it starts a match. `find`, `match`, `gmatch`, and `gsub` share this. On `template` from the cross-language suite, which escapes a million titles with `gsub(s, "[&<>\"']", ESC)`, the skip together with the decimal fast paths below took the run from 1.38 s to 1.15 s.

The state keeps the last pattern whose start bytes it computed, keyed by the text of the pattern, so a loop that calls `gsub` with the same pattern computes them once. The strings of single ASCII characters, which captures and `string.sub` produce often, are made fixed the first time and `newStringKnown` returns them without a lookup. These took `template` from 1.20 s to 1.09 s, best of three alternating runs on a loaded machine.

The builder behind `string.format`, `gsub`, and the other functions that assemble a result starts with its 512-byte stack buffer as capacity and copies a piece that fits inline, so a short result never calls the allocator or a copy routine. It retires 3 percent fewer instructions on `template` and `logs` with the JIT off. A piece of up to 16 bytes is copied by `ops.copyBytes` with two overlapping moves of a word or half a word, without a call to the C library. The builder, the JSON writer, `ops.joinShort`, and the appends of `table.concat` and the general join use it, and with the JIT off it saves 5.6 percent of the instructions of `template`, 3 percent of `json`, and 2 percent of `csv`.

`string.format` writes `%d`, `%i`, and `%u` with a table of digit pairs, and `tonumber` and arithmetic coercion read a plain decimal integer of at most 18 digits directly, without the lexer. `ops.intDigits` is the one integer writer that concatenation, `string.format`, and `tojson` use.

## JSON and CSV

The JSON parser keeps the values of every open container on the Lus stack, which roots them for the collector, and makes the table at its exact size when the container closes: an array with `storeList`, an object with one store per key into a hash part sized for all of them. A container with more than 1024 waiting values moves them into its table early, and near the stack limit every value moves at once, so a parse needs stack only for the containers that are still open. String scanning checks 16 bytes at a time for a quote, a backslash, a control character, or a byte that is not ASCII, and an ASCII string goes to the string table without a second pass to validate and count it. Integers of at most 18 digits are read as they are scanned. Objects in a document tend to repeat their keys, so short ASCII keys go through a cache of 256 entries that holds the keys this parse made, and a repeated key skips the string table. Every cached key waits on the stack or sits in a table of the result, and a key whose value is null, which the object never stores, leaves the cache when its object closes. A repeated key replaces the earlier value, which may be a container whose keys were cached and are now garbage, so an object that stored fewer keys than it read empties the cache. A key found in the cache is revived like a key found in the string table, in case the sweep is about to free it. The cache took `fromjson` on the million records from 0.23 s to 0.19 s. The inline copy and the skipped `transform` took `tojson` on them from 0.26 s to 0.16 s.

The writer copies a piece that fits the room left inline, calls `transform` only when a filter is set or the value is a table with a metatable, copies runs of bytes that need no escape 16 at a time, writes integers with `ops.intDigits`, and counts the continuation bytes it writes, so the result needs no pass to count its characters. It decides between array and object from the table parts directly, stopping at the first key that is not a positive integer, and it walks the hash part by node in the order of `next`. A filter or `__json` runs Lus code, so the walk keeps the current key and every table it writes on the stack, and when that code moved the hash part, the walk finds the key again and continues after it. The path of open tables, for cycle detection, is a short list.

`fromcsv` cuts its fields from a string, which is valid WTF-8 already, so a field needs no validation, and an ASCII source makes every field ASCII. The fields of a row wait on the stack and the row table is made at its exact size.

Wall times in seconds for the cross-language programs, best of three alternating runs on an Apple silicon Mac that other work was loading, with peak resident memory. The JSON phases alone went from 0.36 s to 0.19 s for `tojson` and from 0.50 s to 0.23 s for `fromjson`.

| program | before | after | peak before | peak after |
|---|---:|---:|---:|---:|
| json | 1.23 | 0.88 | 1109 MB | 1078 MB |
| csv | 1.65 | 1.31 | 1129 MB | 980 MB |
| template | 1.39 | 1.11 | 1061 MB | 960 MB |
| wordfreq | 1.20 | 1.13 | 656 MB | 588 MB |
| logs | 1.12 | 1.09 | 527 MB | 526 MB |

