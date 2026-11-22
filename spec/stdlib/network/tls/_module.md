---
name: network.tls
module: network
kind: module
since: 2.0.0
stability: stable
origin: lus
---

The `network.tls` table opens TLS connections with [`network.tls.connect`](/manual/api#network.tls.connect). A plain TCP socket starts TLS with [`tcp_socket:starttls`](/manual/api#tcp_socket:starttls), as the client or as the server, and [`network.serve`](/manual/api#network.serve) serves HTTPS with its `tls` option.

A _TLS socket_ is a TCP socket whose bytes travel through TLS 1.2 or TLS 1.3. It has every method of a TCP socket, and `send` and `receive` carry plain text while the bytes on the wire are encrypted. [`tcp_socket:tlsinfo`](/manual/api#tcp_socket:tlsinfo) reports the protocol version, the cipher suite, and the protocol that ALPN chose. Closing a TLS socket sends a TLS `close_notify` alert to the peer before the TCP connection closes. A peer that ends the TCP connection without that alert ends the stream like one that sends it, so `receive("*a")` returns what arrived.

The handshake, `send`, and `receive` wait for the network as the operations of a TCP socket do. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and the other detached coroutines run in the meantime. Anywhere else they block their caller and run the detached coroutines while they wait. A timeout set with `settimeout` bounds each wait.

A client verifies the certificate of the server by default. The certificate must chain to a trusted certificate authority and must name the server: `servername` must match one of its DNS names or, when the certificate lists none, its common name. The trusted authorities are the certificates of the system, which load once per process on the first connection that needs them, or the authorities of the `ca` option.

The options of a client connection form a table with any of these fields:

| Field | Value |
| --- | --- |
| `servername` | The name that the client sends in SNI and checks the certificate against. It defaults to the host of `network.tls.connect`. |
| `alpn` | A list of between 1 and 16 protocol names, such as `{ "h2", "http/1.1" }`, that the client offers through ALPN. |
| `ca` | PEM text of the certificate authorities to trust in place of those of the system. |
| `cert`, `key` | PEM text of a client certificate chain and of its private key, which the client presents when the server asks for one. Each needs the other. |
| `password` | The password of an encrypted private key. |
| `verify` | `false` to accept any certificate of the server. It defaults to `true`. |
| `timeout` | Seconds for `network.tls.connect`: the connection to every address of the host must end within it, each wait of the handshake lasts at most that long, and the socket keeps it as its timeout. |

PEM text is a string or a vector. A program reads a certificate file with `io.open`, which needs `fs:read` for the file. An unknown field raises `"bad argument #N to 'connect' (unknown option 'NAME')"`, and a field of the wrong type raises a `bad argument` error that names it. A `ca` that holds no certificate raises an error that says so, and a `cert` or `key` that does not parse raises `"invalid certificate"` or `"invalid private key"` with the reason.

A handshake that fails raises an error and closes the socket. A certificate that does not verify raises `"certificate verification failed for NAME: REASON"`, such as `"certificate verification failed for example.com: The certificate is not correctly signed by the trusted CA"`. Any other failure raises `"TLS handshake failed: REASON"`, and a handshake whose timeout runs out raises `"TLS handshake timeout"`. A failure of the TLS layer after the handshake makes `send` and `receive` return `nil` and a message that starts with `"TLS: "`.

The WebAssembly build has no network library, so `network.tls` is absent there.

```lus nocheck
pledge("network")
local sock <close> = network.tls.connect("example.com", 443, { alpn = { "http/1.1" } })
sock:send("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
print(sock:tlsinfo().version)                       --> TLSv1.3
print(vector.tostring(sock:receive("*l")))          --> HTTP/1.1 200 OK
```
