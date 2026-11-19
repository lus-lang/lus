---
name: package.cpath
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

The native-module templates used by `require`. Its default is the empty string. Lus 2.0 runs its standard library in the runtime itself and extends it from a host program through the C embedding API, so a native module found on `package.cpath` reports that native C libraries are unavailable.
