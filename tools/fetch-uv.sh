#!/bin/zsh
# Puts the pinned uv into <dest-dir>/uv: downloaded once into build/uv/<version>/ and checked
# against the release's sha256. The app carries it in Contents/Helpers (DECISIONS 40).
set -e
VERSION=0.13.7
SHA256=81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731
DEST=${1:?usage: tools/fetch-uv.sh <dest-dir>}
CACHE="$(cd "$(dirname "$0")/.." && pwd)/build/uv/$VERSION"
if [ ! -x "$CACHE/uv" ]; then
  mkdir -p "$CACHE"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/uv.tar.gz" "https://github.com/astral-sh/uv/releases/download/$VERSION/uv-aarch64-apple-darwin.tar.gz"
  echo "$SHA256  $TMP/uv.tar.gz" | shasum -a 256 -c --status || { echo "uv $VERSION: sha256 mismatch"; exit 1; }
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP" --strip-components 1 uv-aarch64-apple-darwin/uv
  mv "$TMP/uv" "$CACHE/uv"
fi
mkdir -p "$DEST"
rm -f "$DEST/uv"
cp "$CACHE/uv" "$DEST/uv"
