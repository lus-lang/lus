---
name: string.bytelen
module: string
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: s
    type: string
returns: integer
---

Returns the number of bytes that `s` takes in UTF-8.

`s` is the string to measure. A number is converted to its textual form first.

The result is a non-negative integer. A string records its size in bytes, so the call takes the same time for a string of any length. The length operator `#s` counts characters, and the two results differ for a string with a character outside ASCII: `"héllo"` has 5 characters and 6 bytes. A protocol that states the size of a message in bytes, such as the `Content-Length` header of HTTP, takes its count from this function.

An argument that is neither a string nor a number raises `bad argument #1 to 'bytelen' (string expected, got nil)` with its type.

```lus
print(string.bytelen("héllo"), #"héllo")  --> 6  5
print(string.bytelen("😀"), string.bytelen(""))  --> 4  0
print(string.bytelen("a\0b"))  --> 3
```

[`vector.fromstring`](/manual/api#vector.fromstring) returns the bytes themselves.
