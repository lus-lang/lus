---
name: "tcp_socket:receive"
module: network.tcp
kind: function
since: 0.1.0
stability: stable
origin: lus
receiver: tcp_socket
params:
  - name: pattern
    type: integer|string
    optional: true
  - name: max_bytes
    type: integer
    optional: true
returns: vector
---

Receives data from a TCP socket according to `pattern` and returns it as a vector.

`pattern` defaults to `"*l"`, which reads one line and removes its trailing LF and an optional CR before it. `"*a"` reads everything up to the end of the connection. A positive integer reads exactly that many bytes, or the bytes that remain when the connection ends first, and it may be at most 1 MiB. `max_bytes` is an optional positive integer that sets the limit of `"*l"` and `"*a"`, which defaults to 1 MiB for a line and 64 MiB for `"*a"`.

On success the call returns one vector. At the end of the connection every pattern returns the bytes that remain, which is an empty vector once nothing remains. A failure of the connection itself, such as a reset by the other end, returns `nil` and a message such as `"receive: Connection reset by peer"`. An integer that is zero, negative, or over 1 MiB raises `"invalid receive size: N"`, and any other pattern raises `"invalid receive pattern: PATTERN"`. A `max_bytes` that is not positive raises a `bad argument` error. A line or a stream that exceeds its limit closes the socket and raises `"receive limit exceeded"`. A closed socket raises `"attempt to use a closed socket"`, and a timeout set with `settimeout` that runs out raises `"receive timeout"`. The method needs no permission.

The following example reads one message with each pattern after the sender has closed its end.

```lus
pledge("network")
local server <close> = network.tcp.bind("127.0.0.1", 0)
local client = network.tcp.connect(server:getsockname())
local conn <close> = server:accept()
client:send("first\r\nsecond\nrest")
client:close()
print(vector.tostring(conn:receive()))       --> first
print(vector.tostring(conn:receive(3)))      --> sec
print(vector.tostring(conn:receive()))       --> ond
print(vector.tostring(conn:receive("*a")))   --> rest
print(#conn:receive("*l"))                   --> 0
```

`receive` waits for data, as described in [`network.tcp`](/manual/api#network.tcp). [`vector.tostring`](/manual/api#vector.tostring) turns the received bytes into a string.
