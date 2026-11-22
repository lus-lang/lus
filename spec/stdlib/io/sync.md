---
name: "file:sync"
module: io
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: file
returns: file
---

Writes the data and the size of a file through to its storage device and returns the file handle.

A write returns once the operating system holds the bytes in its cache, and a crash of the system or a loss of power can still lose them. After `file:sync()` returns, the bytes written before the call survive both. On macOS the call also asks the drive to empty its own cache, which a plain sync leaves full. For the standard output the call flushes the buffered output, and for a pipe and the other standard streams it does nothing, since they keep nothing on a device. The method needs no permission, a closed handle raises `attempt to use a closed file`, and a failure of the device returns `nil`, the message, and the number of the error, as a refused write does.

The following example writes a file and syncs it before closing.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-sync-example.txt")
local f = assert(io.open(path, "w"))
f:write("saved\n")
print(f:sync() == f)   --> true
f:close()
fs.remove(path)
```

A synced file can still disappear if its name is new: the entry of a file lives in its directory, which [`fs.sync`](/manual/api#fs.sync) syncs. [Durable writes](/manual/filesystem#durable-writes) describes the full sequence.
