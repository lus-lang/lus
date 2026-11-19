---
name: "LUS_ERROR"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: "#define LUS_ERROR (-1)"
type: int
value: -1
---

What a C function returns to raise its pending error. `lus_error`, `lus_errorstr`, and `lus_errorf` set the pending error and return this value, so a C function raises an error with `return lus_error(L)`.

`lus_newmetatable`, `lus_ref`, and `lus_next` also return it to report a failure, with the error value pushed, because their other return values carry a result.
