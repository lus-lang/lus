---
name: package.path
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

`package.path` is the string of templates that `require` searches for source modules, separated by `;`.

In each template, `require` replaces every `?` with the module name, after turning each dot of the name into the directory separator, and tries the resulting files in order. The default is `./?.lus;./?/init.lus;./?.lua;./?/init.lua`, which searches the working directory and puts `.lus` and `init.lus` before the matching `.lua` compatibility templates.

When the environment variable `LUS_PATH` is set, its value becomes the initial `package.path`. The `-E` option ignores it. `require` reads `package.path` at each search, so a program may assign a new string before it requires a module, and a value that is not a string makes the search raise `'package.path' must be a string`.

```lus
print(package.path)  --> ./?.lus;./?/init.lus;./?.lua;./?/init.lua
print(package.searchpath("util.strings", "./lib/?.lus"))
--> nil  no file './lib/util/strings.lus'
```

Programs that ship their modules together use `--include` or `lus build`, which make the modules available to `require` from any directory. [`package.searchpath`](/manual/api#package.searchpath) applies the same template rules to any path string, and [Search paths](/manual/guide#search-paths) in the guide describes the order of the searchers.
