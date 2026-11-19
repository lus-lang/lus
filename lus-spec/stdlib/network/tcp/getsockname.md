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

Returns the server's bound numeric address and port. Use it after binding to port `0` to learn the port selected by the operating system.
