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
returns: vector
---

Returns the HMAC of `data` under `key`, as defined by RFC 2104, as a vector.

- `algorithm` is `"sha256"`, `"sha384"`, `"sha512"`, `"sha1"`, or `"md5"`.
- `key` is the secret key, a string or a vector of any length.
- `data` is the message, a string or a vector.

The result has the size of a digest of `algorithm`: 32 bytes for SHA-256, 48 bytes for SHA-384, 64 bytes for SHA-512, 20 bytes for SHA-1, and 16 bytes for MD5. A string `key` or `data` contributes its WTF-8 bytes. A number is converted to its textual form first. The errors are those of [`crypto.hash`](/manual/api#crypto.hash), with `key` as argument 2 and `data` as argument 3.

An HMAC proves that a message comes from a holder of the key, such as the signature of a webhook or of a JSON Web Token. Compare a received HMAC with the expected one through [`crypto.equal`](/manual/api#crypto.equal), whose running time reveals nothing about where they differ.

The following example computes an HMAC and checks a received hex value against it.

```lus
local mac = crypto.hmac("sha256", "key", "The quick brown fox jumps over the lazy dog")
print(#mac)   --> 32

local received = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
print(crypto.equal(mac, string.transcode(received, "hex", "binary")))   --> true
```
