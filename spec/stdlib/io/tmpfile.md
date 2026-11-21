---
name: io.tmpfile
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lua
returns: userdata|nil
---

Creates a temporary file, opens it for reading and writing in text mode, and returns its handle.

The function takes no arguments. It creates the file in the directory named by the `TMPDIR` environment variable, or in `/tmp` when the variable is unset, and removes its name from the directory at once. The file therefore has no path that another program could open, and its storage is released when the handle closes or the process ends.

On success the call returns one handle opened in mode `"w+"`. A file that cannot be created raises an error. The call requires `fs:write` for the path of the file it creates, so a grant limited to other paths raises an error such as `permission "fs:write" denied for '/tmp/lus_1f2e3d4c5b6a7980'`.

The following example writes to a temporary file, seeks back to its start, and reads the contents.

```lus
pledge("fs:write")
local tmp <close> = io.tmpfile()
tmp:write("scratch data")
tmp:seek("set")
print(tmp:read("a"))   --> scratch data
```

[`os.tmpname`](/manual/api#os.tmpname) creates a temporary file that has a name.
