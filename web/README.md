# GitMit Web (Separated Delivery)

This folder contains the dedicated web shell and delivery workflow for GitMit.
The web app uses the same Flutter/Dart codebase as mobile, including E2EE logic.

## Web Interface Mode

- Wide web screens (`>= 1000px`): desktop web shell with left navigation.
- Narrow web screens (`< 1000px`): mobile-like shell with bottom navigation.
- Chat, DM, group, E2EE, notifications, and settings use the same app logic as mobile.

## What Is Shared

- UI and app logic: `lib/**`
- E2EE implementation: `lib/e2ee.dart`
- Firebase config: `lib/firebase_options.dart`

## What Is Web-Specific

- Web host page: `web/index.html`
- FCM service worker: `web/firebase-messaging-sw.js`
- Static JS helpers: `web/js/**`
- Build output target for deployment: `web/dist/`

## Local Run (Web)

```bash
flutter run -d chrome
```

If you use web push notifications, pass VAPID key:

```bash
flutter run -d chrome --dart-define=GITMIT_WEB_PUSH_VAPID_KEY=YOUR_VAPID_PUBLIC_KEY
```

## Build Separated Web Output

Use the script below. It builds Flutter web and copies output into `web/dist`.

```bash
./web/build_web.sh
```

Optional with VAPID key:

```bash
./web/build_web.sh --dart-define=GITMIT_WEB_PUSH_VAPID_KEY=YOUR_VAPID_PUBLIC_KEY
```

After build, deploy the `web/dist` directory to your web hosting.
