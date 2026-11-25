---
name: io.popen
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["exec"]
origin: lua
params:
  - name: prog
    type: string
  - name: mode
    type: string
    optional: true
returns: userdata|nil
---

Starts the program `prog` in a separate process and returns a file handle connected to its standard output or its standard input.

`prog` is a command string. It runs in the system shell: `/bin/sh -c` on POSIX systems, and `cmd.exe /s /c` on Windows, which receives the command exactly as written. `mode` is `"r"`, the default, which reads the output of the program, or `"w"`, which writes to its input. Any other mode raises a `bad argument` error.

On success the call returns one handle. A program that cannot be started returns `nil` and a message. The call requires the `exec` permission without a value, since the shell runs any program, and without it raises `permission "exec" denied for popen`. Reading a handle opened with `"w"` returns `nil`, `"file not opened for reading"`, and `0`.

Closing the handle closes the pipe in both directions and waits for the program to exit. A program that still writes its output when the handle closes then stops on a broken pipe, which on POSIX systems is the signal `SIGPIPE`. Closing returns the same three results as [`os.execute`](/manual/api#os.execute).

The following example reads the output of a command and the status it exits with.

```lus
pledge("exec")
local proc = io.popen("echo hello")
print(proc:read("l"))  --> hello
print(proc:close())  --> true  exit  0
local failing = io.popen("exit 3")
print(failing:close())  --> nil  exit  3
```

`proc:lines()` reads the output line by line and leaves the handle open, so a later `proc:close()` waits for the program and returns its status. [`os.execute`](/manual/api#os.execute) runs a command without a pipe.
