---
name: crypto.hash
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: algorithm
    type: string
  - name: data
    type: string|vector
returns: vector
---

Returns the digest of `data` under a hash function, as a vector.

- `algorithm` is `"sha256"`, `"sha384"`, `"sha512"`, or `"sha1"`.
- `data` is the input. A string contributes its WTF-8 bytes. A number is converted to its textual form first.

The result is a vector of 32 bytes for SHA-256, 48 bytes for SHA-384, 64 bytes for SHA-512, and 20 bytes for SHA-1. [`string.transcode`](/manual/api#string.transcode) writes it as hex or base64 text. SHA-1 is broken for collision resistance, so it is for formats that require it, such as git object names, and never for new signatures.

An unknown algorithm raises `bad argument #1 to 'hash' (invalid option 'md5')`. A `data` that is neither a string, a number, nor a vector raises `bad argument #2 to 'hash' (string or vector expected, got table)` with its type.

The following example hashes the test message of FIPS 180 with each algorithm and writes the digests as text.

```lus
local function hex(v)
    return string.transcode(v, "binary", "hex")
end
print(hex(crypto.hash("sha256", "abc")))
--> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
print(hex(crypto.hash("sha1", "abc")))       --> a9993e364706816aba3e25717850c26c9cd0d89d
print(#crypto.hash("sha512", "abc"))         --> 64
print(string.transcode(crypto.hash("sha256", ""), "binary", "base64"))
--> 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
```

[`crypto.hasher`](/manual/api#crypto.hasher) computes the same digests over data that arrives in pieces. [`crypto.hmac`](/manual/api#crypto.hmac) computes a keyed digest with the same algorithms.
