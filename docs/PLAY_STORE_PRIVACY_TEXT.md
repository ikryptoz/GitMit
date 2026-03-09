# Play Store Privacy/Security Text Templates

Use these as a starting point for Play Console forms.
Review with your legal/privacy owner before publishing.

## 1) Data Safety - Short Description

GitMit uses end-to-end encryption for message content. Message plaintext is intended to be encrypted on user devices before backend storage. Some operational metadata (such as sender/recipient identifiers and timestamps) is processed to enable message routing and synchronization.

## 2) Data Safety - Security Practices

- Data is encrypted in transit.
- Message content is encrypted end-to-end in app flows designed for E2EE.
- Access controls are enforced on backend resources.
- Security-sensitive issues can be reported via the project security policy.

## 3) Data Safety - Data Collected (Template)

Adjust this section to your exact implementation.

- Personal info: account identifiers (for login and routing)
- Messages: encrypted content payloads and operational metadata
- App activity: limited diagnostics/security logs (if enabled)
- Device/session info: used for session management and multi-device continuity

## 4) Data Safety - Purpose of Collection (Template)

- App functionality (messaging, account, synchronization)
- Security and fraud prevention
- Troubleshooting and service reliability

## 5) Data Safety - Data Deletion (Template)

Users can request account/session data deletion according to project policy and backend capabilities. Deletion behavior for message metadata and encrypted payload retention follows documented backend retention settings.

## 6) App Content - User Generated Content (Template)

GitMit includes user-generated messaging content. The app provides account controls and moderation/reporting pathways according to project policies.

## 7) App Content - Security Commitment (Store Listing Snippet)

GitMit is built with privacy-first messaging principles. Message content is designed to be end-to-end encrypted, and fingerprint verification is available for identity checks in sensitive conversations.

## 8) Privacy Policy Snippet (Public Page)

GitMit processes only the data required to provide messaging functionality and security. Message content is intended to remain encrypted in storage and transit paths supporting E2EE. Operational metadata is processed for delivery and synchronization.

## 9) Important Notes Before Submission

- Do not claim absolute anonymity or zero metadata if metadata exists.
- Do not claim perfect security.
- Keep statements aligned with real implementation and audits.
- Re-check Data Safety after any architectural change.
