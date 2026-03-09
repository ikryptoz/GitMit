# Security Model

This document describes the practical security posture of GitMit.

## Security Goals

- Protect message plaintext in transit and at rest on backend.
- Keep private keys and session state on client devices.
- Provide fingerprint verification for identity checks.
- Minimize secret exposure in source code and CI.

## Trust Boundaries

Client devices are trusted to:
- generate/store keys,
- encrypt before upload,
- decrypt after download.

Backend is trusted to:
- route/store encrypted payloads,
- enforce auth and access control,
- not require plaintext for normal operations.

## Data Classification

### Sensitive
- private keys,
- session state,
- decrypted message cache,
- access tokens/credentials.

### Internal
- user IDs/logins,
- chat IDs/group IDs,
- timestamps and delivery metadata.

### Public
- open-source source code (if repository is public),
- published documentation and release notes.

## Known Limits

- Public web deployments expose client-side code by definition.
- Public repositories can always be cloned/forked.
- Obfuscation raises reverse-engineering cost but is not full protection.

## Hardening Checklist

### Repository and Access
- Keep production repository private if source theft is a concern.
- Enable branch protection and required reviews.
- Enable 2FA for all maintainers.
- Remove old secrets from git history if leaked.

### Secrets Management
- Never commit API keys, private keys, keystore passwords.
- Use environment/CI secrets and per-environment config.
- Rotate credentials after any potential exposure.

### Build and Release
- Use signed release builds only.
- Use Android code shrinking/minification for release.
- Consider Dart obfuscation for release artifacts.
- Store signing keys outside repository.

### Runtime
- Enforce auth for all backend writes/reads.
- Keep dependencies patched.
- Audit logs for abnormal behavior.

## Incident Response

If compromise is suspected:
1. rotate credentials and signing keys where possible,
2. revoke compromised sessions/tokens,
3. communicate issue and user impact transparently,
4. publish remediation timeline and follow-up changes.

## Audit Recommendation

For high-assurance environments, schedule independent audits:
- cryptographic flow review,
- backend rules/auth review,
- mobile/web storage and session handling review,
- supply-chain/dependency assessment.
