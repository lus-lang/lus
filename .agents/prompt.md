# Prompts for your agent

Paste one of these into a coding agent such as Claude Code, Codex, Cursor, or Gemini CLI. Each prompt names exactly what the agent fetches and installs, so you can read those pages first.

## Try Lus here

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh`. Then add the Lus skills. In Claude Code, run `claude plugin install lus --marketplace lus-lang/lus`. In any other agent, run `lus agents init` in this project. Use one method. You can read the skill first at https://lus.dev/agents/skills/lus/SKILL.md. Then use the lus skill to look at this project and tell me where Lus would help. Change nothing yet.
```

## Write something new

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh`. Then add the Lus skills. In Claude Code, run `claude plugin install lus --marketplace lus-lang/lus`. In any other agent, run `lus agents init` in this project. Use one method. You can read the skill first at https://lus.dev/agents/skills/lus/SKILL.md. Then use the lus skill to write the program below, with tests, and run `lus check`, `lus fmt`, and `lus test` until they pass.

<describe the program>
```

## Rewrite a project

```text
Install Lus with `curl -fsSL https://lus.dev/install.sh | sh`. Then add the Lus skills. In Claude Code, run `claude plugin install lus --marketplace lus-lang/lus`. In any other agent, run `lus agents init` in this project. Use one method. You can read the skill first at https://lus.dev/agents/skills/lus/SKILL.md. Then follow the lus-rewrite skill for this project. Start with the assessment and stop after it so I can decide.
```
