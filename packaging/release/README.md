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
`runtime/build.zig.zon` holds, `X.Y.Z-dev`, from one start in the
Actions tab. Its first job stops a real release unless CI passed on the
commit, the last nightly run passed, the tag is new, and every secret is
set. The run then executes every job of `full.yml` and runs
`release.yml`, which tests the commit and builds every target. Its
signing jobs run in the environment `release`, so they wait for a
reviewer of the environment to approve. They sign and notarize the macOS
binaries and sign the Windows binaries and the installer. `release.yml`
then writes the archives from the signed files and attests every file.
Once `full.yml` passes as well, the run pushes the tag `vX.Y.Z`,
publishes the GitHub release as the latest, signs the release index, and
publishes the VSIX to Open VSX and the Visual Studio Marketplace. Last,
it opens a pull request that dates the section of `CHANGELOG.md`, adds
that section to the news of the site, and sets the version to
`X.(Y+1).0-dev`. `tools/release-version.mjs` writes both the release
commit and the changes of the pull request.

The tag points to the release commit, which sets the version to `X.Y.Z`
and whose parent is the commit of the run. No branch holds the release
commit, so the branch that the workflow runs on changes only when the
pull request merges. A published release is immutable, so the workflow
creates each release as a draft, uploads all its assets, and publishes
it last. `https://lus.dev/releases/` redirects to the branch
`release-index`, which holds the release index.

The input `dry_run` is set by default. A dry run builds and checks
everything, attests and publishes nothing, and lists in its summary each
gate that a real release would stop at.

Before the first real release, set up the following in the repository.

- **The Lus app**, the GitHub App of the project. Its permissions must
  include read and write access to contents and to pull requests. Add it
  as a bypass actor of the ruleset of `v*` tags, which lets it create the
  tag of a release and of each unstable build. Store its identifier and a
  private key as the secrets `LUS_APP_ID` and `LUS_APP_PRIVATE_KEY`. Each
  job mints a token that has only the permissions the job needs.
- **The environment `release`**, whose reviewers approve each release.
  It also holds the settings of code signing, which the next section
  lists.
- **The signing key of the release index.** Commit the key list
  `keys.json`, which the root key signs. Store the seed and the
  identifier of the signing key as `LUS_RELEASE_SIGNING_SEED` and
  `LUS_RELEASE_SIGNING_KEY_ID`.
- **The publishing token** `OVSX_PAT` for Open VSX.
- **The publisher of the Visual Studio Marketplace**, which the section
  "The Visual Studio Marketplace" describes.

## Code signing

The signing jobs of `release.yml` read their settings from the
environment `release`. A signing job signs its files when all of its
settings are set. In the environment it stops when one of them is
missing, which keeps a real release from shipping unsigned files. A dry
run and an unstable build run in no environment, so their binaries stay
unsigned.

`sign-macos` signs `bin/lus` and `lib/liblus.dylib` of both macOS
targets on Linux with `rcodesign`, with the hardened runtime and a
secure timestamp. `bin/lus` also gets the entitlements of
`lus.entitlements`, which let the JIT map memory that is writable and
executable. The job then submits the signed files to the notary service
of Apple with the App Store Connect API and waits for the result. It
reads these secrets of the environment.

- `APPLE_CERT_P12`, the Developer ID Application certificate and its
  private key as a PKCS#12 file, encoded in base64.
- `APPLE_CERT_PASSWORD`, the password of that file.
- `APPLE_API_KEY_P8`, the text of the private key of an App Store
  Connect API key, the `.p8` file that App Store Connect offers once.
- `APPLE_API_KEY_ID`, the identifier of that key.
- `APPLE_API_ISSUER`, the issuer identifier of the team that owns the
  key.

`sign-windows` signs `bin/lus.exe` and `bin/lus.dll` of both Windows
targets with `jsign` and a certificate of Azure Artifact Signing. Inno
Setup then signs the uninstaller and `lus-setup.exe` with the same
command. The job logs in to Azure with the OpenID Connect token of the
run, so the repository stores no Azure secret. It reads these variables
of the environment.

- `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_SUBSCRIPTION_ID`, the
  tenant, the app registration, and the subscription. The app
  registration needs a federated credential for the subject
  `repo:lus-lang/lus:environment:release` and a role assignment that
  lets it sign with the certificate profile.
- `AZURE_SIGNING_ENDPOINT`, the endpoint of the region of the account,
  such as `https://eus.codesigning.azure.net`.
- `AZURE_SIGNING_ACCOUNT`, the name of the Artifact Signing account.
- `AZURE_SIGNING_PROFILE`, the name of its certificate profile.

`lus-runtime` keeps the signature of the build on both systems, because
`lus build` writes its executables from it. `release.yml` pins
`rcodesign` and `jsign` by the SHA-256 digest of their release files.

## The Visual Studio Marketplace

The job `marketplace` of `publish-vscode.yml` publishes the VSIX with
the trusted publishing of the Marketplace. `vsce publish --oidc` exchanges
the OpenID Connect token of the job for a Marketplace credential that
lasts 15 minutes, so the repository stores no Marketplace token and no
Azure identity takes part. The job runs in the environment `release`, so
it waits for a reviewer of the environment like the signing jobs. It
publishes only when the environment sets the variable
`MARKETPLACE_PUBLISHER` to the publisher that the VSIX names, which is
`lus` in `packages/vscode/package.json`.
`packaging/release/vsce/package-lock.json` pins `vsce` and each of its
dependencies by digest.

Set up the publisher once, with these steps.

1. Sign in at `https://marketplace.visualstudio.com/manage` with the
   Microsoft account that is to own the publisher, and select **Create
   publisher**.
2. Enter `lus` as the ID and `Lus` as the name, then select **Create**.
   The ID is the `publisher` of `packages/vscode/package.json` and the
   first part of the identifier `lus.lus`. It cannot change once the
   publisher exists. When the form reports the ID as taken, choose
   another ID and change `publisher` in `packages/vscode/package.json` to
   match, which also changes the namespace on Open VSX.
3. On the page of the publisher, open **Trusted Publishing** and create
   a policy with the repository owner `lus-lang`, the repository `lus`,
   the workflow `ship.yml`, and the environment `release`. Create a
   second policy that names the workflow `publish-vscode.yml`. A release
   calls `publish-vscode.yml` from `ship.yml`. The documentation of the
   Marketplace does not say which of the two files a policy matches, so
   the two policies cover both. A manual run of `publish-vscode.yml`
   matches the second policy.
4. In the environment `release` of the repository, set the variable
   `MARKETPLACE_PUBLISHER` to `lus`.

## Attestations

`release.yml` attests the provenance of every file it builds.
`gh attestation verify FILE --repo lus-lang/lus` checks the attestation
of a file.
