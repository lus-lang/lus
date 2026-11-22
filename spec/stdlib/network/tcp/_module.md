---
name: network.tcp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `network.tcp` table opens TCP connections with [`network.tcp.connect`](/manual/api#network.tcp.connect) and listens for them with [`network.tcp.bind`](/manual/api#network.tcp.bind).

A TCP socket has the methods `send(data, i, j)`, `receive(pattern, max_bytes)`, `settimeout(seconds)`, `getsockname()`, `getpeername()`, `starttls(options)`, `tlsinfo()`, `reader(max_bytes)`, and `close()`. [`network.tls`](/manual/api#network.tls) describes the sockets that carry TLS. A server has the methods `accept()`, `settimeout(seconds)`, `getsockname()`, and `close()`, and `accept` returns a socket. A method other than `close` on a closed socket raises `"attempt to use a closed socket"`, and on a closed server `"attempt to use a closed server"`. A second `close` does nothing. The collector closes a socket or a server that nothing refers to any more, and one declared with the `<close>` attribute closes when its variable goes out of scope.

`connect`, `accept`, `send`, and `receive` wait for the network. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and the other detached coroutines run in the meantime. Anywhere else they block their caller and run the detached coroutines while they wait. A timeout set with `settimeout` bounds each wait in both cases. `settimeout(nil)` and a negative value remove the timeout, and `settimeout(0)` makes an operation that cannot finish at once fail at once, and an operation whose timeout runs out raises `"receive timeout"`, `"send timeout"`, or `"accept timeout"` and leaves the socket usable.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
server:settimeout(0.05)
local ok, err = catch server:accept()
print(ok, err:match("accept timeout"))   --> false  accept timeout
```
