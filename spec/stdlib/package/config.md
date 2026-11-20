---
name: package.config
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

A string describing some compile-time configurations for packages. Its first line is the directory separator, `\` on Windows and `/` elsewhere, which `require` and `package.searchpath` put in place of each dot of a module name.
