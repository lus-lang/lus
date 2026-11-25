---
name: fs.walk
module: fs
kind: function
since: 2.0.0
stability: unstable
pledges: ["fs:read"]
origin: lus
params:
  - name: dir
    type: string
  - name: options
    type: table
    optional: true
returns: function
---

Returns an iterator that visits every entry below the directory `dir`, for use in a generic `for`.

Each step gives three values: the path of the entry joined to `dir`, then `"directory"` or `"file"`, then whether the entry is a symbolic link. These are the path that `fs.path.join` would build and the two results of `fs.type`, so the path opens directly. The walk is depth first. Within each directory the names are sorted by their bytes, and a directory comes before the entries inside it, so a walk of the same tree gives the same sequence on every system. A directory is read when the walk reaches it.

`options` is a table with these optional fields.

- `depth` limits how far the walk goes. `1` visits the entries of `dir` only, `2` adds the entries of its subdirectories, and so on. Without it the walk has no limit.
- `glob` keeps only the entries that match it, in the glob syntax of [`fs.list`](/manual/api#fs.list). A glob without `/` and `**` matches the name of each entry at any depth, so `"*.lus"` keeps every Lus file. Any other glob matches the path relative to `dir`, with `/` between its segments, and the walk skips directories that no match can lie under.
- `exclude` is a glob or an array of globs, matched the same way. An entry that matches is neither reported nor entered, so `exclude = "node_modules"` leaves out every directory of that name with all it holds.
- `links` is `"list"`, the default, or `"follow"`. With `"list"` a symbolic link is reported with the type of its target and the walk does not enter it. With `"follow"` the walk enters links to directories, except a link to a directory that the walk is already inside, which would never end.
- `errors` is `"raise"`, the default, or `"skip"`. With `"skip"` a subdirectory that cannot be read, such as one without read permission, is left out. A `dir` that cannot be read raises in both modes.

The call requires `fs:read` for `dir` and raises at once without it. The walk reports the entries of every directory it reads but enters a subdirectory only when `fs:read` covers it. A `dir` that does not exist raises `"cannot list directory DIR: No such file or directory"` at the first step, and a `dir` that names a file raises `"DIR is not a directory"`. An option of the wrong type or value raises a bad argument error.

The iterator closes when the loop ends, also through `break` or an error, because the call returns a closing value as the fourth result of the generic `for`.

The following example builds a small tree and prints the Lus files in it, leaving out a directory of dependencies.

```lus
pledge("env", "fs")
local dir = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-walk-example")
fs.createdirectory(fs.path.join(dir, "lib"), true)
fs.createdirectory(fs.path.join(dir, "deps", "json"), true)

for _, name in ipairs({ "main.lus", "notes.md", "lib/util.lus", "deps/json/json.lus" }) do
    io.open(fs.path.join(dir, name), "w"):close()
end

for path, kind in fs.walk(dir, { glob = "*.lus", exclude = "deps" }) do
    print(fs.path.name(path), kind)
end

--> util.lus  file
--> main.lus  file
fs.remove(dir, true)
```

[`fs.list`](/manual/api#fs.list) returns the matching paths of a tree as one array.
