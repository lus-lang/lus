---
name: crypto.random
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: n
    type: integer
returns: vector
---

Returns a new vector of `n` bytes read from the secure random source of the operating system.

- `n` is the number of bytes, from 0 to 1048576.

The source is `arc4random_buf` or `getrandom` on native targets and the `random_get` call of WASI in the WebAssembly build. Every call reads the source afresh, so the bytes are suitable for keys, salts, nonces, and session tokens. [`math.random`](/manual/api#math.random) is a separate generator that `math.randomseed` makes reproducible, so it is for simulations and never for secrets.

An `n` outside the range raises `bad argument #1 to 'random' (size out of range)`. If the operating system cannot supply random bytes, the call raises `secure random source unavailable`.

The following example makes a session token of 32 random bytes and writes it as hex.

```lus
local token = string.transcode(crypto.random(32), "binary", "hex")
print(#token)          --> 64
print(#crypto.random(0))   --> 0
```
