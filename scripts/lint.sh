#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

HOOK_MODE=false
FAILED=0
PASSED=0
SKIPPED=0
RUN_ONLY=""

for arg in "$@"; do
  case "$arg" in
    --hook) HOOK_MODE=true ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *) RUN_ONLY="$arg" ;;
  esac
done

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1: $2"; FAILED=$((FAILED + 1)); }
skip() { echo "  SKIP  $1: $2"; SKIPPED=$((SKIPPED + 1)); }

should_run() {
  [ -z "$RUN_ONLY" ] || [ "$RUN_ONLY" = "$1" ]
}

# ---------------------------------------------------------------------------
# 1. version-not-released
# ---------------------------------------------------------------------------
if should_run version-not-released; then
  if ! VERSION=$(python3 scripts/release.py version 2>/dev/null); then
    fail version-not-released "lua.h does not contain one canonical numeric version"
    VERSION="invalid"
  fi

  if [ "$VERSION" = "invalid" ]; then
    :
  elif git tag -l "v$VERSION" | grep -q "v$VERSION"; then
    # The release tag itself (CI runs this lint on v* tag pushes) and
    # post-release commits that leave the runtime untouched (site,
    # docs, CI) are fine; new lus/ work under a released version is
    # what must force a bump.
    if git tag --points-at HEAD 2>/dev/null | grep -qx "v$VERSION"; then
      pass version-not-released
    elif git diff --quiet "v$VERSION" HEAD -- lus/ 2>/dev/null; then
      pass version-not-released
    else
      fail version-not-released "v$VERSION already tagged; bump version before committing runtime changes"
    fi
  else
    pass version-not-released
  fi
fi

# ---------------------------------------------------------------------------
# 2. version-consistency
# ---------------------------------------------------------------------------
if should_run version-consistency; then
  if ! CANONICAL=$(python3 scripts/release.py version 2>/dev/null); then
    fail version-consistency "lua.h does not contain one canonical numeric version"
    CANONICAL="invalid"
  fi

  MESON_VER=$(sed -n "s/.*version: *'\([0-9]*\.[0-9]*\.[0-9]*\)'.*/\1/p" lus/meson.build)
  PKG_VER=$(sed -n 's/.*"version": *"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' lus-vscode/package.json)
  CHANGELOG_VER=$(sed -n 's/^## \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' CHANGELOG.md | head -1)

  MISMATCH=""
  [ "$MESON_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH meson.build($MESON_VER)"
  [ "$PKG_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH package.json($PKG_VER)"
  [ "$CHANGELOG_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH CHANGELOG.md($CHANGELOG_VER)"

  if [ "$CANONICAL" = "invalid" ]; then
    :
  elif [ -n "$MISMATCH" ]; then
    fail version-consistency "lua.h=$CANONICAL but$MISMATCH"
  else
    pass version-consistency
  fi
fi

# ---------------------------------------------------------------------------
# 3. stdlib-freshness
# ---------------------------------------------------------------------------
if should_run stdlib-freshness; then
  if ! command -v node &>/dev/null; then
    if $HOOK_MODE; then
      skip stdlib-freshness "node not in PATH"
    else
      fail stdlib-freshness "node not in PATH"
    fi
  else
    RUN_CHECK=true
    if $HOOK_MODE; then
      STAGED_SPEC=$(git diff --cached --name-only -- 'lus-spec/stdlib/' 2>/dev/null || true)
      [ -z "$STAGED_SPEC" ] && RUN_CHECK=false
    fi

    if $RUN_CHECK; then
      if ! node lus-spec/build-lsp.js --check >/dev/null 2>&1; then
        fail stdlib-freshness "stdlib_data.lus is stale; run: node lus-spec/build-lsp.js"
      else
        pass stdlib-freshness
      fi
    else
      skip stdlib-freshness "no spec files staged"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. grammar-freshness
# ---------------------------------------------------------------------------
if should_run grammar-freshness; then
  if ! command -v node &>/dev/null; then
    if $HOOK_MODE; then
      skip grammar-freshness "node not in PATH"
    else
      fail grammar-freshness "node not in PATH"
    fi
  else
    RUN_CHECK=true
    if $HOOK_MODE; then
      STAGED_GRAMMAR=$(git diff --cached --name-only -- \
        'lus-spec/stdlib/' \
        'lus-textmate/' \
        'lus-vscode/syntaxes/lus.tmLanguage.json' 2>/dev/null || true)
      [ -z "$STAGED_GRAMMAR" ] && RUN_CHECK=false
    fi

    if $RUN_CHECK; then
      if ! node lus-textmate/build-grammar.test.js >/dev/null 2>&1 \
          || ! node lus-textmate/build-grammar.js --check >/dev/null 2>&1; then
        fail grammar-freshness "TextMate grammars are stale. Run: node lus-textmate/build-grammar.js"
      else
        pass grammar-freshness
      fi
    else
      skip grammar-freshness "no grammar inputs staged"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. spec-frontmatter
# ---------------------------------------------------------------------------
if should_run spec-frontmatter; then
  SPEC_ERRORS=""
  for f in $(find lus-spec/stdlib -name '*.md' -type f | sort); do
    # Extract YAML frontmatter (between first --- and second ---)
    FM=$(sed -n '/^---$/,/^---$/p' "$f" | sed '1d;$d')
    MISSING=""
    for field in name kind module stability; do
      if ! echo "$FM" | grep -q "^${field}:"; then
        MISSING="$MISSING $field"
      fi
    done
    # Validate since format if present
    SINCE=$(echo "$FM" | sed -n 's/^since: *//p')
    if [ -n "$SINCE" ]; then
      if ! echo "$SINCE" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        MISSING="$MISSING since(bad format: $SINCE)"
      fi
    fi
    if [ -n "$MISSING" ]; then
      SPEC_ERRORS="$SPEC_ERRORS\n  $f: missing$MISSING"
    fi
  done

  if [ -n "$SPEC_ERRORS" ]; then
    fail spec-frontmatter "$(echo -e "$SPEC_ERRORS")"
  else
    pass spec-frontmatter
  fi
fi

# ---------------------------------------------------------------------------
# 6. h1-coverage
# ---------------------------------------------------------------------------
if should_run h1-coverage; then
  # Extract registered test names from meson.build
  REGISTERED=$(sed -n "/^h1_tests = \[/,/^\]/p" lus/meson.build \
    | grep "'" | sed "s/.*'\(.*\)'.*/\1/" | sort)

  # Actual test files on disk (direct children only)
  ACTUAL=$(find lus-tests/h1 -maxdepth 1 -name '*.lus' -type f \
    | sed 's|lus-tests/||; s|\.lus$||' | sort)

  UNREGISTERED=$(comm -23 <(echo "$ACTUAL") <(echo "$REGISTERED"))
  STALE=$(comm -13 <(echo "$ACTUAL") <(echo "$REGISTERED"))

  COVERAGE_ERRORS=""
  if [ -n "$UNREGISTERED" ]; then
    COVERAGE_ERRORS="unregistered files: $(echo "$UNREGISTERED" | tr '\n' ' ')"
  fi
  if [ -n "$STALE" ]; then
    [ -n "$COVERAGE_ERRORS" ] && COVERAGE_ERRORS="$COVERAGE_ERRORS; "
    COVERAGE_ERRORS="${COVERAGE_ERRORS}stale registrations: $(echo "$STALE" | tr '\n' ' ')"
  fi

  if [ -n "$COVERAGE_ERRORS" ]; then
    fail h1-coverage "$COVERAGE_ERRORS"
  else
    pass h1-coverage
  fi
fi

# ---------------------------------------------------------------------------
# 7. install-sh
# ---------------------------------------------------------------------------
if should_run install-sh; then
  if ! SH_ERR=$(sh -n lus-install/install.sh 2>&1); then
    fail install-sh "sh -n: $SH_ERR"
  elif command -v shellcheck &>/dev/null; then
    if SC_ERR=$(shellcheck -s sh lus-install/install.sh 2>&1); then
      pass install-sh
    else
      fail install-sh "$SC_ERR"
    fi
  else
    if $HOOK_MODE; then
      skip install-sh "shellcheck not in PATH (sh -n passed)"
    else
      fail install-sh "shellcheck not in PATH"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8. release-metadata
# ---------------------------------------------------------------------------
if should_run release-metadata; then
  if RELEASE_ERR=$(python3 scripts/release.py check 2>&1); then
    pass release-metadata
  else
    fail release-metadata "$RELEASE_ERR"
  fi
fi

# ---------------------------------------------------------------------------
# 9. documentation
# ---------------------------------------------------------------------------
if should_run documentation; then
  if DOC_ERR=$(python3 scripts/validate-docs.py 2>&1); then
    pass documentation
  else
    fail documentation "$DOC_ERR"
  fi
fi

# ---------------------------------------------------------------------------
# 10. workflow-fail-closed
# ---------------------------------------------------------------------------
if should_run workflow-fail-closed; then
  WORKFLOW_ALWAYS=$(grep -R -n -E 'always[[:space:]]*\(' \
    --include='*.yml' --include='*.yaml' .github/workflows 2>/dev/null || true)
  if [ -n "$WORKFLOW_ALWAYS" ]; then
    fail workflow-fail-closed "workflow conditions use always():
$WORKFLOW_ALWAYS"
  else
    pass workflow-fail-closed
  fi
fi

# ---------------------------------------------------------------------------
# 11. release-self-tests
# ---------------------------------------------------------------------------
if should_run release-self-tests; then
  if RELEASE_TEST_ERR=$(PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/lus-pycache" \
      python3 scripts/test_release.py 2>&1); then
    pass release-self-tests
  else
    fail release-self-tests "$RELEASE_TEST_ERR"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Lint: $PASSED passed, $FAILED failed, $SKIPPED skipped"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
