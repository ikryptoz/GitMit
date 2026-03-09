#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "[secret-check] scanning tracked files for obvious committed secrets"

# Fail if forbidden sensitive files are tracked.
forbidden_files=(
  "android/key.properties"
)

for f in "${forbidden_files[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "[secret-check] forbidden tracked file detected: $f"
    exit 1
  fi
done

# Fail if tracked keystore/key material files exist.
if git ls-files | grep -E '(^|/)android/app/keystore/.*\.(jks|keystore)$' >/dev/null; then
  echo "[secret-check] tracked keystore file detected under android/app/keystore"
  exit 1
fi

# Check for hardcoded secret-like assignments in code/config (skip docs/examples).
scan_patterns=(
  'storePassword\s*=\s*"[^"]+"'
  'keyPassword\s*=\s*"[^"]+"'
  'api[_-]?key\s*[:=]\s*"[^"]{12,}"'
  'secret\s*[:=]\s*"[^"]{12,}"'
  'token\s*[:=]\s*"[^"]{20,}"'
)

tracked_candidates=$(git ls-files | grep -E '\.(kts|gradle|properties|yaml|yml|json|dart|js|ts|env)$' || true)

if [[ -n "$tracked_candidates" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      *.md|*.example|docs/*|dokumentace/*|android/app/google-services.json|ios/Runner/GoogleService-Info.plist|lib/firebase_options.dart)
        continue
        ;;
    esac

    for pattern in "${scan_patterns[@]}"; do
      if grep -EIn "$pattern" "$file" >/dev/null 2>&1; then
        echo "[secret-check] possible hardcoded secret in $file (pattern: $pattern)"
        grep -EIn "$pattern" "$file" | head -n 3 || true
        exit 1
      fi
    done
  done <<< "$tracked_candidates"
fi

echo "[secret-check] passed"
