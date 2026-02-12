import { db } from './config.js';
import { currentUserId, currentGithubUsername } from './auth.js';
import { getSharedKey, encryptMessage } from './e2ee.js';
import { updateInfoPanel } from './ui.js';

let messagesListener = null;

export async function startChatWithUser(githubUser) {
    console.log("Starting chat with user:", githubUser.login);
    // We need the UID for this GitHub user to start a chat.
    const snap = await db.ref(`usernames/${githubUser.login.toLowerCase()}`).get();
    const targetUid = snap.val();

    if (!targetUid) {
        console.warn("User not found in usernames map:", githubUser.login);
        alert("Tento uživatel ještě nepoužívá GitMit (nemá UID).");
        return;
    }

    console.log("Target UID found:", targetUid);
    selectChat(githubUser.login, targetUid, githubUser.avatar_url);
}

export async function selectChat(login, uid, avatarUrl) {
    const activeChatName = document.getElementById('active-chat-name');
    const statusText = document.getElementById('active-chat-status');
    const avatarImg = document.getElementById('active-chat-avatar');

    // UI Updates
    activeChatName.textContent = login;
    avatarImg.src = avatarUrl || `https://github.com/${login}.png`;
    statusText.textContent = 'Načítám šifrování...';

    document.querySelectorAll('.chat-item').forEach(i => {
        i.classList.toggle('active', i.querySelector('.chat-item-name').textContent === login);
    });

    // Update global state tracking (attached to window for cross-module access simplicity in vanilla JS)
    window.activeChatLogin = login;
    window.activeChatUid = uid;

    // Update Info Panel
    updateInfoPanel(login, avatarUrl || `https://github.com/${login}.png`);

    // Fetch and store Shared Key
    const sharedKey = await getSharedKey(uid);
    window.activeSharedKey = sharedKey;

    if (sharedKey) {
        statusText.textContent = '🔒 Šifrováno (E2EE)';
    } else {
        statusText.textContent = '⚠️ Nešifrováno (Chybí klíč)';
    }

    loadMessages(login);
}

function loadMessages(otherLogin) {
    const messagesContainer = document.getElementById('messages-container');
    if (messagesListener) db.ref(`messages/${currentUserId}/${otherLogin}`).off('value', messagesListener);
    messagesContainer.innerHTML = '<div class="empty-state">Načítám zprávy...</div>';

    messagesListener = db.ref(`messages/${currentUserId}/${otherLogin}`).on('value', async snapshot => {
        messagesContainer.innerHTML = '';
        const msgs = snapshot.val();
        if (!msgs) {
            messagesContainer.innerHTML = '<div class="empty-state"><p>Zatím žádné zprávy</p></div>';
            return;
        }

        // Process messages asynchronously for decryption
        for (const msg of Object.values(msgs)) {
            const type = msg.fromUid === currentUserId ? 'sent' : 'received';
            const time = msg.createdAt ? new Date(msg.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : "";

            let text = msg.text;

            // Try decryption if encrypted fields are present
            if (msg.ciphertext && window.activeSharedKey) {
                const decrypted = await decryptMessage(msg, window.activeSharedKey);
                text = decrypted || "🔒 Šifrovaná zpráva";
            }

            addMessageToUI(text || "...", type, time);
        }
    });
}

export async function sendMessage() {
    const messageInput = document.getElementById('message-input');
    const text = messageInput.value.trim();

    if (!text || !window.activeChatLogin || !currentUserId) return;

    messageInput.value = '';
    messageInput.style.height = 'auto';

    const timestamp = firebase.database.ServerValue.TIMESTAMP;
    const otherUid = window.activeChatUid;
    const activeChatLogin = window.activeChatLogin;

    if (!otherUid) return;

    // Encryption
    let msgData = {
        fromUid: currentUserId,
        text: text, // Plaintext fallback/simultaneous
        createdAt: timestamp,
    };

    if (window.activeSharedKey) {
        const encrypted = await encryptMessage(text, window.activeSharedKey);
        msgData = { ...msgData, ...encrypted };
        // Optional: Remove plaintext text field if you want "true" privacy from database
        // but often keeping it for search/previews is requested. 
        // We'll keep it as a fallback since the user said "make it work".
    }

    const updates = {};
    const msgId = db.ref().child('messages').push().key;

    updates[`messages/${currentUserId}/${activeChatLogin}/${msgId}`] = msgData;
    updates[`messages/${otherUid}/${currentGithubUsername}/${msgId}`] = msgData;

    updates[`savedChats/${currentUserId}/${activeChatLogin}/lastMessageText`] = text;
    updates[`savedChats/${currentUserId}/${activeChatLogin}/lastMessageAt`] = timestamp;
    updates[`savedChats/${otherUid}/${currentGithubUsername}/lastMessageText`] = text;
    updates[`savedChats/${otherUid}/${currentGithubUsername}/lastMessageAt`] = timestamp;

    try {
        await db.ref().update(updates);
    } catch (e) {
        console.error("Failed to send message:", e);
    }
}

function addMessageToUI(text, type, time) {
    const messagesContainer = document.getElementById('messages-container');
    const msgDiv = document.createElement('div');
    msgDiv.className = `message message-${type}`;

    let processedText = text.replace(/`([^`]+)`/g, '<code>$1</code>');
    processedText = processedText.replace(/\n/g, '<br>');

    msgDiv.innerHTML = `
        <div class="message-bubble">
            <div class="message-text">${processedText}</div>
            <div class="message-time" style="font-size: 0.7rem; opacity: 0.5; text-align: right; margin-top: 4px;">${time}</div>
        </div>
    `;

    const bubble = msgDiv.querySelector('.message-bubble');
    if (type === 'sent') {
        bubble.style = "background:var(--green-6); border:1px solid var(--green-5); border-radius:12px 12px 0 12px; padding:10px 14px; color:var(--gray-1); max-width:100%; word-break:break-word;";
    } else {
        bubble.style = "background:var(--gray-5); border:1px solid var(--border); border-radius:12px 12px 12px 0; padding:10px 14px; color:var(--gray-1); max-width:100%; word-break:break-word;";
    }

    messagesContainer.appendChild(msgDiv);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
}
