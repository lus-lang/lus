---
name: network.fetch
module: network
kind: function
since: 0.1.0
stability: stable
pledges: ["network:http"]
origin: lus
params:
  - name: url
    type: string
  - name: method
    type: string
    optional: true
  - name: headers
    type: table
    optional: true
  - name: body
    type: string|vector|function|thread
    optional: true
  - name: options
    type: table
    optional: true
returns:
  - name: status
    type: integer
  - name: body
    type: vector|thread
  - name: headers
    type: table
---

Sends one HTTP or HTTPS request to `url` and returns the response status, the response body, and the response headers.

`url` is a string that starts with `http://` or `https://`. The arguments after it are positional and optional. `method` is a string that defaults to `"GET"`. It holds letters, digits, and the marks ``!#$%&'*+-.^_`|~``, and any other character raises an error. `headers` is a table from header names to values. A value is a string, a number, or a list of them, and a list sends one header line for each element in order. `body` is the request body and defaults to an empty body. The request carries `Host`, `Connection: close`, and `User-Agent: Lus/VERSION`, where `VERSION` is the full version of the runtime such as `2.0.0`, except those that `headers` names in any case, then the entries of `headers`, then the framing of the body.

A string or a vector `body` goes out whole after a `Content-Length` header. A coroutine or a function produces the request body as it goes out. `fetch` resumes a coroutine again and again, sends each chunk that it yields, and ends the body when the coroutine ends, after a chunk that the coroutine returns at its end. `fetch` calls a function again and again, sends each chunk that it returns, and ends the body when it returns `nil`. A chunk is a string or a vector, and an empty chunk or a `nil` that a coroutine yields sends nothing. Such a body goes out with `Transfer-Encoding: chunked`, unless `headers` sets `Content-Length`, in which case the chunks go out as they are and must add up to that length. Any other value raises an error, and so does an error of the coroutine or the function.

`options` is a table with any of these fields:

| Field | Value |
| --- | --- |
| `stream` | `true` to return the body as a coroutine that yields it, described below. It defaults to `false`. |
| `timeout` | Seconds for each step of the request, described below, which defaults to 30. A negative value waits without limit. |
| `tls` | A table of client TLS options for an `https` URL, as [`network.tls`](/manual/api#network.tls) describes them, such as `{ ca = pem }` for a private certificate authority. ALPN always offers `http/1.1`. |

`timeout` bounds each step of the request. Connecting, the TLS handshake, and receiving the status line and the headers each must end within `timeout` seconds of their start, and connecting counts every address of the host. Sending the request and reading the body wait at most `timeout` seconds for each part, so a long upload or a stream that keeps sending stays open as long as it moves. A step that runs out of time raises an error that names it: `"fetch timeout while connecting to HOST:PORT"`, `"fetch timeout in the TLS handshake with HOST"`, `"fetch timeout while sending the request"`, `"fetch timeout while waiting for the response headers"`, or `"fetch timeout while reading the body"`.

On success the call returns three values: the integer status code, the body, and a table from lowercase header names to their values. The body is a vector, or a coroutine when `options.stream` is `true`. Each resume of the coroutine returns `true` and the next part of the body as a vector, between 1 and 65536 bytes, as soon as it arrives. At the end of the body the coroutine closes the connection and ends, so its last resume returns `true` alone. A failure while it reads, such as a body that ends early or a step that runs out of time, makes the resume return `false` and the error. [`coroutine.close`](/manual/api#coroutine.close) ends the coroutine before the end of the body and closes the connection, and so does the collector for a coroutine that nothing refers to any more. [`network.lines`](/manual/api#network.lines) reads such a coroutine line by line, which suits server-sent events and other streams of text. A response to `"HEAD"`, and a 1xx, 204, or 304 response, has an empty body whatever its `Content-Length` says. A response without `Content-Length` and without chunked transfer coding ends with the connection. A response header that appears more than once holds its values joined by `", "` in the order they arrived. Every status counts as a response, so a 404 or a 500 is returned like a 200, and a redirect returns its 3xx status together with its `location` header. A program that expects text decodes the body with [`vector.tostring`](/manual/api#vector.tostring).

Every failure raises an error. A failure of the network or of the response raises an error object with the fields `code` and `message`, as socket operations return them (see [`network.tcp`](/manual/api#network.tcp)), whose `__tostring` gives the message. A host that cannot be reached raises an error such as `"cannot resolve 'invalid.host.example': Domain name not found"` or `"cannot connect to 127.0.0.1:1: Connection refused"`. A connection that fails once it is open raises `"failed to send request: REASON"`, `"failed to read response: REASON"`, or `"failed to read response body: REASON"`, where `REASON` is the error of the system, such as `Connection reset by peer`. A server that closes the connection before the end of the headers gives the reason `Connection closed by peer`. A URL with another scheme raises `"invalid URL: URL"`, and a URL, method, or header that contains a line break raises an error before anything is sent. A whole body over 64 MiB raises `"response body too large"`, and a body shorter than its `Content-Length` raises `"truncated response body"`. Over HTTPS, a body that runs to the end of the connection raises `"truncated response body: the TLS connection ended without a close notification"` when the connection ends before the close notification of the server arrives. HTTPS verifies the certificate of the server against the certificates of the system, or against the `ca` of the `tls` option, and a certificate that does not verify raises `"certificate verification failed for HOST: REASON"`. A handshake that fails for another reason, such as a server that does not speak TLS, raises `"TLS handshake failed: REASON"`. A `tls` option with an `http` URL and an unknown option raise a `bad argument` error. The call requires `network:http` for `url`.

The following example requests a JSON document from a public server, so it needs network access to run.

```lus nocheck
pledge("network:http")
local status, body, headers = network.fetch("https://httpbin.org/get")
print(status)                    --> 200
print(headers["content-type"])   --> application/json
local data = fromjson(vector.tostring(body))
```

Every wait of `fetch` goes through the scheduler. Inside a detached coroutine it suspends the coroutine, and the other detached coroutines run in the meantime. Anywhere else it blocks its caller and runs the detached coroutines while it waits, so the main chunk can fetch from a [`network.serve`](/manual/api#network.serve) server that runs in the same state.

The following example sends a request body from a coroutine and streams the response from a server of the same state.

```lus
pledge("network")
local server = network.tcp.bind("127.0.0.1", 0)
local _, port = server:getsockname()

local serving = coroutine.detach(coroutine.create(network.serve), server, function(req)
    local got = vector.tostring(req.body)
    local n = 0

    return 200, function()
        n = n + 1

        if n <= 2 then
            return `line $n of $got\n`
        end
    end
end)

local upload = coroutine.create(function()
    coroutine.yield("up")
    coroutine.yield("load")
end)

local status, body = network.fetch(
    `http://127.0.0.1:$port/`,
    "POST",
    nil,
    upload,
    { stream = true }
)

for line in network.lines(body) do
    print(vector.tostring(line))
end

--> line 1 of upload
--> line 2 of upload
coroutine.close(serving)
server:close()
```
