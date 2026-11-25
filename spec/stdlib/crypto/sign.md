---
name: crypto.sign
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
  - name: algorithm
    type: string
    optional: true
returns: vector
---

Returns the signature of `message` under a secret key, as a vector.

- `key` is a private [`crypto.key`](/manual/api#crypto.importkey), or an Ed25519 secret key from [`crypto.keypair`](/manual/api#crypto.keypair) as a vector of 32 bytes.
- `message` is a string or a vector of any length. A string contributes its WTF-8 bytes.
- `algorithm` is a JOSE algorithm name: `"EdDSA"`, `"ES256"`, `"ES384"`, `"RS256"`, `"RS384"`, `"RS512"`, `"PS256"`, `"PS384"`, or `"PS512"`.

An Ed25519 or EC key implies its algorithm, so `algorithm` may be left out. An RSA key signs with PKCS #1 v1.5 (`RS`) or PSS (`PS`), so it requires the algorithm. PSS uses MGF1 with the same hash and a salt as long as the digest, as JSON Web Signatures fix it.

The result is 64 bytes for Ed25519 and ES256, 96 bytes for ES384, and as long as the modulus for RSA. ECDSA signatures are the two numbers `r` and `s` side by side, the form of JSON Web Signatures and WebCrypto. Ed25519 and RS signatures are deterministic. ECDSA and PS signatures mix in fresh random bytes, so two signatures of one message differ and both verify. Every RSA signature is checked against the public key before it is returned, so a fault or a key with mismatched parts raises `RSA signature failed its verification check` and never releases a signature.

A `key` of the wrong type raises `bad argument #1 to 'sign' (crypto.key or vector expected, got string)` with its type. A public key raises `bad argument #1 to 'sign' (private key expected)`. An RSA key without an algorithm raises `bad argument #3 to 'sign' (RSA key requires an algorithm)`. An algorithm of another key type raises `bad argument #3 to 'sign' (algorithm 'ES256' does not fit an RSA key)`. A `message` that is neither a string, a number, nor a vector raises `bad argument #2 to 'sign' (string or vector expected, got table)` with its type.

The following example signs a release manifest with Ed25519, then signs a token header with a P-256 key.

```lus
local secret, public = crypto.keypair()
local manifest = tojson({ name = "app", version = "1.4.0" })
local sig = crypto.sign(secret, manifest)
print(#sig, crypto.verify(public, manifest, sig))  --> 64  true

local ec = crypto.keypair("P-256")
local es = crypto.sign(ec, "eyJhbGciOiJFUzI1NiJ9.e30")
print(#es, crypto.verify(ec:public(), "eyJhbGciOiJFUzI1NiJ9.e30", es))  --> 64  true
```
