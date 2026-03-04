---
name: table.clone
module: table
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: t
    type: T
  - name: deep
    type: boolean
    optional: true
generic: T
returns: T
---

Creates a copy of the table `t`. If `deep` is true, nested tables are recursively cloned. Deep copies preserve circular references.

```lus
local x = table.clone(t)        -- shallow copy
local y = table.clone(t, true)  -- deep copy
```
