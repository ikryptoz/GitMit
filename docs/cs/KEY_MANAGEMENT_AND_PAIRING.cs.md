# Sprava Klicu a Pairing (CZ)

## Zivotni cyklus klicu

1. generace na duveryhodnem zarizeni,
2. publikace verejneho klice,
3. navazani session,
4. lokalni persistence,
5. rotace/recovery pri zmene stavu.

## Pairing

Pairing prenasi klicovy material z primarniho zarizeni na sekundarni.
Dulezite je:
- explicitni akce uzivatele,
- kratkodoby pairing token,
- potvrzeni uspesneho/failed importu na obou stranach,
- moznost replace local keys pro sjednoceni identity.

## Web poznamky

Web musi mit stabilni lokalni ulozeni klicu.
Pri ztrate lokalniho stavu je nutny restore/pairing.
