---
name: require
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: modname
    type: string
returns: any
---

Loads and runs the module `modname`. Searches `package.searchers` in order to find a loader. Caches results in `package.loaded` so subsequent calls return the same value.
