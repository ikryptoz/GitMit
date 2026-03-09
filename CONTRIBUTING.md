# Contributing to GitMit

Thanks for contributing. This project is security-sensitive, so please follow the flow below.

## Contribution Principles

- Prefer clear, reviewable changes over large opaque rewrites.
- Keep security and privacy impact explicit in every feature change.
- Do not introduce secrets into repository history.
- Preserve backward compatibility for chat/encryption data contracts when possible.

## Before You Start

Read these first:
- `README.md`
- `docs/ARCHITECTURE_OVERVIEW.md`
- `docs/CODEBASE_MAP.md`
- `docs/ENCRYPTION_ARCHITECTURE.md`
- `SECURITY.md`

## Development Flow

1. Create a branch from `main`.
2. Implement focused changes.
3. Run local checks:
   - `dart analyze`
   - `flutter test` (where available)
   - `bash scripts/check_no_secrets.sh`
4. Update docs if behavior or security model changed.
5. Open PR with clear summary and risk notes.

## PR Template (Recommended)

Use this structure in PR description:

- What changed
- Why it changed
- Security/privacy impact
- Backward compatibility impact
- Testing done
- Follow-up tasks

## Security-Sensitive Areas

Take extra care when touching:
- `lib/e2ee.dart`
- message send/decrypt paths in `lib/dashboard.dart`
- device pairing and key import flows
- Android signing and CI secret tooling

## Secret Handling Rules

Never commit:
- `android/key.properties`
- keystore files (`.jks`, `.keystore`)
- private tokens/passwords

Use:
- environment variables
- local untracked config files
- CI secrets

## Commit Guidance

- Keep commits small and thematic.
- Prefer descriptive commit messages.
- Include docs update in same PR when relevant.

## Reporting Security Issues

Do not open public issues for vulnerabilities first.
Follow `SECURITY.md` responsible disclosure process.
