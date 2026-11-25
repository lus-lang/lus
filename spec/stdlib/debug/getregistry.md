---
name: debug.getregistry
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
returns: table
---

Returns the registry, a table that the runtime and native code share to store values that Lus code cannot reach otherwise.

The function takes no arguments and returns the same table on every call. It raises no errors.

The runtime keeps its own entries in the registry. `_LOADED` is the table of loaded modules, the same table as [`package.loaded`](/manual/api#package.loaded), and the metatables of library types such as `"time.instant"` are stored under their type names. A program that stores its own values in the registry uses keys that cannot collide with these, such as a table it created.

The following example reads two entries of the registry.

```lus
local reg = debug.getregistry()
print(type(reg), reg == debug.getregistry())                    --> table  true
print(reg._LOADED == package.loaded)                            --> true
print(debug.getmetatable(time.now()) == reg["time.instant"])    --> true
```

Changing or removing an entry that the runtime owns changes the behavior of the library that uses it.
