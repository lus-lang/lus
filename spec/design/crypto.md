# Cryptography

The `crypto` library gives Lus programs the primitives that package signing, token signing, and password storage need: the SHA-2 hash functions SHA-256, SHA-384, and SHA-512, HMAC, Ed25519 signatures, secure random bytes, constant-time comparison, and Argon2id password hashing. It also generates UUIDs and ULIDs. The runtime uses the same code to verify remote modules and Lus releases, which are signed with Ed25519 over SHA-256 digests.

Every primitive comes from Zig's `std.crypto`. The library adds argument checking, the conversion between Lus values and bytes, and the text formats of UUIDs and ULIDs. It contains no cryptographic code of its own.

## Functions

The library is the global table `crypto` with twelve functions.

| Function | Result |
|---|---|
| `crypto.hash(algorithm, data)` | The digest of `data`. |
| `crypto.hasher(algorithm)` | A streaming hasher with the methods `update(data)` and `digest()`. |
| `crypto.hmac(algorithm, key, data)` | The HMAC of `data` under `key`. |
| `crypto.random(n)` | A vector of `n` bytes from the operating system's secure random source. |
| `crypto.equal(a, b)` | `true` when `a` and `b` hold the same bytes, compared in constant time. |
| `crypto.keypair([seed])` | An Ed25519 secret key and its public key. |
| `crypto.sign(secret, message)` | The Ed25519 signature of `message`. |
| `crypto.verify(public, message, signature)` | `true` when `signature` is a valid signature of `message` by `public`. |
| `crypto.hashpassword(password [, options])` | An Argon2id hash of `password` in PHC string format. |
| `crypto.verifypassword(password, hash)` | `true` when `password` matches `hash`. |
| `crypto.uuid([version])` | A UUID of version 4, the default, or version 7, as a string. |
| `crypto.ulid()` | A ULID as a string. |

`algorithm` is `"sha256"`, `"sha384"`, `"sha512"`, or `"sha1"`. SHA-1 is broken for collision resistance, so it exists for interoperability with formats that require it, such as git object names. Any other name raises `bad argument #1 to 'hash' (invalid option 'md5')`.

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

## Passwords

`crypto.hashpassword` hashes with Argon2id and a random 16-byte salt, then returns the PHC string, such as `$argon2id$v=19$m=19456,t=2,p=1$...`. The string records the parameters and the salt, so `crypto.verifypassword` needs only the password and the stored string. Verification compares the hashes in constant time.

The default cost is the OWASP recommendation: 19 MiB of memory, 2 iterations, and 1 lane. `options` may set `memory` in KiB, `time` as the iteration count, and `parallelism` as the lane count. A hash made with any parameters verifies, since the string carries them. A malformed hash string raises an error, because it points to corrupt storage rather than a wrong password.

## Random bytes and comparison

`crypto.random` reads the secure random source of the operating system: `arc4random_buf` or `getrandom` on native targets, and `random_get` under WASI. If the source fails, the call raises `secure random source unavailable`. `n` must be between 0 and 2^20. The PRNG behind `math.random` is separate and stays reproducible under `math.randomseed`.

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
