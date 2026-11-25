---
name: package.searchpath
module: package
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: name
    type: string
  - name: path
    type: string
  - name: sep
    type: string
    optional: true
  - name: rep
    type: string
    optional: true
returns: string|nil
---

`package.searchpath(name, path, sep, rep)` returns the first file that the templates of `path` produce for `name` and that exists, or `nil` and a list of every file tried.

The parameters describe the search:

- `name` is the name to search for, such as a module name.
- `path` is a string of templates separated by `;`. Every `?` in a template is replaced by the name.
- `sep` is the string in `name` to replace before the search and defaults to `"."`. An empty `sep` replaces nothing.
- `rep` is the replacement for each `sep` and defaults to the directory separator, `/` on most systems and `\` on Windows.

A candidate counts only when it exists, is not a directory, and the chunk may read it under `fs:read`. A candidate that the permissions forbid is skipped as if it were missing, so `searchpath` itself raises no permission error. On failure, the second result lists each candidate on its own line as `no file 'PATH'`, with every line after the first starting with a tab.

```lus
print(package.searchpath("a.b", "./?.x;./lib/?.x"))
--> nil  no file './a/b.x'
-->      no file './lib/a/b.x'
print(package.searchpath("a.b", "./?.x", ".", "_"))  --> nil  no file './a_b.x'
```

[`package.path`](/manual/api#package.path) holds the templates that `require` uses.
