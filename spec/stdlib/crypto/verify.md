---
name: crypto.verify
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: key
    type: userdata|vector
  - name: message
    type: string|vector
  - name: signature
    type: string|vector
  - name: algorithm
    type: string
    optional: true
returns: boolean
---

Returns `true` when `signature` is a valid signature of `message` by the holder of `key`, and `false` otherwise.

- `key` is a [`crypto.key`](/manual/api#crypto.importkey), public or private, or an Ed25519 public key from [`crypto.keypair`](/manual/api#crypto.keypair) as a vector of 32 bytes.
- `message` is the signed message, a string or a vector.
- `signature` is the signature, a vector. A string contributes its bytes.
- `algorithm` is a JOSE algorithm name, as for [`crypto.sign`](/manual/api#crypto.sign). An RSA key requires it.

Ed25519 verification is strict. It rejects a non-canonical signature, a non-canonical public key, and a public key of small order, so every strict verifier gives the same answer for the same input. Every invalid signature, including one made for another message, another key, or another algorithm, and one of the wrong length, returns `false`.

The function raises only for an argument of the wrong type. With a vector key, a key that is not 32 bytes raises `bad argument #1 to 'verify' (32-byte vector expected)` and a signature that is not 64 bytes raises `bad argument #3 to 'verify' (64-byte vector expected)`. Another `key` type raises `bad argument #1 to 'verify' (crypto.key or vector expected, got string)`. The algorithm errors are those of `crypto.sign`, for argument 4.

The following example checks the signature of the empty message from the first test vector of RFC 8032, then the same signature over another message.

```lus
local function bytes(hex)
    return string.transcode(hex, "hex", "binary")
end

local public = bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
local sig = bytes(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
)
print(crypto.verify(public, "", sig))  --> true
print(crypto.verify(public, "x", sig))  --> false
```
