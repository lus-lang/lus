#!/bin/sh
# The Lus installer — served at https://lus.dev/install.sh
#
# Downloads the prebuilt binary for this machine from a GitHub
# release of lus-lang/lus and installs it as `lus`.
#
#   curl -fsSL https://lus.dev/install.sh | sh
#
# The script writes exactly one file: $INSTALL_DIR/lus. sudo is used
# only for that copy, and only when the directory isn't writable.
# Downloads are verified against the release's SHA256SUMS asset
# (published since 1.6.0).
#
# Platforms without prebuilt binaries (BSDs, illumos, Intel Macs,
# non-x86_64 Linux) get pointed at the build-from-source manual.

set -u

REPO="lus-lang/lus"
COMPILING_URL="https://lus.dev/manual/compiling"

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
The Lus installer.

Usage:
  curl -fsSL https://lus.dev/install.sh | sh
  sh install.sh [--version TAG] [--dir DIR]

Options:
  --version TAG   install a specific release: v1.6.0, 1.6.0, or an
                  unstable-<sha> pre-release tag (env: LUS_VERSION)
  --dir DIR       install directory, default /usr/local/bin
                  (env: LUS_INSTALL_DIR)
  -h, --help      show this help

When piping to sh, pass options as environment variables:
  LUS_VERSION=v1.6.0 curl -fsSL https://lus.dev/install.sh | sh
EOF
}

# fetch URL DEST — curl preferred, wget fallback. Both fail on HTTP
# errors so a 404 page can't masquerade as a binary.
fetch() {
  if need curl; then
    curl -fsSL --proto '=https' -o "$2" "$1"
  elif need wget; then
    wget -q -O "$2" "$1"
  else
    die "neither curl nor wget is available"
  fi
}

# No prebuilt binary for this platform: point at the manual, which
# documents dependencies and build steps per platform.
unsupported() {
  printf '%s\n' \
    "No prebuilt Lus binaries are published for $1." \
    "" \
    "Lus builds from source in a couple of minutes; the manual" \
    "covers the dependencies and build steps for your platform:" \
    "  $COMPILING_URL" >&2
  exit 1
}

# Sets OS and ASSET for this machine, or exits with guidance.
detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)

  case "$OS" in
    Linux)
      case "$ARCH" in
        x86_64)
          if [ -e /lib/ld-musl-x86_64.so.1 ] || ldd --version 2>&1 | grep -qi musl; then
            ASSET="lus-linux-musl"
          else
            ASSET="lus-linux"
          fi
          ;;
        *) unsupported "Linux on $ARCH" ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        arm64) ASSET="lus-macos" ;;
        x86_64)
          # An x86_64 shell under Rosetta is still an Apple Silicon
          # machine; the arm64 binary is the right one.
          if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
            ASSET="lus-macos"
          else
            unsupported "Intel Macs (prebuilt lus-macos is Apple Silicon only)"
          fi
          ;;
        *) unsupported "macOS on $ARCH" ;;
      esac
      ;;
    FreeBSD)   unsupported "FreeBSD" ;;
    OpenBSD)   unsupported "OpenBSD" ;;
    NetBSD)    unsupported "NetBSD" ;;
    DragonFly) unsupported "DragonFly BSD" ;;
    SunOS)     unsupported "illumos/Solaris" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "on Windows, use the installer instead:
  https://github.com/$REPO/releases/latest/download/lus-setup.exe"
      ;;
    *) unsupported "$OS" ;;
  esac
}

# verify_checksum FILE ASSET URLBASE — check FILE against the
# release's SHA256SUMS. Missing checksums (releases before 1.6.0)
# warn and continue; a mismatch is fatal.
verify_checksum() {
  if ! fetch "$3/SHA256SUMS" "$WORKDIR/SHA256SUMS" 2>/dev/null; then
    warn "this release publishes no SHA256SUMS (added in 1.6.0) — skipping verification"
    return 0
  fi

  expected=$(awk -v name="$2" '$2 == name || $2 == "*" name { print $1; exit }' "$WORKDIR/SHA256SUMS")
  if [ -z "$expected" ]; then
    warn "no SHA256SUMS entry for $2 — skipping verification"
    return 0
  fi

  if need sha256sum; then
    actual=$(sha256sum "$1" | awk '{ print $1 }')
  elif need shasum; then
    actual=$(shasum -a 256 "$1" | awk '{ print $1 }')
  else
    warn "no sha256sum or shasum on this system — skipping verification"
    return 0
  fi

  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $2
  expected: $expected
  actual:   $actual
The download may be corrupted or tampered with. Not installing."
  fi
  info "checksum verified"
}

# Run a command, under sudo when install_binary decided it's needed.
run() {
  if [ -n "$SUDO" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Place the downloaded binary as $INSTALL_DIR/lus (copy to a
# temporary name, then atomic rename — safe over a running lus).
install_binary() {
  SUDO=""
  if ! mkdir -p "$INSTALL_DIR" 2>/dev/null || [ ! -w "$INSTALL_DIR" ]; then
    if [ "$(id -u)" = "0" ]; then
      die "cannot write to $INSTALL_DIR"
    fi
    if ! need sudo; then
      die "cannot write to $INSTALL_DIR and sudo is unavailable
Re-run with --dir DIR (or LUS_INSTALL_DIR=DIR) pointing at a writable directory."
    fi
    info "sudo is required to write to $INSTALL_DIR"
    SUDO="sudo"
    run mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
  fi

  tmp="$INSTALL_DIR/.lus.tmp.$$"
  if ! { run cp "$1" "$tmp" && run chmod 755 "$tmp" && run mv "$tmp" "$INSTALL_DIR/lus"; }; then
    run rm -f "$tmp" 2>/dev/null
    die "failed to install to $INSTALL_DIR/lus"
  fi
}

main() {
  INSTALL_DIR="${LUS_INSTALL_DIR:-/usr/local/bin}"
  VERSION="${LUS_VERSION:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)     [ $# -ge 2 ] || die "--dir needs a value"; INSTALL_DIR=$2; shift 2 ;;
      --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)         die "unknown option: $1 (try --help)" ;;
    esac
  done

  detect_platform

  case "$VERSION" in
    "")     URLBASE="https://github.com/$REPO/releases/latest/download" ;;
    [0-9]*) VERSION="v$VERSION"
            URLBASE="https://github.com/$REPO/releases/download/$VERSION" ;;
    *)      URLBASE="https://github.com/$REPO/releases/download/$VERSION" ;;
  esac

  WORKDIR=$(mktemp -d) || die "failed to create a temporary directory"
  trap 'rm -rf "$WORKDIR"' EXIT
  trap 'exit 1' INT TERM HUP

  info "downloading $ASSET (${VERSION:-latest release}) ..."
  fetch "$URLBASE/$ASSET" "$WORKDIR/$ASSET" || die "download failed: $URLBASE/$ASSET"
  verify_checksum "$WORKDIR/$ASSET" "$ASSET" "$URLBASE"

  if [ "$OS" = "Darwin" ]; then
    # Defensive: curl downloads carry no quarantine attribute, but a
    # re-used browser download might.
    xattr -c "$WORKDIR/$ASSET" 2>/dev/null || true
  fi

  install_binary "$WORKDIR/$ASSET"

  info "installed: $INSTALL_DIR/lus"
  "$INSTALL_DIR/lus" -v 2>/dev/null || true

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "$INSTALL_DIR is not on your PATH — add it to your shell profile" ;;
  esac
}

# Everything above only defines functions; nothing runs until here,
# so a truncated download can't execute a half-script.
main "$@"
