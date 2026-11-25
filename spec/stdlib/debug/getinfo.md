---
name: debug.getinfo
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: f
    type: function|integer
  - name: what
    type: string
    optional: true
returns: table|nil
---

Returns a table that describes a function or an active stack level, or `nil` when the level lies beyond the stack.

The function accepts an optional thread as its first argument, and the remaining arguments then refer to that thread.

- `f` is a function, or an integer stack level. Level 0 is `debug.getinfo` itself, level 1 is the function that called it, and so on.
- `what` is a string of option letters that select the fields to fill. It defaults to `"flnSrtu"`, every option except `L`.

The options fill these fields:

- `S` fills `source`, `short_src`, `linedefined`, `lastlinedefined`, and `what`. `what` is `"main"` for a main chunk, `"Lua"` for a Lus function, and `"C"` for a native function. A native function has `source` `"=[C]"`, `short_src` `"[C]"`, and both line fields `-1`.
- `l` fills `currentline`, the line that the level is running. It is `-1` for a native function and when `f` is a function rather than a level.
- `u` fills `nups`, `nparams`, and `isvararg`. A native function reports `nparams` 0 and `isvararg` `true`.
- `n` fills `name` and `namewhat`, such as `"local"`, `"global"`, `"method"`, or `"field"`. A function with no known name has `namewhat` `""` and no `name`.
- `t` fills `istailcall`.
- `r` fills `ftransfer` and `ntransfer`, which are always 0.
- `f` fills `func`, the function itself.
- `L` fills `activelines`, a table whose keys are the lines that carry code. A native function has no `activelines` field.

A level beyond the stack, or a negative level, returns `nil`. An unknown option letter, or a `what` that starts with `>`, raises `bad argument #2 to 'getinfo' (invalid option)`. An `f` that is neither a function nor an integer raises `bad argument #1 to 'getinfo'`.

The following example reads the name and line of the running function and the parameters of another.

```lus
local function where()
    local info = debug.getinfo(1, "nSl")
    return info.name, info.namewhat, info.what, info.currentline
end
print(where())                           --> where  local  Lua  2
local u = debug.getinfo(string.rep, "u")
print(u.nparams, u.isvararg)             --> 0  true
print(debug.getinfo(100))                --> nil
```

[`debug.traceback`](/manual/api#debug.traceback) formats the same information for every level of the stack, and [`debug.getlocal`](/manual/api#debug.getlocal) reads the variables of a level.
