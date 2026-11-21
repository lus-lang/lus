# Release metadata

`manifest.json` pins the digests of release components that the release
workflow builds and checks.

`keys.json` is the key list of the Lus release process, which `lus version`
reads at `https://lus.dev/releases/keys.json` (`spec/tools/version.md`). The
root key signs it, and the public half of the root key is
`lus_release` in `runtime/src/release_keys.zig`. The root key stays offline.
`release-index.yml` signs the release index with a signing key from the list,
whose seed is the repository secret `LUS_RELEASE_SIGNING_SEED` and whose
identifier is `LUS_RELEASE_SIGNING_KEY_ID`.

The commands below create the keys and the list. Run them on an offline
machine and keep `root.seed` there.

```sh
node tools/release-index.mjs keygen > root.json
node tools/release-index.mjs keygen > signing.json
node -p 'require("./root.json").seed' > root.seed
node tools/release-index.mjs keylist --root-seed root.seed --out packaging/release/keys.json \
  --key "lus-release-1=$(node -p 'require("./signing.json").public')"
```

The public key of `root.json` goes into `runtime/src/release_keys.zig`, and
the seed of `signing.json` and its identifier `lus-release-1` go into the
repository secrets. A new signing key needs only a new `keys.json`, which
the root key signs, so every installed `lus` keeps accepting the index.
