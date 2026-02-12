# 💻 Vývojářská a bezpečnostní dokumentace GitMit

Tento dokument slouží pro vývojáře, bezpečností auditory a technické nadšence, kteří chtějí pochopit "vnitřnosti" aplikace GitMit.

## 🏗️ Architektura systému
GitMit je multiplatformní aplikace postavená na:
- **Frontend (Mobile)**: Flutter (Dart) - hlavní aplikační logika a E2EE.
- **Frontend (Web)**: Vanilla JS / HTML / CSS - odlehčený klient (aktuálně v demo/beta režimu).
- **Backend**: Firebase 
    - **Authentication**: Správa identit.
    - **Realtime Database (RTDB)**: Ukládání veřejných klíčů (bundles) a šifrovaných zpráv.
    - **Cloud Functions**: Backendová logika a integrace.
- **External API**: GitHub REST API (pro avatary a metadata).

## 🛡️ Bezpečnostní model (E2EE)
Srdcem GitMitu je soubor `lib/e2ee.dart`, který implementuje moderní standardy pro end-to-end šifrování.

### 1. Kryptografické primitivy
- **X25519**: Diffie-Hellman Key Exchange (asymetrické klíče).
- **Ed25519**: Digitální podpisy pro ověření identity.
- **ChaCha20-Poly1305**: Symetrické šifrování zpráv (Authenticated Encryption).
- **HKDF (SHA-256)**: Odvozování klíčů (Key Derivation).
- **Double Ratchet**: Algoritmus pro forward secrecy a break-in recovery.

### 2. Protokol X3DH (Extended Triple Diffie-Hellman)
Při navazování relace (Session Initiation) aplikace využívá mechanismus "Signed Prekeys". Každý uživatel publikuje do Firebase RTDB bundle, který obsahuje:
- Identity Key (X25519)
- Identity Signing Key (Ed25519)
- Signed Prekey (X25519) + jeho podpis
- Prekey ID

Tento mechanismus umožňuje navázat bezpečnou šifrovanou relaci, i když je příjemce v danou chvíli offline.

### 3. Double Ratchet (v2)
GitMit implementuje druhou verzi Double Ratchet algoritmu pro kontinuální obměnu klíčů během konverzace.
- **DH Ratchet**: Každý nový "round-trip" zpráv vytvoří nový sdílený "root secret".
- **Symmetric Ratchet**: Každá odeslaná/přijatá zpráva odvozuje nový klíč z aktuálního řetězce (Chain Key).

### 4. Šifrování příloh (Encrypted Attachments)
Soubory a fotky jsou šifrovány pomocí separátní instance **ChaCha20-Poly1305** (`_attachmentAead`). 
- Pro každou přílohu se generuje unikátní klíč a nonce.
- Metadata o příloze (klíč, ID v bucketu) jsou zasílána jako šifrovaný payload v rámci E2EE zprávy.

### 5. Skupinové pozvánky (QR / Link)
Logika v `lib/join_group_via_link_qr_page.dart` umožňuje bezpečné připojení do skupiny:
- **Validace**: Kontroluje se existence skupiny a zda jsou link pozvánky povoleny (`inviteLinkEnabled`).
- **Mechanismus**: Skupina má unikátní `inviteCode`, který se porovnává s kódem z QR/linku.

## 🔑 Správa a konfigurace
- **Firebase**: Aplikace využívá projekt `githubmessenger-7d2c6`. Konfigurace pro Android/iOS je v `lib/firebase_options.dart`.
- **Local Storage**: Soukromé klíče jsou uloženy v zařízení pomocí `flutter_secure_storage`.
- **Lokalizace**: Dynamické překlady probíhají přes `lib/app_language.dart` (aktuálně CZ/EN).

## 📝 Audit kódu
Doporučené soubory k revizi:
1. `lib/e2ee.dart`: Jádro kryptografie.
2. `lib/dashboard.dart`: Implementace `_GitmitSyntaxHighlighter` a šifrování příloh.
3. `lib/join_group_via_link_qr_page.dart`: Logika QR skenování a připojování.

## 🔧 Vývoj a testování
Pro spuštění s GitHub tokenem použijte:
```bash
flutter run --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

---
[Zpět na hlavní přehled](file:///c:/Users/danie/GitMit/dokumentace/README.md)
