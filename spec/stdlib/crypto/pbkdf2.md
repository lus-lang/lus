---
name: crypto.pbkdf2
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: algorithm
    type: string
  - name: password
    type: string|vector
  - name: salt
    type: string|vector
  - name: iterations
    type: integer
  - name: length
    type: integer
returns: vector
---

Derives a key from a password with PBKDF2 (RFC 8018) and returns `length` bytes as a vector.

- `algorithm` names the HMAC, as for [`crypto.hmac`](/manual/api#crypto.hmac).
- `password` and `salt` are strings or vectors.
- `iterations` is the iteration count, from 1 to 4,294,967,295.
- `length` is the size of the result, from 1 to 1024 bytes.

PBKDF2 is the key derivation of formats that require it, such as SCRAM authentication in PostgreSQL and password-based encryption of old key files. To store passwords, [`crypto.hashpassword`](/manual/api#crypto.hashpassword) is stronger, since Argon2id also costs memory.

An `iterations` or `length` out of range raises `bad argument #4 to 'pbkdf2' (iterations out of range)` or `bad argument #5 to 'pbkdf2' (length out of range)`. The other errors are those of `crypto.hmac`.

The following example derives the first key of RFC 6070.

```lus
local key = crypto.pbkdf2("sha1", "password", "salt", 1, 20)
print(string.transcode(key, "binary", "hex"))  --> 0c60c80f961f0e71f3a9b524af6012062fe037a6
```
