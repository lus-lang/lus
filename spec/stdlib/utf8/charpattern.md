---
name: utf8.charpattern
module: utf8
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: string
---

`utf8.charpattern` is the pattern that matches exactly one character, and its value is `"."`.

Lus patterns match whole characters, so `.` matches one character of any length in bytes. Programs written for Lua, where the pattern matches one UTF-8 sequence byte by byte, work unchanged.

```lus
for ch in ("añb"):gmatch(utf8.charpattern) do
    io.write("[", ch, "]")
end

print()  --> [a][ñ][b]
```

[String patterns](/manual/guide#strings-and-patterns) in the guide describes the pattern language.
