# GitMit

A Flutter application for browsing GitHub repositories, users, and activity — powered by the GitHub REST API.

![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-lightgrey)
![GitHub API](https://img.shields.io/badge/GitHub%20REST%20API-v3-181717?logo=github&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Screenshots

| | | |
|---|---|---|
| ![](https://github.com/user-attachments/assets/06e99630-4eb7-490c-890b-01732712b897) | ![](https://github.com/user-attachments/assets/6738a9c2-0417-4d89-8f1e-911a2335bb9b) | ![](https://github.com/user-attachments/assets/60e70bd2-4d00-4318-883a-e2a7f38229ea) |
| ![](https://github.com/user-attachments/assets/3b998b22-05c9-453a-a6c1-dc5b26efca77) | ![](https://github.com/user-attachments/assets/6080f93c-60f1-4482-b3cb-9c466033b71e) | ![](https://github.com/user-attachments/assets/22bb3370-29d8-496e-a04e-eaa359ad2699) |
| ![](https://github.com/user-attachments/assets/7592079d-2d23-466b-a5b3-d3cb846b6dad) | ![](https://github.com/user-attachments/assets/dac8030c-575b-46df-8e6f-4b0076669c4f) | ![](https://github.com/user-attachments/assets/a8c868c6-1ab8-4127-8ec4-20fa65a86339) |
| ![](https://github.com/user-attachments/assets/1a847abb-bed0-4785-b201-870b7cec8ad2) | ![](https://github.com/user-attachments/assets/c0903c34-98f6-4b34-9fce-41b787ee2229) | ![](https://github.com/user-attachments/assets/77d1c97e-e268-448e-b5f0-4bb5341956af) |
| ![](https://github.com/user-attachments/assets/0c496707-3ed1-45b6-a6b0-198b0ac58eb1) | ![](https://github.com/user-attachments/assets/e60291f4-752f-480a-b8c9-675796ccfbcb) | ![](https://github.com/user-attachments/assets/1a9953c1-dbc8-4955-ba74-a2e76a79bf0f) |
| ![](https://github.com/user-attachments/assets/3e0b7270-677f-4ab2-87ae-d47221f8361b) | ![](https://github.com/user-attachments/assets/0ac91232-e617-4319-80f8-d0095417b764) | ![](https://github.com/user-attachments/assets/d31ef80f-85d1-4889-9525-a84e48a59783) |

---

## Quick Walkthrough

```bash
# 1. Clone the repo
git clone https://github.com/ikryptoz/GitMit.git
cd GitMit

# 2. Install dependencies
flutter pub get

# 3. Run (with or without a GitHub PAT)
flutter run
flutter run --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

The app connects to the GitHub REST API immediately — no backend required.

---

## Features

- Search GitHub users and browse their public profile and repositories
- View repository details — description, language breakdown, star and fork counts
- Authenticated API requests via Personal Access Token for significantly higher rate limits
- Handles GitHub API pagination for large result sets
- Responsive Flutter UI targeting Android and iOS

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| API | GitHub REST API v3 |
| HTTP client | `http` package |
| Authentication | Personal Access Token via `--dart-define` |
| Platform | Android, iOS |

---

## Project Structure

```
GitMit/
├── android/                   # Android platform files
├── ios/                       # iOS platform files
├── lib/
│   ├── main.dart              # App entry point
│   ├── models/                # Data models (Repository, User, ...)
│   ├── services/              # GitHub API service layer
│   ├── screens/               # UI screens
│   ├── widgets/               # Reusable UI components
│   └── utils/                 # Helpers and constants
├── test/                      # Unit and widget tests
├── pubspec.yaml               # Dependencies and assets
└── README.md
```

> Update this tree to match your actual directory layout.

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) — stable channel recommended
- Dart SDK — bundled with Flutter
- Android Studio or Xcode for running on a device or emulator

### Installation

```bash
git clone https://github.com/ikryptoz/GitMit.git
cd GitMit
flutter pub get
```

### Run on a device or emulator

```bash
flutter run
```

---

## GitHub API & Rate Limits

| Mode | Limit |
|---|---|
| Unauthenticated | ~60 requests / hour |
| With Personal Access Token | 5,000 requests / hour |

GitMit reads the token from the `GITHUB_TOKEN` Dart define. When provided, it is automatically attached to every request as `Authorization: token <value>`.

### Running with a token

```bash
flutter run --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

### Running tests with a token

```bash
flutter test --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

### Generating a Personal Access Token

1. Open [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens)
2. Create a new token — classic or fine-grained
3. Grant the `public_repo` scope (read-only is sufficient)
4. Copy the token and pass it via `--dart-define` as shown above

> **Security:** Never hardcode the token in source files. Never commit it to the repository. Add any local secrets file to `.gitignore`.

---

## Running Tests

```bash
# Without authentication
flutter test

# With GitHub PAT
flutter test --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Commit your changes: `git commit -m "Add your feature"`
4. Push to the branch: `git push origin feature/your-feature`
5. Open a Pull Request

---

## License

This project is open source. See [LICENSE](LICENSE) for details.

---

## Resources

- [Flutter documentation](https://docs.flutter.dev/)
- [GitHub REST API documentation](https://docs.github.com/en/rest)
- [Flutter cookbook](https://docs.flutter.dev/cookbook)
