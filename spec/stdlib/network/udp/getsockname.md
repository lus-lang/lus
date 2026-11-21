---
name: "udp_socket:getsockname"
module: network.udp
kind: function
since: 1.7.0
stability: unstable
origin: lus
receiver: udp_socket
returns:
  - name: address
    type: string
  - name: port
    type: integer
---

Returns the local numeric address and port of the UDP socket.

The method takes no arguments and needs no permission. It returns two values, the address as a string and the port as an integer. After a bind to port `0` the port is the one that the operating system chose. A socket opened without an address reports `"0.0.0.0"`. On a closed socket the call raises `"attempt to use a closed UDP socket"`.

```lus
pledge("network")
local sock <close> = network.udp.open(0, "127.0.0.1")
local address, port = sock:getsockname()
print(address, math.type(port), port > 0)   --> 127.0.0.1  integer  true
```

[`network.udp.open`](/manual/api#network.udp.open) creates and binds the socket.
