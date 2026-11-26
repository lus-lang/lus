---
name: vector.archive.zip.unpack
module: vector.archive.zip
kind: function
since: 2.0.0
stability: unstable
pledges: ["fs:write"]
origin: lus
params:
  - name: archive
    type: string|vector|userdata
  - name: directory
    type: string
  - name: options
    type: table
    optional: true
returns: integer
---

Writes every entry of a ZIP archive under `directory` and returns the number of entries written.

- `archive` is a vector, a string, or an open file, as for [`vector.archive.zip.list`](/manual/api#vector.archive.zip.list).
- `directory` is the target directory, created when it does not exist.
- `options` may set `max`, the largest total size in bytes to write, 536,870,912 by default, `entries`, the largest number of entries, 10,000 by default, and `overwrite`.

Every write stays inside `directory`. Before anything is written, the function checks every entry. An archive that fails a check leaves the file system untouched.

- An entry name that is absolute, starts with a drive letter, or holds a backslash, a NUL byte, or a `..` component raises `unsafe entry name 'NAME'`.
- A symlink is created only when its target is relative, all of its `..` components come first, and they climb no higher than the directory that holds the link. Any other target raises `symlink 'NAME' points outside the target directory`.
- The local header of every entry must match the central directory. No two entries may share bytes. Overlapping entries raise `invalid ZIP archive (overlapping entries)`, which stops an archive from reaching a high ratio by pointing many entries at the same data.
- More entries than `entries` raise `archive exceeds entry limit (N entries)`.

While writing, every directory on the way to an entry is opened without following a symbolic link, so no entry is written through a link, whether the archive made it or it was already on disk. Such a path raises `cannot write 'PATH' (a parent is a symlink or a file)`. Sizes are counted from the bytes actually decompressed, so a total past `max` raises `archive exceeds size limit (N bytes)` whatever the headers declare. Files get the permission bits `0644`, or `0755` when the entry is executable. Directories get `0755`.

A file that already exists raises `file exists: PATH`. Directories that exist are merged. With `overwrite = true`, an existing file or symlink is removed and the entry written in its place, never through it. The function requires `fs:write` for `directory` and for every path it writes. The other errors are those of [`vector.archive.zip.read`](/manual/api#vector.archive.zip.read).

The following example unpacks an archive, then unpacks it again over the same files.

```lus
local zip = vector.archive.zip.pack({
    { name = "site/index.html", data = "<h1>hi</h1>" },
    { name = "site/css/main.css", data = "h1 { color: red }" },
})
local dir = `unpack-example-$(time.now():epoch())`
print(vector.archive.zip.unpack(zip, dir))  --> 2
print(catch vector.archive.zip.unpack(zip, dir))  --> false  ...: file exists: ...
print(vector.archive.zip.unpack(zip, dir, { overwrite = true }))  --> 2
fs.remove(dir, true)
```
