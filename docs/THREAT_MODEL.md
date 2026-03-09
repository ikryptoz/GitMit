# Threat Model

This document describes the security assumptions and attacker model for GitMit.

## Security Objectives

- Preserve confidentiality of message plaintext.
- Preserve integrity/authenticity of encrypted payloads.
- Reduce impact of backend compromise on message content.
- Limit account/session abuse through backend controls.

## In-Scope Adversaries

### A1: Passive network observer
Goal: read message content from intercepted traffic.
Mitigation: transport security + E2EE payload encryption.

### A2: Backend data observer
Goal: read plaintext from stored backend data.
Mitigation: backend stores ciphertext and routing metadata.

### A3: Unauthorized app user
Goal: access other users' data via client manipulation.
Mitigation: backend authz/rules and server-side validation.

### A4: Malicious fork/copycat
Goal: clone app, impersonate brand, abuse user trust.
Mitigation: trademark policy, package ID control, signing identity, legal process.

## Out-of-Scope / Hard Problems

- fully compromised endpoint devices,
- physical attacks on unlocked devices,
- social engineering and phishing,
- full prevention of source copying when repository is public.

## Trust Assumptions

- Client cryptographic implementation behaves correctly.
- Secure storage on device is reasonably protected by OS.
- Backend auth/rules are correctly configured and reviewed.
- Build/signing keys are not leaked.

## Mitigation Matrix

| Threat | Primary Mitigation | Residual Risk |
|---|---|---|
| Network interception | E2EE + TLS | endpoint compromise |
| Backend data disclosure | ciphertext at rest | metadata visibility |
| Session abuse | authz rules + logging | credential theft |
| Copycat app distribution | package signing + trademark policy | store-side lag in enforcement |

## Verification Actions

- perform independent crypto review,
- perform backend rules test suite,
- rotate leaked secrets quickly,
- monitor suspicious authentication and write patterns.
