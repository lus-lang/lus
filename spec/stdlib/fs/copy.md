---
name: fs.copy
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read", "fs:write"]
origin: lus
params:
  - name: source
    type: string
  - name: dest
    type: string
returns: []
---

Copies the contents of the file at `source` into a new file at `dest` and returns no values.

`source` is the path of an existing file, and a symbolic link at `source` is followed, so the copy holds the contents of its target. `dest` is the path of the new file, and nothing may exist there yet. Both paths are strings, and a relative path resolves against the working directory.

On success the call returns nothing. Every failure raises an error. A `dest` that already exists raises `"target 'DEST' already exists"`, so `fs.copy` never replaces a file. A missing `source` raises `"cannot open source 'SOURCE': No such file or directory"`, and a directory as `source` raises an error that ends in `Is a directory`. If the copy fails partway, the partial file at `dest` is removed before the error is raised. The call requires `fs:read` for `source` and `fs:write` for `dest`.

The following example copies a file in a temporary directory and shows that a second copy to the same target fails.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-copy-example")
fs.createdirectory(dir, true)
local original = fs.path.join(dir, "original.txt")
local backup = fs.path.join(dir, "backup.txt")
io.open(original, "w"):write("contents"):close()
fs.copy(original, backup)
print(io.open(backup):read("a"))           --> contents
print((catch fs.copy(original, backup)))   --> false
fs.remove(dir, true)
```

A program that needs to replace a file removes the old one with [`fs.remove`](/manual/api#fs.remove) first. [`fs.move`](/manual/api#fs.move) renames a file without copying it.
