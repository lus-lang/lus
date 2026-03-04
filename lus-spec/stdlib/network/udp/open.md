---
name: network.udp.open
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

Opens a UDP socket bound to `host` and `port`. Returns a socket object for sending and receiving datagrams. Requires `network` pledge.
