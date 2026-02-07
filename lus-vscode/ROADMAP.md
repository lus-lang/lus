# Lus VS Code Extension - Roadmap

## Phase 0: Syntax Highlighting and Language Configuration

- [x] TextMate grammar for Lus syntax (from lus-textmate)
- [x] Language configuration (brackets, comments, indentation, folding)
- [x] File association for `.lus` extension
- [x] Extension manifest (package.json)

**Milestone**: Opening a `.lus` file in VS Code shows syntax highlighting.

---

## Phase 1: WASM LSP Integration

- [x] WASM API extensions for LSP message handling (lus_load_lsp, lus_handle_message)
- [x] io.write/io.read overrides for capturing LSP output in WASM
- [x] Non-blocking LSP entry point (wasm.lus)
- [x] WASM build script updates (embed lus-language files, export new functions)
- [x] TypeScript WASM loader (wasm.ts)
- [x] Custom LSP MessageTransport over WASM (lspTransport.ts)
- [x] Extension activate/deactivate lifecycle (extension.ts)
- [ ] Build and test the WASM module with Emscripten
- [ ] End-to-end test: open .lus file, verify diagnostics appear

**Milestone**: Full language server features work in VS Code via WASM.

---

## Phase 2: Extension Packaging and Distribution

- [ ] Build pipeline: WASM compilation + TypeScript bundling
- [ ] VSIX packaging with vsce
- [ ] CI/CD for automated builds
- [ ] Marketplace publishing
- [ ] Extension icon and branding
- [ ] README with feature showcase and screenshots

**Milestone**: Extension is installable from the VS Code Marketplace.

---

## Phase 3: Native Binary Fallback

- [ ] Detect platform and check for `lus` binary on PATH
- [ ] Spawn `lus lus-language/main.lus` as stdio child process for desktop
- [ ] Use WASM transport for VS Code for Web
- [ ] Configuration option to prefer native or WASM

**Milestone**: Desktop users get native performance; web users still work.

---

## Phase 4: Enhanced Editor Features

- [ ] Snippets for common patterns (function, if/end, for/end, etc.)
- [ ] Task provider for `lus run` and `lus format`
- [ ] Debug Adapter Protocol (DAP) integration
- [ ] Run/debug code lens on functions
- [ ] Custom color theme optimized for Lus semantic tokens

**Milestone**: Full IDE experience for Lus development.
