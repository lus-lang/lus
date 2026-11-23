---
name: "tcp_server.accepted"
module: network.tcp
kind: variable
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_server
type: thread
---

The connections of a TCP server as a coroutine: each resume returns `true` and the next accepted connection, and the coroutine ends when the server closes.

A resume waits for a connection as [`accept`](/manual/api#tcp_server:accept) does, and returns its socket. When the server is closed, also while a resume waits, the resume returns `true` alone and the coroutine is dead, so a [loop over the coroutine](/manual/guide#looping-over-a-coroutine) serves connections until the program closes the server. A failure of the system call makes the resume return `false` and the error that `accept` raises. One coroutine accepts through `server.accepted` at a time. Every access returns the same coroutine. The field needs no permission beyond the `network:server` permission that binding the server took.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local host, port = server:getsockname()
coroutine.detach(coroutine.create(function()
    for conn in server.accepted do
        coroutine.resume(conn.output, "welcome\n")
        conn:close()
    end
end))
for _ = 1, 2 do
    local sock <close> = network.tcp.connect(host, port)
    local _, line = coroutine.resume(sock.input)
    print(vector.tostring(line))
end
server:close()
--> welcome
--> welcome
```
