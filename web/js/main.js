import { initAuth } from './auth.js';
import { setupUI } from './ui.js';
import { sendMessage } from './chat.js';

function init() {
    console.log("GitMit Web Client Initializing (Modular)...");

    // Initialize Auth (which triggers other setups)
    initAuth();

    // Initialize UI listeners
    setupUI();

    // Global Event Listeners (e.g. send button)
    document.getElementById('send-btn').addEventListener('click', sendMessage);
    document.getElementById('message-input').addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });
    // Auto-expand textarea
    document.getElementById('message-input').addEventListener('input', function () {
        this.style.height = 'auto';
        this.style.height = (this.scrollHeight) + 'px';
    });

    // Info panel toggle
    document.getElementById('info-toggle').addEventListener('click', () => {
        document.getElementById('info-panel').classList.toggle('hidden');
    });
    document.getElementById('info-close').addEventListener('click', () => {
        document.getElementById('info-panel').classList.add('hidden');
    });
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
