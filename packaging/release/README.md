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
builds, tests, and attests every target through `release.yml`. After a
reviewer of the environment `release` approves, it pushes the tag `vX.Y.Z`,
publishes the GitHub release as the latest, signs the release index,
and publishes the VSIX to Open VSX and `lus-wasm` to npm. Last, it opens a
pull request that dates the section of `CHANGELOG.md`, adds it to the news
of the site, and starts `X.(Y+1).0-dev` (`tools/release-version.mjs`).

The tag points to the release commit, whose parent is the commit of the
run. That commit sets the version to `X.Y.Z` and no branch holds it, so
the branch changes only through the pull request. A published release is
immutable, so the workflow creates each release as a draft with all its
assets and publishes it last. The release index lives on the branch
`release-index`, which `https://lus.dev/releases/` redirects to.

The input `dry_run` is set by default. A dry run builds and checks
everything, attests and publishes nothing, and lists in its summary each
gate that a real release would stop at.

A real release needs these settings of the repository.

- The Lus app, the GitHub App of the project, with read and write access
  to contents and to pull requests among its permissions. The ruleset of
  `v*` tags lists it as a bypass actor, which lets it create the tag of a
  release and of each unstable build. Each job asks for a token with only
  the permissions it needs. Its identifier and a private key are the
  secrets `LUS_APP_ID` and `LUS_APP_PRIVATE_KEY`.
- The environment `release`, whose reviewers approve each release.
- The secrets `LUS_RELEASE_SIGNING_SEED` and `LUS_RELEASE_SIGNING_KEY_ID`
  with the file `keys.json`, `OVSX_PAT`, and `NPM_TOKEN`.

`release.yml` attests the provenance of every file it builds, which
`gh attestation verify FILE --repo lus-lang/lus` checks.
