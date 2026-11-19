---
name: tonumber
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: e
    type: any
  - name: base
    type: integer
    optional: true
returns: number|nil
---

Converts `e` to a number. Integers and floats are returned unchanged. A bigint or a decimal converts to the nearest float, which makes `tonumber` the explicit way to mix an exact number with float arithmetic. If `e` is a string, tries to parse it as a numeral, and a numeral that overflows 64 bits becomes a float. If `e` is an enum value, returns its 1-based index. The optional `base` accepts an integer from 2 through 36 and specifies the base for string conversion, in which case `e` must be a string. Returns `nil` on failure.

The functions `bigint` and `decimal` convert strings to exact numbers.
