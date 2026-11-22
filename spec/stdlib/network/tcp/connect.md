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
  - name: options
    type: table
    optional: true
returns: tcp_socket
---

Opens a TCP connection to `host` and `port` and returns the connected socket.

`host` is a host name or a numeric address. `port` is an integer from 1 through 65535. `options` is a table whose one field, `timeout`, is a number of seconds. The call waits until the connection is established, as described in [`network.tcp`](/manual/api#network.tcp). With `timeout`, the connection must be established within that time, which counts the attempts at every address of the host, and the socket then keeps `timeout` as the timeout of its operations, as `settimeout` sets it. A negative `timeout` waits without limit.

On success the call returns one socket with the methods `send`, `receive`, `settimeout`, `getsockname`, `getpeername`, `starttls`, `tlsinfo`, `reader`, and `close`. `send(data, i, j)` sends a string or a vector in full and returns the position of its last element, which for a string is its number of characters and for a vector its number of bytes. With `i` and `j` it sends the part from position `i` to position `j`, which count characters of a string and bytes of a vector as `string.sub` counts them, and returns `j` as `string.sub` clips it, or 0 for an empty part. A failure to connect returns `nil` and an error object (see [`network.tcp`](/manual/api#network.tcp)), such as one with the code `"refused"` and the message `"cannot connect to 127.0.0.1:1: Connection refused"`, or the code `"resolve"` and the message `"cannot resolve 'HOST': Domain name not found"`. A connection that runs out of time has the code `"timeout"` and the message `"timeout while connecting to HOST:PORT"`. A port out of range, an unknown option, and a `timeout` that is not a number raise a `bad argument` error. The call requires `network:tcp` for `host:port`.

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

A failure of an open connection during `send` or `receive`, such as a reset by the other end, returns `nil` and an error object with the code `"reset"` and a message such as `"receive: Connection reset by peer"`. [`tcp_socket:receive`](/manual/api#tcp_socket:receive) reads from the socket.
