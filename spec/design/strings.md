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

A string object stores its byte length, its character count, its hash, and an ASCII flag. ASCII strings index any character in constant time. Non-ASCII strings build a breadcrumb index on first indexed access. The index records the byte offset of every 64th character, so any character is found by one lookup and a scan of at most 63 characters. Validation, character counting, and breadcrumb construction use vectorized loops.

Short strings are interned, so equality between them is a pointer comparison. Substrings of long strings are views into their parent's buffer. A view that is much smaller than its parent copies its bytes when it outlives a collection cycle, so a small substring never keeps a large buffer alive.

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
