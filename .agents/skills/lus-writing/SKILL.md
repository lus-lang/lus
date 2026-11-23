---
name: lus-writing
description: Write and revise prose in the house style of the Lus project, for documentation, READMEs, AGENTS.md files, doc comments, error messages, commit messages, and changelogs. Use when writing or reviewing any prose in the Lus repository, the atmosphere registry, an atmos package, or a project whose AGENTS.md says prose follows lus-writing.
---

# Writing in the Lus style

Lus documentation states behavior so precisely that a reader can predict the result of a call without running it, in plain sentences that flow. The full guide is [references/style.md](references/style.md). Read it before writing prose for the first time in a session, and again before reviewing someone else's.

## The loop

1. Write the passage as if for a reader who knows general programming and nothing about the project.
2. Run the greps of the checklist in section 12 of the guide over the changed files, and judge every hit by the rule it points to.
3. Reread each paragraph for the points a grep cannot find: a run of short sentences that tells one scenario, a metaphor or a personified verb, a term used before it is introduced, a claim that goes stale or that a reader can refute, and an example that does no recognisable job.
4. Run the project's own checks. In the Lus repository these are `node tools/lint-repo.js` after a commit and `lus test --doc` over the changed pages. In a package they are `lus check` and `lus test`.

## The rules most often broken

- Two independent clauses are never joined with ", and". Name the relation with "so", "because", or "which", or write two sentences.
- One scenario is one sentence. A run of short sentences that tells one scenario is joined with relative or subordinate clauses.
- No em dashes, en dashes, or semicolons in prose.
- A page talks about its subject, never about itself or its reader.
- "is" and "are", never "serves as" or "acts as".
- No counts or versions that go stale, and no claim that the thing compared with contradicts.
