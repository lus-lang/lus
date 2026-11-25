---
name: "file:setvbuf"
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
receiver: file
params:
  - name: mode
    type: string
  - name: size
    type: integer
    optional: true
returns: boolean|nil
---

Sets how a file handle buffers the bytes written to it, and returns `true`.

- `mode` is `"no"`, `"full"`, or `"line"`. In mode `"no"`, each `write` hands its bytes to the operating system before it returns. In mode `"full"`, the handle keeps the bytes in its buffer until the buffer is full or something flushes the handle. Mode `"line"` buffers as `"full"` does and also flushes at the end of each `write` whose bytes contain a line feed.
- `size` is the size of the buffer in bytes, 65536 by default. A `write` that would overflow the buffer flushes it first. A `write` of at least `size` bytes then goes to the operating system at once.

A handle that `io.open`, `io.popen`, or `io.tmpfile` returns starts in mode `"no"`, as do `io.stdin` and `io.stderr`. `io.stdout` starts in mode `"full"`. A handle flushes its buffer when `file:flush`, `file:sync`, or `file:close` runs, when the collector closes it, and before a read or a seek on the same handle, so a program that reads back what it wrote sees every byte. The runtime also flushes every buffered handle before it reads standard input, before [`os.execute`](/manual/api#os.execute), [`io.popen`](/manual/api#io.popen), [`os.spawn`](/manual/api#os.spawn), and [`os.exit`](/manual/api#os.exit), before it writes to the standard error, and when the program ends. The pipes of `os.spawn` hand every `write` to the operating system at once in each mode, because a full pipe pauses the coroutine that writes to it.

A change of mode flushes the bytes that the old mode buffered. If the operating system refuses that flush, the method returns `nil`, the message, and the number of the error, as a refused write does. A flush that the runtime makes on its own and the system refuses keeps its error on the handle. The next `write`, `flush`, `seek`, or `close` of that handle returns the error. The method needs no permission. A `mode` that is not one of the three raises a `bad argument` error, as does a `size` below 1. A closed handle raises `attempt to use a closed file`.

The following example keeps the lines of a log in the buffer of the handle until `close` writes all three with one system call.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-setvbuf-example.log")
local function contents()
    local f <close> = assert(io.open(path))
    return f:read("a")
end

local log = assert(io.open(path, "w"))
log:setvbuf("full")
for step = 1, 3 do
    log:write("step ", step, " done\n")
end
print(#contents())     --> 0
log:close()
print(#contents())     --> 36
fs.remove(path)
```

[`io.flush`](/manual/api#io.flush) flushes the default output. [`file:sync`](/manual/api#file:sync) writes a file through to its storage device.
