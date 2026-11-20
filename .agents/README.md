# Agents

This folder holds what coding agents read to work with Lus: the skills, the curated `llms.txt` index, and the prompts the site offers to people who work through an agent. `spec/design/agents.md` describes the design.

- `skills/lus` teaches an agent to write, check, format, and test Lus.
- `skills/lus-rewrite` guides an agent through assessing a project and porting it to Lus behind a parity harness.
- `llms.txt` is the index served at `lus.dev/llms.txt`.
- `prompt.md` holds the prompts shown on `lus.dev/agents`.

`.agents/skills/` is the discovery path that agents across tools read. `.claude/skills` is a symbolic link to it.

Every `lus` code block in this folder runs under `lus test --doc`. From `runtime/`, run `zig-out/bin/lus test --doc ../.agents`.
