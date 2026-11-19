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

Opens a UDP socket, optionally bound to `port` and `address`. Port `0` lets the operating system select an available port when an address is supplied. Returns a socket for sending and receiving datagrams.
