---
name: "tcp_socket.output"
module: network.tcp
kind: variable
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_socket
type: thread
---

The output of a TCP socket as a coroutine: `coroutine.resume(conn.output, data)` sends all of `data`, a string or a vector, and returns `true`.

A failure makes the resume return `false` and the error that [`send`](/manual/api#tcp_socket:send) raises, and the coroutine stays usable. `data` of another type makes the resume return `false` and a `bad argument` message. One coroutine writes through `conn.output` at a time, as with [`conn.input`](/manual/api#tcp_socket.input). The coroutine waits as `send` does, and the timeout of the socket bounds the send. Closing the coroutine with [`coroutine.close`](/manual/api#coroutine.close) ends the sending side of the connection, so the peer reads the end of its input, while this side can still read. Every access returns the same coroutine. The field needs no permission.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local client <close> = network.tcp.connect(server:getsockname())
local conn <close> = server:accept()
coroutine.resume(conn.output, "hello\n")
coroutine.close(conn.output)
for line in client.input do
    print(vector.tostring(line))
end
--> hello
```
