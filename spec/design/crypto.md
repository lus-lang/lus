# Cryptography

The `crypto` library gives Lus programs the primitives that package signing, token signing, OAuth, database authentication, encrypted cookies, and password storage need: the SHA-2 hash functions SHA-256, SHA-384, and SHA-512, HMAC, PBKDF2 and HKDF, AES-256-GCM, Ed25519, ECDSA, and RSA signatures with keys from PEM, DER, and JWK, secure random bytes, constant-time comparison, and Argon2id password hashing. SHA-1 and MD5 exist for formats that require them. It also generates UUIDs and ULIDs. The runtime uses the same code to verify remote modules and Lus releases, which are signed with Ed25519 over SHA-256 digests.

Every primitive comes from Zig's `std.crypto`. The library adds argument checking, the conversion between Lus values and bytes, the key formats, the RSA signature encodings that std leaves private, and the text formats of UUIDs and ULIDs. The section on RSA describes the one place where the library composes std's arithmetic itself.

## Functions

The library is the global table `crypto` with seventeen functions.

| Function | Result |
|---|---|
| `crypto.hash(algorithm, data)` | The digest of `data`. |
| `crypto.hasher(algorithm)` | A streaming hasher with the methods `update(data)` and `digest()`. |
| `crypto.hmac(algorithm, key, data)` | The HMAC of `data` under `key`. |
| `crypto.random(n)` | A vector of `n` bytes from the operating system's secure random source. |
| `crypto.equal(a, b)` | `true` when `a` and `b` hold the same bytes, compared in constant time. |
| `crypto.pbkdf2(algorithm, password, salt, iterations, length)` | A key derived from a password with PBKDF2. |
| `crypto.hkdf(algorithm, key, salt, info, length)` | A key derived from a key with HKDF. |
| `crypto.encrypt(algorithm, key, nonce, plaintext [, aad])` | The AES-256-GCM ciphertext and tag. |
| `crypto.decrypt(algorithm, key, nonce, ciphertext, tag [, aad])` | The plaintext, or `nil` when authentication fails. |
| `crypto.importkey(data)` | A key object read from PEM, DER, or JWK. |
| `crypto.keypair([seed or curve])` | An Ed25519 secret key and its public key, or an EC key pair. |
| `crypto.sign(key, message [, algorithm])` | The signature of `message`. |
| `crypto.verify(key, message, signature [, algorithm])` | `true` when `signature` is a valid signature of `message` by `key`. |
| `crypto.hashpassword(password [, options])` | An Argon2id hash of `password` in PHC string format. |
| `crypto.verifypassword(password, hash)` | `true` when `password` matches `hash`. |
| `crypto.uuid([version])` | A UUID of version 4, the default, or version 7, as a string. |
| `crypto.ulid()` | A ULID as a string. |

`algorithm` is `"sha256"`, `"sha384"`, `"sha512"`, `"sha1"`, or `"md5"` for every function that takes a hash. SHA-1 is broken for collision resistance, so it exists for interoperability with formats that require it, such as git object names. MD5 is broken for every security purpose and exists for formats that still name it, such as the `md5` authentication of PostgreSQL. Any other name raises `bad argument #1 to 'hash' (invalid option 'sha3')`.

Each operation is one function that takes the algorithm as an argument, which keeps the table small. A later algorithm, such as SHA-3 or BLAKE3, becomes a new name that `algorithm` accepts.

## Bytes and text

Digests, keys, signatures, and random output are raw bytes, so they are vectors, following the rule in [strings](strings.md) that byte data lives in vectors. Inputs that a program writes as text, such as a message, an HMAC key, or a password, may be strings or vectors. A string contributes its WTF-8 bytes. A number converts to its textual form first, as it does for every string parameter.

Keys and signatures must be vectors of the exact size: 32 bytes for an Ed25519 secret key, a public key, and a seed, and 64 bytes for a signature. A vector of another size, or a value of another type, raises a "bad argument" error that names the expected size, such as `bad argument #1 to 'sign' (32-byte vector expected)`. A key or signature that arrives as hex or base64 text converts with [`string.transcode`](/manual/api#string.transcode), for example `string.transcode(text, "hex", "binary")`.

Every digest, HMAC, key, and signature is a vector. The one way to turn those bytes into text is `string.transcode` with the encodings `"hex"`, `"base64"`, and `"base64url"`. Lus 2.0 adds `"base64url"` to `string.transcode` for this library. It is the URL-safe alphabet of RFC 4648 without padding, which JSON Web Tokens and many HTTP APIs use. Decoding accepts it with or without padding.

The example below prints the SHA-256 digest of a string in hex.

```lus nocheck
print(string.transcode(crypto.hash("sha256", "abc"), "binary", "hex"))
--> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

## Streaming

`crypto.hasher(algorithm)` returns a _hasher_, a userdata that accumulates bytes. `hasher:update(data)` adds a string or vector and returns the hasher, so calls chain. `hasher:digest()` returns the digest of every byte added so far as a vector. It finishes a copy of the internal state, so the hasher accepts more data afterwards and a later `digest` covers everything. A program verifies a large download or a package bundle by feeding it to a hasher in chunks as it arrives, without holding the whole input in memory. The hasher holds no memory outside its userdata, so it needs no finalizer. A worker message cannot carry it.

The example below hashes a file in blocks of 64 KiB.

```lus nocheck
local h = crypto.hasher("sha256")
local f = io.open("lus-2.0.0.tar.gz", "rb")
while block = f:read(65536) do
    h:update(block)
end
f:close()
print(string.transcode(h:digest(), "binary", "hex"))
```

## Ed25519

`crypto.keypair()` returns two vectors: the 32-byte secret key, which is the seed of RFC 8032, and the 32-byte public key. `crypto.keypair(seed)` derives the same pair from a given 32-byte seed, which also computes the public key of a stored secret key. Signing is deterministic, so a message and a key always give the same signature. The RFC 8032 test vectors therefore apply directly.

`crypto.verify` uses strict verification. It rejects non-canonical encodings and public keys of small order, so a signature that one verifier accepts is accepted by every strict verifier. It returns `false` for every invalid signature and raises only when an argument has the wrong type or size.

The example below signs a message and checks the signature.

```lus nocheck
local secret, public = crypto.keypair()
local sig = crypto.sign(secret, "release 2.0.0")
print(crypto.verify(public, "release 2.0.0", sig))   --> true
print(crypto.verify(public, "release 2.0.1", sig))   --> false
```

## Keys

RSA and EC keys have structure, so they are objects: userdata with the metatable `crypto.key`, made by `crypto.importkey` or `crypto.keypair`. A key object holds plain data and no heap memory, so it needs no finalizer. It reports `key.type` (`"rsa"`, `"ec"`, `"ed25519"`), `key.private`, `key.bits` for RSA, and `key.curve` for EC and Ed25519. `key:public()` returns the public half. `key:export(format)` writes PEM, DER, or a JWK table, choosing PKCS #8 for a private key and SubjectPublicKeyInfo for a public one, the layouts of `openssl pkey`. Ed25519 keys may be key objects too, so a program that reads keys from a file treats every type alike, while the vectors of `crypto.keypair()` keep working.

`crypto.importkey` tells its input apart by type and first bytes: PEM text, JSON text of a JWK, a JWK table, or DER bytes in a vector. PEM blocks of EC parameters before a key are skipped. The DER layouts are PKCS #8 (versions 1 and 2), SubjectPublicKeyInfo, the RSA keys of PKCS #1, and the EC private key of SEC1. Encrypted keys raise an error that names them, since decrypting them needs password-based encryption schemes that belong with a key file tool. RSA moduli are 2048, 3072, or 4096 bits. EC keys use P-256 and P-384, the curves of ES256 and ES384. Every key is validated on import: EC points lie on their curve, Ed25519 points decode, RSA values are odd and reduce under their moduli, and a private key whose stated public part differs from the one it derives raises.

std reads DER only inside its certificate parser, through a reader that trusts its lengths, so the key structures have a reader of their own that checks every bound. The corrupt harness feeds it truncated and flipped keys.

The library generates RSA keys nowhere. Providers and `openssl` make them. New keys in Lus are Ed25519 or P-256, which `crypto.keypair` generates.

## Signatures

`crypto.sign` and `crypto.verify` take a key object and a JOSE algorithm name: `EdDSA`, `ES256`, `ES384`, `RS256`, `RS384`, `RS512`, `PS256`, `PS384`, or `PS512`. Ed25519 and EC keys imply their algorithm, so the name is optional for them and must match when given. An RSA key requires it, since PKCS #1 v1.5 and PSS are both common. ECDSA signatures are `r || s`, the form of JWS and WebCrypto. They use the nonces of std with fresh random bytes mixed into a nonce derived from the key and the message, so a weak random source alone cannot leak the key. PSS uses MGF1 with the message hash and a salt as long as the digest, as JWS fixes it.

`crypto.verify` returns `false` for every invalid signature, including one of the wrong length or under an algorithm that does not fit the key, and raises only for arguments of the wrong type.

## RSA

std has RSA verification for PKCS #1 v1.5 and PSS with moduli up to 4096 bits, in `std.crypto.Certificate.rsa`, and constant-time modular arithmetic in `std.crypto.ff`. It has no RSA signing. Its encoders of the padded message are private. Signing is therefore built from those parts.

- The message is encoded by EMSA-PKCS1-v1_5 or EMSA-PSS of RFC 8017, written here from the RFC: a DigestInfo prefix and padding, or a salted hash masked with MGF1.
- The encoded message is raised to the private exponent through the Chinese remainder theorem, with `powWithEncodedExponent` of `std.crypto.ff`, whose running time does not depend on the exponent.
- Every signature is verified with std's verifier before it is returned. A fault during signing, or a key whose primes and exponents do not match its modulus, raises instead of releasing a signature that could leak a prime.

Verification uses std's verifier directly, so the encoders written here are checked against an independent implementation on every signature. The conformance suite also checks the deterministic RS256 signature of RFC 7515 byte for byte and verifies signatures that OpenSSL made.

## Key derivation

`crypto.pbkdf2` is PBKDF2 of RFC 8018 over any HMAC, for formats that require it, such as SCRAM in PostgreSQL. `crypto.hkdf` is HKDF of RFC 5869, extract then expand, which splits one strong secret into independent keys by its `info` argument. Lengths are capped at 1024 bytes for PBKDF2 and at 255 digests for HKDF, the limit of the RFC.

## Authenticated encryption

`crypto.encrypt` and `crypto.decrypt` take the algorithm `"aes-256-gcm"`, a 32-byte key, and a 12-byte nonce from the caller. `encrypt` returns the ciphertext and the 16-byte tag as two vectors, which fits JWE and other formats that carry the nonce and the tag in fields of their own. `decrypt` returns `nil` when the tag does not match, parallel to `crypto.verify` returning `false`, and wipes the plaintext it computed. A nonce must never repeat under one key, which the documentation states with `crypto.random(12)` as the usual source. The algorithm argument leaves room for ChaCha20-Poly1305, which std also has.

## Passwords

`crypto.hashpassword` hashes with Argon2id and a random 16-byte salt, then returns the PHC string, such as `$argon2id$v=19$m=19456,t=2,p=1$...`. The string records the parameters and the salt, so `crypto.verifypassword` needs only the password and the stored string. Verification compares the hashes in constant time.

The default cost is the OWASP recommendation: 19 MiB of memory, 2 iterations, and 1 lane. `options` may set `memory` in KiB, `time` as the iteration count, and `parallelism` as the lane count. A hash made with any parameters verifies, since the string carries them. A malformed hash string raises an error, because it points to corrupt storage rather than a wrong password.

## Random bytes and comparison

`crypto.random` reads the secure random source of the operating system: `arc4random_buf` or `getrandom` on native targets, and `random_get` under WASI. If the source fails, the call raises `secure random source unavailable`. `n` may be any size that fits in memory. A large request reads the source in pieces of 1 MiB, since some sources cap one request. The PRNG behind `math.random` is separate and stays reproducible under `math.randomseed`.

`crypto.equal` takes two strings or vectors. Its running time depends only on their lengths, never on where they differ, so it is the comparison for MACs, tokens, and digests. Inputs of different lengths return `false` at once, since lengths are not secret.

## UUIDs and ULIDs

`crypto.uuid()` returns a version 4 UUID of RFC 9562, 122 random bits, in the canonical lowercase form `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`. `crypto.uuid(7)` returns a version 7 UUID, which starts with the Unix time in milliseconds, so version 7 UUIDs sort by creation time. `crypto.ulid()` returns a ULID: 48 bits of Unix time in milliseconds and 80 random bits, written as 26 characters of Crockford base32 in uppercase. Any version other than 4 or 7 raises `bad argument #1 to 'uuid' (version 4 or 7 expected)`.

Within one Lus state, successive version 7 UUIDs and successive ULIDs strictly increase. When two values fall in the same millisecond, the second one is the first plus one in its random field, which is the monotonic method of RFC 9562 and of the ULID specification. Each worker is a separate state with a sequence of its own.

UUIDs and ULIDs live in `crypto` because their random bits come from the secure random source, which makes them safe to use as unguessable identifiers.

## Permissions

The library requires no permission. Hashing, signing, and comparison are computations on values the program already holds. Reading the secure random source has no effect outside the process, like `math.random` and `os.clock`. A chunk that renounced every permission with `pledge` can therefore still verify a signature or hash a password.

## Zig interface

The runtime verifies release archives and remote module bundles with the same primitives, through three functions of `src/lib/crypto.zig`: `sha256(data) [32]u8`, `ed25519Verify(public, msg, sig) bool` with strict verification, and `secureRandom(l, buf)`. Streaming verification in Zig uses `std.crypto.hash.sha2.Sha256` directly.

## WebAssembly

Every function is available in the WebAssembly build. `crypto.random`, key generation, password salts, UUIDs, and ULIDs read `random_get`, which the JavaScript host in `packages/wasm` implements with `crypto.getRandomValues`. Argon2id runs on one thread there, so `parallelism` above 1 gives the same hash with no speedup.
