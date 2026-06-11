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

Shrinks the internal storage of `t` to fit its current contents and returns `t`. Removing keys from a table never shrinks its array or hash storage on its own, so a table that was once large keeps its capacity; `table.compact` releases that memory. Raises an error if `t` is readonly.

```lus
local cache = build_huge_table()
prune(cache)            -- removes most entries
table.compact(cache)    -- releases the now-unused capacity
```
