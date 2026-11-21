---
name: crypto.verifypassword
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: password
    type: string|vector
  - name: hash
    type: string
returns: boolean
---

Returns `true` when `password` matches `hash`, a PHC string from [`crypto.hashpassword`](/manual/api#crypto.hashpassword), and `false` otherwise.

- `password` is the attempt, a string or a vector.
- `hash` is the stored PHC string.

The function reads the algorithm, the parameters, and the salt from `hash`, recomputes the hash of `password`, and compares the two in constant time. It accepts the three variants `argon2id`, `argon2i`, and `argon2d` of version 19, so it also checks hashes made by other Argon2 implementations.

A wrong password returns `false`. A `hash` that is not a well-formed PHC string raises `bad argument #2 to 'verifypassword' (invalid password hash)`, because it points to corrupt storage rather than a failed attempt. The same error covers a memory cost above 4194304 KiB or more than 65536 passes. Another algorithm raises `bad argument #2 to 'verifypassword' (unsupported password hash 'scrypt')` with its name.

The following example checks a password against a hash from the reference implementation of Argon2.

```lus
local stored = "$argon2i$v=19$m=65536,t=2,p=4$c29tZXNhbHQ$RdescudvJCsgt3ub+b+dWRWJTmaaJObG"
print(crypto.verifypassword("password", stored))   --> true
print(crypto.verifypassword("Password", stored))   --> false
```
