#!/bin/sh
# Prepares a linked worktree for an agent session. The sandbox of an agent
# session cannot write under .agents/skills or create .claude/skills, so a
# checkout or reset that had to update either stopped halfway. Here git
# leaves both out of the working tree, so it never writes there, and
# symbolic links put the skills of the main clone in their place, so the
# session still reads them. The skill files stay in the index, and
# `node tools/build-skills.js --check` reads the generated copy from there.
# The post-checkout hook runs this script in each new worktree when the
# main clone sets `lus.agentWorktrees` to true.

set -eu
cd "$(git rev-parse --show-toplevel)"
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
main=$(dirname "$common")
[ "$(pwd -P)" != "$main" ] || { echo "agent-worktree.sh: run it in a linked worktree" >&2; exit 1; }

git config extensions.worktreeConfig true
git config --worktree sparse.expectFilesOutsideOfPatterns true
git sparse-checkout set --no-cone '/*' '!/.agents/skills/' '!/.claude/skills'
[ -e .agents/skills ] || ln -s "$main/.agents/skills" .agents/skills
mkdir -p .claude
[ -e .claude/skills ] || [ -L .claude/skills ] || ln -s "$main/.agents/skills" .claude/skills

# The links are untracked, so a per-worktree ignore file keeps them out of
# `git status` and `git add -A`.
ignore="$(git rev-parse --absolute-git-dir)/agent-ignore"
printf '/.agents/skills\n/.claude/skills\n' > "$ignore"
git config --worktree core.excludesFile "$ignore"
