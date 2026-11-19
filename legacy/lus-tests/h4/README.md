# H4 performance evidence

H4 compares two processes in paired order. Every run uses two alternating
warmup pairs followed by eight alternating measured pairs. The harness reports
the median and median absolute deviation for each side and for paired
speedups. Every relative MAD must be at most 3 percent. An unstable case
receives one complete retry. A case that
remains unstable blocks qualification because its speedup is not valid
evidence. Benchmark subprocesses use the C locale and ignore Lus environment
initialization so ambient user configuration does not alter the workload.
Each fastcall label accumulates fixed-size iteration batches until its timed
sample reaches at least 250 milliseconds. The raw JSON records total elapsed
time and executed iterations for every sample. Ingestion recomputes nanoseconds
per operation from those totals and rejects short or inconsistent evidence.
Fastcall measurements use a four-pair balanced cycle. Baseline-first and
candidate-first order each occur once with forward traversal and once with
reverse traversal. The cycle repeats across the eight measured pairs, and the
raw evidence records every traversal direction.

The default release gate requires an overall geometric mean of at least 1.05x.
Every category must be at least 0.95x. Every valid case must be at least 0.98x.
Fastcall qualification also requires the time category geometric mean to be at
least 1.10x. These qualification blocks take precedence.

The regression policy warns below 0.95x and blocks below 0.90x. Promotion
warnings have separate names because they describe a missing expected gain.
The default promotion warnings are below 1.08x overall and below 1.02x for a
case. The time fastcall promotion warning is below 1.15x. Focused promotion
warnings, targets, and revert guidance live in `benchmarks.json`.

## Validate the harness

Run the static inventory check and the focused statistical tests from the
repository root.

```sh
python3 lus-tests/h4/harness.py validate
python3 lus-tests/h4/test_harness.py
```

The inventory check reads the registered fastcalls from `lfastcall.c` and
requires `bench_fastcall.lus` to contain every exact `module.function` label
once. Each enabled workload function also proves that its bytecode contains
exactly one `OP_FASTCALL` with the matching registered id. The disabled form
proves that no `OP_FASTCALL` remains.

## Compare with Lus 1.6.2

The repository carries the `v1.6.2` tag. Configure and build the candidate
with the canonical release profile first. The preparation helper reads that
configured build, replays its compiler and relevant Meson flags for the tagged
source, and blocks unless compiler, dependencies, tool versions, build type,
optimization, LTO, PGO, sanitizer, C, and link settings match exactly. Both
builds use the release-pinned c-ares source archive. The archive digest and the
resolved c-ares version must match `release/dependencies.json`.
Compiler-specific Meson options are compared whenever the selected compiler
exposes them. Platform-independent release options are always required.

```sh
cares_root=$(mktemp -d /tmp/lus-h4-cares.XXXXXX)
cares_pc=$(lus-tests/h4/build_pinned_cares.sh "$cares_root")
cares_version=$(python3 scripts/release.py dependency caresSource.version)
export PKG_CONFIG_PATH="$cares_pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export H4_CARES_SOURCE_ARCHIVE="$cares_root/c-ares-$cares_version.tar.gz"

meson setup lus/build-benchmark lus \
  --buildtype=release -Doptimization=3 -Db_lto=true -Db_pgo=off
meson compile -C lus/build-benchmark 'lus:executable'

baseline=$(lus-tests/h4/prepare_baseline.sh /tmp/lus-h4-v1.6.2 \
  --candidate-build lus/build-benchmark \
  --evidence /tmp/lus-h4-build-parity.json)
python3 lus-tests/h4/harness.py release \
  --baseline "$baseline" \
  --candidate lus/build-benchmark/lus \
  --json /tmp/lus-h4-release.json \
  --markdown /tmp/lus-h4-release.md
```

The helper reports a clear error when the local tag is unavailable. Fetching
the tag is an explicit preparation step, which keeps qualification independent
from live network availability. The c-ares build helper is the one networked
preparation step. It verifies the stored source digest before compiling.

The parity evidence records Meson's dependency rows and the actual Lus
executable linker inputs. Its normalized external inventory contains library
flags, framework inputs, and linked library files. Linked files carry SHA-256
values. The common external closure must match exactly.

Lus 1.7 adds bundled and generated source features that are part of the
candidate itself. The evidence labels these as source feature deltas. It
records every candidate-only compiled source and validates the SQLite 3.53.4,
tzdata 2026c, and CLDR 48.2.1 versions and hashes against
`release/dependencies.json`. Upstream input digests and integrated generated
file digests remain distinct in that metadata. This inventory describes
intentional source features. Build parity means a matching toolchain and
external link closure with the recorded source feature deltas. The parity JSON
is required release evidence.

## Qualify fastcalls

Fastcall qualification alternates the same binary with fastcalls enabled and
with `--no-fastcall`.

```sh
python3 lus-tests/h4/harness.py fastcall \
  --binary lus/build-benchmark/lus \
  --json /tmp/lus-h4-fastcall.json \
  --markdown /tmp/lus-h4-fastcall.md
```

## Run focused experiments

Each experiment script runs directly with a compatible Lus binary. The paired
harness can also select one case by its manifest id.

```sh
lus/build-release/lus lus-tests/h4/experiment_cache.lus

python3 lus-tests/h4/harness.py compare \
  --baseline /path/to/baseline/lus \
  --candidate /path/to/candidate/lus \
  --case cache.method_resolution
```

The release comparison contains 13 cases that support a 1.6.2 baseline. The
SQLite and time cases use the `current` suite and compare two current-series
builds. The `release` suite selects the 13 compatible cases. The receive-line
experiment needs local
loopback bind permission. The paired harness allocates a fresh loopback port
for each receive-line process. A direct current-series run can omit the port
argument because the experiment discovers it with `getsockname`.

The PGO experiment compares a plain current build with a PGO current build
across its predeclared representative suite.

```sh
python3 lus-tests/h4/harness.py pgo \
  --plain /path/to/plain/lus \
  --pgo /path/to/pgo/lus
```

Every report contains per-case results, category geometric means, the overall
geometric mean, stability data, the applied gates, and a final pass, warning,
or block outcome. It records version strings, SHA-256 binary fingerprints, and
the host platform, then verifies that both binaries remain unchanged through
the run. JSON retains every measured sample and execution order for independent
review.

Release automation validates and combines the parity, release, and fastcall
JSON documents. Ingestion recomputes medians, MAD values, paired speedups,
category means, overall means, and blocking outcomes from the raw samples. The
final enforcement command accepts pass and warning outcomes and rejects block,
missing, truncated, or inconsistent evidence.

```sh
python3 lus-tests/h4/harness.py ingest \
  --parity /tmp/lus-h4-build-parity.json \
  --release /tmp/lus-h4-release.json \
  --fastcall /tmp/lus-h4-fastcall.json \
  --output /tmp/lus-h4-evidence.json

python3 lus-tests/h4/harness.py enforce \
  --evidence /tmp/lus-h4-evidence.json
```
