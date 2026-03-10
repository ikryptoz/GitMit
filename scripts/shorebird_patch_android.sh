#!/usr/bin/env bash
set -euo pipefail

# Publishes a Dart-only Shorebird patch for an existing Android release.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v shorebird >/dev/null 2>&1; then
  echo "shorebird CLI not found. Install it first." >&2
  exit 1
fi

if [[ -z "${SHOREBIRD_TOKEN:-}" ]]; then
  echo "SHOREBIRD_TOKEN is missing." >&2
  echo "Run: export SHOREBIRD_TOKEN=..." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/shorebird_patch_android.sh <release-version> [extra shorebird args...]" >&2
  echo "Example: scripts/shorebird_patch_android.sh 1.2.3+45" >&2
  exit 1
fi

RELEASE_VERSION="$1"
shift

shorebird patch android --release-version "$RELEASE_VERSION" "$@"
