---
name: debug.traceback
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: message
    type: any
    optional: true
  - name: level
    type: integer
    optional: true
returns: string
---

Returns a string that describes the call stack, one line per level, after an optional message.

The function accepts an optional thread as its first argument, and the traceback then describes the stack of that thread.

- `message` is text to place on the first line. It may be a string or a number, and it is omitted when absent or `nil`.
- `level` is the stack level where the traceback starts. It defaults to 1, the function that called `debug.traceback`, or to 0 when the traceback describes another thread.

The function returns the message followed by a newline, when there is a message, then the line `stack traceback:`, then one line per level. Each level line starts with a tab and gives the source and current line of the function, then how it was called, such as `in local 'f'`, `in main chunk`, or `in function <file:3>`. A level reached through a tail call is followed by the line `(...tail calls...)`. A traceback of more than 22 levels keeps the first 10 and the last 11 and replaces the rest with a line that ends in `(skipping N levels)`, where `N` is one less than the number of levels left out, as in Lua. A `level` beyond the bottom of the stack starts at the outermost level.

If `message` is neither a string, a number, nor `nil`, the function returns it unchanged and builds no traceback, so an error handler can pass any error object through. A non-integer `level` raises `bad argument #2 to 'traceback'`.

The following example takes a traceback inside a function and prints its first two lines, which do not depend on the file name.

```lus
local function checkpoint()
    return debug.traceback("checkpoint reached")
end
local lines = {}
for line in checkpoint():gmatch("[^\n]+") do lines[#lines + 1] = line end
print(lines[1])                              --> checkpoint reached
print(lines[2])                              --> stack traceback:
print(debug.traceback({ code = 7 }).code)    --> 7
```

The `lus` command prints a traceback of this form when an error ends a script. [`debug.getinfo`](/manual/api#debug.getinfo) returns the same information for one level as a table.
