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
    type: string
    optional: true
returns:
  - name: status
    type: integer
  - name: body
    type: string
  - name: headers
    type: table
---

Performs an HTTP or HTTPS request using positional optional arguments. `method` defaults to `"GET"`. `headers` supplies request header names and values, and `body` supplies the request body. Returns the integer response status, response body string, and a table with lowercase response header names. Response bodies are capped at 64 MiB.
