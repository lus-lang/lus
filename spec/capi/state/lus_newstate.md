---
name: "lus_newstate"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "lus_State *lus_newstate(void)"
returns:
  - type: "lus_State*"
---

Creates a state and returns it, or returns `NULL` when memory runs out. The new state has an empty global table and holds no permissions. `lus_openlibs` opens the standard libraries, and the [permission functions](#lus_grant) set what scripts may do.

The following host shows the whole life of a state.

```c
#include <stdio.h>
#include "lus.h"

int main(void) {
  lus_State *L = lus_newstate();
  if (L == NULL)
    return 1;
  if (lus_openlibs(L) != LUS_OK || lus_dostring(L, "print('hello')") != LUS_OK) {
    fprintf(stderr, "%s\n", lus_tostring(L, -1, NULL));
    lus_close(L);
    return 1;
  }
  lus_close(L);
  return 0;
}
```
