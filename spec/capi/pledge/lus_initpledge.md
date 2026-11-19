---
name: lus_initpledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_initpledge (lua_State *L, lus_PledgeRequest *p, const char *base)"
params:
  - name: L
    type: "lua_State*"
  - name: p
    type: "lus_PledgeRequest*"
  - name: base
    type: "const char*"
---

Initializes a pledge request for C-side grants. This bypasses granters and is used for direct permission grants from C code.
