# Key Management and Device Pairing

This document explains key lifecycle and multi-device continuity.

## Key Lifecycle

1. Key generation on trusted client device.
2. Public key publication for peers.
3. Session establishment per chat context.
4. Local persistence of key/session state.
5. Rotation/recovery flows when device state changes.

## Fingerprint Verification

Users should verify fingerprints out-of-band for sensitive conversations.
Unexpected fingerprint changes should be treated as a warning signal.

## Device Pairing

Pairing flow is used to transfer key material from trusted primary device to a secondary device.

Expected secure behavior:
- explicit user action to initiate transfer,
- short-lived pairing token,
- success/failure confirmation on both devices,
- local key replacement where required for identity continuity.

## Web Session Notes

Web clients must persist key state locally to avoid decryption drift.
If web key state is lost/reset, re-pairing or key restore is required.

## Recovery and Resync

If decrypt mismatch appears:
1. compare local and expected fingerprints,
2. trigger controlled key restore/pairing flow,
3. reopen affected threads after import.

## Operational Risks

- user imports keys on untrusted/shared machine,
- stale sessions after reinstall,
- local cache retention on shared browsers.

## Recommendations

- pair only on trusted devices,
- prefer full logout on public/shared computers,
- add periodic key-state integrity checks,
- document user-visible remediation steps clearly.
