---
name: fs.sync
module: fs
kind: function
since: 2.0.0
stability: stable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
returns: []
---

Writes the entries of the directory at `path` through to the storage device and returns no values.

The name of a file is an entry of its directory, and creating, renaming, or removing a file changes that directory. Until the directory is synced, a crash of the system or a loss of power can undo the change, even when the file itself was synced with [`file:sync`](/manual/api#file:sync). After `fs.sync(dir)` returns, the changes made in `dir` before the call survive. A `path` that names a file syncs the data of that file, as `file:sync` does.

On success the call returns nothing. A missing `path` raises `"cannot sync 'PATH': path does not exist"`, and a failure of the device raises an error of the form `"cannot sync 'PATH': REASON"`. On Windows, the file systems record the changes of a directory in their log, and the call succeeds when the system refuses to sync a directory directly. Windows flushes a file only through a handle with write access, so there the call opens a file for writing, and a file that the program may not write raises `"cannot sync 'PATH': Permission denied"`. The call requires `fs:read` for `path`.

The following example creates a file and syncs its directory, so the new name survives a crash.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-fs-sync-example")
fs.createdirectory(dir, true)
local f = assert(io.open(fs.path.join(dir, "new.txt"), "w"))
f:write("hello\n")
f:sync()
f:close()
fs.sync(dir)
print(fs.type(fs.path.join(dir, "new.txt")))   --> file  false
fs.remove(dir, true)
```

[Durable writes](/manual/filesystem#durable-writes) shows how a program replaces a file so that a crash leaves either the old contents or the new ones.
