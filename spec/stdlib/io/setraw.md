---
name: "file:setraw"
module: io
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: file
params:
  - name: on
    type: boolean
    optional: true
returns: file|nil
---

Switches the terminal of a file handle to raw input when `on` is `true` or absent, and back to its earlier mode when `on` is `false`.

In raw mode the terminal neither echoes keys nor waits for a whole line. Each key reaches the program as soon as it is pressed, so `io.stdin:read(1)` returns one character per key. Keys that a terminal sends as several characters arrive as escape sequences, such as `"\27[A"` for the up arrow. Ctrl-C arrives as the character `"\3"` and ends nothing, so a program in raw mode handles it itself. Output keeps turning a line feed into a new line. On Windows the console delivers the same escape sequences through its virtual terminal input.

On success the method returns the handle. A handle that is not a terminal returns `nil` and `"not a terminal"`, and a platform without terminals returns `nil` and `"raw mode is not supported"`. The method needs no permission, and a closed handle raises `attempt to use a closed file`.

Raw mode belongs to the terminal, which the whole process shares. Switching back restores the mode from before the first switch, and the process restores it as well when it ends, including through an error or `os.exit`. A prompt for a password reads keys in raw mode and prints nothing for them.

```lus nocheck
io.stdin:setraw(true)
io.write("password: ")
local chars = {}
while true do
    local key = io.stdin:read(1)
    if key == "\r" or key == "\n" then break end
    chars[#chars + 1] = key
end
io.stdin:setraw(false)
print()
```

[`file:isatty`](/manual/api#file:isatty) tells whether a handle is a terminal.
