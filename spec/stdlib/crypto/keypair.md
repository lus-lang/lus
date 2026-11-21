---
name: crypto.keypair
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: seed
    type: vector
    optional: true
returns:
  - name: secret
    type: vector
  - name: public
    type: vector
---

Returns an Ed25519 secret key and its public key, as two vectors of 32 bytes.

- `seed` is a vector of 32 bytes. When it is absent, the seed comes from the secure random source.

The secret key is the seed itself, which is the private key of RFC 8032. `crypto.keypair(secret)` therefore returns the same secret key with its public key, which is how a program recovers the public key of a stored secret key. Keep the secret key private. The public key may be published.

A `seed` that is not a vector of 32 bytes raises `bad argument #1 to 'keypair' (32-byte vector expected)`.

The following example derives the public key of the first test vector of RFC 8032.

```lus
local seed = string.transcode("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "hex", "binary")
local secret, public = crypto.keypair(seed)
print(string.transcode(public, "binary", "hex"))
--> d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
```

[`crypto.sign`](/manual/api#crypto.sign) signs with the secret key and [`crypto.verify`](/manual/api#crypto.verify) checks a signature with the public key.
