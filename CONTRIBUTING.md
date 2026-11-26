# Contributing

Lus is open-source, allowing you to make as many copies of it as desired and do whatever you want with those copies. Lus, however, is not fully _open-contribution_. Please submit only pull requests correcting bugs, optimizing existing code, proposing new tests for currently unaccounted edge cases, or improving the documentation.

If you _do_ make a PR, make sure to:

- [**Read the project goals.**](https://lus.dev/manual/introduction/#goals) Changes that implement a _non-goal_ or contradict a goal are rejected.
- **Test, test, test.** Run `mise run test` to make sure your changes break nothing. Compare `tests/bench` before and after to make sure you add no massive _performance_ regression. If you change the JIT or the heap, also run the extra checks in [`runtime/HACKING.md`](/runtime/HACKING.md). Add a test for every bug you fix.
- **Document, document, document.** Add your change to the [CHANGELOG](/CHANGELOG.md) as one entry that follows [the changelog rules](/spec/design/style.md#6c-changelogs), and put any details in the body of the PR.
- **Format your code.** Format Zig code with `zig fmt` and Lus code with `lus fmt`. Run `mise run lint` before you push. Set your editor to format on save. No formatting, no merging.
- **Pass the checks.** See [Before you open a pull request](#before-you-open-a-pull-request) and [Commit messages](#commit-messages).

If you haven't done any of the above, either submit a draft PR until you have or simply don't submit a PR at all. When all else fails, [Louka Ménard Blondin](https://louka.sh) is the BDFL of the project and has the final say on whether or not your contribution will be accepted.

## Before you open a pull request

- **Your account must be at least two years old.**
- **Sign commits.** GitHub must show each one as verified. See [Signed commits](#signed-commits).
- **Fill in the template.** Name the kind of your pull request and [disclose any agent](#agent-disclosure) you used.

## Commit messages

Write the first line of each commit message as `type(area): subject`. Write `subject` in the imperative, starting with a lowercase letter, with no period at the end.

| Type | Use it when the commit |
|---|---|
| `fix` | fixes a bug |
| `perf` | makes code faster or uses less memory |
| `feat` | adds a feature to a tool |
| `refactor` | changes code without changing its behavior |
| `test` | adds or changes tests |
| `docs` | changes documentation |
| `ci` | changes workflows, CI tools, or hooks |
| `build` | changes the build or its dependencies |
| `chore` | changes anything else, such as housekeeping |

| Area | Covers |
|---|---|
| `runtime` | the interpreter, compiler, front end, and embedding interface |
| `jit` | the baseline and optimizing JIT tiers and their back ends |
| `gc` | the collector and the heap |
| `lib` | the standard library |
| `lsp` | the language server |
| `vscode` | the VS Code extension and the TextMate grammar |
| `www` | the pages of lus.dev |
| `docs` | the manual and the design notes |
| `spec` | the specification of the language and the standard library |
| `tests` | test suites and test harnesses |
| `examples` | the runnable examples |
| `perf` | benchmarks |
| `wasm` | the WebAssembly build and its host |
| `windows` | code that runs only on Windows |
| `ci` | workflows, CI tools, hooks, and the workspace |
| `packaging` | versions, installers, and licenses |
| `release` | the release workflows and the tools that version and publish a release |
| `tools` | the generators, the repository lint, and the other tools in `tools/` |
| `agents` | the agent skills, prompts, and instructions |

If you add a body, leave a blank line after the first line and write plain prose that follows [`spec/design/style.md`](/spec/design/style.md). Keep the `Co-Authored-By` trailer of any coding agent that wrote the commit.

```
fix(lib): hand a decoded chunk to the reader before the next line

The decoder returned a chunk only after decoding the line of the next
one, so the handler saw each part one chunk late.
```

## Signed commits

Run `mise run setup` once in your clone to install the hooks and turn on signing for commits and tags. If you have no signing key, run the two commands it prints to sign with the SSH key you already use for GitHub. Then add that key to your GitHub account again, this time as a signing key.

To sign commits you already made, run `git rebase --exec 'git commit --amend --no-edit -S' origin/main` and push again.

## Agent disclosure

If no coding agent wrote any part of your change, write `none` in the Agent disclosure field. Otherwise, write three lines for each agent you used:

```
Agent: Claude
Model: claude-opus-5-5
Harness: Claude Code
```

If your harness adds a `Co-Authored-By` trailer to its commits, keep that trailer on at least one commit. Check [`tools/ci/harnesses.json`](/tools/ci/harnesses.json) to see whether yours does.

## Code of Conduct

Only good programmers are welcome, and all discussion must be strictly related to code, design, or workflow. If you're being mean† to people here, you will be ejected from the premises. If you are stirring up too much trouble, you will be ejected from the premises. If you are playing letter of the law, you will be ejected from the premises. Simple enough.

† _"Mean" must not be confused with "being stern" and "enforcing project discipline"._
