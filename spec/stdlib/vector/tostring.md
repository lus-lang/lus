---
name: vector.tostring
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: i
    type: integer
    optional: true
  - name: j
    type: integer
    optional: true
  - name: mode
    type: string
    optional: true
returns: string
---

Decodes bytes of `v` as text and returns the string. Offsets are zero based, like every vector offset. `i` is the first byte to decode and defaults to 0. `j` is the offset just past the last byte and defaults to the size of the vector. Both are clamped to the vector.

With `mode` set to `"strict"`, the default, input that is not valid WTF-8 raises an error naming the byte offset of the first invalid sequence. With `mode` set to `"lossy"`, each invalid sequence becomes U+FFFD.

```lus
local v = vector.fromstring("héllo")
print(vector.tostring(v))                 --> héllo
print(vector.tostring(v, 0, 1))           --> h
print(vector.tostring(v, 0, 2, "lossy"))  --> h�
```
