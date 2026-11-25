---
name: _G
module: base
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: table
---

`_G` is a global variable that holds the global table, where every free name of a chunk is looked up by default. The field `_G._G` refers to the table itself, and the environment `_ENV` of a chunk starts as the same table.

Indexing `_G` with a string reads or writes the global of that name, which reaches globals whose names are computed at run time.

```lus
counter = 1
print(_G.counter)  --> 1
_G["computed_" .. 1] = true
print(computed_1)  --> true
print(_G._G == _G, _ENV == _G)  --> true  true
```

Assigning a new value to `_G` changes only the variable. Free names keep resolving through `_ENV`, so the global environment stays the original table. [`load`](/manual/api#load) takes an `env` argument that gives a chunk a different environment, and [The environment](/manual/guide#the-environment) in the guide describes `_ENV` and sandboxing.
