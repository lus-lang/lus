---
name: "lus_seal"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_seal(lus_State *L)"
params:
  - name: L
    type: "lus_State*"
returns:
  - type: "int"
    name: status
---

Seals the permission set and returns `LUS_OK`. Afterwards the host can no longer grant or reject anything, and those calls return `LUS_ERRRUN` with the message `permission set is sealed`. Every script pledge returns false, while the capabilities granted before the seal stay in effect. Sealing a sealed set succeeds and changes nothing.
