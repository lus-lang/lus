---
name: network.udp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `network.udp` sub-module.

`receive` and `sendto` wait for the network. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and anywhere else they block their caller and run the detached coroutines while they wait.
