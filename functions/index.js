const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');

admin.initializeApp();

const backendApiKey = defineSecret('BACKEND_API_KEY');

exports.notifyOnlinePresence = onRequest(
  {
    region: 'us-central1',
    secrets: [backendApiKey],
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'Method Not Allowed' });
    }

    const expected = backendApiKey.value();
    if (expected && expected.trim().length > 0) {
      const provided = String(req.get('x-api-key') || '').trim();
      if (provided !== expected.trim()) {
        return res.status(401).json({ error: 'Unauthorized' });
      }
    }

    const toUid = String(req.body?.toUid || '').trim();
    const fromUid = String(req.body?.fromUid || '').trim();
    const fromLogin = String(req.body?.fromLogin || '').trim();

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

      const result = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: 'GitMit',
          body: `@${fromLogin} je online`,
        },
        data: {
          type: 'online_presence',
          fromUid,
          fromLogin,
        },
        android: { priority: 'high' },
        apns: {
          headers: { 'apns-priority': '10' },
          payload: { aps: { sound: 'default' } },
        },
      });

      return res.json({
        success: true,
        sent: result.successCount,
        failed: result.failureCount,
      });
    } catch (error) {
      return res.status(500).json({ error: error?.message || 'Internal server error' });
    }
  }
);
