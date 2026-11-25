# Examples

Each file in this folder is a short, complete Lus program on one topic. lus.dev shows them on `/examples` in the order of `index.json`, which groups them into sections. The programs marked for the playground open there with one click.

## Adding an example

Start the file with two comment lines: the title and a sentence that says what the example shows, then whether it runs in the playground.

```lus nocheck
-- Title: One sentence that says what the example shows.
-- playground: true
```

Set `playground: false` when the program uses files, processes, workers, signals, or the network. Add `-- posix: true` as a third line when the program cannot run on Windows. Declare every global with `global`, then pledge the narrowest permissions right after it.

Write the exact line that each `print` shows as a comment that starts with `-->`, either after the call or on the lines below it. Annotate only output that stays the same from run to run. Then add the name of the file to a section of `index.json`.

## Checking an example

`tests/conformance/examples_test.lus` runs every example of `index.json` in an empty temporary directory. An example passes when it exits with status 0 within the time limit, leaves no file behind, and prints every line that its `-->` comments name. The test also checks that every file is in `index.json` once. From `runtime/`, run the following command after you build `lus`:

```sh
zig-out/bin/lus test ../tests/conformance/examples_test.lus
```

Keep each file clean under `lus check` and `lus fmt --check`.
