---
name: "lus_gettop"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_gettop(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
---

Returns the index of the top value, which is also the number of values in the current frame. Inside a C function the frame starts at its first argument, so on entry `lus_gettop` returns the number of arguments. At host level the frame is the whole stack.
