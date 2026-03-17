---
name: network.udp.open
module: network
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: port
    type: integer
    optional: true
  - name: address
    type: string
    optional: true
returns: userdata
---

Opens a UDP socket, optionally bound to `port` and `address`. Returns a socket object for sending and receiving datagrams. Requires `network` pledge.
