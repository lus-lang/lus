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
  MAJOR=$(awk '/^#define LUA_VERSION_MAJOR_N / {print $3}' lus/src/lua.h)
  MINOR=$(awk '/^#define LUA_VERSION_MINOR_N / {print $3}' lus/src/lua.h)
  RELEASE=$(awk '/^#define LUA_VERSION_RELEASE_N / {print $3}' lus/src/lua.h)
  VERSION="$MAJOR.$MINOR.$RELEASE"

  if git tag -l "v$VERSION" | grep -q "v$VERSION"; then
    fail version-not-released "v$VERSION already tagged — bump version before committing"
  else
    pass version-not-released
  fi
fi

# ---------------------------------------------------------------------------
# 2. version-consistency
# ---------------------------------------------------------------------------
if should_run version-consistency; then
  MAJOR=$(awk '/^#define LUA_VERSION_MAJOR_N / {print $3}' lus/src/lua.h)
  MINOR=$(awk '/^#define LUA_VERSION_MINOR_N / {print $3}' lus/src/lua.h)
  RELEASE=$(awk '/^#define LUA_VERSION_RELEASE_N / {print $3}' lus/src/lua.h)
  CANONICAL="$MAJOR.$MINOR.$RELEASE"

  MESON_VER=$(sed -n "s/.*version: *'\([0-9]*\.[0-9]*\.[0-9]*\)'.*/\1/p" lus/meson.build)
  PKG_VER=$(sed -n 's/.*"version": *"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' lus-vscode/package.json)
  CHANGELOG_VER=$(sed -n 's/^## \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' CHANGELOG.md | head -1)

  MISMATCH=""
  [ "$MESON_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH meson.build($MESON_VER)"
  [ "$PKG_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH package.json($PKG_VER)"
  [ "$CHANGELOG_VER" != "$CANONICAL" ] && MISMATCH="$MISMATCH CHANGELOG.md($CHANGELOG_VER)"

  if [ -n "$MISMATCH" ]; then
    fail version-consistency "lua.h=$CANONICAL but$MISMATCH"
  else
    pass version-consistency
  fi
fi

# ---------------------------------------------------------------------------
# 3. clang-format
# ---------------------------------------------------------------------------
if should_run clang-format; then
  if ! command -v clang-format &>/dev/null; then
    if $HOOK_MODE; then
      skip clang-format "clang-format not in PATH"
    else
      fail clang-format "clang-format not in PATH"
    fi
  else
    CF_ERRORS=""
    if $HOOK_MODE; then
      FILES=$(git diff --cached --name-only --diff-filter=ACM -- 'lus/src/*.c' 'lus/src/*.h' 2>/dev/null || true)
    else
      FILES=$(find lus/src -maxdepth 1 \( -name '*.c' -o -name '*.h' \) -type f | sort)
    fi

    if [ -z "$FILES" ]; then
      pass clang-format
    else
      for f in $FILES; do
        if ! clang-format --dry-run --Werror "$f" 2>/dev/null; then
          CF_ERRORS="$CF_ERRORS $f"
        fi
      done
      if [ -n "$CF_ERRORS" ]; then
        fail clang-format "formatting issues in:$CF_ERRORS"
      else
        pass clang-format
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. stdlib-freshness
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
      # Save current state
      cp lus-language/analysis/stdlib_data.lus /tmp/stdlib_data_backup.lus 2>/dev/null || true
      node lus-spec/build-lsp.js >/dev/null 2>&1
      if ! git diff --exit-code --quiet lus-language/analysis/stdlib_data.lus 2>/dev/null; then
        # Restore
        git checkout -- lus-language/analysis/stdlib_data.lus 2>/dev/null || true
        fail stdlib-freshness "stdlib_data.lus is stale — run: node lus-spec/build-lsp.js"
      else
        pass stdlib-freshness
      fi
    else
      skip stdlib-freshness "no spec files staged"
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
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Lint: $PASSED passed, $FAILED failed, $SKIPPED skipped"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
