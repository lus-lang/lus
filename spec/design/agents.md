# Lus for agents

This note records how Lus serves coding agents: the skills and documentation it ships, the skill that rewrites projects in Lus, the site entrance for people who work through an agent, and the homepage. The skills and the curated index live in `.agents/`, and the roadmap at the end lists what remains to build.

## Premise

More and more code is written by agents and read by nobody. A person adopts a language today by asking an agent to use it, so Lus wins adoption when agents write correct Lus on the first try, find out fast when they did not, and can move an existing project onto Lus safely. The design has four parts: what Lus ships for agents, a skill that rewrites projects in Lus, a site entrance for people who work through an agent, and a homepage about what Lus does for software.

## 1. Skills and documentation for agents

### How tools publish for agents today

The conventions have settled into four layers, and the projects that agents handle best ship all of them.

| Layer | What it is | Who ships it |
| --- | --- | --- |
| `llms.txt` | A Markdown index at the site root: a title, a summary, and sections of links to Markdown pages. Variants carry the whole documentation (`llms-full.txt`) or a version sized for small contexts (`llms-small.txt`, `llms-medium.txt`). | Svelte ships all four sizes. Deno ships an index, a full file, and an AI entry page that links every agent resource. Context7 indexes `llms.txt` files and reads a `context7.json` in the repository. |
| Markdown pages | Every documentation page also served as Markdown at a predictable URL, often with a "copy as Markdown" button. | Most documentation platforms now do this by default. |
| Agent skills | A folder with a `SKILL.md` whose frontmatter `name` and `description` tell the agent when to load it, plus reference files it reads on demand. Anthropic published the format as an open standard in December 2025, and the Agentic AI Foundation now maintains it. Claude Code, Codex, Cursor, GitHub Copilot, VS Code, and Gemini CLI read it. `.agents/skills/` in a repository is becoming the shared discovery path. | Deno keeps its skills in a separate repository. Svelte publishes skills alongside its documentation. |
| MCP servers | Tools an agent calls over a protocol, such as documentation search or a checker. | Svelte runs an MCP server whose autofixer statically checks generated components for common model mistakes. |

Project rule files such as `AGENTS.md` and `CLAUDE.md` sit beside these as per-repository instructions, and a skill installer usually adds a line to them.

### What Lus ships

Lus has an advantage most languages lack: the documentation, the checker, and the runtime come from one repository and one release. Lus ships the agent layer from the same place, versioned with the binary.

| Artifact | Source | Built by | Served at |
| --- | --- | --- | --- |
| `llms.txt` | `.agents/llms.txt`, curated by hand, with links checked | site build | `lus.dev/llms.txt` |
| `llms-full.txt` | the guide, the CLI page, the topic pages, and the API reference from `spec/stdlib` | `tools/build-llms.js` | `lus.dev/llms-full.txt` |
| `llms-small.txt` | `.agents/skills/lus/references/language.md` and one line per stdlib function: signature, permissions, stability | `tools/build-llms.js` | `lus.dev/llms-small.txt` |
| Markdown pages | every manual page with MDX components rendered to Markdown | `tools/build-llms.js` | `lus.dev/manual/NAME.md` |
| Skills `lus`, `lus-rewrite`, and `lus-writing` | `.agents/skills/` | copied as is | `lus.dev/agents/skills/`, the GitHub repository, and inside the `lus` binary |
| Agent entry page | `.agents/prompt.md` and a short intro | site build | `lus.dev/agents` and `lus.dev/agents.md` |
| `context7.json` | repository root | by hand | read by Context7 |

Measured on the current tree, the manual and the stdlib spec together hold about 425 KB of text, roughly 105,000 tokens, which suits `llms-full.txt`. The stdlib spec alone is 116 KB and compresses to 25 KB with zstd.

#### Where the files live

The `.agents/` folder at the repository root holds everything agents consume directly: the skills, the curated `llms.txt`, and the prompts. `.agents/skills/` is the shared discovery path that agents across tools read, so an agent working in the Lus repository itself loads the Lus skills, and skill installers that read a GitHub repository find them at the same path. For tools that read only their own folder, `.claude/skills` is a symbolic link to `.agents/skills`, so each skill has one copy. The same files ship in the binary, the repository, skill registries, and the site. The generated files are build outputs of the site, produced by Astro endpoints the same way `install.sh.ts` serves `packaging/install/install.sh`, so nothing generated is committed and nothing goes stale.

#### Skills in the binary

`lus agents init` writes the skills that match the installed runtime into `.agents/skills/` of the current project, links `.claude/skills` to that folder, and writes a short Lus section to `AGENTS.md`. Each run rewrites the skills and the text between the markers of that section, so both follow the installed runtime, and the rest of `AGENTS.md` stays as its authors wrote it. A section from a version before the end marker is recognized by its first sentence and upgraded. Any other text after a lone start marker is left alone. `lus help NAME` prints the spec entry for a function, such as `lus help network.serve`, from documentation compiled into the binary. The agent then reads documentation for exactly the version it runs, offline, with nothing fetched from the network at install time. The stdlib spec and the skills add about 205 KB to a 6.8 MB executable, embedded as plain text by a module that `build.zig` generates. `lus help MODULE` lists a module, and `lus help --search TEXT` searches names and descriptions. Both commands are in place.

#### The skills

- [`.agents/skills/lus/SKILL.md`](../../.agents/skills/lus/SKILL.md) teaches the check, format, and test loop, the file header with `global` and `pledge`, the standard library map, and the idioms the checker expects. [`references/language.md`](../../.agents/skills/lus/references/language.md) lists every difference from Lua that changes generated code, with runnable examples.
- [`.agents/skills/lus-rewrite/`](../../.agents/skills/lus-rewrite/SKILL.md) is the rewrite skill from part 2.
- [`.agents/skills/lus-writing/`](../../.agents/skills/lus-writing/SKILL.md) carries the prose style guide of `spec/design/style.md` to other repositories. `tools/build-skills.js` generates its reference file from that note.
- [`.agents/llms.txt`](../../.agents/llms.txt) is the index, grouped by task.
- [`.agents/prompt.md`](../../.agents/prompt.md) holds the prompts for part 3.

### Keeping it in sync

- `tools/build-llms.js` reads the same frontmatter as `tools/build-lsp.js`, so the language server, the grammar, and the agent documentation share one source. The `pledges` and `stability` fields in `spec/stdlib` go straight into `llms-small.txt`.
- `tools/build-llms.test.js` checks that every stdlib entry appears in `llms-small.txt`, that every link in `llms.txt` resolves to a page the site builds, that no MDX syntax survives into Markdown output, and that `llms-small.txt` stays under 25,000 tokens. It runs in `mise run gen:check`.
- `mise run test` runs `lus test --doc ../.agents` beside the manual and the spec, so every code block in the skills runs on every change. Writing the skills already caught three mistakes this way: a `+=` that Lus does not parse, a missing `assert` in a `global` declaration, and a `$` that needed escaping in an interpolated string.
- `node tools/lint-repo.js` covers `.agents/` like the rest of the repository.
- A shortdesc audit fixes manual frontmatter that the index quotes, such as a description that still names command line options that became `lus ast`.

### Fast feedback for agents

The tools an agent calls after every edit decide how quickly it converges. `lus check --json`, `lus test --json`, and `lus fmt --check` already give structured, stable output. Writing the skills surfaced the gaps below, in order of value. The first three are in place.

1. **Directories.** Agents pass directories by habit. `lus check src` and `lus fmt --check src` read every `.lus` file below `src`, in sorted order, and leave out `node_modules`, `.git`, `zig-out`, and `.zig-cache`.
2. **Test files in the checker.** `lus check` applies the test conventions to `*_test.lus` files. The helpers `snapshot`, `raises`, `same`, `skip`, and `TEST_DIR` count as defined, and the top-level locals `NAME_test` and `NAME_cases` that the runner reads count as used.
3. **Hints for common model mistakes.** A syntax error on a construct from another language names the Lus spelling: `x += 1` reads `syntax error near '+' (update a variable with 'x = x + y')`. The hints cover compound assignment for every binary operator, `++`, `!=`, `!`, `&&`, `||`, and `//` comments, and `undefined-global` on `null` points to `nil`.
4. **`lus check --fix`** applies the rewrites that `deprecated-pcall`, `use-from`, `use-optional-chain`, and `use-if-assign` already detect.
5. **Inferred permissions.** The spec records which permissions each function needs. `lus check --pledges FILE` prints the narrowest pledge line for a file, and a `missing-pledge` warning flags a call that no pledge in the file covers. This turns the most common runtime failure of generated Lus into a compile-time message.
6. **Documentation links.** Each diagnostic in `--json` output gains a `docs` field with the URL of its explanation.
7. **Named cases.** A case table with string keys names each run after its key, so a parity failure reads `parity_test[empty.txt]` and the agent sees which input broke.

### The language server for agents

`lus lsp` runs the language server that is built into `lus`, so a coding agent with a Language Server Protocol client reads diagnostics after each edit without calling `lus check`. The `lus` plugin of Claude Code registers the server in `lspServers` of `.agents/.claude-plugin/plugin.json`, so installing the plugin installs the skills and the server together. The manual page `/manual/ide-setup` gives the configuration for opencode, Neovim, Helix, Sublime Text, and Emacs. An agent without a client, such as Codex, runs `lus check --json` on the files it changes.

### Measuring whether it works

`tests/agents/` holds a small set of tasks, each a prompt plus hidden acceptance tests: write a CSV summarizer, serve a JSON API, port a 200-line Python script. A runner gives each task to a headless agent with only the Lus skill installed and records whether `lus check` is clean and the hidden tests pass, with and without the skill. It never gates a merge, like the benchmarks, and it shows which skill edits actually help.

### MCP

An MCP server comes last. Coding agents already run shell commands, and the skill plus the JSON output of the CLI covers them. A `lus mcp` command becomes worthwhile for chat clients without a shell: it would expose `check`, `fmt`, `test`, `help`, and a `run` tool that executes code under an explicit pledge set, which the permission system makes safe to offer.

## 2. The rewrite skill

The skill is [`.agents/skills/lus-rewrite/SKILL.md`](../../.agents/skills/lus-rewrite/SKILL.md) with three references: the [decision rubric](../../.agents/skills/lus-rewrite/references/rubric.md), the [parity harness templates](../../.agents/skills/lus-rewrite/references/harness.md), and a [porting map](../../.agents/skills/lus-rewrite/references/porting.md) from common libraries to the Lus standard library.

### Phases

| Phase | Work | Artifact in `.lus-rewrite/` | Checkpoint |
| --- | --- | --- | --- |
| 0. Assess | Read the code, list interfaces and dependencies, apply the rubric, list every improvement with evidence | `assessment.md` with a verdict | The user decides whether to continue. |
| 1. Preview | Port one leaf module that shows a clear gain, checked and formatted, beside the original | `preview/` and its README | The user sees real Lus for their code. |
| 2. Harness | Inventory behaviors, build a corpus, record the original into golden files, prove the harness passes on the original and fails on an altered golden file | `behaviors.md`, `harness/`, `progress.md` | The harness is trusted. |
| 3. Port | Slices in dependency order, each with unit tests, a narrow pledge, and a green harness. Dependencies decided one by one. | source files, `dependencies.md`, `progress.md` | Each slice is marked done with its harness result. |
| 4. Measure | Final harness run, time, memory, and shipped size against the original, `lus build` | `report.md` | The user decides when to retire the original. |

### When not to rewrite

The rubric begins with hard stops, and one yes ends the in-place rewrite. A project that other programs link against or import in its own language, such as a C++ library or an npm package, keeps its language, because a rewrite would break every user. The skill then offers a fork under a new name, a new major version announced as a language change, or a Lus companion such as a command line front end that embeds the library through `lus.h`. A project whose core lives in one ecosystem, such as a GUI toolkit or a GPU framework, gets a partial verdict that moves only the scripting, tooling, or service layer. In every case the user still receives the table of improvements Lus would bring, since that is what they asked for.

### Proving sameness

The harness records the original once and keeps the recordings, so it outlives the original program. It is a set of ordinary `*_test.lus` files: a recorder runs the original over each case with `io.popen` and stores output and exit status, and a parity test runs the port through a case table and compares. The power assert shows both outputs on a mismatch. The templates, run verbatim on a toy project, passed on a correct port and caught a deliberately broken one with both outputs shown.

The same run found a runtime bug. Reading standard input with `io.lines()` makes the current ReleaseSafe build print `error(SafeAllocator): leaked ... len: 98432` to standard error at exit, which breaks any parity check that captures standard error. The runtime fix belongs to the runtime workstreams.

## 3. A site entrance for people who use agents

This lands after the website 2.0 restyle merges, and follows its "Field instrument" design. Nothing in `packages/site` changes before then.

### The install block

The masthead install block carries a two-way switch: `agent` and `shell`, with the agent side shown first. The agent side holds one prompt in a monospace box with a copy button. The shell side holds `curl -fsSL https://lus.dev/install.sh | sh`, or the Windows installer on Windows.

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh`. Then add the Lus skills. In Claude Code, run `claude plugin install lus --marketplace lus-lang/lus`. In any other agent, run `lus agents init` in this project. Use one method. You can read the skill first at https://lus.dev/agents/skills/lus/SKILL.md. Then use the lus skill to look at this project and tell me where Lus would help. Change nothing yet.
```

The prompt installs the skills the way each agent expects. Claude Code takes them as a plugin from the marketplace in `.claude-plugin/marketplace.json`, whose one plugin is the `.agents` folder itself. Every other agent takes them from `lus agents init`, which needs nothing beyond the runtime the first sentence installs. The prompt links the skill so the agent, or a careful reader, can read it before installing, and it ends on a request for an assessment, which is the first phase of the rewrite skill and the safest first step for any codebase. Under the box, one link reads `what this does`, and it opens `/agents`.

### The agents page

`/agents`, also served as `/agents.md`, is the single entry point for agent resources, in the spirit of the AI entry page of Deno: the three prompts from `.agents/prompt.md`, `lus agents init` and the registry install lines, links to `llms.txt` and its variants, the skills with their contents, and the rules for agents that work in this repository. The site header gains an `agents` link beside `manual`.

### Every page as Markdown

Each manual page gets a `copy as Markdown` control in the restyle's quiet style, and its Markdown twin lives at the same path with `.md` appended. An agent that lands on any page can read it in full without parsing HTML.

## 4. The homepage

The page reads in this order: the masthead with the agent prompt and the news, the releases standing on the horizon rule, the standard library index, the benchmarks, then the sections below. The sections below take the place of "Lus at a glance" entirely and speak about what Lus does for a program. Syntax lives in the manual and the playground. Each section is a heading, one sentence, and one piece of evidence: a number, a short code block, or a list. The copy follows the site style of compact facts.

### Fast

**Heading:** Faster than the runtimes you use today
**Line:** A two-tier JIT and a generational, parallel collector put Lus ahead of Bun, Node.js, Python, Ruby, PHP, and Lua on six everyday programs, in time and in memory.
**Evidence:** The benchmarks section the restyle already renders from `benchmarks.json`. The speed and memory workstreams aim for Lus to lead every program in the suite on both measures, and the copy is written for that result. The component builds the list of runtimes in the line from `benchmarks.json` at build time, naming each runtime Lus leads on every program, so the sentence matches the chart at every release.

### Batteries

**Heading:** Everything in one binary
**Line:** The libraries most projects install come with the runtime.
**Evidence:** A dense list: JSON · CSV · SQLite · HTTP client and server · TCP · UDP · TLS · gzip · zstd · brotli · lz4 · hashes and signatures · time zones · bigints and decimals · workers · test runner · formatter · checker · debugger · bundler.

### Permissions

**Heading:** Every program states what it touches
**Line:** A script reaches files, the network, processes, and the environment only with the permissions it pledges, which the grants of `lus -P` bound.
**Evidence:**

```lus nocheck
pledge("fs:read=./data/**", "network:http=api.example.com")
pledge("seal")
```

### Concurrency

**Heading:** Thousands of connections, plain code
**Line:** Sockets suspend only the coroutine that waits, so a server reads top to bottom.
**Evidence:**

```lus nocheck
network.serve("0.0.0.0", 8080, function(req)
    local status, body = network.fetch(`http://inventory.internal$(req.path)`)
    return status, body
end)
```

### Everywhere

**Heading:** Script, server, executable, library, browser
**Line:** The same code runs as a script, ships as one file with `lus build`, embeds in C and Zig hosts through `lus.h`, and runs in the browser as WebAssembly.
**Evidence:** Five short labeled commands, one per target.

### Small

**Heading:** About 7 MB, nothing else to install
**Line:** One executable carries the runtime, the libraries, and the tools.
**Evidence:** The size of the release archive for the visitor's platform, read from the release data at build time.

### Built for agents

**Heading:** Your agent already knows how
**Line:** Skills, Markdown documentation, and a checker with structured output let any coding agent write, test, and port Lus.
**Evidence:** The agent prompt from the masthead and a link to `/agents`.

## Roadmap

1. **Repository.** The skills, `llms.txt`, and the prompts in `.agents/`, with `lus test --doc ../.agents` in `mise run test`. `tools/build-llms.js` builds every agent file into a directory with `pnpm run llms -- --out DIR`, `mise run gen:check` validates its output, and `tools/build-llms.test.js` runs in `pnpm run test:tools`. Today `llms-small.txt` holds about 7,700 tokens and `llms-full.txt` about 95,000.
2. **Runtime.** Directories in `check` and `fmt`, the test-aware checker, hints for common mistakes, `lus agents init`, and `lus help` are in place. Next come `check --pledges` with `missing-pledge`, `check --fix`, documentation links in diagnostics, named cases.
3. **Site.** The site serves `llms.txt`, `llms-small.txt`, `llms-full.txt`, `agents.md`, `benchmarks.md`, the skills, and a Markdown twin of every manual page, all built by `tools/build-llms.js` through `packages/site/src/lib/llms.ts`. The masthead offers an agent and shell switch that opens on the agent prompt, the header links `/agents`, manual pages announce and link their Markdown twins, and the homepage section "In your software" replaces "Lus at a glance". Its speed line comes from `lib/lead.ts`, which names the runtimes Lus beats on every program in time and memory and otherwise states what was measured.
4. **Reach.** The agent task suite, `context7.json`, listings in skill registries, and `lus mcp`.

## Decisions

1. The skills live in `.agents/skills/`, the shared discovery path, and `.claude/skills` is a symbolic link to that folder. The index and the prompts sit beside them in `.agents/`.
2. The binary embeds the skills and the reference, for `lus agents init` and `lus help`, at a cost of about 205 KB.
3. The masthead prompt installs Lus, installs the skills as a Claude Code plugin or with `lus agents init`, links the skill to read first, and asks for an assessment with no changes.
4. The advantage sections replace "Lus at a glance" entirely.
5. The speed section is written for Lus leading every program in the suite, with the named runtimes derived from the benchmark data.
6. `lus mcp` comes last, after the skills, the runtime work, and the site.
