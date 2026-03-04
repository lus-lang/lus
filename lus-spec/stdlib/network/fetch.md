---
name: network.fetch
module: network
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: url
    type: string
  - name: options
    type: table
    optional: true
returns: table
---

Performs an HTTP(S) request to `url`. The optional `options` table may specify method, headers, and body. Returns the response body as a string, plus the HTTP status code and a response headers table. Requires `network` pledge.
