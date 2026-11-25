---
name: table.concat
module: table
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: list
    type: table
  - name: sep
    type: string
    optional: true
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
returns: string
---

Returns the elements `list[i]` through `list[j]` joined into one string, with `sep` between each pair.

`list` is the table to read. `sep` is the separator and defaults to the empty string. `i` defaults to 1, and `j` defaults to the length `#list`.

The result is a string. A number element is converted as [`tostring`](/manual/api#tostring) converts it, so a decimal keeps its digits and a bigint is written in full. When `i` is greater than `j`, the result is the empty string.

An element that is neither a string nor a number raises `invalid value (table) at index 2 in table for 'concat'`, with its type and its index. A `nil` element in the range, including one past the end of the list, raises the same error with `nil`.

```lus
print(table.concat({ 1, 2, 3 }))  --> 123
print(table.concat({ 1, 2, 3 }, ", "))  --> 1, 2, 3
print(table.concat({ "a", "b", "c", "d" }, "-", 2, 3))  --> b-c
print(table.concat({ 1.5, 2n, 1.50d }, " "))  --> 1.5 2 1.50
print(table.concat({}, ",") == "")  --> true
```

The elements are read through `__index` and the length through `__len`, so a proxy table joins as its metamethods describe. [`string.join`](/manual/api#string.join) converts every element with `tostring` and stops at the first `nil`.
