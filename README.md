<p>
<a href="https://lus.dev">
<img src="./packages/site/src/assets/logo.svg" width="64" height="64">
</a>
</p>

# [Lus](https://lus.dev)

Lus is a small, productive programming language. It should be able to be picked up easily by programmers and put to good use right away.

[Instructions for compiling and using Lus can be found here.](https://lus.dev/manual/compiling/)

## Project tree

This is a monorepository containing the following projects:

- [**`/runtime`**](runtime): The Lus 2.0 runtime, written in Zig
- [**`/packages/wasm`**](packages/wasm): The runtime as a WebAssembly module with its JavaScript host
- [**`/tests`**](tests): Conformance, embedding, tool, and benchmark tests for the runtime
- [**`/spec`**](spec): Standard library specification and design notes
- [**`/packages/language-server`**](packages/language-server): Language server for Lus
- [**`/packages/vscode`**](packages/vscode): VSCode extension for Lus
- [**`/packages/textmate`**](packages/textmate): TextMate grammar
- [**`/packages/site`**](packages/site): Source code for lus.dev
- [**`/examples`**](examples): Examples of Lus syntax
- [**`/packaging`**](packaging): Install scripts, notices, and dependency licenses
- [**`/tools`**](tools): Generators and repository checks
- [**`/.agents`**](.agents): Skills and documentation index for coding agents

Tasks run through [mise](https://mise.jdx.dev). In a fresh clone, run `mise trust` and `mise install` once, then `mise tasks` to list them.

## Examples

[Browse the runnable examples](https://lus.dev/examples/) for focused language and standard library recipes. Browser-compatible examples open directly in the playground.

## License

These works are licensed under the 0-clause BSD license. They may be used for any purpose, including commercial purposes, at no cost. [For more details, consult the license here.](/LICENSE.md)

Dependency licenses can be found in [`/packaging/licenses`](/packaging/licenses).
