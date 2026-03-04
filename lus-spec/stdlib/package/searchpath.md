---
name: package.searchpath
module: package
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: name
    type: string
  - name: path
    type: string
  - name: sep
    type: string
    optional: true
  - name: rep
    type: string
    optional: true
returns: string|nil
---

Searches for `name` in the given `path` string, replacing each `"?"` with `name` (with `"."` replaced by `sep`). Returns the first file that exists, or `nil` plus a string listing all files tried.
