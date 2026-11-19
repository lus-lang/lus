---
name: debug.gethook
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: thread
    type: thread
    optional: true
returns: function
---

Returns the current hook function, hook mask (a string), and hook count for the given thread (or the current thread).
