---
name: fs.remove
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: path
    type: string
  - name: recursive
    type: boolean
    optional: true
returns: []
---

Removes the file, symbolic link, or directory at `path` and returns no values.

`path` is the string path of the entry to remove. `recursive` is a boolean that defaults to `false`. Without it, a directory must be empty. With `recursive` set to `true`, the directory and everything below it are removed. A file or a link is removed the same way in both modes.

On success the call returns nothing. Every failure raises an error. A missing `path` raises `"cannot remove 'PATH': path does not exist"`, and a directory that still has entries raises `"cannot remove directory 'PATH': not empty"` unless `recursive` is `true`. The call requires `fs:write` for the location of `path` itself.

The following example shows that a directory with contents needs `recursive`.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-remove-example")
fs.createdirectory(fs.path.join(dir, "deep"), true)
io.open(fs.path.join(dir, "deep", "file.txt"), "w"):close()
print((catch fs.remove(dir)))         --> false
fs.remove(dir, true)
print((catch fs.type(dir)))           --> false
```

`fs.remove` never follows a symbolic link. Removing a link removes the link and leaves its target, and a recursive removal removes the links it meets inside the tree without entering them. The permission check follows the same rule, so a grant that covers a link permits removing the link even when its target lies outside the grant. A recursive removal keeps the directory it validated open while it deletes, so authorization stays bound to that directory until the removal ends. [`fs.createdirectory`](/manual/api#fs.createdirectory) creates directories.
