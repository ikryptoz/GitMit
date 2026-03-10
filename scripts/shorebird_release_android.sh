#!/usr/bin/env bash
set -euo pipefail

# Creates a new Shorebird Android release line from current code.

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

if [[ -z "${KEYSTORE_PASSWORD:-}" || -z "${KEY_ALIAS:-}" || -z "${KEY_PASSWORD:-}" ]]; then
  echo "Android signing env vars are missing." >&2
  echo "Required: KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD" >&2
  exit 1
fi

if [[ ! -f "android/app/keystore/release.keystore" ]]; then
  echo "Missing keystore file: android/app/keystore/release.keystore" >&2
  exit 1
fi

shorebird release android --artifact aab --flutter-version=stable "$@"
