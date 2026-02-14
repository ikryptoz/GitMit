const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');

admin.initializeApp();

const backendApiKey = defineSecret('BACKEND_API_KEY');
const githubNotifyToken = defineSecret('GITHUB_NOTIFY_TOKEN');

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
