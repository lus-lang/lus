---
name: "LUS_VERSION"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: |
  #define LUS_VERSION_MAJOR 2
  #define LUS_VERSION_MINOR 0
  #define LUS_VERSION_PATCH 0
  #define LUS_VERSION "Lus 2.0.0-dev"
---

The version of the header. `LUS_VERSION` is a readable string for messages, and the three numbers allow checks at compile time.

The following check stops a build against an older header.

```c
#include "lus.h"

#if LUS_VERSION_MAJOR < 2
#error "this host needs Lus 2"
#endif
```
