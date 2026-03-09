# Security Model (CZ)

## Bezpecnostni cile

- chranit obsah zprav,
- drzet soukrome klice na klientech,
- vynucovat autorizaci na backendu,
- zamezit uniku tajnych udaju v repu/CI.

## Trust boundaries

Klient: generuje/uklada klice, sifruje a desifruje.
Backend: routuje a uklada sifrovana data, vynucuje authz.

## Limity

- public repo lze klonovat,
- webovy klient nelze plne skryt,
- obfuskace zvysuje narocnost reverse engineeringu, ale neni absolutni ochrana.

## Hardening

- privatni repo pokud je to pozadavek,
- 2FA a branch protection,
- tajemstvi jen v secrets manageru,
- server-side validace vseho citliveho,
- rotace tokenu po incidentu.

## Incident response

1. rotace credentialu,
2. revokace session/tokenu,
3. transparentni komunikace dopadu,
4. zpetna analyza a fix.
