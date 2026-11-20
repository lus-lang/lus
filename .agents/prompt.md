# Prompts for your agent

Paste one of these into a coding agent such as Claude Code, Codex, Cursor, or Gemini CLI. Each prompt names exactly what the agent fetches and installs, so you can read those pages first.

## Try Lus here

```text
Install Lus (curl -fsSL https://lus.dev/install.sh | sh), run `lus agents init` here, read https://lus.dev/llms.txt, and tell me where Lus would help this project. Change nothing yet.
```

## Write something new

```text
Install Lus (curl -fsSL https://lus.dev/install.sh | sh) and run `lus agents init` here. Using the lus skill, write a small program that does the following, with tests, and run `lus check`, `lus fmt`, and `lus test` until they pass:

<describe the program>
```

## Rewrite a project

```text
Install Lus (curl -fsSL https://lus.dev/install.sh | sh) and run `lus agents init` here. Follow the lus-rewrite skill. Start with the assessment and stop after it so I can decide.
```
