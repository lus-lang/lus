# Continuous integration

This note describes what CI runs for a change, what runs each night, and the tools that a contributor and the maintainer run on their own machines.

## The path map

`tools/ci/areas.json` assigns every path of the repository to one or more areas. An area names the conformance files and the checks that a change to it needs, the runners that it needs them on, the jobs of `full.yml` that it calls, the benchmarks that it affects, its labels, and whether an outside contributor may change it. `tools/ci/areas.mjs` reads the map. A path takes the union of what its areas need, and the strictest of their contributor rules.

The map is complete by construction. `tools/ci/areas.test.mjs` fails when a tracked file belongs to no area, and so does the pre-commit hook when a new file does. A changed path that no area knows still runs something, the fallback of the map, which is the conformance suite on Linux with the unit tests.

An area lists its conformance files in three ways. A list of files names them directly. The pattern `tests/conformance/{stem}*_test.lus` takes the name of the changed file, so `runtime/src/lib/json.zig` runs `json_test.lus`. The word `suite` runs the whole suite, which is what a change to the interpreter, the compiler, the collector, or the JIT runs.

The nightly run adds a second source of conformance files. `tools/ci/testmap.mjs` runs each conformance file alone in a `-Dcoverage=true` build and records the runtime source files that its run reaches. The map leaves out a source file that more than half of the conformance files reach, since the path map already sends it to the whole suite. `ci.yml` downloads the map of the last successful nightly run and adds the files that reach each changed source file.

## On each change

`ci.yml` runs on every push to `main` and `rewrite` and on every pull request. Its first job writes the plan of the change to the summary of the run. Lint, the format of the Zig sources, and the generated files are checked on every change.

The targeted runtime job runs once for each runner the plan names. Linux runs everything that is the same on every system. macOS and Windows run the areas whose code differs per system, such as the file system, processes, sockets, signals, the scheduler, and the JIT. Each runner builds lus and runs the chosen conformance files with `LUS_JIT=off`, with the default setting, with `LUS_JIT=eager`, and with `LUS_JIT=opt-eager`. The checks of the plan add the unit tests, the documentation examples, the collector at every 97th allocation, short chains of direct calls, the differential programs, the allocation failure sweep, the corrupted inputs, the mutated sources, the crash and fault tests, the WebAssembly build, and the installer.

A pull request also runs the check of its commit messages (`tools/ci/commits.mjs`) and of the Kind and the agent disclosure of its description (`tools/ci/pr.mjs`). The job `ci-ok` waits for every other job of the run and passes when each one passed or was left out by the plan, so it is the one check that the rules of `main` require.

Changes that reach the linker, a back end of the JIT, or the build call `full.yml` for the jobs they need: the runtime job on every runner, the cross builds and their emulated runs for the affected targets, FreeBSD, Android, and Windows on arm64. The site and the extension build in the web job of `full.yml`.

## Benchmarks

A pull request whose paths name benchmarks in the path map builds its base and its head and runs those benchmarks on one runner, the two binaries in turn with their order alternating each round (`tools/ci/perf.mjs`). A benchmark regresses when the median of its wall time grows by more than 7%, or the median of its peak memory by more than 5%, and the growth also exceeds three times the larger median absolute deviation of the two. `tools/ci/perf.json` holds these limits. The run of a pull request from a fork cannot write to the pull request, so `perf-label.yml` reads the measurement after the run, as data, and sets the label `perf-regression` with a comment of the table.

Each nightly run measures every benchmark and compares the result with the run before it and with the newest stable release. The branch `perf-data` holds the measurements, as `nightly/DATE.json` and `release/TAG.json`, and `perf-release.yml` measures each release as it is published. A nightly regression goes to the one open issue labelled `perf-regression`.

## Contributions

`contributions.yml` runs for every pull request and every issue. GitHub runs it from the default branch with the token of the base repository, so no job checks out or runs the code of a pull request, and nothing in it runs from `rewrite`.

The gate (`tools/ci/gate.mjs`) runs first, and nothing else runs for a contribution that fails it. The maintainer, the members and collaborators of the repository, and the logins of `.github/known-authors` skip it. Every other author needs an account at least two years old. A pull request needs every commit verified by GitHub, a valid Kind and agent disclosure, and only paths that the path map opens to contributors. An issue needs a GPG or SSH signing key on the account, which is how the gate checks that an account is verified. A failure gets the label `gate-failed` and one comment that the next run updates. A Kind that asks for a feature closes the pull request, and an egregious path closes and locks it. `.github/CODEOWNERS` lists the closed paths, and `node tools/ci/areas.mjs codeowners --write` writes that list from the path map.

A pull request gets the labels of its areas and its Kind. Once it passes the gate, an agent reviews it against the rules of the repository, reading its files as data from a directory where no settings, hooks, or instruction files of the pull request load, and the review is posted as one comment. The targeted tests of `ci.yml` run on the event of the pull request itself.

An issue that passes is sorted by a small model. A suggestion, a design proposal, or a question is closed with a pointer to Discussions. A bug report goes through four jobs. The first runs the program of the report under three modes of the JIT, with no secret and a token that only reads. The second gives an agent the report, the runs, and the sources, with tools that read and edit files and run nothing, and the agent writes a fix, a regression test, and a report. The third applies the fix in a job without secrets, checks that it changes only the runtime and the conformance tests, that the regression test fails without the fix and passes with it, and that the tests of its areas pass in every mode of the JIT. The last pushes a verified fix to the branch `agent/issue-N` and comments the report on the issue. The maintainer reviews the branch.

`tools/ci/agents.json` holds the model, the budget in dollars, and the time limit of each agent, and the pinned version of the CLI. The CLI stops a run at its budget, and the job stops at its time limit.

## Each night

`nightly.yml` tests the newest commit of `rewrite` once a day. It runs every job of `full.yml`, the long tests of `spec/design/testing.md`, and a canary build of every release artifact through `release.yml` with `publish` set to false. It also stores the map of sources to conformance files and measures the benchmarks.

The Monday run publishes the unstable channel of `lus version` once its full checks and its canary pass. It tags the commit that it tested as `vX.Y.Z-unstable.N`, then calls `release.yml` and `release-index.yml`. A week whose nightly run fails publishes no unstable build.

A release tag runs every job of `full.yml` before `release.yml` creates the draft release.

## On a contributor's machine

`mise run setup` points git at `tools/git-hooks` and signs every commit and tag. The pre-commit hook checks the format of the staged Zig files, runs the repository lint, checks the generated files when their sources are staged, and checks that every new file belongs to an area. The commit-msg hook checks the format of the message that CONTRIBUTING.md describes.

## On the maintainer's machine

`tools/security-review.sh` reviews an outside pull request for security problems with the model that `LUS_REVIEW_MODEL` names. It exports the files of the change to a temporary directory, starts the agent in an empty directory with read access to those files and no shell, network, editing, or MCP servers, and writes the report to a private file under `~/.local/state/lus/reviews`. Nothing leaves the machine except the request to the model.

`tools/land-contribution.sh` lands an accepted pull request as one signed commit on a new branch. The commit squashes the contribution and the branch of fixes from its review. The author of the contribution stays its author, and the trailers of its commits stay in the message.
