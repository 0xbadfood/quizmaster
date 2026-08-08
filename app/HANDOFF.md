# StoryVault V1 Voice Handoff

Date: 2026-07-24

This app lives at `/home/nitin/StoryVault`. It is the active Flutter client for
StoryVault, copied out of the larger `/home/nitin/story_generator` work so the
voice feature could be hardened without disturbing the main app.

This file is the handoff for the next `story_generator` context. Treat it as
the current V1 source of truth.

## Final V1 Shape

Talk is a server-text, on-device-audio feature.

- The Flutter app talks only to `https://voice.photovault.live`.
- The server owns personas, prompts, welcome prompts, persona images, voice
  samples, sessions, and LLM routing.
- The app records audio locally and runs local Whisper ASR.
- The app sends text turns to the server over WebSocket.
- The server streams `tts_text_chunk` events.
- The app runs local PocketTTS/Sherpa on those text chunks and plays audio
  locally.
- The app requires WebSocket `client_text` mode.
- The V1 app must not fall back to server-generated TTS audio.
- No local LLM ships in V1.

The backend can still contain ASR, server TTS, TTS router, local LLM, and other
prototype paths, but the StoryVault V1 app path is intentionally simpler:

`device ASR -> voice server LLM router -> device TTS`

## Backend

Backend repo:

`/home/nitin/chatbot`

Live service:

`voicechat`

Public endpoint:

`https://voice.photovault.live`

Important backend files:

- `backend/app/session.py`
- `backend/app/llm.py`
- `backend/app/prompt.py`
- `backend/app/mobile_model_assets.py`
- `backend/app/settings.py`
- `personas/*.json`

Expected server behavior for the app:

- `GET /api/personas` returns all persona metadata.
- `GET /api/mobile-voice-assets` returns the mobile model manifest.
- `GET /api/mobile-voice-assets/files/{path}` serves PocketTTS and Whisper
  assets.
- `GET /api/personas/{id}/assets/thumbnail` serves persona thumbnails.
- `GET /api/personas/{id}/assets/portrait` serves persona portraits.
- `GET /api/tts-assets/personas/{id}/voice-sample` serves normalized WAV voice
  samples.
- `/ws/session` accepts `tts_mode_preference=client_text` and streams
  `tts_text_chunk`.

Useful live checks:

```bash
systemctl is-active voicechat
journalctl -u voicechat -n 200 --no-pager
curl -sS https://voice.photovault.live/api/personas
curl -sS https://voice.photovault.live/api/mobile-voice-assets
```

The server now logs bounded client TTS text previews for debugging language and
script problems:

```bash
journalctl -u voicechat -n 300 --no-pager | rg 'client_tts_text|devanagari='
```

The log records `non_ascii`, `devanagari`, language, persona, chunk index, and
a short preview. This helped confirm that Hindi edge testing produced romanized
Hindi, not Devanagari.

## Flutter App

Important app files:

- `lib/screens/voice_chat_screen.dart`
  - hardcoded voice server URL
  - WebSocket session logic
  - persona UI
  - persona fetch/cache
  - local ASR turn submission
  - `tts_text_chunk` handling
  - local PocketTTS playback orchestration

- `lib/startup/app_preparation.dart`
  - lazy Talk preparation controller
  - mobile model download
  - local TTS benchmark
  - device compatibility decision
  - persona/image/voice prefetch after a successful benchmark

- `lib/screens/app_preparation_screen.dart`
  - production Talk preparation screen
  - progress GIF
  - real MB progress while model assets download
  - simple final compatible/not-compatible result

- `lib/voice/voice_model_assets.dart`
  - downloads, resumes, hashes, and caches PocketTTS/Whisper assets

- `lib/voice/persona_asset_cache.dart`
  - downloads persona thumbnails, portraits, and voice samples after the device
    passes the TTS benchmark

- `lib/voice/local_pocket_tts.dart`
  - local PocketTTS/Sherpa wrapper
  - uses persona voice sample WAVs for cloning
  - inserts sentence pauses
  - waits for actual native playback completion

- `lib/voice/local_whisper_asr.dart`
  - local Whisper/Sherpa ASR wrapper

- `lib/voice/audio_bridge.dart`
  - platform audio record/playback bridge

## Talk Preparation

Talk setup is intentionally lazy. It starts only when the user taps the Talk
dock item.

The preparation flow:

1. Download voice model assets from the voice server.
2. Show real progress as downloaded MB over total MB.
3. Verify SHA-256 and cache the files.
4. Run the local PocketTTS benchmark.
5. If the device passes, prefetch all persona images and voice samples.
6. Show only a simple final result:
   - `Chat can be enabled on this device.`
   - `Chat cannot be enabled on this device.`

Benchmark internals stay in Settings. The public preparation screen should not
show RTF, first-audio p95, thread count, or other technical values.

The Talk dock item is hidden/disabled when the benchmark definitively fails.
There is a Settings path to re-run the benchmark and adjust benchmark gates.

## Persona Assets

The server owns persona metadata. The client should not hardcode prompt,
language, voice, or persona asset details.

`GET /api/personas` should provide:

- `id`
- `display_name`
- `subtitle`
- `tagline`
- `color`
- `thumbnail_url`
- `portrait_url`
- `asset_version`
- `voice_sample_url`
- `voice_asset_sha256`
- `voice_library_id`
- `voice_library_name`
- `language`

Client cache logic:

- Images are cached by `persona_id + asset_version + kind`.
- Voice samples are cached by `persona_id + voiceCacheKey`.
- `voiceCacheKey` prefers `voice_asset_sha256`, then
  `voice_library_id + asset_version`, then `asset_version`.

If a persona voice changes on the server, update the normalized WAV/hash so the
client downloads the new voice automatically.

Voice samples for PocketTTS should remain:

- WAV
- mono
- 24 kHz
- 16-bit PCM
- roughly 10 to 12 seconds
- clean speech, no music/noise

## Language Scope

V1 Talk is English-only from the TTS point of view. Edge testing showed that
romanized Hindi reaches PocketTTS as ASCII text and can sound poor because the
English TTS model guesses English phonemes.

Handle this in persona prompts for now:

```text
Speak only in simple English. If the child asks for Hindi or another language,
warmly say this voice currently speaks best in English. Do not output
Devanagari or romanized Hindi.
```

This is a prompt/product constraint, not a transport bug.

## Build

From now on, build release APKs for Android checks.

```bash
cd /home/nitin/StoryVault
flutter pub get
flutter analyze
flutter test test/device_tts_benchmark_test.dart
flutter build apk --release
```

Latest verified release artifact:

`/home/nitin/StoryVault/build/app/outputs/flutter-apk/app-release.apk`

The release build completed successfully at about 193 MB. Kotlin Gradle plugin
migration warnings are present but are not current build failures.

iOS must be built on a Mac.

## Verified Recently

On 2026-07-24:

- `flutter analyze` passed.
- `flutter test test/device_tts_benchmark_test.dart` passed.
- `flutter build apk --release` passed.
- `voicechat` was restarted and active.
- Server-side `client_tts_text_chunk` logging was added and validated.
- Model download progress and persona prefetch were added to the app.
- Release APK build is the default going forward.

## Intentional V1 Exclusions

Do not revive these for V1 unless explicitly requested:

- bundled local LLM
- HostAI/llama.cpp local companion app path
- server-side TTS fallback in the Flutter app
- backend TTS router as the app production path
- Hindi or multilingual TTS
- captioning
- heavy diagnostic UI on the Talk screen

The server can keep prototype code, but the app should remain focused on local
ASR/TTS plus server LLM routing.

## Integration Back Into story_generator

When merging this work into `/home/nitin/story_generator`, treat Talk as a
launcher from the StoryVault dock into a full-screen voice route.

The dock item should appear after stories/rhymes and before playlists, matching
the previous StoryVault integration direction.

Keep the original StoryVault content experience independent from Talk:

- Do not start model downloads at app launch.
- Do not run the Talk benchmark at app launch.
- Do not block stories, rhymes, playlists, or registration on Talk setup.
- If Talk setup is skipped or fails, the rest of StoryVault should remain fully
  usable.

## Quick Mental Model

The app is now an audio endpoint, not an AI backend.

The server decides what to say. The phone decides how to hear and speak it.

That is the V1 architecture.
