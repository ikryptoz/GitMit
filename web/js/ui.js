import { db } from './config.js';
import { fetchGithubUser, searchGithubUsers } from './api.js';
import { startChatWithUser, selectChat } from './chat.js';
import { currentUserId, currentGithubUsername } from './auth.js';

let savedChatsListener = null;

export function setupUI() {
    setupNavigation();
    setupSearch();
    setupSidebarSearch();
}

function setupNavigation() {
    // Navigation items
    const navChats = document.getElementById('nav-chats');
    const navSearch = document.getElementById('nav-search');
    const navSettings = document.getElementById('nav-settings');
    const userProfile = document.querySelector('.user-profile'); // Avatar in nav

    navChats.addEventListener('click', () => {
        setActiveNav(navChats);
        showView('chat-view');
        showMyProfile(); // As requested: "ukaze informace o me"
    });

    navSearch.addEventListener('click', () => {
        setActiveNav(navSearch);
        showView('search-view'); // We will simulate a dedicated search view or reusing the list
        // Based on request: "v hledani hledam novy chat" -> Maybe user wants sidebar search focused?
        // Or a dedicated search page. Let's focus sidebar search for simplicity as it fits the layout.
        document.getElementById('sidebar-search').focus();
    });

    navSettings.addEventListener('click', () => {
        setActiveNav(navSettings);
        showSettingsView(); // We'll implement this modal/view
    });

    userProfile.addEventListener('click', () => {
        // "click on message pole at to vyskoci na vsechny chaty co mam a ukaze informace o me"
        // Wait, "message pole" -> maybe "user avatar"?
        // Request: "kdyz kliknu na message pole at to vyskoci na vsechny chaty co mam a ukaze informace o me"
        // "message icon" is navChats.
        // User profile icon -> show my info.
        showMyProfile();
    });
}

function setActiveNav(element) {
    document.querySelectorAll('.nav-item').forEach(i => i.classList.remove('active'));
    element.classList.add('active');
}

function showView(viewName) {
    // For now, we are single page, but we can toggle sidebars or main content visibility.
    // Default is chat list.
    console.log("Switching to", viewName);
}

function showSettingsView() {
    const mainContent = document.querySelector('.main-content');
    mainContent.innerHTML = `
        <div style="padding:40px;max-width:600px;margin:0 auto;">
            <h1>Nastavení</h1>
            <div style="margin-top:20px;padding:20px;background:var(--gray-5);border-radius:8px;">
                <h3>Vzhled</h3>
                <label style="display:flex;align-items:center;margin-top:10px;gap:10px;">
                    <input type="checkbox" checked disabled> Tmavý režim (GitHub Dark)
                </label>
            </div>
             <div style="margin-top:20px;padding:20px;background:var(--gray-5);border-radius:8px;">
                <h3>Šifrování</h3>
                <p>E2EE Klíč: <span style="color:var(--github-green);">Aktivní (X25519)</span></p>
                <button style="margin-top:10px;padding:8px 16px;background:rgba(255,0,0,0.2);color:#ff6666;border:none;border-radius:6px;cursor:pointer;">Resetovat Klíče</button>
            </div>
        </div>
    `;
}

function showMyProfile() {
    // Show info panel with MY info
    if (document.getElementById('info-panel').classList.contains('hidden')) {
        document.getElementById('info-panel').classList.remove('hidden');
    }
    // Fetch my info
    if (currentGithubUsername) {
        // Placeholder avatar from auth
        // Use standard updateInfoPanel function but for ME
        const me = firebase.auth().currentUser; // simpler access
        updateInfoPanel(currentGithubUsername, me.photoURL);
    }
}

export function setupLoggedInUI(user) {
    document.getElementById('user-avatar').src = user.photoURL || "https://github.com/identicons/gitmit.png";

    // Listen for saved chats
    if (savedChatsListener) db.ref(`savedChats/${user.uid}`).off('value', savedChatsListener);
    savedChatsListener = db.ref(`savedChats/${user.uid}`).on('value', snapshot => {
        const chats = snapshot.val();
        renderChatList(chats);
    });
}

function renderChatList(chats) {
    const chatList = document.getElementById('chat-list');
    chatList.innerHTML = '';

    if (!chats) {
        chatList.innerHTML = '<div class="chat-item-placeholder">Žádné konverzace</div>';
        return;
    }

    Object.entries(chats).sort((a, b) => (b[1].lastMessageAt || 0) - (a[1].lastMessageAt || 0)).forEach(([login, data]) => {
        const item = document.createElement('div');
        item.className = 'chat-item';

        // Find UID? 
        // Logic complication: savedChats structure is {login: {lastMessage...}}
        // We need UID to start chat. Either we store it or fetch it.
        // For quickness, we'll fetch on click if not stored.

        item.innerHTML = `
            <img src="${data.avatarUrl || `https://github.com/${login}.png`}" alt="${login}" class="avatar-sm">
            <div class="chat-item-meta">
                <div class="chat-item-name">${login}</div>
                <div class="chat-item-last">${data.lastMessageText || "..."}</div>
            </div>
        `;
        item.onclick = async () => {
            // We need UID.
            const snap = await db.ref(`usernames/${login.toLowerCase()}`).get();
            const uid = snap.val();
            selectChat(login, uid, data.avatarUrl);
        };
        chatList.appendChild(item);
    });
}

function setupSidebarSearch() {
    const searchInput = document.getElementById('sidebar-search');
    const searchResults = document.getElementById('search-results');

    // Request: "aby hledani fungovalo az po zmacknuti enter nebo sipky"
    searchInput.addEventListener('keydown', async (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            const query = searchInput.value;
            if (query.length >= 2) {
                const results = await searchGithubUsers(query);
                renderSearchResults(results);
            }
        }
    });

    // Close on outside click
    document.addEventListener('click', (e) => {
        if (!e.target.closest('.search-container')) {
            searchResults.classList.add('hidden');
        }
    });
}

function renderSearchResults(users) {
    const searchResults = document.getElementById('search-results');
    searchResults.innerHTML = '';
    if (users.length === 0) {
        searchResults.innerHTML = '<div style="padding:10px;color:var(--text-secondary);">Žádní uživatelé nenalezeni</div>';
        searchResults.classList.remove('hidden');
        return;
    }

    users.forEach(user => {
        const div = document.createElement('div');
        div.className = 'search-result-item';
        div.innerHTML = `
            <img src="${user.avatar_url}" class="avatar-sm">
            <span class="search-result-name">${user.login}</span>
        `;
        div.onclick = () => {
            console.log("Search result clicked for:", user.login);
            searchResults.classList.add('hidden');
            document.getElementById('sidebar-search').value = '';
            startChatWithUser(user);
        };
        searchResults.appendChild(div);
    });
    searchResults.classList.remove('hidden');
}

export async function updateInfoPanel(username, avatarUrl) {
    const infoPanel = document.getElementById('info-panel');
    infoPanel.classList.remove('hidden'); // Ensure visible

    document.getElementById('info-name').textContent = username;
    document.getElementById('info-avatar').src = avatarUrl;
    document.getElementById('info-login').textContent = `@${username.toLowerCase()}`;

    const data = await fetchGithubUser(username);
    if (data) {
        document.querySelector('.info-stats').innerHTML = `
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:20px;">
                <div style="background:rgba(255,255,255,0.05);padding:10px;border-radius:8px;text-align:center;">
                    <div style="font-size:1.2rem;font-weight:700;color:var(--github-green);">${data.public_repos}</div>
                    <div style="font-size:0.8rem;color:var(--text-secondary);">Repozitářů</div>
                </div>
                <div style="background:rgba(255,255,255,0.05);padding:10px;border-radius:8px;text-align:center;">
                    <div style="font-size:1.2rem;font-weight:700;color:var(--github-green);">${data.followers}</div>
                    <div style="font-size:0.8rem;color:var(--text-secondary);">Sledujících</div>
                </div>
            </div>
            ${data.bio ? `<div style="margin-bottom:15px;color:var(--text-primary);font-size:0.9rem;">${data.bio}</div>` : ''}
            ${data.location ? `<div style="margin-bottom:8px;color:var(--text-secondary);font-size:0.9rem;">📍 ${data.location}</div>` : ''}
        `;

        document.getElementById('github-contributions-container').innerHTML = `
            <img src="https://ghchart.rshah.org/${username}" alt="Github Chart" style="width:100%;opacity:0.8;">
        `;
    }
}

function setupSearch() {
    // Main header search button removed/unused? 
    // Left just in case.
}
