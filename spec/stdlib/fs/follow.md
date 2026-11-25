---
name: fs.follow
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
returns: string
---

Returns the target stored in the symbolic link at `path`, exactly as the link stores it.

`path` is the string path of a symbolic link. The target is not resolved further, so a relative target comes back relative, and a target that does not exist is returned all the same.

On success the call returns one string. Every failure raises an error. An entry that exists and is not a symbolic link raises `"'PATH' is not a symbolic link"`, and a missing `path` raises `"cannot stat 'PATH': No such file or directory"`. The call requires `fs:read` for `path`.

The following example reads the targets of two links, one of them dangling, and shows that a plain file is rejected.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-follow-example")
fs.createdirectory(dir, true)
local file = fs.path.join(dir, "data.txt")
io.open(file, "w"):close()
fs.createlink(fs.path.join(dir, "good"), "data.txt")
fs.createlink(fs.path.join(dir, "dangling"), "missing.txt")
print(fs.follow(fs.path.join(dir, "good")))  --> data.txt
print(fs.follow(fs.path.join(dir, "dangling")))  --> missing.txt
print((catch fs.follow(file)))  --> false
fs.remove(dir, true)
```

The second result of [`fs.type`](/manual/api#fs.type) tells whether a path is a symbolic link before `fs.follow` reads it. [`fs.createlink`](/manual/api#fs.createlink) creates a link.
