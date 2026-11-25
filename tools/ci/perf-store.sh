#!/bin/sh
# Adds one measurement to the perf-data branch, which holds nothing but
# measurements: nightly/DATE.json for each nightly run and release/TAG.json
# for each release. The branch starts empty the first time.
#
#   sh tools/ci/perf-store.sh PATH_ON_BRANCH FILE
#
# It runs in a checkout whose origin the workflow token can push to.

set -eu
dest=$1
file=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

remote=$(git config --get remote.origin.url)
auth=$(git config --get-regexp '^http\..*\.extraheader$' | head -1 | cut -d' ' -f2- || true)
cd "$work"
git init -q
git remote add origin "$remote"
if [ -n "$auth" ]; then git config "http.https://github.com/.extraheader" "$auth"; fi
if git fetch -q --depth 1 origin perf-data 2> /dev/null; then
  git checkout -q -b perf-data FETCH_HEAD
else
  git checkout -q --orphan perf-data
fi
mkdir -p "$(dirname "$dest")"
cp "$file" "$dest"
git add "$dest"
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "perf(perf): store $dest"
git push -q origin perf-data
