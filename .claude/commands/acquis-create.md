Create a new acquis (Lus RFC) from the following feature request: $ARGUMENTS

Follow these steps precisely:

## 1. Determine the next acquis number

Glob `lus-site/src/manual/acquis-*.mdx` to find all existing acquis files. Extract the highest number N. The new acquis number is N+1, and its order is 100 + (N+1).

## 2. Create the acquis file

Create `lus-site/src/manual/acquis-{N+1}.mdx` with this structure:

```yaml
---
order: {100 + N+1}
title: "Acquis {N+1} - {Feature Name}"
acquis: true
shortdesc: "{One-sentence description of the feature.}"
draft: true
---
```

The body should contain:
- A brief opening paragraph explaining the feature
- `##` sections for each distinct aspect (e.g. "Basic usage", "Advanced usage", integration with other features)
- Code examples using ` ```lus ` fencing (never `lua`)
- Keep the tone consistent with existing acquis pages — concise and specification-oriented

Read a few existing acquis files in `lus-site/src/manual/` for style reference before writing.

## 3. Create lus-spec definition files

For every function, constant, type, or C API proposed by the acquis, create a corresponding spec file:

**For Lus stdlib functions** → `lus-spec/stdlib/{module}/{function_name}.md`:
```yaml
---
name: module.function
module: module
kind: function
since: {current Lus version from CHANGELOG.md}
stability: unstable
origin: lus
params:
  - name: arg1
    type: string
  - name: arg2
    type: number
    optional: true
returns: returntype
---

Brief description of the function.
```

**For Lus stdlib constants** → `lus-spec/stdlib/{module}/{constant_name}.md`:
```yaml
---
name: module.constant
module: module
kind: constant
since: {current Lus version}
stability: unstable
origin: lus
type: string
value: '"value"'
---

Brief description.
```

**For C API functions** → `lus-spec/capi/{header_without_.h}/{function_name}.md`:
```yaml
---
name: lua_functionname
header: lua.h
kind: function
since: {current Lus version}
stability: unstable
origin: lus
signature: "returntype lua_functionname (lua_State *L, int arg)"
params:
  - name: L
    type: "lua_State*"
  - name: arg
    type: int
---

Brief description.
```

**For C API constants/typedefs** → same directory, use `kind: constant` or `kind: typedef` as appropriate.

Create subdirectories (`mkdir -p`) if they don't already exist. Read existing spec files in `lus-spec/stdlib/` and `lus-spec/capi/` for style reference.

## 4. Determine the current version

Read `CHANGELOG.md` in the repo root and use the topmost version number as the `since` value for all new spec files.

## 5. Verify

Run `npx astro build` from `lus-site/` to confirm the site builds cleanly with the new acquis page.

## 6. Report

List all created files with their full paths, and summarize what was defined.
