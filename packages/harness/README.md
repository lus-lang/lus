# Lus harness for Pi

The Lus harness extends [Pi](https://pi.dev), a terminal coding agent, for writing programs in Lus and for working on Lus itself. It adds the Lus language server, the `lus` command line as tools, permission-aware runs of Lus scripts, the Lus agent skills as context, and a theme in the colors of lus.dev. Inside the Lus repository it also adds the build lock, the mise tasks, the conformance suite under every JIT mode, and the prose lint.

The harness consists of Pi extensions, two themes, and an installer. Pi is a separate program that the installer finds on `PATH` or installs with its own installer from pi.dev, so no code of Pi is part of the Lus repository.

## Installing

In a checkout of the Lus repository, run the installer from the checkout. It writes a `lush` launcher into `~/.lus/bin` that loads the harness from the checkout:

```sh
sh packages/harness/install.sh
```

Outside a checkout, run the installer from lus.dev. It downloads the harness from the source archive of the Lus release that matches the installed `lus`, or from the `main` branch for a development build of `lus`:

```sh
curl -fsSL https://lus.dev/harness.sh | sh
```

`lush` accepts every option of `pi` and starts Pi with the harness loaded. The harness uses the Pi settings, logins, and packages of the person who runs it. `pi` without the launcher starts with none of the harness. The installer asks before it installs Pi, unless `--yes` is given. It also accepts `--name` to rename the launcher, `--ref` to select the release to download, and `--uninstall` to remove the launcher and the downloaded files.

The tools need a Lus 2 runtime. They run the first `lus` that reports version 2 or later among `$LUS_BIN`, the runtime built in `runtime/zig-out/bin` when the working directory is inside the Lus repository, `~/.lus/bin/lus`, and the `lus` on `PATH`.

## Writing programs in Lus

Every edit or write of a `.lus` file returns the diagnostics of the file with the result, so the agent sees an error on the turn that caused it. The diagnostics come from `lus check`, which reports syntax errors at their column with a hint, and from the language server, which adds what it finds on the other lines. Hints are left out, so the agent reads only errors and warnings. The language server starts on the first edit of a Lus file and stops when the session ends.

The harness adds the following tools.

| Tool | Runs |
| --- | --- |
| `lus_check` | `lus check --json` on files and directories. |
| `lus_fmt` | `lus fmt --write` on the files that `lus fmt --check` lists. |
| `lus_test` | `lus test`, with a filter, snapshot updates, or documentation tests. |
| `lus_doc` | `lus doc` on one module, returning its Markdown reference. |
| `lus_lsp` | A hover, definition, references, or symbols request to the language server. |
| `lus_run` | A script under explicit `-P` grants, as the next section describes. |

`/check`, `/fmt`, `/test`, and `/doc` ask the agent to run the matching tool, which puts the result into the conversation for the next prompt. The `lus`, `lus-rewrite`, and `lus-writing` skills load from `.agents/skills`. The system prompt includes the index of the Lus documentation from `llms.txt`.

## Running scripts with permissions

A script that `lus` starts without the `-P` option may pledge any permission, so `lus_run` always passes `-P` grants, which limit what the script may pledge to what the grants cover. Reading the project directory and loading modules are granted on every run. For every other permission, the person running the agent chooses between allowing it once, allowing it for the rest of the session, and denying it.

Before a run, `lus_run` collects the permissions that the agent requests and the literal `pledge` calls of the script, then asks about the ones that no grant covers yet. When a run stops with a `permission "NAME" denied for 'VALUE'` error, `lus_run` asks about the grant that covers that value and runs the script again once the person allows it. A grant for a network value names the host of the URL. A grant for a file names its absolute path. A script that wrote files or sent requests before the error repeats that work on the second run.

A `lus script.lus` command that the agent types into the shell without `-P` is blocked with a message that names `lus_run`. For a shell command with `-P` grants, the harness asks the person about every grant beyond reading the project and loading modules. `/grants` shows how many grants the session holds. `/grants clear` drops them.

## Working on Lus

Repository mode turns on when the working directory is inside the Lus monorepo. It adds the following tools.

| Tool | Runs |
| --- | --- |
| `lus_build` | `zig build -j2` in `runtime` under `tools/with-build-lock.sh`, showing the holder of the lock while it waits. |
| `mise_task` | `mise run` on a task of `mise.toml`, or lists the tasks. |
| `lus_conformance` | `tests/conformance` and the language server tests with the built runtime, once per JIT mode. |

A shell command that starts `zig build` runs under the build lock with at most two jobs. A mise task whose own commands start `zig build` outside the lock also runs under the lock, unless the task or one of its dependencies takes the lock itself, because that inner lock would then wait forever for the outer one. After an edit of a tracked file, the result includes the findings of `tools/lint-repo.js` for that file. A Markdown file is also checked against the semicolon rule of `spec/design/style.md`. The system prompt includes `runtime/HACKING.md`. `/build`, `/conformance`, `/mise`, and `/lint` ask the agent to run the matching tool.

## Appearance

Tool calls are flat rows: a bullet, a verb, the argument, and the result on the lines under it. The bullet is lime when the call succeeds and red when it fails. An edit shows its diff with line numbers, with added lines on a lime tint and removed lines on a red tint. The diagnostics of the file follow the diff. The left side of the footer holds the Lus state, such as the runtime version, the language server, the grants, and the build lock. The right side holds the model, the context use, and the token counts.

The `lus` theme is for dark terminals and `lus-light` for light ones. The launcher selects `lus-light/lus`, which follows the appearance of the terminal, unless the command line names a theme with `--use-theme` or `LUS_HARNESS_THEME` names one.

## Development

Run the unit tests of the rules, the parsers, and the installer from `packages/harness`. The installer tests run against stub `pi` and `lus` commands:

```sh
node --experimental-strip-types --test test/*.test.ts
```

To run a whole session without a network, load `test/script-provider.ts` beside the harness. It is a Pi extension that registers a model named `script`, which answers each turn with the next step of the JSON file named by `LUS_HARNESS_SCRIPT`:

```sh
LUS_HARNESS_SCRIPT=steps.json pi -e packages/harness -e packages/harness/test/script-provider.ts \
  --provider script --model script -p "go"
```

A step is a string, which the model answers as text, or a list of tool calls such as `[{"tool": "lus_check", "args": {"paths": ["."]}}]`. `LUS_HARNESS_DEBUG` names a file that receives a line for each diagnostic request and each change of the language server.
