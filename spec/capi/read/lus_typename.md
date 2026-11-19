---
name: "lus_typename"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "const char *lus_typename(int type)"
params:
  - name: type
    type: "int"
returns:
  - type: "const char*"
---

Returns the name of a type code as a static string, such as `"number"` or `"table"`. Both `LUS_TLIGHT` and `LUS_TUSERDATA` give `"userdata"`, which is how scripts see both types. `LUS_TNONE` and any code outside the list give `"no value"`.
