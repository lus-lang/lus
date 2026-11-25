---
name: vector.archive.tar.pack
module: vector.archive.tar
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: entries
    type: table
returns: vector
---

Writes a tar archive and returns it as a vector.

- `entries` is an array of entry tables, written in order, with the fields of [`vector.archive.zip.pack`](/manual/api#vector.archive.zip.pack) except `method`.

Each entry gets a ustar header. A name longer than the ustar fields hold, a link target longer than 100 bytes, a size of 8 GiB or more, or a time before 1970 or after 2242 adds a pax record that carries the exact value. Owners are written as 0 with empty names. The archive ends with two blocks of zeros. The errors are those of `vector.archive.zip.pack`.

The following example writes a gzip-compressed tar file of two entries.

```lus
local tar = vector.archive.tar.pack({
    { name = "release/README", data = "Read me first.\n", mtime = 1700000000 },
    { name = "release/bin/tool", data = "#!/bin/sh\n", mode = 493 },
})
print(#tar % 512)  --> 0
local tgz = vector.archive.gzip.compress(tar)
print(vector.archive.tar.list(vector.archive.gzip.decompress(tgz))[1].mtime)  --> 1700000000
```
