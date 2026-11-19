---
name: "udp_socket:receive"
module: network.udp
kind: function
since: 0.1.0
stability: stable
origin: lus
receiver: udp_socket
params:
  - name: size
    type: integer
    optional: true
returns:
  - name: data
    type: string
  - name: address
    type: string
  - name: port
    type: integer
---

Receives one datagram and returns its data together with the sender's numeric address and port. `size` defaults to 8 KiB and accepts values through 1 MiB.
