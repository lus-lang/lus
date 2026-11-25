---
name: vector.archive.zip.read
module: vector.archive.zip
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

Returns the contents of one file in a ZIP archive as a vector, or `nil` when the archive holds no entry by that name.

- `archive` is a vector, a string, or an open file, as for [`vector.archive.zip.list`](/manual/api#vector.archive.zip.list).
- `name` is the entry name. Names compare after dropping empty and `.` components, so `"./a//b"` finds `a/b`.
- `max` is the largest size in bytes to read. It defaults to 536,870,912 (512 MiB), and a value of 0 or less also selects the default.

The function reads the first entry with the name. It checks the local header against the central directory, counts the bytes actually decompressed against both `max` and the size the header declares, and checks the CRC-32. An entry that grows past `max` raises `archive exceeds size limit (N bytes)`. A size that differs from the header raises `size of 'NAME' does not match its header`. A wrong checksum raises `checksum mismatch in 'NAME'`. An entry that is a directory or a symlink raises `'NAME' is not a file`. A name with a `..` component or an absolute path raises `unsafe entry name 'NAME'`. Encrypted entries raise `encrypted entry 'NAME' is not supported`. Compression methods other than store and deflate raise `unsupported compression method N in 'NAME'`.

The following example reads one file of an archive and looks for a missing one.

```lus
local zip = vector.archive.zip.pack({ { name = "config.json", data = '{"debug":true}' } })
print(vector.tostring(vector.archive.zip.read(zip, "config.json")))  --> {"debug":true}
print(vector.archive.zip.read(zip, "missing.json"))  --> nil
```
