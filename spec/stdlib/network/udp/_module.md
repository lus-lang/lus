---
name: network.udp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `network.udp` table opens UDP sockets with [`network.udp.open`](/manual/api#network.udp.open) for sending and receiving datagrams.

A UDP socket has the methods `sendto(data, address, port)`, `receive(size)`, `setsockname(address, port)`, `getsockname()`, `settimeout(seconds)`, and `close()`. `sendto` sends one datagram of a string or a vector and returns the number of bytes sent, and it checks `network:udp` for every destination. `setsockname` binds a socket that is not bound yet and returns nothing, and on a bound socket it returns `nil` and an error message. A method other than `close` on a closed socket raises `"attempt to use a closed UDP socket"`.

`receive` and `sendto` wait for the network. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and anywhere else they block their caller and run the detached coroutines while they wait. A timeout set with `settimeout` bounds each wait, and an operation whose timeout runs out raises `"receive timeout"` or `"sendto timeout"` and leaves the socket usable.

```lus
pledge("network")
local sock <close> = network.udp.open(0, "127.0.0.1")
sock:settimeout(0.05)
local ok, err = catch sock:receive()
print(ok, err:match("receive timeout"))   --> false  receive timeout
```
