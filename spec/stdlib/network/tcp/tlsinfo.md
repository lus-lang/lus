---
name: "tcp_socket:tlsinfo"
module: network.tcp
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_socket
returns: table|nil
---

Returns what the TLS handshake of a socket settled, or `nil` for a socket without TLS.

The table has these fields. `version` is the protocol version, `"TLSv1.2"` or `"TLSv1.3"`. `cipher` is the name of the cipher suite, such as `"TLS1-3-AES-128-GCM-SHA256"`. `alpn` is the protocol that ALPN chose, or absent when the peers chose none. `servername` is the name that a client checked the certificate against, or the name that the client of a server asked for through SNI, or absent when there is none. A socket of `network.serve` before its first request has `servername` alone, since its handshake runs inside the first read. The method needs no permission.

```lus nocheck
pledge("network")
local sock <close> = network.tls.connect("example.com", 443)
local info = sock:tlsinfo()
print(info.version, info.servername)   --> TLSv1.3  example.com
local plain <close> = network.tcp.connect("example.com", 80)
print(plain:tlsinfo())                 --> nil
```
