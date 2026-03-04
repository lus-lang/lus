# lus-spec

Centralized specification for the Lus standard library and C API. One `.md` file per entry, with YAML frontmatter for machine-readable metadata and markdown body for documentation prose.

## Directory Structure

```
lus-spec/
├── stdlib/           — Lus standard library
│   ├── base/         — Global functions (print, error, assert, ...)
│   ├── string/       — string.find, string.format, ...
│   ├── table/
│   ├── math/
│   ├── io/
│   ├── os/
│   ├── debug/
│   ├── coroutine/
│   ├── utf8/
│   ├── fs/           — Lus-specific filesystem library
│   │   └── path/
│   ├── network/      — Lus-specific networking library
│   │   ├── tcp/
│   │   └── udp/
│   ├── worker/       — Lus-specific concurrency library
│   ├── vector/       — Lus-specific byte buffer library
│   ├── package/
│   └── json/         — tojson / fromjson globals
└── capi/             — C embedding API
    ├── core/         — lua_* functions (lua.h)
    ├── auxiliary/     — luaL_* functions (lauxlib.h)
    ├── pledge/       — lus_pledge* (lpledge.h)
    ├── worker/       — lus_worker* (lworkerlib.h)
    └── library/      — luaopen_* entry points (lualib.h)
```

Filename is the bare name (e.g., `stdlib/string/find.md`, `capi/core/lua_pushstring.md`).
Nested sub-modules use subdirectories (e.g., `stdlib/network/tcp/connect.md`, `stdlib/fs/path/join.md`).

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
name: lua_pushstring
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_pushstring (lua_State *L, const char *s)"
params:
  - name: L
    type: lua_State*
  - name: s
    type: const char*
returns:
  - type: const char*
---
```

### C API type / struct

```yaml
---
name: lus_PledgeRequest
header: lpledge.h
kind: type
since: 0.1.0
stability: stable
origin: lus
signature: |
  typedef struct lus_PledgeRequest { ... } lus_PledgeRequest;
---
```

### C API constant

```yaml
---
name: LUS_PLEDGE_GRANT
header: lpledge.h
kind: constant
since: 0.1.0
stability: stable
origin: lus
type: int
value: 0
---
```

## Field Reference

| Field | Required | Values | Notes |
|-------|----------|--------|-------|
| `name` | yes | fully qualified name | `string.find`, `lua_pushstring`, `math.pi` |
| `module` | stdlib only | library name | `string`, `base`, `math` |
| `header` | capi only | header file | `lua.h`, `lauxlib.h`, `lpledge.h` |
| `kind` | yes | `function`, `constant`, `variable`, `module`, `type`, `macro` | |
| `since` | yes | Lus semver | Version when the entry first appeared |
| `stability` | yes | `stable`, `unstable`, `deprecated`, `removed` | |
| `origin` | yes | `lua`, `lus` | |
| `params` | functions | array of `{name, type, optional?}` | |
| `vararg` | functions | boolean | Whether `...` is accepted |
| `returns` | functions | array of `{type, name?}` | |
| `type` | constants/vars | type string | `number`, `string`, `int`, etc. |
| `value` | constants | literal value | Only for C `#define` constants |
| `signature` | capi funcs/types | C declaration | Full C prototype |
| `deprecated_by` | if deprecated | replacement name | |
| `removed_in` | if removed | version | When it was removed |

## Consumers

- **Website** (`lus-site/`): Astro content collections render API docs from these files
- **Language server** (`lus-language/`): `build-lsp.js` generates `stdlib_data.lus` from stdlib entries
- **Future**: editor hover docs, man pages, etc.

## Build

```sh
# Generate LSP data file
node lus-spec/build-lsp.js

# Rebuild WASM + VS Code extension (after any spec change)
cd lus/wasm && ./build.sh
cd lus-vscode && pnpm run build
```
