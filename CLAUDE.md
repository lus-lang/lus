# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

Monorepository for the Lus programming language (a Lua 5.5 derivative). Key directories:

- **`/lus`** — C runtime (interpreter `lus`, compiler `lusc`, static library `liblus`)
- **`/lus-tests`** — Four test harnesses (H1–H4)
- **`/lus-language`** — Language server written in Lus
- **`/lus-vscode`** — VSCode extension (TypeScript + WASM)
- **`/lus-site`** — Website (Astro + MDX)
- **`/lus-spec`** — Stdlib specification (YAML frontmatter `.md` files)
- **`/lus-textmate`** — TextMate grammar (shared by site and extension)

## Build Commands

### Runtime (C)

```sh
cd lus
meson setup build
meson compile -C build
./build/lus            # interpreter
./build/lusc           # bytecode compiler
```

### Tests

```sh
# From lus/ directory:
meson test -C build                    # all suites
meson test -C build --suite h1         # language integrity (pure Lus)
meson test -C build --suite h2         # C API
meson test -C build --suite h3-local   # system integration (containerized)
meson test -C build --suite h4         # benchmarks
meson test -C build h1/optchain        # single test by name

# Full CI simulation with sanitizers (requires Docker + act):
act -j sanitize                        # from repo root
```

### Website

```sh
cd lus-site
pnpm install
pnpm dev          # dev server
pnpm build        # production build (npx astro build)
```

### Language Server Data

```sh
node lus-spec/build-lsp.js    # regenerates lus-language/analysis/stdlib_data.lus
```

## Architecture Notes

### Lus Language vs Lua

Lus extends Lua 5.5 with: `catch` (replaces `pcall`/`xpcall`), `enum`, optional chaining (`?.`), string interpolation (backticks), `from` destructuring, if/while-assignment, `pledge` permissions, `vector` buffers, workers, slices, `table.clone`, do-expressions (`provide`), runtime attributes, and new stdlib (JSON, filesystem, networking, transcoding).

All Lus source files use `.lus` extension. Code blocks in documentation use ` ```lus ` fencing.

### C Runtime Internals

The runtime is a modified Lua 5.5 codebase. New types added to the GC system:
- `LUA_TENUM` / `LUA_TENUMROOT` — first-class enums (`lenum.c`, `lenum.h`)
- `LUA_TVECTOR` — mutable byte buffers (`lvector.c`)

New libraries: `ljsonlib.c`, `lfslib.c`, `lnetlib.c`, `lworkerlib.c`, `lvectorlib.c`. Permissions: `lpledge.c`. AST: `last.c`. Bundling: `lbundle.c`.

When adding GC-managed types or constants, always initialize new array slots to nil (see `addk` in `lcode.c` for the pattern). The GC's `markvalue` macro will dereference garbage type tags if `BIT_ISCOLLECTABLE` happens to be set.

### Test Harnesses

- **H1** — Pure Lus tests using `lus-tests/framework.lus`. Each file is a self-contained test suite.
- **H2** — Compiled C programs linking against `liblus` (tests C API embedding).
- **H3** — System integration: `runner_local.lus` (containerized) and `runner_direct.lus` (CI-only).
- **H4** — Benchmarks with pass/fail thresholds. `BUILD_TYPE` env controls strictness.

Tests run from the repo root as working directory. The test binary path is the meson-built executable; runners use `arg[-1]` to find it.

### CI Workflow

Platform-specific build directories (`build-<platform>`) prevent race conditions when `act` runs matrix jobs in parallel on a shared filesystem. The sanitizer job uses ASAN+UBSAN. Windows and macOS matrix entries will fail under `act` (Docker limitation) — only linux-glibc and linux-musl run locally.

### Website Content

Manual pages are MDX files in `lus-site/src/manual/`. Cross-references use `/manual/guide#section-slug` and `/manual/acquis-N` formats. The acquis pages (0–23) document individual language features. The guide is the comprehensive reference.

### Lus-spec → Language Server Pipeline

`lus-spec/stdlib/` contains one `.md` per stdlib entry with YAML frontmatter (`name`, `kind`, `module`, `params`, `returns`, `stability`). Running `node lus-spec/build-lsp.js` generates `lus-language/analysis/stdlib_data.lus` which the language server uses for completions, hover, and linting.

## Code Style

C code is formatted with clang-format (config at `lus/.clang-format`): LLVM base style, 2-space indent, 80-column limit, `else` on new line after `}`, pointers right-aligned (`char *p`). Never sort includes.

Lus code uses 4-space indentation. Global variables must be declared with `global` at the top of the file. Permissions are pledged immediately after globals.
