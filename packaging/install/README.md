# lus-install

Sources for the official Lus installers. Both install from the release
archives that `.github/workflows/release.yml` publishes for every `v2.*`
tag. Each archive is named `lus-<tag>-<target>.tar.gz`, or `.zip` for
Windows, and holds the install prefix: `bin/lus`, the embedding libraries
in `lib`, `include/lus.h`, and the license texts. The release lists the
SHA-256 digest of every asset in `SHA256SUMS`.

- **`install.sh`** is the installer for Linux and macOS. The website serves
  it verbatim at `https://lus.dev/install.sh` (see
  `packages/site/src/pages/install.sh.ts`), so the canonical user command is
  the following one.

  ```sh
  curl -fsSL https://lus.dev/install.sh | sh
  ```

  The script picks the archive for the host. Linux hosts with glibc or musl
  both get the static `x86_64-linux-musl`, `aarch64-linux-musl`, or
  `arm-linux-musleabihf` build, and macOS hosts get `aarch64-macos` or
  `x86_64-macos`. It downloads `SHA256SUMS` first. A pinned version
  (`--version v2.0.0` or `LUS_VERSION`) names the archive directly. For
  the latest release, the one `lus-v*-<target>.tar.gz` entry in the
  manifest of the latest release gives the archive name and so the tag.
  The script verifies the archive against its digest before unpacking it
  and then installs `bin/lus` with an atomic rename.
  `LUS_RELEASE_BASE_URL` points it at an HTTPS mirror of one release. The
  script is POSIX sh, because it also runs on the BSDs and illumos, where
  it prints build-from-source guidance.

  The script installs into the Lus home, the directory that `lus version`
  manages (`spec/tools/version.md`). It is `$LUS_HOME`, by default
  `~/.lus`, and `--home DIR` selects another. The archive goes to
  `versions/<version>` with a `channel` file, `bin/lus` links to it, and
  `default` names it, each through a rename. The script then adds
  `$LUS_HOME/bin` to `PATH` in the profile of the user's shell, once,
  unless that directory is already on `PATH` or `--no-modify-path` (or
  `LUS_NO_MODIFY_PATH=1`) is given. No step needs `sudo`.

- **`lus.iss`** is the Inno Setup script for `lus-setup.exe`, the Windows
  installer. The `windows-installer` job of the release workflow unpacks
  the `x86_64-windows` archive into `packaging/install/archive`, compiles
  the script with ISCC, and round-trips a silent install and uninstall as a
  smoke test before the installer joins the draft release. The installer
  lays the archive out as the Lus home: it copies the archive into
  `versions\<version>`, copies `lus.exe` to `bin`, writes `default` and
  the `channel` file, and adds `bin` to `PATH`. Installation is per user
  by default, into `%LOCALAPPDATA%\lus`, the default Lus home on Windows.
  `/ALLUSERS` selects a machine-wide installation in Program Files, which
  `lus version` manages only when `LUS_HOME` names it.

## Testing

`install.test.mjs` serves a release from a local HTTPS server, with the
certificate in `fixtures`. The release holds an archive built from
`runtime/zig-out`, so the runtime is built first. The test installs from a
pinned version and from the latest release, runs the installed `lus`, and
checks that a tampered archive and a release without an archive for the
host are both rejected. It also checks the layout of the Lus home, that
the installed `lus version` lists what the script installed, and that the
shell profile gains one `PATH` line.

```sh
(cd runtime && zig build -Doptimize=ReleaseSafe)
node --test packaging/install/install.test.mjs
sh -n packaging/install/install.sh
shellcheck -s sh packaging/install/install.sh
```

`LUS_INSTALL_TEST_PREFIX` selects another install prefix, such as one from
`zig build -Dtarget=... --prefix DIR`. The release workflow runs the test
before it builds the archives, and CI runs it on Linux and macOS.

The Windows installer compiles only on Windows, so the release workflow
exercises `lus.iss` changes. To try one by hand on Windows, unpack an
`x86_64-windows` archive into `packaging/install/archive` and run
`ISCC.exe /DAppVer=2.0.0 /DNumVer=2.0.0 packaging\install\lus.iss`.
