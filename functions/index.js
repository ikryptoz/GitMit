const { onRequest } = require('firebase-functions/v2/https');
const { onValueCreated } = require('firebase-functions/v2/database');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');

admin.initializeApp();

const backendApiKey = defineSecret('BACKEND_API_KEY');
const githubNotifyToken = defineSecret('GITHUB_NOTIFY_TOKEN');

function buildPreviewText(rawText) {
  const text = String(rawText || '').trim();
  if (!text) {
    return 'Nova sifrovana zprava';
  }

  if (text.startsWith('{') && text.endsWith('}')) {
    try {
      const parsed = JSON.parse(text);
      if (parsed && parsed.type === 'image') {
        return 'Obrazek';
      }
      if (parsed && parsed.type === 'code') {
        const title = String(parsed.title || '').trim();
        if (title) return `Kod: ${title}`;
        return 'Kod';
      }
    } catch (_) {
      // Non-JSON plaintext; continue.
    }
  }

  if (text.length > 160) {
    return `${text.slice(0, 160)}...`;
  }
  return text;
}

async function isUserOffline(uid) {
  const snap = await admin.database().ref(`presence/${uid}`).get();
  const value = snap.val();
  if (!value || typeof value !== 'object') {
    return true;
  }
  return value.online !== true;
}

async function notificationsEnabledForUser(uid) {
  const snap = await admin.database().ref(`settings/${uid}/notificationsEnabled`).get();
  const value = snap.val();
  return value !== false;
}

async function getUserTokens(uid) {
  const snap = await admin.database().ref(`fcmTokens/${uid}`).get();
  const value = snap.val();
  if (!value || typeof value !== 'object') {
    return [];
  }

  return Object.values(value)
    .map((item) => (item && typeof item === 'object' ? String(item.token || '') : ''))
    .filter((token) => token.length > 0);
}

async function sendPushToUser({ uid, title, body, data }) {
  const tokens = await getUserTokens(uid);
  if (!tokens.length) return { sent: 0, failed: 0, reason: 'No tokens' };

  const result = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data,
    android: { priority: 'high' },
    apns: {
      headers: { 'apns-priority': '10' },
      payload: { aps: { sound: 'default' } },
    },
  });

  return {
    sent: result.successCount,
    failed: result.failureCount,
  };
}

exports.notifyDmMessageCreated = onValueCreated(
  {
    region: 'us-central1',
    ref: '/messages/{toUid}/{peerLogin}/{messageId}',
  },
  async (event) => {
    const toUid = String(event.params?.toUid || '').trim();
    const peerLogin = String(event.params?.peerLogin || '').trim();
    const messageId = String(event.params?.messageId || '').trim();
    const payload = event.data?.val();

    if (!toUid || !peerLogin || !messageId || !payload || typeof payload !== 'object') {
      return null;
    }

    const fromUid = String(payload.fromUid || '').trim();
    if (!fromUid || fromUid === toUid) {
      // Ignore sender-side mirrored message node.
      return null;
    }

    const [offline, enabled] = await Promise.all([
      isUserOffline(toUid),
      notificationsEnabledForUser(toUid),
    ]);
    if (!offline || !enabled) {
      return null;
    }

    const sender = `@${peerLogin}`;
    const preview = buildPreviewText(payload.text);
    const body = `${sender}: ${preview}`;

    await sendPushToUser({
      uid: toUid,
      title: 'Nova zprava',
      body,
      data: {
        type: 'dm_message',
        fromUid,
        fromLogin: peerLogin,
        chatLogin: peerLogin,
        messageId,
      },
    });

    return null;
  },
);

exports.notifyGroupMessageCreated = onValueCreated(
  {
    region: 'us-central1',
    ref: '/groupMessages/{groupId}/{messageId}',
  },
  async (event) => {
    const groupId = String(event.params?.groupId || '').trim();
    const messageId = String(event.params?.messageId || '').trim();
    const payload = event.data?.val();

    if (!groupId || !messageId || !payload || typeof payload !== 'object') {
      return null;
    }

    const fromUid = String(payload.fromUid || '').trim();
    if (!fromUid) {
      return null;
    }

    const [membersSnap, groupTitleSnap] = await Promise.all([
      admin.database().ref(`groupMembers/${groupId}`).get(),
      admin.database().ref(`groups/${groupId}/title`).get(),
    ]);

    const membersValue = membersSnap.val();
    if (!membersValue || typeof membersValue !== 'object') {
      return null;
    }

    const groupTitle = String(groupTitleSnap.val() || '').trim();
    const senderRaw = String(payload.fromGithub || '').trim();
    const sender = senderRaw ? `@${senderRaw}` : fromUid;
    const preview = buildPreviewText(payload.text);
    const body = `${sender}: ${preview}`;
    const title = groupTitle ? `Nova zprava ve skupine #${groupTitle}` : 'Nova skupinova zprava';

    const memberUids = Object.keys(membersValue).filter((uid) => uid && uid !== fromUid);
    if (!memberUids.length) {
      return null;
    }

    await Promise.all(
      memberUids.map(async (uid) => {
        const [offline, enabled] = await Promise.all([
          isUserOffline(uid),
          notificationsEnabledForUser(uid),
        ]);
        if (!offline || !enabled) return;

        await sendPushToUser({
          uid,
          title,
          body,
          data: {
            type: 'group_message',
            groupId,
            groupTitle,
            fromUid,
            fromLogin: senderRaw,
            messageId,
          },
        });
      }),
    );

    return null;
  },
);

function readProvidedApiKey(req) {
  const headerApiKey = String(req.get('x-api-key') || '').trim();
  if (headerApiKey) return headerApiKey;

  const auth = String(req.get('authorization') || '').trim();
  if (auth.toLowerCase().startsWith('bearer ')) {
    return auth.slice(7).trim();
  }
  return '';
}

async function sendGithubInviteMention({ targetLogin, fromLogin, preview }) {
  const token = String(githubNotifyToken.value() || '').trim();
  if (!token) {
    throw new Error('Missing GITHUB_NOTIFY_TOKEN secret');
  }

  const repoFull = String(process.env.GITMIT_GITHUB_NOTIFY_REPO || 'ikryptoz/GitMit').trim();
  if (!repoFull || !repoFull.includes('/')) {
    throw new Error('Missing GITMIT_GITHUB_NOTIFY_REPO (owner/repo)');
  }

  const issueNumberRaw = String(process.env.GITMIT_GITHUB_NOTIFY_ISSUE_NUMBER || '1').trim();
  const issueNumber = Number.parseInt(issueNumberRaw, 10);
  if (!Number.isFinite(issueNumber) || issueNumber <= 0) {
    throw new Error('Missing/invalid GITMIT_GITHUB_NOTIFY_ISSUE_NUMBER');
  }

  const [owner, repo] = repoFull.split('/');
  const appUrl = String(process.env.GITMIT_APP_URL || 'https://github.com/ikryptoz/GitMit').trim();

  const lines = [
    `@${targetLogin}`,
    `You have a new GitMit invite from @${fromLogin}.`,
    String(preview || '').trim() || 'Please install GitMit to continue the conversation.',
  ];
  if (appUrl) {
    lines.push(`Download GitMit: ${appUrl}`);
  }

  const response = await fetch(`https://api.github.com/repos/${owner}/${repo}/issues/${issueNumber}/comments`, {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'gitmit-functions',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      body: lines.join('\n\n'),
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${response.status}: ${body}`);
  }

  const data = await response.json();
  return {
    commentUrl: data?.html_url || '',
    commentId: data?.id || null,
  };
}

exports.notifyOnlinePresence = onRequest(
  {
    region: 'us-central1',
    secrets: [backendApiKey, githubNotifyToken],
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'Method Not Allowed' });
    }

    const expected = backendApiKey.value();
    if (expected && expected.trim().length > 0) {
      const provided = readProvidedApiKey(req);
      if (provided !== expected.trim()) {
        return res.status(401).json({ error: 'Unauthorized' });
      }
    }

    const targetLogin = String(req.body?.targetLogin || '').trim().replace(/^@+/, '');
    const fromLoginForGithub = String(req.body?.fromLogin || '').trim().replace(/^@+/, '');
    const preview = String(req.body?.preview || '').trim();

    // GitHub invite mode: notify non-GitMit user via GitHub mention.
    if (targetLogin && fromLoginForGithub) {
      try {
        const result = await sendGithubInviteMention({
          targetLogin,
          fromLogin: fromLoginForGithub,
          preview,
        });

        return res.json({
          success: true,
          mode: 'github-invite',
          targetLogin,
          fromLogin: fromLoginForGithub,
          ...result,
        });
      } catch (error) {
        return res.status(500).json({
          success: false,
          mode: 'github-invite',
          error: error?.message || 'Failed to send GitHub invite notification',
        });
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
