---
name: "tcp_socket:reader"
module: network.tcp
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_socket
params:
  - name: max_bytes
    type: integer
    optional: true
returns: thread
---

Returns a coroutine that reads the socket: each resume yields what has arrived, and the coroutine ends at the end of the stream.

`max_bytes` is a positive integer that limits each part and defaults to 65536. Each resume returns `true` and a vector of between 1 and `max_bytes` bytes as soon as the socket holds any, so a relay moves bytes as they come rather than one at a time. When the peer ends the stream, the resume returns `true` alone and the coroutine is dead. A TLS socket yields plain text. The coroutine waits as `receive` does: inside a detached coroutine the wait suspends, anywhere else it runs the detached coroutines, and the timeout of the socket bounds it. A failure makes the resume return `false` and the error object of the failure (see [`network.tcp`](/manual/api#network.tcp)): a wait that runs out has the code `"timeout"` and the message `"receive timeout"`, and a failure of the connection has a code such as `"reset"` and a message such as `"receive: Connection reset by peer"`. A socket that the program closed makes the resume return `false` and `"attempt to use a closed socket"`. Closing the coroutine leaves the socket open. A `max_bytes` that is not positive raises a `bad argument` error. The method needs no permission.

The coroutine has the shape of the streamed bodies of the network library, so [`network.lines`](/manual/api#network.lines) reads it line by line, a handler of [`network.serve`](/manual/api#network.serve) may return it as a body, and [`network.fetch`](/manual/api#network.fetch) sends it as a request body.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()
local writer = coroutine.detach(coroutine.create(function()
    local conn <close> = server:accept()
    conn:send("+OK one\r\n+OK two\r\n")
end))
local sock <close> = network.tcp.connect("127.0.0.1", port)
for line in network.lines(sock:reader()) do
    print(vector.tostring(line))
end
--> +OK one
--> +OK two
```
