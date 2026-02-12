const express = require('express');
const bodyParser = require('body-parser');
const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// Path to your service account JSON
const serviceAccountPath = path.join(__dirname, 'serviceAccountKey.json');
if (!fs.existsSync(serviceAccountPath)) {
  console.error('Missing serviceAccountKey.json. Please copy your Firebase service account JSON here.');
  process.exit(1);
}

const serviceAccount = require(serviceAccountPath);
const projectId = serviceAccount.project_id;
const databaseURL = process.env.FIREBASE_DATABASE_URL || `https://${projectId}-default-rtdb.firebaseio.com`;

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL,
});

const app = express();
app.use(bodyParser.json());

function requireApiKey(req, res, next) {
  const expected = (process.env.BACKEND_API_KEY || '').trim();
  if (!expected) return next();
  const provided = (req.header('x-api-key') || '').trim();
  if (provided && provided === expected) return next();
  return res.status(401).json({ error: 'Unauthorized' });
}

// POST /send-fcm
// Body: { "token": "...", "title": "...", "body": "...", "data": { ... } }
app.post('/send-fcm', async (req, res) => {
  const { token, title, body, data } = req.body;
  if (!token || !title || !body) {
    return res.status(400).json({ error: 'token, title, and body are required' });
  }
  const message = {
    token,
    notification: { title, body },
    data: data || {},
  };
  try {
    const response = await admin.messaging().send(message);
    res.json({ success: true, response });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /notify-online
// Body: { "toUid": "...", "fromUid": "...", "fromLogin": "..." }
app.post('/notify-online', requireApiKey, async (req, res) => {
  const { toUid, fromUid, fromLogin } = req.body || {};
  if (!toUid || !fromUid || !fromLogin) {
    return res.status(400).json({ error: 'toUid, fromUid and fromLogin are required' });
  }

  try {
    const snap = await admin.database().ref(`fcmTokens/${toUid}`).get();
    const value = snap.val();
    if (!value || typeof value !== 'object') {
      return res.json({ success: true, sent: 0, reason: 'No tokens' });
    }

    const tokens = Object.values(value)
      .map((item) => (item && typeof item === 'object' ? String(item.token || '') : ''))
      .filter((token) => token.length > 0);

    if (!tokens.length) {
      return res.json({ success: true, sent: 0, reason: 'No tokens' });
    }

    const multicastMessage = {
      tokens,
      notification: {
        title: 'GitMit',
        body: `@${fromLogin} je online`,
      },
      data: {
        type: 'online_presence',
        fromUid: String(fromUid),
        fromLogin: String(fromLogin),
      },
      android: { priority: 'high' },
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { sound: 'default' } },
      },
    };

    const result = await admin.messaging().sendEachForMulticast(multicastMessage);
    return res.json({
      success: true,
      sent: result.successCount,
      failed: result.failureCount,
    });
  } catch (err) {
    return res.status(500).json({ error: err.message || 'Internal server error' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`FCM backend listening on port ${PORT}`);
});
