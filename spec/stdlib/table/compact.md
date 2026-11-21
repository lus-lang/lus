---
name: table.compact
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: t
    type: T
generic: T
returns: T
---

Shrinks the internal storage of `t` to fit its current contents and returns `t`.

`t` is the table to compact. The array part shrinks to end at its last non-nil element, and the hash part shrinks to the number of keys it holds. This releases capacity that remains after many keys were removed.

The result is `t` itself. Its keys and values are unchanged, so a read-only table compacts as well.

A `t` that is not a table raises `bad argument #1 to 'compact' (table expected, got nil)` with its type.

```lus
local cache = {}
for i = 1, 1000 do cache["k" .. i] = i end
for i = 1, 990 do cache["k" .. i] = nil end
print(table.compact(cache) == cache, cache.k995)   --> true  995
```

A table grows its storage again as keys are added, so compacting pays off for a table that stays small after it shrank. [`table.create`](/manual/api#table.create) sizes a new table in advance.
