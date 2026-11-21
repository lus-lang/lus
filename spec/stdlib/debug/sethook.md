---
name: debug.sethook
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: hook
    type: function
    optional: true
  - name: mask
    type: string
    optional: true
  - name: count
    type: integer
    optional: true
---

Installs a function as the debug hook of a thread, or removes the hook when called without one.

The function accepts an optional thread as its first argument, and the hook then applies to that thread. It defaults to the running thread.

- `hook` is the function to call on each event. Without it, the hook of the thread is removed.
- `mask` is a string whose letters select events: `c` calls the hook on every call, `r` on every return, and `l` on every new line. Other characters are ignored.
- `count` is an integer. A value above 0 also calls the hook after every `count` instructions. It defaults to 0.

The hook receives the name of the event as its first argument: `"call"`, `"return"`, `"line"`, or `"count"`. A line event also passes the new line number as the second argument. The function returns no values.

A `mask` with none of the three letters and a `count` of 0 or less removes the hook, as a call without arguments does. A `hook` that is not a function raises `bad argument #1 to 'sethook' (function expected)`. A missing `mask` raises `bad argument #2 to 'sethook' (string expected)`, and a non-integer `count` raises `bad argument #3 to 'sethook'`.

The following example records the calls, returns, and lines of one call to a function.

```lus
local events = {}
local function square(x)
    return x * x
end
debug.sethook(function(event, line)
    events[#events + 1] = line and `$(event) $(line)` or event
end, "crl")
square(3)
debug.sethook()
print(table.concat(events, ", "))    --> line 8, call, line 3, return, line 9
```

Each thread has one hook, and installing a new one replaces the old. [`debug.gethook`](/manual/api#debug.gethook) reads the hook back, and [`debug.getinfo`](/manual/api#debug.getinfo) with level 2 describes the function that triggered the event.
