---
name: network.tcp.connect
module: network
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

Connects to a TCP server at `host` and `port`. Returns a TCP socket for reading and writing.
