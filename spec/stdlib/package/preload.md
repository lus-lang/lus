---
name: package.preload
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: table
---

`package.preload` is a table of loader functions keyed by module name, which `require` consults before it searches any file.

The first default searcher looks up `package.preload[name]`. When it holds a value, `require` calls it as the loader with the module name and the string `":preload:"`, and caches its result in [`package.loaded`](/manual/api#package.loaded). The table starts empty, and a module loaded from it needs no permission.

```lus
package.preload.settings = function(name)
    return { name = name, debug = false }
end
local settings, origin = require("settings")
print(settings.name, origin)   --> settings  :preload:
```

A value of `package.preload` that is not a table makes `require` raise `'package.preload' must be a table`. [`require`](/manual/api#require) describes the whole loading process.
