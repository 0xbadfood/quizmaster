# Quizmaster Creator

Mobile-first Flutter client for orchestrating the Quizmaster category production
pipeline. Provider connections, credentials, endpoint tests, and narrator reference
audio remain managed by the Quizmaster web application.

The app supports three tasks:

- Choose configured providers and model overrides for a pipeline run.
- Submit category metadata and monitor persistent generation jobs.
- Review bundle readiness and explicitly deploy a completed bundle.

## Configuration

The default API is `https://quizmaster.photovault.live`. Set the bearer token in
the app's **Server access** sheet, where it is stored with platform secure storage,
or provide it at build time:

```bash
flutter run --dart-define=QUIZMASTER_API_TOKEN=<token>
```

The API URL can also be overridden with
`--dart-define=QUIZMASTER_API_URL=<url>`. Do not commit production tokens.

## Verification

```bash
flutter analyze
flutter test
flutter build apk --release
```
