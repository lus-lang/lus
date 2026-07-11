# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Repository Structure

Monorepository for the Lus programming language (a Lua 5.5 derivative). Key directories:

- **`/lus`**: C runtime (interpreter `lus`, compiler `lusc`, static library `liblus`)
- **`/lus-tests`**: Four test harnesses (H1-H4)
- **`/lus-language`**: Language server written in Lus
- **`/lus-vscode`**: VSCode extension (TypeScript + WASM)
- **`/lus-site`**: Website (Astro + MDX)
- **`/lus-spec`**: Stdlib specification (YAML frontmatter `.md` files)
- **`/lus-textmate`**: TextMate grammar (shared by site and extension)

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
- `LUA_TENUM` / `LUA_TENUMROOT`: first-class enums (`lenum.c`, `lenum.h`)
- `LUA_TVECTOR`: mutable byte buffers (`lvector.c`)

New libraries: `ljsonlib.c`, `lfslib.c`, `lnetlib.c`, `lworkerlib.c`, `lvectorlib.c`. Permissions: `lpledge.c`. AST: `last.c`. Bundling: `lbundle.c`.

When adding GC-managed types or constants, always initialize new array slots to nil (see `addk` in `lcode.c` for the pattern). The GC's `markvalue` macro will dereference garbage type tags if `BIT_ISCOLLECTABLE` happens to be set.

### Stdlib Fastcall Parity

The VM intrinsifies common stdlib calls as `OP_FASTCALL` (`lfastcall.c`, `lfastcall.h`), so a fastcalled builtin has two implementations: the intrinsic case in `luaV_dofastcall` and the registered C function. Which one runs depends on the call shape (single-result sites take the fast path, multret sites such as the last argument of a call or a `return` take the C path), so any divergence surfaces as position-dependent behavior. A whole class of 1.7.0 bugs came from the two paths disagreeing. Treat parity as a hard requirement whenever you touch the stdlib:

1. **Adding a stdlib function**: assess it for fastcall eligibility (hot, fixed arity, and implementable on the fast path without allocation, metamethods, or Lua calls). If eligible, add the intrinsic in the same change: an `FC_*` id, an `FCDef` entry with correct `nargs`, registration via `luaF_registerfastcall`, and the `multret` flag when the builtin can return other than exactly one value at the registered arity (otherwise return-position calls truncate it). If not eligible, state why in the PR or commit message.
2. **Changing either side of an existing fastcall** (the `luaV_dofastcall` case or the C function in the library file): re-verify behavioral parity on every axis that has produced real bugs: numeric-string coercion, NaN and signed-zero handling, integer versus float subtype of results, position clamping and out-of-range behavior, metatable and metamethod interaction, error messages and error object types, and result counts including zero results.
3. **Fall back instead of approximating.** For any input outside the intrinsic's exact competence, `return 0` from `luaV_dofastcall` so the plain call runs. The C function is the single source of truth for coercions, metamethods, and error reporting. The fast path may only ever duplicate its behavior bit for bit or decline.
4. **Prove parity with tests.** Extend `lus-tests/h1/fastcall-parity.lus` for every new or changed fastcall. It drives an `OP_FASTCALL` call site and an aliased `OP_CALL` site over the same adversarial corpus and asserts identical results, subtypes, and error reasons, using `framework.get_fastcalls` to prove the fast form really compiled to `OP_FASTCALL`. For manual differential checks, run the same script with and without `--no-fastcall`. Casual `print(f(...))` repros hide divergences because the multret argument position never emits `OP_FASTCALL`.

### Test Harnesses

- **H1**: Pure Lus tests using `lus-tests/framework.lus`. Each file is a self-contained test suite.
- **H2**: Compiled C programs linking against `liblus` (tests C API embedding).
- **H3**: System integration: `runner_local.lus` (containerized) and `runner_direct.lus` (CI-only).
- **H4**: Benchmarks with pass/fail thresholds. `BUILD_TYPE` env controls strictness.

Tests run from the repo root as working directory. The test binary path is the meson-built executable, and runners use `arg[-1]` to find it.

### CI Workflow

Platform-specific build directories (`build-<platform>`) prevent race conditions when `act` runs matrix jobs in parallel on a shared filesystem. The sanitizer job uses ASAN+UBSAN. Windows and macOS matrix entries will fail under `act` (Docker limitation). Only linux-glibc and linux-musl run locally.

### Website Content

Manual pages are MDX files in `lus-site/src/manual/`. Cross-references use `/manual/guide#section-slug` and `/manual/acquis-N` formats. The acquis pages (0 to 30) document individual language features. The guide is the comprehensive reference.

### Writing Acquis and Documentation

Acquis are tracked both as GitHub issues (label `📗 acquis`, assigned to a version milestone) and as MDX pages. Whenever you write an acquis, or any project prose (docs, changelog, spec `.md`, comments), follow these rules:

- **Frame everything positively.** Describe what the design is and does. Never describe it in terms of an alternative the reader has not seen. Phrasing like "there is no `tolist` method", "instead of a new global", "not an object", or "clauses rather than methods" implies an earlier proposal that exists only in your head, and the reader has no context for it. State the actual behavior instead ("the only way to run a query is the `query` iterator"). Comparisons to features that already ship, or to concepts every reader knows, are fine.
- **No em dashes or en dashes.** Rewrite the sentence so the dash is unnecessary rather than swapping it for a hyphen. The repository is kept free of both.
- **No semicolons.** Write separate full sentences.
- **Use full sentences and flowing paragraphs**, including complete-sentence lead-ins before code blocks.

Before posting an issue or committing prose, grep for em dashes, en dashes, and semicolons, and reread for any wording that presumes a rejected alternative.

### Lus-spec → Language Server Pipeline

`lus-spec/stdlib/` contains one `.md` per stdlib entry with YAML frontmatter (`name`, `kind`, `module`, `params`, `returns`, `stability`). Running `node lus-spec/build-lsp.js` generates `lus-language/analysis/stdlib_data.lus` which the language server uses for completions, hover, and linting.

## Picking the right models for workflows and subagents

This section applies only when working inside Claude Code. Other harnesses (Codex, OpenCode, and the rest) must ignore it, since the plugin commands and model parameters below do not exist there.

Rankings are higher = better. Cost reflects what the maintainer actually pays (OpenAI has really generous limits), not list price. Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.

| model    | cost | intelligence | taste |
| -------- | :--: | :----------: | :---: |
| gpt-5.5  |  9   |      8       |   5   |
| sonnet-5 |  5   |      5       |   7   |
| opus-4.8 |  4   |      8       |   8   |
| fable-5  |  2   |      9       |   9   |

### How to apply

- These are defaults, not limits. You have standing permission to override them: if a cheaper model's output doesn't meet the bar, rerun or redo the work with a smarter model without asking. Judge the output, not the price tag. Escalating costs less than shipping mediocre work.
- Cost is a tie-breaker only. When axes conflict for anything that ships: intelligence > taste > cost.
- Bulk / mechanical work (clear-spec implementation, data analysis, migrations): use `gpt-5.5`, which is cheap and token-efficient.
- Anything user-facing (UI, copy, API design) needs taste ≥ 7.
- Reviews of plans and implementations: `fable-5` or `opus-4.8`, optionally `gpt-5.5` as an extra independent perspective.
- Never use Haiku.

### Mechanics

`gpt-5.5` is handled natively via the `openai/codex-plugin-cc` plugin inside Claude Code, which automatically adopts your user-level configuration from `~/.codex/config.toml`. Avoid writing custom bash scripts. Use the plugin's built-in tools and skills instead:

- `/codex:review`: non-destructive, read-only code-quality assessment. Supports `--base <ref>` for branch analysis.
- `/codex:adversarial-review`: skeptical design review to pressure-test tradeoffs, auth, and reliability. Append custom focus text at the end of the command to steer it.
- `/codex:rescue`: subcontract active debugging, multi-file refactoring, or implementation loops to Codex when a second pass is required.
- `/codex:status` / `/codex:result` / `/codex:cancel`: check, fetch, or abort asynchronous jobs when using the `--background` flag on heavy tasks.

Claude models (`sonnet-5`, `opus-4.8`, `fable-5`) run via the Agent/Workflow model parameter.

### Using gpt-5.5 inside workflows and subagents

- Subagents and automated workflows should call the plugin's native slash commands or its exposed `codex-cli-runtime` skills to delegate tasks directly, without raw terminal wrappers.
- For closed-loop quality assurance, keep the review gate on via `/codex:setup --enable-review-gate`. This installs a stop hook that automatically challenges Claude's outputs with Codex before finalizing, preventing broken code or weak design assumptions from reaching the main session unvetted.

## Code Style

C code is formatted with clang-format (config at `lus/.clang-format`): LLVM base style, 2-space indent, 80-column limit, `else` on new line after `}`, pointers right-aligned (`char *p`). Never sort includes.

Lus code uses 4-space indentation. Global variables must be declared with `global` at the top of the file. Permissions are pledged immediately after globals.
