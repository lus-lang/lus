---
name: crypto
module: crypto
kind: module
since: 2.0.0
stability: unstable
origin: lus
---

The `crypto` module computes SHA-2, SHA-1, and MD5 digests, in one call or streamed. It computes HMACs, derives keys with PBKDF2 and HKDF, and encrypts with AES-256-GCM. It signs and verifies with Ed25519, ECDSA over P-256 and P-384, and RSA, with keys read from PEM, DER, or JWK. It also reads secure random bytes, compares secrets in constant time, hashes passwords with Argon2id, and generates UUIDs and ULIDs.

Digests, raw keys, signatures, ciphertexts, and random output are raw bytes, so the module returns them as vectors. RSA and EC keys are `crypto.key` objects from [`crypto.importkey`](/manual/api#crypto.importkey) or [`crypto.keypair`](/manual/api#crypto.keypair). Messages, HMAC keys, and passwords may be strings or vectors. A string contributes its WTF-8 bytes. [`string.transcode`](/manual/api#string.transcode) converts vectors to hex, base64, or base64url text and back.

The following example prints a SHA-256 digest in hex, then signs a message and checks the signature.

```lus
print(string.transcode(crypto.hash("sha256", "abc"), "binary", "hex"))
--> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad

local secret, public = crypto.keypair()
local sig = crypto.sign(secret, "release 2.0.0")
print(crypto.verify(public, "release 2.0.0", sig))  --> true
```

The module requires no permission, so a chunk that renounced every permission with [`pledge`](/manual/api#pledge) can still use it. Every function is available in the WebAssembly build, where the secure random source is the `random_get` call of WASI. Every primitive comes from the Zig standard library. The [cryptography](/manual/crypto) page of the manual describes the module in full.
