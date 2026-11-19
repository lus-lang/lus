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

Performs an HTTP or HTTPS request using positional optional arguments. `method` defaults to `"GET"`. `headers` supplies request header names and values, and `body` supplies the request body as a string or a vector. Returns the integer response status, the response body as a vector, and a table with lowercase response header names. A program that expects a text body decodes it with `vector.tostring`. Response bodies are capped at 64 MiB.
