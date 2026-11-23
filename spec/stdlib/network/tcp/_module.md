---
name: network.tcp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `network.tcp` table opens TCP connections with [`network.tcp.connect`](/manual/api#network.tcp.connect) and listens for them with [`network.tcp.bind`](/manual/api#network.tcp.bind).

A TCP socket has the methods `send(data, i, j)`, `receive(pattern, max_bytes)`, `settimeout(seconds)`, `getsockname()`, `getpeername()`, `starttls(options)`, `tlsinfo()`, `reader(max_bytes)`, and `close()`. [`network.tls`](/manual/api#network.tls) describes the sockets that carry TLS. A server has the methods `accept()`, `settimeout(seconds)`, `getsockname()`, and `close()`, and `accept` returns a socket. A socket also has two coroutines, [`input`](/manual/api#tcp_socket.input), whose resumes read, and [`output`](/manual/api#tcp_socket.output), whose resumes send, and a server has [`accepted`](/manual/api#tcp_server.accepted), whose resumes accept. A method other than `close` on a closed socket raises `"attempt to use a closed socket"`, and on a closed server `"attempt to use a closed server"`. A second `close` does nothing. The collector closes a socket or a server that nothing refers to any more, and one declared with the `<close>` attribute closes when its variable goes out of scope.

`connect`, `accept`, `send`, and `receive` wait for the network. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and the other detached coroutines run in the meantime. Anywhere else they block their caller and run the detached coroutines while they wait. A timeout set with `settimeout` bounds each wait in both cases. `settimeout(nil)` and a negative value remove the timeout, and `settimeout(0)` makes an operation that cannot finish at once fail at once. An operation whose timeout runs out fails with the code `"timeout"` and the message `"receive timeout"`, `"send timeout"`, or `"accept timeout"`, and leaves the socket usable.

Socket operations report failures as file operations do. A failed operation returns `nil` and an _error object_, a table with the fields `code` and `message`, and `status` where an HTTP status applies. Its `__tostring` gives the message, so printing it or concatenating it with `tostring` reads like the message of a file operation. The code says what failed:

| Code | Failure |
| --- | --- |
| `"timeout"` | A timeout ran out. |
| `"refused"` | The peer refused the connection. |
| `"reset"` | The peer reset or aborted the connection. |
| `"closed"` | The connection ended while the operation needed it. |
| `"unreachable"` | No route leads to the host. |
| `"resolve"` | The name of the host does not resolve. |
| `"address"` | The address is in use or cannot be assigned. |
| `"denied"` | The system denied the operation. |
| `"limit"` | A received line or stream went over its limit. |
| `"tls"` | The TLS handshake or the TLS layer failed. |
| `"certificate"` | The certificate of the peer did not verify. |
| `"protocol"` | An HTTP response broke the protocol, such as a malformed status line or `Content-Length`, or a body that broke its framing. |
| `"too_large"` | An HTTP body or head went over its limit: a response body of `network.fetch` over 64 MiB, or a request body that `network.serve` refuses with 413 or 431. |
| `"malformed"` | A request body broke its framing, which `network.serve` refuses with 400. |
| `"io"` | Any other failure of the system. |

Misuse raises rather than returns: a bad argument, a socket that the program closed before the call, and a permission that the program lacks. The coroutines `input`, `output`, and `accepted`, and a coroutine of [`tcp_socket:reader`](/manual/api#tcp_socket:reader), raise their error object, so the resume returns `false` and the object, as for any coroutine.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
server:settimeout(0.05)
local sock, err = server:accept()
print(sock, err.code, tostring(err))   --> nil  timeout  accept timeout
```
