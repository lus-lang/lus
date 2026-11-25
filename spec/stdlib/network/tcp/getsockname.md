---
name: "tcp_server:getsockname"
module: network.tcp
kind: function
since: 1.7.0
stability: unstable
origin: lus
receiver: tcp_server
returns:
  - name: address
    type: string
  - name: port
    type: integer
---

Returns the numeric address and the port that the server is bound to.

The method takes no arguments and needs no permission. It returns two values, the address as a string such as `"127.0.0.1"` and the port as an integer. After a bind to port `0` the port is the one that the operating system chose. On a closed server the call raises `"attempt to use a closed server"`.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local address, port = server:getsockname()
print(address, math.type(port), port > 0)  --> 127.0.0.1  integer  true
```

A connected socket has `getsockname` for its own end and `getpeername` for the other end. [`network.tcp.bind`](/manual/api#network.tcp.bind) binds a server.
