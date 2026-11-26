# Third-party notices

Lus includes software and generated data maintained by other projects. The
runtime compiles the C sources it depends on into the same executable,
library, or WebAssembly module. The corresponding
license texts ship in the `licenses` directory.

| Component | Distributed artifact | License | License file |
| --- | --- | --- | --- |
| Brotli | Native runtime, WASM, site, VSIX | MIT | `LICENSE.BROTLI.txt` |
| Fontsource font files | Site | SIL Open Font License 1.1 | `LICENSE.FONTS.txt` |
| IANA time zone database | Native runtime, WASM, site, VSIX | Public domain | `LICENSE.TZDATA.txt` |
| JSON Test Suite fixtures | Source tests | MIT | `LICENSE.JTS.txt` |
| Lua | Native runtime, WASM, site, VSIX | MIT | `LICENSE.LUA.txt` |
| Lua language server lineage | WASM, site, VSIX | MIT | `LICENSE.LUALS.txt` |
| Lucide icons | Site | ISC | `LICENSE.LUCIDE.txt` |
| Mbed TLS | Native runtime | Apache 2.0 | `LICENSE.MBEDTLS.txt` |
| modern-monaco | Site | MIT | `LICENSE.MODERN-MONACO.txt` |
| musl libc | Native runtime for Linux musl targets | MIT | `LICENSE.MUSL.txt` |
| SQLite | Native runtime, WASM, site, VSIX | Public domain | `LICENSE.SQLITE.txt` |
| Unicode and CLDR data | Native runtime, WASM, site, VSIX | Unicode License V3 | `LICENSE.UNICODE.txt` |
| wasi-libc | WASM, site, VSIX | MIT, Apache 2.0 | `LICENSE.WASI-LIBC.txt` |
| Zig standard library and compiler runtime | Native runtime, WASM, site, VSIX | MIT | `LICENSE.ZIG.txt` |
| Zstandard | Native runtime, WASM, site, VSIX | BSD | `LICENSE.ZSTD.txt` |

The runtime pins the versions of its bundled sources.

| Component | Version | Source |
| --- | --- | --- |
| Brotli | 1.1.0 | `runtime/build.zig.zon` |
| IANA time zone database | 2026c | `runtime/src/lib/data/tzdata.version` |
| Mbed TLS | 3.6.8 | `runtime/build.zig.zon` |
| SQLite | 3.53.4 | `runtime/vendor/sqlite/sqlite3.h` |
| Zig | 0.17.1 | `mise.toml` |
| Zstandard | 1.5.7 | `runtime/build.zig.zon` |

The gzip, deflate, and LZ4 codecs of `vector.archive` and the WebAssembly
host in `packages/wasm` are written in Zig or JavaScript as part of Lus and
the Zig standard library. The TLS of the `network` library is Mbed TLS, which
Lus takes under the Apache 2.0 license of its dual license.

Each release archive contains an artifact-specific notice, the Lus license,
and the license texts for the components it redistributes. The release
inventory verifies that exact set.
