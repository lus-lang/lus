---
name: "LUS_OK"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: |
  #define LUS_OK 0
  #define LUS_ERRRUN 1
  #define LUS_ERRSYNTAX 2
  #define LUS_ERRMEM 3
  #define LUS_ERRFILE 4
---

The status codes that fallible functions return.

- `LUS_OK` reports success.
- `LUS_ERRRUN` reports a runtime error, including a failed permission check.
- `LUS_ERRSYNTAX` reports a syntax error while compiling, or a malformed binary chunk.
- `LUS_ERRMEM` reports that the allocator failed.
- `LUS_ERRFILE` reports that a file could not be opened or read.

Every status other than `LUS_OK` comes with the error value on top of the stack, in place of the result of the call.
