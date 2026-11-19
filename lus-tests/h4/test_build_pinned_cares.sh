#!/bin/sh
# Exercise the portable c-ares source digest verifier.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
VERIFIER=$ROOT/lus-tests/h4/build_pinned_cares.sh
EXPECTED=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lus-cares-verifier.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

expect_failure() {
  description=$1
  shift
  if "$@" >"$TMP_ROOT/failure.stdout" 2>"$TMP_ROOT/failure.stderr"; then
    echo "error: verifier accepted $description" >&2
    exit 1
  fi
}

printf abc >"$TMP_ROOT/archive"
"$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"

printf abd >"$TMP_ROOT/archive"
expect_failure "a digest mismatch" \
  "$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"
printf abc >"$TMP_ROOT/archive"

expect_failure "an uppercase stored digest" \
  "$VERIFIER" --verify-sha256 \
  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD \
  "$TMP_ROOT/archive"
expect_failure "a short stored digest" \
  "$VERIFIER" --verify-sha256 ba7816bf "$TMP_ROOT/archive"

mkdir "$TMP_ROOT/fake"
cat >"$TMP_ROOT/fake/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n%s  %s\n' \
  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$1" \
  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$1"
EOF
chmod +x "$TMP_ROOT/fake/sha256sum"
expect_failure "multiple digest lines" \
  env PATH="$TMP_ROOT/fake:$PATH" \
  "$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"

cat >"$TMP_ROOT/fake/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s extra\n' \
  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$1"
EOF
chmod +x "$TMP_ROOT/fake/sha256sum"
expect_failure "an ambiguous digest suffix" \
  env PATH="$TMP_ROOT/fake:$PATH" \
  "$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"

cat >"$TMP_ROOT/fake/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' \
  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD "$1"
EOF
chmod +x "$TMP_ROOT/fake/sha256sum"
expect_failure "an uppercase tool digest" \
  env PATH="$TMP_ROOT/fake:$PATH" \
  "$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"

mkdir "$TMP_ROOT/empty"
expect_failure "a missing digest tool" \
  env PATH="$TMP_ROOT/empty" \
  /bin/sh "$VERIFIER" --verify-sha256 "$EXPECTED" "$TMP_ROOT/archive"

echo "portable c-ares digest verifier tests passed"
