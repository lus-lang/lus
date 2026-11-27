---
name: "file:readbytes"
module: io
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: file
params:
  - name: n
    type: integer
returns: vector|nil
---

Reads up to `n` bytes from the file handle and returns them as a vector.

`n` is the number of bytes to read. The call waits until `n` bytes arrived or the file ended, so the vector holds fewer than `n` bytes only at the end of the file. It returns `nil` when the file ended before any byte. A negative `n` raises `bad argument #2 to 'readbytes' (the count must not be negative)`.

The bytes are returned as they are in the file, whatever the mode of the handle. A handle in text mode, such as the standard input, therefore reads a message whose size is given in bytes with this method, and [`vector.tostring`](/manual/api#vector.tostring) turns the bytes into a string. The method shares the position of the handle with [`file:read`](/manual/api#io.read), so a program reads the header lines of a message with `read` and its body with `readbytes`.

The following example writes a message with a size in bytes and reads it back.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-readbytes-example.txt")
local body = "héllo"
io.open(path, "w"):write(`$(string.bytelen(body))\n$body`):close()
local f = io.open(path)
local size = tonumber(f:read("l"))
print(size)  --> 6
print(vector.tostring(f:readbytes(size)))  --> héllo
print(f:readbytes(1))  --> nil
f:close()
fs.remove(path)
```

[`string.bytelen`](/manual/api#string.bytelen) returns the size of a string in bytes.
