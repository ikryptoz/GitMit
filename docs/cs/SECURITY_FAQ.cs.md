# Security FAQ (CZ)

## Je GitMit end-to-end sifrovany?

Ano, obsah zprav je navrzeny pro E2EE flow.

## Muze server cist moje zpravy?

Server ma ukladat sifrovane payloady; plaintext je urceny pro klienta.

## Schova E2EE vsechno?

Ne. Metadata pro routing/sync zustavaji.

## Lze aplikaci ukrast z GitHubu?

U public repozitare ano, kod lze kopirovat. Ochrana je o secrets, backend authz a pravni/IP kontrole.

## Lze web kod uplne skryt?

Ne, browser ho musi stahnout.
