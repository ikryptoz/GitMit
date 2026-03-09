# Architektura Sifrovani

GitMit pouziva end-to-end sifrovani (E2EE) pro obsah zprav.

## Co je cil

- plaintext zprav deifrovat jen na zarizenich ucastniku,
- na backend ukladat sifrovany payload,
- klice a session stav drzet na klientech.

## Krypto stavebni bloky

- identita/fingerprint: Ed25519,
- dohoda klice: X25519,
- sifrovani zpravy: autentizovane sifrovani (ChaCha20-Poly1305 styl),
- DM: ratchet/session mechanismus,
- skupiny: group key/sender key podle dostupnosti.

## Fingerprint overeni

Fingerprint slouzi jako anti-MITM kontrola.
Doporuceni:
1. porovnej fingerprint mimo app,
2. pri neocekavane zmene ber situaci jako bezpecnostni incident.

## Co E2EE neumi schovat

- routing metadata,
- casove znacky,
- stav doruceni/precteni,
- cast topologie komunikace.

## Prakticka doporuceni

- overuj fingerprinty u citlivych chatu,
- pouzivej duveryhodna zarizeni,
- aktualizuj aplikaci,
- pri mismatch stavu klicu spust resync/pairing.
