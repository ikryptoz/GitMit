# Architecture Overview

This document is intended for engineers who want to understand GitMit internals before making changes.

## System Shape

GitMit is a Flutter app with one large integration surface (`lib/dashboard.dart`) and supporting services/modules for crypto, storage, notifications, and platform adaptation.

High-level layers:
- Presentation/state orchestration: `lib/dashboard.dart`
- Crypto and key/session handling: `lib/e2ee.dart`
- Local persistence and cache support: `lib/isar_service.dart`, `lib/plaintext_cache.dart`
- Notification and background behavior: `lib/notifications_service.dart`
- Deep links and invite routing: `lib/deep_links.dart`, `lib/join_group_via_link_qr_page.dart`
- App bootstrap and wiring: `lib/main.dart`

## Runtime Domains

### 1) Chat Domain

Responsibilities:
- DM and group messaging flows
- typing, read state, reactions, attachments
- chat-specific navigation and split-pane behavior (web desktop)

Primary location:
- `lib/dashboard.dart` (`_ChatsTab` and related helpers)

### 2) Encryption Domain

Responsibilities:
- key generation and publication
- fingerprint generation and verification helper flows
- DM and group encryption/decryption paths
- key transfer/pairing import-export support

Primary location:
- `lib/e2ee.dart`

### 3) Session and Device Domain

Responsibilities:
- active device sessions
- web pairing state
- key resync triggers and continuity checks

Primary location:
- `lib/dashboard.dart` (settings/devices and pairing flows)

### 4) Web Shell Domain

Responsibilities:
- desktop split layout
- shell app bar actions sourced from active chat state
- startup/splash behavior in web entrypoint

Primary location:
- `lib/dashboard.dart`, `web/index.html`

## Data Flow (Conceptual)

1. User action triggers state update in UI layer.
2. UI layer calls encryption/storage/network helpers.
3. Encrypted payload is written to backend paths.
4. Other clients consume backend updates and decrypt locally.
5. Local cache/plaintext helpers optimize UX/search behavior.

## Change Strategy

When implementing a new feature:
1. Identify domain boundaries first (chat, crypto, session, web shell).
2. Keep backend write paths and data contracts explicit.
3. Preserve backward compatibility of encrypted message formats where possible.
4. Add user-visible fallback/error states for crypto/session edge cases.

## Risk Hotspots

- `lib/dashboard.dart` is large and stateful: small regressions can cascade.
- Multi-device key continuity and web pairing are sensitive to persistence issues.
- DM/group crypto paths require careful compatibility handling.

## Suggested Refactor Direction (Optional)

For long-term maintainability, consider extracting:
- chat view-model/state management from `_ChatsTab`
- pairing/session orchestration service
- app-shell action state adapter for desktop split mode
- dedicated module for message send/decrypt pipelines
