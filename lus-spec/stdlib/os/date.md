---
name: os.date
module: os
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: format
    type: string
    optional: true
  - name: time
    type: integer
    optional: true
returns: string|table
---

Returns a string or table with the date and time, formatted according to `format`. If `format` starts with `"!"`, uses UTC. If `format` is `"*t"`, returns a table with fields `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, `isdst`. The optional `time` argument specifies the time to format (defaults to current time).
