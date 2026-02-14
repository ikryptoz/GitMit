# GitMit Firebase Functions

HTTP function for:
- online presence push notifications (FCM)
- GitHub invite notifications for users not registered in GitMit

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

4. Set secret API key used by the mobile app (`x-api-key` or `Authorization: Bearer`):
```bash
firebase functions:secrets:set BACKEND_API_KEY
```

5. Set GitHub token secret (must have permission to create issue comments in target repo):
```bash
firebase functions:secrets:set GITHUB_NOTIFY_TOKEN
```

6. Set runtime env vars for GitHub invite mention mode in your Function environment:
- `GITMIT_GITHUB_NOTIFY_REPO` (e.g. `myorg/gitmit-notify`)
- `GITMIT_GITHUB_NOTIFY_ISSUE_NUMBER` (single issue used as notification thread)
- `GITMIT_APP_URL` (optional download URL included in message)

7. Deploy:
```bash
firebase deploy --only functions
```

## Function URL

After deploy, endpoint URL is:

`https://us-central1-githubmessenger-7d2c6.cloudfunctions.net/notifyOnlinePresence`

The same endpoint supports two payload modes:

1) Online presence (FCM)
```json
{
	"toUid": "firebaseUid",
	"fromUid": "firebaseUid",
	"fromLogin": "githubLogin"
}
```

2) GitHub invite mention (non-GitMit user)
```json
{
	"targetLogin": "targetGithubUser",
	"fromLogin": "senderGithubUser",
	"preview": "Message from GitMit app ..."
}
```

## Flutter app

The app already uses this URL as default in `lib/notifications_service.dart`.

Optional override for local/testing:
```bash
flutter run --dart-define=GITMIT_NOTIFY_BACKEND_URL=https://your-url --dart-define=GITMIT_NOTIFY_BACKEND_TOKEN=your-secret
```
