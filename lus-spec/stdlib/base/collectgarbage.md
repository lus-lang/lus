---
name: collectgarbage
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: opt
    type: string
    optional: true
  - name: arg
    type: any
    optional: true
returns: any
---

Controls the garbage collector. The `opt` argument selects the operation: `"collect"` (default) performs a full collection, `"stop"` and `"restart"` control the collector, `"count"` returns memory in use (in KB), `"step"` performs a collection step, `"isrunning"` returns whether the collector is running, `"incremental"` and `"generational"` set the GC mode, and `"param"` queries or sets a GC parameter.
