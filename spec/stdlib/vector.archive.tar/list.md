---
name: vector.archive.tar.list
module: vector.archive.tar
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: archive
    type: string|vector|userdata
returns: table
---

Returns the entries of a tar archive as an array of tables, in archive order.

- `archive` is the archive as a vector or a string, or an open file. A file is read from its start with positional reads, which leave its position unchanged, so a large archive is never loaded whole.

The reader takes ustar, pax, and GNU archives. Pax records set the name, the link target, the size, and the time. GNU long-name records set the name and the link target. Each entry is a table with these fields.

- `name` is the full name, joined from the prefix and name fields of a ustar header or taken from a pax or GNU record. Bytes that are not UTF-8 read as U+FFFD.
- `kind` is `"file"`, `"directory"`, `"symlink"`, `"link"` for a hard link, or `"special"` for a device, a FIFO, or another type.
- `size` is the size of the contents in bytes.
- `mode` is the permission bits.
- `mtime` is the modification time in seconds since the Unix epoch.
- `target` is the target of a symlink or a hard link.

The archive ends at a block of zeros. A header with a wrong checksum raises `invalid tar archive (bad header checksum)`. An archive that ends before its zero block raises `truncated archive`. A gzip-compressed tar file goes through [`vector.archive.gzip.decompress`](/manual/api#vector.archive.gzip.decompress) first.

The following example lists a compressed tar archive.

```lus
local tgz = vector.archive.gzip.compress(vector.archive.tar.pack({
    { name = "pkg/init.lus", data = "return {}" },
    { name = "pkg/latest", kind = "symlink", target = "init.lus" },
}))

for _, e in ipairs(vector.archive.tar.list(vector.archive.gzip.decompress(tgz))) do
    print(e.name, e.kind, e.target)
end
--> pkg/init.lus  file  nil
--> pkg/latest  symlink  init.lus
```
