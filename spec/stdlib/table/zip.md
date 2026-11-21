---
name: table.zip
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
vararg: true
returns: table
---

Returns a new list of tuples that combines the given lists element by element, so that tuple `i` is `{t1[i], t2[i], ...}`.

The arguments are zero or more lists.

The result is a new table. Its length is the length of the shortest list, and each tuple is a new table with one element from each list, in argument order. With no arguments the result is an empty table.

An argument that is not a table raises `bad argument #2 to 'zip' (table expected, got number)` with its position and type.

```lus
local rows = table.zip({1, 2, 3}, {"a", "b"})
print(#rows, rows[1][1], rows[1][2], rows[2][2])   --> 2  1  a  b
print(#table.zip())                                        --> 0
```

[`table.unzip`](/manual/api#table.unzip) is the inverse. [`table.transpose`](/manual/api#table.transpose) does the same for lists held in one table, and requires them to have equal lengths.
