# lus-install

Sources for the official Lus installers (shipped since 1.6.0).

- **`install.sh`**: the generic UNIX installer. Served verbatim at
  `https://lus.dev/install.sh` by the website (see
  `packages/site/src/pages/install.sh.ts`), so the canonical user command is:

  ```sh
  curl -fsSL https://lus.dev/install.sh | sh
  ```

  POSIX sh only, because it must run on every platform Lus supports,
  including the BSDs, where it prints build-from-source guidance.
  `scripts/lint.sh` shellchecks it. The
  `install-test.yml` workflow resolves a published unstable release
  containing both tools and runs it end-to-end on Linux with glibc,
  Linux with musl, and macOS.

- **`lus.iss`**: Inno Setup script for `lus-setup.exe`, the Windows
  installer. Compiled by the `windows-installer` job in
  `.github/workflows/build.yml`, which supplies the release `lus.exe`
  and `lusc.exe`, license notices, and supporting files. The job runs
  ISCC and round-trips a silent install and uninstall as a smoke test.
  Installation is per-user by default. `/ALLUSERS` selects a
  machine-wide installation.

Local testing:

```sh
sh packaging/install/install.sh --help
sh -n packaging/install/install.sh
shellcheck -s sh packaging/install/install.sh
```

The Windows installer is compiled on Windows or in CI. The installer
job exercises `lus.iss` changes with its smoke tests.
