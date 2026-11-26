---
name: package.searchers
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: table
---

`package.searchers` is the sequence of searcher functions that `require` calls, in order, to find the loader of a module.

`require` calls each searcher with the module name. A searcher that finds the module returns a loader function and an extra value that `require` passes to the loader. A searcher that does not find it returns a string that explains why, which `require` adds to its `module 'NAME' not found:` error, or returns nothing.

The six default searchers run in this order:

1. [`package.preload`](/manual/api#package.preload).
2. Modules preincluded with `--include`, loaded from memory.
3. Modules bundled into an executable by `lus build`.
4. Source modules found through [`package.path`](/manual/api#package.path). The extra value is the path of the file.
5. Native modules found through [`package.cpath`](/manual/api#package.cpath), which raise an error because native C libraries are unavailable.
6. Native modules found through `package.cpath` under the first part of a dotted name, which raise the same error.

```lus
table.insert(package.searchers, 1, function(name)
    if name:match("^virtual%.") then
        return function(modname)
            return { id = modname }
        end, "virtual"
    end

    return `no virtual module '$name'`
end)

print(require("virtual.answer").id)  --> virtual.answer
```

A program may insert, remove, or reorder searchers. A value of `package.searchers` that is not a table makes `require` raise `'package.searchers' must be a table`. [`require`](/manual/api#require) describes the whole loading process.
