# Threat Model (CZ)

## In-scope utocnici

- pasivni odposlech site,
- pozorovatel backend uloziste,
- neautorizovany uzivatel manipulujici klientem,
- copycat fork vydavajici se za oficialni app.

## Out-of-scope

- plne kompromitovane endpointy,
- fyzicky pristup k odemcenemu zarizeni,
- social engineering.

## Mitigace

- E2EE + TLS,
- backend authorization rules,
- monitoring anomalii,
- trademark/package identity kontrola.

## Rezidualni rizika

- metadata viditelnost,
- kradez credentialu uzivatele,
- zpozdeni pri enforce proti impersonaci.
