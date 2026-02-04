# Lus Language Server - Design Document

## Overview

The Lus Language Server (lus-language) provides IDE features for Lus files through the Language Server Protocol (LSP). It is written entirely in Lus, leveraging the language's built-in `debug.parse` for AST generation and `fromjson`/`tojson` for protocol communication.

## Goals

1. **Self-hosted**: Written in Lus, demonstrating the language's capabilities
2. **WASM-compatible**: Runs in the VS Code extension via Lus's WebAssembly build
3. **Lus-focused**: Handles `.lus` files natively; lightweight Lua 5.5 parser for `require()`d `.lua` files
4. **Practical**: Prioritize features that improve day-to-day development

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    VS Code Extension                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Lus WASM Runtime                          │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │            lus-language                          │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │  │  │
│  │  │  │  JSON-RPC │  │ Document │  │    AST       │  │  │  │
│  │  │  │ Transport │  │  Store   │  │  Analysis    │  │  │  │
│  │  │  └──────────┘  └──────────┘  └──────────────┘  │  │  │
│  │  │        │              │              │          │  │  │
│  │  │        └──────────────┴──────────────┘          │  │  │
│  │  │                       │                          │  │  │
│  │  │              ┌────────┴────────┐                │  │  │
│  │  │              │  debug.parse    │                │  │  │
│  │  │              │  (Lus AST)      │                │  │  │
│  │  │              └─────────────────┘                │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Components

1. **JSON-RPC Transport**: Reads/writes LSP messages via stdin/stdout using `fromjson`/`tojson`
2. **Document Store**: Maintains open document state with incremental text sync
3. **AST Analysis**: Uses `debug.parse` to build and analyze syntax trees
4. **Symbol Index**: Tracks definitions, references, and scopes across files
5. **Lightweight Lua Parser**: Minimal parser for `.lua` files to extract exports for `require()` resolution

## Key Design Decisions

### Parser Strategy: `debug.parse` vs Custom Parser

**Recommendation: Use `debug.parse` with potential enhancements**

`debug.parse` already provides:

- Full AST with node types, line numbers, and structure
- All Lus-specific syntax (optional chaining, catch expressions, string interpolation, etc.)
- Correct handling of edge cases (it uses the actual parser)

Current limitations that may need addressing:

- No column/character position (only line numbers)
- No error recovery (returns `nil` on parse errors)
- No comment preservation

**Proposed Approach**:

1. Start with `debug.parse` for v1
2. Identify specific gaps through real-world usage
3. Consider enhancements to `debug.parse` in the Lus runtime:
   - Add `column` field to AST nodes (requires parser modification)
   - Add partial parsing mode for error recovery
   - Optionally preserve comments as AST nodes

If `debug.parse` proves fundamentally inadequate, a custom Lus-in-Lus parser could be written later, but this is a significant undertaking and should be avoided if possible.

### Formatting: `lus format` CLI vs Language Server Only

**Recommendation: Implement as `lus format` CLI command**

Advantages of CLI approach:

- Usable outside of IDE (CI pipelines, git hooks, scripts)
- Single implementation shared between CLI and LSP
- Follows patterns of `gofmt`, `rustfmt`, `stylua`
- Can be tested independently

The language server would invoke the same formatting logic internally when handling `textDocument/formatting` requests.

Implementation location: The formatter would be a Lus module that can be:

- Called from the `lus` CLI via a new `format` subcommand
- Imported and used by the language server

## Communication Protocol

### LSP over JSON-RPC

Messages follow the LSP specification with Content-Length headers:

```
Content-Length: 52\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize",...}
```

The transport layer:

1. Reads `Content-Length` header from stdin
2. Reads exactly that many bytes of JSON
3. Parses with `fromjson`
4. Dispatches to method handler
5. Serializes response with `tojson`
6. Writes with `Content-Length` header to stdout

### Message Types

- **Requests**: Have `id`, expect response (e.g., `textDocument/completion`)
- **Notifications**: No `id`, no response (e.g., `textDocument/didOpen`)
- **Responses**: Match request `id` with result or error

## Supported Features

### Phase 1: Core (MVP)

| Feature          | LSP Method                                      | Description                               |
| ---------------- | ----------------------------------------------- | ----------------------------------------- |
| Document Sync    | `textDocument/didOpen`, `didChange`, `didClose` | Track open documents                      |
| Diagnostics      | `textDocument/publishDiagnostics`               | Syntax errors from parse failures         |
| Document Symbols | `textDocument/documentSymbol`                   | Outline view (functions, locals, globals) |
| Formatting       | `textDocument/formatting`                       | Code formatting                           |

### Phase 2: Navigation

| Feature          | LSP Method                | Description                          |
| ---------------- | ------------------------- | ------------------------------------ |
| Go to Definition | `textDocument/definition` | Jump to variable/function definition |
| Find References  | `textDocument/references` | Find all usages                      |
| Hover            | `textDocument/hover`      | Show info on hover                   |
| Rename           | `textDocument/rename`     | Rename symbol across files           |

### Phase 3: Intelligence

| Feature         | LSP Method                    | Description                  |
| --------------- | ----------------------------- | ---------------------------- |
| Completion      | `textDocument/completion`     | Auto-complete suggestions    |
| Signature Help  | `textDocument/signatureHelp`  | Function parameter hints     |
| Semantic Tokens | `textDocument/semanticTokens` | Enhanced syntax highlighting |
| Folding Ranges  | `textDocument/foldingRange`   | Code folding                 |

### Phase 4: Advanced

| Feature           | LSP Method                | Description                 |
| ----------------- | ------------------------- | --------------------------- |
| Workspace Symbols | `workspace/symbol`        | Project-wide symbol search  |
| Code Actions      | `textDocument/codeAction` | Quick fixes, refactoring    |
| Inlay Hints       | `textDocument/inlayHint`  | Inline type/parameter hints |

## Lua 5.5 Lightweight Parser

For `require()`d `.lua` files, we need to extract:

- Module return type (what `require()` returns)
- Exported function signatures
- Global assignments

This doesn't need a full parser. A lightweight approach:

1. Tokenize the Lua source
2. Track top-level assignments and function definitions
3. Identify the return statement pattern
4. Build a simplified symbol table

This information enables:

- Completion for required module members
- Hover info for Lua library functions
- Go-to-definition into `.lua` files (best effort)

## File Structure

```
lus-language/
├── main.lus              # Entry point, message loop
├── transport.lus         # JSON-RPC over stdio
├── protocol.lus          # LSP types and constants
├── document.lus          # Document store and sync
├── analysis/
│   ├── ast.lus           # AST utilities using debug.parse
│   ├── scope.lus         # Scope analysis and symbol resolution
│   ├── symbols.lus       # Symbol table management
│   └── diagnostics.lus   # Error detection and reporting
├── operations/
│   ├── completion.lus    # Auto-completion
│   ├── definition.lus    # Go-to-definition
│   ├── hover.lus         # Hover information
│   ├── references.lus    # Find references
│   ├── rename.lus        # Symbol rename
│   ├── symbols.lus       # Document/workspace symbols
│   └── format.lus        # Code formatting
├── lua/
│   └── parser.lus        # Lightweight Lua 5.5 parser
└── util/
    ├── uri.lus           # URI handling
    └── position.lus      # Position/range utilities
```

## Error Handling

Since `debug.parse` returns `nil` on parse errors without details:

1. On parse failure, attempt to provide a generic "syntax error" diagnostic
2. Consider enhancing `debug.parse` to return error information
3. For partial analysis, cache the last successful AST

## Performance Considerations

1. **Incremental updates**: Only re-parse changed documents
2. **Lazy analysis**: Compute symbols/diagnostics on demand
3. **Caching**: Cache ASTs and symbol tables
4. **Debouncing**: Delay analysis after rapid edits

## Testing Strategy

1. **Unit tests**: Individual functions (AST traversal, scope analysis)
2. **Protocol tests**: JSON-RPC message handling
3. **Integration tests**: Full request/response cycles
4. **Snapshot tests**: Expected responses for sample documents

## Future Considerations

- **Type inference**: Basic type tracking for better completions
- **Linting**: Style and best-practice warnings
- **Code actions**: Auto-import, extract function, etc.
- **Debugging**: DAP (Debug Adapter Protocol) integration
- **Multi-root workspaces**: Multiple project folders
