---
name: package.path
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

The source-module templates used by `require`. The default is `./?.lus;./?/init.lus;./?.lua;./?/init.lua`, which searches the current directory and puts `.lus` and `init.lus` before the matching `.lua` compatibility templates.

When the environment variable `LUS_PATH` is set, its value becomes the initial `package.path`. The `-E` option ignores it. Programs that ship their modules together use `--include` or `lus build`, which make the modules available to `require` from any directory.
