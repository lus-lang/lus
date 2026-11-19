# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Repository Structure

Monorepository for the Lus programming language (a Lua 5.5 derivative). Lus 2.0 is a ground-up rewrite in Zig, developed on the `rewrite` branch. The 1.7 C runtime is frozen under `legacy/` and tagged `v1.7-legacy`. It receives no feature work and serves only as the differential oracle for the rewrite. Key directories:

- **`/runtime`**: The Lus 2.0 runtime in Zig (created at milestone M1)
- **`/legacy`**: Frozen 1.7 C runtime (`legacy/lus`), its four test harnesses (`legacy/lus-tests`), and its release tooling
- **`/spec`**: Stdlib specification (YAML frontmatter `.md` files) and, from M1, design notes in `spec/design/`
- **`/packages/language-server`**: Language server written in Lus (module namespace `lus-language`)
- **`/packages/vscode`**: VSCode extension (TypeScript + WASM)
- **`/packages/site`**: Website (Astro + MDX)
- **`/packages/textmate`**: TextMate grammar (shared by site and extension)
- **`/examples`**: Runnable examples, shown on the site and in the playground
- **`/packaging`**: Install scripts, third-party notices, and dependency licenses
- **`/tools`**: Generators (spec to LSP data, spec to grammar) and the repository lint

The JavaScript packages form one pnpm workspace with a single lockfile at the root. mise pins the toolchain and is the task runner. Run `mise tasks` to list the tasks.

## Build Commands

### Workspace

```sh
mise run install       # pnpm install --frozen-lockfile
mise run gen           # regenerate LSP stdlib data and TextMate grammars from spec/
mise run gen:check     # fail if generated files are stale
mise run lint          # repository prose and naming checks
mise run site          # build the website
mise run vscode        # build the VSCode extension
```

### Legacy runtime (C, frozen)

```sh
cd legacy/lus
meson setup build
meson compile -C build
meson test -C build --suite h1 --suite h2
```

The legacy tests run with `legacy/` as their working directory. The `legacy/lus-language` symbolic link points at `packages/language-server` so the language server tests resolve their modules.

### Website

```sh
cd packages/site
pnpm dev          # dev server
pnpm build        # production build
```

## Architecture Notes

### Lus Language vs Lua

Lus extends Lua 5.5 with: `catch` (replaces `pcall`/`xpcall`), `enum`, optional chaining (`?.`), string interpolation (backticks), `from` destructuring, if/while-assignment, `pledge` permissions, `vector` buffers, workers, slices, `table.clone`, do-expressions (`provide`), runtime attributes, local groups, compile flags, queries, and new stdlib (JSON, CSV, filesystem, networking, compression, time, SQLite, transcoding). Lus 2.0 keeps every one of these and adds `continue`, `range`, bigint and decimal number literals, WTF-8 strings indexed by character, `lus test`, `lus debug`, and `lus doc`.

All Lus source files use `.lus` extension. Code blocks in documentation use ` ```lus ` fencing.

### Legacy C Runtime Internals

The legacy runtime is a modified Lua 5.5 codebase. These notes apply only when reading `legacy/` as a reference. New types added to the GC system:
- `LUA_TENUM` / `LUA_TENUMROOT`: first-class enums (`lenum.c`, `lenum.h`)
- `LUA_TVECTOR`: mutable byte buffers (`lvector.c`)

New libraries: `ljsonlib.c`, `lfslib.c`, `lnetlib.c`, `lworkerlib.c`, `lvectorlib.c`. Permissions: `lpledge.c`. AST: `last.c`. Bundling: `lbundle.c`.

The legacy VM intrinsifies common stdlib calls as `OP_FASTCALL` (`lfastcall.c`), so a fastcalled builtin has two implementations, and the two must agree bit for bit. A whole class of 1.7.0 bugs came from them disagreeing. Lus 2.0 removes this class by construction: every builtin is written once in Zig and the fast call path is generated from the same definition.

### Website Content

Manual pages are MDX files in `packages/site/src/manual/`. Cross-references use `/manual/guide#section-slug` and `/manual/acquis-N` formats. The acquis pages document individual language features. The guide is the comprehensive reference.

### Writing Acquis and Documentation

Acquis are tracked both as GitHub issues (label `📗 acquis`, assigned to a version milestone) and as MDX pages. Whenever you write an acquis, or any project prose (docs, changelog, spec `.md`, comments), follow these rules:

- **Frame everything positively.** Describe what the design is and does. Never describe it in terms of an alternative the reader has not seen. Phrasing like "there is no `tolist` method", "instead of a new global", "not an object", or "clauses rather than methods" implies an earlier proposal that exists only in your head, and the reader has no context for it. State the actual behavior instead ("the only way to run a query is the `query` iterator"). Comparisons to features that already ship, or to concepts every reader knows, are fine.
- **No em dashes or en dashes.** Rewrite the sentence so the dash is unnecessary rather than swapping it for a hyphen. The repository is kept free of both, and `tools/lint-repo.js` enforces it.
- **No semicolons.** Write separate full sentences.
- **Use full sentences and flowing paragraphs**, including complete-sentence lead-ins before code blocks.
- **Never name the Roblox Lua dialect** anywhere in the repository: code, comments, docs, design notes, or commit messages. Describe techniques neutrally (for example "slot-prediction inline caches" or "goal-based GC pacer"). `tools/lint-repo.js` enforces this too.

Before posting an issue or committing prose, run `node tools/lint-repo.js`, grep for semicolons, and reread for any wording that presumes a rejected alternative.

### Spec → Language Server Pipeline

`spec/stdlib/` contains one `.md` per stdlib entry with YAML frontmatter (`name`, `kind`, `module`, `params`, `returns`, `stability`). Running `node tools/build-lsp.js` generates `packages/language-server/analysis/stdlib_data.lus`, which the language server uses for completions, hover, and linting. `node tools/build-grammar.js` generates both TextMate grammar copies from the same spec.

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

Zig code is formatted with `zig fmt`. Legacy C code is formatted with clang-format (config at `legacy/lus/.clang-format`): LLVM base style, 2-space indent, 80-column limit, `else` on new line after `}`, pointers right-aligned (`char *p`). Never sort includes.

Lus code uses 4-space indentation. Global variables must be declared with `global` at the top of the file. Permissions are pledged immediately after globals.
