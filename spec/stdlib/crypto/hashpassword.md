---
name: crypto.hashpassword
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: password
    type: string|vector
  - name: options
    type: table
    optional: true
returns: string
---

Hashes a password with Argon2id and returns the hash in PHC string format.

- `password` is a string or a vector. A string contributes its WTF-8 bytes.
- `options` is a table with the optional integer fields `memory`, the memory cost in KiB, `time`, the number of passes, and `parallelism`, the number of lanes.

The defaults are the recommendation of OWASP: `memory = 19456`, `time = 2`, and `parallelism = 1`. Higher costs make each guess of an attacker slower and the hash slower to compute. `parallelism` must be from 1 to 255, `time` from 1 to 65536, and `memory` from 8 times `parallelism` to 4194304. A value outside its range raises `bad argument #2 to 'hashpassword' (option 'memory' out of range)` with the name of the option, and a value that is not an integer raises `bad argument #2 to 'hashpassword' (option 'memory' must be an integer)`.

Each call draws a new salt of 16 bytes from the secure random source, so hashing the same password twice gives two different strings. The result has the form `$argon2id$v=19$m=19456,t=2,p=1$` followed by the salt and a hash of 32 bytes, both in base64 without padding. It records every parameter, so [`crypto.verifypassword`](/manual/api#crypto.verifypassword) needs only the password and the string. Store the string as it is.

The following example hashes a password and checks two attempts against it.

```lus
local stored = crypto.hashpassword("correct horse battery staple")
print(stored:sub(1, 30))                                           --> $argon2id$v=19$m=19456,t=2,p=1
print(crypto.verifypassword("correct horse battery staple", stored))   --> true
print(crypto.verifypassword("Tr0ub4dor&3", stored))                    --> false
```
