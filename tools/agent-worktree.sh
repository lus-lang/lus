#!/bin/sh
# Leaves the generated copy of the style guide out of the working tree of
# the current git worktree. The sandbox of an agent session cannot write
# under .agents/skills, so a checkout or reset that has to update that file
# stops halfway. With the file left out, git never writes it. The copy stays
# in the index, and `node tools/build-skills.js --check` reads it from
# there. Run it in a linked worktree. The post-checkout hook runs it in each
# new worktree when the main clone sets `lus.agentWorktrees` to true.

set -eu
cd "$(git rev-parse --show-toplevel)"
git config extensions.worktreeConfig true
git sparse-checkout set --no-cone '/*' '!/.agents/skills/lus-writing/references/style.md'
