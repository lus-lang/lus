#!/bin/sh
# Lands an accepted outside contribution as one signed commit: the
# contribution and the fixes of its security review, squashed together.
#
#   tools/land-contribution.sh PR_NUMBER [FIXES_REF] [--base REF]
#
# FIXES_REF is a branch that starts at the head of the PR and holds the
# fixes, if the review found any. The commit goes on a new branch
# land/pr-N from the base of the PR. Its author is the author of the first
# commit of the PR, and every other author and every Co-Authored-By
# trailer of the PR's commits stays as a trailer. git opens the message in
# the editor, starting from the title and the body of the PR. The script
# never pushes.

set -eu

usage() {
  echo "usage: tools/land-contribution.sh PR_NUMBER [FIXES_REF] [--base REF]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
pr=$1
shift
case "$pr" in *[!0-9]* | "") usage ;; esac
fixes=""
base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base=$2; shift 2 ;;
    -*) usage ;;
    *) fixes=$1; shift ;;
  esac
done

root=$(git rev-parse --show-toplevel)
cd "$root"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "land-contribution: commit or set aside the changes of this checkout first" >&2
  exit 1
fi

git fetch --quiet origin "pull/$pr/head:refs/lus-review/pr-$pr"
head=$(git rev-parse "refs/lus-review/pr-$pr")
title=""
body=""
if command -v gh > /dev/null; then
  [ -n "$base" ] || base="origin/$(gh pr view "$pr" --json baseRefName --jq .baseRefName)"
  title=$(gh pr view "$pr" --json title --jq .title)
  body=$(gh pr view "$pr" --json body --jq .body)
fi
[ -n "$base" ] || base=origin/main
git fetch --quiet origin
fork=$(git merge-base "$base" "$head")

source=$head
if [ -n "$fixes" ]; then
  source=$(git rev-parse --verify "$fixes^{commit}")
  if ! git merge-base --is-ancestor "$head" "$source"; then
    echo "land-contribution: $fixes does not start at the head of PR $pr" >&2
    exit 1
  fi
fi

first=$(git rev-list --reverse "$fork..$head" | head -1)
author=$(git log -1 --format='%an <%ae>' "$first")

msg=$(mktemp "${TMPDIR:-/tmp}/lus-land.XXXXXX")
trap 'rm -f "$msg"' EXIT INT TERM
{
  printf '%s\n' "${title:-Land PR $pr}"
  if [ -n "$body" ]; then printf '\n%s\n' "$body"; fi
  printf '\n'
  # Every other author of the PR, and every trailer its commits carry.
  git log --format='%an <%ae>' "$fork..$head" | sort -u | grep -vxF "$author" | sed 's/^/Co-Authored-By: /' || true
  git log --format='%(trailers:key=Co-Authored-By,valueonly=false)' "$fork..$head" | grep -i '^Co-Authored-By:' | sort -u || true
} > "$msg"

branch="land/pr-$pr"
git switch --quiet -c "$branch" "$base"
git merge --squash --quiet "$source"
git commit --quiet -S --author "$author" --edit -F "$msg"
echo "land-contribution: $branch holds the squashed commit. Review it, then merge and push it yourself." >&2
