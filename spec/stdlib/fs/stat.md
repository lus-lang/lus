---
name: fs.stat
module: fs
kind: function
since: 2.0.0
stability: unstable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
  - name: options
    type: table
    optional: true
returns: table
---

Returns a table that describes the file, directory, or link at `path`.

The table has three fields. `size` is the size in bytes as an integer. `modified` is the time of the last change to the contents, as a wall-clock `instant` of the `time` library. `kind` is `"file"`, `"directory"`, `"link"`, or `"other"` for a device, a socket, or a named pipe.

`options` is a table with one optional field, `follow`. With `follow` true, the default, a symbolic link is followed and the table describes its target, as the first result of [`fs.type`](/manual/api#fs.type) does, so `kind` is never `"link"`. With `follow` false the table describes the link itself, and `kind` is `"link"`.

Every failure raises an error. A `path` that does not exist, or a link whose target does not exist when `follow` is true, raises `"path 'PATH' does not exist"`, and any other failure raises `"cannot stat 'PATH': REASON"`. A `follow` that is not a boolean raises a bad argument error. The call requires `fs:read` for `path`.

The following example writes a file and reads its size and the age of its contents.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-stat-example.txt")
local f = io.open(path, "w")
f:write("hello")
f:close()
local info = fs.stat(path)
print(info.kind, info.size)                        --> file  5
print((time.now() - info.modified):seconds() < 60)   --> true
fs.remove(path)
```

[`fs.type`](/manual/api#fs.type) tells files and directories apart without the other fields.
