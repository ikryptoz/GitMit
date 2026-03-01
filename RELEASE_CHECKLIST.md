# Play Store Release Checklist for GitMit

- [ ] Update version and versionCode in pubspec.yaml for each release
- [ ] Ensure applicationId in build.gradle.kts is correct and final
- [ ] Generate a release keystore and update signingConfigs in build.gradle.kts
- [ ] Do not use debug signing for Play Store releases
- [ ] Complete Play Store listing (title, description, screenshots, icon, feature graphic)
- [ ] Add privacy policy and required disclosures
- [ ] Remove or update any restricted permissions/APIs
- [ ] Test release build on a real device
- [ ] Run `flutter build apk --release` and verify output
- [ ] Upload to Play Console and complete review steps

See https://developer.android.com/studio/publish for full details.
