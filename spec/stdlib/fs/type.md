---
name: fs.type
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
returns:
  - name: kind
    type: string
  - name: link
    type: boolean
---

Returns the kind of the entry at `path`, `"directory"` or `"file"`, and whether `path` is a symbolic link.

`path` is the string path to inspect.

On success the call returns two values. The first is `"directory"` for a directory and `"file"` for anything else. The second is `true` when `path` itself is a symbolic link and `false` otherwise. A link reports the kind of its target, and a link whose target does not exist reports `"file"`. The first value is never `"link"`. A missing `path` raises the error `"path 'PATH' does not exist"`, so a program that tests for existence wraps the call in `catch`. The call requires `fs:read` for `path`.

The following example inspects a directory, a file, and a link, and tests a missing path for existence.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-type-example")
fs.createdirectory(dir, true)
io.open(fs.path.join(dir, "data.txt"), "w"):close()
fs.createlink(fs.path.join(dir, "shortcut"), "data.txt")
print(fs.type(dir))                                --> directory  false
print(fs.type(fs.path.join(dir, "data.txt")))      --> file  false
print(fs.type(fs.path.join(dir, "shortcut")))      --> file  true
print((catch fs.type(fs.path.join(dir, "nope"))))  --> false
fs.remove(dir, true)
```

A link to a directory reports `"directory"` and `true`. [`fs.follow`](/manual/api#fs.follow) reads the target of a link, and [`fs.list`](/manual/api#fs.list) lists the entries of a directory.
