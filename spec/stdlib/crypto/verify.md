---
name: crypto.verify
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: public
    type: vector
  - name: message
    type: string|vector
  - name: signature
    type: vector
returns: boolean
---

Returns `true` when `signature` is a valid Ed25519 signature of `message` by the holder of `public`, and `false` otherwise.

- `public` is a public key from [`crypto.keypair`](/manual/api#crypto.keypair), a vector of 32 bytes.
- `message` is the signed message, a string or a vector.
- `signature` is a vector of 64 bytes.

Verification is strict. It rejects a non-canonical signature, a non-canonical public key, and a public key of small order, so every strict verifier gives the same answer for the same input. Every invalid signature, including one made for another message or another key, returns `false`. The function raises only for an argument of the wrong type or size: `bad argument #1 to 'verify' (32-byte vector expected)` for the key and `bad argument #3 to 'verify' (64-byte vector expected)` for the signature.

The following example checks the signature of the empty message from the first test vector of RFC 8032, then the same signature over another message.

```lus
local function bytes(hex)
    return string.transcode(hex, "hex", "binary")
end
local public = bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
local sig = bytes("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
print(crypto.verify(public, "", sig))    --> true
print(crypto.verify(public, "x", sig))   --> false
```
