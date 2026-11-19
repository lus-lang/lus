---
name: "lus_defcapability"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_defcapability(lus_State *L, const lus_Capability *cap)"
params:
  - name: L
    type: "lus_State*"
  - name: cap
    type: "const lus_Capability*"
returns:
  - type: "int"
    name: status
---

Declares a capability and returns `LUS_OK`. Scripts can then pledge it, the host can grant and reject it, and C functions check it with `lus_require` and `lus_allowed`. The name and the subcapability names are copied, so the declaration can live on the C stack. The `ud` pointer is kept as given for as long as the state lives.

The call returns `LUS_ERRRUN` and pushes the error value when the name is missing or invalid, when the name is already declared or is `all` or `seal`, when the kind is unknown, and when a `LUS_CAP_CUSTOM` capability has no `match` function. It returns `LUS_ERRMEM` when memory runs out.

```c
static const char *const store_subs[] = {"read", "write", NULL};

static int open_store(lus_State *L) {
  lus_Capability cap = {0};
  cap.name = "store";
  cap.subcapabilities = store_subs;
  cap.kind = LUS_CAP_PATTERN;
  if (lus_defcapability(L, &cap) != LUS_OK)
    return lus_error(L);
  return 0;
}
```

With the grant `"store:read=users/*"`, a check of `store:read` for `users/ada` passes and a check for `secrets/key` fails.
