---
name: "lus_errorf"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "static inline int lus_errorf(lus_State *L, const char *fmt, ...)"
params:
  - name: L
    type: "lus_State*"
  - name: fmt
    type: "const char*"
vararg: true
returns:
  - type: "int"
---

Formats a message with the rules of the C `printf` family and raises it with `lus_errorstr`, then returns `LUS_ERROR`. The header defines it inline, and the message is cut at 511 bytes.

```c
static int check_port(lus_State *L) {
  lus_Integer port = lus_tointeger(L, 1, NULL);
  if (port < 1 || port > 65535)
    return lus_errorf(L, "port %lld out of range", (long long)port);
  return 0;
}
```
