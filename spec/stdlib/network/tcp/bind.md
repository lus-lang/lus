---
name: network.tcp.bind
module: network.tcp
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

Binds a listening TCP server to `host` and `port` and returns the server.

`host` is a host name or a numeric address, and the server listens on the first address it resolves to. `port` is an integer from 0 through 65535, and port `0` lets the operating system choose a free port. `backlog` is the number of connections the system queues before `accept` takes them, and defaults to 128.

On success the call returns one server with the methods `accept`, `settimeout`, `getsockname`, and `close`. `accept()` waits for the next connection and returns a TCP socket. Every failure raises an error. A port out of range raises `bad argument #2 to 'bind' (port out of range)`, a name that does not resolve raises `"cannot resolve 'HOST': REASON"`, and an address that cannot be bound raises `"cannot bind to HOST:PORT: REASON"`. The call requires `network:tcp` for `host:port`.

The following example binds a port that the system chooses, accepts one connection, and reads a line from it.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local address, port = server:getsockname()
local client <close> = network.tcp.connect(address, port)
local conn <close> = server:accept()
client:send("ping\n")
print(vector.tostring(conn:receive()))   --> ping
```

[`tcp_server:getsockname`](/manual/api#tcp_server:getsockname) reports the chosen port, and [`network.serve`](/manual/api#network.serve) serves HTTP on a bound server.
