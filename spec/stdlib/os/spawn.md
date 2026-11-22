---
name: os.spawn
module: os
kind: function
since: 2.0.0
stability: unstable
pledges: ["exec"]
origin: lus
params:
  - name: argv
    type: table
  - name: options
    type: table
    optional: true
returns: userdata|nil
---

Starts a program without a shell and returns a process object, or `nil` and a message when the program cannot be found or started.

`argv` is an array of strings. `argv[1]` names the program and the other elements are its arguments, which reach the program exactly as written because no shell interprets them. A name without a separator is looked up in the directories of `PATH`, together with the extensions of `PATHEXT` on Windows. A name with a separator is a path, relative to `cwd` when that option is given. `PATH` comes from the environment that the child receives.

`options` is a table with these optional fields.

- `stdin`, `stdout`, and `stderr` each name what the stream of the child is connected to. `"inherit"`, the default, gives the child the stream of the program. `"pipe"` connects the stream to a pipe whose other end is a field of the process object. `"null"` connects it to the null device. An open file from `io.open` connects it to that file. `stderr` also accepts `"stdout"`, which sends the errors of the child wherever its output goes, into the same pipe when `stdout` is `"pipe"`.
- `env` is a table of strings that replaces the environment of the child. Without it the child receives the environment of the program, including the changes that `os.setenv` made.
- `cwd` is the working directory of the child.

The process object has these fields and methods.

- `p.pid` is the integer that the system gives the process.
- `p.stdin`, `p.stdout`, and `p.stderr` are the pipe ends of the streams opened with `"pipe"`, and `nil` for the others. They are files with the methods of `io.open` files: `p.stdin` is written with `write` and closed with `close`, and `p.stdout` and `p.stderr` are read with `read` and `lines`. A read or a write that cannot proceed waits, which suspends a detached coroutine and lets the other detached coroutines run while any other thread waits.
- `p:wait()` returns a coroutine that waits for the process to end. Resuming it returns `true` followed by the three values of `os.execute`: `true` or `nil`, then `"exit"` or `"signal"`, then the exit status or the signal number. Every call returns a new coroutine, and once the process has ended each new coroutine returns the same status at once.
- `p:poll()` returns the same three values when the process has ended, and nothing while it runs.
- `p:kill(signal)` sends a signal to the process and returns `true`, or returns `false` when the process has already ended. `signal` is `"terminate"`, the default, `"kill"`, `"interrupt"`, `"hangup"`, or a signal number. On Windows every signal ends the process with exit code 1.

Leaving the scope of a process in a `<close>` variable closes its pipes and then waits for it to end, so a child that reads its input to the end sees the end and exits. A process object that the collector reclaims while the process runs leaves it running, and the runtime collects its exit status so that it never remains a zombie. A child keeps running after the program ends.

The call requires the `exec` permission for the program. A grant without a value covers every program. A value without a separator is a glob over the name as `argv[1]` writes it, so `pledge("exec=git")` allows `{"git", ...}`. A value with a separator is a path glob over the absolute path the name resolves to, which resolves through symbolic links like a grant of `fs:read`, so `pledge("exec=/usr/bin/*")` allows every program found there. A denied program raises `permission "exec" denied for 'NAME'`. Since a shell runs any program, `os.execute` and `io.popen` need the grant without a value.

On Windows the arguments are quoted for the rules that the C runtime uses to split a command line, so a program built with any common compiler receives them unchanged. A `.bat` or `.cmd` program runs through `cmd.exe`, which parses its arguments with rules of its own. An argument for such a program that holds `%`, `!`, `"`, or a line break cannot reach it intact, and the call raises an error before it starts anything.

An `argv` that is empty, an empty program name, an element that is not a string or holds a zero byte, and an option of the wrong type raise a bad argument error.

The following example sends text through `sort` and reads the result.

```lus
pledge("exec=sort")
local p <close> = os.spawn({"sort"}, {stdin = "pipe", stdout = "pipe"})
p.stdin:write("pear\napple\nfig\n")
p.stdin:close()
print(p.stdout:read("a"))
--> apple
--> fig
--> pear
print(coroutine.resume(p:wait()))   --> true  true  exit  0
```

Two pipes that both fill can hold a child and the program in a deadlock when one thread reads them in turn. A detached coroutine for each pipe avoids that, as the following POSIX example shows with a child that writes to both streams.

```lus nocheck
pledge("exec=sh")
local p = os.spawn({"sh", "-c", "echo out; echo err >&2"}, {stdout = "pipe", stderr = "pipe"})
local errors
local reader = coroutine.detach(coroutine.create(function()
    errors = p.stderr:read("a")
end))
local output = p.stdout:read("a")
coroutine.resume(reader)
print(output:sub(1, -2), errors:sub(1, -2))      --> out  err
print(select(4, coroutine.resume(p:wait())))   --> 0
```

[`os.execute`](/manual/api#os.execute) runs a command line in the system shell, and [`os.signal`](/manual/api#os.signal) handles the signals that the program itself receives.
