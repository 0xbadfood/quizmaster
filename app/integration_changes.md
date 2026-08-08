# StoryVault Integration Notes

This folder is a copied integration target based on `~/story_generator/sunshine/sunshine_app`.
The original Sunshine app and the standalone chatbot app are intentionally left untouched.

## Intent

StoryVault keeps the Sunshine/Story Generator shell and adds the voice companion as a full-screen route launched from the bottom dock. The dock item is a launcher, not a persistent tab, so returning from voice chat drops the child back into the existing StoryVault shell.

## Voice Integration

- The dock uses `DockItem` enum values instead of integer indexes.
- The `Talk` dock item launches `VoiceChatScreen`.
- The voice screen is adapted from `~/chatbot/mobile/spark_client`.
- Native Android audio capture/playback and WebRTC VAD are wired through the `spark/audio` and `spark/mic` channels.
- Android microphone permission is included.
- iOS microphone usage text is included, though the native bridge work is currently Android-focused.

## Persona Ownership

The app should treat persona metadata as server-owned. The client can cache thumbnails/assets for display, but conversation startup should pass persona IDs to the backend rather than embedding prompt logic in the app.

Bundled persona images are currently fallback/local display assets. The longer-term direction is to fetch persona JSON and images from the voice server.

## Build Contract

Always build with the voice server URL define:

```bash
flutter build apk --release --dart-define=SPARK_SERVER_URL=https://voice.photovault.live
```

Use `./build.sh` from this folder to avoid losing that define in future Story Generator context:

```bash
./build.sh
```

Optional overrides:

```bash
BUILD_MODE=debug ./build.sh
CLEAN=1 ./build.sh
SPARK_SERVER_URL=https://voice.photovault.live ./build.sh
```

## Current Scope Boundary

GUI responsibility for the chatbot-side project is considered complete here. Future visual adjustments should happen in the Story Generator context, while backend voice routing, LLM routing, TTS routing, and production service hardening remain backend responsibilities.
