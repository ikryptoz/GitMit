# Encryption Architecture

This document explains how GitMit encryption is designed and what guarantees it provides.

## Scope

GitMit uses end-to-end encryption (E2EE) for message content. The intent is:
- only chat participants can decrypt message plaintext,
- backend stores ciphertext and metadata required for message delivery,
- local device state maintains keys/sessions needed for decryption.

## Cryptographic Components

GitMit code references the following primitives and flows:
- identity/signing keys: Ed25519 fingerprints for identity checks,
- key agreement: X25519-based peer key establishment,
- message encryption: ChaCha20-Poly1305 style authenticated encryption,
- direct messages (DM): signal-like ratchet/session handling,
- groups: group key/sender-key style encrypted payloads depending on capability.

## Key Material

Key material is device-scoped and stored locally.

Important behaviors in current implementation:
- fingerprint display allows out-of-band verification,
- key transfer between devices can be initiated through pairing flows,
- key import flows can replace local keys to align web and mobile identity state.

## Message Flow (High Level)

1. Sender prepares plaintext.
2. Sender encrypts for peer (DM) or group key context (group chat).
3. Encrypted payload (ciphertext + crypto metadata) is stored in backend.
4. Recipient device fetches payload and decrypts locally.
5. Plaintext may be cached locally for UX/search.

## Fingerprints and Verification

Fingerprints are used for anti-MITM checks. Recommended user flow:
1. open chat fingerprint screen,
2. verify fingerprint with peer out-of-band (in person / trusted channel),
3. if fingerprint changes unexpectedly, treat as security event.

## What E2EE Protects

E2EE is intended to protect:
- message body content,
- attachments/embedded payload content when encrypted path is used,
- confidentiality against backend plaintext access.

## What E2EE Does Not Fully Hide

Like most messaging systems, some metadata is still visible to infrastructure:
- sender/recipient identifiers required for routing,
- message timestamps,
- delivery/read state signals,
- group membership and basic chat topology.

## Threat Model Summary

GitMit primarily addresses:
- backend plaintext disclosure risk,
- passive interception of stored message content,
- accidental plaintext leakage through server storage.

It does not claim to fully defeat:
- compromised endpoints,
- malware/keyloggers on user devices,
- social engineering against users,
- legal/physical access to unlocked devices.

## Web Pairing and Multi-Device Notes

Web clients require secure local persistence of key material.
Pairing and restore flows should ensure key continuity across devices.
If fingerprints diverge, key resync is required to avoid decryption drift.

## Operational Best Practices

- Verify peer fingerprints for sensitive conversations.
- Use device lock + OS encryption on all endpoints.
- Keep app versions updated.
- Treat unexpected fingerprint changes as a warning.
- Avoid sharing unlocked sessions on shared computers.

## Security Transparency

No messaging app can honestly promise "perfect" security.
GitMit aims for strong practical protection and transparent limitations.
If your use case requires formal assurance, run an external security audit.
