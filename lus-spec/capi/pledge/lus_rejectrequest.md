---
name: lus_rejectrequest
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_rejectrequest (lua_State *L, lus_PledgeRequest *p)"
params:
  - name: L
    type: "lua_State*"
  - name: p
    type: "lus_PledgeRequest*"
---

Permanently rejects a permission using the request struct. Future attempts to grant this permission will fail.
