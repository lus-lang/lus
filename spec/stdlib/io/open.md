---
name: io.open
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read", "fs:write"]
origin: lua
params:
  - name: filename
    type: string
  - name: mode
    type: string
    optional: true
  - name: options
    type: table
    optional: true
returns: userdata|nil
---

Opens `filename` in the given `mode` and returns a file handle, or `nil` plus an error message on failure.

Modes follow C `fopen` conventions: `"r"` (read, the default), `"w"` (write), `"a"` (append), plus an optional `"b"` suffix for binary. A read mode requires only `fs:read`. Any write or append mode requires `fs:write`.

A file opened in text mode reads strings and validates them as text. A read that meets an invalid UTF-8 sequence raises an error naming its byte offset. The optional `options` table takes the boolean field `lossy`, which replaces each invalid sequence with U+FFFD instead. A file opened in binary mode, with `"b"` in `mode`, reads vectors of raw bytes. Writing accepts strings, numbers, and vectors in either mode.
