# Developer tooling against the Rust toolchain

This note maps the developer tools of Lus 2.0 against the Rust toolchain, whose cargo, clippy, and rust-analyzer many programmers already know. Each row names a Rust tool or feature, the Lus equivalent, and the state of the gap. The last sections list what Lus offers that Rust lacks and the order in which we close the gaps.

The Lus toolchain is one executable. `lus` runs scripts and holds every tool as a subcommand, which `lus --help` lists. The language server in `packages/language-server` is written in Lus. The VS Code extension in `packages/vscode` runs it as WebAssembly. Packages are published with `atmos`, the command line tool of the atmosphere registry, which lives in the `lus-lang/atmosphere` repository.

A gap is marked **closed** when Lus has an equivalent, **partial** when the equivalent covers the common case, **open** when Lus has nothing yet, and **by design** when Lus deliberately does without it. The column "Cost" estimates the work to close an open or partial gap as small (a day or less), medium (a few days), or large.

## Project and package management

Rust projects are driven by cargo and a `Cargo.toml` manifest. A Lus package is described by the doc comment header of its main module (`spec/design/modules.md`, section 6). A program names its dependencies by URL in `require`, so most cargo commands that edit a manifest have nothing to edit.

| Rust | Lus | State | Cost |
|---|---|---|---|
| `cargo new`, `cargo init` | `atmos init` creates a package from `lus-lang/atmos-template`. A program that is not a package needs a template of its own in `atmos init`. | partial | small |
| `cargo run` | `lus FILE` or `lus run FILE`. | closed | |
| `cargo build` | `lus build` writes a standalone executable, which `--aot` compiles ahead of time from a training run. `lus compile` writes a binary chunk. | closed | |
| `cargo build --target` | `lus build --runtime FILE` starts the executable from a `lus-runtime` of another platform. | partial | medium |
| `cargo test` | `lus test` with filters, parallel files, timeouts, JSON output, snapshots, and table-driven cases. | closed | |
| `cargo test -- --list` | Missing. `lus test --filter TEXT` narrows a run to matching tests. | open | small |
| `cargo bench`, criterion | Functions named `NAME_bench` in test files. `lus test --bench` measures the median time and the bytes allocated per call, and compares them with a baseline that `--bench -u` saves. A plain `lus test` calls each benchmark once. | closed | |
| `cargo doc` | `lus doc` writes Markdown or JSON per module. | partial | |
| `cargo add`, `cargo remove` | `atmos add` prints the `require` line of a package. A program removes a dependency by deleting its `require`. | closed | |
| `cargo update`, `Cargo.lock` | A stable atmosphere line receives patch releases only. A program that needs one exact release requires its pinned URL. | by design | |
| `cargo publish` | `atmos publish` checks, tags, signs, and pushes a release. | closed | |
| `cargo install` | `lus build` produces the executable, which the user copies onto `PATH`. A one-step `lus install URL` is missing. | open | medium |
| `cargo fix` | `lus check --fix` applies every rewrite that keeps what the program does. `--json` lists the edits of each fix. | closed | |
| `cargo tree` | `lus tree FILE` prints the require tree that `lus build` bundles, with the require scan of `src/modtree.zig`. | closed | |
| `cargo metadata` | `lus check --json`, `lus doc --format json`, `lus ast`, and `lus version --json` cover diagnostics, API, syntax, and installs. | partial | |
| workspaces | A directory of packages tests as one with `lus test DIR`. Packages share nothing else. | by design | |
| features | Compile-time flags (`-F name=value`) fold `if flags.name` at compile time. A package declares the flags it reads in its header. | closed | |

## Versions

| Rust | Lus | State | Cost |
|---|---|---|---|
| `rustup install`, `rustup default` | `lus version install` and `lus version use`, with signed release documents. | closed | |
| `cargo +nightly` | `lus +VERSION ARGS` runs another installed version. | closed | |
| `rust-toolchain.toml` | A program declares no version pin. | by design | |
| `rustup target add` | Runtimes for other platforms are release downloads, without a command to fetch one. | open | medium |
| `rustup doc` | `lus help NAME` prints the standard library reference offline. | closed | |

## Formatting and linting

| Rust | Lus | State | Cost |
|---|---|---|---|
| rustfmt, `cargo fmt --check` | `lus fmt` with `--check`, `--write`, and `--indent N`. The language server formats ranges. | closed | |
| `rustfmt.toml` | `--indent` is the only setting. | by design | |
| clippy | `lus check` reports each lint code with one of three severities (error, warning, hint), including speed hints measured in `spec/design/hints.md`. | closed | |
| clippy lint levels (`allow`, `warn`, `deny`) | Each code has a fixed severity. Hints never change the exit status. | partial | medium |
| `#[allow(...)]` on an item | `-- lus: allow(CODE)` covers a line, the next statement, or the whole file from the module header. | closed | |
| clippy categories (`style`, `perf`, ...) | The hint severity groups the suggestions. The code names group the rest. | partial | |
| `clippy --fix` | `lus check --fix`, for the unused names and the hints whose rewrite is exact. | closed | |
| `rustc --explain E0382` | `lus check --list` prints a one-line summary per code. `lus check --explain CODE` prints a full explanation with an example and its fix. | closed | |

## Editor support

| rust-analyzer | Lus language server and VS Code extension | State | Cost |
|---|---|---|---|
| `rust-analyzer` as a command | `lus lsp` runs the language server built into `lus`, on standard input and output, so any editor or agent harness starts it with one command. | closed | |
| diagnostics as you type | Syntax errors and every `lus check` code. | closed | |
| completion, hover, signature help | Completion with the standard library generated from `spec/stdlib`, hover with doc comments, and signature help. | closed | |
| go to definition, references, highlights | All three, across the workspace. | closed | |
| rename | Rename with `prepareRename`. | closed | |
| inlay hints | Parameter names at call sites. | closed | |
| semantic tokens | Full-document semantic tokens. | closed | |
| document and workspace symbols, folding, selection ranges | All four. | closed | |
| code actions | Quick fixes that declare a global and prefix an unused name with `_`. Every hint with a mechanical rewrite could offer one. | partial | medium |
| go to implementation | Lus has no traits. The nearest question is which tables share a metatable, which static analysis answers only for simple cases. | by design | |
| expand macro | Lus has no macros. Folded flags and `<meta>` values are the nearest equivalent. Showing their values inline is open. | open | medium |
| call hierarchy, type hierarchy | Missing. | open | medium |
| run and debug code lenses, test explorer | The extension debugs with `lus debug`, but offers no lens or test explorer. | open | medium |
| debugger | `lus debug` speaks DAP with breakpoints, stepping, pausing, stack, variables, and evaluation. | closed | |

## Documentation

| rustdoc | Lus | State | Cost |
|---|---|---|---|
| doc comments to HTML | `lus doc` writes Markdown and JSON, which the website renders. HTML output from the command itself is missing. | partial | medium |
| doctests in doc comments | `lus test --doc` runs the `lus` code blocks of Markdown files and of the doc comments of `.lus` files, with the directory of each file on `package.path`. | closed | |
| intra-doc links | Missing. | open | medium |
| search | The website searches the manual. Generated package documentation has no search of its own. | open | large |

## Diagnostics

| Rust | Lus | State | Cost |
|---|---|---|---|
| stable error codes | Every `lus check` diagnostic carries a stable code. Runtime errors carry a message and a traceback, without a code. | partial | |
| source snippets with a caret | `lus check` prints `file:line:column: severity: message [code]`, with the end position in the JSON form. A snippet with a caret under the span is missing. | open | small |
| suggestions inside the diagnostic | Hints name the better form in their message. | partial | |
| `--explain` | `lus check --explain CODE`. | closed | |

## Correctness tools

| Rust | Lus | State | Cost |
|---|---|---|---|
| miri | Lus code cannot corrupt memory, so undefined behavior can only come from the runtime, which runs under invariant checks, a verifying collector, sanitizers, allocation failure sweeps, and crash injection (`runtime/HACKING.md`). | by design | |
| cargo-fuzz | The runtime fuzzes its parser and its TLS layer. User code has no fuzz harness. | open | large |
| coverage (`cargo llvm-cov`) | `lus test --coverage` reports the lines of the code under test that ran, per file. `--coverage-out` writes them as an lcov tracefile. | closed | |
| playground | The website playground runs `lus.wasm` in the browser. | closed | |

## What Lus has that Rust lacks

- **Permissions in the toolchain.** `-P` grants a capability to a run, to a test, to `lus build`, and to `lus debug`. `lus --sandbox` seals the permissions before any code runs, so one flag runs untrusted code. `lus check` warns about pledges that cannot take effect.
- **One executable.** The interpreter, the test runner, the formatter, the checker, the debugger, the bundler, the version manager, and the standard library reference ship as one file.
- **Requires by URL.** A program requires its dependencies by URL and runs them without an install step. Signatures verify each download. `--offline` runs a program from the module cache.
- **Agent setup.** `lus agents init` writes the agent skills that match the installed version, which are the skills built into the executable.
- **Measured speed hints.** The hints of `lus check` flag slow forms of code, each with the speed ratio measured for the interpreter and the JIT.
- **Snapshot and table-driven tests built in.** `snapshot(value)` and `NAME_cases` need no library. A failed `assert` of a comparison prints both sides and the values of the variables and fields inside each side, which `assert_eq!` leaves to the programmer.
- **The syntax tree as data.** `lus ast` prints the tree as JSON with a published schema.
- **A language server in the language.** The server runs natively and as WebAssembly inside the editor, so the extension needs no native download.

## Order of work

The small gaps that remain are the caret snippet and `lus test --list`.

The medium gaps follow in this order: test lenses and a test explorer in the editor, more code actions, call hierarchy, and HTML documentation with intra-doc links and search. A fuzz harness for user code stays open.
