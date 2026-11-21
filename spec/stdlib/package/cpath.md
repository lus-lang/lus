---
name: package.cpath
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

`package.cpath` is the string of templates that `require` searches for native modules, and its default is the empty string.

Lus 2.0 runs its standard library in the runtime itself, and a host program extends it through the C embedding API in `lus.h`. The last two default [`package.searchers`](/manual/api#package.searchers) search `package.cpath` with the same template rules as [`package.path`](/manual/api#package.path). A native module found there raises `error loading module 'NAME' from file 'PATH':` followed by `native C libraries are unavailable in Lus 2.0`.

```lus
print(package.cpath == "")   --> true
```

[`package.loadlib`](/manual/api#package.loadlib) reports the same message for a library loaded directly. [Embedding Lus](/manual/guide#embedding-lus) in the guide describes how a host registers native functions.
