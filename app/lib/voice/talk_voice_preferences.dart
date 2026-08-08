import 'package:shared_preferences/shared_preferences.dart';

const double talkVoiceSpeedMin = 0.7;
const double talkVoiceSpeedMax = 1.2;
const double talkVoiceSpeedDefault = 0.8;
const int talkVoicePrerollMinMs = 200;
const int talkVoicePrerollMaxMs = 800;
const int talkVoicePrerollDefaultMs = 400;
const TalkVoiceChunkBoundary talkVoiceChunkBoundaryDefault =
    TalkVoiceChunkBoundary.fullStop;

const String _talkVoiceSpeedKey = 'storyvault_talk_voice_speed';
const String _talkVoicePrerollMsKey = 'storyvault_talk_voice_preroll_ms';
const String _talkVoiceChunkBoundaryKey =
    'storyvault_talk_voice_chunk_boundary';

enum TalkVoiceChunkBoundary { punctuation, fullStop, paragraph }

double clampTalkVoiceSpeed(double value) {
  return value.clamp(talkVoiceSpeedMin, talkVoiceSpeedMax);
}

int clampTalkVoicePrerollMs(int value) {
  return value.clamp(talkVoicePrerollMinMs, talkVoicePrerollMaxMs);
}

String talkVoiceChunkBoundaryStorageValue(TalkVoiceChunkBoundary value) {
  return switch (value) {
    TalkVoiceChunkBoundary.punctuation => 'punctuation',
    TalkVoiceChunkBoundary.fullStop => 'full_stop',
    TalkVoiceChunkBoundary.paragraph => 'paragraph',
  };
}

String talkVoiceChunkBoundaryLabel(TalkVoiceChunkBoundary value) {
  return switch (value) {
    TalkVoiceChunkBoundary.punctuation => 'Punctuation',
    TalkVoiceChunkBoundary.fullStop => 'Full stop',
    TalkVoiceChunkBoundary.paragraph => 'Paragraph',
  };
}

TalkVoiceChunkBoundary parseTalkVoiceChunkBoundary(String? value) {
  for (final TalkVoiceChunkBoundary boundary in TalkVoiceChunkBoundary.values) {
    if (talkVoiceChunkBoundaryStorageValue(boundary) == value) {
      return boundary;
    }
  }
  return talkVoiceChunkBoundaryDefault;
}

Future<double> loadTalkVoiceSpeed() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return clampTalkVoiceSpeed(
    preferences.getDouble(_talkVoiceSpeedKey) ?? talkVoiceSpeedDefault,
  );
}

Future<void> saveTalkVoiceSpeed(double value) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setDouble(_talkVoiceSpeedKey, clampTalkVoiceSpeed(value));
}

Future<int> loadTalkVoicePrerollMs() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return clampTalkVoicePrerollMs(
    preferences.getInt(_talkVoicePrerollMsKey) ?? talkVoicePrerollDefaultMs,
  );
}

Future<void> saveTalkVoicePrerollMs(int value) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setInt(
    _talkVoicePrerollMsKey,
    clampTalkVoicePrerollMs(value),
  );
}

Future<TalkVoiceChunkBoundary> loadTalkVoiceChunkBoundary() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return parseTalkVoiceChunkBoundary(
    preferences.getString(_talkVoiceChunkBoundaryKey),
  );
}

Future<void> saveTalkVoiceChunkBoundary(TalkVoiceChunkBoundary value) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _talkVoiceChunkBoundaryKey,
    talkVoiceChunkBoundaryStorageValue(value),
  );
}
