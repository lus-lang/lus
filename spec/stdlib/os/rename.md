---
name: os.rename
module: os
kind: function
since: 0.1.0
stability: removed
origin: lua
params:
  - name: oldname
    type: string
  - name: newname
    type: string
---

`os.rename` is a Lua function that Lus removed, so `os.rename` is `nil`. [`fs.move`](/manual/api#fs.move) takes its place and moves a file or a directory to a new path.
