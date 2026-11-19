---
name: "lus_loadfile"
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_loadfile(lus_State *L, const char *path)"
params:
  - name: L
    type: "lus_State*"
  - name: path
    type: "const char*"
returns:
  - type: "int"
    name: status
---

Loads the file at `path` like `lus_load`, with the chunk name `"@path"`. A relative path is resolved against the working directory of the process. The host reads the file under its own authority, so no permission check applies.

When the file cannot be opened or read, the call returns `LUS_ERRFILE` and pushes a message that names the path and the reason. Otherwise it returns what `lus_load` returns. The call pushes exactly one value in every case.
