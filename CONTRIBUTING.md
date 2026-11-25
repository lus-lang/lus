# Contributing

Lus is open-source, allowing you to make as many copies of it as desired and do whatever you want with those copies. Lus, however, is not fully _open-contribution_. Please submit only pull requests correcting bugs, optimizing existing code, proposing new tests for currently unaccounted edge cases, or improving the documentation.

If you _do_ make a PR, make sure to:

- [**Read the project goals.**](https://lus.dev/manual/introduction/#goals) Changes that implement a _non-goal_ or contradict a goal are rejected.
- **Test, test, test.** Run `mise run test` to make sure your changes break nothing. Compare `tests/bench` before and after to make sure you add no massive _performance_ regression. If you change the JIT or the heap, also run the extra checks in [`runtime/HACKING.md`](/runtime/HACKING.md). Add a test for every bug you fix.
- **Document, document, document.** Add your change to the [CHANGELOG](/CHANGELOG.md) as a one-line summary and put any details in the body of the PR.
- **Format your code.** Format Zig code with `zig fmt` and Lus code with `lus fmt`. Run `mise run lint` before you push. Set your editor to format on save. No formatting, no merging.
- **Pass the checks.** See [Before you open a pull request](#before-you-open-a-pull-request) and [Commit messages](#commit-messages).

If you haven't done any of the above, either submit a draft PR until you have or simply don't submit a PR at all. When all else fails, [Louka Ménard Blondin](https://louka.sh) is the BDFL of the project and has the final say on whether or not your contribution will be accepted.

## Before you open a pull request

- **Your account must be at least two years old.**
- **Sign every commit.** GitHub must show each one as verified. See [Signed commits](#signed-commits).
- **Fill in the template.** Name the [kind](#kind) of your pull request and [disclose any agent](#agent-disclosure) you used.
- **Change only what contributors may change.** You may change code, tests, the manual, the spec, and the design notes. Leave versions, packaging, the installers, the site's pages and brand, the workflows and CI tools, the agent instructions, and every file at the root of the repository except the CHANGELOG alone. Check [`tools/ci/areas.json`](/tools/ci/areas.json) for the rule on any path.

If a check fails, read the comment on your pull request and fix what it lists, by editing the description or pushing new commits. Never change a workflow, the CI tools, the installers, the release keys, the license, or the agent instructions. A pull request that does is closed and locked.

To open an issue, your account must also be at least two years old and have a GPG or SSH signing key.

## Kind

Write exactly one of these words in the Kind field of the template.

- `bug`: you fix a bug and add a regression test that fails before your fix.
- `perf`: you make something faster or smaller and name the benchmarks it improves.
- `test`: you add or improve tests.
- `docs`: you change documentation only.

Don't open a pull request that adds a feature or changes the design of the language. Bring those ideas to [Discussions](https://github.com/lus-lang/lus/discussions).

## Commit messages

Write the first line of each commit message as `type(area): subject`, in at most 72 characters.

- For `type`, use one of `fix`, `perf`, `feat`, `refactor`, `test`, `docs`, `ci`, `build`, or `chore`.
- For `area`, use one of `runtime`, `jit`, `gc`, `lib`, `lsp`, `vscode`, `harness`, `www`, `docs`, `spec`, `tests`, `examples`, `perf`, `wasm`, `windows`, `ci`, `packaging`, `release`, `tools`, `agents`, or `marketing`. Use `www` for the site.
- Write `subject` in the imperative, starting with a lowercase letter, with no period at the end.

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

## Use of LLMs

If you are using large language models to write code, or is suspected of doing so, you may be subjected to the following questions:

- **Are you a programmer?**
  - If not, your PR will be rejected.
- **Do you know how to program in Zig and Lus?**
  - Have you used either language before to build a project? If not, please familiarize with building software in both languages so that your next PR won't be rejected. Preferably, do it with some brain-coding.
- **Do you know how Lus works internally?**
  - If not, please spend some time studying the internal workings of the language. It is irresponsible to submit a PR without understanding how the language even works to begin with.
- **Do you understand the code that you are submitting?**
  - Are you simply asking the LLM to "implement X feature" or "fix Y bug" without a clear idea of how you would implement that feature or fix that bug yourself? If so, your PR will be rejected.
- **Can you _explain_ the code that you are submitting?**
  - Explaining is often a prerequisite of _understanding_. If you think that you can understand the code, but then you find yourself unable to explain it in moderate detail, you may not understand it as well as you think you do. Your PR will be rejected.

If you pass, then your PR may be merged. I believe it acceptable to use LLMs to write code as long as it's used in an assistive capacity, not a replacement capacity. If you are using LLMs to be more productive, then you are welcome to do so, but please be transparent about it. A 1979 IBM adage observes that a computer cannot be held accountable and therefore cannot make a management decision. A PR is a management decision.

## Code of Conduct

Only good programmers are welcome, and all discussion must be strictly related to code, design, or workflow. If you're being mean† to people here, you will be ejected from the premises. If you are stirring up too much trouble, you will be ejected from the premises. If you are playing letter of the law, you will be ejected from the premises. Simple enough.

† _"Mean" must not be confused with "being stern" and "enforcing project discipline"._
