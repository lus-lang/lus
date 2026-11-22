---
name: vector.archive.zip.list
module: vector.archive.zip
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: archive
    type: string|vector|userdata
returns: table
---

Returns the entries of a ZIP archive as an array of tables, in the order of its central directory.

- `archive` is the archive as a vector or a string, or an open file. A file is read from its start with positional reads, which leave its position unchanged, so a large archive is never loaded whole.

Each entry is a table with these fields.

- `name` is the name as stored. Bytes that are not UTF-8 read as U+FFFD.
- `kind` is `"file"`, `"directory"`, or `"symlink"`.
- `size` is the size of the contents in bytes, and 0 for a directory or a symlink.
- `mode` is the permission bits, such as `420` (`0644`).
- `mtime` is the modification time in seconds since the Unix epoch. The Unix timestamp field is read when present. Otherwise the DOS date and time are read, taken as UTC.
- `target` is the target of a symlink.
- `method` is `"store"` or `"deflate"`.
- `compressed` is the size of the stored data in bytes.

ZIP64 archives are read. Data that is not a ZIP archive raises `invalid ZIP archive` with the reason in parentheses, such as `(no end of central directory)`. An archive that ends early raises `truncated archive`. An argument that is not a string, a vector, or a file raises `bad argument #1 to 'list' (string, vector, or file expected, got boolean)` with its type.

The following example packs two files and lists them.

```lus
local zip = vector.archive.zip.pack({
    { name = "notes/todo.txt", data = "buy milk" },
    { name = "notes/done.txt", data = "", method = "store" },
})
for _, e in ipairs(vector.archive.zip.list(zip)) do
    print(e.name, e.kind, e.size, e.method)
end
--> notes/todo.txt  file  8  deflate
--> notes/done.txt  file  0  store
```
