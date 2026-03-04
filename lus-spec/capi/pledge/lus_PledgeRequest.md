---
name: lus_PledgeRequest
header: lpledge.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: "typedef struct lus_PledgeRequest { const char *base; const char *sub; const char *value; const char *current; int status; int count; int has_base; } lus_PledgeRequest;"
---

Request structure passed to granter callbacks. Contains all information about the permission being granted or checked.

`status` indicates the operation: `LUS_PLEDGE_GRANT` for new grants, `LUS_PLEDGE_UPDATE` for updates, `LUS_PLEDGE_CHECK` for access checks.
