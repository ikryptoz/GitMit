# Release Security Checklist

Use this checklist before publishing Android/Web releases.

## Pre-Release

- [ ] Verify no secrets are committed in git.
- [ ] Verify keystore credentials are loaded from secure local/CI secrets.
- [ ] Run dependency review for critical vulnerabilities.
- [ ] Confirm build reproducibility from clean environment.

## Android

- [ ] Build signed release AAB.
- [ ] Ensure release signing key is not in repository.
- [ ] Ensure minify/shrink is enabled for release build.
- [ ] Verify package name and signing identity match official release track.

## Web

- [ ] Build production web artifacts only.
- [ ] Verify no debug endpoints/tokens are embedded.
- [ ] Validate cache and compression settings on web server.
- [ ] Validate startup UX (no blank white-screen regressions).

## Verification

- [ ] Smoke test critical chat/encryption flows.
- [ ] Validate fingerprint and key continuity behavior.
- [ ] Validate login/logout/session handling.
- [ ] Validate privacy/security docs links in README.

## Post-Release

- [ ] Monitor error spikes and auth anomalies.
- [ ] Monitor reports for encryption/pairing failures.
- [ ] Document release hash/version and rollback path.
