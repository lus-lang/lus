---
name: vector.fromstring
module: vector
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: s
    type: string|vector
returns: vector
---

Returns a new vector holding the WTF-8 bytes of the string `s`. Given a vector, it returns a copy. String functions work in characters, and this function is how a program reaches the bytes of a string.

```lus
local v = vector.fromstring("héllo")
print(#v, vector.get(v, 1))   --> 6  195
```
