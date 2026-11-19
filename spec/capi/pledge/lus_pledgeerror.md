---
name: lus_pledgeerror
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "void lus_pledgeerror (lua_State *L, lus_PledgeRequest *p, const char *msg)"
params:
  - name: L
    type: "lua_State*"
  - name: p
    type: "lus_PledgeRequest*"
  - name: msg
    type: "const char*"
---

Sets a denial error message for user-facing feedback.
