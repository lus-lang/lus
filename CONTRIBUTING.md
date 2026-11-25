# Contributing

Lus is open-source, allowing you to make as many copies of it as desired and do whatever you want with those copies. Lus, however, is not fully _open-contribution_. Please submit only pull requests correcting bugs, optimizing existing code, proposing new tests for currently unaccounted edge cases, or improving the documentation. The language of Lus 2 is frozen, so pull requests for features or changes of its design are closed automatically.

If you _do_ make a PR, make sure to:

- [**Have read the project goals.**](https://lus.dev/manual/introduction/#goals) It is possible that your suggestion is a _non-goal_ of the project and therefore barred from being accepted. Likewise, it is possible for your suggestion to go _against_ the goals, which will result in the same.
- **Test, test, test.** Run `mise run test` to make sure your changes aren't breaking anything, and compare `tests/bench` before and after to make sure you're not introducing a massive _performance_ regression as well. [`runtime/HACKING.md`](/runtime/HACKING.md) lists the extra checks that changes to the JIT or the heap need. If you are introducing a new language feature, please also add a test for it.
- **Document, document, document.** Please document your changes in the [CHANGELOG](/CHANGELOG.md). Changes should be simple one-line summaries. Additional details can be added in the body of the PR.
- **Format your code.** Zig code is formatted with `zig fmt`, and `mise run lint` checks it. Please pair it with an extension in your editor to automatically format your code when saving. No formatting, no merging.
- **Sign every commit.** GitHub must show each commit of the PR as verified. See [Signed commits](#signed-commits).
- **Fill in the template.** The PR names its [kind](#the-kind-of-a-pull-request) and [discloses its agents](#agent-disclosure), and each commit message follows [the format](#commit-messages).

If you haven't done any of the above, either submit a draft PR until you have or simply don't submit a PR at all. When all else fails, [Louka Ménard Blondin](https://louka.sh) is the BDFL of the project and has the final say on whether or not your contribution will be accepted.

## The gate

A workflow checks every pull request and every issue from an outside contributor before anyone reviews it or any test or agent runs. The maintainer, the members and collaborators of the repository, and the logins in [`.github/known-authors`](/.github/known-authors) skip it. The gate checks the following.

- **The account is at least two years old.**
- **The account is verified.** For a pull request, GitHub verifies the signature of every commit, which needs a signing key that belongs to a verified email of the account. For an issue, the account has a GPG or SSH signing key.
- **The kind and the agent disclosure of the pull request are filled in,** and the disclosure agrees with the trailers of the commits.
- **The pull request touches only paths that contributors may change.** Code, tests, the manual, the spec, and the design notes are open. Versions, packaging, the installers, the pages and brand of the site, the workflows and CI tools, the agent instructions, and the files of the repository root such as this one are not. [`tools/ci/areas.json`](/tools/ci/areas.json) holds the rule for every path, and [`.github/CODEOWNERS`](/.github/CODEOWNERS) lists the closed ones.

A pull request that fails a check gets the label `gate-failed` and one comment that lists what to fix. Each fix, as an edit of the description or a push of new commits, runs the gate again. A pull request that changes a workflow, the CI tools, the installers, the release keys, the license, or the agent instructions is closed and locked at once.

## The kind of a pull request

The Kind field of the pull request template holds exactly one of these words.

- `bug`: fixes a bug, with a regression test that fails before the fix.
- `perf`: makes something faster or smaller, with the benchmarks it improves.
- `test`: adds or improves tests.
- `docs`: changes documentation only.

Lus 2 is frozen, so a pull request for a feature or a change of the language design is closed. Ideas and design conversations live in [Discussions](https://github.com/lus-lang/lus/discussions). Linked issues and test evidence are optional fields of the template.

## Commit messages

The first line of a commit message is `type(area): subject`, at most 72 characters in all.

- `type` is one of `fix`, `perf`, `feat`, `refactor`, `test`, `docs`, `ci`, `build`, and `chore`. `feat` is for tooling only, since the language is frozen.
- `area` is one of the labels of [`tools/ci/areas.json`](/tools/ci/areas.json): `runtime`, `jit`, `gc`, `lib`, `lsp`, `vscode`, `www`, `docs`, `spec`, `tests`, `examples`, `perf`, `wasm`, `windows`, `ci`, and `packaging`.
- `subject` is imperative, starts with a lowercase letter, and ends without a period.

A body is optional. It follows a blank line, is written in plain prose that follows [`spec/design/style.md`](/spec/design/style.md), and holds no em dash, en dash, or semicolon outside code. A commit made with a coding agent carries that agent's `Co-Authored-By` trailer. For example:

```
fix(lib): hand a decoded chunk to the reader before the next line

The decoder waited for the line of the next chunk before it returned the
chunk it had already decoded, so a part reached the handler only when the
next one arrived.
```

The commit-msg hook that `mise run setup` installs checks each message, and CI checks every commit of a pull request.

## Signed commits

Every commit of a pull request is signed, and GitHub shows each one as verified. A PR with an unsigned commit, or with a signature that GitHub cannot verify, is closed before anyone reviews it.

Run `mise run setup` once in your clone. It points git at the hooks in `tools/git-hooks`, which run the format, lint, and generated file checks before each commit, and it turns on signing for every commit and tag. It never creates a key. If you have none configured, it prints the two commands that sign with the SSH key you already use for GitHub. Add that key to your GitHub account a second time as a signing key, so that GitHub can verify what it signs.

To sign commits that you already made, rebase them with `git rebase --exec 'git commit --amend --no-edit -S' origin/main` and push again.

## Agent disclosure

The Agent disclosure field of the pull request template holds `none` when no coding agent wrote any part of the change. Otherwise it holds three lines for each agent you used:

```
Agent: Claude
Model: claude-opus-5-5
Harness: Claude Code
```

Some harnesses add a `Co-Authored-By` trailer to every commit they write, and [`tools/ci/harnesses.json`](/tools/ci/harnesses.json) lists them. When the disclosure names one of them, at least one commit carries its trailer, and when a commit carries the trailer of one of them, the disclosure names it. Keep these trailers when you squash or rebase. The disclosure of any other harness is recorded as you write it.

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
