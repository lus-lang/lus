---
name: debug.debug
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
---

Runs an interactive loop that reads one line of standard input at a time, runs it as Lus code, and returns no values when the loop ends.

The function takes no arguments. It writes the prompt `lus_debug> ` to standard error before each line. Each line compiles and runs as a chunk of its own, so a local declared on one line is gone on the next, while globals persist. A line that raises an error writes the error message to standard error, and the loop continues. A line that reads `cont`, or the end of standard input, ends the loop.

The function requires the `load` permission. Without it, the call raises `permission "load" denied`.

The following function stops in the loop before it returns. Typing `print(debug.getlocal(3, 1))` at the prompt prints `n` and `21`, because level 1 is the line itself, level 2 is `debug.debug`, and level 3 is `step`. Typing `cont` resumes the program, which prints `42`.

```lus nocheck
local function step(n)
    debug.debug()
    return n * 2
end
print(step(21))
```

A line sees the locals of the paused function only through [`debug.getlocal`](/manual/api#debug.getlocal) and [`debug.setlocal`](/manual/api#debug.setlocal). The `lus debug` command runs a whole script under a debugger that speaks the Debug Adapter Protocol.
