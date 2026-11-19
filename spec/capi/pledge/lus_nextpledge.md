---
name: lus_nextpledge
header: lpledge.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int lus_nextpledge (lua_State *L, lus_PledgeRequest *p)"
params:
  - name: L
    type: "lua_State*"
  - name: p
    type: "lus_PledgeRequest*"
---

Iterates through stored values for a permission. Sets `p->current` to the next stored value. Returns `1` if there are more values, `0` when done.
