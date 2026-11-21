---
name: crypto.sign
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: secret
    type: vector
  - name: message
    type: string|vector
returns: vector
---

Returns the Ed25519 signature of `message`, a vector of 64 bytes.

- `secret` is a secret key from [`crypto.keypair`](/manual/api#crypto.keypair), a vector of 32 bytes.
- `message` is a string or a vector of any length. A string contributes its WTF-8 bytes.

Signing is deterministic, as RFC 8032 defines it, so the same key and message always give the same signature. A `secret` that is not a vector of 32 bytes raises `bad argument #1 to 'sign' (32-byte vector expected)`. A `message` that is neither a string, a number, nor a vector raises `bad argument #2 to 'sign' (string or vector expected, got table)` with its type.

The following example signs a release manifest and writes the signature as base64.

```lus
local secret, public = crypto.keypair()
local manifest = tojson({ name = "app", version = "1.4.0" })
local sig = crypto.sign(secret, manifest)
print(#sig)                                       --> 64
print(#string.transcode(sig, "binary", "base64"))  --> 88
print(crypto.verify(public, manifest, sig))       --> true
```
