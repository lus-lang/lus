---
name: crypto.encrypt
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: algorithm
    type: string
  - name: key
    type: vector
  - name: nonce
    type: vector
  - name: plaintext
    type: string|vector
  - name: aad
    type: string|vector
    optional: true
returns:
  - name: ciphertext
    type: vector
  - name: tag
    type: vector
---

Encrypts and authenticates `plaintext` and returns the ciphertext and the authentication tag as two vectors.

- `algorithm` is `"aes-256-gcm"`.
- `key` is a vector of 32 bytes.
- `nonce` is a vector of 12 bytes.
- `plaintext` is a string or a vector.
- `aad` is optional additional data, such as a header or a record ID, which the tag covers without encrypting it.

The ciphertext is as long as the plaintext. The tag is 16 bytes. [`crypto.decrypt`](/manual/api#crypto.decrypt) needs the key, the nonce, the ciphertext, the tag, and the same `aad`, so a program stores or sends the nonce and the tag with the ciphertext.

A nonce must never repeat under one key. Two messages encrypted with the same key and nonce reveal the difference of their plaintexts and let an attacker forge tags. [`crypto.random(12)`](/manual/api#crypto.random) is the usual source of a nonce, which is safe for up to about four billion messages per key.

A `key` or `nonce` of the wrong size raises `bad argument #2 to 'encrypt' (32-byte vector expected)` or `bad argument #3 to 'encrypt' (12-byte vector expected)`. Another algorithm raises `bad argument #1 to 'encrypt' (invalid option 'aes-128-gcm')`.

The following example encrypts a session cookie with a fresh nonce and decrypts it.

```lus
local key = crypto.random(32)
local nonce = crypto.random(12)
local ct, tag = crypto.encrypt("aes-256-gcm", key, nonce, '{"user":42}', "session")
print(#ct, #tag)   --> 11  16
local plain = crypto.decrypt("aes-256-gcm", key, nonce, ct, tag, "session")
print(vector.tostring(plain))   --> {"user":42}
```
