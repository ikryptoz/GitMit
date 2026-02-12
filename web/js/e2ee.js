import { db } from './config.js';

export let myKeyPair = null; // { publicKey: Uint8Array, privateKey: Uint8Array }

async function getSodium() {
    if (typeof sodium !== 'undefined') return sodium;
    if (window.sodium) return window.sodium;

    // Wait a bit if it's loading
    return new Promise((resolve) => {
        let attempts = 0;
        const interval = setInterval(() => {
            const s = typeof sodium !== 'undefined' ? sodium : window.sodium;
            if (s || attempts > 20) {
                clearInterval(interval);
                resolve(s);
            }
            attempts++;
        }, 100);
    });
}

export async function setupE2EE(uid) {
    const s = await getSodium();
    if (!s) {
        console.error("Sodium not loaded after waiting.");
        return;
    }
    await s.ready;

    // 1. Load or Generate KeyPair
    const storedPrivKey = localStorage.getItem(`e2ee_priv_${uid}`);
    if (storedPrivKey) {
        try {
            const privateKey = s.from_base64(storedPrivKey, s.base64_variants.URLSAFE);
            const publicKey = s.crypto_scalarmult_base(privateKey);
            myKeyPair = { publicKey, privateKey };
        } catch (e) {
            console.error("Failed to load stored E2EE key:", e);
        }
    }

    if (!myKeyPair) {
        myKeyPair = s.crypto_box_keypair();
        localStorage.setItem(`e2ee_priv_${uid}`, s.to_base64(myKeyPair.privateKey, s.base64_variants.URLSAFE));
    }

    // 2. Publish Public Key to Firebase (if changed or missing)
    const pubKeyB64 = s.to_base64(myKeyPair.publicKey, s.base64_variants.URLSAFE);

    const snap = await db.ref(`users/${uid}/e2ee`).get();
    const existing = snap.val();

    if (!existing || existing.x25519 !== pubKeyB64) {
        await db.ref(`users/${uid}/e2ee`).update({
            v: 1,
            x25519: pubKeyB64,
            updatedAt: firebase.database.ServerValue.TIMESTAMP
        });
        console.log("E2EE Public Key published using Sodium.");
    }
}

export async function getSharedKey(otherUid) {
    const s = await getSodium();
    if (!s || !myKeyPair) return null;
    await s.ready;

    const snap = await db.ref(`users/${otherUid}/e2ee/x25519`).get();
    const otherPubKeyB64 = snap.val();

    if (!otherPubKeyB64) return null;

    try {
        const otherPubKey = s.from_base64(otherPubKeyB64, s.base64_variants.URLSAFE);
        return s.crypto_scalarmult(myKeyPair.privateKey, otherPubKey);
    } catch (e) {
        console.error("Shared key derivation failed:", e);
        return null;
    }
}

export async function encryptMessage(text, sharedKey) {
    const s = await getSodium();
    if (!s || !sharedKey) return { text: text };
    await s.ready;

    const nonce = s.randombytes_buf(s.crypto_aead_chacha20poly1305_ietf_NPUBBYTES);
    const messageUint8 = s.from_string(text);

    const encrypted = s.crypto_aead_chacha20poly1305_ietf_encrypt(
        messageUint8,
        null,
        null,
        nonce,
        sharedKey
    );

    const tagLength = s.crypto_aead_chacha20poly1305_ietf_ABYTES;
    const ciphertext = encrypted.slice(0, encrypted.length - tagLength);
    const mac = encrypted.slice(encrypted.length - tagLength);

    return {
        e2eeV: 1,
        alg: 'x25519+chacha20poly1305',
        nonce: s.to_base64(nonce, s.base64_variants.URLSAFE),
        ciphertext: s.to_base64(ciphertext, s.base64_variants.URLSAFE),
        mac: s.to_base64(mac, s.base64_variants.URLSAFE)
    };
}

export async function decryptMessage(msg, sharedKey) {
    const s = await getSodium();
    if (!s || !sharedKey) return null;
    if (!msg.ciphertext || !msg.nonce || !msg.mac) return msg.text;

    await s.ready;

    try {
        const nonce = s.from_base64(msg.nonce, s.base64_variants.URLSAFE);
        const ciphertext = s.from_base64(msg.ciphertext, s.base64_variants.URLSAFE);
        const mac = s.from_base64(msg.mac, s.base64_variants.URLSAFE);

        const fullCipher = new Uint8Array(ciphertext.length + mac.length);
        fullCipher.set(ciphertext);
        fullCipher.set(mac, ciphertext.length);

        const decrypted = s.crypto_aead_chacha20poly1305_ietf_decrypt(
            null,
            fullCipher,
            null,
            nonce,
            sharedKey
        );

        return s.to_string(decrypted);
    } catch (e) {
        console.error("Decryption failed:", e);
        return "🔒 Nepodařilo se dešifrovat zprávu";
    }
}
