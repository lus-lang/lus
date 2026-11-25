---
name: fs.path
module: fs
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `fs.path` table builds and takes apart path strings for the platform the program runs on.

Its functions work on strings alone and never touch the filesystem, so they need no permission. They treat `/` as a separator on every platform, and also `\` on Windows. The table holds [`fs.path.join`](/manual/api#fs.path.join), [`fs.path.split`](/manual/api#fs.path.split), [`fs.path.name`](/manual/api#fs.path.name), [`fs.path.parent`](/manual/api#fs.path.parent), and the constants [`fs.path.separator`](/manual/api#fs.path.separator) and [`fs.path.delimiter`](/manual/api#fs.path.delimiter).

```lus
local path = fs.path.join("docs", "guide", "intro.md")
print(fs.path.name(path))  --> intro.md
print(fs.path.parent(path))  --> docs/guide
```
