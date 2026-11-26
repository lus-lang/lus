# Continuous integration

This note describes what CI runs for a change, what runs each night, and the tools that a contributor and the maintainer run on their own machines.

## The path map

`tools/ci/areas.json` assigns every path of the repository to one or more areas. An area names the conformance files and the checks that a change to it needs, the runners that it needs them on, the jobs of `full.yml` that it calls, its labels, and whether an outside contributor may change it. The benchmarks of a path come from `tests/bench/perf-map.json`. `tools/ci/areas.mjs` reads the map. A path takes the union of what its areas need, and the strictest of their contributor rules.

The map is complete by construction. `tools/ci/areas.test.mjs` fails when a tracked file belongs to no area, and so does the pre-commit hook when a new file does. A changed path that no area knows still runs something, the fallback of the map, which is the conformance suite on Linux with the unit tests.

An area lists its conformance files in three ways. A list of files names them directly. The pattern `tests/conformance/{stem}*_test.lus` takes the name of the changed file, so `runtime/src/lib/json.zig` runs `json_test.lus`. The word `suite` runs the whole suite, which is what a change to the interpreter, the compiler, the collector, or the JIT runs.

The nightly run adds a second source of conformance files. `tools/ci/testmap.mjs` runs each conformance file alone in a `-Dcoverage=true` build and records the runtime source files that its run reaches. The map leaves out a source file that more than half of the conformance files reach, since the path map already sends it to the whole suite. `ci.yml` downloads the map of the last successful nightly run and adds the files that reach each changed source file.

## On each change

`ci.yml` runs on every push to `main` and `rewrite` and on every pull request. Its first job writes the plan of the change to the summary of the run. A pull request plans from its base. A push plans from the newest commit of its branch whose run passed, or from the commit where the history of the push parts from that commit, so a check that failed runs again on every later push until it passes. When that commit is gone, as after a rewrite of the history, the plan covers every tracked file. Lint, the format of the Zig sources, and the generated files are checked on every change.

The targeted runtime job runs once for each runner the plan names. Linux runs everything that is the same on every system. macOS and Windows run the areas whose code differs per system, such as the file system, processes, sockets, signals, the scheduler, and the JIT. Each runner builds lus and runs the chosen conformance files with `LUS_JIT=off`, with the default setting, with `LUS_JIT=eager`, and with `LUS_JIT=opt-eager`. The checks of the plan add the unit tests, the documentation examples, the collector at every 97th allocation, short chains of direct calls, the differential programs, the allocation failure sweep, the corrupted inputs, the mutated sources, the crash and fault tests, the WebAssembly build, and the installer.

A pull request also runs the check of its commit messages (`tools/ci/commits.mjs`) and of the Kind and the agent disclosure of its description (`tools/ci/pr.mjs`). The job `ci-ok` waits for every other job of the run and passes when each one passed or was left out by the plan, so it is the one check that the rules of `main` require.

Changes that reach the linker, a back end of the JIT, or the build call `full.yml` for the jobs they need: the runtime job on every runner, the cross builds and their emulated runs for the affected targets, FreeBSD, Android, and Windows on arm64. The site and the extension build in the web job of `full.yml`.

## Benchmarks

`tests/bench/perf-map.json` lists every benchmark, the 21 programs of `tests/bench` and the programs of `tests/bench/compare`, with its command and the source paths that reach it. A pull request whose paths reach benchmarks builds its base and its head and runs those benchmarks on one runner, the two binaries in turn with their order alternating each round (`tools/ci/perf.mjs`). Each benchmark has its own threshold in the perf map, the growth of its median time and peak memory that counts as a regression, set from the noise measured for it. The growth must also exceed three times the larger median absolute deviation of the two measurements on the runner, which `tools/ci/perf.json` sets. The run of a pull request from a fork cannot write to the pull request, so `perf-label.yml` reads the measurement after the run, as data, and sets the label `perf-regression` with a comment of the table.

Each nightly run measures every benchmark and compares the result with the run before it and with the newest stable release. The branch `perf-data` holds the measurements, as `nightly/DATE.json` and `release/TAG.json`, and `perf-release.yml` measures each release as it is published. A nightly regression goes to the one open issue labelled `perf-regression`.

## Contributions

`contributions.yml` runs for every pull request and every issue. GitHub runs it from the default branch with the token of the base repository, so no job runs the code of a pull request. Nothing in it runs from `rewrite`.

Every write of these workflows goes through the Lus app, whose secrets are `LUS_APP_ID` and `LUS_APP_PRIVATE_KEY`. Each job that writes mints its own token with `actions/create-github-app-token`, with only the permissions of that job, and a job that hands untrusted text to an agent holds no write token. A branch that the app pushes runs the workflows of its pull request, which a push with the token of the workflow would not.

The gate (`tools/ci/gate.mjs`) runs first, and nothing else runs for a contribution that fails it. The maintainer, the members and collaborators of the repository, the logins of `.github/known-authors`, and the Lus app skip it. Every other author needs an account at least two years old. A pull request needs every commit verified by GitHub, a valid Kind and agent disclosure, and only paths that the path map opens to contributors. An issue needs only the account age. A failure gets the label `gate-failed` and one comment that the next run updates. A Kind that asks for a feature closes the pull request, and an egregious path closes and locks it. `.github/CODEOWNERS` lists the closed paths, and `node tools/ci/areas.mjs codeowners --write` writes that list from the path map.

A pull request gets the labels of its areas and its Kind. Once it passes the gate, an agent reviews it against the rules of the repository, reading its files as data. The next job posts the review as one comment. The targeted tests of `ci.yml` run on the event of the pull request itself.

An issue that passes is sorted by a small model. A suggestion, a design proposal, or a question moves to Discussions: the app opens a discussion that quotes the issue, in the category that `tools/ci/agents.json` names, and closes and locks the issue with its link. A bug report goes through four jobs. The first runs the program of the report under three modes of the JIT, with no secret and a token that only reads. The second gives an agent the report, the runs, and the sources, with tools that read and edit files and run nothing. The agent writes a fix, a regression test, and a report. The third applies the fix in a job without secrets, checks that it changes only the runtime and the conformance tests, that the regression test fails without the fix and passes with it, and that the tests of its areas pass in every mode of the JIT. The last pushes a verified fix to the branch `agent/issue-N`, opens a draft pull request for it that follows the template and fixes the issue, and comments the report on the issue. The pull request runs the targeted tests of `ci.yml`, and the maintainer reviews it.

The three agents, which review pull requests, sort issues, and look for the cause of a bug, run in steps that use `anthropics/claude-code-action`, with the prompts of `tools/ci/prompts`. The workflow pins the action by the commit of a release, with the date the release was chosen in a comment next to the pin. A pin moves only to a release that has been public for at least two weeks. The commit of the action also fixes the version of the CLI. `tools/ci/agents.json` holds the model, the budget in dollars, the number of turns, the time limit, and the tools of each agent. The CLI stops a run at its budget or its number of turns. The job stops at its time limit.

The action admits only authors with write access unless `allowed_non_write_users` names them. The gate checks outside authors before any agent starts, so each agent job sets that input to every author and runs only once the gate has passed. With the input set, the action starts the agent in a permission mode that denies every tool that no rule allows. It also removes the Anthropic, cloud, and Actions secrets from the environment of the commands it starts.

Each agent job mints a token of the Lus app that only reads contents, pull requests, and issues. The action makes its requests as the app with that token. Every write stays in a job without an agent: the comment of the review, the move to Discussions, the labels, the branch of a fix, and its draft pull request. The action writes the token into the git configuration of the checkout, where the agent could read it. That token reads only this repository, which is public, and expires within an hour. A step after the agent fails the job when an output holds the token or the API key.

Each agent has only the tools that `agents.json` lists. Its list of denied tools covers the shell, the web, and the GitHub servers of the action, whatever another setting allows. An agent can therefore run no command and push nothing. It loads only the settings that the action writes, with `--setting-sources user`, so no settings, hooks, or instruction files of a checkout load. The review and the sort answer in a JSON schema. The sort job reads any kind outside the schema as `other`.

Every outside pull request comes from a fork, so the review sets `allow_fork_prs`, without which the action skips a fork. The action itself checks out nothing from the pull request. The job checks out the default branch at the root of the workspace, where the agent starts, and the head of the pull request in `pr-head`, which `--add-dir` opens to the agent, as the security notes of the action describe. `restrict_untrusted_prs` stays on, so on a pull request whose author has no write access the action also denies the commands that run code from a checkout. `show_full_output` and `display_report` stay off in every job, so the public log and the summary of a run hold no output of a tool and no text of the agent.

## Each night

`nightly.yml` tests the newest commit of `rewrite` once a day. It runs every job of `full.yml`, the long tests of `spec/design/testing.md`, and a canary build of every release artifact through `release.yml` with `publish` set to false. It also stores the map of sources to conformance files and measures the benchmarks.

The Monday run publishes the unstable channel of `lus version` once its full checks and its canary pass. It tags the commit that it tested as `vX.Y.Z-unstable.N`, then calls `release.yml` and `release-index.yml`. A week whose nightly run fails publishes no unstable build.

A release tag runs every job of `full.yml` before `release.yml` creates the draft release.

## On a contributor's machine

`mise run setup` points git at `tools/git-hooks` and signs every commit and tag. The pre-commit hook checks the format of the staged Zig files, runs the repository lint, checks the generated files when their sources are staged, and checks that every new file belongs to an area. The commit-msg hook checks the format of the message that CONTRIBUTING.md describes.

## On the maintainer's machine

`tools/land-contribution.sh` lands an accepted pull request as one signed commit on a new branch. The commit squashes the contribution and the branch of fixes from its review. The author of the contribution stays its author, and the trailers of its commits stay in the message.
