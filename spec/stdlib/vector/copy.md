---
name: vector.copy
module: vector
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: dst
    type: vector
  - name: dstoff
    type: integer
  - name: src
    type: vector
  - name: srcoff
    type: integer
    optional: true
  - name: len
    type: integer
    optional: true
returns: []
---

Copies `len` bytes of `src`, starting at the zero-based offset `srcoff`, into `dst` at the zero-based offset `dstoff`, and returns no values.

- `dst` is the vector written. It keeps its size.
- `dstoff` is the offset in `dst` where the copy goes.
- `src` is the vector read. It may be `dst` itself.
- `srcoff` defaults to 0.
- `len` defaults to the rest of `src` after `srcoff`.

The ranges may overlap, and the result is the same as if the bytes went through a temporary copy. The range read must lie inside `src` and the range written inside `dst`. An `srcoff` outside `src` raises `bad argument #4 to 'copy' (offset out of bounds)`. A `len` past the end of `src` raises `bad argument #5 to 'copy' (length out of bounds)`. A range that does not fit in `dst` raises `bad argument #2 to 'copy' (offset out of bounds)`. A read-only `dst` raises `bad argument #1 to 'copy' (vector is read-only)`.

The following example writes a header into a buffer, then shifts its contents to drop the first two bytes.

```lus
local buf = vector.create(8)
vector.copy(buf, 0, vector.fromstring("LUS2"))
vector.copy(buf, 4, buf, 0, 4)
print(vector.tostring(buf))  --> LUS2LUS2
vector.copy(buf, 0, buf, 2)
print(vector.tostring(buf, 0, 6))  --> S2LUS2
```
