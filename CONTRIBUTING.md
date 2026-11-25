# Contributing

Lus is open-source, allowing you to make as many copies of it as desired and do whatever you want with those copies. Lus, however, is not fully _open-contribution_. Please submit only pull requests correcting bugs, optimizing existing code, proposing new tests for currently unaccounted edge cases, or improving the documentation.

If you _do_ make a PR, make sure to:

- [**Have read the project goals.**](https://lus.dev/manual/introduction/#goals) It is possible that your suggestion is a _non-goal_ of the project and therefore barred from being accepted. Likewise, it is possible for your suggestion to go _against_ the goals, which will result in the same.
- **Test, test, test.** Run `mise run test` to make sure your changes aren't breaking anything, and compare `tests/bench` before and after to make sure you're not introducing a massive _performance_ regression as well. [`runtime/HACKING.md`](/runtime/HACKING.md) lists the extra checks that changes to the JIT or the heap need. If you are introducing a new language feature, please also add a test for it.
- **Document, document, document.** Please document your changes in the [CHANGELOG](/CHANGELOG.md). Changes should be simple one-line summaries. Additional details can be added in the body of the PR.
- **Format your code.** Zig code is formatted with `zig fmt`, and `mise run lint` checks it. Please pair it with an extension in your editor to automatically format your code when saving. No formatting, no merging.
- **Pass the checks.** See [Before you open a pull request](#before-you-open-a-pull-request) and [Commit messages](#commit-messages).

If you haven't done any of the above, either submit a draft PR until you have or simply don't submit a PR at all. When all else fails, [Louka Ménard Blondin](https://louka.sh) is the BDFL of the project and has the final say on whether or not your contribution will be accepted.

## Before you open a pull request

Your pull request is checked before anyone reads it. If you are a maintainer, a collaborator, or listed in [`.github/known-authors`](/.github/known-authors), you skip these checks.

- **Your account must be at least two years old.**
- **Sign every commit.** GitHub must show each one as verified. See [Signed commits](#signed-commits).
- **Fill in the template.** Name the [kind](#kind) of your pull request and [disclose any agent](#agent-disclosure) you used.
- **Change only what contributors may change.** You may change code, tests, the manual, the spec, and the design notes. Leave versions, packaging, the installers, the site's pages and brand, the workflows and CI tools, the agent instructions, and the files at the root of the repository alone. [`tools/ci/areas.json`](/tools/ci/areas.json) has the rule for every path.

If a check fails, your pull request gets the `gate-failed` label and a comment listing what to fix. Fix it by editing the description or pushing new commits, and the checks run again. If you change a workflow, the CI tools, the installers, the release keys, the license, or the agent instructions, your pull request is closed and locked.

To open an issue, your account must also be at least two years old and have a GPG or SSH signing key.

## Kind

Write exactly one of these words in the Kind field of the template.

- `bug`: you fix a bug, and add a regression test that fails before your fix.
- `perf`: you make something faster or smaller, and name the benchmarks it improves.
- `test`: you add or improve tests.
- `docs`: you change documentation only.

Pull requests that add a feature or change the design of the language are closed. Bring ideas to [Discussions](https://github.com/lus-lang/lus/discussions) instead.

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

Run `mise run setup` once in your clone. It installs the hooks that check formatting, lint, generated files, and your commit messages, and it turns on signing for commits and tags. If you have no signing key configured, it prints the two commands that sign with the SSH key you already use for GitHub. Add that key to your GitHub account again, this time as a signing key.

To sign commits you already made, run `git rebase --exec 'git commit --amend --no-edit -S' origin/main` and push again.

## Agent disclosure

If no coding agent wrote any part of your change, write `none` in the Agent disclosure field. Otherwise, write three lines for each agent you used:

```
Agent: Claude
Model: claude-opus-5-5
Harness: Claude Code
```

If your harness adds a `Co-Authored-By` trailer to its commits, keep that trailer on at least one commit. [`tools/ci/harnesses.json`](/tools/ci/harnesses.json) lists these harnesses.

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
