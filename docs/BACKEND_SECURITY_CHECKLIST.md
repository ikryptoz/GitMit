# Backend Security Checklist

Use this checklist to harden backend security around encrypted messaging.

## Authentication and Authorization

- [ ] Require authenticated identity for all private writes/reads.
- [ ] Enforce per-user and per-group authorization at rule level.
- [ ] Deny by default, allow only required paths/actions.
- [ ] Validate ownership fields server-side, not only in client.

## Input and Payload Validation

- [ ] Validate payload schema and size limits.
- [ ] Reject malformed/oversized encrypted blobs.
- [ ] Validate attachment metadata and allowed MIME types.
- [ ] Sanitize user-provided display fields.

## Abuse Protection

- [ ] Add per-user/per-IP rate limits where applicable.
- [ ] Detect suspicious write bursts and replay-like behavior.
- [ ] Add anti-automation controls for public endpoints.

## Secrets and Configuration

- [ ] Keep service credentials out of source control.
- [ ] Rotate secrets on schedule and after incidents.
- [ ] Separate dev/staging/prod credentials.

## Logging and Monitoring

- [ ] Log auth failures and permission denials.
- [ ] Avoid plaintext sensitive content in logs.
- [ ] Alert on unusual access patterns.
- [ ] Keep immutable security event logs when possible.

## Incident Readiness

- [ ] Define on-call escalation process.
- [ ] Maintain key/token rotation runbook.
- [ ] Test recovery drills at regular intervals.
