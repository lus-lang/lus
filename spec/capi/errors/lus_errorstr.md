---
name: "lus_errorstr"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_errorstr(lus_State *L, const char *msg)"
params:
  - name: L
    type: "lus_State*"
  - name: msg
    type: "const char*"
returns:
  - type: "int"
---

Makes the string `msg` the pending error and returns `LUS_ERROR`. When Lus code called the running C function, the message is prefixed with its position, as in `script.lus:12: bad thing`. A C function called directly by the host through `lus_pcall` gets the message unchanged. The stack is unchanged.
