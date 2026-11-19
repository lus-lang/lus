# Legacy runtime

This directory holds the Lus 1.7 C runtime, its test harnesses, and its release tooling, exactly as tagged at `v1.7-legacy`. It is frozen. It exists only as the differential oracle for the 2.0 rewrite in `runtime/`, and it is deleted before the rewrite merges into `main`.

Build and test it from this directory:

```sh
cd lus
meson setup build
meson compile -C build
meson test -C build --suite h1 --suite h2
```

The tests run with this directory as their working directory. The `lus-language` symbolic link points at `../packages/language-server` so the language server tests resolve their modules.
