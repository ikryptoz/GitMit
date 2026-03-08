# GitMit

A Flutter application for browsing GitHub repositories, users, and activity — built with the GitHub REST API.

---

## Screenshots

![](https://github.com/user-attachments/assets/06e99630-4eb7-490c-890b-01732712b897)
![](https://github.com/user-attachments/assets/6738a9c2-0417-4d89-8f1e-911a2335bb9b)
![](https://github.com/user-attachments/assets/60e70bd2-4d00-4318-883a-e2a7f38229ea)
![](https://github.com/user-attachments/assets/3b998b22-05c9-453a-a6c1-dc5b26efca77)
![](https://github.com/user-attachments/assets/6080f93c-60f1-4482-b3cb-9c466033b71e)
![](https://github.com/user-attachments/assets/22bb3370-29d8-496e-a04e-eaa359ad2699)
![](https://github.com/user-attachments/assets/7592079d-2d23-466b-a5b3-d3cb846b6dad)
![](https://github.com/user-attachments/assets/dac8030c-575b-46df-8e6f-4b0076669c4f)
![](https://github.com/user-attachments/assets/a8c868c6-1ab8-4127-8ec4-20fa65a86339)
![](https://github.com/user-attachments/assets/1a847abb-bed0-4785-b201-870b7cec8ad2)
![](https://github.com/user-attachments/assets/c0903c34-98f6-4b34-9fce-41b787ee2229)
![](https://github.com/user-attachments/assets/77d1c97e-e268-448e-b5f0-4bb5341956af)
![](https://github.com/user-attachments/assets/0c496707-3ed1-45b6-a6b0-198b0ac58eb1)
![](https://github.com/user-attachments/assets/e60291f4-752f-480a-b8c9-675796ccfbcb)
![](https://github.com/user-attachments/assets/1a9953c1-dbc8-4955-ba74-a2e76a79bf0f)
![](https://github.com/user-attachments/assets/3e0b7270-677f-4ab2-87ae-d47221f8361b)
![](https://github.com/user-attachments/assets/0ac91232-e617-4319-80f8-d0095417b764)
![](https://github.com/user-attachments/assets/d31ef80f-85d1-4889-9525-a84e48a59783)


---

## Quick Walkthrough

1. Clone the repository and install dependencies
2. Optionally configure a GitHub Personal Access Token for higher API rate limits
3. Run the app with `flutter run` (or with your token via `--dart-define`)
4. Browse repositories, search users, and explore GitHub activity directly from the app

---

## Features

- Browse and search GitHub repositories and users
- View repository details, languages, stars, and forks
- Authenticated requests via Personal Access Token (PAT) for higher rate limits
- Clean, responsive Flutter UI for Android and iOS

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Framework | Flutter (Dart) |
| API | GitHub REST API v3 |
| HTTP | `http` package |
| State management | _(e.g. Provider / Riverpod / Bloc — update as applicable)_ |
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
├── screenshots/               # App screenshots (add yours here)
├── pubspec.yaml               # Dependencies and assets
└── README.md
```

> Note: Update this structure to match your actual directory layout if it differs.

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel recommended)
- Dart SDK (included with Flutter)
- Android Studio or Xcode for device/emulator setup

### Installation

```bash
git clone https://github.com/ikryptoz/GitMit.git
cd GitMit
flutter pub get
```

### Running the app

```bash
flutter run
```

---

## GitHub API & Rate Limits

The GitHub REST API has a default unauthenticated limit of approximately **60 requests/hour**.  
With a Personal Access Token (PAT), this limit increases to **5,000 requests/hour**.

GitMit reads the token from the `GITHUB_TOKEN` Dart define variable. When set, it is automatically included in the `Authorization: token ...` request header.

### Running with a token

```bash
flutter run --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

### Running tests with a token

```bash
flutter test --dart-define=GITHUB_TOKEN=YOUR_TOKEN
```

### Generating a Personal Access Token

1. Go to [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens)
2. Generate a new token (classic or fine-grained)
3. Select the `public_repo` scope (read-only access is sufficient for browsing)
4. Copy the token and use it as shown above

> **Security notice:** Never hardcode your token in source files and never commit it to the repository. Use environment variables or a local `.env` file that is listed in `.gitignore`.

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
