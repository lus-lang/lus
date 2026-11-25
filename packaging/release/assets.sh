#!/bin/sh
# Prints the name of every asset of the release TAG, one per line, which
# release.yml and ship.yml compare with the files they are about to publish.
set -eu
tag="$1"
echo lus.wasm
echo lus-setup.exe
for target in x86_64-linux-musl aarch64-linux-musl arm-linux-musleabihf riscv64-linux-musl loongarch64-linux-musl powerpc64le-linux-musl s390x-linux-musl x86_64-freebsd aarch64-freebsd x86_64-macos aarch64-macos; do
  echo "lus-$tag-$target.tar.gz"
done
for target in x86_64-windows aarch64-windows; do
  echo "lus-$tag-$target.zip"
done
# Open VSX takes plain x.y.z versions, so only a stable release carries the
# extension.
case "$tag" in
  v*-*) ;;
  v*) echo "lus-${tag#v}.vsix"; echo "lus-${tag#v}-open-vsx-publisher.cjs" ;;
esac
