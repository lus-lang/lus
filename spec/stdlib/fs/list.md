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

`path` is the string path of a directory. The optional `glob` is a string that keeps only the entries that match it. Without `glob`, every entry is listed.

In a glob, `*` matches any sequence of characters, including the empty one, and `?` matches exactly one character. `[abc]` matches one of the characters between the brackets, `[a-z]` one character of the range, and `[!abc]` one character that is not listed. A `]` right after the opening bracket is a member of the class, so `[]]` matches `]`, and `[*]` matches a literal `*`. `{a,b}` stands for each of its comma separated alternatives in turn, and braces nest. A name that starts with `.` matches `*` like any other name. A `[` without its `]` and a `{` without its `}` match themselves.

A glob that contains `/` or a `**` segment reaches below `path`. The glob is then matched against the path of each entry relative to `path`, with `/` between its segments, and the array holds those relative paths. A `**` segment matches any number of directories, including none, so `**/*.lus` matches `main.lus` and `lib/util.lus`. Directories that no match can lie under are not read, and symbolic links to directories are listed without being followed. A glob that expands to more than 256 patterns raises an error.

On success the call returns one table. The names of a glob that stays in `path` carry no directory prefix, the array leaves out `.` and `..`, and the order of the names is unspecified. An empty directory gives an empty table. Every failure raises an error. A missing directory raises `"cannot list directory PATH: No such file or directory"`, and a `path` that names a file raises `"PATH is not a directory"`. The call requires `fs:read` for `path`.

The following example lists a directory with and without a glob, sorting the names because their order is unspecified.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-list-example")
fs.createdirectory(dir, true)

for _, name in ipairs({ "b.json", "a.json", "notes.md" }) do
    io.open(fs.path.join(dir, name), "w"):close()
end

fs.createdirectory(fs.path.join(dir, "old"))
io.open(fs.path.join(dir, "old", "c.json"), "w"):close()
local names = fs.list(dir, "*.json")
table.sort(names)
print(table.concat(names, " "))  --> a.json b.json
local all = fs.list(dir, "**/*.{json,md}")
table.sort(all)
print(table.concat(all, " "))  --> a.json b.json notes.md old/c.json
print(#fs.list(dir))  --> 4
fs.remove(dir, true)
```

A symbolic link appears in the list under its own name. [`fs.walk`](/manual/api#fs.walk) visits a whole tree one entry at a time, and [`fs.type`](/manual/api#fs.type) tells files and directories apart, and [`fs.path.join`](/manual/api#fs.path.join) builds the full path of an entry.
