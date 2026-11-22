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
    type: string|vector
    optional: true
returns:
  - name: status
    type: integer
  - name: body
    type: vector
  - name: headers
    type: table
---

Sends one HTTP or HTTPS request to `url` and returns the response status, the response body as a vector, and the response headers.

`url` is a string that starts with `http://` or `https://`. The arguments after it are positional and optional. `method` is a string that defaults to `"GET"`. `headers` is a table from header names to values. A value is a string, a number, or a list of them, and a list sends one header line for each element in order. `body` is the request body as a string or a vector and defaults to an empty body. The request carries `Host`, `Connection: close`, and `User-Agent: Lus/VERSION`, where `VERSION` is the full version of the runtime such as `2.0.0`, except those that `headers` names in any case, then the entries of `headers`, then `Content-Length` when the body is not empty.

On success the call returns three values: the integer status code, the body as a vector, and a table from lowercase header names to their values. A response to `"HEAD"`, and a 1xx, 204, or 304 response, has an empty body whatever its `Content-Length` says. A response header that appears more than once holds its values joined by `", "` in the order they arrived. Every status counts as a response, so a 404 or a 500 is returned like a 200, and a redirect returns its 3xx status together with its `location` header. A program that expects text decodes the body with [`vector.tostring`](/manual/api#vector.tostring).

Every failure raises an error. A host that cannot be reached raises an error such as `"cannot resolve 'invalid.host.example': Domain name not found"` or `"cannot connect to 127.0.0.1:1: Connection refused"`. A connection that fails once it is open raises `"failed to send request: REASON"`, `"failed to read response: REASON"`, `"failed to read response headers: REASON"`, or `"failed to read response body: REASON"`, where `REASON` is the error of the system, such as `Connection reset by peer`. A server that sends nothing for 30 seconds gives the reason `Operation timed out`. A server that closes the connection in the middle of a line gives the reason `Connection closed by peer`. A URL with another scheme raises `"invalid URL: URL"`, and a URL, method, or header that contains a line break raises an error before anything is sent. A body over 64 MiB raises `"response body too large"`, and a body shorter than its `Content-Length` or its chunk sizes raises `"truncated response body"`. A body without either ends where the server closes the connection. HTTPS verifies the certificate of the server against the certificates of the system and raises `"SSL certificate verification failed for HOST"` when the verification fails. A handshake that fails for another reason, such as a server that does not speak TLS, raises `"SSL handshake failed: REASON"`. The call requires `network:http` for `url`.

The following example requests a JSON document from a public server, so it needs network access to run.

```lus nocheck
pledge("network:http")
local status, body, headers = network.fetch("https://httpbin.org/get")
print(status)                    --> 200
print(headers["content-type"])   --> application/json
local data = fromjson(vector.tostring(body))
```

Outside a detached coroutine, `fetch` runs the detached coroutines while it waits for the response, so the main chunk can fetch from a [`network.serve`](/manual/api#network.serve) server that runs in the same state. Inside a detached coroutine, `fetch` blocks the whole state while it waits, the other detached coroutines included.
