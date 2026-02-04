# Lus Language Server - Implementation Roadmap

## Phase 0: Foundation

### 0.1 JSON-RPC Transport

- [ ] Read Content-Length header from stdin
- [ ] Parse JSON message body with `fromjson`
- [ ] Write responses with Content-Length to stdout
- [ ] Handle malformed messages gracefully
- [ ] Basic logging/tracing for debugging

### 0.2 LSP Lifecycle

- [ ] Handle `initialize` request, return server capabilities
- [ ] Handle `initialized` notification
- [ ] Handle `shutdown` request
- [ ] Handle `exit` notification
- [ ] Track initialization state

### 0.3 Document Store

- [ ] Handle `textDocument/didOpen` - store document content
- [ ] Handle `textDocument/didChange` - apply incremental edits
- [ ] Handle `textDocument/didClose` - remove document
- [ ] URI parsing and normalization
- [ ] Line/column position utilities

**Milestone**: Server starts, connects, and tracks open documents.

---

## Phase 1: Diagnostics and Symbols

### 1.1 Parse Integration

- [ ] Call `debug.parse` on document content
- [ ] Cache AST per document
- [ ] Invalidate cache on document change
- [ ] Handle parse failures

### 1.2 Syntax Diagnostics

- [ ] Detect parse errors (when `debug.parse` returns nil)
- [ ] Publish diagnostics via `textDocument/publishDiagnostics`
- [ ] Clear diagnostics on successful parse
- [ ] Map error information to LSP Diagnostic format

### 1.3 Document Symbols

- [ ] Implement `textDocument/documentSymbol`
- [ ] Extract functions (local, global, methods)
- [ ] Extract variables (local, global declarations)
- [ ] Build symbol hierarchy (nested functions)
- [ ] Include symbol kind and location

**Milestone**: Outline view works, syntax errors shown.

---

## Phase 2: Formatting

### 2.1 Formatter Core

- [ ] Design formatting rules (indentation, spacing, line breaks)
- [ ] AST-to-string conversion with formatting
- [ ] Preserve comments (may require enhancing debug.parse or separate comment extraction)
- [ ] Handle all Lus constructs

### 2.2 LSP Integration

- [ ] Implement `textDocument/formatting`
- [ ] Return TextEdit array for full document
- [ ] Handle formatting options (tab size, insert spaces)

### 2.3 CLI Integration

- [ ] Add `lus format` command to CLI
- [ ] Support file arguments and stdin
- [ ] `--check` mode (exit non-zero if unformatted)
- [ ] `--write` mode (format in place)

**Milestone**: Code can be formatted via IDE and CLI.

---

## Phase 3: Scope Analysis

### 3.1 Scope Builder

- [ ] Build scope tree from AST
- [ ] Track variable declarations (local, global, for-loop vars)
- [ ] Track function parameters
- [ ] Handle shadowing correctly
- [ ] Track scope boundaries (blocks, functions)

### 3.2 Symbol Resolution

- [ ] Resolve name references to declarations
- [ ] Build definition-to-references map
- [ ] Handle upvalues (references to outer scopes)
- [ ] Track global vs local distinction

### 3.3 Cross-File Analysis

- [ ] Parse `require()` calls, resolve module paths
- [ ] Build module dependency graph
- [ ] Track exports per module
- [ ] Invalidate dependents on file change

**Milestone**: Symbol resolution works within and across files.

---

## Phase 4: Navigation

### 4.1 Go to Definition

- [ ] Implement `textDocument/definition`
- [ ] Find declaration for name at position
- [ ] Handle local variables and functions
- [ ] Handle required module members
- [ ] Return Location or LocationLink

### 4.2 Find References

- [ ] Implement `textDocument/references`
- [ ] Find all usages of symbol at position
- [ ] Include declaration optionally
- [ ] Search across open documents

### 4.3 Hover

- [ ] Implement `textDocument/hover`
- [ ] Show variable name and scope
- [ ] Show function signature
- [ ] Show documentation comments if present

### 4.4 Rename

- [ ] Implement `textDocument/rename`
- [ ] Validate rename is possible
- [ ] Compute all locations to change
- [ ] Return WorkspaceEdit

**Milestone**: Full navigation features work.

---

## Phase 5: Completion

### 5.1 Basic Completion

- [ ] Implement `textDocument/completion`
- [ ] Complete local variables in scope
- [ ] Complete global variables
- [ ] Complete keywords contextually

### 5.2 Member Completion

- [ ] Complete table fields after `.`
- [ ] Complete methods after `:`
- [ ] Track table structures from assignments
- [ ] Complete standard library members

### 5.3 Signature Help

- [ ] Implement `textDocument/signatureHelp`
- [ ] Show function parameters on `(`
- [ ] Highlight current parameter
- [ ] Support overloaded functions (multiple signatures)

**Milestone**: Auto-completion provides useful suggestions.

---

## Phase 6: Lua Interop

### 6.1 Lua Tokenizer

- [ ] Tokenize Lua 5.5 source
- [ ] Handle all token types (keywords, identifiers, strings, numbers)
- [ ] Track token positions

### 6.2 Export Extraction

- [ ] Identify module return patterns
- [ ] Extract top-level function definitions
- [ ] Extract assigned globals/locals that are returned
- [ ] Build simplified symbol table

### 6.3 Integration

- [ ] Resolve `require()` to `.lua` files
- [ ] Provide completion for Lua module members
- [ ] Go-to-definition into Lua files (best effort)

**Milestone**: Completion and navigation work for required Lua modules.

---

## Phase 7: Enhanced Features

### 7.1 Semantic Tokens

- [ ] Implement `textDocument/semanticTokens/full`
- [ ] Classify tokens (function, variable, parameter, etc.)
- [ ] Add modifiers (declaration, definition, readonly)
- [ ] Differentiate locals vs globals vs upvalues

### 7.2 Folding Ranges

- [ ] Implement `textDocument/foldingRange`
- [ ] Fold functions, if/else, loops
- [ ] Fold multi-line tables
- [ ] Fold comment blocks

### 7.3 Inlay Hints

- [ ] Implement `textDocument/inlayHint`
- [ ] Show parameter names at call sites
- [ ] Show inferred types (if type tracking added)

### 7.4 Workspace Symbols

- [ ] Implement `workspace/symbol`
- [ ] Index symbols across all workspace files
- [ ] Support fuzzy matching

**Milestone**: Full-featured language server.

---

## Optional Enhancements

### debug.parse Improvements (Lus Core)

- [ ] Add column positions to AST nodes
- [ ] Error recovery mode (return partial AST)
- [ ] Comment preservation option
- [ ] Source range (start + end) per node

### Linting

- [ ] Unused variable warnings
- [ ] Undefined global warnings
- [ ] Style suggestions
- [ ] Configurable rule set

### Code Actions

- [ ] Auto-import for undefined globals
- [ ] Extract to local variable
- [ ] Extract to function
- [ ] Convert string concatenation to interpolation

---

## Testing Milestones

After each phase:

1. Unit tests for new functionality
2. Integration tests with sample documents
3. Manual testing in VS Code extension
4. Performance profiling for large files

## Dependencies

- `fromjson` / `tojson` - JSON serialization
- `debug.parse` - AST generation
- `io` - stdin/stdout communication
- `string` - text manipulation
- `table` - data structures
