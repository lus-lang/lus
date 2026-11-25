---
name: string.transcode
module: string
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: input
    type: string|vector
  - name: from
    type: string
  - name: to
    type: string
  - name: ignorebad
    type: boolean
    optional: true
returns: string|vector
---

Converts `input` from the encoding `from` to the encoding `to` and returns the result, a vector for a byte encoding and a string for a text encoding.

`input` is a string or a vector. A number is converted to its textual form first. `from` and `to` name encodings, and the names are case sensitive. `ignorebad` defaults to false. When it is true, each invalid input sequence becomes U+FFFD, and a character that `to` cannot represent is skipped. In UTF-8 input each maximal subpart of an invalid sequence becomes one U+FFFD, the practice of Unicode and of the URL standard, so `"\xE2\x82A"` gives U+FFFD followed by `A`. In UTF-16 input each unpaired surrogate and an odd last byte become one U+FFFD, and in UTF-32 and ASCII input each invalid unit does.

The byte encodings are `"utf-16le"`, `"utf-16be"`, `"utf-32le"`, `"utf-32be"`, `"iso-8859-1"` (also `"latin1"` and `"latin-1"`), and `"binary"`, which stands for the raw bytes. The text encodings are `"utf-8"`, `"utf-8bom"`, `"ascii"`, and the binary to text encodings `"base64"`, `"base64url"`, `"base32"`, `"url"`, and `"hex"`. Decoding `"base64"`, `"base64url"`, `"base32"`, `"url"`, or `"hex"` input yields its raw bytes, which are then converted to `to`.

The result is a new vector when `to` is a byte encoding and a string when `to` is a text encoding.

An unknown name raises `invalid source encoding 'name'` or `invalid target encoding 'name'`. Invalid input, and a character that the target encoding cannot represent, raise an error that names the position or the code point, unless `ignorebad` is true. An `input` that is neither a string, a number, nor a vector raises `bad argument #1 to 'transcode' (string or vector expected, got table)` with its type.

```lus
local bytes = string.transcode("hé", "utf-8", "utf-16le")
print(type(bytes), #bytes)  --> vector  4
print(string.transcode(bytes, "utf-16le", "utf-8"))  --> hé
print(string.transcode("hi", "utf-8", "base64"))  --> aGk=
print(string.transcode("hi?", "utf-8", "base64url"))  --> aGk_
print(string.transcode("Hello 日本", "utf-8", "ascii", true))  --> Hello
```

`"utf-8bom"` adds the byte order mark U+FEFF as a target and removes a leading one as a source. Base64 input may omit its padding. `"base64url"` is the URL-safe alphabet of RFC 4648, with `-` and `_` in place of `+` and `/`, and it writes no padding. Its input may carry padding. `"base32"` is the alphabet of RFC 4648, written in uppercase with padding, as TOTP secrets use it. Its input may be in either case and may omit padding. A base32 text without padding has a length of 0, 2, 4, 5, or 7 characters after its last full group of 8, since a group of 1, 3, or 6 characters encodes no whole byte, and any other length raises an error. Base64, base64url, and base32 decoding skip spaces, tabs, carriage returns, and line feeds anywhere in the input, so text wrapped across lines decodes. Padding `=` may appear only at the end, after the data, and a `=` followed by more data raises an error, so `string.transcode("MZ=XQ", "base32", "utf-8")` raises. URL decoding reads `+` as a space. With `ignorebad`, URL decoding keeps a `%` that does not start two hexadecimal digits as it is and decodes the rest, so `string.transcode("a%zz%41", "url", "utf-8", true)` returns `a%zzA`. The decoded bytes are then UTF-8, so an escape that decodes to an invalid byte becomes U+FFFD, and `string.transcode("%C3%A9%FF", "url", "utf-8", true)` returns `é` followed by U+FFFD, as the URL standard decodes it. Base64, base64url, and base32 decoding with `ignorebad` skip every character outside their alphabet and an incomplete last group, and hex decoding skips each pair that holds a character other than a hexadecimal digit and a lone last digit, so `string.transcode("4g41", "hex", "utf-8", true)` returns `A`. [Text and bytes](/manual/text#transcoding) describes every encoding with examples. [`vector.fromstring`](/manual/api#vector.fromstring) and [`vector.tostring`](/manual/api#vector.tostring) convert between a string and its WTF-8 bytes.
