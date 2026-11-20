# Prompts for your agent

Paste one of these into a coding agent such as Claude Code, Codex, Cursor, or Gemini CLI. Each prompt names exactly what the agent fetches and installs, so you can read those pages first.

## Try Lus in this project

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh`, then run `lus agents init` in this repository to add the Lus skills. Read https://lus.dev/llms.txt. Then look at this project and tell me where Lus would help: speed, permissions, dependencies it could drop, and shipping it as one executable. Change nothing yet.
```

## Write something new in Lus

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh` and run `lus agents init` here. Using the lus skill, write a small program that does the following, with tests, and run `lus check`, `lus fmt`, and `lus test` until they pass:

<describe the program>
```

## Rewrite this project in Lus

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh` and run `lus agents init` here. Follow the lus-rewrite skill. Start with the assessment and stop after it so I can decide.
```
