# GitMit

GitMit is a Flutter messaging platform with end-to-end encryption (E2EE) focused on practical privacy, transparent security behavior, and multi-device usage.

## Repository Purpose

This repository is intentionally structured for:
- understanding how the system works,
- reviewing security/privacy design decisions,
- contributing new features safely.

It is not just a "download and run" project page. The primary goal is transparent engineering and contributor onboarding.

## Study Path (Recommended)

If you are new and want to understand internals first, read in this order:
1. `docs/ARCHITECTURE_OVERVIEW.md`
2. `docs/CODEBASE_MAP.md`
3. `docs/ENCRYPTION_ARCHITECTURE.md`
4. `docs/THREAT_MODEL.md`
5. `CONTRIBUTING.md`

## Documentation Index

- Public security page: `/security` on web deployment (for example `https://app.gitmit.eu/security`).
- `docs/ARCHITECTURE_OVERVIEW.md`: high-level system architecture and change strategy.
- `docs/CODEBASE_MAP.md`: practical map of features to files.
- `CONTRIBUTING.md`: contribution process and security expectations.
- `docs/ENCRYPTION_ARCHITECTURE.md`: how encryption works, what it protects, and what it does not.
- `docs/SECURITY_MODEL.md`: trust boundaries, threat model, and operational hardening.
- `docs/SOURCE_CODE_PROTECTION.md`: realistic source protection strategy for public/private repos.
- `docs/THREAT_MODEL.md`: attacker profiles, assumptions, and mitigation matrix.
- `docs/KEY_MANAGEMENT_AND_PAIRING.md`: key lifecycle, device pairing, and multi-device continuity.
- `docs/PRIVACY_AND_METADATA.md`: what metadata exists, retention concerns, and minimization strategy.
- `docs/BACKEND_SECURITY_CHECKLIST.md`: backend authorization and rule-hardening checklist.
- `docs/RELEASE_SECURITY_CHECKLIST.md`: secure release process for Android/Web.
- `docs/SECURITY_FAQ.md`: concise answers for users asking about privacy and encryption.
- `docs/PLAY_STORE_PRIVACY_TEXT.md`: ready-to-adapt text snippets for Play Console forms.
- `SECURITY.md`: vulnerability reporting policy.
- `TRADEMARK_POLICY.md`: branding and logo usage rules.
- `docs/cs/README.md`: Czech translations of security/privacy docs.

## CI Security Guard

This repository includes a CI workflow that fails builds when obvious committed secrets are detected:
- workflow: `.github/workflows/security-secrets-scan.yml`
- checker script: `scripts/check_no_secrets.sh`
- gitleaks gate with baseline/config: `scripts/run_gitleaks.sh`, `.gitleaks.toml`, `.gitleaks.baseline.json`

## Security Statement

GitMit aims to provide strong practical protection for message content.

Important transparency note:
- no client app can claim "perfect" security,
- no public repository can be made impossible to copy,
- no web client code can be fully hidden from end users.

Security is achieved through layered controls: cryptography, backend authorization, secrets management, release hardening, and incident response.

## Contributing New Features

For feature work and refactors:
1. follow `CONTRIBUTING.md`,
2. map changes via `docs/CODEBASE_MAP.md`,
3. update docs for any behavior/security impact.

Local validation before PR:
- `dart analyze`
- `flutter test` (where relevant)
- `bash scripts/check_no_secrets.sh`

## Android Release Artifacts

```bash
# APK
flutter build apk

# AAB (Play Console)
flutter build appbundle || (cd android && ./gradlew bundleRelease)
```

Typical outputs:
- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`

## Security Best Practices for This Project

- Keep production credentials and signing secrets out of git.
- Use private repository mode if source-code theft is a concern.
- Keep critical trust/authorization checks on backend, not in client.
- Verify E2EE fingerprints out of band for sensitive conversations.
- Rotate keys/tokens immediately after suspected exposure.

## About "Hiding" an App

If the repo is public, source code can always be cloned.
If the app runs in browser, client code can always be downloaded.

What you can do:
- move repository to private,
- protect secrets and release keys,
- keep sensitive business logic on backend,
- enforce legal/IP policy and brand controls,
- use release hardening (minify/obfuscate) to increase reverse-engineering effort.

See `docs/SOURCE_CODE_PROTECTION.md` for an implementation checklist.

## Responsible Disclosure

Please report vulnerabilities privately according to `SECURITY.md`.

## Optional Local Run

```bash
git clone https://github.com/ikryptoz/GitMit.git
cd GitMit
flutter pub get
flutter run
```
