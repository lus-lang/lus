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

Returns a string or table with the date and time, formatted according to `format`. If `format` starts with `"!"`, the time is formatted in UTC. If `format` is `"*t"`, the result is a table with fields `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, and `isdst`.

The optional `time` argument specifies the time to format and defaults to the current time.
