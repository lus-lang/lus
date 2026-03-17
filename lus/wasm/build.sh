#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"
REPO_ROOT="$SCRIPT_DIR/../.."
OUT_DIR="$SCRIPT_DIR/dist"

# --- Python version check for Emscripten ---
MIN_PYTHON="3.10"

find_python() {
  for py in python3 python; do
    local bin
    bin=$(command -v "$py" 2>/dev/null) || continue
    local ver
    ver=$("$bin" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || continue
    if "$bin" -c "import sys; exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
      echo "$bin"
      return 0
    fi
  done

  # Check common versioned names
  for py in python3.13 python3.12 python3.11 python3.10; do
    local bin
    bin=$(command -v "$py" 2>/dev/null) || continue
    echo "$bin"
    return 0
  done

  return 1
}

PYTHON=$(find_python) || {
  echo "Error: Python >= $MIN_PYTHON is required by Emscripten but was not found."
  echo "Install it or set EM_PYTHON to point to a compatible interpreter."
  exit 1
}

# Export so Emscripten uses the correct Python
export EM_PYTHON="$PYTHON"
echo "Using Python: $PYTHON ($($PYTHON --version 2>&1))"

# --- Platform target ---
# Usage: ./build.sh [web|node|all]
#   web   - browser target (playground)
#   node  - Node.js target (VSCode extension)
#   all   - both (default)
TARGET="${1:-all}"

case "$TARGET" in
  web|node|all) ;;
  *)
    echo "Usage: $0 [web|node|all]"
    echo "  web   Build for browsers (playground)"
    echo "  node  Build for Node.js (VSCode extension)"
    echo "  all   Build both (default)"
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"

# Source files (core + libraries, excluding standalone interpreter main)
SOURCES=(
  "$SRC_DIR/lapi.c"
  "$SRC_DIR/lauxlib.c"
  "$SRC_DIR/lbaselib.c"
  "$SRC_DIR/lcode.c"
  "$SRC_DIR/lcorolib.c"
  "$SRC_DIR/lctype.c"
  "$SRC_DIR/ldblib.c"
  "$SRC_DIR/ldebug.c"
  "$SRC_DIR/ldo.c"
  "$SRC_DIR/ldump.c"
  "$SRC_DIR/lenum.c"
  "$SRC_DIR/lfastcall.c"
  "$SRC_DIR/lfunc.c"
  "$SRC_DIR/lfslib.c"
  "$SRC_DIR/lgc.c"
  "$SRC_DIR/lglob.c"
  "$SRC_DIR/linit.c"
  "$SRC_DIR/liolib.c"
  "$SRC_DIR/ljsonlib.c"
  "$SRC_DIR/lcsvlib.c"
  "$SRC_DIR/larena.c"
  "$SRC_DIR/last.c"
  "$SRC_DIR/llex.c"
  "$SRC_DIR/lformat.c"
  "$SRC_DIR/lmathlib.c"
  "$SRC_DIR/lmem.c"
  "$SRC_DIR/loadlib.c"
  "$SRC_DIR/lobject.c"
  "$SRC_DIR/lopcodes.c"
  "$SRC_DIR/loslib.c"
  "$SRC_DIR/lpack.c"
  "$SRC_DIR/lparser.c"
  "$SRC_DIR/lpledge.c"
  "$SRC_DIR/lstate.c"
  "$SRC_DIR/lstring.c"
  "$SRC_DIR/lstrlib.c"
  "$SRC_DIR/ltable.c"
  "$SRC_DIR/ltablib.c"
  "$SRC_DIR/ltm.c"
  "$SRC_DIR/lundump.c"
  "$SRC_DIR/lutf8lib.c"
  "$SRC_DIR/lvector.c"
  "$SRC_DIR/lvectorlib.c"
  "$SRC_DIR/lvm.c"
  "$SRC_DIR/lzio.c"
  "$SCRIPT_DIR/lus_wasm.c"
  "$SCRIPT_DIR/lev_wasm_stubs.c"
)

# Generate LSP stdlib data from lus-spec
echo "Generating LSP stdlib data..."
node "$REPO_ROOT/lus-spec/build-lsp.js"

# Shared emcc flags
COMMON_FLAGS=(
  -I"$SRC_DIR"
  -s MODULARIZE=1
  -s EXPORT_ES6=1
  -s EXPORTED_FUNCTIONS='["_lus_create","_lus_execute","_lus_destroy","_lus_load_lsp","_lus_handle_message","_malloc","_free"]'
  -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8"]'
  -s ALLOW_MEMORY_GROWTH=1
  -s NO_EXIT_RUNTIME=1
  --embed-file "$REPO_ROOT/lus-language@/lus-language"
  -O2
  -DLUA_USE_C89
  -DLUS_NO_ARCHIVE
)

build_target() {
  local env="$1"
  local suffix="$2"

  echo "Building Lus WASM ($env)..."
  emcc "${SOURCES[@]}" "${COMMON_FLAGS[@]}" \
    -s ENVIRONMENT="$env" \
    -o "$OUT_DIR/lus${suffix}.js"
  echo "  -> $OUT_DIR/lus${suffix}.js, $OUT_DIR/lus${suffix}.wasm"
}

if [ "$TARGET" = "web" ] || [ "$TARGET" = "all" ]; then
  build_target "web" ".web"
fi

if [ "$TARGET" = "node" ] || [ "$TARGET" = "all" ]; then
  build_target "node" ".node"
fi

# When both targets are built, they produce identical .wasm files.
# Keep a shared lus.wasm and remove duplicates.
if [ "$TARGET" = "all" ]; then
  mv "$OUT_DIR/lus.web.wasm" "$OUT_DIR/lus.wasm"
  rm -f "$OUT_DIR/lus.node.wasm"
elif [ "$TARGET" = "web" ]; then
  mv "$OUT_DIR/lus.web.wasm" "$OUT_DIR/lus.wasm"
elif [ "$TARGET" = "node" ]; then
  mv "$OUT_DIR/lus.node.wasm" "$OUT_DIR/lus.wasm"
fi

# Copy node build to VS Code extension directory
if [ "$TARGET" = "node" ] || [ "$TARGET" = "all" ]; then
  VSCODE_WASM="$REPO_ROOT/lus-vscode/wasm"
  if [ -d "$VSCODE_WASM" ]; then
    cp "$OUT_DIR/lus.node.js" "$VSCODE_WASM/lus.js"
    cp "$OUT_DIR/lus.wasm" "$VSCODE_WASM/lus.wasm"
    echo "Copied node build to $VSCODE_WASM"
  fi
fi

echo "Build complete."
