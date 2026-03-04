---
name: network.tcp.bind
module: network
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: host
    type: string
  - name: port
    type: integer
returns: userdata
---

Binds a TCP server to `host` and `port`. Returns a server object that can accept incoming connections. Requires `network` pledge.
