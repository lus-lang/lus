# Third-party notices for Lus WASM archives

Lus WASM archives contain the WebAssembly runtime, Emscripten runtime support,
generated Unicode and CLDR data, and the embedded Lus language server. The
language server retains lineage from the Lua language server. The complete
license texts ship beside this notice.

| Component | License file |
| --- | --- |
| Emscripten runtime support | `LICENSE.EMSCRIPTEN.txt` |
| Lua | `LICENSE.LUA.txt` |
| Lua language server lineage | `LICENSE.LUALS.txt` |
| Unicode and CLDR data | `LICENSE.UNICODE.txt` |

The WASM build uses the components listed above. The native artifact set
carries the network, compression, and SQLite dependency licenses.
