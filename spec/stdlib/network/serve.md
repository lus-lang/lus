---
name: network.serve
module: network
kind: function
since: 2.0.0
stability: stable
pledges: ["network:server", "network:tcp"]
origin: lus
params:
  - name: host
    type: string
  - name: port
    type: integer
  - name: handler
    type: function
  - name: options
    type: table
    optional: true
---

Serves HTTP/1.1 on `host` and `port`, calls `handler` for every request, and returns only when the server stops.

`host` is a string and `port` an integer that name the address to listen on. `handler` is a function that receives one table per request and returns the response. `options` is an optional table described below. The second form, `network.serve(server, handler, options)`, serves on a server that [`network.tcp.bind`](/manual/api#network.tcp.bind) returned, which lets a program bind port `0` and read the chosen port with `getsockname` before it serves.

`serve` blocks its caller for as long as the server runs and returns no values. It accepts connections in a loop, and each connection runs in a coroutine of its own that the runtime resumes whenever its socket is ready (see `coroutine.detach`), so a slow client never holds up the others. Connections stay open between requests unless the client asks to close them. A server that `serve` bound itself closes when `serve` ends, and a server passed to it stays open until the program closes it. `serve` ends when the coroutine that called it is closed, or when accepting a connection fails for a reason other than a shortage of file descriptors or memory.

Closing the coroutine that runs `serve` stops the server gracefully. `serve` stops accepting, and a server it bound itself closes at once. A connection that waits between two requests closes at once, and a connection in the middle of a request finishes it, with a response that carries `Connection: close`, then closes. A connection still open when `drain_timeout` has passed is closed, together with a response that was not sent yet. A handler that still runs at that point continues, and its response is dropped. The program keeps running while connections drain, because each connection runs in a detached coroutine of its own.

The call requires the `network:server` permission for the address it serves, and in the first form `network:tcp` to bind it. A failure to bind raises an error such as `"cannot bind to HOST:PORT: REASON"`.

The handler receives one table per request:

| Field | Value |
| --- | --- |
| `method` | The request method, such as `"GET"`. |
| `path` | The request target up to the first `?`, as the client sent it. |
| `query` | The text after the first `?`, or the empty string. |
| `headers` | A table from lowercase header names to their values. A header that repeats joins its values with `", "`. |
| `body` | The request body as a vector, which is empty for a request without a body. |

The handler returns `status, body, headers`, in the order in which `network.fetch` returns them. `status` is an integer and defaults to 200. `body` is a string or a vector and defaults to an empty body. `headers` is a table from header names to strings or integers. A header value may also be a list of strings and integers, which sends one header line for each element in order, so a response can set several cookies with `{ ["Set-Cookie"] = { "a=1", "b=2" } }`. An empty list sends no line. The server adds `Date`, `Content-Length`, and `Connection` when the handler does not set them. A handler may suspend: socket operations and `coroutine.yield` inside it let the other connections run.

When the handler raises an error, or returns values that make no response, such as a status that is not an integer, the server answers 500 with an empty body, reports the error, and closes that connection. The other connections continue. It writes the error to standard error, in the form `lus: network.serve: message`, or passes the error value to the `on_error` function of the options.

A handler upgrades the connection to another protocol, such as a WebSocket, by returning the status 101 and a function in place of the body. The server sends the 101 response with the headers of the handler and no body, then calls the function with the TCP socket of the connection, in the coroutine of the connection. Bytes that the client sent after the request are already in the buffer of the socket, so the first `receive` returns them. The connection closes when the function returns. When the function raises an error, the server reports it like an error of a handler and closes the connection without a further response. The socket keeps the `idle_timeout` of the server until the function calls `settimeout`. A function body with any other status, and the status 101 with any other body, count as values that make no response.

When the request carries a `Sec-WebSocket-Key` header, the server adds the headers of a WebSocket handshake that the handler does not set: `Upgrade: websocket`, `Connection: Upgrade`, and the `Sec-WebSocket-Accept` value that RFC 6455 derives from the key. The function then exchanges WebSocket frames over the socket. A handler that checks `req.headers.upgrade` before it upgrades refuses other requests with an ordinary status.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()
local serving = coroutine.detach(coroutine.create(network.serve), server, function(req)
    return 101, function(sock)
        sock:send("upgraded")
    end
end)
local sock <close> = network.tcp.connect("127.0.0.1", port)
sock:send("GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
local response = vector.tostring(sock:receive("*a"))
print(response:match("Sec%-WebSocket%-Accept: ([^\r]+)"))   --> s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
print(response:match("\r\n\r\n(.*)$"))                     --> upgraded
coroutine.close(serving)
server:close()
```

`options` is a table with any of these fields:

| Field | Value |
| --- | --- |
| `idle_timeout` | How many seconds a connection may spend without progress, which defaults to 60. A negative value lets a connection wait without limit. |
| `max_connections` | How many connections the server keeps open at once. It defaults to half of the file descriptors that the process may open, and to 65536 at most. |
| `on_error` | A function that receives the error of a handler in place of the line on standard error. |
| `drain_timeout` | How many seconds the open connections may take to finish after the coroutine of `serve` closed, which defaults to 10. A negative value lets them take as long as they need, and `0` closes them at once. |

A connection makes progress when the server reads a part of a request from it or writes a part of a response to it. A connection that stays idle for `idle_timeout` between two requests closes. One that stops in the middle of a request is answered with 408 and closes, and one that stops reading its response closes as well. A handler may take as long as it needs.

While `max_connections` connections are open, further clients wait in the queue of the system, and the server accepts the next one when a connection closes. When the system has no file descriptor or no memory left for a new connection, the server waits for a connection to close, or for a moment, and accepts again.

The server reads request bodies with a `Content-Length` and bodies with `Transfer-Encoding: chunked`, answers `Expect: 100-continue`, and leaves the body out of the response to a `HEAD` request. The request line and the headers of a request are limited to 64 KiB and 128 header lines, and a request body to 16 MiB. A chunked body gives each chunk size as hexadecimal digits alone, and the line that starts a chunk is limited to 1 KiB. The framing of a chunked body, which is its chunk lines and its trailers, is limited to 64 KiB plus 8 bytes for every byte of the body. A request over a limit is answered with 431 or 413, and a malformed request with 400. The connection closes after each of these answers.

The following example serves in a detached coroutine on a port that the system chooses, sends one request over a TCP socket, and stops the server.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()
local serving = coroutine.detach(coroutine.create(network.serve), server, function(req)
    return 200, `hello from $(req.path)`, { ["Content-Type"] = "text/plain" }
end)
local sock <close> = network.tcp.connect("127.0.0.1", port)
sock:send("GET /docs HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
local response = vector.tostring(sock:receive("*a"))
print(response:match("\r\n\r\n(.*)$"))   --> hello from /docs
coroutine.close(serving)
server:close()
```

The example talks to its server through a TCP socket because [`network.fetch`](/manual/api#network.fetch) blocks the whole state, the server coroutines included.
