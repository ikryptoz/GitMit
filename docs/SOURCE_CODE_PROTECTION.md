# Source Code Protection Guide

If your app is in a public Git repository, you cannot fully "hide" the code.
Anyone can clone/fork public repositories.

This guide focuses on realistic protection layers.

## 1. Decide Visibility Model

If code theft risk is unacceptable:
- move repository to private,
- grant least-privilege access,
- publish only binaries (APK/AAB/web build) and docs.

If repository stays public:
- assume all code is visible,
- rely on legal + branding + operational security controls.

## 2. Keep Secrets Out of Git

Never store in repository:
- keystore passwords,
- production API keys with broad privileges,
- service account private keys,
- backend admin credentials.

Use:
- CI secret vaults,
- runtime environment injection,
- restricted keys with scope limits.

## 3. Protect Intellectual Property

- Add explicit LICENSE terms matching your intent.
- Add trademark/brand policy for app name/logo use.
- Keep proprietary server-side logic on backend, not in client.

Note: client-side web code is always downloadable by browser users.

## 4. Raise Reverse-Engineering Cost

### Android
- enable minify/proguard for release,
- avoid debug logs in release,
- consider Dart obfuscation in release pipeline.

### Web
- serve production minified assets only,
- avoid embedding sensitive business logic solely in JS,
- move critical checks to authenticated backend APIs.

## 5. Anti-Abuse Controls

- enforce backend authorization checks on every sensitive action,
- rate-limit abusive endpoints,
- validate all client input server-side,
- monitor unusual traffic patterns.

## 6. Legal and Process Controls

- maintain contributor agreements where needed,
- document ownership of assets/code,
- create takedown process for unauthorized copies.

## 7. Practical Reality

No client application can be made impossible to copy.
Goal should be:
- protect secrets,
- protect backend authority,
- protect brand/IP,
- reduce abuse impact,
- detect and respond quickly.
