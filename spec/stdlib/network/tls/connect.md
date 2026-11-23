---
name: network.tls.connect
module: network.tls
kind: function
since: 2.0.0
stability: stable
pledges: ["network:tcp"]
origin: lus
params:
  - name: host
    type: string
  - name: port
    type: integer
  - name: options
    type: table
    optional: true
returns: tcp_socket
---

Opens a TCP connection to `host` and `port`, runs a TLS handshake over it, and returns the TLS socket.

`host` is a host name or a numeric address, and `port` is an integer from 1 through 65535. `options` is the table of client options that [`network.tls`](/manual/api#network.tls) describes. The call connects as [`network.tcp.connect`](/manual/api#network.tcp.connect) does, then runs the handshake, and returns once the handshake ends. The `timeout` option bounds the connection as it bounds that of `network.tcp.connect`, then every wait of the handshake, and becomes the timeout of the socket. A connection that runs out of time fails with the code `"timeout"` and the message `"timeout while connecting to HOST:PORT"`.

On success the call returns one socket with the methods of a TCP socket and [`tlsinfo`](/manual/api#tcp_socket:tlsinfo). A failure to connect returns `nil` and the error object that `network.tcp.connect` returns, and a failed handshake closes the socket and returns `nil` and an error object that `network.tls` describes. A port out of range and an invalid option raise a `bad argument` error. The call requires `network:tcp` for `host:port`.

The following example connects to a server with a private certificate authority and asks for HTTP/1.1 through ALPN.

```lus nocheck
pledge("network", "fs:read=/etc/myapp/*")
local f <close> = io.open("/etc/myapp/ca.pem")
local sock <close> = network.tls.connect("db.internal", 5433, {
    ca = f:read("a"),
    alpn = { "http/1.1" },
    timeout = 5,
})
print(sock:tlsinfo().alpn)   --> http/1.1
```
