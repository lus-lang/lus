---
name: "lus_onrequest"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "void lus_onrequest(lus_State *L, lus_RequestHook hook, void *ud)"
params:
  - name: L
    type: "lus_State*"
  - name: hook
    type: "lus_RequestHook"
  - name: ud
    type: "void*"
---

Installs the request hook of the state, or removes it when `hook` is `NULL`. The hook decides every script pledge that the host ceiling does not cover.

A script pledge is decided in this order.

1. A pledge on a sealed set returns false.
2. A pledge of a rejected capability raises an error.
3. A pledge that the ceiling covers succeeds.
4. With a hook installed, the hook decides. With no hook, the pledge succeeds when the host has granted nothing, and returns false otherwise.

The following host allows `fs:read` for its data directory, rejects `exec`, and asks the user about anything else.

```c
static int ask(void *ud, lus_State *L, const char *capability, const char *value) {
  (void)ud;
  (void)L;
  printf("allow %s%s%s? ", capability, value ? "=" : "", value ? value : "");
  return getchar() == 'y';
}

static int setup(lus_State *L) {
  if (lus_grant(L, "fs:read=/srv/data/**") != LUS_OK ||
      lus_reject(L, "exec") != LUS_OK)
    return lus_error(L);
  lus_onrequest(L, ask, NULL);
  return 0;
}
```
