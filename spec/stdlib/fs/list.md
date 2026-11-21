---
name: fs.list
module: fs
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
  - name: glob
    type: string
    optional: true
returns: table
---

Returns an array with the name of every entry in the directory at `path`.

`path` is the string path of a directory. The optional `glob` is a string that keeps only the names that match it. In a glob, `*` matches any sequence of characters, including the empty one, and `?` matches exactly one byte, which is one character in an ASCII name. A name that starts with `.` matches `*` like any other name. Without `glob`, every entry is listed.

On success the call returns one table. The names carry no directory prefix, the array leaves out `.` and `..`, and the order of the names is unspecified. An empty directory gives an empty table. Every failure raises an error. A missing directory raises `"cannot list directory PATH: No such file or directory"`, and a `path` that names a file raises `"PATH is not a directory"`. The call requires `fs:read` for `path`.

The following example lists a directory with and without a glob, sorting the names because their order is unspecified.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-list-example")
fs.createdirectory(dir, true)
for _, name in ipairs({"b.json", "a.json", "notes.md"}) do
    io.open(fs.path.join(dir, name), "w"):close()
end
local names = fs.list(dir, "*.json")
table.sort(names)
print(table.concat(names, " "))   --> a.json b.json
print(#fs.list(dir))              --> 3
fs.remove(dir, true)
```

A symbolic link appears in the list under its own name. [`fs.type`](/manual/api#fs.type) tells files and directories apart, and [`fs.path.join`](/manual/api#fs.path.join) builds the full path of an entry.
