---
name: os.time
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
    optional: true
returns: integer
---

Returns the current time as a number (seconds since epoch) when called without arguments. When called with a table argument `t`, returns the time represented by that table (with fields `year`, `month`, `day`, `hour`, `min`, `sec`).
