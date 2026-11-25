---
name: vector.archive.tar.read
module: vector.archive.tar
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: archive
    type: string|vector|userdata
  - name: name
    type: string
  - name: max
    type: integer
    optional: true
returns: vector|nil
---

Returns the contents of one file in a tar archive as a vector, or `nil` when the archive holds no entry by that name.

- `archive` is a vector, a string, or an open file, as for [`vector.archive.tar.list`](/manual/api#vector.archive.tar.list).
- `name` is the entry name. Names compare after dropping empty and `.` components, so `"./a//b"` finds `a/b`.
- `max` is the largest size in bytes to read. It defaults to 536,870,912 (512 MiB), and a value of 0 or less also selects the default.

The function reads the first entry with the name. Tar carries no checksum of the contents, so only the headers are checked. An entry larger than `max` raises `archive exceeds size limit (N bytes)`. An entry that is not a file raises `'NAME' is not a file`. A name with a `..` component or an absolute path raises `unsafe entry name 'NAME'`.

The following example reads a file from an archive.

```lus
local tar = vector.archive.tar.pack({ { name = "VERSION", data = "2.0.0\n" } })
io.write(vector.tostring(vector.archive.tar.read(tar, "VERSION")))  --> 2.0.0
```
