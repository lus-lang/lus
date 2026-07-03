---
name: time.instant
module: time
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: epoch_seconds
    type: integer
  - name: nanos
    type: integer
    optional: true
returns: instant
---

Constructs an `instant` from `epoch_seconds` (Unix seconds since 1970-01-01 UTC) and an optional `nanos` fraction. Use this to lift an `os.time()` value into the `time` type system.

An `instant` supports: `i:epoch()`, `i:nanos()`, `i:format(fmt)`, `i:iso()`, `i:at(zone)` (render as a `zoned` in a `zone` or a fixed offset in seconds), the operators `i + duration`, `i - duration`, `i - instant` (a `duration`), and the comparisons `==`, `<`, `<=`.
