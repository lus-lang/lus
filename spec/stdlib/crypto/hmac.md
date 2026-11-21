---
name: crypto.hmac
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
  - name: data
    type: string|vector
  - name: encoding
    type: string
    optional: true
returns: vector|string
---

Returns the HMAC of `data` under `key`, as defined by RFC 2104.

- `algorithm` is `"sha256"`, `"sha512"`, or `"sha1"`.
- `key` is the secret key, a string or a vector of any length.
- `data` is the message, a string or a vector.
- `encoding` is `"hex"` or `"base64"`. When it is absent, the result is a vector.

The result has the size of a digest of `algorithm`: 32 bytes for SHA-256, 64 bytes for SHA-512, and 20 bytes for SHA-1. A string `key` or `data` contributes its WTF-8 bytes, and a number is converted to its textual form first. The errors are those of [`crypto.hash`](/manual/api#crypto.hash), with `key` as argument 2 and `data` as argument 3.

An HMAC proves that a message comes from a holder of the key, such as the signature of a webhook or of a JSON Web Token. Compare a received HMAC with the expected one through [`crypto.equal`](/manual/api#crypto.equal), whose running time reveals nothing about where they differ.

The following example computes an HMAC and checks a received value against it.

```lus
local mac = crypto.hmac("sha256", "key", "The quick brown fox jumps over the lazy dog", "hex")
print(mac)   --> f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8

local received = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
print(crypto.equal(mac, received))   --> true
```
