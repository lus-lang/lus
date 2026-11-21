---
name: string.packsize
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: fmt
    type: string
returns: integer
---

Returns the size in bytes of the vector that [`string.pack`](/manual/api#string.pack) produces with the format `fmt`.

`fmt` is a format string with the options of `string.pack`. The size includes the padding that alignment options add.

The result is a non-negative integer. The empty format has size 0.

A format with a variable-length option, `s[n]` or `z`, raises `bad argument #1 to 'packsize' (variable-length format)`. An unknown option or an invalid size raises the same errors as `string.pack`.

```lus
print(string.packsize("<i4d"))     --> 12
print(string.packsize("i1 i8"))    --> 9
print(string.packsize("!8 i1 i8")) --> 16
print(catch string.packsize("z"))  --> false  ...: bad argument #1 to 'packsize' (variable-length format)
```

The size depends only on the format, so it is the size of every vector that the format packs. [`string.unpack`](/manual/api#string.unpack) reads a packed vector.
