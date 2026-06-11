/*
** Canonical install commands — imported by the homepage and
** getting-started.mdx so the surfaces can never drift.
*/

/*
** The one-line installer for Linux and macOS. Serves
** lus-install/install.sh (repo root) via src/pages/install.sh.ts;
** on platforms without prebuilt binaries it prints build-from-source
** guidance instead of installing.
*/
export const INSTALL_SH = `curl -fsSL https://lus.dev/install.sh | sh`

/*
** The Windows installer: per-user by default (no admin prompt),
** puts lus on PATH; /ALLUSERS from an elevated prompt installs
** machine-wide.
*/
export const WINDOWS_INSTALLER_URL =
  "https://github.com/lus-lang/lus/releases/latest/download/lus-setup.exe"

/*
** Manual downloads — the bare binary, no installer.
*/
export const INSTALL_LINUX = `# glibc; use lus-linux-musl on Alpine
curl -LO https://github.com/lus-lang/lus/releases/latest/download/lus-linux
chmod +x lus-linux
./lus-linux -v`

export const INSTALL_MACOS = `# Apple Silicon
curl -LO https://github.com/lus-lang/lus/releases/latest/download/lus-macos
chmod +x lus-macos
xattr -d com.apple.quarantine lus-macos   # clear Gatekeeper quarantine
./lus-macos -v`

export const INSTALL_WINDOWS = `curl.exe -LO https://github.com/lus-lang/lus/releases/latest/download/lus-windows.exe
.\\lus-windows.exe -v`
