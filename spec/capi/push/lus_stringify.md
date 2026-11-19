---
name: "lus_stringify"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_stringify(lus_State *L, int idx)"
params:
  - name: L
    type: "lus_State*"
  - name: idx
    type: "int"
returns:
  - type: "int"
    name: status
---

Pushes the result of `tostring` on the value at `idx` and returns `LUS_OK`. A `__tostring` metamethod runs and its result is converted to a string. Without one, a `__name` field in the metatable names the value, as in `Point: 0x7f3c0a4010`.

When the metamethod raises an error, the call returns its status and pushes the error value in place of the string, so the stack grows by one value in every case.
