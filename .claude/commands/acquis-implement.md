Implement the following acquis: $ARGUMENTS

Follow these steps precisely:

## 1. Find and read the acquis

Search `lus-site/src/manual/` for the acquis file matching the number or name provided. Read it fully.

## 2. Read associated lus-spec definitions

Search `lus-spec/` for all files with `stability: unstable` that are related to this acquis (match by module name, function names, or feature area described in the acquis). Read each one to understand the full API surface that needs to be implemented.

List all found spec files for the user.

## 3. Plan the implementation

Enter plan mode. Design a complete implementation plan by:

- Reading the relevant source files in `lus/src/` to understand where changes are needed
- Identifying which C source files need modification (parser, VM, libraries, etc.)
- Planning any new test cases needed in `lus-tests/`
- Considering edge cases described in the acquis specification

Present the plan for user approval before making any changes.

## 4. Implement the feature

After the user approves the plan, implement the feature as designed.

## 5. Verify

- Run `meson test -C lus/build` to confirm tests pass (adjust build directory if platform-specific, e.g. `build-linux-glibc`)
- Run `npx astro build` from `lus-site/` to confirm the site builds cleanly
- Report results to the user
