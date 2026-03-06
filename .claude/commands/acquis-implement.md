Implement the following acquis: $ARGUMENTS

Follow these steps precisely:

## 1. Find and read the acquis

Search `lus-site/src/manual/` for the acquis file matching the number or name provided. Read it fully.

If the acquis does NOT have `draft: true` in its frontmatter, inform the user that it appears to already be implemented/stable and ask whether to proceed.

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

## 5. Mark as stable

After implementation is complete:

1. **Acquis file**: Remove the `draft: true` line from the acquis `.mdx` frontmatter in `lus-site/src/manual/`.
2. **Spec files**: Change `stability: unstable` to `stability: stable` in all associated `lus-spec/` files identified in step 2.

## 6. Verify

- Run `meson test -C lus/build` to confirm tests pass (adjust build directory if platform-specific, e.g. `build-linux-glibc`)
- Run `npx astro build` from `lus-site/` to confirm the site builds cleanly
- Report results to the user
