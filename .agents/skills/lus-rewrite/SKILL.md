---
name: lus-rewrite
description: Assess an existing codebase for a rewrite in Lus, show a preview, then port it behind a parity harness that proves the Lus version behaves like the original. Use when the user asks to rewrite, port, convert, or migrate a project or a part of one to Lus, or asks whether Lus would improve their project. Requires the lus skill.
---

# Rewriting a project in Lus

This skill moves a working program to Lus without changing what it does. The order is fixed: assess, preview, build the parity harness, port in slices, measure. Each phase writes its artifacts into `.lus-rewrite/` at the project root, and each phase ends at a checkpoint where the user decides whether to continue. Load the `lus` skill first. It holds the language rules and the check, format, and test loop.

## Phase 0: Assess

Read the project before judging it. Find the entry points, the build files, the dependency manifest, the tests, and the external interfaces: command line arguments, files read and written, network endpoints, environment variables, exit codes, and anything other programs call or link against.

Then score the project with [references/rubric.md](references/rubric.md). The rubric has hard stops. A project whose users consume its language API or its binary interface, such as a C++ library, an npm or PyPI package, a plugin loaded by a host, or a shared object, keeps its language. Rewriting it in place breaks every user. For those projects the outcome is a fork, a new major version under a new name, a Lus companion tool, or a declined rewrite that still lists what Lus would improve.

Write `.lus-rewrite/assessment.md` with these sections, in this order:

1. **Verdict.** One of `rewrite`, `partial`, `fork or new major`, or `decline`, with one sentence of reasoning.
2. **What the project is.** Language, size in lines, entry points, external interfaces, dependencies.
3. **Where Lus improves it.** One row per finding: the file or area, the improvement, and the evidence. Look for each of the following.
   - Speed in interpreter-bound code: parsing, text processing, data transformation, request handling.
   - Permissions: a `pledge` line that states exactly what the program touches, sealed after startup.
   - Dependencies the standard library replaces: JSON, CSV, SQLite, HTTP client and server, compression, hashing and signatures, password hashing, UUIDs, time zones, test runner, formatter, linter.
   - Concurrency: callback or async code that becomes plain sequential code in detached coroutines, and process pools that become workers.
   - Distribution: an installer, a container, or a runtime prerequisite that becomes one executable from `lus build`.
4. **What gets harder.** Libraries with no Lus counterpart, platform features, team familiarity, unstable Lus features the port would rely on.
5. **Effort.** Slices, in porting order, with a size estimate for each.

Stop and present the verdict and the improvement table. Continue only on the user's word.

## Phase 1: Preview

Port one small, representative piece end to end, so the user sees real Lus written for their code before committing to anything. Pick a leaf module with clear inputs and outputs, ideally one that shows an improvement from the assessment, such as a dependency the standard library replaces.

Write the preview to `.lus-rewrite/preview/`, run `lus check` and `lus fmt --write` on it, and add a short `.lus-rewrite/preview/README.md` that places the original and the Lus version side by side with line counts, dependencies removed, and the pledge line. Keep the preview out of the project's own source tree. Stop and show it.

## Phase 2: Parity harness

Before porting anything else, build the instrument that proves sameness, and prove the instrument works on the original. [references/harness.md](references/harness.md) has templates.

1. **Inventory behavior.** List every observable behavior in `.lus-rewrite/behaviors.md`: commands and flags, inputs and outputs, error messages, exit codes, files written, requests made and served.
2. **Build a corpus.** Collect inputs that exercise each behavior into `.lus-rewrite/harness/cases/`. Start from the project's own tests and examples, add edge cases from the code, and add one case per error path.
3. **Record the original.** Run the original over the corpus and store its outputs in `.lus-rewrite/harness/golden/`. For network clients, record the requests and responses once and replay them. For servers, write request scripts and record the responses. Normalize only what is truly nondeterministic, such as timestamps, temporary paths, and random identifiers, and list each normalization in `behaviors.md`.
4. **Check the harness.** The parity test must pass when pointed at the original program, and must fail when one golden file is deliberately altered. Record both runs in `.lus-rewrite/progress.md`.

The harness is a set of ordinary `*_test.lus` files, so `lus test .lus-rewrite/harness` runs it and reports each case.

## Phase 3: Port in slices

Port in the order from the assessment, leaves first. For each slice:

1. Write the Lus code and its unit tests. Start the file with its `global` declaration and the narrowest `pledge` that works, then `pledge("seal")`.
2. Run `lus check`, `lus fmt --write`, and `lus test` until all are clean.
3. Run the parity harness. A slice is done only when every case it touches passes.
4. Mark the slice done in `.lus-rewrite/progress.md` with the harness result line.

While the original and the port coexist, keep one way to run each, so the harness can run against both. Never edit a golden file to make a port pass. A golden file changes only when the user agrees the original behavior was a bug, and the change is recorded in `behaviors.md`.

For each dependency, decide in `.lus-rewrite/dependencies.md` between four options: the standard library covers it, port it as a Lus module in the project, keep it as an external process the Lus program calls, or embed it in a host program through `lus.h`. Port a library only as far as the project uses it, and give the ported part its own tests.

## Phase 4: Measure and hand over

Run the full harness one final time. Then measure the original and the port on the same inputs: wall time, peak memory, and the size of what ships. Build the executable with `lus build` and the pledges the program needs. Write `.lus-rewrite/report.md` with the numbers, the dependencies removed, the pledge line, and any behavior that changed with the user's approval. Leave the harness in the repository as the regression suite of the new code.

## Rules

- Behavior parity first, idiomatic Lus second, speed third. Improve design only after the harness is green, and only with the user's agreement.
- Every claim in a report carries evidence: a command and its output, a file, or a measurement.
- Ask before deleting the original code. Keep it until the user has run the port in production conditions.
