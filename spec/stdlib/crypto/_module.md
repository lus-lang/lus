---
name: crypto
module: crypto
kind: module
since: 2.0.0
stability: unstable
origin: lus
---

The `crypto` module computes SHA-2 and SHA-1 digests and HMACs, signs and verifies with Ed25519, reads secure random bytes, compares secrets in constant time, hashes passwords with Argon2id, and generates UUIDs and ULIDs.

Digests, keys, signatures, and random output are raw bytes, so the module returns them as vectors. Messages, HMAC keys, and passwords may be strings or vectors. A string contributes its WTF-8 bytes. [`crypto.hash`](/manual/api#crypto.hash) and [`crypto.hmac`](/manual/api#crypto.hmac) also return hex or base64 text on request, and [`string.transcode`](/manual/api#string.transcode) converts keys and signatures between vectors and text.

The following example prints a SHA-256 digest in hex, then signs a message and checks the signature.

```lus
print(crypto.hash("sha256", "abc", "hex"))
--> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad

local secret, public = crypto.keypair()
local sig = crypto.sign(secret, "release 2.0.0")
print(crypto.verify(public, "release 2.0.0", sig))   --> true
```

The module requires no permission, so a chunk that renounced every permission with [`pledge`](/manual/api#pledge) can still use it. Every function is available in the WebAssembly build, where the secure random source is the `random_get` call of WASI. Every primitive comes from the Zig standard library. The [cryptography](/manual/crypto) page of the manual describes the module in full.
