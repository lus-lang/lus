---
name: "tcp_socket:receive"
module: network.tcp
kind: function
since: 0.1.0
stability: stable
origin: lus
receiver: tcp_socket
params:
  - name: pattern
    type: integer|string
    optional: true
  - name: max_bytes
    type: integer
    optional: true
returns: vector
---

Receives data from a TCP socket and returns it as a vector. A positive integer pattern reads that many bytes, with a maximum size of 1 MiB. The default pattern is `"*l"`, which reads a line and removes its trailing LF and optional CR. `"*a"` reads through EOF.

The optional positive `max_bytes` applies to `"*l"` and `"*a"`. Lines default to a 1 MiB limit and all-data reads default to 64 MiB. Exceeding either limit closes the socket and raises `"receive limit exceeded"`.
