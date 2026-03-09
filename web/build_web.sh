#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/web/dist"

cd "$ROOT_DIR"

flutter build web --no-wasm-dry-run "$@"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R build/web/. "$DIST_DIR"

echo "Web build ready in: $DIST_DIR"
