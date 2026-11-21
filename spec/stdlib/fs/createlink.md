---
name: fs.createlink
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lus
params:
  - name: link
    type: string
  - name: target
    type: string
returns: []
---

Creates a symbolic link at `link` that points to `target` and returns no values.

`link` is the string path where the link is created, and nothing may exist there yet. `target` is the string the link stores. It is stored exactly as given, so a relative target resolves against the directory of the link when the link is used, and the target need not exist.

On success the call returns nothing. Every failure raises an error of the form `"failed to create symlink 'LINK' -> 'TARGET': REASON"`, where the reason comes from the operating system, such as `File exists` when `link` already exists. The call requires `fs:write` for both `link` and `target`, so a script cannot plant a link that leads outside the paths it may write.

The following example links to a file by a relative target and reads the stored target back.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-link-example")
fs.createdirectory(dir, true)
io.open(fs.path.join(dir, "real.txt"), "w"):close()
local alias = fs.path.join(dir, "alias")
fs.createlink(alias, "real.txt")
print(fs.follow(alias))   --> real.txt
print(fs.type(alias))     --> file  true
fs.remove(dir, true)
```

A link to a missing target is created without complaint, and [`fs.type`](/manual/api#fs.type) reports it as `"file"`. [`fs.follow`](/manual/api#fs.follow) reads the stored target, and [`fs.remove`](/manual/api#fs.remove) removes the link and leaves its target in place.
