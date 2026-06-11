# lus-install

Sources for the official Lus installers (shipped since 1.6.0).

- **`install.sh`** — the generic UNIX installer. Served verbatim at
  `https://lus.dev/install.sh` by the website (see
  `lus-site/src/pages/install.sh.ts`), so the canonical user command is:

  ```sh
  curl -fsSL https://lus.dev/install.sh | sh
  ```

  POSIX sh only — it must run on every platform Lus supports,
  including the BSDs (where it prints build-from-source guidance
  instead of installing). `scripts/lint.sh` shellchecks it; the
  `install-test.yml` workflow runs it end-to-end against real
  releases on Linux (glibc + musl) and macOS.

- **`lus.iss`** — Inno Setup script for `lus-setup.exe`, the Windows
  installer. Compiled by the `installer` job in
  `.github/workflows/build.yml`, which drops the release `lus.exe`
  next to it, runs ISCC, and round-trips a silent install/uninstall
  as a smoke test. Per-user by default; `/ALLUSERS` installs
  machine-wide.

Local testing:

```sh
sh lus-install/install.sh --dir /tmp/lus-bin              # latest stable
sh lus-install/install.sh --version v1.5.1 --dir /tmp/b   # pinned tag
shellcheck -s sh lus-install/install.sh
```

The Windows installer can only be compiled on Windows (or in CI);
`lus.iss` changes are exercised by the installer job's smoke tests.
