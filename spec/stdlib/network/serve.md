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
| `ip` | The numeric address of the client, from the accepted connection, such as `"127.0.0.1"`. |
| `port` | The port of the client, from the accepted connection. |
| `body` | The whole request body as a vector, which is empty for a request without a body. The server reads it on the first use of the field. |
| `reader` | A coroutine that yields the request body part by part, which the server makes on the first use of the field. |

`ip` and `port` name the other end of the TCP connection. Behind a reverse proxy, a load balancer, or a service such as Cloudflare, that end is the proxy, so they hold its address. The address of the client then travels in a header that the proxy sets, such as `X-Forwarded-For` or `CF-Connecting-IP`, and the application decides which proxies it trusts to set it.

The server calls the handler once the request line and the headers arrived, and the body stays in the connection. The handler reads it whole through `req.body`, which reads the rest of the body and stores the vector in the table, or part by part through `req.reader`. Each resume of `req.reader` returns `true` and the next part of the body as a vector, as soon as it arrives, and the coroutine ends at the end of the body. A failure while it reads makes the resume return `false` and the error. [`network.lines`](/manual/api#network.lines) reads it line by line. Reading `req.body` after `req.reader` yielded a part raises `"the request body was already read through req.reader"`, and using `req.reader` after `req.body` raises `"the request body was already read through req.body"`. Both work until the handler returns. Later, reading either field raises `"the body is no longer available"`, and a resume of a `req.reader` that the handler kept returns `false` and that error. When the request carries `Expect: 100-continue`, the server sends the interim response `100 Continue` on the first read of the body. Whatever the handler left of the body, the server reads and drops before the next request.

The handler returns `status, body, headers`, in the order in which `network.fetch` returns them. `status` is an integer and defaults to 200. `body` is a string, a vector, a coroutine, or a function, and defaults to an empty body. `headers` is a table from header names to strings or integers. A header value may also be a list of strings and integers, which sends one header line for each element in order, so a response can set several cookies with `{ ["Set-Cookie"] = { "a=1", "b=2" } }`. An empty list sends no line. The server adds `Date`, `Content-Length`, and `Connection` when the handler does not set them. A handler may suspend: socket operations and `coroutine.yield` inside it let the other connections run.

A coroutine or a function body streams the response. The server sends the status and the headers, then resumes the coroutine again and again, or calls the function again and again. Each chunk that the coroutine yields or the function returns is a string or a vector, and the server sends it before the next resume or call, so each chunk leaves as soon as it exists. The coroutine ends the body by ending, after a chunk that it returns at its end, and the function ends it by returning `nil`. An empty chunk, and a `nil` that a coroutine yields without ending, send nothing. The coroutine of `req.reader` is such a body, so a handler that returns it sends the request body back as it arrives. The server sends the chunks with `Transfer-Encoding: chunked` and keeps the connection open for the next request. When the handler sets `Content-Length`, or the client speaks HTTP/1.0, the chunks go out as they are and the connection closes after the last one. The coroutine and the function may wait on sockets and suspend between chunks, so a handler that waits for events streams them as they come. A response to `HEAD`, and a status that carries no body, send the headers and never resume the coroutine or call the function. When the coroutine or the function raises an error or produces a value other than a string, a vector, or `nil`, the server reports the error and closes the connection after the chunks it sent, so the client sees a body that ended early.

The following example streams server-sent events. Each event is a `data:` line and an empty line, and the response has the content type `text/event-stream`.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()
local serving = coroutine.detach(coroutine.create(network.serve), server, function(req)
    return 200, coroutine.create(function()
        for n = 1, 3 do
            coroutine.yield(`data: {"count": $(n)}\n\n`)
        end
    end), { ["Content-Type"] = "text/event-stream", ["Cache-Control"] = "no-cache" }
end)
local status, events = network.fetch(`http://127.0.0.1:$(port)/events`, "GET", nil, nil, { stream = true })
for line in network.lines(events) do
    local data = vector.tostring(line):match("^data: (.*)$")
    if data then print(fromjson(data).count) end
end
--> 1
--> 2
--> 3
coroutine.close(serving)
server:close()
```

When the handler raises an error, or returns values that make no response, such as a status that is not an integer, the server answers 500 with an empty body, reports the error, and closes that connection. The other connections continue. It writes the error to standard error, in the form `lus: network.serve: message`, or passes the error value to the `on_error` function of the options.

A handler upgrades the connection to another protocol, such as a WebSocket, by returning the status 101 and a function in place of the body. The server sends the 101 response with the headers of the handler and no body, then calls the function with the TCP socket of the connection, in the coroutine of the connection. Bytes that the client sent after the request are already in the buffer of the socket, so the first `receive` returns them. The connection closes when the function returns. When the function raises an error, the server reports it like an error of a handler and closes the connection without a further response. The socket keeps the `idle_timeout` of the server until the function calls `settimeout`. The status 101 with any other body counts as values that make no response.

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
| `tls` | A table with `cert` and `key`, PEM text of the certificate chain and the private key of the server, and `password` for an encrypted key. A list of such tables serves one certificate for each name. |

A connection makes progress when the server reads a part of a request from it or writes a part of a response to it. A connection that stays idle for `idle_timeout` between two requests closes. One that stops in the middle of the head of a request, or in the middle of a body that the handler reads, is answered with 408 and closes, and one that stops reading its response closes as well. A handler may take as long as it needs.

With the `tls` option the server serves HTTPS. Every connection runs a TLS handshake inside its first read, so a client that never finishes it closes after `idle_timeout`, and a client that speaks plain HTTP gets no response. The server offers HTTP/1.1 through ALPN and chooses the certificate by the name that the client sends through SNI: the first certificate whose DNS names, or whose common name when it lists none, match the name. A client that sends no name, or a name that no certificate carries, gets the first certificate. The server reads the certificates once, when `serve` starts, and a certificate that does not parse raises a `bad argument` error before the server accepts anything. A server picks up renewed certificates when the program calls `serve` again. An upgrade with the status 101 hands the function a TLS socket, so a WebSocket over HTTPS works like one over HTTP.

While `max_connections` connections are open, further clients wait in the queue of the system, and the server accepts the next one when a connection closes. When the system has no file descriptor or no memory left for a new connection, the server waits for a connection to close, or for a moment, and accepts again.

The server reads request bodies with a `Content-Length` and bodies with `Transfer-Encoding: chunked`, answers `Expect: 100-continue`, and leaves the body out of the response to a `HEAD` request. The request line and the headers of a request are limited to 64 KiB and 128 header lines. A chunked body gives each chunk size as hexadecimal digits alone, and the line that starts a chunk is limited to 1 KiB. The framing of a chunked body, which is its chunk lines and its trailers, is limited to 64 KiB plus 8 bytes for every byte of the body. A head over a limit is answered with 431, and a malformed head with 400, before the handler runs. `req.body` holds at most 16 MiB, and `req.reader` yields a body of any size. A body that breaks its framing or its limit while the handler reads it raises an error in the handler. When the handler lets that error end it, the server answers 400, 413, or 431 in place of 500. Whatever the handler returns, a connection whose body broke closes after the response, and so does a connection whose unread body is over 16 MiB or waits for a `100 Continue` that the server never sent.

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

The example talks to its server through a TCP socket so that every byte on the wire shows. [`network.fetch`](/manual/api#network.fetch) reaches a server of the same state too.
