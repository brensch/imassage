#!/usr/bin/env bash
# Builds the bridge image: upstream jasonlaguidice/imessage at a pinned commit plus our patches.
# Upstream's own Dockerfile does the build; we only patch the source first.
#
# mac-anisette.patch: take anisette headers from a real Mac (ANISETTE_MAC_URL) instead of the
# public remote servers, which Apple has rejected with -80045 since Oct 2026.
set -euo pipefail
cd "$(dirname "$0")"

UPSTREAM=https://github.com/jasonlaguidice/imessage.git
COMMIT=595ce7e9bb588fbcf7cbe9906a0b79b7b0869c41
TAG="imassage-bridge:${COMMIT:0:7}-mac"

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git clone -q "$UPSTREAM" "$src"
git -C "$src" checkout -q "$COMMIT"
for p in ./*.patch; do
	git -C "$src" apply "$PWD/$p"
done

docker build -t "$TAG" \
	--build-arg BUILD_VERSION=imassage \
	--build-arg BUILD_COMMIT="${COMMIT:0:7}" \
	"$src"
echo "built $TAG"
