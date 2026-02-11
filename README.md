# gitmit

A new Flutter project.

## GitHub API limit (PAT)

GitHub REST API má bez autentizace limit cca 60 requestů/hod.
S Personal Access Tokenem (PAT) se limit zvedne (typicky na 5 000 requestů/hod).

V aplikaci se token bere z `--dart-define` proměnné `GITHUB_TOKEN` a pokud je nastavená,
automaticky se přidá do hlavičky `Authorization: token ...`.

Spuštění s tokenem:

- `flutter run --dart-define=GITHUB_TOKEN=YOUR_TOKEN`
- `flutter test --dart-define=GITHUB_TOKEN=YOUR_TOKEN`

Poznámka: token nikdy nehardcoduj do repozitáře a nesdílej ho veřejně.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
