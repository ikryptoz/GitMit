#!/usr/bin/env bash
set -euo pipefail

# One-command launcher for API 23 devices where `flutter run` is blocked by Flutter tool checks.

DEVICE_ID="${1:-LGH8407881928b}"
APK_PATH="${2:-build/app/outputs/flutter-apk/app-release.apk}"
PACKAGE_NAME="com.nothix.gitmit"

if [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
  ADB="${ANDROID_HOME}/platform-tools/adb"
elif [[ -n "${ANDROID_SDK_ROOT:-}" && -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]]; then
  ADB="${ANDROID_SDK_ROOT}/platform-tools/adb"
elif [[ -x "${HOME}/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="${HOME}/Library/Android/sdk/platform-tools/adb"
elif command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
else
  echo "[ERROR] adb not found. Install Android SDK platform-tools or set ANDROID_HOME/ANDROID_SDK_ROOT." >&2
  exit 1
fi

ensure_compatible_apk() {
  local needs_build="false"
  if [[ ! -f "${APK_PATH}" ]]; then
    needs_build="true"
  else
    # LG H840 is ARM32; ensure Flutter engine and app libs exist for armeabi-v7a.
    if ! unzip -l "${APK_PATH}" | grep -q "lib/armeabi-v7a/libflutter.so"; then
      needs_build="true"
    fi
    if ! unzip -l "${APK_PATH}" | grep -q "lib/armeabi-v7a/libapp.so"; then
      needs_build="true"
    fi
  fi

  if [[ "${needs_build}" == "true" ]]; then
    echo "[INFO] Building release APK for android-arm + android-arm64 compatibility..."
    flutter build apk --release --target-platform android-arm,android-arm64
  fi
}

ensure_compatible_apk

echo "[INFO] Using adb: ${ADB}"
echo "[INFO] Target device: ${DEVICE_ID}"

"${ADB}" start-server >/dev/null

if ! "${ADB}" devices | awk 'NR>1 {print $1}' | grep -qx "${DEVICE_ID}"; then
  echo "[ERROR] Device ${DEVICE_ID} is not connected." >&2
  echo "[INFO] Connected devices:" >&2
  "${ADB}" devices -l >&2
  exit 1
fi

echo "[INFO] Installing ${APK_PATH}..."
"${ADB}" -s "${DEVICE_ID}" install -r "${APK_PATH}"

echo "[INFO] Launching ${PACKAGE_NAME}..."
"${ADB}" -s "${DEVICE_ID}" shell monkey -p "${PACKAGE_NAME}" -c android.intent.category.LAUNCHER 1 >/dev/null

echo "[OK] App installed and launch intent sent."
