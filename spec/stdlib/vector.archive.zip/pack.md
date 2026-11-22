---
name: vector.archive.zip.pack
module: vector.archive.zip
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: entries
    type: table
  - name: options
    type: table
    optional: true
returns: vector
---

Writes a ZIP archive and returns it as a vector.

- `entries` is an array of entry tables, written in order.
- `options` may set `method`, the default method of every entry, and `level`, the deflate level from 0 to 9, which defaults to 6.

Each entry table has these fields.

- `name` is the entry name, which is required. `kind` is `"file"`, the default, `"directory"`, or `"symlink"`. A name that ends in `/` defaults to a directory.
- `data` is the contents of a file, a string or a vector. It defaults to empty.
- `target` is the target of a symlink, which is required for one.
- `mode` is the permission bits. It defaults to `0644` for a file, `0755` for a directory, and `0777` for a symlink.
- `mtime` is the modification time in seconds since the Unix epoch. It defaults to 0. ZIP dates start in 1980, so an earlier time is written as 1 January 1980 in the DOS field. The exact time goes in the Unix timestamp field.
- `method` is `"deflate"`, the default, or `"store"`.

Names are stored normalized and in UTF-8, with a `/` after a directory. The writer adds ZIP64 records when a size, an offset, or the entry count needs them. A name that is empty, absolute, or holds a `..` component raises `unsafe entry name 'NAME'`. A missing name raises `bad entry #1 to 'pack' (field 'name' missing)`. A field of the wrong type raises the same error with the field named.

The following example packs a small project and checks that a file reads back.

```lus
local zip = vector.archive.zip.pack({
    { name = "app", kind = "directory" },
    { name = "app/main.lus", data = 'print("hi")' },
    { name = "app/run.sh", data = "#!/bin/sh\nlus main.lus\n", mode = 493 },
}, { level = 9 })
print(#vector.archive.zip.list(zip))                                  --> 3
print(vector.tostring(vector.archive.zip.read(zip, "app/main.lus")))  --> print("hi")
```
