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

Short strings are interned, so equality between them is a pointer comparison. A string of up to 32 bytes hashes inline with a few multiplications in the manner of wyhash, and longer strings hash with wyhash itself. The string table probes linearly and stays at most a quarter full. Each slot packs the pointer to a string with the top 16 bits of its hash, so a probe that passes other strings never loads them, and a lookup reads two neighboring slots at once and picks the candidate without a branch. The table halves itself after a collection that leaves it less than a sixteenth full.

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
