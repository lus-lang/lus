---
name: crypto.hkdf
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: algorithm
    type: string
  - name: key
    type: string|vector
  - name: salt
    type: string|vector
    optional: true
  - name: info
    type: string|vector
    optional: true
  - name: length
    type: integer
returns: vector
---

Derives `length` bytes from a key with HKDF (RFC 5869) and returns them as a vector.

- `algorithm` names the HMAC, as for [`crypto.hmac`](/manual/api#crypto.hmac).
- `key` is the input keying material, such as a shared secret or a master key.
- `salt` is an optional non-secret random value. `nil` is the empty salt.
- `info` is optional context that binds the result to one use, such as `"cookie encryption"`. `nil` is empty.
- `length` is the size of the result, from 1 to 255 times the digest size of `algorithm`.

HKDF turns one strong secret into several independent keys, one per `info`. It adds no cost to guessing, so the input must already be a strong secret. A password goes through [`crypto.hashpassword`](/manual/api#crypto.hashpassword) or [`crypto.pbkdf2`](/manual/api#crypto.pbkdf2) instead.

A `length` out of range raises `bad argument #5 to 'hkdf' (length out of range)`. The other errors are those of `crypto.hmac`.

The following example derives two keys for different purposes from one master key.

```lus
local master = crypto.random(32)
local enc = crypto.hkdf("sha256", master, nil, "cookie encryption", 32)
local mac = crypto.hkdf("sha256", master, nil, "cookie signing", 32)
print(#enc, #mac, crypto.equal(enc, mac))   --> 32  32  false
```
