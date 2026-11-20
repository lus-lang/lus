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

Starts program `prog` in a separate process and returns a file handle. Mode `"r"`, the default, reads the program's output. Mode `"w"` writes to its input. The command runs in the system shell: `/bin/sh -c` on POSIX systems, and `cmd.exe /s /c` on Windows, which receives the command exactly as written. Closing the handle closes the pipe in both directions and waits for the program to exit. A program that still writes its output when the handle closes then stops on a broken pipe, which on POSIX systems is the signal `SIGPIPE`. Closing returns the same three results as `os.execute`.
