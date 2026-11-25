---
name: crypto.keypair
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: seed
    type: vector|string
    optional: true
returns:
  - name: secret
    type: vector|userdata
  - name: public
    type: vector|userdata
---

Returns a new secret key and its public key.

- With no argument, the function returns an Ed25519 key pair as two vectors of 32 bytes, drawn from the secure random source.
- With a `seed` vector of 32 bytes, it returns the Ed25519 key pair of that seed.
- With the curve name `"P-256"` or `"P-384"`, it returns a new ECDSA key pair as two [`crypto.key`](/manual/api#crypto.importkey) objects.

The Ed25519 secret key is the seed itself, which is the private key of RFC 8032. `crypto.keypair(secret)` therefore returns the same secret key with its public key, which is how a program recovers the public key of a stored secret key. An EC secret key gives its public key through `key:public()`. Keep the secret key private. The public key may be published.

A `seed` vector of another size raises `bad argument #1 to 'keypair' (32-byte vector expected)`. Another curve name raises `bad argument #1 to 'keypair' (invalid option 'P-521')`. The library generates no RSA keys. A program imports them with [`crypto.importkey`](/manual/api#crypto.importkey).

The following example derives the public key of the first test vector of RFC 8032, then makes a P-256 key pair.

```lus
local seed = string.transcode(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "hex",
    "binary"
)
local secret, public = crypto.keypair(seed)
print(string.transcode(public, "binary", "hex"))
--> d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a

local ec_secret, ec_public = crypto.keypair("P-256")
print(ec_secret.curve, ec_secret.private, ec_public.private)  --> P-256  true  false
```

[`crypto.sign`](/manual/api#crypto.sign) signs with the secret key and [`crypto.verify`](/manual/api#crypto.verify) checks a signature with the public key.
