---
name: tonumber
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: e
    type: any
  - name: base
    type: integer
    optional: true
returns: number|nil
---

Converts `e` to a number. If `e` is already a number, returns it. If `e` is a string, tries to parse it as a numeral. If `e` is an enum value, returns its 1-based index. The optional `base` (2--36) specifies the base for string conversion. Returns `nil` on failure.
