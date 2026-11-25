---
name: _VERSION
module: base
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

`_VERSION` is a global variable that holds the name and version of the running language as a string, `"Lus 2.0"` in this release.

```lus
print(_VERSION)  --> Lus 2.0
```

The base library sets `_VERSION` when it opens. Assigning to it changes only the variable.
