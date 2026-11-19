# Lus

Language support for [Lus](https://github.com/lus-lang/lus), a small, productive, and sovereign programming language designed to be picked up easily by programmers and put to good use right away.

This extension provides completions, diagnostics, syntax highlighting, and formatting for `.lus` files. Each extension release carries its matching Lus WebAssembly runtime, language server, and standard library data.

The package runs in VS Code's Node-based workspace extension host. Remote workspaces run it in their remote workspace host, where it mirrors `.lus` and `.lua` files through the VS Code filesystem API for cross-file analysis. Browser-only extension-host packaging is planned for a future release.

The language client and server accept JSON-RPC frames up to 16 MiB. Oversized or malformed frames are rejected before dispatch.

## Links

- [Repository](https://github.com/lus-lang/lus)
- [Manual](https://lus.dev/manual/introduction/)
