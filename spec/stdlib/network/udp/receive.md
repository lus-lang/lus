---
name: "udp_socket:receive"
module: network.udp
kind: function
since: 0.1.0
stability: stable
origin: lus
receiver: udp_socket
params:
  - name: size
    type: integer
    optional: true
returns:
  - name: data
    type: vector
  - name: address
    type: string
  - name: port
    type: integer
---

Waits for one datagram and returns its data as a vector, together with the numeric address and the port of the sender.

`size` is an optional integer from 1 through 1048576 (1 MiB) that defaults to 8192 (8 KiB). The call returns at most `size` bytes of the datagram and discards the rest of it. Any other size raises `"invalid receive size: N"`.

On success the call returns three values: the data as a vector, the address of the sender as a string, and its port as an integer. A failure of the socket returns `nil` and an error object (see [`network.tcp`](/manual/api#network.tcp)), and a timeout set with `settimeout` that runs out has the code `"timeout"` and the message `"receive timeout"`. A socket that the program closed raises `"attempt to use a closed UDP socket"`. The method needs no permission.

The following example receives the first 5 bytes of a longer datagram.

```lus
pledge("network")
local receiver <close> = network.udp.open(0, "127.0.0.1")
local sender <close> = network.udp.open()
local _, port = receiver:getsockname()
sender:sendto("hello world", "127.0.0.1", port)
local data, address, from_port = receiver:receive(5)
print(vector.tostring(data), address)   --> hello  127.0.0.1
print(from_port == select(2, sender:getsockname()))   --> true
```

`receive` waits as described in [`network.udp`](/manual/api#network.udp). [`vector.tostring`](/manual/api#vector.tostring) turns the received bytes into a string.
