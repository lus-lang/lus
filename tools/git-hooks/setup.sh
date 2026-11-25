#!/bin/sh
# Configures a clone for contributing: git runs the hooks of this
# directory, and every commit and tag is signed. `mise run setup` runs it.
# It never creates or chooses a key.

set -eu
root=$(git rev-parse --show-toplevel)
cd "$root"

git config core.hooksPath tools/git-hooks
git config commit.gpgsign true
git config tag.gpgsign true
chmod +x tools/git-hooks/pre-commit tools/git-hooks/commit-msg tools/git-hooks/post-checkout

echo "Your clone now runs the hooks of tools/git-hooks and signs every commit and tag."
if [ -z "$(git config user.signingkey || true)" ]; then
  cat << 'MSG'
Configure a signing key. To sign with the SSH key you already use for
GitHub, run:

  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/id_ed25519.pub

Then add the same key to GitHub as a signing key
(https://github.com/settings/ssh/new, key type "Signing Key"), so GitHub
shows your commits as verified.
MSG
fi
