#!/bin/sh
# The Lus installer, served at https://lus.dev/install.sh
#
# Downloads the release archive for this machine from a GitHub release of
# lus-lang/lus and installs the `lus` executable from it.
#
#   curl -fsSL https://lus.dev/install.sh | sh
#
# A release publishes one archive per target, named
# lus-<tag>-<target>.tar.gz, beside a SHA256SUMS manifest. The script
# picks the archive for this machine, checks it against SHA256SUMS before
# unpacking it, and writes $INSTALL_DIR/lus with an atomic rename. sudo is
# used only for that copy, and only when the directory is not writable.
#
# Platforms without prebuilt archives (the BSDs, illumos, and other CPU
# architectures) get pointed at the build-from-source manual.

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
  --version TAG   install a specific release, such as v2.0.0 or 2.0.0
                  (env: LUS_VERSION). The default is the latest release.
  --dir DIR       install directory, default /usr/local/bin
                  (env: LUS_INSTALL_DIR)
  LUS_RELEASE_BASE_URL selects an HTTPS release mirror that serves
                  SHA256SUMS and the archives of one release
  -h, --help      show this help

When piping to sh, pass options as environment variables:
  LUS_VERSION=v2.0.0 curl -fsSL https://lus.dev/install.sh | sh
EOF
}

# fetch URL DEST: curl preferred, wget fallback. Both fail on HTTP
# errors so a 404 page can't masquerade as an archive.
fetch() {
  if need curl; then
    curl -fsSL --proto '=https' -o "$2" "$1"
  elif need wget; then
    wget -q -O "$2" "$1"
  else
    die "neither curl nor wget is available"
  fi
}

# No prebuilt archive for this platform: point at the manual, which
# documents dependencies and build steps per platform.
unsupported() {
  printf '%s\n' \
    "No prebuilt Lus archives are published for $1." \
    "" \
    "Lus builds from source with Zig. The manual covers the steps:" \
    "  $COMPILING_URL" >&2
  exit 1
}

# Sets OS and TARGET (the Zig target triple of the release archive) for
# this machine, or exits with guidance.
detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)

  case "$OS" in
    Linux)
      # The Linux archives are static musl builds, so glibc and musl
      # hosts run the same executable.
      case "$ARCH" in
        x86_64|amd64)  TARGET="x86_64-linux-musl" ;;
        aarch64|arm64) TARGET="aarch64-linux-musl" ;;
        *) unsupported "Linux on $ARCH" ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        arm64) TARGET="aarch64-macos" ;;
        x86_64)
          # An x86_64 shell under Rosetta still runs on Apple Silicon,
          # where the native arm64 build is the right one.
          if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
            TARGET="aarch64-macos"
          else
            TARGET="x86_64-macos"
          fi
          ;;
        *) unsupported "macOS on $ARCH" ;;
      esac
      ;;
    FreeBSD)   unsupported "FreeBSD" ;;
    OpenBSD)   unsupported "OpenBSD" ;;
    NetBSD)    unsupported "NetBSD" ;;
    DragonFly) unsupported "DragonFly BSD" ;;
    SunOS)     unsupported "illumos and Solaris" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "on Windows, use the installer:
  https://github.com/$REPO/releases/latest/download/lus-setup.exe"
      ;;
    *) unsupported "$OS" ;;
  esac
}

# sums_names: print every file name listed in SHA256SUMS, with the
# binary-mode '*' marker removed.
sums_names() {
  awk 'NF == 2 { name = $2; sub(/^\*/, "", name); print name }' "$WORKDIR/SHA256SUMS"
}

# resolve_asset: set ASSET to the archive name for TARGET. A pinned
# version names it directly. The latest release is identified by the one
# lus-v*-TARGET.tar.gz entry in its SHA256SUMS, which carries the tag.
resolve_asset() {
  if [ -n "$VERSION" ]; then
    ASSET="lus-$VERSION-$TARGET.tar.gz"
    return
  fi
  suffix="-$TARGET.tar.gz"
  matches=$(sums_names | awk -v suffix="$suffix" '
    {
      tail = length($0) - length(suffix) + 1
      if (substr($0, 1, 5) == "lus-v" && tail > 6 &&
          substr($0, tail) == suffix && $0 !~ /[\/\\]/) print
    }')
  count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] ||
    die "the latest release lists no single archive for $TARGET in SHA256SUMS"
  ASSET=$matches
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

# extract ARCHIVE: unpack the verified archive and set BINARY to the
# lus executable inside it.
extract() {
  need tar || die "tar is required to unpack the release"
  mkdir "$WORKDIR/archive" || die "failed to create the unpack directory"
  tar -xzf "$1" -C "$WORKDIR/archive" || die "failed to unpack $ASSET"
  BINARY="$WORKDIR/archive/bin/lus"
  if [ ! -f "$BINARY" ] || [ -L "$BINARY" ]; then
    die "$ASSET does not contain bin/lus"
  fi
}

# Run a command, under sudo when install_binary decided it's needed.
run() {
  if [ -n "$SUDO" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Place the executable under a temporary name, then rename it over
# $INSTALL_DIR/lus so a running lus never sees a partial file.
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

  lus_tmp="$INSTALL_DIR/.lus.tmp.$$"
  if ! {
    run cp "$1" "$lus_tmp" &&
    run chmod 755 "$lus_tmp" &&
    run mv "$lus_tmp" "$INSTALL_DIR/lus"
  }; then
    run rm -f "$lus_tmp" 2>/dev/null
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
    latest) VERSION="" ;;
    [0-9]*) VERSION="v$VERSION" ;;
  esac
  case "$VERSION" in
    *[!A-Za-z0-9._-]*) die "invalid version: $VERSION" ;;
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

  info "downloading Lus (${VERSION:-latest release}) for $TARGET ..."
  fetch "$URLBASE/SHA256SUMS" "$WORKDIR/SHA256SUMS" ||
    die "release checksum manifest is unavailable: $URLBASE/SHA256SUMS"
  resolve_asset
  fetch "$URLBASE/$ASSET" "$WORKDIR/$ASSET" ||
    die "download failed: $URLBASE/$ASSET"
  verify_checksum "$WORKDIR/$ASSET" "$ASSET"
  extract "$WORKDIR/$ASSET"

  if [ "$OS" = "Darwin" ]; then
    # Defensive: curl downloads carry no quarantine attribute, but a
    # reused browser download might.
    xattr -c "$BINARY" 2>/dev/null || true
  fi

  install_binary "$BINARY"

  info "installed: $INSTALL_DIR/lus"
  "$INSTALL_DIR/lus" -v

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "$INSTALL_DIR is not on your PATH. Add it to your shell profile." ;;
  esac
}

# Everything above only defines functions. Nothing runs until here,
# so a truncated download can't execute a half-script.
main "$@"
