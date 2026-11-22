---
name: crypto.hasher
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: algorithm
    type: string
returns: userdata
---

Returns a new hasher, a userdata that computes a digest over data added in pieces.

- `algorithm` is `"sha256"`, `"sha384"`, `"sha512"`, `"sha1"`, or `"md5"`, as for [`crypto.hash`](/manual/api#crypto.hash).

A hasher has two methods.

- `hasher:update(data)` adds the bytes of `data`, a string or a vector, and returns the hasher, so calls chain. A string contributes its WTF-8 bytes. A `data` that is neither a string, a number, nor a vector raises `bad argument #1 to 'update' (string or vector expected, got table)` with its type.
- `hasher:digest()` returns the digest of every byte added so far, as a vector. It leaves the hasher unchanged, so more data may follow and a later `digest` covers all of it.

The digest of data added in any number of pieces equals the digest that `crypto.hash` returns for the same bytes in one string or vector. A program reads a large file in blocks and feeds each block to a hasher, so it never holds the whole file in memory. Calling a method on a value that is not a hasher raises `bad argument #1 to 'update' (crypto.hasher expected, got number)` with its type, or the same error for `digest`. An unknown algorithm raises `bad argument #1 to 'hasher' (invalid option 'sha3')`. A hasher is userdata, so a worker message cannot carry it.

The following example hashes a message in two pieces, then adds a third piece and hashes again.

```lus
local h = crypto.hasher("sha256")
h:update("a"):update(vector.fromstring("b"))
local whole = crypto.hash("sha256", "ab")
print(crypto.equal(h:digest(), whole))   --> true

h:update("c")
print(string.transcode(h:digest(), "binary", "hex"))
--> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

The [cryptography](/manual/crypto#digests) page shows a hasher that checks a file read in blocks.
