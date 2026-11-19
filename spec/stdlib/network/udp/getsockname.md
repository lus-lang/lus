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

Returns the UDP socket's local numeric address and port. Use it after binding to port `0` to learn the port selected by the operating system.
