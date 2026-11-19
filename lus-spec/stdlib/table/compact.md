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

Shrinks the internal storage of `t` to fit its current contents and returns `t`. This releases unused array and hash capacity left after removing keys. It raises an error if `t` is readonly.

```lus
local cache = build_huge_table()
prune(cache)            -- removes most entries
table.compact(cache)    -- releases the now-unused capacity
```
