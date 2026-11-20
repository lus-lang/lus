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

Serves HTTP/1.1 on `host` and `port` and calls `handler` for every request. `serve` blocks its caller for as long as the server runs. It accepts connections in a loop, and each connection runs in a coroutine of its own that the runtime resumes whenever its socket is ready (see `coroutine.detach`), so a slow client never holds up the others. Connections stay open between requests unless the client asks to close them.

The handler receives one table per request:

| Field | Value |
| --- | --- |
| `method` | The request method, such as `"GET"`. |
| `path` | The request target up to the first `?`, as the client sent it. |
| `query` | The text after the first `?`, or the empty string. |
| `headers` | A table from lowercase header names to their values. A header that repeats joins its values with `", "`. |
| `body` | The request body as a vector, which is empty for a request without a body. |

The handler returns `status, body, headers`, in the order in which `network.fetch` returns them. `status` is an integer and defaults to 200. `body` is a string or a vector and defaults to an empty body. `headers` is a table from header names to strings or integers. The server adds `Date`, `Content-Length`, and `Connection: close` when the handler does not set them. A handler may suspend: socket operations and `coroutine.yield` inside it let the other connections run.

When the handler raises an error, or returns values that make no response, the server answers 500, reports the error, and closes the connection. It writes the error to standard error, in the form `lus: network.serve: message`, or passes the error value to the `on_error` function of the options.

`options` is a table with any of these fields:

| Field | Value |
| --- | --- |
| `idle_timeout` | How many seconds a connection may spend without progress, which defaults to 60. A negative value lets a connection wait without limit. |
| `max_connections` | How many connections the server keeps open at once. It defaults to half of the file descriptors that the process may open, and to 65536 at most. |
| `on_error` | A function that receives the error of a handler in place of the line on standard error. |

A connection makes progress when the server reads a part of a request from it or writes a part of a response to it. A connection that stays idle for `idle_timeout` between two requests closes. One that stops in the middle of a request is answered with 408 and closes, and one that stops reading its response closes as well. A handler may take as long as it needs.

While `max_connections` connections are open, further clients wait in the queue of the system, and the server accepts the next one when a connection closes. When the system has no file descriptor or no memory left for a new connection, the server waits for a connection to close, or for a moment, and accepts again.

The server reads request bodies with a `Content-Length` and bodies with `Transfer-Encoding: chunked`, answers `Expect: 100-continue`, and leaves the body out of the response to a `HEAD` request. The request line and the headers of a request are limited to 64 KiB and 128 header lines, and a request body to 16 MiB. A chunked body gives each chunk size as hexadecimal digits alone, and the line that starts a chunk is limited to 1 KiB. The framing of a chunked body, which is its chunk lines and its trailers, is limited to 64 KiB plus 8 bytes for every byte of the body. A request over a limit is answered with 431 or 413, and a malformed request with 400. The connection closes after each of these answers.

`network.serve(server, handler, options)` serves on a server that `network.tcp.bind` returned. That form lets a program bind port `0` and read the selected port with `getsockname` before it serves. A server that `serve` bound itself closes when `serve` ends, which happens when the coroutine that called it is closed or when accepting a connection fails for a reason other than a shortage of descriptors or memory.

Requires the `network:server` permission for the address, and `network:tcp` to bind it.

```lus nocheck
pledge("network")

network.serve("127.0.0.1", 8080, function(req)
    if req.path ~= "/" then
        return 404, "not found\n"
    end
    return 200, "hello\n", { ["Content-Type"] = "text/plain" }
end)
```
