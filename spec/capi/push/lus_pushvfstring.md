---
name: "lus_pushvfstring"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "static inline int lus_pushvfstring(lus_State *L, const char *fmt, va_list ap)"
params:
  - name: L
    type: "lus_State*"
  - name: fmt
    type: "const char*"
  - name: ap
    type: "va_list"
returns:
  - type: "int"
    name: status
---

The `va_list` form of `lus_pushfstring`, for hosts that wrap it in their own variadic functions. Text up to 255 bytes is formatted on the C stack and longer text in a temporary heap buffer. When that buffer cannot be allocated, the pushed string holds the first 255 bytes of the text.
