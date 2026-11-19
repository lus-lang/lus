---
name: tojson
module: base
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: value
    type: any
  - name: filter
    type: function
    optional: true
returns: string
---

Converts a Lus value to JSON. A table whose complete key set is the contiguous integer range from 1 through `n` becomes an array. Other tables become objects that retain string keys and omit keys of other types. The empty table becomes `[]`. JSON object member order is unspecified.

The optional `filter` is called first with `nil, value` for the root, then with integer array keys or string object keys. Its returned value is serialized recursively, and returning `nil` omits a field or produces `null` at the root. A table's `__json` metamethod can return any serializable replacement value.

Non-finite numbers become `null`. Functions, threads, userdata, vectors, and enum values become `null` at the root or in arrays and are omitted from objects. Shared acyclic tables are serialized by value. Cycles raise errors. Serialization enforces a 1,000-level nesting ceiling and follows the interpreter's C-call limit, which can raise a C stack overflow first for deeply nested tables.
