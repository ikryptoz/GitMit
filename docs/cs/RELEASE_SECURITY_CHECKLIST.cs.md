# Release Security Checklist (CZ)

## Pred releasem

- [ ] Zkontrolovat, ze nejsou commitnute secrety.
- [ ] Podepisovani release je mimo git.
- [ ] Dependency/security review.

## Android

- [ ] Build podepsaneho AAB.
- [ ] Spravny package name a signing identita.
- [ ] Minify/shrink zapnuto pro release.

## Web

- [ ] Produkcni build bez debug endpointu.
- [ ] Overit startup UX a cache/compression.

## Po release

- [ ] Monitoring chyb a auth anomalii.
- [ ] Dokumentace verze, rollback plan.
