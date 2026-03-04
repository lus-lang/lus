---
name: debug.sethook
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: hook
    type: function
  - name: mask
    type: string
  - name: count
    type: integer
    optional: true
---

Sets the given function as a debug hook. The `mask` string may contain `"c"` (call), `"r"` (return), `"l"` (line). The `count` argument sets a count hook. Call with no arguments to remove the hook.
