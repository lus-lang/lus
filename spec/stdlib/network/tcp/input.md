---
name: "tcp_socket.input"
module: network.tcp
kind: variable
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_socket
type: thread
---

The input of a TCP socket as a coroutine: each resume returns `true` and the next piece of input, and the coroutine ends at the end of the connection.

The arguments of a resume are the read request, with the patterns of [`receive`](/manual/api#tcp_socket:receive): `coroutine.resume(conn.input)` reads a line, `coroutine.resume(conn.input, "*l", 1024)` reads a line of at most 1024 bytes, `coroutine.resume(conn.input, 512)` reads 512 bytes, and `coroutine.resume(conn.input, "*a")` reads everything up to the end of the connection. Each piece is a vector. An empty line is an empty vector. When the connection ends with nothing left to read, the resume returns `true` alone and the coroutine is dead, so a [loop over the coroutine](/manual/guide#looping-over-a-coroutine) reads every line until the peer closes its end.

A failure makes the resume return `false` and the error that `receive` raises, and the coroutine stays usable. One coroutine reads through `conn.input` at a time: a resume while another coroutine waits inside it returns `false` and `"cannot resume non-suspended coroutine"`. The coroutine waits as `receive` does, and the timeout of the socket bounds each read. A resume reads the data that has already arrived without a switch to another coroutine. Every access returns the same coroutine. Closing it stops the reads and leaves the socket open. The field needs no permission.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local client = network.tcp.connect(server:getsockname())
local conn <close> = server:accept()
client:send("first\n\nthird\n")
client:close()
for line in conn.input do
    print(#line, vector.tostring(line))
end
--> 5  first
--> 0
--> 5  third
print(coroutine.status(conn.input))   --> dead
```
