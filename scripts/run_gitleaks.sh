#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

BASELINE_FILE=".gitleaks.baseline.json"
CONFIG_FILE=".gitleaks.toml"

if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "[]" > "$BASELINE_FILE"
fi

echo "[gitleaks] running scan with config and baseline"
gitleaks detect \
  --source . \
  --config "$CONFIG_FILE" \
  --baseline-path "$BASELINE_FILE" \
  --redact \
  --no-banner

echo "[gitleaks] passed"
