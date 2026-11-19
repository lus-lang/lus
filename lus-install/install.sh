#!/bin/sh
# The Lus installer, served at https://lus.dev/install.sh
#
# Downloads the prebuilt binary for this machine from a GitHub
# release of lus-lang/lus and installs `lus` and `lusc`.
#
#   curl -fsSL https://lus.dev/install.sh | sh
#
# The script writes $INSTALL_DIR/lus and $INSTALL_DIR/lusc. sudo is
# used only for those copies, and only when the directory is not writable.
# Every download must have an entry in the release SHA256SUMS asset.
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
  --version TAG   install a specific release: v1.7.0, 1.7.0, or an
                  unstable-<sha> pre-release tag (env: LUS_VERSION)
  --dir DIR       install directory, default /usr/local/bin
                  (env: LUS_INSTALL_DIR)
  LUS_RELEASE_BASE_URL selects an HTTPS release mirror for qualification
                  and managed distribution environments
  -h, --help      show this help

When piping to sh, pass options as environment variables:
  LUS_VERSION=v1.7.0 curl -fsSL https://lus.dev/install.sh | sh
EOF
}

# fetch URL DEST: curl preferred, wget fallback. Both fail on HTTP
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

# Sets OS, LUS_ASSET, and LUSC_ASSET for this machine, or exits with guidance.
detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)

  case "$OS" in
    Linux)
      case "$ARCH" in
        x86_64)
          if [ -e /lib/ld-musl-x86_64.so.1 ] || ldd --version 2>&1 | grep -qi musl; then
            LUS_ASSET="lus-linux-musl"
            LUSC_ASSET="lusc-linux-musl"
          else
            LUS_ASSET="lus-linux"
            LUSC_ASSET="lusc-linux"
          fi
          ;;
        *) unsupported "Linux on $ARCH" ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        arm64)
          LUS_ASSET="lus-macos"
          LUSC_ASSET="lusc-macos"
          ;;
        x86_64)
          # An x86_64 shell under Rosetta is still an Apple Silicon
          # machine; the arm64 binary is the right one.
          if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
            LUS_ASSET="lus-macos"
            LUSC_ASSET="lusc-macos"
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

# verify_checksum FILE ASSET: check FILE against the downloaded
# release SHA256SUMS. Missing or ambiguous entries are fatal.
verify_checksum() {
  matches=$(awk -v name="$2" '$2 == name || $2 == "*" name { print $1 }' "$WORKDIR/SHA256SUMS")
  count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || die "SHA256SUMS must contain exactly one entry for $2"
  expected=$matches
  printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' ||
    die "SHA256SUMS contains an invalid digest for $2"
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')

  if need sha256sum; then
    actual=$(sha256sum "$1" | awk '{ print $1 }')
  elif need shasum; then
    actual=$(shasum -a 256 "$1" | awk '{ print $1 }')
  else
    die "sha256sum or shasum is required to verify the release"
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

# Place the downloaded binaries using temporary names and atomic renames.
install_binaries() {
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

  lus_tmp="$INSTALL_DIR/.lus.tmp.$$"
  lusc_tmp="$INSTALL_DIR/.lusc.tmp.$$"
  if ! {
    run cp "$1" "$lus_tmp" &&
    run cp "$2" "$lusc_tmp" &&
    run chmod 755 "$lus_tmp" "$lusc_tmp" &&
    run mv "$lus_tmp" "$INSTALL_DIR/lus" &&
    run mv "$lusc_tmp" "$INSTALL_DIR/lusc"
  }; then
    run rm -f "$lus_tmp" "$lusc_tmp" 2>/dev/null
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
    [0-9]*) VERSION="v$VERSION" ;;
  esac

  if [ -n "${LUS_RELEASE_BASE_URL:-}" ]; then
    case "$LUS_RELEASE_BASE_URL" in
      https://*) URLBASE=${LUS_RELEASE_BASE_URL%/} ;;
      *) die "LUS_RELEASE_BASE_URL must use HTTPS" ;;
    esac
  else
    case "$VERSION" in
      "") URLBASE="https://github.com/$REPO/releases/latest/download" ;;
      *)  URLBASE="https://github.com/$REPO/releases/download/$VERSION" ;;
    esac
  fi

  WORKDIR=$(mktemp -d) || die "failed to create a temporary directory"
  trap 'rm -rf "$WORKDIR"' EXIT
  trap 'exit 1' INT TERM HUP

  info "downloading Lus tools (${VERSION:-latest release}) ..."
  fetch "$URLBASE/SHA256SUMS" "$WORKDIR/SHA256SUMS" ||
    die "release checksum manifest is unavailable: $URLBASE/SHA256SUMS"
  fetch "$URLBASE/$LUS_ASSET" "$WORKDIR/$LUS_ASSET" ||
    die "download failed: $URLBASE/$LUS_ASSET"
  fetch "$URLBASE/$LUSC_ASSET" "$WORKDIR/$LUSC_ASSET" ||
    die "download failed: $URLBASE/$LUSC_ASSET"
  verify_checksum "$WORKDIR/$LUS_ASSET" "$LUS_ASSET"
  verify_checksum "$WORKDIR/$LUSC_ASSET" "$LUSC_ASSET"

  if [ "$OS" = "Darwin" ]; then
    # Defensive: curl downloads carry no quarantine attribute, but a
    # re-used browser download might.
    xattr -c "$WORKDIR/$LUS_ASSET" "$WORKDIR/$LUSC_ASSET" 2>/dev/null || true
  fi

  install_binaries "$WORKDIR/$LUS_ASSET" "$WORKDIR/$LUSC_ASSET"

  info "installed: $INSTALL_DIR/lus and $INSTALL_DIR/lusc"
  "$INSTALL_DIR/lus" -v
  "$INSTALL_DIR/lusc" -v

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "$INSTALL_DIR is not on your PATH; add it to your shell profile" ;;
  esac
}

# Everything above only defines functions; nothing runs until here,
# so a truncated download can't execute a half-script.
main "$@"
