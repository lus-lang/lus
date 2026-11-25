# Contributing

Lus is open-source, allowing you to make as many copies of it as desired and do whatever you want with those copies. Lus, however, is not fully _open-contribution_. Please submit only pull requests correcting bugs, optimizing existing code, or proposing new tests for currently unaccounted edge cases. Feature requests (à la RFC) will be subject to intense scrutiny and will most likely be rejected.

If you _do_ make a PR, make sure to:

- [**Have read the project goals.**](https://lus.dev/manual/introduction/#goals) It is possible that your suggestion is a _non-goal_ of the project and therefore barred from being accepted. Likewise, it is possible for your suggestion to go _against_ the goals, which will result in the same.
- **Test, test, test.** Run `mise run test` to make sure your changes aren't breaking anything, and compare `tests/bench` before and after to make sure you're not introducing a massive _performance_ regression as well. [`runtime/HACKING.md`](/runtime/HACKING.md) lists the extra checks that changes to the JIT or the heap need. If you are introducing a new language feature, please also add a test for it.
- **Document, document, document.** Please document your changes in the [CHANGELOG](/CHANGELOG.md). Changes should be simple one-line summaries. Additional details can be added in the body of the PR.
- **Format your code.** Zig code is formatted with `zig fmt`, and `mise run lint` checks it. Please pair it with an extension in your editor to automatically format your code when saving. No formatting, no merging.
- **Sign every commit.** GitHub must show each commit of the PR as verified. See [Signed commits](#signed-commits).
- **Disclose your agents.** The PR names every coding agent that wrote part of the change, and each commit it helped write carries its trailer. See [Agent disclosure](#agent-disclosure).

If you haven't done any of the above, either submit a draft PR until you have or simply don't submit a PR at all. When all else fails, [Louka Ménard Blondin](https://louka.sh) is the BDFL of the project and has the final say on whether or not your contribution will be accepted.

## Signed commits

Every commit of a pull request is signed, and GitHub shows each one as verified. A PR with an unsigned commit, or with a signature that GitHub cannot verify, is closed before anyone reviews it.

Run `mise run setup` once in your clone. It points git at the hooks in `tools/git-hooks`, which run the format, lint, and generated file checks before each commit, and it turns on signing for every commit and tag. It never creates a key. If you have none configured, it prints the two commands that sign with the SSH key you already use for GitHub. Add that key to your GitHub account a second time as a signing key, so that GitHub can verify what it signs.

To sign commits that you already made, rebase them with `git rebase --exec 'git commit --amend --no-edit -S' origin/main` and push again.

## Agent disclosure

The pull request template asks which coding agents wrote part of the change. Name each agent you used, such as Claude Code or Codex, or answer that you used none.

Each commit that an agent helped write carries that agent's `Co-Authored-By` trailer, as the agent adds it by default. Keep these trailers when you squash or rebase. A PR that names an agent without its trailer on the commits, or that carries an agent's trailer without naming the agent, is closed before anyone reviews it.

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
