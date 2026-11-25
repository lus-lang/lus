---
name: crypto.importkey
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: data
    type: string|vector|table
returns: userdata
---

Reads an RSA, EC, or Ed25519 key and returns it as a `crypto.key` object.

- A string that starts with `-----BEGIN` is PEM text. The labels `PRIVATE KEY` (PKCS #8), `PUBLIC KEY` (SubjectPublicKeyInfo), `RSA PRIVATE KEY` and `RSA PUBLIC KEY` (PKCS #1), and `EC PRIVATE KEY` (SEC1) are read. A block of EC parameters before the key, which `openssl ecparam -genkey` writes, is skipped.
- A string that starts with `{` is a JSON Web Key as JSON text.
- A table is a JSON Web Key with its members as fields.
- A vector holds the DER bytes of any of the PEM layouts.

RSA keys have a modulus of 2048, 3072, or 4096 bits. EC keys use the curves P-256 and P-384. A JWK has `kty` `"RSA"`, `"EC"`, or `"OKP"` with the curve `"Ed25519"`. A private RSA key carries its primes and CRT values, as every PKCS #1 and PKCS #8 key does. Members of a JWK that hold no key material, such as `alg` and `kid`, are ignored.

A key object has four fields.

- `key.type` is `"rsa"`, `"ec"`, or `"ed25519"`.
- `key.private` is `true` for a private key.
- `key.bits` is the size of an RSA modulus, and `nil` for other keys.
- `key.curve` is `"P-256"`, `"P-384"`, or `"Ed25519"`, and `nil` for RSA.

It has two methods.

- `key:public()` returns the public half of the key as a new key object.
- `key:export([format])` writes the key. `"pem"`, the default, returns PEM text in PKCS #8 for a private key and in SubjectPublicKeyInfo for a public key, the layouts of `openssl pkey`. `"der"` returns the same structure as a vector. `"jwk"` returns a table of JWK members.

Data that is not a key raises `invalid key`. An encrypted PEM key raises `encrypted keys are not supported`. Another algorithm, curve, or PEM label raises `unsupported key type`. An RSA modulus of another size raises `RSA keys must have 2048, 3072, or 4096 bits`. A JWK whose public part does not match its private part raises `public and private parts of the key do not match`. A string that is neither PEM nor JSON raises `bad argument #1 to 'importkey' (PEM text or JWK expected)`. A JWK member that is not a string raises `bad argument #1 to 'importkey' (JWK member 'n' must be a string)`.

The following example reads an Ed25519 key from RFC 8410 and writes its public half as PEM and as a JWK.

```lus
local key = crypto.importkey([[
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp+K06/nwoy/HU++CXqI9EdVhC
-----END PRIVATE KEY-----
]])
print(key.type, key.private)  --> ed25519  true
io.write(key:public():export())
--> -----BEGIN PUBLIC KEY-----
--> MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=
--> -----END PUBLIC KEY-----
print(key:public():export("jwk").x)  --> Gb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE
```

[`crypto.sign`](/manual/api#crypto.sign) and [`crypto.verify`](/manual/api#crypto.verify) take key objects.
