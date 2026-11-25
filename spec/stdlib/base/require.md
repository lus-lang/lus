---
name: require
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: modname
    type: string
returns: any
---

`require(modname)` loads the module `modname` once and returns its value, which later calls return from the cache in [`package.loaded`](/manual/api#package.loaded).

The parameter `modname` is the module name, such as `"json_helpers"` or `"util.strings"`. When `package.loaded[modname]` is truthy, `require` returns that value alone. Otherwise it calls each function of [`package.searchers`](/manual/api#package.searchers) in order with `modname` until one returns a loader. The default searchers look in [`package.preload`](/manual/api#package.preload), in the modules preincluded with `--include`, in the modules bundled by `lus build`, and in the files that [`package.path`](/manual/api#package.path) names, where each dot of the name becomes a directory separator.

`require` calls the loader with `modname` and the extra value the searcher returned, which is the path of the file for a file module. A result other than `nil` is stored in `package.loaded[modname]`. When the loader returns `nil` and stored nothing, `require` stores `true`. On a first load, `require` returns the stored value and the extra value of the searcher.

A name that no searcher finds raises `module 'NAME' not found:`, followed by the message of each searcher on its own line. A module file with a syntax error raises `error loading module 'NAME' from file 'PATH':` followed by the syntax error. An error raised while the module runs propagates to the caller.

Loading a module from a file requires `fs:read` for the file and the `load` permission. A candidate file that the chunk may not read is skipped and listed as not found, and a missing `load` permission raises `permission "load" denied`. Modules from `package.preload`, from `--include`, and from a `lus build` bundle load without permissions.

```lus
package.preload.greeter = function(name)
    return {
        hello = function()
            return "hello from " .. name
        end,
    }
end

local greeter, origin = require("greeter")
print(greeter.hello(), origin)  --> hello from greeter  :preload:
print(require("greeter") == greeter)  --> true
```

`require` keeps the loaded table that the package library created, so assigning a new table to `package.loaded` leaves the cache in place. The standard libraries are in the cache from the start, so `require("string")` returns the `string` table. [Modules and require](/manual/guide#modules) in the guide describes search paths and preincluded modules.
