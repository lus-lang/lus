---
name: lus_setpledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_setpledge (lua_State *L, lus_PledgeRequest *p, const char *sub, const char *value)"
params:
  - name: L
    type: "lua_State*"
  - name: p
    type: "lus_PledgeRequest*"
  - name: sub
    type: "const char*"
  - name: value
    type: "const char*"
---

Confirms or sets a pledge value. Marks the request as processed, preventing automatic denial.
