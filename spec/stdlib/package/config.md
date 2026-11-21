---
name: package.config
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

`package.config` is a string that describes the compile-time configuration of the module system, one item per line.

The string has five lines, each followed by a newline:

- Line 1 is the directory separator, `\` on Windows and `/` elsewhere, which `require` and [`package.searchpath`](/manual/api#package.searchpath) put in place of each dot of a module name.
- Line 2 is the separator between the templates of a path, `;`.
- Line 3 is the substitution point in a template, `?`, which is replaced by the module name.
- Lines 4 and 5 hold the marks `!` and `-`, which Lua uses for the executable directory and for ignored name prefixes. Lus keeps them for compatibility, and its searchers give them no meaning.

```lus
local sep = package.config:sub(1, 1)
print(sep == "/" or sep == "\\")         --> true
print(select(2, package.config:gsub("\n", "")))   --> 5
```

The searchers use these characters as fixed values, so assigning a new string to `package.config` changes nothing. [`package.path`](/manual/api#package.path) holds the templates that the separators describe.
