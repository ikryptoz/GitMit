# Shorebird Update Pipeline (Android)

This guide configures GitMit for fast Dart-only updates delivered outside normal Play review cycles.

## What Shorebird Solves

- Push Dart code patches quickly to installed app versions.
- Users receive updates on next app startup (or shortly after) without reinstall.
- Session/login state remains intact.

## What Shorebird Does Not Solve

- Native/plugin/Gradle/manifest changes still require a Play release.
- It does not bypass Google Play security model or app signing requirements.
- First install still comes from Play Store.

## Prerequisites

- Shorebird account and project configured.
- Play-distributed app with stable signing identity.
- Android signing data available in CI secrets.

## Local Setup

1. Install Shorebird CLI.
2. Login:
   - `shorebird login`
3. Initialize project once:
   - `shorebird init`

## Release and Patch Commands

- Base release (new Android release line):
  - `shorebird release android --artifact aab --flutter-version=stable`
- Patch existing release (Dart-only changes):
  - `shorebird patch android --release-version <x.y.z+build>`

## CI Strategy in This Repo

Two manual workflows are provided:
- `.github/workflows/shorebird-release-android.yml`
- `.github/workflows/shorebird-patch-android.yml`

Required repo secrets:
- `SHOREBIRD_TOKEN`
- `GITMIT_KEYSTORE_FILE_BASE64`
- `GITMIT_KEYSTORE_PASSWORD`
- `GITMIT_KEY_ALIAS`
- `GITMIT_KEY_PASSWORD`

The workflow decodes keystore into:
- `android/app/keystore/release.keystore`

And exports env vars expected by Android signing config.

## Safe Usage Policy

Use `shorebird patch` only when changes are Dart-only.
If any native layer changed, publish a normal Play release first.

## Verification After Patch

- install latest Play build on test device,
- push patch,
- relaunch app and verify patched behavior,
- verify auth/session continuity and critical chat flows.
