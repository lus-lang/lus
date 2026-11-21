---
name: string.join
module: string
kind: function
since: 1.6.0
stability: stable
origin: lus
fastcall: true
params:
  - name: t
    type: table
  - name: delimiter
    type: string
returns: string
---

Returns the elements of the list `t` converted to strings and joined into one string, with `delimiter` between each pair.

`t` is a table read from index 1 up to the last element before the first `nil`. `delimiter` is the string placed between elements, and it is required. Pass `""` to join without a separator.

The result is a string. An element that is not a string is converted with [`tostring`](/manual/api#tostring), so numbers, booleans, and tables all join, and a `__tostring` metamethod applies. An empty table returns the empty string.

A `t` that is not a table raises `bad argument #1 to 'string.join' (table expected, got string)` with its type, and a missing `delimiter` raises `bad argument #2 to 'string.join' (string expected, got no value)`.

```lus
print(string.join({"a", "b", "c"}, ", "))        --> a, b, c
print(string.join({1, true, 2.5, 3n}, "-"))      --> 1-true-2.5-3
print(string.join({"a", "b", nil, "d"}, ","))    --> a,b
print(string.join({}, ",") == "")                --> true
```

`string.join` takes the table as its first argument, so a call reads `string.join(t, delimiter)`. Keys other than the positive integers are ignored. [`table.concat`](/manual/api#table.concat) joins a range of a list and raises an error on an element that is neither a string nor a number. [`string.split`](/manual/api#string.split) is the inverse.
