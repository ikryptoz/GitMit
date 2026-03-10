# Shorebird pipeline (CZ)

Shorebird slouzi pro rychle Dart-only updaty bez cekani na plny Play review cyklus.

## Co umi

- rychly patch Dart kodu,
- update po dalsim spusteni aplikace,
- bez nutnosti noveho loginu.

## Co neumi

- nativni zmeny (pluginy, Android manifest, Gradle) porad vyzaduji normalni Play release,
- neobchazi Google Play bezpecnostni model.

## Priprava

1. `shorebird login`
2. `shorebird init` (jednorazove)

## Zakladni prikazy

- release:
  - `shorebird release android --artifact aab --flutter-version=stable`
- patch:
  - `shorebird patch android --release-version <x.y.z+build>`

## CI v tomto repu

- `.github/workflows/shorebird-release-android.yml`
- `.github/workflows/shorebird-patch-android.yml`

Potreba secrets:
- `SHOREBIRD_TOKEN`
- `GITMIT_KEYSTORE_FILE_BASE64`
- `GITMIT_KEYSTORE_PASSWORD`
- `GITMIT_KEY_ALIAS`
- `GITMIT_KEY_PASSWORD`

## Dulezite pravidlo

Patch pouzivej jen pro Dart-only zmeny. Nativni zmeny = novy Play release.
