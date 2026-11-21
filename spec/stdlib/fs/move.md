---
name: fs.move
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: source
    type: string
  - name: dest
    type: string
returns: []
---

Renames the file or directory at `source` to `dest` and returns no values.

`source` is the string path of an existing entry, and `dest` is its new path. Renaming to a path in another directory moves the entry there, as long as both paths lie on the same filesystem. A directory moves together with everything inside it.

On success the call returns nothing. Every failure raises an error. A `dest` that already exists raises `"cannot move to 'DEST': target already exists"`, so `fs.move` never replaces an entry. A missing `source` raises `"cannot move 'SOURCE': source does not exist"`. A move across two filesystems raises an error that ends in `cross-device move`. The call requires `fs:read` and `fs:write` for `source` and `fs:write` for `dest`.

The following example renames a file and then moves it into a subdirectory.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-move-example")
fs.createdirectory(fs.path.join(dir, "archive"), true)
local draft = fs.path.join(dir, "draft.txt")
local final = fs.path.join(dir, "final.txt")
io.open(draft, "w"):close()
fs.move(draft, final)
fs.move(final, fs.path.join(dir, "archive", "final.txt"))
print(fs.type(fs.path.join(dir, "archive", "final.txt")))   --> file  false
fs.remove(dir, true)
```

A program that moves a file to another filesystem copies it with [`fs.copy`](/manual/api#fs.copy) and removes the original with [`fs.remove`](/manual/api#fs.remove).
