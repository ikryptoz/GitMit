# Codebase Map

A practical map for contributors who want to navigate quickly.

## Start Here

- Entry point: `lib/main.dart`
- Main app shell and tabs: `lib/dashboard.dart`
- Crypto core: `lib/e2ee.dart`

## Feature-to-File Mapping

### Authentication and User Session
- App bootstrap/auth context: `lib/main.dart`, `lib/dashboard.dart`

### Direct Messages and Groups
- Chat UI, send/decrypt, call integration: `lib/dashboard.dart`
- Message local cache support: `lib/plaintext_cache.dart`

### E2EE and Fingerprints
- Key management, encrypt/decrypt helpers: `lib/e2ee.dart`
- Security docs and threat model references: `docs/*.md`

### Device Pairing and Key Sync
- Pairing QR flows, transfer status, import logic: `lib/dashboard.dart`
- Web key persistence shim: `lib/flutter_secure_storage_stub.dart`

### Notifications
- Notification setup and handling: `lib/notifications_service.dart`
- Backend helper endpoints: `functions/`, `fcm_backend/`

### Web
- HTML shell and startup behavior: `web/index.html`
- Public security page: `web/security/index.html`

### Android Release and Signing
- Android Gradle config: `android/app/build.gradle.kts`
- Local signing template: `android/key.properties.example`

## Docs to Read Before Editing

- Security policy: `SECURITY.md`
- Architecture: `docs/ARCHITECTURE_OVERVIEW.md`
- Encryption model: `docs/ENCRYPTION_ARCHITECTURE.md`
- Threat model: `docs/THREAT_MODEL.md`
- Contribution workflow: `CONTRIBUTING.md`

## Typical Change Paths

### Add a new chat capability
1. Update chat state/handlers in `lib/dashboard.dart`
2. If payload changes, validate crypto compatibility in `lib/e2ee.dart`
3. Update docs if security/privacy implications change

### Add security/privacy documentation
1. Add/modify files in `docs/`
2. Link from `README.md`
3. If user-facing, mirror on `web/security/index.html`

### Harden release process
1. Update signing and release scripts/configs
2. Validate CI secret checks
3. Build release artifacts and verify output paths
