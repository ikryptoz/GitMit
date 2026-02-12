# GitMit Firebase Functions

HTTP function for online presence push notifications.

## Deploy

1. Install Firebase CLI (once):
```bash
npm i -g firebase-tools
```

2. Login:
```bash
firebase login
```

3. Install function deps:
```bash
cd functions
npm install
cd ..
```

4. Set secret API key used by the mobile app header `x-api-key`:
```bash
firebase functions:secrets:set BACKEND_API_KEY
```

5. Deploy:
```bash
firebase deploy --only functions
```

## Function URL

After deploy, endpoint URL is:

`https://us-central1-githubmessenger-7d2c6.cloudfunctions.net/notifyOnlinePresence`

## Flutter app

The app already uses this URL as default in `lib/notifications_service.dart`.

Optional override for local/testing:
```bash
flutter run --dart-define=GITMIT_NOTIFY_BACKEND_URL=https://your-url --dart-define=GITMIT_NOTIFY_BACKEND_TOKEN=your-secret
```
