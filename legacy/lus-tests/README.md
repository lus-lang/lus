# Lus tests

The repository uses four harnesses to qualify correctness, integration, embedding, and performance.

- H1 runs language, parser, virtual machine, and standard library suites written in Lus.
- H2 runs C programs against the embedding API and static library.
- H3 exercises independent system integration cases from `h3/manifest.json`. Local runs use the containerized `h3-local` suite, while CI uses the direct `h3-ci` suite in its prepared runner. Each case receives an isolated temporary directory. The HTTPS case uses a checked-in localhost certificate and an ephemeral loopback port.
- H4 produces paired performance evidence. Its inventory, stability rules, thresholds, and focused commands are documented in [the H4 guide](h4/README.md).

Release qualification requires the configured H1, H2, and H3 suites on each supported test platform. Main and tag builds also require the focused H4 benchmark job. Pull requests can omit that benchmark job while still running correctness, sanitizer, and platform checks. The release evidence records each required result, and the release bundle is assembled only after its quality gate passes.

## Running tests locally

Configure and compile from the `lus` directory.

```sh
cd lus
meson setup build
meson compile -C build
```

Run all configured suites or select the surface relevant to a change.

```sh
meson test -C build
meson test -C build --suite h1
meson test -C build --suite h2
meson test -C build --suite h3-local
meson test -C build --suite h4
meson test -C build h1/optchain
```

`meson test -C build --list` lists every registered test. Focused runs provide fast feedback, while a complete qualification run covers interactions across the repository.

## Sanitizer workflow

The CI sanitizer job qualifies every registered H1 and H2 case with Clang AddressSanitizer and UndefinedBehaviorSanitizer. Linux runs require LeakSanitizer with halt-on-error behavior. A separate ThreadSanitizer build runs the worker lifecycle, multi-state, embedding, and idle-worker cases. Both runs validate their exact test inventory before producing combined release evidence.

Run the focused sanitizer qualifiers from the repository root.

```sh
bash lus-tests/qualify-sanitizers.sh
bash lus-tests/qualify-tsan.sh
```

Docker or Podman together with [`act`](https://nektosact.com/) can run the full CI job locally.

```sh
act -j sanitize
```

Linux jobs run locally through `act`. The macOS and Windows matrix jobs require their native GitHub runners.
