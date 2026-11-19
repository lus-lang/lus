# Lus specification

Centralized specification for the Lus standard library and the C embedding API of `lus.h`. Each entry is one `.md` file with YAML frontmatter for machine-readable metadata and a Markdown body for documentation prose.

## Directory Structure

```
spec/
├── stdlib/           # Lus standard library
│   ├── base/         # Global functions (print, error, assert, ...)
│   ├── string/       # string.find, string.format, ...
│   ├── table/
│   ├── math/
│   ├── io/
│   ├── os/
│   ├── debug/
│   ├── coroutine/
│   ├── utf8/
│   ├── fs/           # Lus-specific filesystem library
│   │   └── path/
│   ├── network/      # Lus-specific networking library
│   │   ├── tcp/
│   │   └── udp/
│   ├── worker/       # Lus-specific concurrency library
│   ├── vector/       # Lus-specific byte buffer library
│   ├── package/
│   └── json/         # tojson / fromjson globals
└── capi/             # C embedding API (lus.h)
    ├── state/        # creating, closing, and collecting a state
    ├── stack/        # stack indices and rearranging values
    ├── read/         # type codes and reading values
    ├── push/         # pushing values
    ├── tables/       # tables and globals
    ├── functions/    # C functions and their upvalues
    ├── userdata/     # userdata and metatables
    ├── references/   # references to values outside the stack
    ├── call/         # loading and calling code
    ├── errors/       # status codes and raising errors from C
    └── permissions/  # host permission policy and custom capabilities
```

The filename is the bare name (for example `stdlib/string/find.md` or `capi/push/lus_pushstring.md`).
Nested submodules use subdirectories (for example `stdlib/network/tcp/connect.md` or `stdlib/fs/path/join.md`).
Each directory under `capi/` is one section of the C API reference, in the order that `packages/site/src/lib/api.ts` lists them.
A group of related C constants shares one entry, whose `signature` lists every `#define` of the group and whose `name` is the shared prefix, such as `LUS_T*`.
Its file is named after the prefix without the wildcard, such as `capi/read/LUS_T.md`.

## Frontmatter Schema

### Stdlib function

```yaml
---
name: string.find
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: pattern
    type: string
  - name: init
    type: integer
    optional: true
  - name: plain
    type: boolean
    optional: true
vararg: false
returns:
  - type: integer
    name: start
  - type: integer
    name: finish
  - type: "string..."
    name: captures
---
```

### Stdlib constant / variable

```yaml
---
name: math.pi
module: math
kind: constant
since: 0.1.0
stability: stable
origin: lua
type: number
---
```

### Stdlib module entry

```yaml
---
name: network.tcp
module: network
kind: module
since: 0.1.0
stability: stable
origin: lus
---
```

### C API function

```yaml
---
name: lus_pushstring
header: lus.h
kind: function
since: "2.0.0"
stability: stable
origin: lus
signature: "int lus_pushstring(lus_State *L, const char *s)"
params:
  - name: L
    type: "lus_State*"
  - name: s
    type: "const char*"
returns:
  - type: "int"
    name: status
---
```

### C API type

```yaml
---
name: lus_State
header: lus.h
kind: type
since: "2.0.0"
stability: stable
origin: lus
signature: "typedef struct lus_State lus_State;"
---
```

### C API constant

```yaml
---
name: LUS_NOREF
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: "#define LUS_NOREF 0"
type: int
value: 0
---
```

### C API constant group

```yaml
---
name: "LUS_CAP_*"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: |
  #define LUS_CAP_NONE 0
  #define LUS_CAP_PATH 1
  #define LUS_CAP_HOST 2
  #define LUS_CAP_PATTERN 3
  #define LUS_CAP_CUSTOM 4
---
```

The body of a C API entry documents the behavior exactly as the runtime implements it: the stack effect, the status codes, the error value left on the stack, and who owns a returned pointer. C code blocks in the body compile against `lus.h`.

## Field Reference

| Field | Required | Values | Notes |
|-------|----------|--------|-------|
| `name` | yes | fully qualified name | `string.find`, `lus_pushstring`, `math.pi`, `LUS_T*` |
| `module` | stdlib only | library name | `string`, `base`, `math` |
| `header` | capi only | header file | `lus.h` |
| `kind` | yes | `function`, `constant`, `variable`, `module`, `type`, `macro` | |
| `since` | yes | Lus semver | Version when the entry first appeared |
| `stability` | yes | `stable`, `unstable`, `deprecated`, `removed` | |
| `origin` | yes | `lua`, `lus` | |
| `params` | functions | array of `{name, type, optional?}` | |
| `vararg` | functions | boolean | Whether `...` is accepted |
| `returns` | functions | array of `{type, name?}` | |
| `type` | constants/vars | type string | `number`, `string`, `int`, etc. |
| `receiver` | methods | nominal receiver type | `instant`, `database` |
| `flags` | optional | array of schema flags | Consumer-specific structured metadata |
| `from` | optional | qualified source symbol | Structured provenance for generated consumers |
| `value` | constants | literal value | Only for a single C `#define` constant |
| `signature` | capi | C declaration | Full C prototype, typedef, or `#define` lines |
| `deprecated_by` | if deprecated | replacement name | |
| `removed_in` | if removed | version | When it was removed |

## Consumers

- **Website** (`packages/site/`): Astro content collections render `/manual/api` from `stdlib/` and `/manual/api/c` from `capi/`
- **Language server** (`packages/language-server/`): `tools/build-lsp.js` generates `stdlib_data.lus` from stdlib entries
- **Future**: editor hover docs, man pages, etc.

## Build

```sh
# Validate the generator and schema
node tools/build-lsp.test.js

# Generate the LSP symbol graph
node tools/build-lsp.js

# Validate schema and generated-file freshness without writing
node tools/build-lsp.js --check

# Run the Lus examples in the spec
cd runtime && zig build -Doptimize=ReleaseSafe && zig-out/bin/lus test --doc ../spec

# Rebuild the VS Code extension (after any stdlib spec change)
mise run vscode
```

The generated language server data contains one symbol graph keyed by qualified
name. Nested modules link to their children at any depth. Function parameters
and returns remain structured so completion, hover, signature help, and type
inference resolve the same records.
