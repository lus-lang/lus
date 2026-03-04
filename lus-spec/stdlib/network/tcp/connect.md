---
name: network.tcp.connect
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

Connects to a TCP server at `host` and `port`. Returns a connection object for reading and writing. Requires `network` pledge.
