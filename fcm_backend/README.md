# FCM Backend for GitMit

This is a simple Node.js Express backend to send Firebase Cloud Messaging (FCM) push notifications using your Firebase service account.

## Setup

1. **Copy your service account JSON**
   - Rename your downloaded service account file to `serviceAccountKey.json`.
   - Place it in this folder (`fcm_backend`).

2. **Install dependencies**
   ```sh
   npm install
   ```

3. **Run the server**
   ```sh
   npm start
   ```
   The server will run on port 3000 by default.

### Optional environment variables

- `FIREBASE_DATABASE_URL` (if your RTDB URL differs from default)
- `BACKEND_API_KEY` (recommended in production)

Example:
```sh
BACKEND_API_KEY=super-secret npm start
```

## Usage

POST to `/send-fcm` with JSON body:
```
{
  "token": "<fcm_device_token>",
  "title": "<notification_title>",
  "body": "<notification_body>",
  "data": { "key": "value" } // optional
}
```

POST to `/notify-online` with JSON body:
```json
{
  "toUid": "recipient_uid",
  "fromUid": "sender_uid",
  "fromLogin": "sender_login"
}
```

If `BACKEND_API_KEY` is set, add header:
```text
x-api-key: <your_api_key>
```

Example with curl:
```
curl -X POST http://localhost:3000/send-fcm \
  -H "Content-Type: application/json" \
  -d '{
    "token": "YOUR_FCM_TOKEN",
    "title": "User is online!",
    "body": "Your DM contact is now online.",
    "data": { "userId": "abc123" }
  }'
```

## Security
- Never expose your service account JSON to the client or public.
- Protect this endpoint (e.g., with authentication) in production.

---

**For integration with your Flutter app:**
- Configure app with `--dart-define`:
  ```sh
  flutter run \
    --dart-define=GITMIT_NOTIFY_BACKEND_URL=https://your-backend.example.com \
    --dart-define=GITMIT_NOTIFY_BACKEND_TOKEN=super-secret
  ```
- The app calls `/notify-online` when a user goes online.
