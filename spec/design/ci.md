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

Changes that reach the linker, a back end of the JIT, or the build call `full.yml` for the jobs they need: the runtime job on every runner, the cross builds and their emulated runs for the affected targets, FreeBSD, Android, and Windows on arm64. The site and the extension build in the web job of `full.yml`.

## Each night

`nightly.yml` tests the newest commit of `rewrite` once a day. It runs every job of `full.yml`, the long tests of `spec/design/testing.md`, and a canary build of every release artifact through `release.yml` with `publish` set to false. It also stores the map of sources to conformance files.

The Monday run publishes the unstable channel of `lus version` once its full checks and its canary pass. It tags the commit that it tested as `vX.Y.Z-unstable.N`, then calls `release.yml` and `release-index.yml`. A week whose nightly run fails publishes no unstable build.

A release tag runs every job of `full.yml` before `release.yml` creates the draft release.

## On a contributor's machine

`mise run setup` points git at `tools/git-hooks` and signs every commit and tag. The pre-commit hook checks the format of the staged Zig files, runs the repository lint, checks the generated files when their sources are staged, and checks that every new file belongs to an area. The commit-msg hook holds the message to the rules of the repository lint.

## On the maintainer's machine

`tools/security-review.sh` reviews an outside pull request for security problems with the model that `LUS_REVIEW_MODEL` names. It exports the files of the change to a temporary directory, starts the agent in an empty directory with read access to those files and no shell, network, editing, or MCP servers, and writes the report to a private file under `~/.local/state/lus/reviews`. Nothing leaves the machine except the request to the model.

`tools/land-contribution.sh` lands an accepted pull request as one signed commit on a new branch. The commit squashes the contribution and the branch of fixes from its review. The author of the contribution stays its author, and the trailers of its commits stay in the message.
