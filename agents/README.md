# Agents

This folder holds what coding agents read to work with Lus: the skills, the curated `llms.txt` index, and the prompts the site offers to people who work through an agent.

- `skills/lus` teaches an agent to write, check, format, and test Lus.
- `skills/lus-rewrite` guides an agent through assessing a project and porting it to Lus behind a parity harness.
- `llms.txt` is the index served at `lus.dev/llms.txt`.
- `prompt.md` holds the prompts shown on `lus.dev/agents`.
- `PROPOSAL.md` describes the strategy and the decisions under review.

Every `lus` code block in this folder runs under `lus test --doc`. Run it from `runtime/` with `zig-out/bin/lus test --doc ../agents`.
