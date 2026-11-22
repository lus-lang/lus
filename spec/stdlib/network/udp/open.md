---
name: network.udp.open
module: network.udp
kind: function
since: 0.1.0
stability: stable
pledges: ["network:udp"]
origin: lus
params:
  - name: port
    type: integer
    optional: true
  - name: address
    type: string
    optional: true
returns: udp_socket
---

Creates a UDP socket, bound to a local address and port when they are given, and returns the socket.

`port` is an optional integer from 0 through 65535 that defaults to `0`. `address` is an optional numeric IPv4 address that defaults to `"0.0.0.0"`, and a host name raises `"invalid address: NAME"`. With an `address`, or with a `port` other than `0`, the socket is bound to that address and port at once, and port `0` then lets the operating system choose a free port. Without either, the socket sends from a port that the system chooses, and `setsockname` may bind it once later.

On success the call returns one socket. A failure returns `nil` and an error object (see [`network.tcp`](/manual/api#network.tcp)) with a message such as `"cannot bind UDP socket: REASON"`. A bound socket requires `network:udp` for `address:port`, and an unbound socket requires any grant of `network:udp`, including one limited to other hosts.

The following example opens a receiving socket on a chosen port and a sending socket without a binding, and passes one datagram between them.

```lus
pledge("network")
local receiver <close> = network.udp.open(0, "127.0.0.1")
local _, port = receiver:getsockname()
local sender <close> = network.udp.open()
print(sender:sendto("hello", "127.0.0.1", port))   --> 5
local data, address = receiver:receive()
print(vector.tostring(data), address)              --> hello  127.0.0.1
```

`sendto` accepts a host name as its destination. [`udp_socket:receive`](/manual/api#udp_socket:receive) waits for a datagram, and [`udp_socket:getsockname`](/manual/api#udp_socket:getsockname) reports the local port.
