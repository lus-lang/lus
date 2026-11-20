---
name: network.tcp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---

The `network.tcp` sub-module.

`connect`, `accept`, `send`, and `receive` wait for the network. Inside a coroutine given to `coroutine.detach` each of them suspends the coroutine until its socket is ready, and the other detached coroutines run in the meantime. Anywhere else they block their caller and run the detached coroutines while they wait. A timeout set with `settimeout` bounds each wait in both cases.
