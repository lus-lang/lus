---
name: vector.archive.tar.unpack
module: vector.archive.tar
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

Writes every entry of a tar archive under `directory` and returns the number of entries written.

- `archive` is a vector, a string, or an open file, as for [`vector.archive.tar.list`](/manual/api#vector.archive.tar.list).
- `directory` is the target directory, created when it does not exist.
- `options` may set `max`, `entries`, and `overwrite`, as for [`vector.archive.zip.unpack`](/manual/api#vector.archive.zip.unpack).

The function keeps every write inside `directory` by the rules of `vector.archive.zip.unpack`, and checks every entry before it writes anything. Hard links and special files raise `unsupported entry type 'link' for 'NAME'` or the same error with `'special'`. The function requires `fs:write` for `directory` and for every path it writes.

The following example unpacks a compressed tar file into a new directory.

```lus
local tgz = vector.archive.gzip.compress(vector.archive.tar.pack({
    { name = "data/a.csv", data = "x,y\n1,2\n" },
}))
local dir = "tar-example-" .. time.now():epoch()
print(vector.archive.tar.unpack(vector.archive.gzip.decompress(tgz), dir))  --> 1
print((fs.type(dir .. "/data/a.csv")))  --> file
fs.remove(dir, true)
```
