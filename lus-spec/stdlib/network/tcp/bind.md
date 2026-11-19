---
name: network.tcp.bind
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
  - name: backlog
    type: integer
    optional: true
returns: tcp_server
---

Binds a TCP server to `host` and `port` with an optional accept `backlog`. Port `0` lets the operating system select an available port. Returns a server that can accept incoming connections and report its effective address through `getsockname`.
