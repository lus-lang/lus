---
name: debug.getinfo
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: f
    type: function|integer
  - name: what
    type: string
    optional: true
returns: table
---

Returns a table with information about a function or stack level. The `what` string selects which fields to fill: `"n"` (name), `"S"` (source), `"l"` (line), `"t"` (tail call), `"u"` (upvalues), `"f"` (function), `"L"` (valid lines). Default is all.
