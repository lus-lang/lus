---
name: network.tcp.connect
module: network.tcp
kind: function
since: 0.1.0
stability: stable
pledges: ["network:tcp"]
origin: lus
params:
  - name: host
    type: string
  - name: port
    type: integer
returns: tcp_socket
---

Opens a TCP connection to `host` and `port` and returns the connected socket.

`host` is a host name or a numeric address. `port` is an integer from 1 through 65535. The call waits until the connection is established, as described in [`network.tcp`](/manual/api#network.tcp).

On success the call returns one socket with the methods `send`, `receive`, `settimeout`, `getsockname`, `getpeername`, and `close`. `send(data)` sends a string or a vector in full and returns the number of bytes sent. Every failure to connect raises an error, such as `"cannot connect to 127.0.0.1:1: Connection refused"` or `"cannot resolve 'HOST': Domain name not found"`. A port out of range raises a `bad argument` error. The call requires `network:tcp` for `host:port`.

The following example connects to a local server and reads the addresses of both ends.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()
local sock <close> = network.tcp.connect("127.0.0.1", port)
local peer_address, peer_port = sock:getpeername()
print(peer_address, peer_port == port)   --> 127.0.0.1  true
print(sock:send("hello"))                --> 5
```

A failure of an open connection during `send` or `receive`, such as a reset by the other end, returns `nil` and a message such as `"receive: Connection reset by peer"`. [`tcp_socket:receive`](/manual/api#tcp_socket:receive) reads from the socket.
