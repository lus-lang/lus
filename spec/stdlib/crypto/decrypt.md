---
name: crypto.decrypt
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
  - name: ciphertext
    type: string|vector
  - name: tag
    type: vector
  - name: aad
    type: string|vector
    optional: true
returns: vector|nil
---

Checks and decrypts a ciphertext from [`crypto.encrypt`](/manual/api#crypto.encrypt) and returns the plaintext as a vector, or `nil` when the check fails.

- `algorithm` is `"aes-256-gcm"`.
- `key` is the vector of 32 bytes that encrypted the data.
- `nonce` is the vector of 12 bytes it was encrypted with.
- `ciphertext` is a string or a vector.
- `tag` is the vector of 16 bytes that `crypto.encrypt` returned.
- `aad` is the additional data given to `crypto.encrypt`, if any.

The function returns `nil` when the ciphertext, the tag, the nonce, the key, or the additional data differs from what was encrypted, so a tampered message never yields a plaintext. It raises only for an argument of the wrong type or size, with the errors of `crypto.encrypt` and `bad argument #5 to 'decrypt' (16-byte vector expected)` for the tag.

The following example decrypts a message, then the same message with one bit of the ciphertext flipped.

```lus
local key, nonce = crypto.random(32), crypto.random(12)
local ct, tag = crypto.encrypt("aes-256-gcm", key, nonce, "attack at dawn")
print(vector.tostring(crypto.decrypt("aes-256-gcm", key, nonce, ct, tag)))   --> attack at dawn
vector.set(ct, 0, vector.get(ct, 0) ~ 1)
print(crypto.decrypt("aes-256-gcm", key, nonce, ct, tag))   --> nil
```
