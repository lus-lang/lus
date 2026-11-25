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

## Shipping a release

`.github/workflows/ship.yml` releases the version that
`runtime/build.zig.zon` holds, `X.Y.Z-dev`, from one start in the Actions
tab. It checks that CI and the nightly tests passed on the commit, then
builds and tests every target through `release.yml`, pushes the release
commit and the tag `vX.Y.Z`, publishes the GitHub release as the latest,
signs the release index, publishes the VSIX to Open VSX and `lus-wasm` to
npm, and pushes a commit that starts `X.(Y+1).0-dev`. The release commit
dates the section of `CHANGELOG.md` and adds it to the news of the site
(`tools/release-version.mjs`).

The input `dry_run` is set by default. A dry run builds and checks
everything and publishes nothing, and its summary lists each gate that a
real release would stop at. A real release needs the secrets
`LUS_RELEASE_SIGNING_SEED`, `LUS_RELEASE_SIGNING_KEY_ID`, `OVSX_PAT`, and
`NPM_TOKEN`, the file `keys.json`, a branch that the workflow token may
push to, and the environment `release`. The job that tags and publishes
the release runs in that environment, so a real release waits for one of
its reviewers to approve. `release.yml` attests the provenance of every
file it builds, which `gh attestation verify FILE --repo lus-lang/lus`
checks, and a dry run attests nothing.
