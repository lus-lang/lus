---
name: vector.resize
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
fastcall: true
params:
  - name: v
    type: vector
  - name: newsize
    type: integer
---

Resizes the vector to `newsize` bytes. New bytes are zero-initialized. Existing data within the new size is preserved.
