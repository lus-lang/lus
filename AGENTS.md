# AGENTS.md

This file guides coding agents that work in this repository.

## Repository Structure

Monorepository for the Lus programming language, which began as a fork of Lua 5.5. Key directories:

- **`/runtime`**: The runtime in Zig: front end, compiler, VM, GC, JIT tiers, standard library, C interface, and the `lus` command line tools. `runtime/HACKING.md` is the map of its sources.
- **`/tests`**: Conformance tests (`tests/conformance/*_test.lus`), embedding tests for the C interface (`tests/embed`), tool tests (`tests/build`, `tests/check`, `tests/doc`, `tests/debug`), and benchmarks (`tests/bench`, never gating)
- **`/spec`**: Stdlib specification (YAML frontmatter `.md` files) and design notes in `spec/design/`
- **`/packages/wasm`**: The runtime as a WebAssembly module, with its JavaScript host and WebAssembly JIT
- **`/packages/language-server`**: Language server written in Lus (module namespace `lus-language`)
- **`/packages/vscode`**: VSCode extension (TypeScript + WASM)
- **`/packages/site`**: Website (Astro + MDX)
- **`/packages/textmate`**: TextMate grammar (shared by site and extension)
- **`/examples`**: Runnable examples, shown on the site and in the playground
- **`/packaging`**: Install scripts, release anchors, third-party notices, and dependency licenses
- **`/tools`**: Generators (spec to LSP data, spec to grammar) and the repository lint
- **`/.agents`**: Agent skills (`lus`, `lus-rewrite`, `lus-writing`), the `llms.txt` index, and agent prompts. `.claude/skills` is a symbolic link to `.agents/skills`, and `spec/design/agents.md` describes the design

The JavaScript packages form one pnpm workspace with a single lockfile at the root. mise pins the toolchain and is the task runner. In a fresh clone, run `mise trust` once so mise reads `mise.toml`, then `mise install` for the toolchain. Run `mise tasks` to list the tasks.

## Build Commands

### Workspace

```sh
mise run install       # pnpm install --frozen-lockfile
mise run gen           # regenerate LSP stdlib data and TextMate grammars from spec/
mise run gen:check     # fail if generated files are stale
mise run lint          # repository prose and naming checks, and zig fmt
mise run site          # build the website
mise run vscode        # build the VSCode extension
```

### Runtime

```sh
mise run build         # zig build -Doptimize=ReleaseSafe, writes runtime/zig-out/bin/lus
mise run test          # unit, embedding, and tool tests, then the conformance suite and doc tests
mise run wasm:test     # build lus.wasm and run its host tests
mise run wasm:conformance
```

The test steps of `zig build` do not reinstall `zig-out/bin/lus`, so build before running `lus test` by hand. The conformance suite runs with `lus test ../tests/conformance ../packages/language-server/tests` from `runtime/`. Run it under every JIT mode a change can reach: `LUS_JIT=off`, the default, `LUS_JIT=eager`, and `LUS_JIT=opt-eager`. A change to the heap, a store, or the JIT also needs a run of a `-Dgc-stress=97 -Dgc-verify=true` build. `lus test --doc ../packages/site/src/manual ../spec ../.agents` runs the code blocks of the manual, the spec, and the agent skills.

### Website

```sh
cd packages/site
pnpm dev          # dev server
pnpm build        # production build
```

## Architecture Notes

### Lus Language vs Lua

Lus began as a fork of Lua 5.5 and is one language of its own. Next to the Lua core it has `catch` (replaces `pcall`/`xpcall`), `enum`, optional chaining (`?.`), string interpolation (backticks), `from` destructuring, if/while-assignment, `pledge` permissions, `vector` buffers, workers, slices, `table.clone`, do-expressions (`provide`), runtime attributes, local groups, compile flags, queries, and new stdlib (JSON, CSV, filesystem, networking, compression, time, SQLite, transcoding). It also has `continue`, bigint and decimal number literals, WTF-8 strings indexed by character, detached coroutines with sockets as suspension points, `network.serve`, and the `lus test`, `lus fmt`, `lus check`, `lus debug`, and `lus doc` tools.

All Lus source files use `.lus` extension. Code blocks in documentation use ` ```lus ` fencing.

### Runtime Internals

`runtime/HACKING.md` describes the source layout, the conventions, and the checks each kind of change needs. The design notes in `spec/design/` record the decisions behind numbers, strings, permissions, tables, the GC, and the JIT tiers. Every builtin is written once in Zig, and its fast call path is generated from the same definition, so the interpreter, the baseline JIT, and the optimizing tier agree by construction.

### Website Content

Manual pages are MDX files in `packages/site/src/manual/`. Cross-references use the `/manual/page#section-slug` format. The guide is the comprehensive reference for the language. The topic pages in the `library` and `use` groups, such as `/manual/permissions` and `/manual/testing`, document a library or a tool in full.

### Writing Documentation

Whenever you write any project prose (docs, changelog, spec `.md`, comments), follow these rules, and follow the style guide in `spec/design/style.md`:

- **Frame everything positively.** Describe what the design is and does. Never describe it in terms of an alternative the reader has not seen. Phrasing like "there is no `tolist` method", "instead of a new global", "not an object", or "clauses rather than methods" implies an earlier proposal that exists only in your head, and the reader has no context for it. State the actual behavior instead ("the only way to run a query is the `query` iterator"). Comparisons to features that already ship, or to concepts every reader knows, are fine.
- **No em dashes or en dashes.** Rewrite the sentence so the dash is unnecessary rather than swapping it for a hyphen. The repository is kept free of both, and `tools/lint-repo.js` enforces it.
- **No semicolons.** Write separate full sentences.
- **Use full sentences and flowing paragraphs**, including complete-sentence lead-ins before code blocks.
- **Never name the Roblox Lua dialect** anywhere in the repository: code, comments, docs, design notes, or commit messages. Describe techniques neutrally (for example "slot-prediction inline caches" or "goal-based GC pacer"). `tools/lint-repo.js` enforces this too.

Before posting an issue or committing prose, run `node tools/lint-repo.js`, grep for semicolons, and reread for any wording that presumes a rejected alternative.

### Spec → Language Server Pipeline

`spec/stdlib/` contains one `.md` per stdlib entry with YAML frontmatter (`name`, `kind`, `module`, `params`, `returns`, `stability`). Running `node tools/build-lsp.js` generates `packages/language-server/analysis/stdlib_data.lus`, which the language server uses for completions, hover, and linting. `node tools/build-grammar.js` generates both TextMate grammar copies from the same spec. `node tools/build-llms.js --out DIR` builds the agent documentation from the spec, the manual, and `.agents/`: `llms.txt`, `llms-full.txt`, `llms-small.txt`, and a Markdown copy of every manual page.

## Code Style

Zig code is formatted with `zig fmt`, and `mise run lint` checks it. C code in `tests/embed` and in the documentation uses 2-space indentation.

Lus code is in the strict style that `lus fmt --strict` writes and `lus check --strict` checks, which the [strict style](https://lus.dev/manual/tools#the-strict-style) section of the manual describes rule by rule. Run `lus fmt --strict --write` on the files you change and fix what `lus check --strict` reports. Global variables are declared with `global` at the top of the file, and permissions are pledged immediately after the globals.

Lus code is idiomatic Lus, everywhere: in the runtime tests, the language server, the examples, the manual, atmosphere, and the atmos packages. Before you finish a change, read every line of Lus you wrote and ask whether it uses a Lua idiom where Lus has a better feature. The checks below cover the common cases. `lus check` reports many of them as hints, and `lus check --fix` rewrites the ones where the rewrite keeps the behavior.

| Lua idiom | Lus feature |
|---|---|
| `a and a.b and a.b.c` | `a?.b?.c` |
| `"x=" .. x`, `string.format("%s", x)` | `` `x=$x` ``, `` `x=$(x + 1)` `` |
| `pcall(f, ...)`, `xpcall` | `catch f(...)`, `catch[handler] f(...)` |
| `local a, b = t.a, t.b` | `local a, b from t` |
| `local v = f() if v then` | `if v = f() then` |
| `goto continue` | `continue` |
| string constants for a fixed set of values | `enum` |
| a temporary local that only feeds one expression | a `do` expression with `provide` |
| copying a table in a loop | `table.clone` |
| a loop that filters, sorts, or groups a table | a query with `@` |
