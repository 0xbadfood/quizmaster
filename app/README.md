# StoryVault App

Flutter app for the StoryVault kids experience, including the voice-chat client.

The active voice architecture is documented in `HANDOFF.md`. Product direction for the assistant layer is documented in `PRODUCT_INTENT.md`. In short, the iOS voice path uses local ASR and local PocketTTS, while `https://voice.photovault.live` owns personas, voice assets, sessions, and LLM routing.

## Build Notes

```bash
flutter pub get
flutter analyze
flutter build ios
```

Talk is opt-in for experimental builds:

```bash
flutter build apk --release --dart-define=STORYVAULT_ENABLE_TALK=true
```

Release/V1 builds omit that define, so the Talk dock item and Talk settings are
hidden.

The Sherpa/PocketTTS and Whisper model assets are not bundled into the app
package. Talk downloads them lazily from
`https://voice.photovault.live/api/mobile-voice-assets`, verifies SHA-256
hashes, and caches them in application support storage before benchmarking the
device. The source tree may still contain `vendor/sherpa_onnx/` so the voice
server can expose the mobile asset manifest.

Generated build outputs, local machine files, APKs, Pods, and Flutter cache folders are intentionally ignored.

## On-device voice benchmark

The V1 first-boot preparation screen measures local PocketTTS only. Talk uses
the voice server for persona/session/LLM routing, while capable devices play
server text chunks through on-device PocketTTS. The benchmark displays and
persists voice latency, warm/sustained RTF, thermal degradation, failures, and
peak process memory.

The benchmark is launched lazily from the Talk dock item, not at app startup.
If the user skips preparation, the rest of StoryVault is unaffected. If the
benchmark definitively fails, the Talk dock item is hidden until a future
retry/reset path is used.

Talk is a server-text, local-ASR, local-TTS feature. The voice server is an LLM
router for the app path; the Flutter client requires `client_text` WebSocket
mode and does not fall back to server-generated TTS audio.
