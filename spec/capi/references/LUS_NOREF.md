---
name: "LUS_NOREF"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: "#define LUS_NOREF 0"
type: int
value: 0
---

The reference that `lus_ref` returns for nil. It never names a value, `lus_getref` pushes nil for it, and `lus_unref` ignores it, so it works as the initial value of a variable that holds a reference.
