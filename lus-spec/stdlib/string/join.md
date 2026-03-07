---
name: string.join
module: string
kind: function
since: 1.6.0
stability: unstable
origin: lus
params:
  - name: t
    type: table
  - name: delimiter
    type: string
returns: string
---

Joins elements of table `t` into a single string with `delimiter` between each element. Non-string values are converted via `tostring`. Empty table returns an empty string.
