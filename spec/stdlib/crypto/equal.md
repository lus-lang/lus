---
name: crypto.equal
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: a
    type: string|vector
  - name: b
    type: string|vector
returns: boolean
---

Returns `true` when `a` and `b` hold the same bytes and `false` otherwise, in time that depends only on their lengths.

- `a` and `b` are strings or vectors, in any combination. A string contributes its WTF-8 bytes. A number is converted to its textual form first.

The comparison reads every byte even after a difference, so an attacker who measures the time of a comparison learns nothing about where a guess goes wrong. Use it to check MACs, tokens, and digests against a secret value. Inputs of different lengths return `false` at once, because lengths are not secret. A value that is neither a string, a number, nor a vector raises `bad argument #1 to 'equal' (string or vector expected, got table)` with its type, or the same error for argument 2.

The following example compares a string with a vector that holds the same bytes, and two strings that differ.

```lus
print(crypto.equal("token", vector.fromstring("token")))  --> true
print(crypto.equal("token", "tokem"))  --> false
print(crypto.equal("token", "tok"))  --> false
```
