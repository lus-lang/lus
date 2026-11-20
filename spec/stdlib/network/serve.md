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

When the handler raises an error, or returns values that make no response, the server answers 500, reports the error through `warn`, and closes the connection.

The server reads request bodies with a `Content-Length` and bodies with `Transfer-Encoding: chunked`, answers `Expect: 100-continue`, and leaves the body out of the response to a `HEAD` request. The request line and the headers of a request are limited to 64 KiB and 128 header lines, and a request body to 16 MiB. A request over a limit is answered with 431 or 413, and a malformed request with 400. The connection closes after each of these answers.

`network.serve(server, handler)` serves on a server that `network.tcp.bind` returned. That form lets a program bind port `0` and read the selected port with `getsockname` before it serves. A server that `serve` bound itself closes when `serve` ends, which happens when the coroutine that called it is closed or when accepting a connection fails.

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
