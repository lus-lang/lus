---
name: lus_PledgeGranter
header: lpledge.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: "typedef void (*lus_PledgeGranter)(lua_State *L, lus_PledgeRequest *p);"
---

Callback type for permission granters. Libraries register granters to handle their own permission validation logic.

Granters should call `lus_setpledge` to confirm valid permissions. Unprocessed requests are automatically denied.
