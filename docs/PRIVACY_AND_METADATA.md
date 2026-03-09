# Privacy and Metadata

E2EE protects message content, but metadata still exists for system operation.

## Metadata Commonly Required

- sender/recipient identifiers,
- group membership references,
- message timestamps,
- delivery/read status,
- device/session bookkeeping.

## Why Metadata Exists

Messaging systems need routing and synchronization data.
Without minimal metadata, real-time delivery and multi-device consistency are not possible.

## Privacy Strategy

- minimize stored metadata fields,
- avoid storing plaintext content server-side,
- avoid logging sensitive payloads,
- apply retention windows where feasible,
- anonymize aggregate telemetry where possible.

## User Transparency

Privacy docs should clearly separate:
- encrypted content (protected),
- operational metadata (partially visible to infrastructure).

## Data Retention Guidance

- keep only metadata required for functionality,
- define retention limits for operational logs,
- document deletion behavior for users and admins,
- provide clear account/data removal process.

## Practical User Advice

- use unique strong credentials,
- secure devices with PIN/biometric lock,
- avoid shared sessions on untrusted machines,
- verify fingerprints for high-risk conversations.
