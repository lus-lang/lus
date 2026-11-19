#!/bin/sh
# Build the locally tagged Lus 1.6.2 source in a new disposable directory.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TAG=v1.6.2

if ! git -C "$ROOT" cat-file -e "$TAG^{commit}"; then
  echo "error: local tag $TAG is unavailable" >&2
  echo "fetch the tag, then run this script again" >&2
  exit 1
fi

DEST=
CANDIDATE_BUILD=
EVIDENCE=
CARES_SOURCE_ARCHIVE=${H4_CARES_SOURCE_ARCHIVE:-}
DEPENDENCY_METADATA="$ROOT/release/dependencies.json"

if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
  DEST=$1
  shift
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-build)
      CANDIDATE_BUILD=$2
      shift 2
      ;;
    --evidence)
      EVIDENCE=$2
      shift 2
      ;;
    --cares-source-archive)
      CARES_SOURCE_ARCHIVE=$2
      shift 2
      ;;
    --dependency-metadata)
      DEPENDENCY_METADATA=$2
      shift 2
      ;;
    *)
      echo "error: unknown baseline preparation option: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$CANDIDATE_BUILD" ]; then
  echo "error: --candidate-build is required for paired H4 qualification" >&2
  exit 2
fi
if [ -z "$CARES_SOURCE_ARCHIVE" ]; then
  echo "error: --cares-source-archive or H4_CARES_SOURCE_ARCHIVE is required" >&2
  exit 2
fi

if [ -n "$DEST" ]; then
  mkdir "$DEST"
else
  DEST=$(mktemp -d "${TMPDIR:-/tmp}/lus-h4-v1.6.2.XXXXXX")
fi
if [ -z "$EVIDENCE" ]; then
  EVIDENCE="$DEST/h4-build-parity.json"
fi

git -C "$ROOT" archive "$TAG" | tar -x -C "$DEST"
python3 "$ROOT/lus-tests/h4/build_parity.py" \
  --candidate-build "$CANDIDATE_BUILD" \
  --source "$DEST/lus" \
  --baseline-build "$DEST/lus/build-release" \
  --evidence "$EVIDENCE" \
  --cares-source-archive "$CARES_SOURCE_ARCHIVE" \
  --dependency-metadata "$DEPENDENCY_METADATA" >&2

printf '%s\n' "$DEST/lus/build-release/lus"
