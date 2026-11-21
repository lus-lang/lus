---
name: vector.fromstring
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: s
    type: string|vector
returns: vector
---

Returns a new vector that holds the WTF-8 bytes of a string.

- `s` is the string to convert. A number is converted to its textual form first. A vector is copied.

String functions work in characters, and this function is how a program reaches the bytes of a string. A character outside ASCII takes two to four bytes, and a lone surrogate takes three. The empty string gives a vector of size 0. An argument that is neither a string, a number, nor a vector raises `bad argument #1 to 'fromstring' (string expected)`.

The following example converts a string with one character outside ASCII.

```lus
local v = vector.fromstring("héllo")
print(#("héllo"), #v)                          --> 5  6
print(vector.get(v, 1), vector.get(v, 2))      --> 195  169
print(#vector.fromstring(""))                  --> 0
```

[`vector.tostring`](/manual/api#vector.tostring) decodes bytes back into a string.
